import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pusatkupos/core/app_config.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/backup_manifest.dart';
import 'package:pusatkupos/data/restore_lock.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';

import '../support/test_database.dart';

Map<String, Object?> _customer(String syncId, String nama) => {
  'sync_id': syncId,
  'store_id': 'utama',
  'device_id': '',
  'nama': nama,
  'nama_normalized': nama.toLowerCase(),
  'nomor_hp': '080000000$nama',
  'nomor_hp_normalized': '080000000$nama',
  'created_at': '2026-11-09T00:00:00',
  'updated_at': '2026-11-09T00:00:00',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('metadata backup', () {
    test('manifest memuat versi skema, kontrak, dan aplikasi', () {
      final manifest = buildBackupManifest(
        format: 3,
        schemaVersion: AppDatabase.schemaVersion,
        contractVersion: AppDatabase.schemaContractVersion,
        appVersion: appVersion,
        createdAt: '2026-11-09T00:00:00',
        activeStoreId: 'utama',
        stores: const [],
      );
      expect(manifest['schema_version'], AppDatabase.schemaVersion);
      expect(
        manifest['schema_contract_version'],
        AppDatabase.schemaContractVersion,
      );
      expect(manifest['app_version'], appVersion);

      final typed = Map<String, dynamic>.from(manifest);
      expect(
        validateBackupManifest(
          typed,
          schemaVersion: AppDatabase.schemaVersion,
          contractVersion: AppDatabase.schemaContractVersion,
        ),
        isNull,
      );
      expect(
        validateBackupManifest(
          {...typed, 'schema_version': AppDatabase.schemaVersion + 1},
          schemaVersion: AppDatabase.schemaVersion,
          contractVersion: AppDatabase.schemaContractVersion,
        ),
        contains('lebih baru'),
      );
      expect(
        validateBackupManifest(
          {
            ...typed,
            'schema_contract_version': AppDatabase.schemaContractVersion + 1,
          },
          schemaVersion: AppDatabase.schemaVersion,
          contractVersion: AppDatabase.schemaContractVersion,
        ),
        contains('kontrak'),
      );
    });
  });

  group('inventaris isi backup', () {
    test('mencatat tabel, jumlah baris, checksum, dan user_version', () async {
      final dir = await Directory.systemTemp.createTemp('pusatkupos_inv_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final path = '${dir.path}/sumber.db';
      final source = await openTestDatabaseAt(path);
      await source.insert('customers', _customer('c1', 'Andi'));
      await source.insert('customers', _customer('c2', 'Budi'));
      await source.rawQuery('PRAGMA wal_checkpoint(FULL)');
      await source.close();

      final app = AppDatabase.instance;
      final inventory = await app.inspectPlainDatabase(path);
      expect(inventory.userVersion, AppDatabase.schemaVersion);
      expect(inventory.tables['customers']!.rows, 2);
      expect(inventory.tables['customers']!.sha256, isNotEmpty);
      expect(compareBackupInventory(inventory, inventory), isNull);

      final tampered = BackupInventory(
        userVersion: inventory.userVersion,
        tables: {
          ...inventory.tables,
          'customers': const BackupTableInventory(rows: 3, sha256: 'beda'),
        },
      );
      expect(
        compareBackupInventory(tampered, inventory),
        contains('Jumlah baris'),
      );
    });

    test('salinan polos memakai VACUUM INTO dan memuat transaksi terakhir',
        () async {
      final dir = await Directory.systemTemp.createTemp('pusatkupos_vacuum_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final sourcePath = '${dir.path}/sumber.db';
      final targetPath = '${dir.path}/salinan.db';
      final source = await openTestDatabaseAt(sourcePath);
      final app = AppDatabase.instance;
      await app.useTestDatabase(source, path: sourcePath);
      addTearDown(app.close);

      await source.insert('customers', _customer('c1', 'Citra'));
      await app.exportPortableCopy(targetPath);
      final copy = await app.inspectPlainDatabase(
        targetPath,
        requiredTables: const ['customers'],
      );
      expect(copy.tables['customers']!.rows, 1);
      expect(copy.userVersion, AppDatabase.schemaVersion);
    });

    test('salinan dengan versi lama disetel ulang ke versi aplikasi', () async {
      final dir = await Directory.systemTemp.createTemp('pusatkupos_migrate_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final path = '${dir.path}/lama.db';
      final source = await openTestDatabaseAt(path);
      await source.execute('PRAGMA user_version = 3');
      await source.close();

      final app = AppDatabase.instance;
      final before = await app.inspectPlainDatabase(path);
      expect(before.userVersion, 3);
      await app.migratePlainCopy(path);
      final after = await app.inspectPlainDatabase(path);
      expect(after.userVersion, AppDatabase.schemaVersion);
    });
  });

  group('status restore', () {
    test('kunci restore menolak restore ganda dan selalu melepas', () {
      final lock = RestoreLock.instance;
      addTearDown(lock.end);
      expect(lock.begin(), isTrue);
      expect(lock.isRestoring, isTrue);
      expect(lock.begin(), isFalse);
      lock.end();
      expect(lock.isRestoring, isFalse);
      lock.end();
      expect(lock.isRestoring, isFalse);
    });
  });

  group('metadata snapshot', () {
    test('snapshot membawa kontrak dan versi aplikasi serta menolak yang baru',
        () async {
      final source = await openTestDatabase();
      final app = AppDatabase.instance;
      await app.useTestDatabase(source);
      addTearDown(app.close);
      final signing = await generateSigningKey();
      final storeKey = List<int>.generate(32, (index) => index + 1);

      final payload = await app.createSnapshotPayload(
        storeId: 'utama',
        deviceId: 'sumber-1',
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeSeq: 4,
      );
      expect(
        payload['schema_contract_version'],
        AppDatabase.schemaContractVersion,
      );
      expect(payload['app_version'], appVersion);

      final rejected = await app
          .applySnapshotPayload(
            {
              'snapshot': {
                'ciphertext': 'x',
                'nonce': 'y',
                'signature': 'z',
                'schema_contract_version':
                    AppDatabase.schemaContractVersion + 1,
              },
            },
            senderPublicKey: signing.publicKey,
            storeKey: storeKey,
            storeId: 'utama',
            deviceId: 'penerima-1',
          )
          .then<Object?>((value) => value)
          .catchError((Object error) => error);
      expect(rejected, isA<StateError>());
    });
  });
}
