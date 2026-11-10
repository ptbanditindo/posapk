import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/session_service.dart';
import 'package:pusatkupos/state/app_state.dart';
import 'package:pusatkupos/ui/entry_gate.dart';

import '../support/test_database.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

Future<void> _writeFile(String path, [String text = 'x']) async {
  await File(path).writeAsString(text, flush: true);
}

Future<void> _seedSignedInStore(Database db, String path) async {
  await AppDatabase.instance.setSetting('bengkel.nama', 'Toko Lama');
  await AppDatabase.instance.setSetting('sync.store_id', 'utama');
  await db.insert('owner_identity', {
    'id': 1,
    'owner_id': 'OWNER1',
    'public_key': 'pk',
    'recovery_hash': 'hash',
    'recovery_salt': 'salt',
    'created_at': '2026-01-01T00:00:00.000Z',
  });
  // Berkas turunan yang wajib ikut dibuang untuk pemilik.
  await _writeFile('$path-wal');
  await _writeFile('$path-shm');
  await _writeFile('$path.schema_version', '10');
  await _writeFile('$path.bak-20260101-000000');
  await _writeFile('$path.corrupt-20260101-000000');
  await _writeFile(p.join(p.dirname(path), 'viewer_OWNER1.db'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  late Directory dir;
  late String path;

  setUp(() async {
    ensureTestDatabaseFactory();
    dir = await Directory.systemTemp.createTemp('pusatku-signout');
    path = p.join(dir.path, 'toko.db');
    final db = await openTestDatabaseAt(path);
    await AppDatabase.instance.useTestDatabase(db, path: path);
    await _seedSignedInStore(db, path);
  });

  tearDown(() async {
    AppState.instance.setOperator(null);
    await AppDatabase.instance.close();
    SessionService.allowOwnerRebind = false;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('pemilik keluar mempertahankan database dan sesi lama', () async {
    await signOutSession(owner: true);

    expect(AppDatabase.instance.isOpen, isTrue);
    final db = AppDatabase.instance.db;
    expect(
      (await db.query('owner_identity')).single['owner_id'],
      'OWNER1',
    );
    expect(
      await AppDatabase.instance.getSetting('bengkel.nama'),
      'Toko Lama',
    );
    expect(await AppDatabase.instance.getSetting('sync.store_id'), 'utama');
    expect(await File('$path-wal').exists(), isTrue);
    expect(await File('$path.bak-20260101-000000').exists(), isTrue);
    expect(
      await File(p.join(dir.path, 'viewer_OWNER1.db')).exists(),
      isTrue,
    );
  });

  test('hapus database lokal membuka database kosong bersih', () async {
    await AppDatabase.instance.deleteLocalDatabases();

    expect(AppDatabase.instance.isOpen, isTrue);
    final db = AppDatabase.instance.db;
    expect(await db.query('owner_identity'), isEmpty);
    // Database baru hanya memuat nilai bawaan, bukan data toko lama.
    expect(
      await AppDatabase.instance.getSetting('bengkel.nama'),
      'PUSATKU POS',
    );
    expect(await AppDatabase.instance.getSetting('sync.store_id'), isNull);
    // WAL/SHM boleh dibuat ulang oleh database kosong yang baru dibuka.
    expect(await File('$path.bak-20260101-000000').exists(), isFalse);
    expect(await File('$path.corrupt-20260101-000000').exists(), isFalse);
    expect(
      await File(p.join(dir.path, 'viewer_OWNER1.db')).exists(),
      isFalse,
    );
    // Penanda ditulis ulang oleh database kosong yang baru dibuka.
    expect(
      await File('$path.schema_version').readAsString(),
      '${AppDatabase.schemaVersion}',
    );
  });

  test('karyawan keluar tidak menghapus database lokal', () async {
    await signOutSession(owner: false);

    expect(AppDatabase.instance.isOpen, isTrue);
    expect(
      await AppDatabase.instance.getSetting('bengkel.nama'),
      'Toko Lama',
    );
    expect(
      (await AppDatabase.instance.db.query('owner_identity')).single['owner_id'],
      'OWNER1',
    );
    expect(await File('$path-wal').exists(), isTrue);
    expect(await File('$path.bak-20260101-000000').exists(), isTrue);
    expect(
      await File(p.join(dir.path, 'viewer_OWNER1.db')).exists(),
      isTrue,
    );
  });
}
