import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/schema.dart';

bool _initialized = false;

/// Menyiapkan factory SQLite FFI untuk pengujian di VM/desktop.
///
/// Dipanggil sekali per isolate test dan tidak pernah menyentuh database
/// pengguna.
void ensureTestDatabaseFactory() {
  if (_initialized) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _initialized = true;
}

OpenDatabaseOptions _testOpenOptions() {
  return OpenDatabaseOptions(
    version: AppDatabase.schemaVersion,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, version) => createCleanSchema(db),
  );
}

/// Membuka database in-memory dengan skema aplikasi yang sama.
Future<Database> openTestDatabase({String storeId = 'utama'}) {
  return openTestDatabaseAt(inMemoryDatabasePath, storeId: storeId);
}

/// Membuka database uji berbasis berkas (untuk skenario backup/restore).
Future<Database> openTestDatabaseAt(
  String path, {
  String storeId = 'utama',
}) async {
  ensureTestDatabaseFactory();
  final db = await databaseFactory.openDatabase(
    path,
    options: _testOpenOptions(),
  );
  try {
    await db.insert(
      'app_meta',
      {'key': 'sync.store_id', 'value': storeId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return db;
  } catch (_) {
    await db.close();
    rethrow;
  }
}
