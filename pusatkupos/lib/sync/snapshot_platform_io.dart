import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<Uint8List> exportSnapshotBytes(
  Database db, {
  required List<String> dropTables,
  required String settingsWhere,
  List<String> sanitize = const [],
}) async {
  final dir = await Directory.systemTemp.createTemp('pusatkupos_snapshot_');
  final target = p.join(dir.path, 'snapshot.db');
  try {
    await db.execute('VACUUM INTO ?', [target]);
    final copy = await databaseFactory.openDatabase(target);
    try {
      for (final table in dropTables) {
        await copy.execute('DROP TABLE IF EXISTS "$table"');
      }
      for (final statement in sanitize) {
        await copy.execute(statement);
      }
      await copy.delete('app_settings', where: settingsWhere);
    } finally {
      await copy.close();
    }
    return await File(target).readAsBytes();
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<Map<String, int>> importSnapshotBytes(
  Uint8List bytes,
  Database target, {
  required List<String> tables,
  required List<String> deleteOrder,
  Future<void> Function(Transaction txn)? afterImport,
}) async {
  final dir = await Directory.systemTemp.createTemp('pusatkupos_snapshot_');
  final path = p.join(dir.path, 'snapshot.db');
  await File(path).writeAsBytes(bytes, flush: true);
  final source = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    return await target.transaction((txn) async {
      for (final table in deleteOrder) {
        await txn.delete(table);
      }
      final counts = <String, int>{};
      for (final table in tables) {
        final rows = await source.query(table);
        for (final row in rows) {
          await txn.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        counts[table] = rows.length;
      }
      final settings = await source.query('app_settings');
      for (final row in settings) {
        final key = row['key'] as String? ?? '';
        if (isLocalSetting(key)) continue;
        await txn.insert(
          'app_settings',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await afterImport?.call(txn);
      return counts;
    });
  } finally {
    await source.close();
    await dir.delete(recursive: true);
  }
}

bool isLocalSetting(String key) {
  return key == 'app.created_at' ||
      key == 'app.role' ||
      key.startsWith('employee.') ||
      key.startsWith('sync.') ||
      key.startsWith('device.') ||
      key.startsWith('auth.') ||
      key.startsWith('license.') ||
      key.startsWith('backup.') ||
      key.startsWith('telegram.') ||
      key.startsWith('secure.');
}
