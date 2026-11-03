import 'dart:io';

import 'package:file_picker/file_picker.dart';

Future<String> readSummaryFile(PlatformFile file) async {
  final path = file.path ?? '';
  if (path.isEmpty) throw StateError('File ringkasan tidak memiliki path.');
  return File(path).readAsString();
}
