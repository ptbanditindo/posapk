import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/money.dart';
import '../core/phone.dart';
import '../core/quantity.dart';
import '../sync/crypto.dart';
import 'approval_service.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart'
    as backup_platform;
import 'models.dart';
import 'price_rules.dart';
import 'schema.dart';
import 'schema_migrations.dart';
import 'secure_store.dart';
import 'store_settings.dart';
import 'store_registry.dart';

class AppDatabase {
  AppDatabase();

  static final AppDatabase instance = AppDatabase();

  static const int schemaVersion = 1;

  Database? _db;
  String? _path;
  String? _activeStoreId;
  String? _mainPath;
  String? _mainStoreId;
  bool _viewerMode = false;

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

  /// True bila database yang terbuka adalah salinan milik mode ringkasan.
  bool get isViewerDatabase => _viewerMode;

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
    _mainPath = _path;
    _mainStoreId = _activeStoreId;
    await _open();
    await _syncRegistryLabel();
  }

  /// Membuka database terpisah untuk ringkasan laporan milik [ownerId].
  /// Salinan ini tidak bercampur dengan pembukuan lokal perangkat.
  Future<void> openViewerDatabase(String ownerId) async {
    final safe = ownerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) throw ArgumentError('ID owner tidak valid.');
    if (_db == null) await init();
    final path = kIsWeb
        ? 'pusatkupos_viewer_$safe.db'
        : p.join(p.dirname(databasePath), 'viewer_$safe.db');
    if (_viewerMode && _path == path) return;
    _mainPath ??= _path;
    _mainStoreId ??= _activeStoreId;
    await close();
    _path = path;
    _activeStoreId = 'utama';
    _viewerMode = true;
    await _open();
  }

  /// Kembali ke database pembukuan utama setelah sesi ringkasan berakhir.
  Future<void> useMainDatabase() async {
    if (!_viewerMode) return;
    await close();
    _viewerMode = false;
    _path = _mainPath;
    _activeStoreId = _mainStoreId;
    if (_path == null) return;
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
    if (_viewerMode) {
      throw StateError('Mode ringkasan hanya membaca satu salinan toko.');
    }
    if (_activeStoreId == store.storeId && _db != null) return;
    await close();
    _path = store.databasePath;
    _activeStoreId = store.storeId;
    await _open();
  }

  Future<void> createDatabaseAt(
    String path, {
    Map<String, String> settings = const {},
    Map<String, bool> features = const {},
    bool copyOwner = false,
    bool copyLicense = false,
    bool copyAccounts = false,
  }) async {
    Map<String, Object?>? ownerRow;
    Map<String, Object?>? licenseRow;
    List<Map<String, Object?>> accountRows = const [];
    if (copyOwner) {
      final rows = await db.query('owner_identity', limit: 1);
      ownerRow = rows.isEmpty ? null : Map.of(rows.first);
    }
    if (copyLicense) {
      final rows = await db.query('license', limit: 1);
      licenseRow = rows.isEmpty ? null : Map.of(rows.first);
    }
    if (copyAccounts) {
      accountRows = await db.query('employee_accounts');
    }
    final fresh = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onDowngrade: _rejectIncompatibleVersion,
      ),
    );
    try {
      for (final entry in settings.entries) {
        await fresh.insert('app_settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (ownerRow != null) {
        await fresh.insert('owner_identity', ownerRow);
      }
      if (licenseRow != null) {
        await fresh.insert('license', licenseRow);
      }
      final storeId = settings['sync.store_id'] ?? '';
      for (final entry in features.entries) {
        if (storeId.isEmpty) break;
        final now = nowIso();
        await fresh.insert('store_features', {
          'store_id': storeId,
          'feature_key': entry.key,
          'sync_id': newSyncId(),
          'device_id': '',
          'enabled': entry.value ? 1 : 0,
          'version': 1,
          'updated_by': 'pemilik',
          'sync_hlc_wall': DateTime.now().millisecondsSinceEpoch,
          'sync_hlc_counter': 0,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final row in accountRows) {
        final now = nowIso();
        final account = Map<String, Object?>.of(row)
          ..remove('id')
          ..['password_hash'] = ''
          ..['password_salt'] = ''
          ..['pin_hash'] = null
          ..['pin_salt'] = null
          ..['updated_at'] = now;
        await fresh.insert(
          'employee_accounts',
          account,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (storeId.isNotEmpty) {
          await fresh.insert('employee_store_access', {
            'sync_id': newSyncId(),
            'store_id': storeId,
            'employee_sync_id': account['sync_id'],
            'role_base': account['role_base'] ?? 'KASIR',
            'extra_permissions_json':
                account['extra_permissions_json'] ?? '[]',
            'permissions_explicit': account['permissions_explicit'] ?? 0,
            'aktif': account['aktif'] ?? 1,
            'version': account['permission_version'] ?? 1,
            'created_at': now,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    } finally {
      await fresh.close();
    }
  }

  /// SQLCipher hanya tersedia untuk Android, iOS, dan macOS. Windows, Linux,
  /// dan web tetap memakai SQLite biasa karena paket tidak mendukung
  /// enkripsi di sana; batas ini dilaporkan ke pengguna lewat [encryptionNote].
  bool get _usesSqlCipher =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get databaseEncrypted => _usesSqlCipher;

  String get encryptionNote => _usesSqlCipher
      ? 'Database lokal terenkripsi SQLCipher.'
      : 'Database lokal belum terenkripsi di platform ini. Gunakan '
            'perangkat Android/iOS untuk data produksi.';

  static const _databaseKeyName = 'database.encryption_key';

  /// Kunci 256-bit dibuat acak saat pertama kali dan disimpan di SecureStore.
  Future<String?> _databasePassword() async {
    if (!_usesSqlCipher) return null;
    final existing = await SecureStore.instance.read(_databaseKeyName);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final key = base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await SecureStore.instance.write(_databaseKeyName, key);
    return key;
  }

  Future<void> _configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Database dari versi aplikasi yang lebih baru tidak dibuka agar tabel
  /// yang belum dikenal tidak ditimpa oleh kode lama.
  Future<void> _rejectIncompatibleVersion(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    throw StateError(
      'Versi skema $oldVersion tidak didukung. '
      'Aplikasi ini memakai skema bersih v$newVersion.',
    );
  }

  Future<void> _open() async {
    await _prepareSchemaUpgrade();
    if (!kIsWeb) {
      // Pulihkan sisa restore yang terputus sebelum database dibuka.
      try {
        await backup_platform.recoverInterruptedRestore(_path!);
      } catch (_) {
        // Bila pemulihan gagal dan database aktif tidak ada, jangan buka
        // database kosong yang bisa menutupi data lama.
        if (!await backup_platform.fileExists(_path!)) rethrow;
      }
    }
    final password = await _databasePassword();
    if (_usesSqlCipher) {
      _db = await sqlcipher.openDatabase(
        _path!,
        password: password,
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: _createSchema,
        onOpen: createOperationalSchema,
        onUpgrade: _upgradeSchema,
        onDowngrade: _rejectIncompatibleVersion,
      );
      await _recordSchemaVersion();
      return;
    }
    _db = await databaseFactory.openDatabase(
      _path!,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: _createSchema,
        onOpen: createOperationalSchema,
        onUpgrade: _upgradeSchema,
        onDowngrade: _rejectIncompatibleVersion,
      ),
    );
    await _recordSchemaVersion();
  }

  /// Versi skema terakhir disimpan di berkas penanda di samping database.
  /// Penanda dibaca sebelum database dibuka agar salinan pengaman dapat dibuat
  /// sebelum migrasi berjalan.
  Future<void> _prepareSchemaUpgrade() async {
    if (kIsWeb) return;
    final path = _path;
    if (path == null) return;
    final marker = '$path.schema_version';
    int? stored;
    try {
      if (await backup_platform.fileExists(marker)) {
        final bytes = await backup_platform.readFile(marker);
        stored = int.tryParse(utf8.decode(bytes).trim());
      }
    } catch (_) {
      stored = null;
    }
    if (stored != null && stored > schemaVersion) {
      throw StateError(
        'Database dibuat oleh aplikasi versi lebih baru (skema v$stored). '
        'Perbarui aplikasi sebelum membuka data ini.',
      );
    }
    if (stored != null &&
        stored < schemaVersion &&
        await backup_platform.fileExists(path)) {
      await backup_platform.backupExistingDatabase(path);
    }
  }

  Future<void> _recordSchemaVersion() async {
    if (kIsWeb) return;
    final path = _path;
    if (path == null) return;
    await backup_platform.writeDatabase(
      '$path.schema_version',
      utf8.encode('$schemaVersion'),
    );
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    await runSchemaMigrations(db, from: oldVersion, to: newVersion);
    await createOperationalSchema(db);
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

  /// Checkpoint WAL untuk database toko yang tidak sedang dibuka, agar
  /// berkas utamanya memuat seluruh transaksi saat disalin untuk backup.
  Future<void> checkpointDatabaseAt(String path) async {
    final handle = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: false),
    );
    try {
      await handle.rawQuery('PRAGMA wal_checkpoint(FULL)');
    } finally {
      await handle.close();
    }
  }

  /// Menulis salinan database aktif sebagai SQLite polos ke [targetPath].
  /// Dipakai backup agar berkas dapat dipulihkan di perangkat lain, bukan
  /// bergantung pada kunci SQLCipher perangkat asal.
  Future<void> exportPortableCopy(String targetPath) async {
    await checkpoint();
    if (!_usesSqlCipher) return;
    final escaped = targetPath.replaceAll("'", "''");
    await db.rawQuery("ATTACH DATABASE '$escaped' AS portable_copy KEY ''");
    try {
      await db.rawQuery("SELECT sqlcipher_export('portable_copy')");
    } finally {
      await db.rawQuery('DETACH DATABASE portable_copy');
    }
  }

  /// Menulis salinan polos database toko lain (tidak sedang terbuka) ke
  /// [targetPath]. Dipakai backup multi-toko di perangkat SQLCipher.
  Future<void> exportPlainDatabaseAt(
    String sourcePath,
    String targetPath,
  ) async {
    final password = await _databasePassword();
    if (password == null) {
      throw StateError('Ekspor database polos hanya untuk SQLCipher.');
    }
    final source = await sqlcipher.openDatabase(sourcePath, password: password);
    try {
      await source.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final escaped = targetPath.replaceAll("'", "''");
      await source.rawQuery(
        "ATTACH DATABASE '$escaped' AS portable_copy KEY ''",
      );
      try {
        await source.rawQuery("SELECT sqlcipher_export('portable_copy')");
      } finally {
        await source.rawQuery('DETACH DATABASE portable_copy');
      }
    } finally {
      await source.close();
    }
  }

  /// Membuat database terenkripsi baru dari salinan SQLite polos.
  Future<void> createEncryptedCopy(String plainPath, String targetPath) async {
    final password = await _databasePassword();
    if (password == null) {
      throw StateError('Kunci database tidak tersedia.');
    }
    final target = await sqlcipher.openDatabase(targetPath, password: password);
    try {
      final escaped = plainPath.replaceAll("'", "''");
      await target.rawQuery("ATTACH DATABASE '$escaped' AS plain_copy KEY ''");
      try {
        await target.rawQuery("SELECT sqlcipher_export('main', 'plain_copy')");
      } finally {
        await target.rawQuery('DETACH DATABASE plain_copy');
      }
      await target.execute('PRAGMA user_version = $schemaVersion');
    } finally {
      await target.close();
    }
  }

  /// Memeriksa integritas berkas terenkripsi memakai kunci perangkat ini.
  Future<void> validateEncryptedCopy(
    String path, {
    List<String> requiredTables = const [],
  }) async {
    final password = await _databasePassword();
    if (password == null) {
      throw StateError('Kunci database tidak tersedia.');
    }
    final probe = await sqlcipher.openDatabase(path, password: password);
    try {
      await _validateProbe(probe, requiredTables);
    } finally {
      await probe.close();
    }
  }

  Future<void> validatePlainCopy(
    String path, {
    List<String> requiredTables = const [],
  }) async {
    if (_usesSqlCipher) {
      throw StateError(
        'Validasi salinan polos tidak tersedia di perangkat '
        'terenkripsi.',
      );
    }
    final probe = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      await _validateProbe(probe, requiredTables);
    } finally {
      await probe.close();
    }
  }

  Future<void> _validateProbe(
    Database probe,
    List<String> requiredTables,
  ) async {
    final integrity = await probe.rawQuery('PRAGMA integrity_check');
    final result = integrity.isEmpty ? '' : '${integrity.first.values.first}';
    if (result.toLowerCase() != 'ok') {
      throw StateError('Integritas database gagal: $result');
    }
    if (requiredTables.isEmpty) return;
    final tableRows = await probe.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tables = tableRows.map((row) => '${row['name']}').toSet();
    for (final required in requiredTables) {
      if (!tables.contains(required)) {
        throw StateError('Tabel wajib "$required" tidak ditemukan.');
      }
    }
  }

  Future<void> _createSchema(Database db, int version) async {
    await createCleanSchema(db);
    final now = nowIso();
    await db.insert('app_settings', {
      'key': 'bengkel.nama',
      'value': 'PUSATKU POS',
    });
    await db.insert('app_settings', {'key': 'bengkel.alamat', 'value': ''});
    await db.insert('app_settings', {'key': 'app.created_at', 'value': now});
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
    await db.insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteSetting(String key) async {
    await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Jam logis berikutnya untuk penulisan lokal. Nilai ini disimpan pada baris
  /// dan amplop agar perangkat lain dapat memakai aturan "HLC terbaru menang".
  static const _hlcTables = [
    'customers',
    'vehicle_or_units',
    'stock_items',
    'harga_jasa',
    'service_records',
    'suppliers',
    'supplier_followups',
    'service_record_commissions',
    'employee_debts',
    'salary_payments',
    'store_features',
    'opname_holds',
    'supplier_purchases',
    'supplier_purchase_items',
    'supplier_payments',
    'supplier_purchase_returns',
    'supplier_purchase_return_items',
    'opening_balances',
    'opening_balance_items',
  ];

  /// HLC baru selalu lebih besar dari antrean keluar, data master yang sudah
  /// tersimpan, dan lantai HLC dari perangkat lain. Dengan begitu penulisan
  /// lokal tidak pernah kalah hanya karena antrean lama sudah dibersihkan.
  Future<Hlc> nextSyncHlc(DatabaseExecutor txn) async {
    final rows = await txn.rawQuery(
      'SELECT COALESCE(MAX(hlc_wall), 0) AS wall, '
      'COALESCE(MAX(hlc_counter), 0) AS counter FROM sync_outbox',
    );
    var wall = (rows.first['wall'] as int?) ?? 0;
    var counter = (rows.first['counter'] as int?) ?? 0;
    for (final table in _hlcTables) {
      final local = await txn.rawQuery(
        'SELECT COALESCE(MAX(sync_hlc_wall), 0) AS wall, '
        'COALESCE(MAX(sync_hlc_counter), 0) AS counter FROM $table',
      );
      final localWall = (local.first['wall'] as int?) ?? 0;
      final localCounter = (local.first['counter'] as int?) ?? 0;
      if (localWall > wall || (localWall == wall && localCounter > counter)) {
        wall = localWall;
        counter = localCounter;
      }
    }
    final floor = await _hlcFloor(txn);
    if (floor.wall > wall || (floor.wall == wall && floor.counter > counter)) {
      wall = floor.wall;
      counter = floor.counter;
    }
    return nextHlc(Hlc(wall, counter));
  }

  /// Menaikkan lantai HLC setelah menerapkan delta dari perangkat lain agar
  /// penulisan lokal berikutnya tidak kalah dibanding data yang baru diterima.
  Future<void> noteRemoteHlc(
    DatabaseExecutor txn,
    int wall,
    int counter,
  ) async {
    if (wall <= 0) return;
    final floor = await _hlcFloor(txn);
    if (wall < floor.wall || (wall == floor.wall && counter <= floor.counter)) {
      return;
    }
    await txn.insert('app_settings', {
      'key': 'sync.hlc_floor',
      'value': '$wall:$counter',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<({int wall, int counter})> _hlcFloor(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync.hlc_floor'],
      limit: 1,
    );
    if (rows.isEmpty) return (wall: 0, counter: 0);
    final parts = '${rows.first['value'] ?? ''}'.split(':');
    if (parts.length != 2) return (wall: 0, counter: 0);
    return (
      wall: int.tryParse(parts[0]) ?? 0,
      counter: int.tryParse(parts[1]) ?? 0,
    );
  }

  Future<List<Customer>> listCustomers({String query = ''}) async {
    final term = query.trim();
    final escaped = escapeLike(term);
    final rows = await db.query(
      'customers',
      where: term.isEmpty
          ? 'deleted_at IS NULL'
          : "deleted_at IS NULL AND (nama LIKE ? ESCAPE '\\' "
                "OR nomor_hp LIKE ? ESCAPE '\\')",
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

  Future<Customer?> customerByPhone(String nomorHp) async {
    final normalized = normalizePhone(nomorHp);
    if (normalized.isEmpty) return null;
    final rows = await db.query('customers', where: 'deleted_at IS NULL');
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
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) {
    return db.transaction((txn) async {
      final normalized = normalizePhone(nomorHp);
      if (normalized.isEmpty) {
        throw ArgumentError('Nomor HP wajib diisi.');
      }
      if (!allowDuplicate) {
        final rows = await txn.query('customers', where: 'deleted_at IS NULL');
        for (final row in rows) {
          if (normalizePhone(row['nomor_hp'] as String? ?? '') == normalized) {
            throw DuplicateCustomerException(
              existingId: row['id'] as int,
              existingName: row['nama'] as String? ?? '',
            );
          }
        }
      }
      final hlc = await nextSyncHlc(txn);
      final id = await txn.insert('customers', {
        'sync_id': newSyncId(),
        'nama': nama.trim(),
        'nama_normalized': _nameKey(nama),
        'nomor_hp': normalized,
        'nomor_hp_normalized': normalizePhone(normalized),
        'alamat': (alamat ?? '').trim().isEmpty ? null : alamat!.trim(),
        'wa_consent': waConsent ? 1 : 0,
        'do_not_contact': doNotContact ? 1 : 0,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, id);
      return id;
    });
  }

  Future<void> updateCustomer({
    required int id,
    required String nama,
    required String nomorHp,
    String? alamat,
    bool waConsent = true,
    bool doNotContact = false,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    final normalized = normalizePhone(nomorHp);
    if (normalized.isEmpty) {
      throw ArgumentError('Nomor HP wajib diisi.');
    }
    await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'deleted_at IS NULL');
      for (final row in rows) {
        if (row['id'] == id) continue;
        if (normalizePhone(row['nomor_hp'] as String? ?? '') == normalized) {
          throw DuplicateCustomerException(
            existingId: row['id'] as int,
            existingName: row['nama'] as String? ?? '',
          );
        }
      }
      final hlc = await nextSyncHlc(txn);
      await txn.update(
        'customers',
        {
          'nama': nama.trim(),
          'nama_normalized': _nameKey(nama),
          'nomor_hp': normalized,
          'nomor_hp_normalized': normalizePhone(normalized),
          'alamat': (alamat ?? '').trim().isEmpty ? null : alamat!.trim(),
          'wa_consent': waConsent ? 1 : 0,
          'do_not_contact': doNotContact ? 1 : 0,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (enqueue != null) await enqueue(txn, id);
    });
  }

  Future<Map<String, List<int>>> mergeCustomers({
    required int sourceId,
    required int targetId,
    Future<void> Function(Transaction txn, int id)? enqueueCustomer,
    Future<void> Function(Transaction txn, int id)? enqueueUnit,
    Future<void> Function(Transaction txn, int id)? enqueueNote,
  }) async {
    if (sourceId == targetId) {
      throw ArgumentError('Pelanggan asal dan tujuan harus berbeda.');
    }
    return db.transaction((txn) async {
      final target = await txn.query(
        'customers',
        where: 'id = ? AND deleted_at IS NULL',
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
      final records = await txn.query(
        'service_records',
        columns: ['id'],
        where: unitIds.isEmpty
            ? 'customer_id = ?'
            : 'customer_id = ? OR unit_id IN '
                  '(${List.filled(unitIds.length, '?').join(',')})',
        whereArgs: unitIds.isEmpty ? [sourceId] : [sourceId, ...unitIds],
      );
      if (records.isNotEmpty) {
        final recordHlc = await nextSyncHlc(txn);
        await txn.update(
          'service_records',
          {
            'customer_id': targetId,
            'sync_hlc_wall': recordHlc.wall,
            'sync_hlc_counter': recordHlc.counter,
            'updated_at': nowIso(),
          },
          where: 'id IN (${List.filled(records.length, '?').join(',')})',
          whereArgs: records.map((row) => row['id']).toList(),
        );
      }
      final followupHlc = await nextSyncHlc(txn);
      await txn.update(
        'followup_items',
        {
          'customer_id': targetId,
          'sync_hlc_wall': followupHlc.wall,
          'sync_hlc_counter': followupHlc.counter,
          'updated_at': nowIso(),
        },
        where: 'customer_id = ?',
        whereArgs: [sourceId],
      );
      await txn.update(
        'wa_message_logs',
        {'customer_id': targetId, 'updated_at': nowIso()},
        where: 'customer_id = ?',
        whereArgs: [sourceId],
      );
      if (unitIds.isNotEmpty) {
        final unitHlc = await nextSyncHlc(txn);
        await txn.update(
          'vehicle_or_units',
          {
            'customer_id': targetId,
            'sync_hlc_wall': unitHlc.wall,
            'sync_hlc_counter': unitHlc.counter,
          },
          where: 'customer_id = ?',
          whereArgs: [sourceId],
        );
      }
      final hlc = await nextSyncHlc(txn);
      await txn.update(
        'customers',
        {
          'deleted_at': nowIso(),
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
        },
        where: 'id = ?',
        whereArgs: [sourceId],
      );
      if (enqueueCustomer != null) {
        await enqueueCustomer(txn, sourceId);
      }
      if (enqueueUnit != null) {
        for (final unitId in unitIds) {
          await enqueueUnit(txn, unitId);
        }
      }
      final recordIds = records.map((row) => row['id'] as int).toList();
      if (enqueueNote != null) {
        for (final recordId in recordIds) {
          await enqueueNote(txn, recordId);
        }
      }
      return {'units': unitIds, 'records': recordIds};
    });
  }

  Future<List<VehicleUnit>> listUnits(int customerId) async {
    final rows = await db.query(
      'vehicle_or_units',
      where: 'customer_id = ? AND deleted_at IS NULL',
      whereArgs: [customerId],
      orderBy: 'id DESC',
    );
    return rows.map(VehicleUnit.fromRow).toList();
  }

  Future<int> addUnit({
    int? customerId,
    String unitType = 'MOBIL',
    String? nopol,
    String? merek,
    String? tipe,
    int? tahunMobil,
    String? noRangka,
    String? noMesin,
    int? kmTerakhir,
    String? jenisMobil,
    String? tipeRadiator,
    String? labelRadiator,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) {
    return db.transaction((txn) async {
      final hlc = await nextSyncHlc(txn);
      final id = await txn.insert('vehicle_or_units', {
        'sync_id': newSyncId(),
        'customer_id': customerId,
        'unit_type': unitType,
        'nopol': _nullable(nopol),
        'merek': _nullable(merek),
        'tipe': _nullable(tipe),
        'jenis_mobil': _nullable(jenisMobil),
        'tahun_mobil': tahunMobil,
        'no_rangka': _nullable(noRangka),
        'no_mesin': _nullable(noMesin),
        'km_terakhir': kmTerakhir,
        'tipe_radiator': _nullable(tipeRadiator),
        'label_radiator': _nullable(labelRadiator),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, id);
      return id;
    });
  }

  Future<List<StockItem>> listStock({String query = ''}) async {
    final term = query.trim();
    final escaped = escapeLike(term);
    final rows = await db.query(
      'stock_items',
      where: term.isEmpty
          ? 'deleted_at IS NULL'
          : "deleted_at IS NULL AND (nama LIKE ? ESCAPE '\\' "
                "OR kode LIKE ? ESCAPE '\\' "
                "OR barcode LIKE ? ESCAPE '\\')",
      whereArgs: term.isEmpty
          ? null
          : ['%$escaped%', '%$escaped%', '%$escaped%'],
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
    int? stokAwalMilli,
    String satuan = 'pcs',
    int desimal = 0,
    int intervalBulan = 0,
    String? alasan,
    Operator? actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
    Future<void> Function(Transaction txn, int movementId)? enqueueMovement,
  }) async {
    _requireActor(actor);
    if (actor != null) Permissions.require(actor, permissionChangeStock);
    if (hargaModalCents < 0 || hargaJualCents < 0) {
      throw ArgumentError('Harga tidak boleh negatif.');
    }
    if (stokMinimum < 0) {
      throw ArgumentError('Stok minimum tidak boleh negatif.');
    }
    if (actor != null && !actor.isOwner) {
      if (id == null) {
        throw StateError('Hanya pemilik yang dapat menetapkan harga barang.');
      }
      final existing = await db.query(
        'stock_items',
        columns: ['harga_modal', 'harga_jual'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty &&
          ((existing.first['harga_modal'] as int?) != hargaModalCents ||
              (existing.first['harga_jual'] as int?) != hargaJualCents)) {
        throw StateError('Hanya pemilik yang dapat mengubah harga barang.');
      }
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
      where: 'kode = ? AND deleted_at IS NULL',
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
      'jumlah': wholeQuantity(milli),
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
        if (rows.isEmpty || rows.first['deleted_at'] != null) {
          throw StateError('Barang tidak ditemukan.');
        }
        final before = StockItem.fromRow(rows.first);
        final stockSyncId = rows.first['sync_id'] as String;
        // Formulir membawa angka stok yang dilihat pengguna. Selisihnya
        // diterapkan ke stok terkini agar penjualan yang masuk setelah
        // formulir dibuka tidak ikut tertimpa.
        final targetMilli = stokAwalMilli == null
            ? milli
            : before.jumlahMilli + (milli - stokAwalMilli);
        if (targetMilli < 0) {
          throw ArgumentError('Stok tidak boleh negatif.');
        }
        final hlc = await nextSyncHlc(txn);
        await txn.update(
          'stock_items',
          {
            ...payload,
            'jumlah': wholeQuantity(targetMilli),
            'jumlah_milli': targetMilli,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        final delta = targetMilli - before.jumlahMilli;
        int? movementId;
        if (delta != 0) {
          movementId = await txn.insert('stock_movements', {
            'sync_id': newSyncId(),
            'stock_item_id': id,
            'stock_sync_id': stockSyncId,
            'nama_item': payload['nama'],
            'jenis': 'KOREKSI',
            'jumlah': wholeQuantity(delta),
            'jumlah_milli': delta,
            'stok_sebelum_milli': before.jumlahMilli,
            'stok_sesudah_milli': targetMilli,
            'sumber_entity': 'stock_item',
            'sumber_sync_id': stockSyncId,
            'operator': actor?.label,
            'alasan': (alasan ?? '').trim().isEmpty
                ? 'Koreksi stok'
                : alasan!.trim(),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': nowIso(),
            'updated_at': nowIso(),
          });
        }
        if (enqueue != null) await enqueue(txn, id);
        if (movementId != null && enqueueMovement != null) {
          await enqueueMovement(txn, movementId);
        }
        return id;
      });
    }
    return db.transaction((txn) async {
      final hlc = await nextSyncHlc(txn);
      final stockSyncId = newSyncId();
      final newId = await txn.insert('stock_items', {
        ...payload,
        'sync_id': stockSyncId,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      int? movementId;
      if (milli != 0) {
        movementId = await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': newId,
          'stock_sync_id': stockSyncId,
          'nama_item': payload['nama'],
          'jenis': 'MASUK',
          'jumlah': wholeQuantity(milli),
          'jumlah_milli': milli,
          'stok_sebelum_milli': 0,
          'stok_sesudah_milli': milli,
          'sumber_entity': 'stock_item',
          'sumber_sync_id': stockSyncId,
          'operator': actor?.label,
          'alasan': (alasan ?? '').trim().isEmpty
              ? 'Stok awal'
              : alasan!.trim(),
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': nowIso(),
          'updated_at': nowIso(),
        });
      }
      if (enqueue != null) await enqueue(txn, newId);
      if (movementId != null && enqueueMovement != null) {
        await enqueueMovement(txn, movementId);
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
    Future<void> Function(Transaction txn, int id)? enqueue,
    Future<void> Function(Transaction txn, int movementId)? enqueueMovement,
  }) async {
    _requireActor(actor);
    if (actor != null) Permissions.require(actor, permissionStockIn);
    final milli = qtyMilli ?? qty * 1000;
    if (milli <= 0) throw ArgumentError('Jumlah stok masuk minimal 1.');
    await _adjustStock(
      item: item,
      deltaMilli: milli,
      jenis: 'MASUK',
      alasan: (alasan ?? '').trim().isEmpty ? 'Tambah stok' : alasan!.trim(),
      serviceRecordId: null,
      enqueue: enqueue,
      enqueueMovement: enqueueMovement,
    );
  }

  Future<void> stockOut({
    required StockItem item,
    required int qty,
    int? qtyMilli,
    required String alasan,
    Operator? actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
    Future<void> Function(Transaction txn, int movementId)? enqueueMovement,
  }) async {
    _requireActor(actor);
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
      enqueue: enqueue,
      enqueueMovement: enqueueMovement,
    );
  }

  Future<void> opname({
    required StockItem item,
    required int jumlahFisikMilli,
    String? alasan,
    Operator? actor,
    Future<void> Function(DatabaseExecutor txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int movementId)?
    enqueueMovement,
  }) async {
    _requireActor(actor);
    if (actor != null) Permissions.require(actor, permissionOpname);
    if (jumlahFisikMilli < 0) {
      throw ArgumentError('Jumlah fisik tidak boleh negatif.');
    }
    await db.transaction(
      (txn) => applyOpnameTx(
        txn,
        itemId: item.id,
        namaItem: item.nama,
        jumlahFisikMilli: jumlahFisikMilli,
        alasan: alasan,
        actor: actor,
        enqueue: enqueue,
        enqueueMovement: enqueueMovement,
      ),
    );
  }

  /// Penerapan opname tanpa membuka transaksi sendiri; dipakai gerbang
  /// opname menunggu sinkron (BD-03) agar penerapan akhir tetap atomik.
  Future<void> applyOpnameTx(
    DatabaseExecutor txn, {
    required int itemId,
    required String namaItem,
    required int jumlahFisikMilli,
    String? alasan,
    String sumberEntity = 'opname',
    Operator? actor,
    Future<void> Function(DatabaseExecutor txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int movementId)?
    enqueueMovement,
  }) async {
    if (jumlahFisikMilli < 0) {
      throw ArgumentError('Jumlah fisik tidak boleh negatif.');
    }
    final rows = await txn.query(
      'stock_items',
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['deleted_at'] != null) {
      throw StateError('Barang tidak ditemukan.');
    }
    final before = StockItem.fromRow(rows.first);
    final stockSyncId = rows.first['sync_id'] as String;
    final delta = jumlahFisikMilli - before.jumlahMilli;
    final hlc = await nextSyncHlc(txn);
    await txn.update(
      'stock_items',
      {
        'jumlah': wholeQuantity(jumlahFisikMilli),
        'jumlah_milli': jumlahFisikMilli,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
    final movementSyncId = newSyncId();
    final movementId = await txn.insert('stock_movements', {
      'sync_id': movementSyncId,
      'stock_item_id': itemId,
      'stock_sync_id': stockSyncId,
      'nama_item': namaItem,
      'jenis': 'KOREKSI',
      'jumlah': wholeQuantity(delta),
      'jumlah_milli': delta,
      'stok_sebelum_milli': before.jumlahMilli,
      'stok_sesudah_milli': jumlahFisikMilli,
      'opname_absolut_milli': jumlahFisikMilli,
      'sumber_entity': sumberEntity,
      'sumber_sync_id': movementSyncId,
      'operator': actor?.label,
      'alasan': (alasan ?? '').trim().isEmpty
          ? 'Opname stok'
          : alasan!.trim(),
      'sync_hlc_wall': hlc.wall,
      'sync_hlc_counter': hlc.counter,
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    if (enqueue != null) await enqueue(txn, itemId);
    if (enqueueMovement != null) await enqueueMovement(txn, movementId);
  }

  Future<void> _adjustStock({
    required StockItem item,
    required int deltaMilli,
    required String jenis,
    required String alasan,
    required int? serviceRecordId,
    Future<void> Function(Transaction txn, int id)? enqueue,
    Future<void> Function(Transaction txn, int movementId)? enqueueMovement,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['deleted_at'] != null) {
        throw StateError('Barang tidak ditemukan.');
      }
      final before = StockItem.fromRow(rows.first);
      final stockSyncId = rows.first['sync_id'] as String;
      final next = before.jumlahMilli + deltaMilli;
      if (next < 0) {
        throw StateError(
          'Stok ${item.nama} tidak cukup. Sisa ${before.jumlahMilli / 1000}.',
        );
      }
      final hlc = await nextSyncHlc(txn);
      await txn.update(
        'stock_items',
        {
          'jumlah': wholeQuantity(next),
          'jumlah_milli': next,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [item.id],
      );
      final movementSyncId = newSyncId();
      final movementId = await txn.insert('stock_movements', {
        'sync_id': movementSyncId,
        'stock_item_id': item.id,
        'stock_sync_id': stockSyncId,
        'nama_item': item.nama,
        'jenis': jenis,
        'jumlah': wholeQuantity(deltaMilli),
        'jumlah_milli': deltaMilli,
        'stok_sebelum_milli': before.jumlahMilli,
        'stok_sesudah_milli': next,
        'sumber_entity': serviceRecordId == null
            ? 'stock_adjustment'
            : 'service_record',
        'sumber_sync_id': movementSyncId,
        'service_record_id': serviceRecordId,
        'alasan': alasan,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, item.id);
      if (enqueueMovement != null) await enqueueMovement(txn, movementId);
    });
  }

  Future<List<ServiceCatalog>> listCatalog() async {
    final rows = await db.query(
      'harga_jasa',
      where: 'deleted_at IS NULL',
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(ServiceCatalog.fromRow).toList();
  }

  Future<int> saveCatalog({
    int? id,
    required String nama,
    required int hargaCents,
    int hargaModalCents = 0,
    int intervalBulan = 0,
    Operator? actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    if (actor != null) {
      Permissions.require(actor, permissionChangeServicePrice);
      if (!actor.isOwner) {
        throw StateError('Hanya pemilik yang dapat mengubah tarif jasa.');
      }
    }
    if (hargaCents < 0) {
      throw ArgumentError('Harga jasa tidak boleh negatif.');
    }
    if (hargaModalCents < 0) {
      throw ArgumentError('Harga modal jasa tidak boleh negatif.');
    }
    final payload = {
      'nama': nama.trim(),
      'harga_jual': hargaCents,
      'harga_modal': hargaModalCents,
      'interval_servis_bulan': intervalBulan < 0 ? 0 : intervalBulan,
    };
    return db.transaction((txn) async {
      final hlc = await nextSyncHlc(txn);
      if (id != null) {
        await txn.update(
          'harga_jasa',
          {
            ...payload,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        if (enqueue != null) await enqueue(txn, id);
        return id;
      }
      final newId = await txn.insert('harga_jasa', {
        ...payload,
        'sync_id': newSyncId(),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, newId);
      return newId;
    });
  }

  Future<void> deleteCatalog(
    int id, {
    Operator? actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    if (actor != null) {
      Permissions.require(actor, permissionChangeServicePrice);
    }
    await db.transaction((txn) async {
      final hlc = await nextSyncHlc(txn);
      await txn.update(
        'harga_jasa',
        {
          'deleted_at': nowIso(),
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (enqueue != null) await enqueue(txn, id);
    });
  }

  Future<int> createTransaction({
    int? unitId,
    int? customerId,
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
    String jenisTransaksi = transactionServisLangsung,
    Map<String, Object?>? modeSaatDibuat,
    String? workOrderSyncId,
    String? estimateSyncId,
    int? totalEstimasiTerakhir,
    String? alasanDiskon,
    DateTime? jatuhTempo,
    String? ownerPin,
    String? approverSecret,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueEstimate,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueOrder,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) async {
    final jenis = sparepartOnly ? transactionJualSparepart : jenisTransaksi;
    if (jenis == transactionEstimasiSaja) {
      throw ArgumentError(
        'Estimasi bukan transaksi keuangan. Gunakan layanan estimasi.',
      );
    }
    if (!transactionTypes.contains(jenis)) {
      throw ArgumentError('Jenis transaksi "$jenis" tidak dikenal.');
    }
    if (jobs.isEmpty && parts.isEmpty) {
      throw ArgumentError('Tambahkan minimal satu jasa atau part.');
    }
    if (jenis == transactionJualSparepart && jobs.isNotEmpty) {
      throw ArgumentError('Penjualan sparepart hanya boleh memuat part.');
    }
    if (jenis == transactionJualSparepart && parts.isEmpty) {
      throw ArgumentError('Penjualan sparepart membutuhkan minimal satu part.');
    }
    if (diskonCents < 0) {
      throw ArgumentError('Diskon tidak boleh negatif.');
    }
    if (bayarCents < 0) {
      throw ArgumentError('Nominal bayar tidak boleh negatif.');
    }
    if (metodeBayar != 'CASH' && metodeBayar != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak dikenal.');
    }
    final settings = await StoreSettingsService.instance.ensure(executor: db);
    _requireActor(actor);
    final role = actor!.role;
    if (!settings.typeEnabled(jenis)) {
      throw StateError('Jenis transaksi "$jenis" sedang dimatikan pemilik.');
    }
    if (!settings.roleCanSelect(role, jenis)) {
      throw StateError('Peran $role tidak berhak membuat jenis "$jenis".');
    }
    if (diskonCents > 0) {
      Permissions.require(actor, permissionDiscount);
      if (!settings.roleAllows(role, 'diskon')) {
        throw StateError('Peran $role tidak berhak memberi diskon.');
      }
    }
    for (final job in jobs) {
      if (job.jumlah <= 0) {
        throw ArgumentError('Jumlah jasa harus lebih dari nol.');
      }
      if (job.hargaCents < 0) {
        throw ArgumentError('Harga jasa tidak boleh negatif.');
      }
    }
    final isOwner = actor.isOwner;
    var approver = isOwner ? actor.label : null;
    if (!isOwner && diskonCents > 0 && settings.approvalDiscount) {
      final hasApprovalInput =
          (ownerPin ?? '').trim().isNotEmpty ||
          (approverSecret ?? '').trim().isNotEmpty;
      if (!hasApprovalInput) {
        throw StateError(
          'Diskon memerlukan persetujuan pemilik atau penanggung jawab.',
        );
      }
      // Verifikasi di luar transaksi: penghitung gagal login harus tetap
      // tersimpan walau transaksi nota dibatalkan.
      try {
        final approval = await ApprovalService.instance.verify(
          settings: settings,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
        );
        approver = approval.isOwner ? 'Pemilik (PIN)' : approval.label;
      } on ApprovalException catch (failure) {
        throw PriceRuleViolation('persetujuan_gagal', failure.message);
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
      final lines = <PriceLine>[];
      final jobCatalogSyncIds = <int, String?>{};
      for (var jobIndex = 0; jobIndex < jobs.length; jobIndex++) {
        final job = jobs[jobIndex];
        job.modalCents = job.modalCents < 0 ? 0 : job.modalCents;
        if (job.jasaId != null) {
          final catalog = await txn.query(
            'harga_jasa',
            columns: [
              'sync_id',
              'harga_jual',
              'harga_modal',
              'deleted_at',
            ],
            where: 'id = ?',
            whereArgs: [job.jasaId],
            limit: 1,
          );
          if (catalog.isEmpty || catalog.first['deleted_at'] != null) {
            throw StateError(
              'Jasa ${job.deskripsi} tidak ditemukan di daftar tarif.',
            );
          }
          jobCatalogSyncIds[jobIndex] =
              catalog.first['sync_id'] as String?;
          final hargaJual = (catalog.first['harga_jual'] as num?)?.toInt() ?? 0;
          if (job.hargaCents != hargaJual) {
            throw StateError(
              'Harga jasa ${job.deskripsi} berubah menjadi '
              '${formatRupiah(hargaJual)}. Muat ulang kasir lalu ulangi.',
            );
          }
          job.modalCents = (catalog.first['harga_modal'] as num?)?.toInt() ?? 0;
        }
        lines.add(
          PriceLine(
            jenis: 'jasa',
            label: job.deskripsi,
            jumlah: job.jumlah,
            hargaTerdaftar: job.hargaCents,
            hargaModal: job.modalCents,
            jasaId: job.jasaId,
            intervalBulan: job.intervalBulan,
          ),
        );
      }
      final requestedMilli = <int, int>{};
      final stockSyncIds = <int, String?>{};
      for (final part in parts) {
        if (part.qtyMilli <= 0) {
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
        if (rows.isEmpty || rows.first['deleted_at'] != null) {
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
        // Baris yang sama bisa muncul lebih dari sekali; validasi memakai
        // total per barang agar stok tidak menjadi negatif.
        final totalRequested =
            (requestedMilli[part.stockItemId] ?? 0) + part.qtyMilli;
        requestedMilli[part.stockItemId] = totalRequested;
        if (stock.jumlahMilli < totalRequested) {
          throw StateError(
            'Stok ${stock.nama} tidak cukup (tersisa ${stock.jumlahLabel}).',
          );
        }
        part
          ..nama = stock.nama
          ..modalCents = stock.hargaModalCents;
        stockSyncIds[part.stockItemId] = rows.first['sync_id'] as String?;
        lines.add(
          PriceLine(
            jenis: 'part',
            label: stock.nama,
            jumlah: part.jumlah,
            qtyMilli: part.qtyMilli,
            hargaTerdaftar: stock.hargaJualCents,
            hargaModal: stock.hargaModalCents,
            stockItemId: stock.id,
            intervalBulan: part.intervalBulan,
          ),
        );
      }
      final allocation = PriceRules.allocate(
        lines,
        diskonCents: diskonCents,
        allowBelowMinimum: isOwner,
        alasanDiskon: alasanDiskon,
        disetujuiOleh: approver,
      );
      for (var index = 0; index < jobs.length; index++) {
        final line = allocation.lines[index];
        jobs[index]
          ..hargaFinalCents = line.hargaFinal
          ..diskonAlokasiCents = line.diskonAlokasi
          ..alasanDiskon = line.alasanDiskon
          ..disetujuiOleh = line.disetujuiOleh;
      }
      for (var index = 0; index < parts.length; index++) {
        final line = allocation.lines[jobs.length + index];
        parts[index]
          ..hargaFinalCents = line.hargaFinal
          ..diskonAlokasiCents = line.diskonAlokasi
          ..alasanDiskon = line.alasanDiskon
          ..disetujuiOleh = line.disetujuiOleh;
      }
      final biayaJasa = jobs.fold<int>(
        0,
        (sum, job) => sum + job.subtotalCents,
      );
      final totalPart = parts.fold<int>(
        0,
        (sum, part) => sum + part.subtotalCents,
      );
      final bruto = biayaJasa + totalPart;
      final diskon = allocation.diskon;
      final total = bruto - diskon;
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
      final prefix = switch (jenis) {
        transactionJualSparepart => 'S',
        transactionOrderKerja => 'O',
        transactionPelunasanOrder => 'P',
        _ => 'N',
      };
      final noNota = await allocateDocumentNumber(
        txn,
        docType: 'nota_$jenis',
        prefix: prefix,
      );
      String? resolvedCustomerSync;
      if (customerId != null) {
        final rows = await txn.query(
          'customers',
          columns: ['sync_id'],
          where: 'id = ?',
          whereArgs: [customerId],
          limit: 1,
        );
        resolvedCustomerSync = rows.isEmpty
            ? null
            : rows.first['sync_id'] as String?;
      }
      if (unitId != null) {
        final unit = await txn.query(
          'vehicle_or_units',
          columns: ['customer_id'],
          where: 'id = ?',
          whereArgs: [unitId],
          limit: 1,
        );
        if (unit.isEmpty) throw StateError('Kendaraan tidak ditemukan.');
        final unitCustomer = unit.first['customer_id'];
        if (resolvedCustomerSync == null && unitCustomer != null) {
          final customer = await txn.query(
            'customers',
            columns: ['sync_id'],
            where: 'id = ?',
            whereArgs: [unitCustomer],
            limit: 1,
          );
          if (customer.isNotEmpty) {
            resolvedCustomerSync = customer.first['sync_id'] as String?;
          }
        }
      }
      final requestedMechanics = <String>[];
      for (final id in mechanicEmployeeSyncIds) {
        final clean = id.trim();
        if (clean.isNotEmpty && !requestedMechanics.contains(clean)) {
          requestedMechanics.add(clean);
        }
      }
      final mechanicRows = <Map<String, Object?>>[];
      if (requestedMechanics.isNotEmpty) {
        final placeholders = List.filled(
          requestedMechanics.length,
          '?',
        ).join(',');
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
        sparepartOnly: jenis == transactionJualSparepart,
        bergaransi: bergaransi,
        garansiBulan: garansiBulan,
        customDate: garansiSampai,
        catatanGaransi: catatanGaransi,
        barangAktif: garansiBarangAktif,
        barangNilai: garansiBarangNilai,
        barangSatuan: garansiBarangSatuan,
      );
      final recordSyncId = newSyncId();
      final recordId = await txn.insert('service_records', {
        'sync_id': recordSyncId,
        'unit_id': unitId,
        'customer_id':
            customerId ?? (await _customerIdBySync(txn, resolvedCustomerSync)),
        'no_nota': noNota,
        'request_id': (requestId ?? '').trim().isEmpty
            ? null
            : requestId!.trim(),
        'jenis_transaksi': jenis,
        'mode_saat_dibuat_json': jsonEncode(
          modeSaatDibuat ?? settings.modeSnapshot(jenisTransaksi: jenis),
        ),
        'diskon_snapshot_json': jsonEncode({
          'input': diskonCents,
          'dialokasikan': diskon,
          'alasan': alasanDiskon,
          'disetujui_oleh': approver,
          'boleh_di_bawah_modal': isOwner,
        }),
        'pajak_snapshot_json': jsonEncode({'nominal': 0, 'persen': 0}),
        'work_order_sync_id': _nullable(workOrderSyncId),
        'estimate_sync_id': _nullable(estimateSyncId),
        'total_estimasi_terakhir': totalEstimasiTerakhir,
        'waktu_service': now,
        'keluhan_awal': keluhan.trim(),
        'catatan_pengerjaan': _nullable(catatan),
        'biaya_jasa': biayaJasa,
        'total_part': totalPart,
        'diskon': diskon,
        'total_servis': total,
        'total_koreksi': 0,
        'total_retur': 0,
        'total_efektif': total,
        'total_kas_diterima': dibayar,
        'metode_bayar': metodeBayar,
        'bayar': bayarCents,
        'kembalian': kembalian,
        'status_bayar': statusBayar,
        'jenis_bayar': statusBayar,
        'total_dibayar': dibayar,
        'sisa_bayar': sisa,
        'jatuh_tempo': sisa > 0 && jatuhTempo != null
            ? jatuhTempo.toIso8601String()
            : null,
        'created_by': actor.label,
        'created_by_employee_id': actor.employeeSyncId,
        'cashier_employee_id': actor.employeeSyncId,
        'mechanic': _nullable(
          mechanic ?? (mechanicNames.isEmpty ? null : mechanicNames),
        ),
        'mechanic_employee_id':
            mechanicEmployeeSyncId ??
            (mechanicRows.isEmpty ? null : mechanicRows.first['sync_id']),
        'bergaransi': warranty.bergaransi ? 1 : 0,
        'garansi_bulan': warranty.bulan,
        'garansi_sampai': warranty.sampai,
        'catatan_garansi': warranty.catatan,
        'status_klaim': 'Belum claim',
        'sparepart_only': jenis == transactionJualSparepart ? 1 : 0,
        'garansi_barang_aktif': warranty.barangAktif ? 1 : 0,
        'garansi_barang_nilai': warranty.barangNilai,
        'garansi_barang_satuan': warranty.barangSatuan,
        'garansi_barang_sampai': warranty.barangSampai,
        'unit_ditinggal': unitDitinggal ? 1 : 0,
        'status': 'AKTIF',
        'version': 1,
        'created_at': now,
        'updated_at': now,
      });
      for (var jobIndex = 0; jobIndex < jobs.length; jobIndex++) {
        final job = jobs[jobIndex];
        await txn.insert('service_jobs', {
          'sync_id': job.syncId ?? newSyncId(),
          'service_record_id': recordId,
          'harga_jasa_id': job.jasaId,
          'harga_jasa_sync_id': jobCatalogSyncIds[jobIndex],
          'deskripsi': job.deskripsi.trim(),
          'jumlah': job.jumlah,
          'qty_retur_milli': 0,
          'harga': job.hargaCents,
          'subtotal': job.subtotalCents,
          'harga_jual_terdaftar': job.hargaTerdaftarCents,
          'harga_batas_saat_transaksi': job.modalCents,
          'harga_final': job.hargaFinalCents,
          'diskon_alokasi': job.diskonAlokasiCents,
          'alasan_diskon': job.alasanDiskon,
          'disetujui_oleh': job.disetujuiOleh,
          'interval_servis_bulan': job.intervalBulan < 0
              ? 0
              : job.intervalBulan,
          'created_at': now,
          'updated_at': now,
        });
      }
      for (final part in parts) {
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [part.stockItemId],
          limit: 1,
        );
        final before = StockItem.fromRow(stockRows.first);
        final partSyncId = part.syncId ?? newSyncId();
        final nextMilli = before.jumlahMilli - part.qtyMilli;
        if (nextMilli < 0) {
          throw StateError('Stok ${before.nama} tidak cukup.');
        }
        await txn.insert('service_parts', {
          'sync_id': partSyncId,
          'service_record_id': recordId,
          'stock_item_id': part.stockItemId,
          'stock_sync_id': stockSyncIds[part.stockItemId],
          'nama_part': part.nama,
          'satuan': before.satuan,
          'jumlah': part.qtyMilli ~/ 1000,
          'jumlah_milli': part.qtyMilli,
          'qty_retur_milli': 0,
          'harga_satuan': part.hargaCents,
          'subtotal': part.subtotalCents,
          'harga_modal': part.modalCents,
          'harga_jual_terdaftar': part.hargaTerdaftarCents,
          'harga_batas_saat_transaksi': part.modalCents,
          'harga_final': part.hargaFinalCents,
          'diskon_alokasi': part.diskonAlokasiCents,
          'alasan_diskon': part.alasanDiskon,
          'disetujui_oleh': part.disetujuiOleh,
          'interval_servis_bulan': part.intervalBulan < 0
              ? 0
              : part.intervalBulan,
          'created_at': now,
          'updated_at': now,
        });
        final stockHlc = await nextSyncHlc(txn);
        await txn.update(
          'stock_items',
          {
            'jumlah': wholeQuantity(nextMilli),
            'jumlah_milli': nextMilli,
            'sync_hlc_wall': stockHlc.wall,
            'sync_hlc_counter': stockHlc.counter,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [part.stockItemId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': part.stockItemId,
          'stock_sync_id': stockSyncIds[part.stockItemId],
          'nama_item': part.nama,
          'jenis': 'KELUAR',
          'jumlah': wholeQuantity(-part.qtyMilli),
          'jumlah_milli': -part.qtyMilli,
          'stok_sebelum_milli': before.jumlahMilli,
          'stok_sesudah_milli': nextMilli,
          'sumber_entity': 'service_part',
          'sumber_sync_id': partSyncId,
          'service_record_id': recordId,
          'operator': actor.label,
          'alasan': 'Penjualan $noNota',
          'sync_hlc_wall': stockHlc.wall,
          'sync_hlc_counter': stockHlc.counter,
          'created_at': now,
          'updated_at': now,
        });
      }
      if (dibayar > 0) {
        final paymentSyncId = newSyncId();
        await txn.insert('service_payments', {
          'sync_id': paymentSyncId,
          'service_record_id': recordId,
          'jenis': sisa > 0 ? 'DP' : 'PELUNASAN',
          'metode': metodeBayar,
          'nominal': dibayar,
          'waktu': now,
          'operator': actor.label,
          'request_id': '${requestId ?? noNota}-bayar',
          'kas_kategori': 'PENJUALAN',
          'catatan': null,
          'created_at': now,
          'updated_at': now,
        });
        await txn.insert('cash_ledger', {
          'sync_id': newSyncId(),
          'waktu': now,
          'kategori': 'PENJUALAN',
          'sumber_entity': 'service_payment',
          'sumber_sync_id': paymentSyncId,
          'nominal': dibayar,
          'metode': metodeBayar,
          'operator': actor.label,
          'catatan': 'Pembayaran $noNota',
          'created_at': now,
          'updated_at': now,
        });
      }
      if (diskon > 0 || allocation.belowMinimum) {
        await txn.insert('permission_audits', {
          'sync_id': newSyncId(),
          'actor': actor.label,
          'target_account_id': actor.employeeId,
          'action': allocation.belowMinimum ? 'harga_bawah_modal' : 'diskon',
          'detail_json': jsonEncode({
            'no_nota': noNota,
            'jenis_transaksi': jenis,
            'diskon': diskon,
            'di_bawah_modal': allocation.belowMinimum,
            'disetujui_oleh': approver,
            'alasan_diskon': alasanDiskon,
          }),
          'created_at': now,
          'updated_at': now,
        });
      }
      if (mechanicRows.isNotEmpty) {
        await _insertMechanicsAndCommissions(
          txn,
          recordId,
          mechanicRows,
          jobs: jobs,
          parts: parts,
          enqueueCommission: enqueueCommission,
        );
      }
      if ((workOrderSyncId ?? '').trim().isNotEmpty) {
        final orderHlc = await nextSyncHlc(txn);
        await txn.update(
          'work_orders',
          {
            'nota_sync_id': recordSyncId,
            'sync_hlc_wall': orderHlc.wall,
            'sync_hlc_counter': orderHlc.counter,
            'updated_at': now,
          },
          where: 'sync_id = ?',
          whereArgs: [workOrderSyncId!.trim()],
        );
        if (enqueueOrder != null) {
          await enqueueOrder(txn, workOrderSyncId.trim());
        }
      }
      if ((estimateSyncId ?? '').trim().isNotEmpty) {
        final estimateHlc = await nextSyncHlc(txn);
        final converted = await txn.update(
          'estimates',
          {
            'status': 'dikonversi',
            'converted_nota_sync_id': recordSyncId,
            'total_estimasi_terakhir': totalEstimasiTerakhir,
            'sync_hlc_wall': estimateHlc.wall,
            'sync_hlc_counter': estimateHlc.counter,
            'updated_at': now,
          },
          where: "sync_id = ? AND status = 'aktif'",
          whereArgs: [estimateSyncId!.trim()],
        );
        if (converted != 1) {
          throw StateError('Estimasi sudah dikonversi atau tidak lagi aktif.');
        }
        if (enqueueEstimate != null) {
          await enqueueEstimate(txn, estimateSyncId.trim());
        }
      }
      if (enqueue != null) await enqueue(txn, recordId);
      return recordId;
    });
  }

  Future<int?> _customerIdBySync(DatabaseExecutor txn, String? syncId) async {
    if (syncId == null || syncId.isEmpty) return null;
    final rows = await txn.query(
      'customers',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  Future<void> _insertMechanicsAndCommissions(
    DatabaseExecutor txn,
    int recordId,
    List<Map<String, Object?>> mechanics, {
    required List<JobDraft> jobs,
    required List<PartDraft> parts,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) async {
    final netJasa = jobs.fold<int>(0, (sum, job) => sum + job.lineTotalCents);
    final margin = parts.fold<int>(
      0,
      (sum, part) =>
          sum +
          (part.hargaCents - part.modalCents) * part.qtyMilli ~/ 1000 -
          part.diskonAlokasiCents,
    );
    final count = mechanics.length;
    var index = 0;
    final snapshot = <String, Object?>{};
    for (final mechanic in mechanics) {
      final syncId = '${mechanic['sync_id']}';
      final nama = '${mechanic['nama'] ?? mechanic['username'] ?? ''}';
      await txn.insert('service_record_mechanics', {
        'sync_id': newSyncId(),
        'service_record_id': recordId,
        'employee_sync_id': syncId,
        'employee_nama_snapshot': nama,
        'urutan': index,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      final mode = '${mechanic['komisi_mode'] ?? 'PERSEN'}';
      final barangNilai =
          (mechanic['komisi_barang_nilai'] as num?)?.toInt() ?? 0;
      final jasaNilai = (mechanic['komisi_jasa_nilai'] as num?)?.toInt() ?? 0;
      snapshot[syncId] = {
        'mode': mode,
        'jasa': jasaNilai,
        'barang': barangNilai,
      };
      final shareJasa = _splitShare(netJasa, index, count);
      final shareMargin = _splitShare(margin, index, count);
      final nominal = mode == 'NOMINAL'
          ? (parts.isNotEmpty ? barangNilai : 0) +
                (jobs.isNotEmpty ? jasaNilai : 0)
          : (shareJasa * jasaNilai) ~/ 100 + (shareMargin * barangNilai) ~/ 100;
      final commissionId = await txn.insert('service_record_commissions', {
        'sync_id': newSyncId(),
        'service_record_id': recordId,
        'employee_sync_id': syncId,
        'employee_nama_snapshot': nama,
        'mode_snapshot': mode,
        'nilai_snapshot': mode == 'NOMINAL'
            ? (parts.isNotEmpty ? barangNilai : jasaNilai)
            : jasaNilai,
        'dasar_jasa': shareJasa,
        'dasar_barang': shareMargin,
        'nominal': nominal,
        'status': 'AKTIF',
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueueCommission != null) {
        await enqueueCommission(txn, commissionId);
      }
      index++;
    }
    await txn.update(
      'service_records',
      {'commission_snapshot_json': jsonEncode(snapshot)},
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  static int _splitShare(int total, int index, int count) {
    if (count <= 0) return 0;
    final base = total ~/ count;
    final remainder = total - base * count;
    if (remainder == 0) return base;
    final extra = index < remainder.abs() ? remainder.sign : 0;
    return base + extra;
  }

  /// Menghitung ulang komisi nota dengan nilai neto setelah retur.
  ///
  /// Basisnya sama dengan saat nota dibuat: jasa dan margin part setelah
  /// diskon, dikurangi porsi baris yang sudah diretur.
  Future<void> recalculateRecordCommissions(
    DatabaseExecutor txn,
    int recordId, {
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) async {
    final commissionRows = await txn.query(
      'service_record_commissions',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [recordId],
    );
    if (commissionRows.isEmpty) return;
    final mechanics = await txn.query(
      'service_record_mechanics',
      columns: ['employee_sync_id'],
      where: 'service_record_id = ?',
      whereArgs: [recordId],
      orderBy: 'urutan',
    );
    final count = mechanics.length;
    if (count == 0) return;
    final jobRows = await txn.rawQuery(
      '''
      SELECT j.jumlah, j.subtotal,
        COALESCE(j.diskon_alokasi, 0) AS diskon_alokasi,
        COALESCE((SELECT SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000))
          FROM sale_return_items ri
          JOIN sale_returns sr ON sr.id = ri.return_id
          WHERE sr.deleted_at IS NULL AND ri.line_type = 'jasa'
            AND ri.line_sync_id = j.sync_id), 0) AS returned_milli
      FROM service_jobs j WHERE j.service_record_id = ?
      ''',
      [recordId],
    );
    var netJasa = 0;
    for (final row in jobRows) {
      final qtyMilli = ((row['jumlah'] as num?)?.toInt() ?? 0) * 1000;
      final sisaMilli =
          qtyMilli - ((row['returned_milli'] as num?)?.toInt() ?? 0);
      if (qtyMilli <= 0 || sisaMilli <= 0) continue;
      final lineTotal =
          ((row['subtotal'] as num?)?.toInt() ?? 0) -
          ((row['diskon_alokasi'] as num?)?.toInt() ?? 0);
      netJasa += sisaMilli >= qtyMilli
          ? lineTotal
          : lineTotal * sisaMilli ~/ qtyMilli;
    }
    final partRows = await txn.rawQuery(
      '''
      SELECT COALESCE(p.jumlah_milli, p.jumlah * 1000) AS qty_milli,
        p.harga_satuan, p.harga_batas_saat_transaksi AS modal,
        COALESCE(p.diskon_alokasi, 0) AS diskon_alokasi,
        COALESCE((SELECT SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000))
          FROM sale_return_items ri
          JOIN sale_returns sr ON sr.id = ri.return_id
          WHERE sr.deleted_at IS NULL AND ri.line_type = 'part'
            AND ri.line_sync_id = p.sync_id), 0) AS returned_milli
      FROM service_parts p WHERE p.service_record_id = ?
      ''',
      [recordId],
    );
    var netMargin = 0;
    var hasPart = false;
    for (final row in partRows) {
      final qtyMilli = (row['qty_milli'] as num?)?.toInt() ?? 0;
      final sisaMilli =
          qtyMilli - ((row['returned_milli'] as num?)?.toInt() ?? 0);
      if (qtyMilli <= 0 || sisaMilli <= 0) continue;
      hasPart = true;
      final margin =
          ((row['harga_satuan'] as num?)?.toInt() ?? 0) -
          ((row['modal'] as num?)?.toInt() ?? 0);
      final diskon = (row['diskon_alokasi'] as num?)?.toInt() ?? 0;
      // Margin negatif tetap dihitung, sama seperti saat nota dibuat.
      netMargin += margin * sisaMilli ~/ 1000 - diskon * sisaMilli ~/ qtyMilli;
    }
    final recordRows = await txn.query(
      'service_records',
      columns: ['sync_id', 'no_nota', 'commission_snapshot_json'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    final recordSync =
        '${recordRows.isEmpty ? '' : recordRows.first['sync_id'] ?? ''}';
    final noNota =
        '${recordRows.isEmpty ? '' : recordRows.first['no_nota'] ?? ''}';
    Map<String, Object?> rawSnapshot = const {};
    try {
      final decoded = jsonDecode(
        '${recordRows.isEmpty ? '{}' : recordRows.first['commission_snapshot_json'] ?? '{}'}',
      );
      if (decoded is Map) {
        rawSnapshot = decoded.cast<String, Object?>();
      }
    } on FormatException {
      rawSnapshot = const {};
    }
    for (final commission in commissionRows) {
      final employeeSyncId = '${commission['employee_sync_id']}';
      final rawIndex = mechanics.indexWhere(
        (row) => row['employee_sync_id'] == employeeSyncId,
      );
      if (rawIndex < 0) {
        // Mekanik sudah tidak terdaftar: nominal lama dipertahankan dan
        // pemilik diberi tahu alih-alih membagi ulang porsi mekanik lain.
        await _recordCommissionConflict(
          txn,
          recordSync: recordSync,
          noNota: noNota,
          commissionSync: '${commission['sync_id'] ?? ''}',
          employeeSyncId: employeeSyncId,
          reason: 'komisi_akun_hilang',
          detail: {'nominal_dipertahankan': commission['nominal'] ?? 0},
        );
        continue;
      }
      final index = rawIndex;
      Map<String, Object?> snapshot = const {};
      final entry = rawSnapshot[employeeSyncId];
      if (entry is Map) {
        snapshot = entry.cast<String, Object?>();
      }
      // Tanpa snapshot tarif, nominal lama dipertahankan. Menghitung ulang
      // dengan tarif master saat ini akan mengubah komisi yang sudah dijanjikan.
      if (snapshot.isEmpty) {
        await _recordCommissionConflict(
          txn,
          recordSync: recordSync,
          noNota: noNota,
          commissionSync: '${commission['sync_id'] ?? ''}',
          employeeSyncId: employeeSyncId,
          reason: 'komisi_tanpa_snapshot',
          detail: {'nominal_dipertahankan': commission['nominal'] ?? 0},
        );
        continue;
      }
      final mode = '${snapshot['mode'] ?? 'PERSEN'}';
      final barangNilai = (snapshot['barang'] as num?)?.toInt() ?? 0;
      final jasaNilai = (snapshot['jasa'] as num?)?.toInt() ?? 0;
      final shareJasa = _splitShare(netJasa, index, count);
      final shareMargin = _splitShare(netMargin, index, count);
      final nominal = mode == 'NOMINAL'
          ? (hasPart ? barangNilai : 0) + (netJasa > 0 ? jasaNilai : 0)
          : (shareJasa * jasaNilai) ~/ 100 + (shareMargin * barangNilai) ~/ 100;
      if (nominal == ((commission['nominal'] as num?)?.toInt() ?? 0)) {
        continue;
      }
      final hlc = await nextSyncHlc(txn);
      await txn.update(
        'service_record_commissions',
        {
          'nominal': nominal,
          'dasar_jasa': shareJasa,
          'dasar_barang': shareMargin,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [commission['id']],
      );
      if (enqueueCommission != null) {
        await enqueueCommission(txn, commission['id'] as int);
      }
    }
  }

  Future<void> _recordCommissionConflict(
    DatabaseExecutor txn, {
    required String recordSync,
    required String noNota,
    required String commissionSync,
    required String employeeSyncId,
    required String reason,
    required Map<String, Object?> detail,
  }) async {
    if (recordSync.isNotEmpty) {
      final existing = await txn.query(
        'sync_conflicts',
        columns: ['id'],
        where: "entity = 'nota' AND entity_id = ? AND reason = ? "
            "AND status IN ('open', 'review')",
        whereArgs: [recordSync, reason],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
    }
    await txn.insert('sync_conflicts', {
      'entity': 'nota',
      'entity_id': recordSync,
      'reason': reason,
      'detail_json': jsonEncode({
        'no_nota': noNota,
        'commission_sync_id': commissionSync,
        'employee_sync_id': employeeSyncId,
        ...detail,
      }),
      'status': 'review',
      'retry_count': 0,
      'last_error': '',
      'created_at': nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Ekspresi SQL total efektif nota: `nilai_baru` koreksi terakhir menurut
  /// HLC, atau nilai cadangan bila belum ada koreksi.
  static String latestAdjustmentTotalSql({
    required String notaSyncIdExpr,
    required String fallbackExpr,
  }) =>
      '''
COALESCE(
  (SELECT a.nilai_baru FROM nota_adjustments a
    WHERE a.nota_sync_id = $notaSyncIdExpr AND a.deleted_at IS NULL
    ORDER BY a.sync_hlc_wall DESC, a.sync_hlc_counter DESC, a.id DESC
    LIMIT 1),
  $fallbackExpr)''';

  /// Join ke koreksi terakhir menurut HLC, sehingga komponen Jasa/Part/Diskon
  /// yang ditampilkan dapat direkonsiliasi dengan total efektif.
  static const String latestAdjustmentJoinSql = '''
LEFT JOIN nota_adjustments adj ON adj.id = (
  SELECT a.id FROM nota_adjustments a
  WHERE a.nota_sync_id = r.sync_id AND a.deleted_at IS NULL
  ORDER BY a.sync_hlc_wall DESC, a.sync_hlc_counter DESC, a.id DESC
  LIMIT 1
)''';

  /// Ekspresi SQL modal nota: jasa memakai qty bulat, part memakai milli.
  /// Urutan parameter: `recordId` untuk jasa, lalu `recordId` untuk part.
  static const String recordModalSql = '''
COALESCE((SELECT SUM(harga_batas_saat_transaksi * jumlah)
  FROM service_jobs WHERE service_record_id = ?), 0) +
COALESCE((SELECT ROUND(SUM(harga_batas_saat_transaksi *
  COALESCE(jumlah_milli, jumlah * 1000) / 1000.0))
  FROM service_parts WHERE service_record_id = ?), 0)''';

  /// Menghitung sisa tagihan dari pembayaran, retur, dan koreksi tersimpan.
  ///
  /// Nilai retur dianggap pertama-tama menghapus piutang; bila sudah lunas,
  /// selisihnya menjadi uang keluar (baris pembayaran `REFUND` bernilai
  /// negatif) sehingga rumus yang sama berlaku di semua perangkat.
  Future<void> recalculateRecordTotals(
    DatabaseExecutor txn,
    int recordId,
  ) async {
    final record = await txn.query(
      'service_records',
      columns: ['sync_id', 'no_nota', 'total_servis', 'status', 'voided_at'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (record.isEmpty) return;
    if (record.first['voided_at'] != null ||
        '${record.first['status']}' == 'VOID') {
      return;
    }
    final paidRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
      'WHERE service_record_id = ?',
      [recordId],
    );
    final returnRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(total), 0) AS total FROM sale_returns '
      'WHERE service_record_id = ? AND deleted_at IS NULL',
      [recordId],
    );
    // Koreksi bersifat absolut: ambil nilai_baru terakhir menurut HLC, bukan
    // jumlahkan selisih yang bisa terhitung ganda saat dua perangkat koreksi
    // bersamaan.
    final adjustmentRows = await txn.rawQuery(
      '''
      SELECT ${latestAdjustmentTotalSql(notaSyncIdExpr: 'r.sync_id', fallbackExpr: 'r.total_servis')} - r.total_servis AS total
      FROM service_records r WHERE r.id = ?
      ''',
      [recordId],
    );
    final total = (record.first['total_servis'] as num?)?.toInt() ?? 0;
    final paid = (paidRows.first['total'] as num?)?.toInt() ?? 0;
    final retur = (returnRows.first['total'] as num?)?.toInt() ?? 0;
    final adjustment = (adjustmentRows.first['total'] as num?)?.toInt() ?? 0;
    final totalEfektif = max(0, total + adjustment - retur);
    final outstanding = totalEfektif - paid;
    final sisa = outstanding < 0 ? 0 : outstanding;
    await txn.update(
      'service_records',
      {
        'total_dibayar': paid,
        'total_koreksi': adjustment,
        'total_retur': retur,
        'total_efektif': totalEfektif,
        'sisa_bayar': sisa,
        'status_bayar': sisa == 0 ? 'LUNAS' : 'KREDIT',
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
    if (outstanding < 0) {
      // Pembayaran melebihi nilai efektif tidak dibuang (uang sudah diterima),
      // tetapi piutang tidak boleh negatif. Kasus ini dicatat sebagai konflik
      // agar dapat ditinjau pemilik dan tidak terkirim ulang tanpa jejak.
      final recordSync = '${record.first['sync_id'] ?? ''}';
      if (recordSync.isNotEmpty) {
        final existing = await txn.query(
          'sync_conflicts',
          columns: ['id'],
          where: "entity = 'nota' AND entity_id = ? AND reason = ? "
              "AND status IN ('open', 'review')",
          whereArgs: [recordSync, 'pembayaran_melebihi_total'],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('sync_conflicts', {
            'entity': 'nota',
            'entity_id': recordSync,
            'reason': 'pembayaran_melebihi_total',
            'detail_json': jsonEncode({
              'no_nota': record.first['no_nota'],
              'total_efektif': totalEfektif,
              'total_dibayar': paid,
              'kelebihan': -outstanding,
            }),
            'status': 'review',
            'retry_count': 0,
            'last_error': '',
            'created_at': nowIso(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }
  }

  /// Nomor dokumen selalu ada dan unik tanpa koordinasi server.
  ///
  /// Format: `{kodeCabang}{kodePerangkat}-{prefix}{yyyymmdd}-{urutan}`.
  /// Urutan disimpan per perangkat, per jenis, per tanggal sehingga dua
  /// perangkat yang offline bersamaan tidak mungkin menghasilkan nomor sama.
  Future<String> allocateDocumentNumber(
    DatabaseExecutor executor, {
    required String docType,
    required String prefix,
    DateTime? date,
  }) async {
    final tanggal = _dateKey(date ?? DateTime.now());
    final kodePerangkat = await deviceCode(executor);
    final branchCode = await _branchCode(executor);
    final rows = await executor.query(
      'document_counters',
      columns: ['terakhir'],
      where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
      whereArgs: [kodePerangkat, docType, tanggal],
      limit: 1,
    );
    final next = rows.isEmpty ? 1 : (rows.first['terakhir'] as int) + 1;
    if (rows.isEmpty) {
      await executor.insert('document_counters', {
        'device_id': kodePerangkat,
        'doc_type': docType,
        'tanggal': tanggal,
        'terakhir': next,
      });
    } else {
      await executor.update(
        'document_counters',
        {'terakhir': next},
        where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
        whereArgs: [kodePerangkat, docType, tanggal],
      );
    }
    final seq = next.toString().padLeft(4, '0');
    return '$branchCode$kodePerangkat-$prefix$tanggal-$seq';
  }

  Future<String> allocateNextNota(DatabaseExecutor executor) =>
      allocateDocumentNumber(executor, docType: 'nota', prefix: 'N');

  /// Nomor antrian pendek yang direset setiap hari per perangkat.
  Future<String> allocateQueueNumber(
    DatabaseExecutor executor, {
    DateTime? date,
  }) async {
    final tanggal = _dateKey(date ?? DateTime.now());
    final kodePerangkat = await deviceCode(executor);
    final branchCode = await _branchCode(executor);
    final rows = await executor.query(
      'document_counters',
      columns: ['terakhir'],
      where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
      whereArgs: [kodePerangkat, 'antrian', tanggal],
      limit: 1,
    );
    final next = rows.isEmpty ? 1 : (rows.first['terakhir'] as int) + 1;
    if (rows.isEmpty) {
      await executor.insert('document_counters', {
        'device_id': kodePerangkat,
        'doc_type': 'antrian',
        'tanggal': tanggal,
        'terakhir': next,
      });
    } else {
      await executor.update(
        'document_counters',
        {'terakhir': next},
        where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
        whereArgs: [kodePerangkat, 'antrian', tanggal],
      );
    }
    return '$branchCode$kodePerangkat-${next.toString().padLeft(3, '0')}';
  }

  Future<String> deviceCode(DatabaseExecutor executor) async {
    final stored = await executor.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['device.kode_lokal'],
      limit: 1,
    );
    final existing = stored.isEmpty ? '' : '${stored.first['value']}'.trim();
    if (isStrongDeviceCode(existing)) return existing;
    final code = newDeviceCode();
    await executor.insert('app_settings', {
      'key': 'device.kode_lokal',
      'value': code,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return code;
  }

  Future<String> _branchCode(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['toko.kode_cabang'],
      limit: 1,
    );
    final raw = rows.isEmpty ? '' : '${rows.first['value']}'.trim();
    return raw.isEmpty ? 'T' : raw.toUpperCase();
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  Future<
    ({
      bool bergaransi,
      int bulan,
      String? sampai,
      String? catatan,
      bool barangAktif,
      int barangNilai,
      String barangSatuan,
      String? barangSampai,
    })
  >
  _warrantyFields(
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

  Future<void> _requireStatusChange(Operator? actor) async {
    if (actor == null || actor.isOwner) return;
    final settings = await StoreSettingsService.instance.ensure();
    if (!settings.roleAllows(actor.role, 'ubah_status')) {
      throw StateError(
        'Peran ${actor.role} tidak berhak mengubah status nota.',
      );
    }
  }

  /// Klaim garansi hanya sekali; update bersyarat menjaga dua klaim paralel.
  Future<void> claimWarranty(
    int recordId, {
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    await _requireStatusChange(actor);
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
        'sync_id': newSyncId(),
        'actor': actor!.label,
        'target_account_id': actor.employeeId,
        'action': 'klaim garansi',
        'detail_json': jsonEncode({
          'record_id': recordId,
          'tanggal': dateOnly.format(today),
        }),
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, recordId);
    });
  }

  Future<void> markUnitTaken(
    int recordId, {
    required bool diambil,
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
  }) async {
    await _requireStatusChange(actor);
    await db.transaction((txn) async {
      final rows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Nota tidak ditemukan.');
      final record = rows.first;
      if (record['unit_ditinggal'] != 1) {
        throw StateError('Nota ini tidak ditandai unit ditinggal.');
      }
      if (record['voided_at'] != null || record['status'] == 'VOID') {
        throw StateError('Nota yang dibatalkan tidak dapat diambil unitnya.');
      }
      if (diambil) {
        final sisa = (record['sisa_bayar'] as num?)?.toInt() ?? 0;
        if (sisa > 0) {
          throw StateError(
            'Unit belum bisa diambil selama masih ada sisa tagihan.',
          );
        }
      }
      await txn.update(
        'service_records',
        {'diambil_at': diambil ? nowIso() : null, 'updated_at': nowIso()},
        where: 'id = ?',
        whereArgs: [recordId],
      );
      if (enqueue != null) await enqueue(txn, recordId);
    });
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
    final rows = await db.rawQuery('''
      SELECT r.*, c.nama AS customer_nama,
        adj.nominal_jasa AS koreksi_jasa,
        adj.nominal_part AS koreksi_part,
        adj.diskon AS koreksi_diskon,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      LEFT JOIN vehicle_or_units u ON u.id = r.unit_id
      LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)
      ${AppDatabase.latestAdjustmentJoinSql}
      WHERE $where
      ORDER BY r.waktu_service DESC
      LIMIT ? OFFSET ?
      ''', args);
    return rows.map(ServiceRecordSummary.fromRow).toList();
  }

  Future<RecordDetail?> recordDetail(int id) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.nama AS customer_nama,
        adj.nominal_jasa AS koreksi_jasa,
        adj.nominal_part AS koreksi_part,
        adj.diskon AS koreksi_diskon,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      LEFT JOIN vehicle_or_units u ON u.id = r.unit_id
      LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)
      ${AppDatabase.latestAdjustmentJoinSql}
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
    final correctionRows = await db.query(
      'nota_adjustments',
      where: 'nota_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [row['sync_id']],
      orderBy: 'created_at',
    );
    final returnRows = await db.query(
      'sale_returns',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'created_at DESC',
    );
    final returns = <SaleReturnRow>[];
    for (final returnRow in returnRows) {
      final itemRows = await db.query(
        'sale_return_items',
        where: 'return_id = ? AND deleted_at IS NULL',
        whereArgs: [returnRow['id']],
        orderBy: 'id',
      );
      returns.add(
        SaleReturnRow.fromRow(
          returnRow,
          items: itemRows
              .map(
                (item) => SaleReturnItemRow(
                  lineType: item['line_type'] as String? ?? 'part',
                  lineSyncId: item['line_sync_id'] as String? ?? '',
                  deskripsi: item['deskripsi'] as String? ?? '',
                  jumlah: (item['jumlah'] as num?)?.toInt() ?? 0,
                  hargaSatuanCents:
                      (item['harga_satuan'] as num?)?.toInt() ?? 0,
                  subtotalCents: (item['subtotal'] as num?)?.toInt() ?? 0,
                  qtyMilli: (item['jumlah_milli'] as num?)?.toInt() ?? 0,
                  qtyAsalMilli: (item['qty_asal_milli'] as num?)?.toInt(),
                  modalSatuanCents:
                      (item['modal_satuan'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(),
        ),
      );
    }
    final noNota = row['no_nota'] as String? ?? '';
    return RecordDetail(
      record: ServiceRecordSummary.fromRow(row),
      jobs: jobRows
          .map(
            (item) => JobDraft(
              deskripsi: item['deskripsi'] as String,
              jumlah: item['jumlah'] as int,
              hargaCents: item['harga'] as int,
              jasaId: item['harga_jasa_id'] as int?,
              modalCents: item['harga_batas_saat_transaksi'] as int? ?? 0,
              intervalBulan: item['interval_servis_bulan'] as int? ?? 0,
              syncId: item['sync_id'] as String?,
              hargaTerdaftarCents:
                  item['harga_jual_terdaftar'] as int? ?? item['harga'] as int,
              hargaFinalCents: item['harga_final'] as int? ?? 0,
              diskonAlokasiCents: item['diskon_alokasi'] as int? ?? 0,
              alasanDiskon: item['alasan_diskon'] as String?,
              disetujuiOleh: item['disetujui_oleh'] as String?,
            ),
          )
          .toList(),
      parts: partRows
          .map(
            (item) => PartDraft(
              stockItemId: item['stock_item_id'] as int? ?? 0,
              nama: item['nama_part'] as String,
              jumlah: item['jumlah'] as int,
              qtyMilli: (item['jumlah_milli'] as num?)?.toInt(),
              hargaCents: item['harga_satuan'] as int,
              modalCents:
                  item['harga_batas_saat_transaksi'] as int? ??
                  item['harga_modal'] as int? ??
                  0,
              intervalBulan: item['interval_servis_bulan'] as int? ?? 0,
              syncId: item['sync_id'] as String?,
              hargaTerdaftarCents:
                  item['harga_jual_terdaftar'] as int? ??
                  item['harga_satuan'] as int,
              hargaFinalCents: item['harga_final'] as int? ?? 0,
              diskonAlokasiCents: item['diskon_alokasi'] as int? ?? 0,
              alasanDiskon: item['alasan_diskon'] as String?,
              disetujuiOleh: item['disetujui_oleh'] as String?,
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
      corrections: correctionRows
          .map(
            (item) => CorrectionEntry(
              noNota: noNota,
              waktu:
                  DateTime.tryParse('${item['created_at']}')?.toLocal() ??
                  DateTime.now(),
              alasan: item['alasan'] as String? ?? '',
              nilaiSelisihCents: (item['nilai_selisih'] as num?)?.toInt() ?? 0,
              nilaiBaruCents: (item['nilai_baru'] as num?)?.toInt() ?? 0,
              dibuatOleh: item['dibuat_oleh'] as String?,
              disetujuiOleh: item['disetujui_oleh'] as String?,
            ),
          )
          .toList(),
      returns: returns,
    );
  }

  Future<void> voidRecord(
    int id,
    String reason, {
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int recordId)? enqueuePayment,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueEstimate,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueOrder,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) async {
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan void wajib diisi.');
    }
    final actorValue = _requireActor(actor);
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
      final existingReturns = await txn.query(
        'sale_returns',
        columns: ['id'],
        where: 'service_record_id = ? AND deleted_at IS NULL',
        whereArgs: [id],
        limit: 1,
      );
      if (existingReturns.isNotEmpty) {
        throw StateError(
          'Nota sudah memiliki retur; void tidak dapat dilakukan.',
        );
      }
      final parts = await txn.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [id],
      );
      final now = nowIso();
      for (final part in parts) {
        final stockId = part['stock_item_id'] as int?;
        if (stockId == null) continue;
        final qtyMilli =
            (part['jumlah_milli'] as num?)?.toInt() ??
            ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        // Baris yang sudah diretur stoknya sudah kembali; void hanya boleh
        // mengembalikan sisa yang belum diretur agar stok tidak berlipat.
        final sisaMilli =
            qtyMilli - ((part['qty_retur_milli'] as num?)?.toInt() ?? 0);
        if (sisaMilli <= 0) continue;
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [stockId],
          limit: 1,
        );
        if (stockRows.isEmpty) continue;
        final stock = StockItem.fromRow(stockRows.first);
        final nextMilli = stock.jumlahMilli + sisaMilli;
        final stockHlc = await nextSyncHlc(txn);
        await txn.update(
          'stock_items',
          {
            'jumlah': wholeQuantity(nextMilli),
            'jumlah_milli': nextMilli,
            'sync_hlc_wall': stockHlc.wall,
            'sync_hlc_counter': stockHlc.counter,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [stockId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': stockId,
          'stock_sync_id': stockRows.first['sync_id'],
          'nama_item': part['nama_part'],
          'jenis': 'MASUK',
          'jumlah': wholeQuantity(sisaMilli),
          'jumlah_milli': sisaMilli,
          'stok_sebelum_milli': stock.jumlahMilli,
          'stok_sesudah_milli': nextMilli,
          'sumber_entity': 'void',
          'sumber_sync_id': '${part['sync_id']}',
          'service_record_id': id,
          'operator': actorValue.label,
          'alasan': 'Void nota ${rows.first['no_nota']}',
          'sync_hlc_wall': stockHlc.wall,
          'sync_hlc_counter': stockHlc.counter,
          'created_at': now,
          'updated_at': now,
        });
      }
      final payments = await txn.rawQuery(
        'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
        "WHERE service_record_id = ? AND nominal > 0 AND jenis != 'REFUND'",
        [id],
      );
      final paid = (payments.first['total'] as int?) ?? 0;
      final returnRefund = await txn.rawQuery(
        'SELECT COALESCE(SUM(total_refund), 0) AS total FROM sale_returns '
        "WHERE service_record_id = ? AND deleted_at IS NULL AND status = 'AKTIF'",
        [id],
      );
      final alreadyRefund = await txn.rawQuery(
        'SELECT COALESCE(SUM(-nominal), 0) AS total FROM service_payments '
        "WHERE service_record_id = ? AND jenis = 'REFUND'",
        [id],
      );
      final refundedViaReturns =
          (returnRefund.first['total'] as int?) ?? 0;
      final refundedViaPayments =
          (alreadyRefund.first['total'] as int?) ?? 0;
      final sisaRefund = paid - refundedViaReturns - refundedViaPayments;
      if (sisaRefund > 0) {
        final refunded = await txn.query(
          'service_payments',
          where: 'service_record_id = ? AND jenis = ? AND request_id = ?',
          whereArgs: [id, 'REFUND', 'void-${rows.first['sync_id']}'],
          limit: 1,
        );
        if (refunded.isEmpty) {
          final refundSyncId = newSyncId();
          await txn.insert('service_payments', {
            'sync_id': refundSyncId,
            'service_record_id': id,
            'jenis': 'REFUND',
            'metode': rows.first['metode_bayar'] ?? 'CASH',
            'nominal': -sisaRefund,
            'waktu': now,
            'operator': actorValue.label,
            'request_id': 'void-${rows.first['sync_id']}',
            'kas_kategori': 'REFUND',
            'catatan': cleanReason,
            'created_at': now,
            'updated_at': now,
          });
          await txn.insert('cash_ledger', {
            'sync_id': newSyncId(),
            'waktu': now,
            'kategori': 'REFUND',
            'sumber_entity': 'service_payment',
            'sumber_sync_id': refundSyncId,
            'nominal': -sisaRefund,
            'metode': rows.first['metode_bayar'] ?? 'CASH',
            'operator': actorValue.label,
            'catatan': 'Void ${rows.first['no_nota']}',
            'created_at': now,
            'updated_at': now,
          });
          // Perangkat lain hanya menyamakan status saat void, jadi REFUND
          // dikirim sebagai amplop pembayaran agar tidak hilang dari kas.
          if (enqueuePayment != null) await enqueuePayment(txn, id);
        }
      }
      final netPaid = await txn.rawQuery(
        'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
        'WHERE service_record_id = ?',
        [id],
      );
      final netPaidTotal = (netPaid.first['total'] as num?)?.toInt() ?? 0;
      await txn.update(
        'service_records',
        {
          'status': 'VOID',
          'voided_at': now,
          'void_reason': cleanReason,
          'sisa_bayar': 0,
          'total_dibayar': netPaidTotal < 0 ? 0 : netPaidTotal,
          'total_efektif': 0,
          'total_kas_diterima': 0,
          'void_refund': sisaRefund > 0 ? sisaRefund : 0,
          'version': ((rows.first['version'] as num?)?.toInt() ?? 1) + 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      final commissionRows = await txn.query(
        'service_record_commissions',
        columns: ['id'],
        where: "service_record_id = ? AND status = 'AKTIF'",
        whereArgs: [id],
      );
      for (final commission in commissionRows) {
        final hlc = await nextSyncHlc(txn);
        await txn.update(
          'service_record_commissions',
          {
            'status': 'VOID',
            'nominal': 0,
            'voided_at': now,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [commission['id']],
        );
        if (enqueueCommission != null) {
          await enqueueCommission(txn, commission['id'] as int);
        }
      }
      final recordSyncId = rows.first['sync_id'] as String? ?? '';
      final estimateSync =
          (rows.first['estimate_sync_id'] as String?)?.trim() ?? '';
      if (estimateSync.isNotEmpty) {
        final hlc = await nextSyncHlc(txn);
        final reopened = await txn.update(
          'estimates',
          {
            'status': 'aktif',
            'converted_nota_sync_id': null,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': now,
          },
          where: 'sync_id = ? AND converted_nota_sync_id = ?',
          whereArgs: [estimateSync, recordSyncId],
        );
        if (reopened > 0 && enqueueEstimate != null) {
          await enqueueEstimate(txn, estimateSync);
        }
      }
      final orderSync =
          (rows.first['work_order_sync_id'] as String?)?.trim() ?? '';
      if (orderSync.isNotEmpty) {
        final hlc = await nextSyncHlc(txn);
        final cleared = await txn.update(
          'work_orders',
          {
            'nota_sync_id': null,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': now,
          },
          where: 'sync_id = ? AND nota_sync_id = ?',
          whereArgs: [orderSync, recordSyncId],
        );
        if (cleared > 0 && enqueueOrder != null) {
          await enqueueOrder(txn, orderSync);
        }
      }
      await txn.insert('permission_audits', {
        'sync_id': newSyncId(),
        'actor': actorValue.label,
        'target_account_id': actorValue.employeeId,
        'action': 'void',
        'detail_json': jsonEncode({
          'no_nota': rows.first['no_nota'],
          'alasan': cleanReason,
        }),
        'created_at': now,
        'updated_at': now,
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
    final actorValue = _requireActor(actor);
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
      final cleanRequest = (requestId ?? '').trim();
      if (cleanRequest.isNotEmpty) {
        final existing = await txn.query(
          'service_payments',
          columns: ['sync_id'],
          where: 'request_id = ?',
          whereArgs: [cleanRequest],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          return {
            'payment_sync_id': existing.first['sync_id'],
            'sisa_bayar': record['sisa_bayar'] as int? ?? 0,
            'status_bayar': record['status_bayar'],
            'total_dibayar': record['total_dibayar'] as int? ?? 0,
            'duplicate': true,
          };
        }
      }
      final totalEfektif =
          (record['total_efektif'] as num?)?.toInt() ??
          (record['total_servis'] as num?)?.toInt() ??
          0;
      // Sisa dihitung ulang dari seluruh pembayaran yang tersimpan, bukan dari
      // kolom ringkasan yang bisa tertinggal setelah sinkronisasi.
      final paidRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
        'WHERE service_record_id = ?',
        [recordId],
      );
      final dibayarSebelum = (paidRows.first['total'] as num?)?.toInt() ?? 0;
      final sisa = max(0, totalEfektif - dibayarSebelum);
      if (sisa <= 0) throw StateError('Nota ini tidak memiliki sisa piutang.');
      if (nominalCents > sisa) {
        throw ArgumentError('Nominal pelunasan melebihi sisa piutang.');
      }
      final now = nowIso();
      final paymentSyncId = newSyncId();
      await txn.insert('service_payments', {
        'sync_id': paymentSyncId,
        'service_record_id': recordId,
        'jenis': nominalCents >= sisa ? 'PELUNASAN' : 'DP',
        'metode': metode,
        'nominal': nominalCents,
        'waktu': now,
        'operator': actorValue.label,
        'request_id': cleanRequest.isEmpty ? newSyncId() : cleanRequest,
        'kas_kategori': 'PENJUALAN',
        'catatan': 'Pelunasan piutang',
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('cash_ledger', {
        'sync_id': newSyncId(),
        'waktu': now,
        'kategori': 'PENJUALAN',
        'sumber_entity': 'service_payment',
        'sumber_sync_id': paymentSyncId,
        'nominal': nominalCents,
        'metode': metode,
        'operator': actorValue.label,
        'catatan': 'Pelunasan ${record['no_nota'] ?? ''}',
        'created_at': now,
        'updated_at': now,
      });
      await txn.update(
        'service_records',
        {
          'total_kas_diterima':
              ((record['total_kas_diterima'] as num?)?.toInt() ?? 0) +
              nominalCents,
          'version': ((record['version'] as num?)?.toInt() ?? 1) + 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [recordId],
      );
      // Ringkasan pembayaran selalu dihitung ulang dari ledger pembayaran.
      await recalculateRecordTotals(txn, recordId);
      final updated = await txn.query(
        'service_records',
        columns: ['sisa_bayar', 'status_bayar', 'total_dibayar'],
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      final summary = updated.isEmpty
          ? const <String, Object?>{}
          : updated.first;
      final newSisa =
          (summary['sisa_bayar'] as num?)?.toInt() ?? sisa - nominalCents;
      if (enqueue != null) await enqueue(txn, recordId);
      return {
        'payment_sync_id': paymentSyncId,
        'sisa_bayar': newSisa,
        'status_bayar':
            summary['status_bayar'] ?? (newSisa == 0 ? 'LUNAS' : 'KREDIT'),
        'total_dibayar': (summary['total_dibayar'] as num?)?.toInt() ??
            dibayarSebelum + nominalCents,
      };
    });
  }

  Future<ReportSummary> reportSummary(DateTime from, DateTime to) async {
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS transaksi,
        COALESCE(SUM(r.biaya_jasa + COALESCE(adj.nominal_jasa, 0)), 0)
          AS total_jasa,
        COALESCE(SUM(r.total_part + COALESCE(adj.nominal_part, 0)), 0)
          AS total_part,
        COALESCE(SUM(r.diskon + COALESCE(adj.diskon, 0)), 0) AS diskon,
        COALESCE(SUM(r.total_efektif + r.total_retur), 0) AS total,
        COALESCE(SUM(r.total_dibayar), 0) AS dibayar,
        COALESCE(SUM(r.sisa_bayar), 0) AS piutang
      FROM service_records r
      ${AppDatabase.latestAdjustmentJoinSql}
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final row = rows.first;
    final parts = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(sp.subtotal - COALESCE(sp.diskon_alokasi, 0)), 0)
          AS omzet,
        COALESCE(SUM(ROUND(sp.harga_modal *
          COALESCE(sp.jumlah_milli, sp.jumlah * 1000) / 1000.0)), 0) AS modal
      FROM service_parts sp
      JOIN service_records r ON r.id = sp.service_record_id
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final jobs = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(sj.subtotal - COALESCE(sj.diskon_alokasi, 0)), 0)
          AS omzet,
        COALESCE(SUM(sj.harga_batas_saat_transaksi * sj.jumlah), 0) AS modal
      FROM service_jobs sj
      JOIN service_records r ON r.id = sj.service_record_id
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
    final typeRows = await db.rawQuery(
      '''
      SELECT r.jenis_transaksi, COUNT(*) AS jumlah,
        COALESCE(SUM(r.total_efektif + r.total_retur), 0) AS total
      FROM service_records r
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
      GROUP BY r.jenis_transaksi
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final omzetPart = (parts.first['omzet'] as num?)?.toInt() ?? 0;
    final modalPart = (parts.first['modal'] as num?)?.toInt() ?? 0;
    final omzetJasa = (jobs.first['omzet'] as num?)?.toInt() ?? 0;
    final modalJasa = (jobs.first['modal'] as num?)?.toInt() ?? 0;
    final returnRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN i.line_type = 'jasa'
          THEN i.subtotal ELSE 0 END), 0) AS retur_jasa,
        COALESCE(SUM(CASE WHEN i.line_type = 'part'
          THEN i.subtotal ELSE 0 END), 0) AS retur_part,
        COALESCE(SUM(CASE WHEN i.line_type = 'part'
          THEN ROUND(i.modal_satuan *
            COALESCE(i.jumlah_milli, i.jumlah * 1000) / 1000.0)
          ELSE 0 END), 0) AS retur_modal
      FROM sale_return_items i
      JOIN sale_returns r ON r.id = i.return_id
      WHERE r.created_at BETWEEN ? AND ?
        AND r.deleted_at IS NULL AND i.deleted_at IS NULL
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final returRow = returnRows.first;
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
      totalModalJasaCents: modalJasa,
      labaKotorJasaCents: omzetJasa - modalJasa,
      komisiCents: commissionRows.first['total'] as int? ?? 0,
      gajiCents: salaryRows.first['total'] as int? ?? 0,
      cashByMethod: {
        for (final cash in cashRows)
          (cash['metode'] as String? ?? 'CASH'): cash['total'] as int? ?? 0,
      },
      countByType: {
        for (final type in typeRows)
          (type['jenis_transaksi'] as String? ?? 'servis_langsung'):
              (type['jumlah'] as num?)?.toInt() ?? 0,
      },
      totalByType: {
        for (final type in typeRows)
          (type['jenis_transaksi'] as String? ?? 'servis_langsung'):
              (type['total'] as num?)?.toInt() ?? 0,
      },
      returJasaCents: (returRow['retur_jasa'] as num?)?.toInt() ?? 0,
      returPartCents: (returRow['retur_part'] as num?)?.toInt() ?? 0,
      returModalCents: (returRow['retur_modal'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<BelowPriceSale>> belowPriceSales(
    DateTime from,
    DateTime to, {
    int limit = 200,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.no_nota, r.waktu_service, r.jenis_transaksi, r.created_by,
        j.deskripsi, j.jumlah, j.jumlah * 1000 AS qty_milli,
        j.harga_jual_terdaftar, j.harga_final,
        j.disetujui_oleh
      FROM service_jobs j
      JOIN service_records r ON r.id = j.service_record_id
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
        AND j.harga_final < j.harga_jual_terdaftar
      UNION ALL
      SELECT r.no_nota, r.waktu_service, r.jenis_transaksi, r.created_by,
        p.nama_part, p.jumlah,
        COALESCE(p.jumlah_milli, p.jumlah * 1000) AS qty_milli,
        p.harga_jual_terdaftar, p.harga_final,
        p.disetujui_oleh
      FROM service_parts p
      JOIN service_records r ON r.id = p.service_record_id
      WHERE r.waktu_service BETWEEN ? AND ? AND r.status != 'VOID'
        AND p.harga_final < p.harga_jual_terdaftar
      ORDER BY waktu_service DESC
      LIMIT ?
      ''',
      [
        isoStartOfDay(from),
        isoEndOfDay(to),
        isoStartOfDay(from),
        isoEndOfDay(to),
        limit,
      ],
    );
    return rows
        .map(
          (row) => BelowPriceSale(
            noNota: row['no_nota'] as String? ?? '',
            waktu:
                DateTime.tryParse('${row['waktu_service']}')?.toLocal() ??
                DateTime.now(),
            jenis: row['jenis_transaksi'] as String? ?? '',
            deskripsi: row['deskripsi'] as String? ?? '',
            jumlah: (row['jumlah'] as num?)?.toInt() ?? 0,
            qtyMilli: (row['qty_milli'] as num?)?.toInt() ?? 0,
            hargaTerdaftarCents:
                (row['harga_jual_terdaftar'] as num?)?.toInt() ?? 0,
            hargaFinalCents: (row['harga_final'] as num?)?.toInt() ?? 0,
            kasir: row['created_by'] as String?,
            disetujuiOleh: row['disetujui_oleh'] as String?,
          ),
        )
        .toList();
  }

  Future<List<CorrectionEntry>> correctionsInRange(
    DateTime from,
    DateTime to, {
    int limit = 200,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.no_nota, a.created_at, a.alasan, a.nilai_selisih,
        a.nilai_baru, a.dibuat_oleh, a.disetujui_oleh
      FROM nota_adjustments a
      JOIN service_records r ON r.sync_id = a.nota_sync_id
      WHERE a.deleted_at IS NULL
        AND a.created_at BETWEEN ? AND ?
      ORDER BY a.created_at DESC
      LIMIT ?
      ''',
      [isoStartOfDay(from), isoEndOfDay(to), limit],
    );
    return rows
        .map(
          (row) => CorrectionEntry(
            noNota: row['no_nota'] as String? ?? '',
            waktu:
                DateTime.tryParse('${row['created_at']}')?.toLocal() ??
                DateTime.now(),
            alasan: row['alasan'] as String? ?? '',
            nilaiSelisihCents: (row['nilai_selisih'] as num?)?.toInt() ?? 0,
            nilaiBaruCents: (row['nilai_baru'] as num?)?.toInt() ?? 0,
            dibuatOleh: row['dibuat_oleh'] as String?,
            disetujuiOleh: row['disetujui_oleh'] as String?,
          ),
        )
        .toList();
  }

  Future<List<EstimateAgingRow>> estimateAging(
    DateTime from,
    DateTime to, {
    int limit = 300,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT e.nomor_estimasi, e.total, e.status, e.dibuat_oleh,
        e.masa_berlaku, e.converted_nota_sync_id, r.total_efektif AS nota_total
      FROM estimates e
      LEFT JOIN service_records r ON r.sync_id = e.converted_nota_sync_id
      WHERE e.deleted_at IS NULL
        AND e.created_at BETWEEN ? AND ?
      ORDER BY e.created_at DESC
      LIMIT ?
      ''',
      [isoStartOfDay(from), isoEndOfDay(to), limit],
    );
    return rows
        .map(
          (row) => EstimateAgingRow(
            nomorEstimasi: row['nomor_estimasi'] as String? ?? '',
            totalCents: (row['total'] as num?)?.toInt() ?? 0,
            status: row['status'] as String? ?? 'aktif',
            dibuatOleh: row['dibuat_oleh'] as String?,
            masaBerlaku: DateTime.tryParse('${row['masa_berlaku']}')?.toLocal(),
            convertedNotaSyncId: row['converted_nota_sync_id'] as String?,
            finalNotaCents: (row['nota_total'] as num?)?.toInt(),
          ),
        )
        .toList();
  }

  Future<DashboardData> dashboard() async {
    final today = DateTime.now();
    final summary = await reportSummary(today, today);
    final lowRows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM stock_items '
      'WHERE deleted_at IS NULL '
      'AND COALESCE(jumlah_milli, jumlah * 1000) <= stok_minimum * 1000',
    );
    final receivableRows = await db.rawQuery('''
      SELECT COALESCE(SUM(sisa_bayar), 0) AS total
      FROM service_records
      WHERE status != 'VOID' AND sisa_bayar > 0
      ''');
    final negativeRows = await db.rawQuery('''
      SELECT COUNT(*) AS total FROM (
        SELECT sync_id AS item_id FROM stock_items
         WHERE COALESCE(jumlah_milli, jumlah * 1000) < 0
           AND deleted_at IS NULL
        UNION
        SELECT c.entity_id AS item_id FROM sync_conflicts c
         WHERE c.reason = 'stok_negatif' AND c.resolved_at IS NULL
           AND NOT EXISTS (
             SELECT 1 FROM stock_items s
              WHERE s.sync_id = c.entity_id
                AND COALESCE(s.jumlah_milli, s.jumlah * 1000) < 0
           )
      ) bermasalah
      ''');
    return DashboardData(
      todayRecords: await listRecords(from: today, to: today, limit: 200),
      todayRevenueCents: summary.totalNetCents,
      todayCount: summary.transaksi,
      lowStockCount: lowRows.first['total'] as int? ?? 0,
      receivableCents: receivableRows.first['total'] as int? ?? 0,
      recent: await listRecords(limit: 8),
      negativeStockCount: negativeRows.first['total'] as int? ?? 0,
      todayGrossCents: summary.totalCents,
      todayReturCents: summary.returCents,
      todayCashCents: summary.cashByMethod.values.fold<int>(
        0,
        (sum, value) => sum + value,
      ),
    );
  }

  static String? _nullable(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }

  /// Operasi tulis yang menyentuh uang, stok, atau status nota tidak boleh
  /// dijalankan tanpa identitas operator yang dapat diaudit.
  static Operator _requireActor(Operator? actor) {
    if (actor == null) {
      throw StateError('Operator wajib diisi untuk operasi ini.');
    }
    if (actor.isViewer) {
      throw StateError('Mode ringkasan hanya dapat membaca data.');
    }
    return actor;
  }

  /// Kunci pencarian nama pelanggan agar duplikat dapat dicek tanpa
  /// bergantung pada kapitalisasi atau spasi berlebih.
  static String _nameKey(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
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
