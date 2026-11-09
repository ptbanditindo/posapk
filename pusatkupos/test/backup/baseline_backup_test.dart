import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

void main() {
  test('database kosong dapat dibackup, dibuka, dan direstore', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_baseline_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final sourcePath = '${dir.path}/sumber.db';
    final backupPath = '${dir.path}/backup.db';
    final restoredPath = '${dir.path}/restore.db';

    final source = await openTestDatabaseAt(sourcePath);
    await source.insert('customers', {
      'sync_id': 'uji-customer',
      'store_id': 'utama',
      'device_id': '',
      'nama': 'Uji',
      'nama_normalized': 'uji',
      'nomor_hp': '0800000000',
      'nomor_hp_normalized': '0800000000',
      'created_at': '2026-11-09T00:00:00',
      'updated_at': '2026-11-09T00:00:00',
    });
    await source.rawQuery('PRAGMA wal_checkpoint(FULL)');
    await source.close();

    await File(sourcePath).copy(backupPath);

    final backup = await databaseFactory.openDatabase(
      backupPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final integrity = await backup.rawQuery('PRAGMA integrity_check');
    expect('${integrity.first.values.first}', 'ok');
    final tables = await backup.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('customers', 'cash_ledger')",
    );
    expect(tables, hasLength(2));
    await backup.close();

    await File(backupPath).copy(restoredPath);
    final restored = await openTestDatabaseAt(restoredPath);
    expect(await restored.query('customers'), hasLength(1));
    final setting = await restored.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['sync.store_id'],
    );
    expect(setting.first['value'], 'utama');
    await restored.close();
  });
}
