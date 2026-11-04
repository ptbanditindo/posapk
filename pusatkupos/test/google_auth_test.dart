import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/secure_store.dart';

import 'test_support.dart';

void main() {
  SecureStore.useDatabaseForTests = true;

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_google_');
    await AppDatabase.instance.initForTest(p.join(dir.path, 'google.db'));
  });

  tearDown(() async {
    LicenseService.instance.clearCache();
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  test('identitas owner dari relay dipakai saat perangkat belum punya owner',
      () async {
    await LicenseService.instance.installRemoteOwner(
      ownerId: 'owner-google',
      publicKey: 'public-key-google',
    );
    expect(await LicenseService.instance.ownerId(), 'owner-google');
    expect(await LicenseService.instance.ownerPublicKey(), 'public-key-google');
    final claims = await installTestLicense(ownerId: 'owner-google');
    expect(claims.premium, isTrue);
    expect(await LicenseService.instance.isPremium(), isTrue);
  });

  test('identitas relay yang berbeda ditolak', () async {
    await LicenseService.instance.installRemoteOwner(
      ownerId: 'owner-lokal',
      publicKey: 'kunci-lokal',
    );
    await expectLater(
      LicenseService.instance.installRemoteOwner(
        ownerId: 'owner-lain',
        publicKey: 'kunci-lain',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('kunci publik yang berbeda ditolak', () async {
    await LicenseService.instance.installRemoteOwner(
      ownerId: 'owner-sama',
      publicKey: 'kunci-a',
    );
    await expectLater(
      LicenseService.instance.installRemoteOwner(
        ownerId: 'owner-sama',
        publicKey: 'kunci-b',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('owner lokal yang sudah ada tidak ditimpa', () async {
    final localId = await LicenseService.instance.ensureOwner();
    await expectLater(
      LicenseService.instance.installRemoteOwner(
        ownerId: 'owner-google',
        publicKey: 'kunci-google',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await LicenseService.instance.ownerId(), localId);
  });
}
