import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<List<int>> readDatabase(String path) async {
  return File(path).readAsBytes();
}

Future<void> writeDatabase(String path, List<int> bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

Future<List<int>> readFile(String path) async {
  return File(path).readAsBytes();
}

Future<bool> fileExists(String path) => File(path).exists();

Future<int> fileSize(String path) async {
  final file = File(path);
  if (!await file.exists()) return 0;
  return file.length();
}

/// Ruang kosong pada volume [directory]; `null` bila tidak dapat diketahui.
Future<int?> freeDiskBytes(String directory) async {
  try {
    final dir = Directory(directory);
    if (!await dir.exists()) return null;
    if (Platform.isWindows) {
      final escaped = directory.replaceAll("'", "''");
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-Item -LiteralPath '$escaped').PSDrive.Free",
      ]);
      if (result.exitCode != 0) return null;
      final match = RegExp(r'\d+').firstMatch('${result.stdout}');
      return match == null ? null : int.tryParse(match.group(0)!);
    }
    final result = await Process.run('df', ['-k', directory]);
    if (result.exitCode != 0) return null;
    final lines = '${result.stdout}'
        .trim()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final columns = lines.last.trim().split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final kilobytes = int.tryParse(columns[3]);
    return kilobytes == null ? null : kilobytes * 1024;
  } catch (_) {
    return null;
  }
}

Future<void> ensureParentDirectory(String path) async {
  await File(path).parent.create(recursive: true);
}

/// Salinan pengaman database lama sebelum ditimpa.
Future<String?> backupExistingDatabase(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-');
  final backup = File('$path.bak-$stamp');
  await file.copy(backup.path);
  return backup.path;
}

Future<void> deleteDatabaseSidecars(String path) async {
  for (final suffix in const ['-wal', '-shm']) {
    final sidecar = File('$path$suffix');
    if (await sidecar.exists()) {
      await sidecar.delete();
    }
  }
}

/// Ganti database secara atomik: berkas lama dipindahkan ke `<path>.old`
/// lebih dahulu, sehingga kegagalan di tengah proses masih dapat
/// dipulihkan lewat [recoverInterruptedRestore]. Berkas `.old` baru dihapus
/// oleh [commitReplacedDatabase] setelah hasil restore diverifikasi.
Future<void> replaceDatabase(String path, String tempPath) async {
  final target = File(path);
  final old = File('$path.old');
  final source = File(tempPath);

  if (!await source.exists()) {
    throw StateError('Berkas database pengganti tidak ditemukan.');
  }
  // Bereskan sisa restore sebelumnya agar pertukaran dimulai dari kondisi
  // database aktif yang utuh.
  await recoverInterruptedRestore(path);
  // Pastikan isi berkas baru benar-benar tersimpan sebelum rename.
  await _flushFile(source);
  await deleteDatabaseSidecars(tempPath);
  await _deleteFileIfExists(old);
  await _deleteFileIfExists(File('$path.restore.ok'));

  if (await target.exists()) {
    await target.rename(old.path);
  }
  // WAL/SHM milik berkas lama tidak berlaku lagi untuk path aktif.
  await deleteDatabaseSidecars(path);
  try {
    await source.rename(path);
    await _flushFile(target);
  } catch (error) {
    if (!await target.exists() && await old.exists()) {
      await old.rename(path);
    }
    rethrow;
  }
}

/// Menandai hasil [replaceDatabase] sudah diverifikasi lalu membuang
/// berkas lama. Penanda `.restore.ok` mencegah pemulihan startup membuang
/// database baru yang sudah sah bila proses berhenti tepat setelah verifikasi.
Future<bool> commitReplacedDatabase(String path) async {
  final marker = File('$path.restore.ok');
  final old = File('$path.old');
  if (!await old.exists()) {
    await _deleteFileIfExists(marker);
    return false;
  }
  await marker.writeAsString(
    DateTime.now().toUtc().toIso8601String(),
    flush: true,
  );
  await _deleteFileIfExists(old);
  await deleteDatabaseSidecars(old.path);
  await _deleteFileIfExists(marker);
  return true;
}

