import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/dates.dart';

class StoreRecord {
  const StoreRecord({
    required this.storeId,
    required this.databaseId,
    required this.nama,
    required this.databasePath,
    this.alamat = '',
    this.createdAt = '',
  });

  final String storeId;
  final String databaseId;
  final String nama;
  final String alamat;
  final String databasePath;
  final String createdAt;
}

class StoreRegistry {
  StoreRegistry._();

  static final StoreRegistry instance = StoreRegistry._();

  Database? _db;
  String? _root;

  bool get isOpen => _db != null;

  Future<void> open(String rootPath) async {
    if (_db != null) {
      if (_root == rootPath) return;
      await close();
    }
    _root = rootPath;
    _db = await databaseFactory.openDatabase(
      p.join(rootPath, 'registry.db'),
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE stores (
              store_id TEXT PRIMARY KEY,
              database_id TEXT NOT NULL UNIQUE,
              nama TEXT NOT NULL,
              alamat TEXT,
              database_path TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE registry_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
      ),
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _root = null;
  }

  Database get _database {
    final value = _db;
    if (value == null) {
      throw StateError('Registry toko belum dibuka.');
    }
    return value;
  }

  String get rootPath {
    final value = _root;
    if (value == null) {
      throw StateError('Registry toko belum dibuka.');
    }
    return value;
  }

  String newDatabasePath(String databaseId) =>
      p.join(rootPath, 'stores', '$databaseId.db');

  Future<List<StoreRecord>> stores() async {
    final rows = await _database.query(
      'stores',
      orderBy: 'created_at, store_id',
    );
    return rows.map(_map).toList();
  }

  Future<StoreRecord?> byId(String storeId) async {
    final rows = await _database.query(
      'stores',
      where: 'store_id = ?',
      whereArgs: [storeId],
      limit: 1,
    );
    return rows.isEmpty ? null : _map(rows.first);
  }

  Future<StoreRecord?> byName(String nama) async {
    final rows = await _database.query(
      'stores',
      where: 'nama COLLATE NOCASE = ?',
      whereArgs: [nama.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : _map(rows.first);
  }

  Future<StoreRecord> ensureDefault(
    String databasePath, {
    String nama = 'Toko utama',
    String alamat = '',
  }) async {
    final existing = await byId('utama');
    if (existing != null) return existing;
    final createdAt = nowIso();
    await _database.insert('stores', {
      'store_id': 'utama',
      'database_id': 'utama',
      'nama': nama,
      'alamat': alamat,
      'database_path': databasePath,
      'created_at': createdAt,
    });
    final active = await activeId();
    if (active == null) await setActive('utama');
    return StoreRecord(
      storeId: 'utama',
      databaseId: 'utama',
      nama: nama,
      alamat: alamat,
      databasePath: databasePath,
      createdAt: createdAt,
    );
  }

  Future<void> insert(StoreRecord store) async {
    await _database.insert('stores', {
      'store_id': store.storeId,
      'database_id': store.databaseId,
      'nama': store.nama,
      'alamat': store.alamat,
      'database_path': store.databasePath,
      'created_at':
          store.createdAt.isEmpty ? nowIso() : store.createdAt,
    });
  }

  Future<void> updateName(
    String storeId, {
    required String nama,
    required String alamat,
  }) async {
    await _database.update(
      'stores',
      {'nama': nama, 'alamat': alamat},
      where: 'store_id = ?',
      whereArgs: [storeId],
    );
  }

  Future<String?> activeId() async {
    final rows = await _database.query(
      'registry_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['active_store_id'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setActive(String storeId) async {
    await _database.insert(
      'registry_meta',
      {'key': 'active_store_id', 'value': storeId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  StoreRecord _map(Map<String, Object?> row) {
    return StoreRecord(
      storeId: row['store_id'] as String,
      databaseId: row['database_id'] as String,
      nama: row['nama'] as String? ?? '',
      alamat: row['alamat'] as String? ?? '',
      databasePath: row['database_path'] as String,
      createdAt: row['created_at'] as String? ?? '',
    );
  }
}
