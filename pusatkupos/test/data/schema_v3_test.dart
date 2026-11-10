import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/data/app_database.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureTestDatabaseFactory();

  test('skema bersih v1 tidak menyimpan kuantitas atau keanggotaan ganda',
      () async {
    final db = await openTestDatabase();
    addTearDown(db.close);

    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(AppDatabase.schemaVersion, 1);
    expect(await _hasTable(db, 'app_meta'), isTrue);
    expect(await _hasTable(db, 'licenses'), isTrue);
    expect(await _hasTable(db, 'app_settings'), isFalse);
    expect(await _hasTable(db, 'license'), isFalse);
    expect(await _hasTable(db, 'sync_peer_digests'), isFalse);

    final stockColumns = await _columns(db, 'stock_items');
    expect(stockColumns, isNot(contains('jumlah')));
    expect(stockColumns, contains('jumlah_milli'));
    final stockInfo = await db.rawQuery('PRAGMA table_info(stock_items)');
    final milli = stockInfo.firstWhere((row) => row['name'] == 'jumlah_milli');
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
  });

  test('createDatabaseAt membuat database v1 dengan pengaturan dan FK',
      () async {
    // Flutter test default ke Android; paksa jalur SQLite polos di desktop.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final dir = await Directory.systemTemp.createTemp('pusatku-schema-v1');
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
  });
}
