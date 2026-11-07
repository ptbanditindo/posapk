import 'dart:convert';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart'
    as platform;
import 'secure_store.dart';
import 'store_registry.dart';

const int _maxRestoredDatabaseBytes = 512 * 1024 * 1024;
const int _maxManifestBytes = 1024 * 1024;
const int _maxTelegramBytes = 50 * 1024 * 1024;
const int _keepAutoBackups = 30;
const int _backupFormat = 3;
const int _singleStoreFormat = 2;
const int _backupPbkdf2Iterations = 210000;
const int _aesTagLength = 16;
const String _telegramTokenKey = 'backup.telegram.token';
const String _autoPassphraseKey = 'backup.auto_passphrase';
const Duration telegramRetryInterval = Duration(minutes: 10);
const List<String> _requiredRestoreTables = [
  'app_settings',
  'customers',
  'vehicle_or_units',
  'stock_items',
  'service_records',
];

class BackupResult {
  const BackupResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class BackupSettings {
  const BackupSettings({
    required this.autoEnabled,
    required this.jam,
    required this.telegramEnabled,
    required this.telegramChatId,
    required this.telegramTokenConfigured,
  });

  final bool autoEnabled;
  final String jam;
  final bool telegramEnabled;
  final String telegramChatId;
  final bool telegramTokenConfigured;

  bool get telegramReady =>
      telegramEnabled &&
      telegramChatId.trim().isNotEmpty &&
      telegramTokenConfigured;
}

class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  String? _normalizeTime(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!) ?? -1;
    final minute = int.tryParse(match.group(2)!) ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  Future<BackupSettings> loadSettings() async {
    final db = AppDatabase.instance;
    final auto = await db.getSetting('backup.auto_enabled') ?? '1';
    final jam =
        _normalizeTime(await db.getSetting('backup.jam') ?? '') ?? '02:00';
    final telegram = await db.getSetting('backup.telegram_enabled') ?? '0';
    final chat = await db.getSetting('backup.telegram_chat') ?? '';
    final token = await SecureStore.instance.read(_telegramTokenKey) ?? '';
    return BackupSettings(
      autoEnabled: auto == '1',
      jam: jam,
      telegramEnabled: telegram == '1',
      telegramChatId: chat,
      telegramTokenConfigured: token.trim().isNotEmpty,
    );
  }

  Future<void> saveSettings({
    required bool autoEnabled,
    required String jam,
    required bool telegramEnabled,
    required String telegramChatId,
    String? telegramToken,
    bool clearTelegramToken = false,
    String? autoPassphrase,
  }) async {
    final normalized = _normalizeTime(jam);
    if (normalized == null) {
      throw ArgumentError('Jam backup harus memakai format HH:MM.');
    }
    final db = AppDatabase.instance;
    await db.setSetting('backup.auto_enabled', autoEnabled ? '1' : '0');
    await db.setSetting('backup.jam', normalized);
    await db.setSetting('backup.telegram_enabled', telegramEnabled ? '1' : '0');
    await db.setSetting('backup.telegram_chat', telegramChatId.trim());
    if (clearTelegramToken) {
      await SecureStore.instance.delete(_telegramTokenKey);
    } else if (telegramToken != null && telegramToken.trim().isNotEmpty) {
      await SecureStore.instance.write(_telegramTokenKey, telegramToken.trim());
    }
    final passphraseValue = autoPassphrase?.trim() ?? '';
    if (passphraseValue.isNotEmpty) {
      await setAutoPassphrase(passphraseValue);
    }
    if (telegramEnabled) {
      // Arsip yang diunggah ke Telegram wajib punya kunci yang dapat
      // ditampilkan ke pemilik; buat otomatis bila belum ada.
      await _autoPassphrase();
    }
  }

  Future<Map<String, String?>> status() async {
    final db = AppDatabase.instance;
    var folder = '';
    if (!kIsWeb) {
      try {
        folder = await platform.autoBackupFolder();
      } catch (_) {
        folder = '';
      }
    }
    return {
      'auto_enabled': await db.getSetting('backup.auto_enabled') ?? '1',
      'jam': await db.getSetting('backup.jam') ?? '02:00',
      'telegram_enabled': await db.getSetting('backup.telegram_enabled') ?? '0',
      'last_local_at': await db.getSetting('backup.last_local_at'),
      'last_local_file': await db.getSetting('backup.last_local_file'),
      'last_telegram_at': await db.getSetting('backup.last_telegram_at'),
      'last_attempt_at': await db.getSetting('backup.last_attempt_at'),
      'last_status': await db.getSetting('backup.last_status'),
      'last_error': await db.getSetting('backup.last_error'),
      'telegram_error': await db.getSetting('backup.telegram_error'),
      'telegram_pending': await db.getSetting('backup.telegram_pending') ?? '0',
      'folder': folder,
    };
  }

