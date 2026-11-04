import 'dart:convert';

import 'package:file_picker/file_picker.dart';

Future<String> readSummaryFile(PlatformFile file) async {
  return utf8.decode(await file.readAsBytes());
}
