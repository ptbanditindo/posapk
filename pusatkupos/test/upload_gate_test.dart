import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/sync/sync_service.dart';

import 'test_support.dart';

void main() {
  SecureStore.useMemoryForTests = true;
  late Directory dir;
  final db = AppDatabase.instance;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_upload_');
    await db.initForTest(p.join(dir.path, 'utama.db'));
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('status sync perangkat tersimpan di database lokal', () async {
    final stamp = nowIso();
    for (final row in [
      {
        'device_id': 'dev_a',
        'nama': 'Karyawan A',
        'kind': 'employee',
        'state': 'synced',
        'last_seq': 12,
        'pending': 0,
        'updated_at': stamp,
      },
      {
        'device_id': 'dev_b',
        'nama': 'Karyawan B',
        'kind': 'employee',
        'state': 'pending',
        'last_seq': 10,
        'pending': 2,
        'updated_at': stamp,
      },
      {
        'device_id': 'dev_owner',
        'nama': 'Pemilik',
        'kind': 'owner',
        'state': 'synced',
        'last_seq': 12,
        'pending': 0,
        'updated_at': stamp,
      },
    ]) {
      await db.db.insert('device_sync_status', row);
    }
    final rows = await SyncService.instance.cachedDeviceSyncStatus();
    expect(rows.length, 3);
    expect(rows.first['kind'], 'owner');
    final pending = rows.firstWhere((row) => row['device_id'] == 'dev_b');
    expect(pending['state'], 'pending');
    expect(pending['pending'], 2);
    expect(AppDatabase.schemaVersion, 1);
  });

  test('upload tidak bisa dimulai tanpa perangkat terdaftar', () async {
    await installTestLicense(ownerId: 'OWNER-UJI', google: true);
    await expectLater(
      SyncService.instance.startUploadCheck(),
      throwsA(isA<StateError>()),
    );
  });
}