  Future<DateTime?> lastLocalAt() async => DateTime.tryParse(
    await AppDatabase.instance.getSetting('backup.last_local_at') ?? '',
  );

  Future<DateTime?> lastAttemptAt() async => DateTime.tryParse(
    await AppDatabase.instance.getSetting('backup.last_attempt_at') ?? '',
  );

  Future<bool> telegramPending() async =>
      (await AppDatabase.instance.getSetting('backup.telegram_pending') ??
          '0') ==
      '1';

  Future<String?> autoBackupFolder() async {
    if (kIsWeb) return null;
    try {
      return await platform.autoBackupFolder();
    } catch (_) {
      return null;
    }
  }

  /// Passphrase backup otomatis. Disimpan di penyimpanan aman dan dapat
  /// ditampilkan ke pemilik; tanpa ini arsip Telegram tidak bisa dipulihkan
  /// setelah aplikasi dipasang ulang atau pindah perangkat.
  Future<String> autoPassphrase() => _autoPassphrase();

  Future<void> setAutoPassphrase(String value) async {
    final clean = value.trim();
    if (clean.length < 8) {
      throw ArgumentError('Passphrase backup minimal 8 karakter.');
    }
    await SecureStore.instance.write(_autoPassphraseKey, clean);
  }

  Future<String> _autoPassphrase() async {
    final existing = await SecureStore.instance.read(_autoPassphraseKey);
    if (existing != null && existing.trim().length >= 8) return existing;
    final random = Random.secure();
    final key = base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await SecureStore.instance.write(_autoPassphraseKey, key);
    return key;
  }

