import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/account_service.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/device_service.dart';
import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/secure_store.dart';

import 'test_support.dart';

void main() {
  SecureStore.useDatabaseForTests = true;
  test('akun karyawan, lisensi, dan batas perangkat', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_auth_');
    final db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'auth.db'));
    try {
      final ownerId = await LicenseService.instance.ensureOwner();
      await installTestLicense(ownerId: ownerId, deviceLimit: 1);
      expect(await LicenseService.instance.isPremium(), isTrue);
      final account = await AccountService.instance.createAccount(
        username: 'kasir1',
        nama: 'Kasir Satu',
        role: 'KASIR',
        password: 'password123',
        extraPermissions: ['opname'],
      );
      final operator = await AccountService.instance.loginHub(
        username: 'kasir1',
        password: 'password123',
        pin: '123456',
      );
      expect(operator, isNotNull);
      expect(operator!.role, 'KASIR');
      expect(operator.can('opname'), isTrue);
      expect(operator.mustChangePassword, isTrue);
      await AccountService.instance.changePassword(
        account['id'] as int,
        oldPassword: 'password123',
        newPassword: 'password456',
      );
      final changed = await AccountService.instance.loginHub(
        username: 'kasir1',
        password: 'password456',
        pin: '123456',
      );
      expect(changed?.mustChangePassword, isFalse);

      final license = await LicenseService.instance.license();
      expect(license?['plan'], 'premium');
      expect(license?['device_limit'], 1);
      final first = await DeviceService.instance.registerDevice(
        nama: 'HP Owner',
        kind: 'owner',
        makeCurrent: true,
      );
      expect(first['id'], isNotNull);
      expect(await DeviceService.instance.currentDevice(), isNotNull);
      await expectLater(
        DeviceService.instance.registerDevice(
          nama: 'HP Kedua',
          kind: 'owner',
          makeCurrent: false,
        ),
        throwsA(isA<StateError>()),
      );
      await DeviceService.instance.revokeDevice(first['id'] as String);
      final replacement = await DeviceService.instance.registerDevice(
        nama: 'HP Pengganti',
        kind: 'owner',
        makeCurrent: true,
      );
      expect(replacement['id'], isNot(first['id']));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
