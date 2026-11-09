import 'package:flutter_test/flutter_test.dart';

import 'package:pusatkupos/data/app_database.dart';

import '../support/test_harness.dart';

void main() {
  final harness = ServiceTestHarness();

  setUp(harness.setUp);
  tearDown(harness.tearDown);

  test('harness service membuka skema bersih in-memory', () async {
    final tables = await harness.db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name = 'service_records'",
    );

    expect(tables, isNotEmpty);
    expect(AppDatabase.instance.isOpen, isTrue);
    expect(AppDatabase.instance.activeStoreId, 'utama');
  });

  test('pengaturan dapat ditulis dan dibaca lewat AppDatabase', () async {
    await AppDatabase.instance.setSetting('uji.harness', 'aktif');

    expect(await AppDatabase.instance.getSetting('uji.harness'), 'aktif');
  });
}
