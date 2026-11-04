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

/// Ganti database secara atomik memakai rename pada direktori yang sama.
Future<void> replaceDatabase(String path, String tempPath) async {
  await deleteDatabaseSidecars(path);
  final target = File(path);
  if (await target.exists()) {
    await target.delete();
  }
  await File(tempPath).rename(path);
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
