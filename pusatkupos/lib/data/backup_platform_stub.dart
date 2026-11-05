Future<List<int>> readDatabase(String path) async {
  throw UnsupportedError('File backup tidak tersedia di platform ini.');
}

Future<void> writeDatabase(String path, List<int> bytes) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<List<int>> readFile(String path) async {
  throw UnsupportedError('Berkas tidak tersedia di platform ini.');
}

Future<bool> fileExists(String path) async => false;

Future<void> ensureParentDirectory(String path) async {}

Future<String?> backupExistingDatabase(String path) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<void> deleteDatabaseSidecars(String path) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<void> replaceDatabase(String path, String tempPath) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<String> temporaryPath(String name) async {
  throw UnsupportedError('Berkas sementara tidak tersedia di platform ini.');
}

Future<void> deleteFile(String path) async {}

Future<String> autoBackupFolder() async {
  throw UnsupportedError('Backup otomatis tidak tersedia di platform ini.');
}

Future<String> writeBackupFile(
  String folder,
  String name,
  List<int> bytes,
) async {
  throw UnsupportedError('Backup otomatis tidak tersedia di platform ini.');
}

Future<List<String>> listBackupFiles(String folder) async => const [];

Future<void> deleteBackupFile(String path) async {}
