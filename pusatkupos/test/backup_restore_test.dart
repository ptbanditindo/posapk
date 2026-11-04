import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/backup_platform_io.dart' as platform;

void main() {
  test('ganti database memakai berkas sementara + salinan pengaman', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_restore_');
    final path = p.join(dir.path, 'restore.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      await db.addCustomer(nama: 'Restore', nomorHp: '081200000088');
      await db.checkpoint();
      final temp = '$path.restore.tmp';
      await File(path).copy(temp);
      await db.close();

      final backup = await platform.backupExistingDatabase(path);
      expect(backup, isNotNull);
      expect(await File(backup!).exists(), isTrue);
      await platform.replaceDatabase(path, temp);
      expect(await File(temp).exists(), isFalse);

      await db.reopen();
      final customers = await db.listCustomers();
      expect(customers.single.nama, 'Restore');
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