/// Mengembalikan database lama yang disimpan [replaceDatabase] pada
/// `<path>.old`. Mengembalikan false bila tidak ada berkas lama.
Future<bool> rollbackReplacedDatabase(String path) async {
  final target = File(path);
  final old = File('$path.old');
  if (!await old.exists()) return false;
  await _flushFile(old);
  await deleteDatabaseSidecars(path);
  await _deleteFileIfExists(target);
  await old.rename(path);
  await deleteDatabaseSidecars(path);
  await _deleteFileIfExists(File('$path.restore.ok'));
  return true;
}

/// Memulihkan database yang tertinggal akibat restore terputus.
///
/// * `.old` ada tanpa penanda selesai: restore belum terverifikasi,
///   kembalikan berkas lama (database aktif yang hilang maupun yang sudah
///   tergantikan).
/// * `.old` ada bersama penanda `.restore.ok`: penggantian sudah
///   terverifikasi, bersihkan sisa berkas lama.
/// * database aktif hilang tanpa `.old`: pakai salinan pengaman `.bak-*`
///   terbaru bila ada.
/// * berkas staging `.restore.tmp`/`.restore.plain` yang tertinggal tidak
///   pernah dipromosikan karena isinya belum tentu lengkap.
Future<String?> recoverInterruptedRestore(String path) async {
  final target = File(path);
  final old = File('$path.old');
  final marker = File('$path.restore.ok');
  final committed = await marker.exists();

  if (await old.exists()) {
    if (committed) {
      await _deleteFileIfExists(old);
      await deleteDatabaseSidecars(old.path);
      await _deleteFileIfExists(marker);
      await _cleanRestoreArtifacts(path);
      return 'sisa berkas .old dibersihkan';
    }
    await _flushFile(old);
    await deleteDatabaseSidecars(path);
    await _deleteFileIfExists(target);
    await old.rename(path);
    await deleteDatabaseSidecars(path);
    await _cleanRestoreArtifacts(path);
    return 'database lama dipulihkan dari .old';
  }

  await _deleteFileIfExists(marker);

  if (await target.exists()) {
    await _cleanRestoreArtifacts(path);
    return null;
  }

  final safety = await _latestSafetyCopy(path);
  if (safety != null) {
    final label = p.basename(safety.path);
    await _flushFile(safety);
    await safety.rename(path);
    await deleteDatabaseSidecars(path);
    await _cleanRestoreArtifacts(path);
    return 'database dipulihkan dari $label';
  }

  await _cleanRestoreArtifacts(path);
  return null;
}

Future<void> _cleanRestoreArtifacts(String path) async {
  for (final suffix in const ['.restore.tmp', '.restore.plain']) {
    final file = File('$path$suffix');
    await _deleteFileIfExists(file);
    await deleteDatabaseSidecars(file.path);
  }
}

Future<void> _flushFile(File file) async {
  final handle = await file.open(mode: FileMode.append);
  try {
    await handle.flush();
  } finally {
    await handle.close();
  }
}

Future<void> _deleteFileIfExists(File file) async {
  if (await file.exists()) await file.delete();
}

/// Salinan pengaman terbaru buatan [backupExistingDatabase] untuk [path].
Future<File?> _latestSafetyCopy(String path) async {
  final dir = File(path).parent;
  if (!await dir.exists()) return null;
  final prefix = '${p.basename(path)}.bak-';
  String? latest;
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith(prefix)) continue;
    if (latest == null || name.compareTo(latest) > 0) latest = name;
  }
  if (latest == null) return null;
  final file = File(p.join(dir.path, latest));
  if (await file.length() == 0) return null;
  return file;
}

/// Lokasi sementara untuk ekspor database sebelum diarsipkan.
Future<String> temporaryPath(String name) async {
  final dir = await getTemporaryDirectory();
  await dir.create(recursive: true);
  return p.join(dir.path, name);
}

Future<void> deleteFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

Future<String> autoBackupFolder() async {
  final base = await getApplicationSupportDirectory();
  final folder = Directory(p.join(base.path, 'backup'));
  await folder.create(recursive: true);
  return folder.path;
}

Future<String> writeBackupFile(
  String folder,
  String name,
  List<int> bytes,
) async {
  final file = File(p.join(folder, name));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<List<String>> listBackupFiles(String folder) async {
  final directory = Directory(folder);
  if (!await directory.exists()) return const [];
  final files = <File>[];
  await for (final entity in directory.list()) {
    if (entity is File && entity.path.toLowerCase().endsWith('.zip')) {
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files.map((file) => file.path).toList();
}

Future<void> deleteBackupFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}
