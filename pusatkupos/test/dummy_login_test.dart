import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/account_service.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/dev/dummy_seed.dart';

void main() {
  SecureStore.useMemoryForTests = true;
  test('seed dummy menyediakan seluruh peran untuk login lokal', () async {    if (!dummySeedEnabled) {
      markTestSkipped(
        'Jalankan dengan --dart-define=PUSATKU_DUMMY_SEED=true.',
      );
      return;
    }
    final dir = await Directory.systemTemp.createTemp('pusatkupos_dummy_');
    await AppDatabase.instance.initForTest(p.join(dir.path, 'dummy.db'));
    await seedDummyDataIfEnabled();
    expect(await LicenseService.instance.ownerId(), dummyOwnerId);
    final accounts = [
      (data: dummyKasir, role: 'KASIR'),
      (data: dummyMekanik, role: 'MEKANIK'),
      (data: dummyKeduanya, role: 'KEDUANYA'),
      (data: dummyPenanggungJawab, role: 'KEDUANYA'),
    ];
    for (final entry in accounts) {
      final operator = await AccountService.instance.loginLocal(
        username: entry.data.username,
        password: entry.data.password,
      );
      expect(operator, isNotNull, reason: entry.data.username);
      expect(operator!.role, entry.role, reason: entry.data.username);
    }
    final approver = await AccountService.instance.loginLocal(
      username: dummyPenanggungJawab.username,
      password: dummyPenanggungJawab.password,
    );
    expect(approver!.can('setujui'), isTrue);
    expect(
      await AccountService.instance.loginLocal(
        username: dummyKasir.username,
        password: 'salah',
      ),
      isNull,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
