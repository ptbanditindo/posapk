import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'printer_storage.dart';

PrinterStorage createPrinterStorage() => FilePrinterStorage();

class FilePrinterStorage implements PrinterStorage {
  static const fileName = 'printer_config.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<String?> readBackup() async {
    final file = await _file();
    final backup = File('${file.path}.bak');
    if (!await backup.exists()) return null;
    return backup.readAsString();
  }

  @override
  Future<void> write(String data) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temp.writeAsString(data, flush: true);
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temp.rename(file.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(file.path);
      rethrow;
    }
  }
}
