import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/schema_migrations.dart';

import '../support/test_database.dart';

Future<List<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return [for (final row in rows) '${row['name']}'];
}

Future<bool> _hasTable(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [table],
  );
  return rows.isNotEmpty;
}

const _foundationTables = [
  'stock_balances',
  'audit_events',
  'feature_audits',
  'employee_payroll_profiles',
  'salary_components',
];

Future<void> _createV2Fixture(Database db) async {
  await db.execute(
    'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  await db.execute('''
    CREATE TABLE license (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      plan TEXT NOT NULL DEFAULT 'free',
      period_end TEXT,
      device_limit INTEGER NOT NULL DEFAULT 1,
      store_limit INTEGER NOT NULL DEFAULT 1,
      provider TEXT NOT NULL DEFAULT 'manual',
      token TEXT,
      activated_at TEXT,
      server_time TEXT,
      last_verified_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE employee_accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      username TEXT NOT NULL,
      nama TEXT NOT NULL,
      role_base TEXT NOT NULL DEFAULT 'KASIR',
      extra_permissions_json TEXT NOT NULL DEFAULT '[]',
      store_ids_json TEXT NOT NULL DEFAULT '[]',
      password_hash TEXT NOT NULL,
      password_salt TEXT NOT NULL,
      aktif INTEGER NOT NULL DEFAULT 1,
      permission_version INTEGER NOT NULL DEFAULT 1,
      permissions_explicit INTEGER NOT NULL DEFAULT 0,
      jenis_imbalan TEXT NOT NULL DEFAULT 'KOMISI',
      gaji_bulanan INTEGER NOT NULL DEFAULT 0,
      komisi_mode TEXT NOT NULL DEFAULT 'PERSEN',
      komisi_barang_nilai INTEGER NOT NULL DEFAULT 0,
      komisi_jasa_nilai INTEGER NOT NULL DEFAULT 0,
      payroll_period TEXT NOT NULL DEFAULT 'BULANAN',
      payroll_tanggal INTEGER NOT NULL DEFAULT 1,
      payroll_hari INTEGER NOT NULL DEFAULT 1,
      bank_nama TEXT,
      bank_nomor TEXT,
      bank_pemilik TEXT,
      tanggal_masuk TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE stock_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      kode TEXT NOT NULL,
      nama TEXT NOT NULL,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      harga_jual INTEGER NOT NULL DEFAULT 0,
      jumlah INTEGER NOT NULL DEFAULT 0,
      jumlah_milli INTEGER,
      stok_minimum INTEGER NOT NULL DEFAULT 0,
      satuan TEXT NOT NULL DEFAULT 'pcs',
      desimal INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_peer_digests (
      source_device_id TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      data_type TEXT NOT NULL,
      jumlah INTEGER NOT NULL DEFAULT 0,
      hash TEXT NOT NULL DEFAULT '',
      received_at TEXT NOT NULL,
      PRIMARY KEY (source_device_id, tanggal, data_type)
    )
  ''');

  await db.insert('app_settings', {'key': 'bengkel.nama', 'value': 'Toko v2'});
  await db.insert('license', {'id': 1, 'plan': 'pro'});
  await db.insert('employee_accounts', {
    'sync_id': 'emp-1',
    'username': 'budi',
    'nama': 'Budi',
    'store_ids_json': '["toko-a","toko-b"]',
    'password_hash': 'hash',
    'password_salt': 'salt',
    'jenis_imbalan': 'GAJI',
    'gaji_bulanan': 5000,
    'komisi_mode': 'NOMINAL',
    'komisi_barang_nilai': 100,
    'komisi_jasa_nilai': 200,
    'bank_nama': 'BCA',
    'tanggal_masuk': '2024-01-01',
    'created_at': '2024-01-01T00:00:00.000Z',
    'updated_at': '2024-01-02T00:00:00.000Z',
  });
  await db.insert('stock_items', {
    'sync_id': 'stock-1',
    'store_id': 'toko-a',
    'kode': 'BRG-1',
    'nama': 'Oli',
    'harga_modal': 30000,
    'jumlah': 7,
    'jumlah_milli': null,
    'updated_at': '2024-01-02T00:00:00.000Z',
  });
  await db.insert('sync_peer_digests', {
    'source_device_id': 'dev-1',
    'tanggal': '2024-01-01',
    'data_type': 'nota',
    'received_at': '2024-01-01T00:00:00.000Z',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureTestDatabaseFactory();

  test(
    'skema bersih v3 tidak menyimpan kuantitas atau keanggotaan ganda',
    () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      expect(await db.getVersion(), AppDatabase.schemaVersion);
      expect(await _hasTable(db, 'app_meta'), isTrue);
      expect(await _hasTable(db, 'licenses'), isTrue);
      expect(await _hasTable(db, 'app_settings'), isFalse);
      expect(await _hasTable(db, 'license'), isFalse);
      expect(await _hasTable(db, 'sync_peer_digests'), isFalse);

      final stockColumns = await _columns(db, 'stock_items');
      expect(stockColumns, isNot(contains('jumlah')));
      expect(stockColumns, contains('jumlah_milli'));
      final stockInfo = await db.rawQuery('PRAGMA table_info(stock_items)');
      final milli = stockInfo.firstWhere(
        (row) => row['name'] == 'jumlah_milli',
      );
      expect(milli['notnull'], 1);

      expect(
        await _columns(db, 'employee_accounts'),
        isNot(contains('store_ids_json')),
      );
      for (final table in _foundationTables) {
        expect(await _hasTable(db, table), isTrue, reason: table);
      }

      final fk = await db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first.values.first, 1);
    },
  );

  test(
    'migrasi v2 ke v3 mengganti nama, backfill, dan menghapus kolom usang',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await _createV2Fixture(db);

      await runSchemaMigrations(db, from: 2, to: 3);

      expect(await _hasTable(db, 'app_meta'), isTrue);
      expect(await _hasTable(db, 'licenses'), isTrue);
      expect(await _hasTable(db, 'sync_peer_digests'), isFalse);

      final setting = await db.query(
        'app_meta',
        where: 'key = ?',
        whereArgs: ['bengkel.nama'],
      );
      expect(setting.first['value'], 'Toko v2');
      final license = await db.query('licenses');
      expect(license.first['plan'], 'pro');

      final stockColumns = await _columns(db, 'stock_items');
      expect(stockColumns, isNot(contains('jumlah')));
      final stock = await db.query('stock_items');
      expect(stock.first['jumlah_milli'], 7000);

      expect(
        await _columns(db, 'employee_accounts'),
        isNot(contains('store_ids_json')),
      );

      for (final table in _foundationTables) {
        expect(await _hasTable(db, table), isTrue, reason: table);
      }

      final profile = await db.query(
        'employee_payroll_profiles',
        where: 'employee_sync_id = ?',
        whereArgs: ['emp-1'],
      );
      expect(profile.single['jenis_imbalan'], 'GAJI');
      expect(profile.single['gaji_bulanan_cents'], 5000);
      expect(profile.single['komisi_barang_bp'], 100);
      expect(profile.single['komisi_jasa_bp'], 200);
      expect(profile.single['bank_nama'], 'BCA');

      final balance = await db.query(
        'stock_balances',
        where: 'stock_sync_id = ?',
        whereArgs: ['stock-1'],
      );
      expect(balance.single['qty_milli'], 7000);
      expect(balance.single['avg_cost_cents'], 30000);
      expect(balance.single['value_cents'], 210000);

      // Migrasi harus idempoten bila dijalankan ulang.
      await runSchemaMigrations(db, from: 2, to: 3);
      expect((await db.query('stock_items')).length, 1);
    },
  );

  test(
    'createDatabaseAt membuat database v3 dengan pengaturan dan FK',
    () async {
      // Flutter test default ke Android; paksa jalur SQLite polos di desktop.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final dir = await Directory.systemTemp.createTemp('pusatku-schema-v3');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'toko-baru.db');

      await AppDatabase.instance.createDatabaseAt(
        path,
        settings: {'sync.store_id': 'toko-baru'},
      );
      await AppDatabase.instance.checkpointDatabaseAt(path);

      final db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          readOnly: true,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      addTearDown(db.close);

      expect(await db.getVersion(), AppDatabase.schemaVersion);
      expect(await _hasTable(db, 'stock_balances'), isTrue);
      final setting = await db.query(
        'app_meta',
        where: 'key = ?',
        whereArgs: ['sync.store_id'],
      );
      expect(setting.first['value'], 'toko-baru');
      expect(await _columns(db, 'stock_items'), isNot(contains('jumlah')));
    },
  );

  test(
    'migrasi v9 menambah modal per baris dan backfill dari modal master',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE stock_items ('
        'sync_id TEXT PRIMARY KEY, harga_modal INTEGER NOT NULL DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE opening_balance_items ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "jenis TEXT NOT NULL, ref_sync_id TEXT NOT NULL DEFAULT '')",
      );
      await db.insert('stock_items', {
        'sync_id': 'stok-1',
        'harga_modal': 40000,
      });
      await db.insert('opening_balance_items', {
        'jenis': 'STOK',
        'ref_sync_id': 'stok-1',
      });

      await runSchemaMigrations(db, from: 8, to: 9);

      expect(await _columns(db, 'opening_balance_items'),
          contains('unit_cost_cents'));
      final row = (await db.query('opening_balance_items')).single;
      expect(row['unit_cost_cents'], 40000);

      // Idempoten bila migrasi dijalankan ulang.
      await runSchemaMigrations(db, from: 8, to: 9);
      expect(
        (await db.query('opening_balance_items')).single['unit_cost_cents'],
        40000,
      );
    },
  );

  test(
    'migrasi v10 menambah limit kredit dan pencatat persetujuan kredit',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE customers ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'sync_id TEXT NOT NULL UNIQUE)',
      );
      await db.execute(
        'CREATE TABLE service_records ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'sync_id TEXT NOT NULL UNIQUE)',
      );
      await db.insert('customers', {'sync_id': 'c1'});

      await runSchemaMigrations(db, from: 9, to: 10);

      expect(await _columns(db, 'customers'), contains('limit_kredit_cents'));
      expect(
        await _columns(db, 'service_records'),
        contains('kredit_disetujui_oleh'),
      );
      expect((await db.query('customers')).single['limit_kredit_cents'], 0);

      // Idempoten bila migrasi dijalankan ulang.
      await runSchemaMigrations(db, from: 9, to: 10);
      expect((await db.query('customers')).single['limit_kredit_cents'], 0);
    },
  );
}
