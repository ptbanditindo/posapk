import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart' as platform;
import 'secure_store.dart';

const int _maxRestoredDatabaseBytes = 512 * 1024 * 1024;
const int _maxManifestBytes = 1024 * 1024;
const int _maxTelegramBytes = 50 * 1024 * 1024;
const int _keepAutoBackups = 30;
const String _telegramTokenKey = 'backup.telegram.token';
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
    final jam = _normalizeTime(await db.getSetting('backup.jam') ?? '') ??
        '02:00';
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
  }) async {
    final normalized = _normalizeTime(jam);
    if (normalized == null) {
      throw ArgumentError('Jam backup harus memakai format HH:MM.');
    }
    final db = AppDatabase.instance;
    await db.setSetting('backup.auto_enabled', autoEnabled ? '1' : '0');
    await db.setSetting('backup.jam', normalized);
    await db.setSetting(
      'backup.telegram_enabled',
      telegramEnabled ? '1' : '0',
    );
    await db.setSetting('backup.telegram_chat', telegramChatId.trim());
    if (clearTelegramToken) {
      await SecureStore.instance.delete(_telegramTokenKey);
    } else if (telegramToken != null && telegramToken.trim().isNotEmpty) {
      await SecureStore.instance.write(
        _telegramTokenKey,
        telegramToken.trim(),
      );
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

  Future<Uint8List> _buildArchive() async {
    final db = AppDatabase.instance;
    await db.checkpoint();
    final bytes = await platform.readDatabase(db.databasePath);
    final checksum = sha256.convert(bytes).toString();
    final manifest = jsonEncode({
      'format': 1,
      'app': 'PusatkuPOS',
      'created_at': nowIso(),
      'database': 'pusatkupos.db',
      'sha256': checksum,
    });
    final archive = Archive();
    archive.addFile(
      ArchiveFile(
        'pusatkupos.db',
        bytes.length,
        Uint8List.fromList(bytes),
      ),
    );
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

  String _stamp() => DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .substring(0, 19);

  Future<BackupResult> createBackup() async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Backup file tersedia di Android/desktop.',
      );
    }
    try {
      final zip = await _buildArchive();
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Simpan backup PusatkuPOS',
        fileName: 'pusatkupos_backup_${_stamp()}.zip',
        bytes: zip,
        mimeType: 'application/zip',
      );
      if (uri == null) {
        return const BackupResult(ok: false, message: 'Backup dibatalkan.');
      }
      return const BackupResult(ok: true, message: 'Backup berhasil disimpan.');
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
      final zip = await _buildArchive();
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
    final bytes = await platform.readFile(path);
    final filename = path.split(RegExp(r'[/\\]')).last;
    await db.setSetting('backup.last_attempt_at', nowIso());
    return _sendTelegramBackup(
      settings: settings,
      bytes: bytes,
      filename: filename,
    );
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
    final storeName =
        await db.getSetting('bengkel.nama') ?? 'PusatkuPOS';
    final caption =
        '$storeName · ${DateTime.now().toIso8601String().substring(0, 10)}';
    try {
      final request = http.MultipartRequest(
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

  Future<BackupResult> restoreBackup() async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Restore file tersedia di Android/desktop.',
      );
    }
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Pilih backup PusatkuPOS',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (picked == null || (picked.path ?? '').isEmpty) {
      return const BackupResult(ok: false, message: 'Restore dibatalkan.');
    }
    final bytes = await platform.readFile(picked.path!);
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final manifestFile =
          archive.files.where((file) => file.name == 'manifest.json').firstOrNull;
      final databaseFile =
          archive.files.where((file) => file.name == 'pusatkupos.db').firstOrNull;
      if (manifestFile == null || databaseFile == null) {
        return const BackupResult(
          ok: false,
          message: 'Arsip bukan backup PusatkuPOS.',
        );
      }
      if (databaseFile.size > _maxRestoredDatabaseBytes) {
        return const BackupResult(
          ok: false,
          message: 'Berkas database di dalam ZIP terlalu besar.',
        );
      }
      if (manifestFile.size > _maxManifestBytes) {
        return const BackupResult(
          ok: false,
          message: 'Manifest backup terlalu besar.',
        );
      }
      final manifest = jsonDecode(
        utf8.decode(manifestFile.content as List<int>),
      ) as Map<String, dynamic>;
      if (manifest['format'] != 1) {
        return const BackupResult(
          ok: false,
          message: 'Versi backup tidak didukung.',
        );
      }
      final databaseBytes = databaseFile.content as List<int>;
      if (databaseBytes.length > _maxRestoredDatabaseBytes) {
        return const BackupResult(
          ok: false,
          message: 'Berkas database hasil dekompresi terlalu besar.',
        );
      }
      final checksum = sha256.convert(databaseBytes).toString();
      if (checksum != manifest['sha256']) {
        return const BackupResult(
          ok: false,
          message: 'Checksum backup tidak cocok.',
        );
      }
      if (databaseBytes.length < 16 ||
          String.fromCharCodes(databaseBytes.take(16)) != 'SQLite format 3\u0000') {
        return const BackupResult(
          ok: false,
          message: 'Berkas database tidak sah.',
        );
      }
      final db = AppDatabase.instance;
      final path = db.databasePath;
      final tempPath = '$path.restore.tmp';
      await platform.writeDatabase(tempPath, databaseBytes);
      try {
        await _validateRestoredDatabase(tempPath);
      } catch (error) {
        return BackupResult(
          ok: false,
          message: 'Backup ditolak: $error',
        );
      }
      final oldMaxSeq = await _maxOutboxSeq();
      final oldFloor = int.tryParse(
            await db.getSetting('device.seq_floor') ?? '',
          ) ??
          0;
      await db.checkpoint();
      await db.close();
      await platform.backupExistingDatabase(path);
      await platform.replaceDatabase(path, tempPath);
      await db.reopen();
      final newMaxSeq = await _maxOutboxSeq();
      var floor = oldMaxSeq;
      if (oldFloor > floor) floor = oldFloor;
      if (newMaxSeq > floor) floor = newMaxSeq;
      await db.setSetting('device.seq_floor', '$floor');
      await db.setSetting('device.nota_prefix', newNotaPrefix());
      await db.setSetting('sync.restore_requires_bootstrap', '1');
      return const BackupResult(
        ok: true,
        message: 'Backup dipulihkan. Prefix nota baru dibuat dan antrean '
            'sinkron dilanjutkan dari nomor urut terakhir. Restore ke '
            'perangkat kedua dapat menyebabkan bentrok; jalankan bootstrap.',
      );
    } catch (error) {
      if (!AppDatabase.instance.isOpen) {
        await AppDatabase.instance.reopen();
      }
      return BackupResult(ok: false, message: 'Restore gagal: $error');
    }
  }

  Future<int> _maxOutboxSeq() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS seq FROM sync_outbox',
    );
    return rows.first['seq'] as int? ?? 0;
  }

  Future<void> _validateRestoredDatabase(String path) async {
    final probe = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final integrity = await probe.rawQuery('PRAGMA integrity_check');
      final result = integrity.isEmpty
          ? ''
          : '${integrity.first.values.first}';
      if (result.toLowerCase() != 'ok') {
        throw StateError('Integritas database gagal: $result');
      }
      final tableRows = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = tableRows.map((row) => '${row['name']}').toSet();
      for (final required in _requiredRestoreTables) {
        if (!tables.contains(required)) {
          throw StateError('Tabel wajib "$required" tidak ditemukan.');
        }
      }
    } finally {
      await probe.close();
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
