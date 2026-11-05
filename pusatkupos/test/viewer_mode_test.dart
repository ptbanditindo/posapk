import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/data/session_service.dart';

void main() {
  SecureStore.useMemoryForTests = true;
  late Directory dir;
  final db = AppDatabase.instance;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_viewer_');
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('database ringkasan terpisah dari pembukuan lokal', () async {
    await db.initForTest(p.join(dir.path, 'utama.db'));
    await db.setSetting('uji.pembukuan', 'Toko Utama');

    await db.openViewerDatabase('OWNER/1');
    expect(db.isViewerDatabase, isTrue);
    expect(await db.getSetting('uji.pembukuan'), isNull);
    await db.setSetting('owner.summary.signed', 'ringkasan');
    expect(db.databasePath, endsWith('viewer_OWNER_1.db'));

    await db.useMainDatabase();
    expect(db.isViewerDatabase, isFalse);
    expect(await db.getSetting('uji.pembukuan'), 'Toko Utama');
    expect(await db.getSetting('owner.summary.signed'), isNull);
  });

  test('sesi ringkasan ditandai read-only', () async {
    const profile = SessionProfile(
      mode: 'viewer',
      ownerId: 'OWNER1',
      nama: 'pemilik@contoh.com',
      role: 'owner',
      storeIds: ['toko-a'],
    );
    expect(profile.isOwner, isTrue);
    expect(profile.isViewer, isTrue);
    expect(SessionProfile.fromJson(profile.toJson()).isViewer, isTrue);
    expect(
      const SessionProfile(
        mode: 'employee',
        ownerId: 'OWNER1',
        nama: 'Kasir',
        role: 'KASIR',
      ).isViewer,
      isFalse,
    );
  });
}
