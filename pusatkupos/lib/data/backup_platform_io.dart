import 'dart:io';

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
