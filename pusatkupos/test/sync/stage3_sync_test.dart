import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/note_sync.dart';
import 'package:pusatkupos/data/store_registry.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';
import 'package:pusatkupos/sync/sync_conflict_rules.dart';
import 'package:pusatkupos/sync/sync_scheduler.dart';
import 'package:pusatkupos/sync/sync_service.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Tanpa ini flutter_test memakai Android, sehingga AppDatabase memilih
  // SQLCipher yang tidak tersedia di VM.
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('snapshot dari skema', () {
    test('memuat tabel bersama baru dan tidak memuat tabel lokal', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final order = await snapshotSharedTableOrder(db);

      expect(
        order,
        containsAll([
          'cash_ledger',
          'opname_holds',
          'audit_events',
          'stock_items',
          'service_records',
        ]),
      );
      for (final local in snapshotLocalTables) {
        expect(order, isNot(contains(local)), reason: 'tabel lokal $local');
      }
      expect(order, isNot(contains('app_meta')));
      expect(order, isNot(contains('sqlite_sequence')));
      // Induk harus lebih dulu saat menyisipkan.
      expect(
        order.indexOf('stock_items'),
        lessThan(order.indexOf('stock_movements')),
      );
      expect(
        order.indexOf('service_records'),
        lessThan(order.indexOf('service_parts')),
      );
      // Hapus anak lebih dulu: urutan terbalik.
      final deleteOrder = order.reversed.toList();
      expect(
        deleteOrder.indexOf('stock_movements'),
        lessThan(deleteOrder.indexOf('stock_items')),
      );
    });

    test('payload menyimpan versi skema dan menolak versi lebih baru',
        () async {
      final source = await openTestDatabase(storeId: 'utama');
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
        storeSeq: 7,
      );
      expect(payload['schema_version'], AppDatabase.schemaVersion);

      final rejected = await app.applySnapshotPayload(
        {
          'snapshot': {
            'ciphertext': 'x',
            'nonce': 'y',
            'signature': 'z',
            'schema_version': AppDatabase.schemaVersion + 1,
          },
        },
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'penerima-1',
      ).then<Object?>((value) => value).catchError((Object error) => error);
      expect(rejected, isA<StateError>());
    });

    test('snapshot membawa kas dan opname, lalu idempoten saat diulang',
        () async {
      final dir = Directory.systemTemp.createTempSync('pusatkupos_snapshot_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final source = await openTestDatabaseAt(
        p.join(dir.path, 'sumber.db'),
        storeId: 'utama',
      );
      final app = AppDatabase.instance;
      await app.useTestDatabase(source, path: p.join(dir.path, 'sumber.db'));
      addTearDown(app.close);
      final now = nowIso();
      await source.insert('cash_ledger', {
        'sync_id': 'kas-1',
        'store_id': 'utama',
        'device_id': 'sumber-1',
        'waktu': now,
        'kategori': 'PENJUALAN',
        'sumber_entity': 'payment',
        'sumber_sync_id': 'bayar-1',
        'nominal': 50000,
        'metode': 'CASH',
        'created_at': now,
        'updated_at': now,
      });
      await source.insert('opname_holds', {
        'sync_id': 'opname-1',
        'store_id': 'utama',
        'device_id': 'sumber-1',
        'stock_item_id': 1,
        'stock_sync_id': 'stok-1',
        'nama_item': 'Oli',
        'jumlah_fisik_milli': 3000,
        'created_at': now,
        'updated_at': now,
      });
      final signing = await generateSigningKey();
      final storeKey = List<int>.generate(32, (index) => index + 1);
      final payload = await app.createSnapshotPayload(
        storeId: 'utama',
        deviceId: 'sumber-1',
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeSeq: 9,
      );

      final targetPath = p.join(dir.path, 'penerima.db');
      final target = await openTestDatabaseAt(targetPath, storeId: 'utama');
      await app.useTestDatabase(target, path: targetPath);
      await target.insert('sync_conflicts', {
        'entity': 'nota',
        'entity_id': 'lokal-1',
        'reason': 'uji_lokal',
        'created_at': now,
      });

      final first = await app.applySnapshotPayload(
        payload,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'penerima-1',
      );
      expect(first['applied'], isTrue);
      expect(
        (await target.query('cash_ledger')).single['sync_id'],
        'kas-1',
      );
      expect(
        (await target.query('opname_holds')).single['sync_id'],
        'opname-1',
      );
      expect(
        (await target.query('sync_conflicts')).single['reason'],
        'uji_lokal',
      );

      final second = await app.applySnapshotPayload(
        payload,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'penerima-1',
      );
      expect(second['duplicate'], isTrue);
      expect((await target.query('cash_ledger')).length, 1);
    });
  });

  group('nota dengan kode stok bentrok', () {
    test('nota tetap masuk, kode diberi akhiran unik, konflik tercatat',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await AppDatabase.instance.useTestDatabase(db);
      final now = nowIso();
      await db.insert('stock_items', {
        'sync_id': 'stok-lama',
        'kode': 'OLI-1',
        'nama': 'Oli lama',
        'harga_modal': 20000,
        'harga_jual': 30000,
        'jumlah_milli': 5000,
        'satuan': 'pcs',
        'created_at': now,
        'updated_at': now,
      });

      final payload = <String, Object?>{
        'record': {
          'sync_id': 'nota-1',
          'no_nota': 'INV-001',
          'waktu_service': now,
          'status': 'AKTIF',
          'status_bayar': 'LUNAS',
          'metode_bayar': 'CASH',
          'total_servis': 50000,
          'total_efektif': 50000,
          'total_kas_diterima': 0,
        },
        'customer': {'sync_id': 'pelanggan-1', 'nama': 'Budi'},
        'unit': <String, Object?>{},
        'jobs': <Object?>[],
        'parts': <Object?>[
          {
            'sync_id': 'part-1',
            'stock_sync_id': 'stok-baru',
            'nama_part': 'Oli baru',
            'jumlah_milli': 1000,
            'jumlah': 1,
            'harga_satuan': 50000,
            'subtotal': 50000,
            'stock': {
              'sync_id': 'stok-baru',
              'kode': 'OLI-1',
              'nama': 'Oli baru',
              'jumlah_milli': 0,
              'harga_modal': 30000,
              'harga_jual': 50000,
            },
          },
        ],
        'payments': <Object?>[],
        'returns': <Object?>[],
        'mechanics': <Object?>[],
      };

      final result = await AppDatabase.instance.applyNotePayload(
        db,
        payload,
        action: 'upsert',
      );
      expect(result, 'applied');

      final record = await db.query(
        'service_records',
        where: 'sync_id = ?',
        whereArgs: ['nota-1'],
      );
      expect(record, hasLength(1));

      final baru = await db.query(
        'stock_items',
        where: 'sync_id = ?',
        whereArgs: ['stok-baru'],
      );
      expect(baru.single['kode'], 'OLI-1-2');

      final lama = await db.query(
        'stock_items',
        where: 'sync_id = ?',
        whereArgs: ['stok-lama'],
      );
      expect(lama.single['kode'], 'OLI-1');
      expect(lama.single['jumlah_milli'], 5000);

      final conflicts = await db.query(
        'sync_conflicts',
        where: 'entity = ? AND reason = ?',
        whereArgs: ['stock', 'kode_barang_bentrok'],
      );
      expect(conflicts, hasLength(1));
    });
  });

  group('pergantian toko dan sync', () {
    test('switchStore mengembalikan sesi lama bila toko tujuan gagal dibuka',
        () async {
      final dir = Directory.systemTemp.createTempSync('pusatkupos_switch_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'utama.db');
      final db = await openTestDatabaseAt(path);
      final app = AppDatabase.instance;
      await app.useTestDatabase(db, path: path);
      addTearDown(app.close);
      await app.setSetting('bengkel.nama', 'Toko Utama');

      final badPath = p.join(dir.path, 'bukan_database');
      Directory(badPath).createSync();
      final target = StoreRecord(
        storeId: 'toko-2',
        databaseId: 'toko-2',
        nama: 'Toko Dua',
        databasePath: badPath,
      );

      await expectLater(app.switchStore(target), throwsA(anything));

      expect(app.isOpen, isTrue);
      expect(app.activeStoreId, 'utama');
      expect(await app.getSetting('bengkel.nama'), 'Toko Utama');
    });

    test('hook idle sync selesai tanpa menunggu saat tidak ada putaran',
        () async {
      await SyncService.instance.whenIdle();
      await SyncScheduler.instance.whenIdle();
      expect(SyncScheduler.instance.isStarted, isFalse);
    });

    test('alasan toko tidak cocok bersifat final', () {
      expect(SyncConflictRules.isFinal('toko_tidak_cocok'), isTrue);
    });
  });
}
