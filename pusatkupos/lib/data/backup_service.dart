import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart' as platform;

const int _maxRestoredDatabaseBytes = 512 * 1024 * 1024;
const int _maxManifestBytes = 1024 * 1024;
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

class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  Future<BackupResult> createBackup() async {
    if (kIsWeb) {
      return const BackupResult(
        ok: false,
        message: 'Backup file tersedia di Android/desktop.',
      );
    }
    try {
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
      final zip = ZipEncoder().encode(archive);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Simpan backup PusatkuPOS',
        fileName: 'pusatkupos_backup_$stamp.zip',
        bytes: Uint8List.fromList(zip),
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
