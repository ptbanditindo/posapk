import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../core/dates.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart' as platform;

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
      await db.close();
      await platform.writeDatabase(path, databaseBytes);
      await db.reopen();
      return const BackupResult(ok: true, message: 'Backup berhasil dipulihkan.');
    } catch (error) {
      if (!AppDatabase.instance.isOpen) {
        await AppDatabase.instance.reopen();
      }
      return BackupResult(ok: false, message: 'Restore gagal: $error');
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