  Future<List<int>> _deriveKey(
    String passphrase,
    List<int> salt, {
    int iterations = _backupPbkdf2Iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    return key.extractBytes();
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<({List<int> bytes, Map<String, Object?> meta})> _encryptPayload(
    List<int> plain,
    String passphrase,
    String scope,
  ) async {
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt);
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return (
      bytes: <int>[...box.cipherText, ...box.mac.bytes],
      meta: <String, Object?>{
        'alg': 'AES-256-GCM',
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': _backupPbkdf2Iterations,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'scope': scope,
      },
    );
  }

  Future<List<int>> _decryptPayload(
    List<int> raw,
    Map<String, dynamic> meta,
    String passphrase,
  ) async {
    if (raw.length <= _aesTagLength) {
      throw StateError('Isi backup terlalu pendek.');
    }
    final iterations =
        (meta['iterations'] as num?)?.toInt() ?? _backupPbkdf2Iterations;
    final key = await _deriveKey(
      passphrase,
      base64Decode('${meta['salt']}'),
      iterations: iterations,
    );
    final box = SecretBox(
      raw.sublist(0, raw.length - _aesTagLength),
      nonce: base64Decode('${meta['nonce']}'),
      mac: Mac(raw.sublist(raw.length - _aesTagLength)),
    );
    return AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key));
  }

  /// Membaca salinan SQLite polos; pada perangkat SQLCipher salinan dibuat
  /// lewat `sqlcipher_export` sehingga tidak terikat kunci perangkat.
  Future<List<int>> _exportPlainDatabase() async {
    final db = AppDatabase.instance;
    if (!db.databaseEncrypted) {
      await db.exportPortableCopy(db.databasePath);
      return platform.readDatabase(db.databasePath);
    }
    final temp = await platform.temporaryPath(
      'pusatkupos_export_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    try {
      await platform.deleteFile(temp);
      await db.exportPortableCopy(temp);
      return await platform.readFile(temp);
    } finally {
      await platform.deleteFile(temp);
    }
  }

  Future<Uint8List> _buildArchive({
    required String passphrase,
    required String scope,
  }) async {
    final db = AppDatabase.instance;
    final stores = await _storesForBackup();
    final archive = Archive();
    final manifestStores = <Map<String, Object?>>[];
    var totalBytes = 0;
    for (var index = 0; index < stores.length; index++) {
      final store = stores[index];
      if (!await platform.fileExists(store.databasePath)) {
        throw StateError('Berkas toko ${store.nama} tidak ditemukan.');
      }
      final plain = await _exportStorePlain(store);
      if (plain.length > _maxRestoredDatabaseBytes) {
        throw StateError('Database toko ${store.nama} melebihi batas 512 MB.');
      }
      totalBytes += plain.length;
      if (totalBytes > _maxRestoredDatabaseBytes) {
        throw StateError('Total database semua toko melebihi batas 512 MB.');
      }
      final checksum = sha256.convert(plain).toString();
      final encrypted = await _encryptPayload(plain, passphrase, scope);
      final payloadName = 'stores/$index.db.enc';
      archive.addFile(
        ArchiveFile(
          payloadName,
          encrypted.bytes.length,
          Uint8List.fromList(encrypted.bytes),
        ),
      );
      manifestStores.add({
        'store_id': store.storeId,
        'database_id': store.databaseId,
        'nama': store.nama,
        'alamat': store.alamat,
        'created_at': store.createdAt,
        'payload': payloadName,
        'sha256': checksum,
        'cipher': encrypted.meta,
      });
    }
    final manifest = jsonEncode({
      'format': _backupFormat,
      'app': 'PusatkuPOS',
      'created_at': nowIso(),
      'active_store_id': db.activeStoreId ?? stores.first.storeId,
      'stores': manifestStores,
    });
    final manifestBytes = utf8.encode(manifest);
    archive.addFile(
      ArchiveFile(
        'manifest.json',
        manifestBytes.length,
        Uint8List.fromList(manifestBytes),
      ),
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<List<StoreRecord>> _storesForBackup() async {
    final db = AppDatabase.instance;
    final fallback = StoreRecord(
      storeId: db.activeStoreId ?? 'utama',
      databaseId: 'utama',
      nama: await db.getSetting('bengkel.nama') ?? 'Toko utama',
      alamat: await db.getSetting('bengkel.alamat') ?? '',
      databasePath: db.databasePath,
      createdAt: nowIso(),
    );
    if (kIsWeb || !StoreRegistry.instance.isOpen) return [fallback];
    try {
      final stores = await StoreRegistry.instance.stores();
      if (stores.isEmpty) return [fallback];
      if (!stores.any((store) => store.storeId == fallback.storeId)) {
        return [...stores, fallback];
      }
      return stores;
    } catch (_) {
      return [fallback];
    }
  }

  Future<List<int>> _exportStorePlain(StoreRecord store) async {
    final db = AppDatabase.instance;
    if (store.databasePath == db.databasePath) {
      return _exportPlainDatabase();
    }
    if (!db.databaseEncrypted) {
      return platform.readFile(store.databasePath);
    }
    final temp = await platform.temporaryPath(
      'pusatkupos_export_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    try {
      await platform.deleteFile(temp);
      await db.exportPlainDatabaseAt(store.databasePath, temp);
      return await platform.readFile(temp);
    } finally {
      await platform.deleteFile(temp);
    }
  }

  String _stamp() => DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .substring(0, 19);

  Future<BackupResult> createBackup({String? passphrase}) async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Backup file tersedia di Android/desktop.',
      );
    }
    final secret = passphrase?.trim() ?? '';
    if (secret.isNotEmpty && secret.length < 8) {
      return const BackupResult(
        ok: false,
        message: 'Passphrase backup minimal 8 karakter.',
      );
    }
    final portable = secret.isNotEmpty;
    try {
      final zip = await _buildArchive(
        passphrase: portable ? secret : await _autoPassphrase(),
        scope: portable ? 'portable' : 'auto',
      );
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Simpan backup PusatkuPOS',
        fileName: 'pusatkupos_backup_${_stamp()}.zip',
        bytes: zip,
        mimeType: 'application/zip',
      );
      if (uri == null) {
        return const BackupResult(ok: false, message: 'Backup dibatalkan.');
      }
      return BackupResult(
        ok: true,
        message: portable
            ? 'Backup tersimpan dan terkunci passphrase.'
            : 'Backup tersimpan. Tanpa passphrase, berkas ini hanya dapat '
                  'dipulihkan di perangkat ini; buat backup manual dengan '
                  'passphrase untuk memindahkan data.',
      );
    } catch (error) {
      return BackupResult(ok: false, message: 'Backup gagal: $error');
    }
  }

  /// Backup harian ke folder aplikasi dan, bila diaktifkan, unggah Telegram.
  Future<BackupResult> createAutomaticBackup() async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Backup otomatis tersedia di Android/desktop.',
      );
    }
    final db = AppDatabase.instance;
    await db.setSetting('backup.last_attempt_at', nowIso());
    try {
      final folder = await platform.autoBackupFolder();
      final zip = await _buildArchive(
        passphrase: await _autoPassphrase(),
        scope: 'auto',
      );
      final filename = 'pusatkupos_${_stamp()}.zip';
      final path = await platform.writeBackupFile(folder, filename, zip);
      await db.setSetting('backup.last_local_at', nowIso());
      await db.setSetting('backup.last_local_file', path);
      await db.setSetting('backup.last_status', 'ok');
      await db.deleteSetting('backup.last_error');
      await _pruneAutoBackups(folder);

      final settings = await loadSettings();
      if (!settings.telegramEnabled) {
        await db.setSetting('backup.telegram_pending', '0');
        return const BackupResult(
          ok: true,
          message: 'Backup otomatis tersimpan.',
        );
      }
      final sent = await _sendTelegramBackup(
        settings: settings,
        bytes: zip,
        filename: filename,
      );
      if (!sent.ok) {
        return BackupResult(
          ok: true,
          message: 'Backup tersimpan. ${sent.message}',
        );
      }
      return const BackupResult(
        ok: true,
        message: 'Backup otomatis tersimpan dan dikirim ke Telegram.',
      );
    } catch (error) {
      final message = 'Backup otomatis gagal: $error';
      await db.setSetting('backup.last_status', 'error');
      await db.setSetting('backup.last_error', '$error');
      return BackupResult(ok: false, message: message);
    }
  }

  /// Kirim ulang berkas lokal terakhir bila unggahan Telegram sebelumnya gagal.
  Future<BackupResult> retryTelegramBackup() async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Backup otomatis tersedia di Android/desktop.',
      );
    }
    final db = AppDatabase.instance;
    final settings = await loadSettings();
    final path = await db.getSetting('backup.last_local_file') ?? '';
    if (!settings.telegramEnabled) {
      return const BackupResult(
        ok: false,
        message: 'Unggah Telegram tidak diaktifkan.',
      );
    }
    if (path.isEmpty || !await platform.fileExists(path)) {
      return createAutomaticBackup();
    }
    final safe = await _isAutoBackupPath(path);
    if (!safe) {
      const message = 'Berkas backup tidak berasal dari folder backup resmi.';
      await db.setSetting('backup.telegram_pending', '1');
      await db.setSetting('backup.telegram_error', message);
      return const BackupResult(ok: false, message: message);
    }
    final bytes = await platform.readFile(path);
    if (bytes.length > _maxTelegramBytes) {
      const message = 'Berkas backup melebihi batas 50 MB Telegram.';
      await db.setSetting('backup.telegram_pending', '1');
      await db.setSetting('backup.telegram_error', message);
      return const BackupResult(ok: false, message: message);
    }
    final filename = path.split(RegExp(r'[/\\]')).last;
    await db.setSetting('backup.last_attempt_at', nowIso());
    return _sendTelegramBackup(
      settings: settings,
      bytes: bytes,
      filename: filename,
    );
  }

  /// Hanya izinkan berkas di folder backup aplikasi dengan pola nama resmi.
  Future<bool> _isAutoBackupPath(String path) async {
    try {
      final folder = await platform.autoBackupFolder();
      final normalizedPath = path.replaceAll('\\', '/');
      final normalizedFolder = folder.replaceAll('\\', '/');
      final name = normalizedPath.split('/').last;
      if (!normalizedPath.startsWith('$normalizedFolder/')) return false;
      return RegExp(r'^pusatkupos_[0-9T\-]+\.zip$').hasMatch(name);
    } catch (_) {
      return false;
    }
  }

  Future<BackupResult> _sendTelegramBackup({
    required BackupSettings settings,
    required List<int> bytes,
    required String filename,
  }) async {
    final db = AppDatabase.instance;
    if (!settings.telegramReady) {
      const message = 'Telegram belum siap: isi chat ID dan bot token.';
      await db.setSetting('backup.telegram_pending', '1');
      await db.setSetting('backup.telegram_error', message);
      return const BackupResult(ok: false, message: message);
    }
    if (bytes.length > _maxTelegramBytes) {
      const message = 'Berkas backup melebihi batas 50 MB Telegram.';
      await db.setSetting('backup.telegram_pending', '1');
      await db.setSetting('backup.telegram_error', message);
      return const BackupResult(ok: false, message: message);
    }
    final token = await SecureStore.instance.read(_telegramTokenKey) ?? '';
    final storeName = await db.getSetting('bengkel.nama') ?? 'PusatkuPOS';
    final caption =
        '$storeName · ${DateTime.now().toIso8601String().substring(0, 10)} · '
        'arsip terkunci passphrase backup';
    try {
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://api.telegram.org/bot$token/sendDocument'),
            )
            ..fields['chat_id'] = settings.telegramChatId.trim()
            ..fields['caption'] = caption
            ..files.add(
              http.MultipartFile.fromBytes(
                'document',
                bytes,
                filename: filename,
              ),
            );
      final streamed = await request.send().timeout(
        const Duration(seconds: 90),
      );
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        String detail = 'HTTP ${response.statusCode}';
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['description'] is String) {
            detail = body['description'] as String;
          }
        } catch (_) {
          // Pesan server tidak wajib JSON.
        }
        throw StateError(_scrubToken(detail, token));
      }
      await db.setSetting('backup.last_telegram_at', nowIso());
      await db.setSetting('backup.telegram_pending', '0');
      await db.deleteSetting('backup.telegram_error');
      return const BackupResult(
        ok: true,
        message: 'Backup dikirim ke Telegram.',
      );
    } catch (error) {
      final message = _scrubToken('$error', token);
      await db.setSetting('backup.telegram_pending', '1');
      await db.setSetting('backup.telegram_error', message);
      return BackupResult(
        ok: false,
        message: 'Unggah Telegram gagal; akan dicoba lagi otomatis.',
      );
    }
  }

  String _scrubToken(String message, String token) {
    if (token.isEmpty) return message;
    return message.replaceAll(token, '***');
  }

  Future<void> _pruneAutoBackups(String folder) async {
    try {
      final files = await platform.listBackupFiles(folder);
      if (files.length <= _keepAutoBackups) return;
      for (final path in files.take(files.length - _keepAutoBackups)) {
        await platform.deleteBackupFile(path);
      }
    } catch (_) {
      // Pembersihan berkas lama tidak boleh menggagalkan backup.
    }
  }

  /// Memilih berkas backup; dipisah dari [restoreBackup] agar UI dapat
  /// meminta passphrase sesuai jenis arsip sebelum memulihkan.
  Future<String?> pickBackupArchive() async {
    if (kIsWeb) return null;
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Pilih backup PusatkuPOS',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      final path = picked?.path ?? '';
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  /// True bila arsip memerlukan passphrase buatan pengguna.
  Future<bool> needsPassphrase(String path) async {
    try {
      final archive = ZipDecoder().decodeBytes(await platform.readFile(path));
      final manifest = _readManifest(archive);
      if (manifest == null) return false;
      final format = manifest['format'];
      if (format == _backupFormat) {
        final stores = manifest['stores'];
        if (stores is! List) return false;
        return stores.any((entry) {
          if (entry is! Map) return false;
          final cipher = entry['cipher'];
          return cipher is Map && '${cipher['scope']}' == 'portable';
        });
      }
      if (format != _singleStoreFormat) return false;
      final cipher = manifest['cipher'];
      if (cipher is! Map) return false;
      return '${cipher['scope']}' == 'portable';
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic>? _readManifest(Archive archive) {
    final file = archive.files
        .where((entry) => entry.name == 'manifest.json')
        .firstOrNull;
    if (file == null || file.size > _maxManifestBytes) return null;
    try {
      final decoded = jsonDecode(utf8.decode(file.content as List<int>));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<BackupResult> restoreBackup({String? path, String? passphrase}) async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Restore file tersedia di Android/desktop.',
      );
    }
    final pickedPath = path ?? await pickBackupArchive();
    if (pickedPath == null || pickedPath.isEmpty) {
      return const BackupResult(ok: false, message: 'Restore dibatalkan.');
    }
    try {
      final bytes = await platform.readFile(pickedPath);
      final archive = ZipDecoder().decodeBytes(bytes);
      final manifest = _readManifest(archive);
      if (manifest == null) {
        return const BackupResult(
          ok: false,
          message: 'Arsip bukan backup PusatkuPOS.',
        );
      }
      final format = manifest['format'];
      if (format != 1 &&
          format != _singleStoreFormat &&
          format != _backupFormat) {
        return const BackupResult(
          ok: false,
          message: 'Versi backup tidak didukung.',
        );
      }
      if (format == _backupFormat) {
        return await _restoreMultiStore(archive, manifest, passphrase);
      }
      final payloadName = '${manifest['payload'] ?? 'pusatkupos.db'}';
      final payloadFile = archive.files
          .where((entry) => entry.name == payloadName)
          .firstOrNull;
      if (payloadFile == null) {
        return const BackupResult(
          ok: false,
          message: 'Berkas database di dalam arsip tidak ditemukan.',
        );
      }
      if (payloadFile.size > _maxRestoredDatabaseBytes) {
        return const BackupResult(
          ok: false,
          message: 'Berkas database di dalam ZIP terlalu besar.',
        );
      }
      var payload = List<int>.from(payloadFile.content as List<int>);
      if (payload.length > _maxRestoredDatabaseBytes) {
        return const BackupResult(
          ok: false,
          message: 'Berkas database hasil dekompresi terlalu besar.',
        );
      }
      if (format == _singleStoreFormat) {
        final cipher = manifest['cipher'];
        if (cipher is! Map) {
          return const BackupResult(
            ok: false,
            message: 'Metadata enkripsi backup tidak lengkap.',
          );
        }
        final meta = Map<String, dynamic>.from(cipher);
        var secret = passphrase?.trim() ?? '';
        if (secret.isEmpty && '${meta['scope']}' == 'auto') {
          secret = await _autoPassphrase();
        }
        if (secret.isEmpty) {
          return const BackupResult(
            ok: false,
            message:
                'Backup terkunci passphrase. Masukkan passphrase yang '
                'dipakai saat membuat backup.',
          );
        }
        try {
          payload = await _decryptPayload(payload, meta, secret);
        } catch (_) {
          return const BackupResult(
            ok: false,
            message: 'Passphrase salah atau berkas backup rusak.',
          );
        }
      }
      final checksum = sha256.convert(payload).toString();
      if (checksum != manifest['sha256']) {
        return const BackupResult(
          ok: false,
          message: 'Checksum backup tidak cocok.',
        );
      }
      if (!_looksLikeSqlite(payload)) {
        return BackupResult(
          ok: false,
          message: format == 1
              ? 'Backup lama ini masih terenkripsi kunci perangkat dan tidak '
                    'dapat dipulihkan. Buat backup baru dari aplikasi versi ini.'
              : 'Berkas database tidak sah.',
        );
      }

      final db = AppDatabase.instance;
      final targetPath = db.databasePath;
      final plainPath = await platform.temporaryPath(
        'pusatkupos_restore_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final newPath = '$targetPath.restore.tmp';
      try {
        await platform.deleteFile(plainPath);
        await platform.writeDatabase(plainPath, payload);
        await platform.deleteFile(newPath);
        await platform.deleteDatabaseSidecars(newPath);
        if (db.databaseEncrypted) {
          await db.createEncryptedCopy(plainPath, newPath);
          await db.validateEncryptedCopy(
            newPath,
            requiredTables: _requiredRestoreTables,
          );
        } else {
          await db.validatePlainCopy(
            plainPath,
            requiredTables: _requiredRestoreTables,
          );
          await platform.writeDatabase(newPath, payload);
        }
      } catch (error) {
        await platform.deleteFile(plainPath);
        await platform.deleteFile(newPath);
        return BackupResult(ok: false, message: 'Backup ditolak: $error');
      } finally {
        await platform.deleteFile(plainPath);
      }

      final oldMaxSeq = await _maxOutboxSeq();
      final oldFloor =
          int.tryParse(await db.getSetting('device.seq_floor') ?? '') ?? 0;
      await db.checkpoint();
      String? safetyCopy;
      try {
        safetyCopy = await platform.backupExistingDatabase(targetPath);
      } catch (_) {
        safetyCopy = null;
      }
      await db.close();
      try {
        await platform.replaceDatabase(targetPath, newPath);
        await db.reopen();
        final integrity = await db.db.rawQuery('PRAGMA integrity_check');
        final result = integrity.isEmpty
            ? ''
            : '${integrity.first.values.first}';
        if (result.toLowerCase() != 'ok') {
          throw StateError('Integritas database hasil restore gagal: $result');
        }
      } catch (error) {
        await db.close();
        if (safetyCopy != null) {
          try {
            await platform.replaceDatabase(targetPath, safetyCopy);
          } catch (_) {
            // Biarkan error asli dilaporkan; salinan pengaman tetap ada.
          }
        }
        try {
          await db.reopen();
        } catch (_) {
          // Reopen gagal dilaporkan lewat pesan di bawah.
        }
        return BackupResult(
          ok: false,
          message: 'Restore gagal dan data lama dikembalikan: $error',
        );
      }

      var floor = oldMaxSeq;
      if (oldFloor > floor) floor = oldFloor;
      final newMaxSeq = await _maxOutboxSeq();
      if (newMaxSeq > floor) floor = newMaxSeq;
      await db.setSetting('device.seq_floor', '$floor');
      await db.setSetting('device.kode_lokal', newDeviceCode());
      await db.setSetting('sync.restore_requires_bootstrap', '1');
      return const BackupResult(
        ok: true,
        message:
            'Backup dipulihkan. Kode perangkat baru dibuat agar nomor '
            'nota tidak bentrok. Jalankan bootstrap sebelum sinkronisasi.',
      );
    } catch (error) {
      if (!AppDatabase.instance.isOpen) {
        try {
          await AppDatabase.instance.reopen();
        } catch (_) {
          // Error asli lebih informatif.
        }
      }
      return BackupResult(ok: false, message: 'Restore gagal: $error');
    }
  }

  Future<BackupResult> _restoreMultiStore(
    Archive archive,
    Map<String, dynamic> manifest,
    String? passphrase,
  ) async {
    final db = AppDatabase.instance;
    if (db.isViewerDatabase) {
      return const BackupResult(
        ok: false,
        message: 'Keluar dari mode ringkasan sebelum memulihkan backup.',
      );
    }
    final rawStores = manifest['stores'];
    if (rawStores is! List || rawStores.isEmpty) {
      return const BackupResult(
        ok: false,
        message: 'Arsip tidak memuat daftar toko.',
      );
    }
    final root = StoreRegistry.instance.isOpen
        ? StoreRegistry.instance.rootPath
        : p.dirname(db.databasePath);
    final restored = <_PendingStoreRestore>[];
    final usedPaths = <String>{};
    final usedStoreIds = <String>{};
    for (final raw in rawStores) {
      if (raw is! Map) {
        return const BackupResult(
          ok: false,
          message: 'Entri toko pada arsip tidak sah.',
        );
      }
      final entry = Map<String, dynamic>.from(raw);
      final label = '${entry['nama'] ?? entry['store_id'] ?? 'toko'}';
      final payloadName = '${entry['payload'] ?? ''}';
      final payloadFile = archive.files
          .where((file) => file.name == payloadName)
          .firstOrNull;
      if (payloadFile == null) {
        return BackupResult(
          ok: false,
          message: 'Berkas database toko $label tidak ditemukan.',
        );
      }
      if (payloadFile.size > _maxRestoredDatabaseBytes) {
        return BackupResult(
          ok: false,
          message: 'Berkas database toko $label terlalu besar.',
        );
      }
      var payload = List<int>.from(payloadFile.content as List<int>);
      if (payload.length > _maxRestoredDatabaseBytes) {
        return BackupResult(
          ok: false,
          message: 'Berkas database toko $label terlalu besar.',
        );
      }
      final cipher = entry['cipher'];
      if (cipher is! Map) {
        return BackupResult(
          ok: false,
          message: 'Metadata enkripsi toko $label tidak lengkap.',
        );
      }
      final meta = Map<String, dynamic>.from(cipher);
      var secret = passphrase?.trim() ?? '';
      if (secret.isEmpty && '${meta['scope']}' == 'auto') {
        secret = await _autoPassphrase();
      }
      if (secret.isEmpty) {
        return const BackupResult(
          ok: false,
          message:
              'Backup terkunci passphrase. Masukkan passphrase yang '
              'dipakai saat membuat backup.',
        );
      }
      try {
        payload = await _decryptPayload(payload, meta, secret);
      } catch (_) {
        return const BackupResult(
          ok: false,
          message: 'Passphrase salah atau berkas backup rusak.',
        );
      }
      if (sha256.convert(payload).toString() != '${entry['sha256'] ?? ''}') {
        return BackupResult(
          ok: false,
          message: 'Checksum toko $label tidak cocok.',
        );
      }
      if (!_looksLikeSqlite(payload)) {
        return BackupResult(
          ok: false,
          message: 'Berkas database toko $label tidak sah.',
        );
      }
      var storeId = '${entry['store_id'] ?? ''}'.trim();
      var databaseId = '${entry['database_id'] ?? ''}'.trim();
      if (databaseId.isEmpty) {
        databaseId = newSyncId();
      }
      databaseId = databaseId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      if (storeId.isEmpty || usedStoreIds.contains(storeId)) {
        storeId = 'toko_${newSyncId()}';
      }
      final existing = StoreRegistry.instance.isOpen
          ? await StoreRegistry.instance.byId(storeId)
          : null;
      var targetPath =
          existing?.databasePath ?? p.join(root, 'stores', '$databaseId.db');
      while (usedPaths.contains(targetPath)) {
        databaseId = newSyncId();
        targetPath = p.join(root, 'stores', '$databaseId.db');
      }
      usedStoreIds.add(storeId);
      usedPaths.add(targetPath);

      final plainPath = await platform.temporaryPath(
        'pusatkupos_restore_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final newPath = '$targetPath.restore.tmp';
      try {
        await platform.ensureParentDirectory(targetPath);
        await platform.deleteFile(plainPath);
        await platform.writeDatabase(plainPath, payload);
        await platform.deleteFile(newPath);
        await platform.deleteDatabaseSidecars(newPath);
        if (db.databaseEncrypted) {
          await db.createEncryptedCopy(plainPath, newPath);
          await db.validateEncryptedCopy(
            newPath,
            requiredTables: _requiredRestoreTables,
          );
        } else {
          await db.validatePlainCopy(
            plainPath,
            requiredTables: _requiredRestoreTables,
          );
          await platform.writeDatabase(newPath, payload);
        }
      } catch (error) {
        await platform.deleteFile(plainPath);
        await platform.deleteFile(newPath);
        return BackupResult(ok: false, message: 'Toko $label ditolak: $error');
      } finally {
        await platform.deleteFile(plainPath);
      }
      restored.add(
        _PendingStoreRestore(
          storeId: storeId,
          databaseId: databaseId,
          nama: label,
          alamat: '${entry['alamat'] ?? ''}',
          createdAt: '${entry['created_at'] ?? ''}',
          targetPath: targetPath,
          tempPath: newPath,
        ),
      );
    }

    await db.checkpoint();
    final safety = <String, String>{};
    for (final store in restored) {
      try {
        final copy = await platform.backupExistingDatabase(store.targetPath);
        if (copy != null) safety[store.targetPath] = copy;
      } catch (_) {
        // Salinan pengaman opsional; replace tetap atomik per berkas.
      }
    }

    await db.close();
    final replaced = <String>[];
    try {
      for (final store in restored) {
        await platform.ensureParentDirectory(store.targetPath);
        await platform.replaceDatabase(store.targetPath, store.tempPath);
        replaced.add(store.targetPath);
      }
    } catch (error) {
      for (final path in replaced) {
        final copy = safety[path];
        if (copy == null) continue;
        try {
          await platform.replaceDatabase(path, copy);
        } catch (_) {
          // Biarkan error asli dilaporkan.
        }
      }
      for (final store in restored) {
        await platform.deleteFile(store.tempPath);
      }
      try {
        await db.reopen();
      } catch (_) {
        // Reopen gagal dilaporkan lewat pesan di bawah.
      }
      return BackupResult(
        ok: false,
        message:
            'Restore multi-toko gagal dan berkas lama dikembalikan: '
            '$error',
      );
    }

    late final List<StoreRecord> records;
    late final StoreRecord activeRecord;
    try {
      if (!StoreRegistry.instance.isOpen) {
        await StoreRegistry.instance.open(root);
      }
      records = restored
          .map(
            (store) => StoreRecord(
              storeId: store.storeId,
              databaseId: store.databaseId,
              nama: store.nama,
              alamat: store.alamat,
              databasePath: store.targetPath,
              createdAt: store.createdAt,
            ),
          )
          .toList();
      final requestedActive = '${manifest['active_store_id'] ?? ''}';
      activeRecord = records.firstWhere(
        (record) => record.storeId == requestedActive,
        orElse: () => records.first,
      );
      await StoreRegistry.instance.replaceAll(
        records,
        activeStoreId: activeRecord.storeId,
      );
    } catch (error) {
      try {
        await db.reopen();
      } catch (_) {
        // Reopen gagal dilaporkan lewat pesan di bawah.
      }
      return BackupResult(
        ok: false,
        message:
            'Berkas toko dipulihkan tetapi registry gagal diperbarui: '
            '$error',
      );
    }

    for (final record in records) {
      try {
        await db.switchStore(record);
        final existingFloor =
            int.tryParse(await db.getSetting('device.seq_floor') ?? '') ?? 0;
        final newMaxSeq = await _maxOutboxSeq();
        final floor = existingFloor > newMaxSeq ? existingFloor : newMaxSeq;
        await db.setSetting('device.seq_floor', '$floor');
        await db.setSetting('device.kode_lokal', newDeviceCode());
        await db.setSetting('sync.restore_requires_bootstrap', '1');
      } catch (_) {
        // Satu toko gagal disiapkan tidak membatalkan restore toko lain.
      }
    }
    try {
      await db.switchStore(activeRecord);
    } catch (_) {
      // Toko aktif sudah dibuka pada iterasi sebelumnya.
    }
    return BackupResult(
      ok: true,
      message:
          'Backup multi-toko dipulihkan (${records.length} toko). '
          'Kode perangkat baru dibuat agar nomor nota tidak bentrok. '
          'Jalankan bootstrap sebelum sinkronisasi.',
    );
  }

  bool _looksLikeSqlite(List<int> bytes) {
    if (bytes.length < 16) return false;
    return String.fromCharCodes(bytes.take(16)) == 'SQLite format 3\u0000';
  }

  Future<int> _maxOutboxSeq() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS seq FROM sync_outbox',
    );
    return rows.first['seq'] as int? ?? 0;
  }
}

class _PendingStoreRestore {
  const _PendingStoreRestore({
    required this.storeId,
    required this.databaseId,
    required this.nama,
    required this.alamat,
    required this.createdAt,
    required this.targetPath,
    required this.tempPath,
  });

  final String storeId;
  final String databaseId;
  final String nama;
  final String alamat;
  final String createdAt;
  final String targetPath;
  final String tempPath;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
