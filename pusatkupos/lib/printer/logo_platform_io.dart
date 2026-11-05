import 'dart:io';

Future<List<int>?> readLogoBytes(String path) async {
  final clean = path.trim();
  if (clean.isEmpty) return null;
  try {
    final file = File(clean);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
