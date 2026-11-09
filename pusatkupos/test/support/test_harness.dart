import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/feature_flags.dart';
import 'package:pusatkupos/ui/theme.dart';

import 'test_database.dart';

/// Harness unit test service yang memakai database in-memory.
class ServiceTestHarness {
  Database? _db;

  Database get db {
    final value = _db;
    if (value == null) {
      throw StateError('Harness belum dijalankan. Panggil setUp() lebih dulu.');
    }
    return value;
  }

  Future<void> setUp({String storeId = 'utama'}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _db = await openTestDatabase(storeId: storeId);
    await AppDatabase.instance.useTestDatabase(_db!, storeId: storeId);
    await FeatureFlagsService.instance.load();
  }

  Future<void> tearDown() async {
    await AppDatabase.instance.close();
    FeatureFlagsService.instance.resetForStore();
    _db = null;
  }
}

/// Membungkus widget uji dengan MaterialApp dan tema aplikasi.
Future<void> pumpTestWidget(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: home,
    ),
  );
  await tester.pump();
}
