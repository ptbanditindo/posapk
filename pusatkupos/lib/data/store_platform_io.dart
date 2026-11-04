import 'dart:io';

Future<void> ensureStoreDirectory(String databasePath) async {
  await Directory(File(databasePath).parent.path).create(recursive: true);
}

Future<bool> storeFileExists(String databasePath) =>
    File(databasePath).exists();
