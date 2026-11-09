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

Future<int> fileSize(String path) async => 0;

Future<int?> freeDiskBytes(String directory) async => null;

Future<void> ensureParentDirectory(String path) async {}

Future<String?> backupExistingDatabase(String path) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<void> deleteDatabaseSidecars(String path) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<void> deleteDatabaseFiles(String path) async {}

Future<void> deleteViewerDatabases(String directory) async {}

Future<void> moveFile(String from, String to) async {
  throw UnsupportedError('Pemulihan database tidak tersedia di sini.');
}

Future<void> replaceDatabase(String path, String tempPath) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<String?> recoverInterruptedRestore(String path) async => null;

Future<bool> commitReplacedDatabase(String path) async => false;

Future<bool> rollbackReplacedDatabase(String path) async => false;

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
