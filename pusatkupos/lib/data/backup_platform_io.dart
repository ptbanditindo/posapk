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
