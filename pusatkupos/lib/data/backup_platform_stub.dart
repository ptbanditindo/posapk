Future<List<int>> readDatabase(String path) async {
  throw UnsupportedError('File backup tidak tersedia di platform ini.');
}

Future<void> writeDatabase(String path, List<int> bytes) async {
  throw UnsupportedError('Restore file tidak tersedia di platform ini.');
}

Future<List<int>> readFile(String path) async {
  throw UnsupportedError('Berkas tidak tersedia di platform ini.');
}
