import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/money.dart';
import '../core/phone.dart';
import 'models.dart';
import 'store_registry.dart';

class AppDatabase {
  AppDatabase();

  static final AppDatabase instance = AppDatabase();

  static const int schemaVersion = 8;

  Database? _db;
  String? _path;
  String? _activeStoreId;

  Database get db {
    final value = _db;
    if (value == null) {
      throw StateError('Database belum dibuka.');
    }
    return value;
  }

  String get databasePath {
    final value = _path;
    if (value == null) {
      throw StateError('Database belum dibuka.');
    }
    return value;
  }

  bool get isOpen => _db != null;

  String? get activeStoreId => _activeStoreId;

  Future<void> init() async {
    if (_db != null) return;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      _path = 'pusatkupos.db';
      _activeStoreId = 'utama';
    } else {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      final dir = await getApplicationSupportDirectory();
      await StoreRegistry.instance.open(dir.path);
      final store = await StoreRegistry.instance.ensureDefault(
        p.join(dir.path, 'pusatkupos.db'),
        nama: 'Toko utama',
      );
      _activeStoreId = store.storeId;
      _path = store.databasePath;
    }
    await _open();
    await _syncRegistryLabel();
  }

  Future<void> initForTest(String path) async {
    await close();
    await StoreRegistry.instance.close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _path = path;
    _activeStoreId = 'utama';
    await _open();
  }

  Future<void> _syncRegistryLabel() async {
    if (kIsWeb) return;
    final storeId = _activeStoreId;
    if (storeId == null) return;
    final record = await StoreRegistry.instance.byId(storeId);
    if (record == null) return;
    final nama = await getSetting('bengkel.nama');
    if (nama == null || nama.trim().isEmpty) return;
    final alamat = await getSetting('bengkel.alamat') ?? '';
    if (record.nama == nama && record.alamat == alamat) return;
    await StoreRegistry.instance.updateName(
      storeId,
      nama: nama,
      alamat: alamat,
    );
  }

  Future<void> switchStore(StoreRecord store) async {
    if (_activeStoreId == store.storeId && _db != null) return;
    await close();
    _path = store.databasePath;
    _activeStoreId = store.storeId;
    await _open();
  }

  Future<void> createDatabaseAt(
    String path, {
    Map<String, String> settings = const {},
    bool copyOwner = false,
    bool copyLicense = false,
  }) async {
    Map<String, Object?>? ownerRow;
    Map<String, Object?>? licenseRow;
    if (copyOwner) {
      final rows = await db.query('owner_identity', limit: 1);
      ownerRow = rows.isEmpty ? null : Map.of(rows.first);
    }
    if (copyLicense) {
      final rows = await db.query('license', limit: 1);
      licenseRow = rows.isEmpty ? null : Map.of(rows.first);
    }
    final fresh = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgrade,
      ),
    );
    try {
      for (final entry in settings.entries) {
        await fresh.insert(
          'app_settings',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (ownerRow != null) {
        await fresh.insert('owner_identity', ownerRow);
      }
      if (licenseRow != null) {
        await fresh.insert('license', licenseRow);
      }
    } finally {
      await fresh.close();
    }
  }

  Future<void> _open() async {
    _db = await databaseFactory.openDatabase(
      _path!,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgrade,
      ),
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> reopen() async {
    await close();
    await _open();
  }

  Future<void> checkpoint() async {
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        nomor_hp TEXT NOT NULL,
        alamat TEXT,
        wa_consent INTEGER NOT NULL DEFAULT 1,
        do_not_contact INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_customers_nama ON customers(nama)',
    );
    await db.execute('''
      CREATE TABLE vehicle_or_units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        customer_id INTEGER NOT NULL,
        unit_type TEXT NOT NULL,
        nopol TEXT,
        jenis_mobil TEXT,
        tahun_mobil INTEGER,
        tipe_radiator TEXT,
        label_radiator TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        kode TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        harga_modal INTEGER NOT NULL DEFAULT 0,
        harga_jual INTEGER NOT NULL DEFAULT 0,
        jumlah INTEGER NOT NULL DEFAULT 0,
        stok_minimum INTEGER NOT NULL DEFAULT 0,
        satuan TEXT NOT NULL DEFAULT 'pcs',
        desimal INTEGER NOT NULL DEFAULT 0,
        jumlah_milli INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_stock_items_nama ON stock_items(nama)',
    );
    await db.execute('''
      CREATE TABLE harga_jasa (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        harga_standar INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE service_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        unit_id INTEGER NOT NULL,
        no_nota TEXT NOT NULL UNIQUE,
        request_id TEXT UNIQUE,
        waktu_service TEXT NOT NULL,
        keluhan_awal TEXT NOT NULL,
        catatan_pengerjaan TEXT,
        biaya_jasa INTEGER NOT NULL DEFAULT 0,
        total_part INTEGER NOT NULL DEFAULT 0,
        diskon INTEGER NOT NULL DEFAULT 0,
        total_servis INTEGER NOT NULL DEFAULT 0,
        metode_bayar TEXT NOT NULL DEFAULT 'CASH',
        bayar INTEGER NOT NULL DEFAULT 0,
        kembalian INTEGER NOT NULL DEFAULT 0,
        status_bayar TEXT NOT NULL DEFAULT 'LUNAS',
        jenis_bayar TEXT NOT NULL DEFAULT 'LUNAS',
        total_dibayar INTEGER NOT NULL DEFAULT 0,
        sisa_bayar INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'AKTIF',
        void_reason TEXT,
        voided_at TEXT,
        created_by TEXT,
        created_by_employee_id TEXT,
        mechanic TEXT,
        mechanic_employee_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (unit_id) REFERENCES vehicle_or_units(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_service_records_waktu ON service_records(waktu_service)',
    );
    await db.execute('''
      CREATE TABLE service_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        harga_jasa_id INTEGER,
        deskripsi TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        harga INTEGER NOT NULL,
        subtotal INTEGER NOT NULL,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE service_parts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        stock_item_id INTEGER,
        nama_part TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        harga_satuan INTEGER NOT NULL,
        subtotal INTEGER NOT NULL,
        harga_modal INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE service_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        jenis TEXT NOT NULL DEFAULT 'PELUNASAN',
        metode TEXT NOT NULL DEFAULT 'CASH',
        nominal INTEGER NOT NULL,
        waktu TEXT NOT NULL,
        operator TEXT NOT NULL DEFAULT 'Pemilik',
        request_id TEXT UNIQUE,
        catatan TEXT,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        stock_item_id INTEGER,
        nama_item TEXT,
        jenis TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        jumlah_milli INTEGER,
        alasan TEXT,
        service_record_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE nota_counters (
        tanggal TEXT PRIMARY KEY,
        terakhir INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final now = nowIso();
    await db.insert('app_settings', {
      'key': 'bengkel.nama',
      'value': 'PUSATKU POS',
    });
    await db.insert('app_settings', {
      'key': 'bengkel.alamat',
      'value': '',
    });
    await db.insert('app_settings', {'key': 'app.created_at', 'value': now});
    await _upgradeV7(db);
    await _createSyncSchema(db);
    await _upgradeV8(db);
    await _addSyncIds(db);
  }

  Future<void> _addSyncIds(Database db) async {
    for (final table in const [
      'service_jobs',
      'service_parts',
      'service_payments',
      'stock_movements',
    ]) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (!columns.any((column) => column['name'] == 'sync_id')) {
        await db.execute('ALTER TABLE $table ADD COLUMN sync_id TEXT');
      }
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS ux_${table}_sync_id ON $table(sync_id)',
      );
    }
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSyncSchema(db);
    }
    if (oldVersion < 3) {
      await _addSyncIds(db);
    }
    if (oldVersion < 4) {
      await _upgradeV4(db);
    }
    if (oldVersion < 5) {
      await _upgradeV5(db);
    }
    if (oldVersion < 6) {
      await _upgradeV6(db);
    }
    if (oldVersion < 7) {
      await _upgradeV7(db);
    }
    if (oldVersion < 8) {
      await _upgradeV8(db);
    }
  }

  Future<void> _addColumn(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((entry) => entry['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<void> _upgradeV7(Database db) async {
    await _addColumn(db, 'service_records', 'bergaransi',
        'INTEGER NOT NULL DEFAULT 1');
    await _addColumn(db, 'service_records', 'garansi_bulan',
        'INTEGER NOT NULL DEFAULT 1');
    await _addColumn(db, 'service_records', 'garansi_sampai', 'TEXT');
    await _addColumn(db, 'service_records', 'catatan_garansi', 'TEXT');
    await _addColumn(db, 'service_records', 'status_klaim',
        "TEXT NOT NULL DEFAULT 'Belum claim'");
    await _addColumn(db, 'service_records', 'tanggal_klaim', 'TEXT');
    await _addColumn(db, 'service_records', 'sparepart_only',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'service_records', 'garansi_barang_aktif',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'service_records', 'garansi_barang_nilai',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'service_records', 'garansi_barang_satuan',
        "TEXT NOT NULL DEFAULT 'HARI'");
    await _addColumn(db, 'service_records', 'garansi_barang_sampai', 'TEXT');
    await _addColumn(db, 'service_records', 'unit_ditinggal',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'service_records', 'diambil_at', 'TEXT');
    await _addColumn(db, 'service_jobs', 'interval_servis_bulan',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'service_parts', 'interval_servis_bulan',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'stock_items', 'interval_servis_bulan',
        'INTEGER NOT NULL DEFAULT 0');
    await _addColumn(db, 'harga_jasa', 'interval_servis_bulan',
        'INTEGER NOT NULL DEFAULT 0');
    await _createFeatureSchemaV7(db);
  }

  Future<void> _createFeatureSchemaV7(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS followup_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        jenis TEXT NOT NULL,
        item_key TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'AKTIF',
        stage INTEGER NOT NULL DEFAULT 0,
        interval_bulan INTEGER NOT NULL DEFAULT 0,
        reference_date TEXT,
        jatuh_tempo TEXT,
        customer_id INTEGER,
        unit_id INTEGER,
        service_record_id INTEGER,
        followup_terakhir TEXT,
        janji_bayar TEXT,
        tanggal_service TEXT,
        tunda_sampai TEXT,
        no_response_count INTEGER NOT NULL DEFAULT 0,
        perlu_telepon INTEGER NOT NULL DEFAULT 0,
        alasan_arsip TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_followup_item_aktif '
      "ON followup_items(item_key) WHERE status <> 'ARSIP'",
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS followup_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        item_id INTEGER NOT NULL,
        jenis TEXT NOT NULL,
        status TEXT,
        catatan TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (item_id) REFERENCES followup_items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wa_message_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        customer_id INTEGER,
        jenis TEXT NOT NULL,
        status TEXT NOT NULL,
        nomor_masked TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        nomor_hp TEXT,
        alamat TEXT,
        catatan TEXT,
        aktif INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        supplier_id INTEGER NOT NULL,
        stock_item_id INTEGER NOT NULL,
        UNIQUE(supplier_id, stock_item_id),
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
        FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_followups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        supplier_id INTEGER NOT NULL,
        stock_item_id INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'BELUM',
        catatan TEXT,
        updated_at TEXT NOT NULL,
        UNIQUE(supplier_id, stock_item_id),
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
        FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _upgradeV8(Database db) async {
    const compensation = <(String, String)>[
      ('jenis_imbalan', "TEXT NOT NULL DEFAULT 'KOMISI'"),
      ('gaji_bulanan', 'INTEGER NOT NULL DEFAULT 0'),
      ('komisi_mode', "TEXT NOT NULL DEFAULT 'PERSEN'"),
      ('komisi_barang_nilai', 'INTEGER NOT NULL DEFAULT 0'),
      ('komisi_jasa_nilai', 'INTEGER NOT NULL DEFAULT 0'),
      ('payroll_period', "TEXT NOT NULL DEFAULT 'BULANAN'"),
      ('payroll_tanggal', 'INTEGER NOT NULL DEFAULT 1'),
      ('payroll_hari', 'INTEGER NOT NULL DEFAULT 1'),
      ('bank_nama', 'TEXT'),
      ('bank_nomor', 'TEXT'),
      ('bank_pemilik', 'TEXT'),
      ('tanggal_masuk', 'TEXT'),
    ];
    for (final (name, definition) in compensation) {
      await _addColumn(db, 'employee_accounts', name, definition);
    }
    await _addColumn(db, 'service_records', 'cashier_employee_id', 'TEXT');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_record_mechanics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        service_record_id INTEGER NOT NULL,
        employee_sync_id TEXT NOT NULL,
        urutan INTEGER NOT NULL DEFAULT 0,
        UNIQUE(service_record_id, employee_sync_id),
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_record_commissions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        service_record_id INTEGER NOT NULL,
        employee_sync_id TEXT NOT NULL,
        nominal INTEGER NOT NULL DEFAULT 0,
        nominal_override INTEGER,
        UNIQUE(service_record_id, employee_sync_id),
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS employee_debts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        employee_sync_id TEXT NOT NULL,
        nominal INTEGER NOT NULL,
        terbayar INTEGER NOT NULL DEFAULT 0,
        catatan TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS salary_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        employee_sync_id TEXT NOT NULL,
        periode TEXT NOT NULL,
        cycle_start TEXT NOT NULL,
        cycle_end TEXT NOT NULL,
        tanggal TEXT NOT NULL,
        nominal INTEGER NOT NULL,
        potongan_hutang INTEGER NOT NULL DEFAULT 0,
        cicilan_hutang INTEGER NOT NULL DEFAULT 0,
        bonus INTEGER NOT NULL DEFAULT 0,
        metode TEXT NOT NULL DEFAULT 'CASH',
        catatan TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(employee_sync_id, cycle_start)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_commissions_employee '
      'ON service_record_commissions(employee_sync_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_debts_employee '
      'ON employee_debts(employee_sync_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_salary_employee '
      'ON salary_payments(employee_sync_id)',
    );
  }

  Future<void> _upgradeV6(Database db) async {
    await db.delete(
      'nota_counters',
      where: 'tanggal <> ?',
      whereArgs: [_numericNotaKey],
    );
    await _seedNumericNotaCounter(db);
  }

  Future<void> _seedNumericNotaCounter(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      '''
      SELECT MAX(CAST(no_nota AS INTEGER)) AS terakhir
      FROM service_records
      WHERE no_nota <> '' AND no_nota NOT GLOB '*[^0-9]*'
      ''',
    );
    final terakhir = (rows.first['terakhir'] as int?) ?? 0;
    await db.rawInsert(
      'INSERT INTO nota_counters(tanggal, terakhir) VALUES(?, ?) '
      'ON CONFLICT(tanggal) DO UPDATE SET terakhir = MAX(terakhir, excluded.terakhir)',
      [_numericNotaKey, terakhir],
    );
  }

  // Sebelum v5 kolom ini menyimpan id lokal perangkat. Id lokal berbeda di
  // tiap perangkat, jadi audit lintas perangkat hanya benar dengan sync_id.
  Future<void> _upgradeV5(Database db) async {
    for (final column in const ['created_by_employee_id', 'mechanic_employee_id']) {
      await db.execute('''
UPDATE service_records
SET $column = (
  SELECT sync_id FROM employee_accounts
  WHERE employee_accounts.id = CAST(service_records.$column AS INTEGER)
)
WHERE $column IS NOT NULL
  AND $column <> ''
  AND $column NOT GLOB '*[^0-9]*'
  AND EXISTS (
    SELECT 1 FROM employee_accounts
    WHERE employee_accounts.id = CAST(service_records.$column AS INTEGER)
  )
''');
    }
  }

  Future<void> _upgradeV4(Database db) async {
    final columns = <String, List<(String, String)>>{
      'stock_items': [
        ('satuan', "TEXT NOT NULL DEFAULT 'pcs'"),
        ('desimal', 'INTEGER NOT NULL DEFAULT 0'),
        ('jumlah_milli', 'INTEGER'),
      ],
      'stock_movements': [
        ('jumlah_milli', 'INTEGER'),
      ],
      'service_records': [
        ('created_by', 'TEXT'),
        ('created_by_employee_id', 'TEXT'),
        ('mechanic', 'TEXT'),
        ('mechanic_employee_id', 'TEXT'),
      ],
    };
    for (final entry in columns.entries) {
      final tableColumns = await db.rawQuery('PRAGMA table_info(${entry.key})');
      final existing = tableColumns.map((row) => row['name']).toSet();
      for (final (name, definition) in entry.value) {
        if (!existing.contains(name)) {
          await db.execute('ALTER TABLE ${entry.key} ADD COLUMN $name $definition');
        }
      }
    }
    await db.execute(
      'UPDATE stock_items SET jumlah_milli = jumlah * 1000 '
      'WHERE jumlah_milli IS NULL',
    );
    await db.execute(
      'UPDATE stock_movements SET jumlah_milli = jumlah * 1000 '
      'WHERE jumlah_milli IS NULL',
    );
    await _migrateTimestampsToUtc(db);
  }

  Future<void> _migrateTimestampsToUtc(Database db) async {
    final targets = <String, List<String>>{
      'customers': ['created_at'],
      'vehicle_or_units': ['created_at'],
      'stock_items': ['created_at'],
      'harga_jasa': ['created_at'],
      'service_records': [
        'waktu_service',
        'voided_at',
        'created_at',
        'updated_at',
      ],
      'service_payments': ['waktu'],
      'stock_movements': ['created_at'],
      'permission_audits': ['created_at'],
      'sync_outbox': ['created_at', 'sent_at'],
    };
    for (final entry in targets.entries) {
      for (final column in entry.value) {
        final rows = await db.query(
          entry.key,
          columns: ['id', column],
          where: "$column IS NOT NULL AND $column != ''",
        );
        for (final row in rows) {
          final raw = row[column] as String? ?? '';
          if (raw.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(raw)) {
            continue;
          }
          final parsed = DateTime.tryParse(raw);
          if (parsed == null) continue;
          await db.update(
            entry.key,
            {column: parsed.toUtc().toIso8601String()},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    }
  }

  Future<void> _createSyncSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS owner_identity (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        owner_id TEXT NOT NULL,
        public_key TEXT NOT NULL,
        recovery_hash TEXT,
        recovery_salt TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS license (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        plan TEXT NOT NULL DEFAULT 'free',
        period_end TEXT,
        device_limit INTEGER NOT NULL DEFAULT 1,
        provider TEXT NOT NULL DEFAULT 'manual',
        token TEXT,
        activated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS employee_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        role_base TEXT NOT NULL DEFAULT 'KASIR',
        extra_permissions_json TEXT NOT NULL DEFAULT '[]',
        store_ids_json TEXT NOT NULL DEFAULT '[]',
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_iterations INTEGER NOT NULL DEFAULT 120000,
        pin_hash TEXT,
        pin_salt TEXT,
        pin_iterations INTEGER NOT NULL DEFAULT 120000,
        must_change_password INTEGER NOT NULL DEFAULT 1,
        aktif INTEGER NOT NULL DEFAULT 1,
        permission_version INTEGER NOT NULL DEFAULT 1,
        last_login_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS permission_audits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor TEXT NOT NULL,
        target_account_id INTEGER,
        action TEXT NOT NULL,
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        nama TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'owner',
        employee_account_id INTEGER,
        public_key TEXT NOT NULL,
        encryption_key TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        last_seen_at TEXT,
        revoked_at TEXT,
        revoked_reason TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS login_guards (
        scope TEXT PRIMARY KEY,
        failures INTEGER NOT NULL DEFAULT 0,
        lock_until TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        hlc_wall INTEGER NOT NULL,
        hlc_counter INTEGER NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL DEFAULT '',
        action TEXT NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        error TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        sent_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursor (
        store_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        last_seq INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (store_id, device_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS applied_deltas (
        idempotency_key TEXT PRIMARY KEY,
        envelope_id TEXT NOT NULL DEFAULT '',
        entity TEXT NOT NULL DEFAULT '',
        entity_id TEXT NOT NULL DEFAULT '',
        applied_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL DEFAULT '',
        reason TEXT NOT NULL,
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        resolved_at TEXT
      )
    ''');
  }

  Future<String?> getSetting(String key) async {
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSetting(String key) async {
    await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<List<Customer>> listCustomers({String query = ''}) async {
    final term = query.trim();
    final escaped = escapeLike(term);
    final rows = await db.query(
      'customers',
      where: term.isEmpty
          ? null
          : "nama LIKE ? ESCAPE '\\' OR nomor_hp LIKE ? ESCAPE '\\'",
      whereArgs: term.isEmpty ? null : ['%$escaped%', '%$escaped%'],
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(Customer.fromRow).toList();
  }

  Future<Map<String, Object?>?> customerRow(int id) async {
    final rows = await db.query(
      'customers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Customer?> customerByPhone(String nomorHp) async {    final normalized = normalizePhone(nomorHp);
    if (normalized.isEmpty) return null;
    final rows = await db.query('customers');
    for (final row in rows) {
      if (normalizePhone(row['nomor_hp'] as String? ?? '') == normalized) {
        return Customer.fromRow(row);
      }
    }
    return null;
  }

  Future<int> addCustomer({
    required String nama,
    required String nomorHp,
    String? alamat,
    bool waConsent = true,
    bool doNotContact = false,
    bool allowDuplicate = false,
  }) {
    return db.transaction((txn) async {
      final normalized = normalizePhone(nomorHp);
      if (normalized.isEmpty) {
        throw ArgumentError('Nomor HP wajib diisi.');
      }
      if (!allowDuplicate) {
        final rows = await txn.query('customers');
        for (final row in rows) {
          if (normalizePhone(row['nomor_hp'] as String? ?? '') == normalized) {
            throw DuplicateCustomerException(
              existingId: row['id'] as int,
              existingName: row['nama'] as String? ?? '',
            );
          }
        }
      }
      return txn.insert('customers', {
        'sync_id': newSyncId(),
        'nama': nama.trim(),
        'nomor_hp': normalized,
        'alamat': (alamat ?? '').trim().isEmpty ? null : alamat!.trim(),
        'wa_consent': waConsent ? 1 : 0,
        'do_not_contact': doNotContact ? 1 : 0,
        'created_at': nowIso(),
      });
    });
  }

  Future<void> updateCustomer({
    required int id,
    required String nama,
    required String nomorHp,
    String? alamat,
    bool waConsent = true,
    bool doNotContact = false,
  }) async {
    final normalized = normalizePhone(nomorHp);
    if (normalized.isEmpty) {
      throw ArgumentError('Nomor HP wajib diisi.');
    }
    final rows = await db.query('customers');
    for (final row in rows) {
      if (row['id'] == id) continue;
      if (normalizePhone(row['nomor_hp'] as String? ?? '') == normalized) {
        throw DuplicateCustomerException(
          existingId: row['id'] as int,
          existingName: row['nama'] as String? ?? '',
        );
      }
    }
    await db.update(
      'customers',
      {
        'nama': nama.trim(),
        'nomor_hp': normalized,
        'alamat': (alamat ?? '').trim().isEmpty ? null : alamat!.trim(),
        'wa_consent': waConsent ? 1 : 0,
        'do_not_contact': doNotContact ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, List<int>>> mergeCustomers({
    required int sourceId,
    required int targetId,
  }) async {
    if (sourceId == targetId) {
      throw ArgumentError('Pelanggan asal dan tujuan harus berbeda.');
    }
    return db.transaction((txn) async {
      final target = await txn.query(
        'customers',
        where: 'id = ?',
        whereArgs: [targetId],
        limit: 1,
      );
      if (target.isEmpty) throw StateError('Pelanggan tujuan tidak ditemukan.');
      final units = await txn.query(
        'vehicle_or_units',
        columns: ['id'],
        where: 'customer_id = ?',
        whereArgs: [sourceId],
      );
      final unitIds = units.map((row) => row['id'] as int).toList();
      if (unitIds.isEmpty) {
        await txn.delete('customers', where: 'id = ?', whereArgs: [sourceId]);
        return {'units': unitIds, 'records': <int>[]};
      }
      final records = await txn.query(
        'service_records',
        columns: ['id'],
        where: 'unit_id IN (${List.filled(unitIds.length, '?').join(',')})',
        whereArgs: unitIds,
      );
      await txn.update(
        'vehicle_or_units',
        {'customer_id': targetId},
        where: 'customer_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete('customers', where: 'id = ?', whereArgs: [sourceId]);
      return {
        'units': unitIds,
        'records': records.map((row) => row['id'] as int).toList(),
      };
    });
  }

  Future<List<VehicleUnit>> listUnits(int customerId) async {
    final rows = await db.query(
      'vehicle_or_units',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'id DESC',
    );
    return rows.map(VehicleUnit.fromRow).toList();
  }

  Future<int> addUnit({
    required int customerId,
    required String unitType,
    String? nopol,
    String? jenisMobil,
    int? tahunMobil,
    String? tipeRadiator,
    String? labelRadiator,
  }) {
    return db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'unit_type': unitType,
      'nopol': _nullable(nopol),
      'jenis_mobil': _nullable(jenisMobil),
      'tahun_mobil': tahunMobil,
      'tipe_radiator': _nullable(tipeRadiator),
      'label_radiator': _nullable(labelRadiator),
      'created_at': nowIso(),
    });
  }

  Future<List<StockItem>> listStock({String query = ''}) async {
    final term = query.trim();
    final escaped = escapeLike(term);
    final rows = await db.query(
      'stock_items',
      where: term.isEmpty
          ? null
          : "nama LIKE ? ESCAPE '\\' OR kode LIKE ? ESCAPE '\\'",
      whereArgs: term.isEmpty ? null : ['%$escaped%', '%$escaped%'],
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(StockItem.fromRow).toList();
  }

  Future<int> saveStockItem({
    int? id,
    required String kode,
    required String nama,
    required int hargaModalCents,
    required int hargaJualCents,
    required int jumlah,
    required int stokMinimum,
    int? jumlahMilli,
    String satuan = 'pcs',
    int desimal = 0,
    int intervalBulan = 0,
    String? alasan,
    Operator? actor,
  }) async {
    if (actor != null) Permissions.require(actor, permissionChangeStock);
    if (hargaModalCents < 0 || hargaJualCents < 0) {
      throw ArgumentError('Harga tidak boleh negatif.');
    }
    final milli = jumlahMilli ?? jumlah * 1000;
    if (milli < 0) throw ArgumentError('Stok tidak boleh negatif.');
    final cleanKode = kode.trim();
    if (cleanKode.isEmpty || nama.trim().isEmpty) {
      throw ArgumentError('Kode dan nama barang wajib diisi.');
    }
    final duplicate = await db.query(
      'stock_items',
      columns: ['id', 'nama'],
      where: 'kode = ?',
      whereArgs: [cleanKode],
      limit: 1,
    );
    if (duplicate.isNotEmpty && duplicate.first['id'] != id) {
      throw StateError(
        'Kode barang "$cleanKode" sudah dipakai oleh '
        '"${duplicate.first['nama']}". Gunakan kode lain.',
      );
    }
    final payload = {
      'kode': cleanKode,
      'nama': nama.trim(),
      'harga_modal': hargaModalCents,
      'harga_jual': hargaJualCents,
      'jumlah': milli ~/ 1000,
      'jumlah_milli': milli,
      'stok_minimum': stokMinimum,
      'satuan': satuan.trim().isEmpty ? 'pcs' : satuan.trim(),
      'desimal': desimal.clamp(0, 3),
      'interval_servis_bulan': intervalBulan < 0 ? 0 : intervalBulan,
    };
    if (id != null) {
      return db.transaction((txn) async {
        final rows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('Barang tidak ditemukan.');
        final before = StockItem.fromRow(rows.first);
        await txn.update('stock_items', payload, where: 'id = ?', whereArgs: [id]);
        final delta = milli - before.jumlahMilli;
        if (delta != 0) {
          await txn.insert('stock_movements', {
            'sync_id': newSyncId(),
            'stock_item_id': id,
            'nama_item': payload['nama'],
            'jenis': 'KOREKSI',
            'jumlah': delta ~/ 1000,
            'jumlah_milli': delta,
            'alasan': (alasan ?? '').trim().isEmpty
                ? 'Koreksi stok'
                : alasan!.trim(),
            'created_at': nowIso(),
          });
        }
        return id;
      });
    }
    return db.transaction((txn) async {
      final newId = await txn.insert('stock_items', {
        ...payload,
        'sync_id': newSyncId(),
        'created_at': nowIso(),
      });
      if (milli != 0) {
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': newId,
          'nama_item': payload['nama'],
          'jenis': 'MASUK',
          'jumlah': milli ~/ 1000,
          'jumlah_milli': milli,
          'alasan': (alasan ?? '').trim().isEmpty
              ? 'Stok awal'
              : alasan!.trim(),
          'created_at': nowIso(),
        });
      }
      return newId;
    });
  }

  Future<void> stockIn({
    required StockItem item,
    required int qty,
    int? qtyMilli,
    String? alasan,
    Operator? actor,
  }) async {
    if (actor != null) Permissions.require(actor, permissionStockIn);
    final milli = qtyMilli ?? qty * 1000;
    if (milli <= 0) throw ArgumentError('Jumlah stok masuk minimal 1.');
    await _adjustStock(
      item: item,
      deltaMilli: milli,
      jenis: 'MASUK',
      alasan: (alasan ?? '').trim().isEmpty ? 'Tambah stok' : alasan!.trim(),
      serviceRecordId: null,
    );
  }

  Future<void> stockOut({
    required StockItem item,
    required int qty,
    int? qtyMilli,
    required String alasan,
    Operator? actor,
  }) async {
    if (actor != null) Permissions.require(actor, permissionStockOut);
    final milli = qtyMilli ?? qty * 1000;
    if (milli <= 0) throw ArgumentError('Jumlah stok keluar minimal 1.');
    final reason = alasan.trim();
    if (reason.isEmpty) {
      throw ArgumentError('Alasan stok keluar wajib diisi.');
    }
    await _adjustStock(
      item: item,
      deltaMilli: -milli,
      jenis: 'KELUAR',
      alasan: reason,
      serviceRecordId: null,
    );
  }

  Future<void> opname({
    required StockItem item,
    required int jumlahFisikMilli,
    String? alasan,
    Operator? actor,
  }) async {
    if (actor != null) Permissions.require(actor, permissionOpname);
    if (jumlahFisikMilli < 0) {
      throw ArgumentError('Jumlah fisik tidak boleh negatif.');
    }
    await db.transaction((txn) async {
      final rows = await txn.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Barang tidak ditemukan.');
      final before = StockItem.fromRow(rows.first);
      final delta = jumlahFisikMilli - before.jumlahMilli;
      await txn.update(
        'stock_items',
        {'jumlah': jumlahFisikMilli ~/ 1000, 'jumlah_milli': jumlahFisikMilli},
        where: 'id = ?',
        whereArgs: [item.id],
      );
      await txn.insert('stock_movements', {
        'sync_id': newSyncId(),
        'stock_item_id': item.id,
        'nama_item': item.nama,
        'jenis': 'KOREKSI',
        'jumlah': delta ~/ 1000,
        'jumlah_milli': delta,
        'alasan': (alasan ?? '').trim().isEmpty
            ? 'Opname stok'
            : alasan!.trim(),
        'created_at': nowIso(),
      });
    });
  }

  Future<void> _adjustStock({
    required StockItem item,
    required int deltaMilli,
    required String jenis,
    required String alasan,
    required int? serviceRecordId,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Barang tidak ditemukan.');
      final before = StockItem.fromRow(rows.first);
      final next = before.jumlahMilli + deltaMilli;
      await txn.update(
        'stock_items',
        {'jumlah': next ~/ 1000, 'jumlah_milli': next},
        where: 'id = ?',
        whereArgs: [item.id],
      );
      await txn.insert('stock_movements', {
        'sync_id': newSyncId(),
        'stock_item_id': item.id,
        'nama_item': item.nama,
        'jenis': jenis,
        'jumlah': deltaMilli ~/ 1000,
        'jumlah_milli': deltaMilli,
        'alasan': alasan,
        'service_record_id': serviceRecordId,
        'created_at': nowIso(),
      });
    });
  }

  Future<List<ServiceCatalog>> listCatalog() async {
    final rows = await db.query(
      'harga_jasa',
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(ServiceCatalog.fromRow).toList();
  }

  Future<int> saveCatalog({
    int? id,
    required String nama,
    required int hargaCents,
    int intervalBulan = 0,
    Operator? actor,
  }) async {
    if (actor != null) {
      Permissions.require(actor, permissionChangeServicePrice);
    }
    if (hargaCents < 0) {
      throw ArgumentError('Harga jasa tidak boleh negatif.');
    }
    final payload = {
      'nama': nama.trim(),
      'harga_standar': hargaCents,
      'interval_servis_bulan': intervalBulan < 0 ? 0 : intervalBulan,
    };
    if (id != null) {
      await db.update(
        'harga_jasa',
        payload,
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return db.insert('harga_jasa', {
      ...payload,
      'sync_id': newSyncId(),
      'created_at': nowIso(),
    });
  }

  Future<void> deleteCatalog(int id, {Operator? actor}) async {
    if (actor != null) {
      Permissions.require(actor, permissionChangeServicePrice);
    }
    await db.delete('harga_jasa', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> createTransaction({
    required int unitId,
    required String keluhan,
    required List<JobDraft> jobs,
    required List<PartDraft> parts,
    required int diskonCents,
    required String metodeBayar,
    required int bayarCents,
    String? requestId,
    String? catatan,
    Operator? actor,
    String? mechanic,
    String? mechanicEmployeeSyncId,
    List<String> mechanicEmployeeSyncIds = const [],
    bool sparepartOnly = false,
    bool bergaransi = true,
    int garansiBulan = 1,
    DateTime? garansiSampai,
    String? catatanGaransi,
    bool garansiBarangAktif = false,
    int garansiBarangNilai = 0,
    String garansiBarangSatuan = 'HARI',
    bool unitDitinggal = false,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    if (jobs.isEmpty && parts.isEmpty) {
      throw ArgumentError('Tambahkan minimal satu jasa atau part.');
    }
    if (sparepartOnly && jobs.isNotEmpty) {
      throw ArgumentError('Mode sparepart hanya tidak boleh memuat jasa.');
    }
    if (sparepartOnly && parts.isEmpty) {
      throw ArgumentError('Mode sparepart hanya membutuhkan minimal satu part.');
    }
    if (diskonCents < 0) {
      throw ArgumentError('Diskon tidak boleh negatif.');
    }
    if (bayarCents < 0) {
      throw ArgumentError('Nominal bayar tidak boleh negatif.');
    }
    if (actor != null && diskonCents > 0) {
      Permissions.require(actor, permissionDiscount);
    }
    if (metodeBayar != 'CASH' && metodeBayar != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak dikenal.');
    }
    for (final job in jobs) {
      if (job.jumlah <= 0) {
        throw ArgumentError('Jumlah jasa harus lebih dari nol.');
      }
      if (job.hargaCents < 0) {
        throw ArgumentError('Harga jasa tidak boleh negatif.');
      }
    }
    return db.transaction((txn) async {
      if ((requestId ?? '').trim().isNotEmpty) {
        final existing = await txn.query(
          'service_records',
          columns: ['id'],
          where: 'request_id = ?',
          whereArgs: [requestId!.trim()],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final id = existing.first['id'] as int;
          if (enqueue != null) await enqueue(txn, id);
          return id;
        }
      }
      for (final part in parts) {
        if (part.jumlah <= 0) {
          throw ArgumentError('Jumlah part harus lebih dari nol.');
        }
        if (part.hargaCents < 0) {
          throw ArgumentError('Harga part tidak boleh negatif.');
        }
        final rows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [part.stockItemId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw StateError('Barang ${part.nama} tidak ditemukan.');
        }
        final stock = StockItem.fromRow(rows.first);
        if (stock.hargaJualCents != part.hargaCents) {
          throw StateError(
            'Harga jual ${stock.nama} berubah menjadi '
            '${formatRupiah(stock.hargaJualCents)}. '
            'Muat ulang kasir lalu ulangi.',
          );
        }
        if (stock.jumlahMilli < part.jumlah * 1000) {
          throw StateError(
            'Stok ${stock.nama} tidak cukup (tersisa ${stock.jumlahLabel}).',
          );
        }
        part
          ..nama = stock.nama
          ..modalCents = stock.hargaModalCents;
      }
      final biayaJasa = jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents);
      final totalPart =
          parts.fold<int>(0, (sum, part) => sum + part.subtotalCents);
      final bruto = biayaJasa + totalPart;
      if (diskonCents > bruto) {
        throw ArgumentError('Diskon melebihi total tagihan.');
      }
      final total = bruto - diskonCents;
      final isOwner = actor?.isOwner ?? true;
      if (!isOwner && diskonCents > 0) {
        final limit = await _maxDiscountPercent(txn);
        final percent = bruto == 0 ? 0.0 : diskonCents / bruto * 100;
        if (percent > limit) {
          throw StateError(
            'Diskon ${percent.toStringAsFixed(1)}% melebihi batas $limit%. '
            'Hanya pemilik yang dapat menyetujui diskon ini.',
          );
        }
      }
      if (metodeBayar == 'TRANSFER' && bayarCents > total) {
        throw ArgumentError(
          'Pembayaran transfer tidak boleh melebihi tagihan (tanpa kembalian).',
        );
      }
      final dibayar = total == 0 ? 0 : bayarCents.clamp(0, total).toInt();
      final kembalian = total > 0 && metodeBayar == 'CASH' && bayarCents > total
          ? bayarCents - total
          : 0;
      final sisa = total - dibayar;
      final statusBayar = sisa == 0 ? 'LUNAS' : 'KREDIT';
      final now = nowIso();
      final noNota = await _nextNota(txn);
      final requestedMechanics = <String>[];
      for (final id in mechanicEmployeeSyncIds) {
        final clean = id.trim();
        if (clean.isNotEmpty && !requestedMechanics.contains(clean)) {
          requestedMechanics.add(clean);
        }
      }
      final mechanicRows = <Map<String, Object?>>[];
      if (requestedMechanics.isNotEmpty) {
        final placeholders = List.filled(requestedMechanics.length, '?').join(',');
        final rows = await txn.query(
          'employee_accounts',
          where: 'sync_id IN ($placeholders) AND aktif = 1',
          whereArgs: requestedMechanics,
        );
        final bySyncId = {
          for (final row in rows) row['sync_id'] as String: row,
        };
        for (final id in requestedMechanics) {
          final row = bySyncId[id];
          if (row != null) mechanicRows.add(row);
        }
      }
      final mechanicNames = mechanicRows
          .map((row) => '${row['nama'] ?? row['username'] ?? ''}')
          .where((name) => name.trim().isNotEmpty)
          .join(', ');
      final warranty = await _warrantyFields(
        txn,
        sparepartOnly: sparepartOnly,
        bergaransi: bergaransi,
        garansiBulan: garansiBulan,
        customDate: garansiSampai,
        catatanGaransi: catatanGaransi,
        barangAktif: garansiBarangAktif,
        barangNilai: garansiBarangNilai,
        barangSatuan: garansiBarangSatuan,
      );
      final recordId = await txn.insert('service_records', {
        'sync_id': newSyncId(),
        'unit_id': unitId,
        'no_nota': noNota,
        'request_id': (requestId ?? '').trim().isEmpty
            ? null
            : requestId!.trim(),
        'waktu_service': now,
        'keluhan_awal': keluhan.trim(),
        'catatan_pengerjaan': _nullable(catatan),
        'biaya_jasa': biayaJasa,
        'total_part': totalPart,
        'diskon': diskonCents,
        'total_servis': total,
        'metode_bayar': metodeBayar,
        'bayar': bayarCents,
        'kembalian': kembalian,
        'status_bayar': statusBayar,
        'jenis_bayar': statusBayar,
        'total_dibayar': dibayar,
        'sisa_bayar': sisa,
        'created_by': actor?.label ?? 'Pemilik',
        'created_by_employee_id': actor?.employeeSyncId,
        'cashier_employee_id': actor?.employeeSyncId,
        'mechanic': _nullable(
          mechanic ?? (mechanicNames.isEmpty ? null : mechanicNames),
        ),
        'mechanic_employee_id': mechanicEmployeeSyncId ??
            (mechanicRows.isEmpty ? null : mechanicRows.first['sync_id']),
        'bergaransi': warranty.bergaransi ? 1 : 0,
        'garansi_bulan': warranty.bulan,
        'garansi_sampai': warranty.sampai,
        'catatan_garansi': warranty.catatan,
        'status_klaim': 'Belum claim',
        'sparepart_only': sparepartOnly ? 1 : 0,
        'garansi_barang_aktif': warranty.barangAktif ? 1 : 0,
        'garansi_barang_nilai': warranty.barangNilai,
        'garansi_barang_satuan': warranty.barangSatuan,
        'garansi_barang_sampai': warranty.barangSampai,
        'unit_ditinggal': unitDitinggal ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      });
      for (final job in jobs) {
        await txn.insert('service_jobs', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'harga_jasa_id': job.jasaId,
          'deskripsi': job.deskripsi.trim(),
          'jumlah': job.jumlah,
          'harga': job.hargaCents,
          'subtotal': job.subtotalCents,
          'interval_servis_bulan': job.intervalBulan < 0 ? 0 : job.intervalBulan,
        });
      }
      for (final part in parts) {
        await txn.insert('service_parts', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'stock_item_id': part.stockItemId,
          'nama_part': part.nama,
          'jumlah': part.jumlah,
          'harga_satuan': part.hargaCents,
          'subtotal': part.subtotalCents,
          'harga_modal': part.modalCents,
          'interval_servis_bulan':
              part.intervalBulan < 0 ? 0 : part.intervalBulan,
        });
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [part.stockItemId],
          limit: 1,
        );
        final before = StockItem.fromRow(stockRows.first);
        final nextMilli = before.jumlahMilli - part.jumlah * 1000;
        await txn.update(
          'stock_items',
          {'jumlah': nextMilli ~/ 1000, 'jumlah_milli': nextMilli},
          where: 'id = ?',
          whereArgs: [part.stockItemId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': part.stockItemId,
          'nama_item': part.nama,
          'jenis': 'KELUAR',
          'jumlah': -part.jumlah,
          'jumlah_milli': -part.jumlah * 1000,
          'alasan': 'Penjualan $noNota',
          'service_record_id': recordId,
          'created_at': now,
        });
      }
      if (dibayar > 0) {
        await txn.insert('service_payments', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'jenis': 'PELUNASAN',
          'metode': metodeBayar,
          'nominal': dibayar,
          'waktu': now,
          'operator': actor?.label ?? 'Pemilik',
          'request_id': '${requestId ?? noNota}-bayar',
          'catatan': null,
        });
      }
      if (diskonCents > 0) {
        final percent = bruto == 0 ? 0.0 : diskonCents / bruto * 100;
        await txn.insert('permission_audits', {
          'actor': actor?.label ?? 'Pemilik',
          'target_account_id': actor?.employeeId,
          'action': 'diskon',
          'detail_json': jsonEncode({
            'no_nota': noNota,
            'diskon': diskonCents,
            'persen': percent,
            'disetujui_pemilik': isOwner,
          }),
          'created_at': now,
        });
      }
      if (mechanicRows.isNotEmpty) {
        await _insertMechanicsAndCommissions(
          txn,
          recordId,
          mechanicRows,
          biayaJasa: biayaJasa,
          jobs: jobs,
          parts: parts,
        );
      }
      if (enqueue != null) await enqueue(txn, recordId);
      return recordId;
    });
  }

  Future<void> _insertMechanicsAndCommissions(
    DatabaseExecutor txn,
    int recordId,
    List<Map<String, Object?>> mechanics, {
    required int biayaJasa,
    required List<JobDraft> jobs,
    required List<PartDraft> parts,
  }) async {
    final margin = parts.fold<int>(
      0,
      (sum, part) => sum + (part.hargaCents - part.modalCents) * part.jumlah,
    );
    final count = mechanics.length;
    var index = 0;
    for (final mechanic in mechanics) {
      final syncId = '${mechanic['sync_id']}';
      await txn.insert('service_record_mechanics', {
        'sync_id': newSyncId(),
        'service_record_id': recordId,
        'employee_sync_id': syncId,
        'urutan': index,
      });
      final mode = '${mechanic['komisi_mode'] ?? 'PERSEN'}';
      final barangNilai = (mechanic['komisi_barang_nilai'] as num?)?.toInt() ?? 0;
      final jasaNilai = (mechanic['komisi_jasa_nilai'] as num?)?.toInt() ?? 0;
      final shareJasa = _splitShare(biayaJasa, index, count);
      final shareMargin = _splitShare(margin, index, count);
      final nominal = mode == 'NOMINAL'
          ? (parts.isNotEmpty ? barangNilai : 0) +
              (jobs.isNotEmpty ? jasaNilai : 0)
          : (shareJasa * jasaNilai) ~/ 100 + (shareMargin * barangNilai) ~/ 100;
      if (nominal > 0) {
        await txn.insert('service_record_commissions', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'employee_sync_id': syncId,
          'nominal': nominal,
        });
      }
      index++;
    }
  }

  static int _splitShare(int total, int index, int count) {
    if (count <= 0) return 0;
    return total ~/ count + (index < total % count ? 1 : 0);
  }

  Future<double> _maxDiscountPercent([DatabaseExecutor? executor]) async {
    final db = executor ?? this.db;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['diskon.maks_persen'],
      limit: 1,
    );
    final raw = rows.isEmpty ? null : rows.first['value'] as String?;
    return double.tryParse(raw ?? '') ?? 10;
  }

  /// Nomor nota selalu bilangan bulat 1, 2, 3, ... tanpa awalan perangkat.
  /// Nilai diambil dari counter dan dari nomor numerik tertinggi yang sudah
  /// ada, sehingga snapshot/restore atau nota masuk dari perangkat lain tidak
  /// pernah memakai nomor yang sudah dipakai.
  Future<String> allocateNextNota(DatabaseExecutor executor) async {
    await _seedNumericNotaCounter(executor);
    final rows = await executor.query(
      'nota_counters',
      columns: ['terakhir'],
      where: 'tanggal = ?',
      whereArgs: [_numericNotaKey],
      limit: 1,
    );
    final next = ((rows.first['terakhir'] as int?) ?? 0) + 1;
    await executor.update(
      'nota_counters',
      {'terakhir': next},
      where: 'tanggal = ?',
      whereArgs: [_numericNotaKey],
    );
    return '$next';
  }

  static const _numericNotaKey = 'NUMERIC';

  Future<String> _nextNota(Transaction txn) => allocateNextNota(txn);

  Future<({
    bool bergaransi,
    int bulan,
    String? sampai,
    String? catatan,
    bool barangAktif,
    int barangNilai,
    String barangSatuan,
    String? barangSampai,
  })> _warrantyFields(
    DatabaseExecutor executor, {
    required bool sparepartOnly,
    required bool bergaransi,
    required int garansiBulan,
    required DateTime? customDate,
    required String? catatanGaransi,
    required bool barangAktif,
    required int barangNilai,
    required String barangSatuan,
  }) async {
    final todayRaw = DateTime.now();
    final today = DateTime(todayRaw.year, todayRaw.month, todayRaw.day);
    final settingRows = await executor.query(
      'app_settings',
      columns: ['key', 'value'],
      where: "key IN ('garansi.default_bulan', 'garansi.syarat')",
    );
    final settings = {
      for (final row in settingRows)
        row['key'] as String: row['value'] as String? ?? '',
    };
    final defaultBulan =
        int.tryParse(settings['garansi.default_bulan'] ?? '') ?? 1;

    if (sparepartOnly) {
      final satuan = barangSatuan.trim().toUpperCase() == 'BULAN'
          ? 'BULAN'
          : 'HARI';
      final nilai = barangAktif ? (barangNilai < 1 ? 1 : barangNilai) : 0;
      DateTime? end;
      if (barangAktif) {
        end = satuan == 'BULAN'
            ? today.add(Duration(days: 30 * nilai))
            : today.add(Duration(days: nilai));
      }
      return (
        bergaransi: barangAktif,
        bulan: satuan == 'BULAN' ? nilai : 0,
        sampai: end == null ? null : dateOnly.format(end),
        catatan: barangAktif
            ? _warrantyNote(catatanGaransi, settings['garansi.syarat'])
            : null,
        barangAktif: barangAktif,
        barangNilai: nilai,
        barangSatuan: satuan,
        barangSampai: end == null ? null : dateOnly.format(end),
      );
    }

    final bulan = garansiBulan > 0 ? garansiBulan : defaultBulan;
    DateTime? end;
    if (bergaransi) {
      end = customDate ?? today.add(Duration(days: 30 * bulan));
      final endDay = DateTime(end.year, end.month, end.day);
      if (endDay.isBefore(today)) {
        throw ArgumentError('Tanggal akhir garansi tidak boleh di masa lalu.');
      }
    }
    return (
      bergaransi: bergaransi,
      bulan: bulan,
      sampai: end == null ? null : dateOnly.format(end),
      catatan: bergaransi
          ? _warrantyNote(catatanGaransi, settings['garansi.syarat'])
          : null,
      barangAktif: false,
      barangNilai: 0,
      barangSatuan: 'HARI',
      barangSampai: null,
    );
  }

  String? _warrantyNote(String? custom, String? standard) {
    final text = (custom ?? '').trim();
    if (text.isNotEmpty) return text;
    final fallback = (standard ?? '').trim();
    return fallback.isEmpty ? null : fallback;
  }

  /// Klaim garansi hanya sekali; update bersyarat menjaga dua klaim paralel.
  Future<void> claimWarranty(
    int recordId, {
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Nota servis tidak ditemukan.');
      final row = rows.first;
      if ((row['status'] as String? ?? 'AKTIF') == 'VOID') {
        throw StateError(
          'Nota sudah dibatalkan (VOID); garansi tidak dapat diklaim.',
        );
      }
      if ((row['bergaransi'] as int? ?? 0) != 1 ||
          row['garansi_sampai'] == null) {
        throw StateError('Transaksi ini tidak memiliki garansi servis.');
      }
      if (row['status_klaim'] == 'Sudah claim') {
        throw StateError('Garansi untuk nota ini sudah pernah diklaim.');
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final end = DateTime.parse(row['garansi_sampai'] as String);
      final endDay = DateTime(end.year, end.month, end.day);
      if (today.isAfter(endDay)) {
        throw StateError(
          'Masa garansi telah habis pada ${dateOnly.format(endDay)}.',
        );
      }
      final updated = await txn.rawUpdate(
        "UPDATE service_records SET status_klaim = 'Sudah claim', "
        'tanggal_klaim = ?, updated_at = ? WHERE id = ? '
        "AND (status_klaim IS NULL OR status_klaim <> 'Sudah claim') "
        "AND status <> 'VOID'",
        [dateOnly.format(today), nowIso(), recordId],
      );
      if (updated == 0) {
        throw StateError('Garansi untuk nota ini sudah pernah diklaim.');
      }
      await txn.insert('permission_audits', {
        'actor': actor?.label ?? 'Pemilik',
        'target_account_id': actor?.employeeId,
        'action': 'klaim garansi',
        'detail_json': jsonEncode({
          'record_id': recordId,
          'tanggal': dateOnly.format(today),
        }),
        'created_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, recordId);
    });
  }

  Future<void> markUnitTaken(
    int recordId, {
    required bool diambil,
    Operator? actor,
  }) async {
    final updated = await db.update(
      'service_records',
      {
        'diambil_at': diambil ? nowIso() : null,
        'updated_at': nowIso(),
      },
      where: 'unit_ditinggal = 1 AND id = ?',
      whereArgs: [recordId],
    );
    if (updated == 0) {
      throw StateError('Nota ini tidak ditandai unit ditinggal.');
    }
  }

  Future<List<ServiceRecordSummary>> listRecords({
    DateTime? from,
    DateTime? to,
    String query = '',
    int limit = 100,
    int offset = 0,
    bool onlyReceivable = false,
  }) async {
    final start = from ?? DateTime(2000);
    final end = to ?? DateTime(2100);
    final term = query.trim();
    final escaped = escapeLike(term);
    final where = StringBuffer('r.waktu_service BETWEEN ? AND ?');
    final args = <Object?>[isoStartOfDay(start), isoEndOfDay(end)];
    if (term.isNotEmpty) {
      where.write(
        " AND (r.no_nota LIKE ? ESCAPE '\\' OR c.nama LIKE ? ESCAPE '\\')",
      );
      args.addAll(['%$escaped%', '%$escaped%']);
    }
    if (onlyReceivable) {
      where.write(" AND r.sisa_bayar > 0 AND r.status != 'VOID'");
    }
    args.addAll([limit, offset]);
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.nama AS customer_nama,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE $where
      ORDER BY r.waktu_service DESC
      LIMIT ? OFFSET ?
      ''',
      args,
    );
    return rows.map(ServiceRecordSummary.fromRow).toList();
  }

  Future<RecordDetail?> recordDetail(int id) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.nama AS customer_nama,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE r.id = ?
      LIMIT 1
      ''',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final jobRows = await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final partRows = await db.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final paymentRows = await db.query(
      'service_payments',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'waktu',
    );
    final commissionRows = await db.rawQuery(
      '''
      SELECT c.*, COALESCE(e.nama, c.employee_sync_id) AS nama
      FROM service_record_commissions c
      LEFT JOIN employee_accounts e ON e.sync_id = c.employee_sync_id
      WHERE c.service_record_id = ?
      ORDER BY c.id
      ''',
      [id],
    );
    return RecordDetail(
      record: ServiceRecordSummary.fromRow(row),
      jobs: jobRows
          .map(
            (item) => JobDraft(
              deskripsi: item['deskripsi'] as String,
              jumlah: item['jumlah'] as int,
              hargaCents: item['harga'] as int,
            ),
          )
          .toList(),
      parts: partRows
          .map(
            (item) => PartDraft(
              stockItemId: item['stock_item_id'] as int? ?? 0,
              nama: item['nama_part'] as String,
              jumlah: item['jumlah'] as int,
              hargaCents: item['harga_satuan'] as int,
              modalCents: item['harga_modal'] as int? ?? 0,
            ),
          )
          .toList(),
      payments: paymentRows
          .map(
            (item) => PaymentRow(
              id: item['id'] as int,
              jenis: item['jenis'] as String,
              metode: item['metode'] as String,
              nominalCents: item['nominal'] as int,
              waktu: localTime(item['waktu']),
              catatan: item['catatan'] as String?,
            ),
          )
          .toList(),
      requestId: row['request_id'] as String?,
      catatan: row['catatan_pengerjaan'] as String?,
      jenisBayar: row['jenis_bayar'] as String? ?? 'LUNAS',
      totalDibayarCents: row['total_dibayar'] as int? ?? 0,
      sisaCents: row['sisa_bayar'] as int? ?? 0,
      voidReason: row['void_reason'] as String?,
      createdBy: row['created_by'] as String?,
      mechanic: row['mechanic'] as String?,
      commissions: commissionRows
          .map(
            (item) => CommissionRow(
              employeeSyncId: item['employee_sync_id'] as String,
              nama: item['nama'] as String? ?? '',
              nominalCents: item['nominal'] as int? ?? 0,
              overrideCents: item['nominal_override'] as int?,
            ),
          )
          .toList(),
    );
  }

  Future<void> voidRecord(
    int id,
    String reason, {
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan void wajib diisi.');
    }
    if (actor != null) Permissions.require(actor, permissionVoid);
    await db.transaction((txn) async {
      final rows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Nota tidak ditemukan.');
      if (rows.first['voided_at'] != null) return;
      final parts = await txn.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [id],
      );
      final now = nowIso();
      for (final part in parts) {
        final stockId = part['stock_item_id'] as int?;
        if (stockId == null) continue;
        final qtyMilli = (part['jumlah'] as int) * 1000;
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [stockId],
          limit: 1,
        );
        if (stockRows.isEmpty) continue;
        final stock = StockItem.fromRow(stockRows.first);
        final nextMilli = stock.jumlahMilli + qtyMilli;
        await txn.update(
          'stock_items',
          {'jumlah': nextMilli ~/ 1000, 'jumlah_milli': nextMilli},
          where: 'id = ?',
          whereArgs: [stockId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': stockId,
          'nama_item': part['nama_part'],
          'jenis': 'MASUK',
          'jumlah': part['jumlah'],
          'jumlah_milli': qtyMilli,
          'alasan': 'Void nota ${rows.first['no_nota']}',
          'service_record_id': id,
          'created_at': now,
        });
      }
      final payments = await txn.rawQuery(
        'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
        'WHERE service_record_id = ? AND jenis = ? AND nominal > 0',
        [id, 'PELUNASAN'],
      );
      final paid = (payments.first['total'] as int?) ?? 0;
      if (paid > 0) {
        final refunded = await txn.query(
          'service_payments',
          where: 'service_record_id = ? AND jenis = ?',
          whereArgs: [id, 'REFUND'],
          limit: 1,
        );
        if (refunded.isEmpty) {
          await txn.insert('service_payments', {
            'sync_id': newSyncId(),
            'service_record_id': id,
            'jenis': 'REFUND',
            'metode': rows.first['metode_bayar'] ?? 'CASH',
            'nominal': -paid,
            'waktu': now,
            'operator': actor?.label ?? 'Pemilik',
            'request_id': 'void-${rows.first['sync_id']}',
            'catatan': cleanReason,
          });
        }
      }
      await txn.update(
        'service_records',
        {
          'status': 'VOID',
          'voided_at': now,
          'void_reason': cleanReason,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.insert('permission_audits', {
        'actor': actor?.label ?? 'Pemilik',
        'target_account_id': actor?.employeeId,
        'action': 'void',
        'detail_json': jsonEncode({
          'no_nota': rows.first['no_nota'],
          'alasan': cleanReason,
        }),
        'created_at': now,
      });
      if (enqueue != null) await enqueue(txn, id);
    });
  }

  Future<Map<String, Object?>> settleReceivable({
    required int recordId,
    required int nominalCents,
    required String metode,
    required Operator? actor,
    String? requestId,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    if (actor != null && !actor.canWriteMoney) {
      throw StateError('Peran ini tidak boleh menerima pembayaran.');
    }
    if (nominalCents <= 0) {
      throw ArgumentError('Nominal pelunasan harus lebih dari nol.');
    }
    if (metode != 'CASH' && metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak dikenal.');
    }
    return db.transaction((txn) async {
      final rows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Nota tidak ditemukan.');
      final record = rows.first;
      if (record['voided_at'] != null) {
        throw StateError('Nota sudah di-void.');
      }
      final sisa = record['sisa_bayar'] as int? ?? 0;
      if (sisa <= 0) throw StateError('Nota ini tidak memiliki sisa piutang.');
      if (nominalCents > sisa) {
        throw ArgumentError('Nominal pelunasan melebihi sisa piutang.');
      }
      final now = nowIso();
      final paymentSyncId = newSyncId();
      final newSisa = sisa - nominalCents;
      final newDibayar = (record['total_dibayar'] as int? ?? 0) + nominalCents;
      await txn.insert('service_payments', {
        'sync_id': paymentSyncId,
        'service_record_id': recordId,
        'jenis': 'PELUNASAN',
        'metode': metode,
        'nominal': nominalCents,
        'waktu': now,
        'operator': actor?.label ?? 'Pemilik',
        'request_id': (requestId ?? '').trim().isEmpty
            ? newSyncId()
            : requestId!.trim(),
        'catatan': 'Pelunasan piutang',
      });
      await txn.update(
        'service_records',
        {
          'total_dibayar': newDibayar,
          'sisa_bayar': newSisa,
          'status_bayar': newSisa == 0 ? 'LUNAS' : 'KREDIT',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [recordId],
      );
      if (enqueue != null) await enqueue(txn, recordId);
      return {
        'payment_sync_id': paymentSyncId,
        'sisa_bayar': newSisa,
        'status_bayar': newSisa == 0 ? 'LUNAS' : 'KREDIT',
        'total_dibayar': newDibayar,
      };
    });
  }

  Future<ReportSummary> reportSummary(DateTime from, DateTime to) async {
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS transaksi,
        COALESCE(SUM(biaya_jasa), 0) AS total_jasa,
        COALESCE(SUM(total_part), 0) AS total_part,
        COALESCE(SUM(diskon), 0) AS diskon,
        COALESCE(SUM(total_servis), 0) AS total,
        COALESCE(SUM(total_dibayar), 0) AS dibayar,
        COALESCE(SUM(sisa_bayar), 0) AS piutang
      FROM service_records
      WHERE waktu_service BETWEEN ? AND ? AND status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final row = rows.first;
    final parts = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(sp.subtotal), 0) AS omzet,
        COALESCE(SUM(sp.harga_modal * sp.jumlah), 0) AS modal
      FROM service_parts sp
      JOIN service_records r ON r.id = sp.service_record_id
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final cashRows = await db.rawQuery(
      '''
      SELECT metode, COALESCE(SUM(nominal), 0) AS total
      FROM service_payments
      WHERE waktu BETWEEN ? AND ?
      GROUP BY metode
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final commissionRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(COALESCE(c.nominal_override, c.nominal)), 0) AS total
      FROM service_record_commissions c
      JOIN service_records r ON r.id = c.service_record_id
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final salaryRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(nominal - potongan_hutang), 0) AS total
      FROM salary_payments
      WHERE tanggal BETWEEN ? AND ?
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final omzetPart = parts.first['omzet'] as int? ?? 0;
    final modalPart = parts.first['modal'] as int? ?? 0;
    return ReportSummary(
      transaksi: row['transaksi'] as int? ?? 0,
      totalJasaCents: row['total_jasa'] as int? ?? 0,
      totalPartCents: row['total_part'] as int? ?? 0,
      diskonCents: row['diskon'] as int? ?? 0,
      totalCents: row['total'] as int? ?? 0,
      dibayarCents: row['dibayar'] as int? ?? 0,
      piutangCents: row['piutang'] as int? ?? 0,
      totalModalPartCents: modalPart,
      labaKotorPartCents: omzetPart - modalPart,
      komisiCents: commissionRows.first['total'] as int? ?? 0,
      gajiCents: salaryRows.first['total'] as int? ?? 0,
      cashByMethod: {
        for (final cash in cashRows)
          (cash['metode'] as String? ?? 'CASH'): cash['total'] as int? ?? 0,
      },
    );
  }

  Future<DashboardData> dashboard() async {
    final today = DateTime.now();
    final summary = await reportSummary(today, today);
    final lowRows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM stock_items '
      'WHERE COALESCE(jumlah_milli, jumlah * 1000) <= stok_minimum * 1000',
    );
    final receivableRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(sisa_bayar), 0) AS total
      FROM service_records
      WHERE status != 'VOID' AND sisa_bayar > 0
      ''',
    );
    final negativeRows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM stock_items '
      'WHERE COALESCE(jumlah_milli, jumlah * 1000) < 0',
    );
    final conflictRows = await db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_conflicts "
      "WHERE reason = 'stok_negatif' AND resolved_at IS NULL",
    );
    return DashboardData(
      todayRecords: await listRecords(from: today, to: today, limit: 200),
      todayRevenueCents: summary.totalCents,
      todayCount: summary.transaksi,
      lowStockCount: lowRows.first['total'] as int? ?? 0,
      receivableCents: receivableRows.first['total'] as int? ?? 0,
      recent: await listRecords(limit: 8),
      negativeStockCount:
          (negativeRows.first['total'] as int? ?? 0) +
          (conflictRows.first['total'] as int? ?? 0),
    );
  }

  static String? _nullable(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }
}

class DuplicateCustomerException implements Exception {
  DuplicateCustomerException({
    required this.existingId,
    required this.existingName,
  });

  final int existingId;
  final String existingName;

  @override
  String toString() =>
      'Pelanggan dengan nomor ini sudah ada: $existingName. '
      'Gunakan pelanggan yang ada untuk menghindari duplikat.';
}
