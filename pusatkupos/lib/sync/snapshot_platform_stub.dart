import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

Future<Uint8List> exportSnapshotBytes(
  Database db, {
  required List<String> dropTables,
  required String settingsWhere,
  List<String> sanitize = const [],
}) {
  throw UnsupportedError('Snapshot hanya tersedia di aplikasi native.');
}

Future<Map<String, int>> importSnapshotBytes(
  Uint8List bytes,
  Database target, {
  required List<String> tables,
  required List<String> deleteOrder,
  Future<void> Function(Transaction txn)? afterImport,
}) {
  throw UnsupportedError('Snapshot hanya tersedia di aplikasi native.');
}
