import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';

void main() {
  test('snapshot owner diterapkan ke perangkat baru', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_snap_');
    final owner = AppDatabase();
    final device = AppDatabase();
    await owner.initForTest(p.join(dir.path, 'owner.db'));
    await device.initForTest(p.join(dir.path, 'device.db'));
    try {
      await owner.setSetting('bengkel.nama', 'BENGKEL SNAPSHOT');
      await owner.db.insert('owner_identity', {
        'id': 1,
        'owner_id': 'OWNER123',
        'public_key': 'pub',
        'created_at': nowIso(),
      });
      final customerId = await owner.addCustomer(
        nama: 'Pelanggan Snapshot',
        nomorHp: '081200000003',
      );
      final unitId = await owner.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 3 SNAP',
      );
      await owner.saveStockItem(
        kode: 'SP-200',
        nama: 'Radiator Snapshot',
        hargaModalCents: 10000000,
        hargaJualCents: 20000000,
        jumlah: 6,
        stokMinimum: 1,
      );
      final stock = (await owner.listStock()).first;
      final recordId = await owner.createTransaction(
        unitId: unitId,
        keluhan: 'Servis snapshot',
        jobs: [
          JobDraft(deskripsi: 'Servis', jumlah: 1, hargaCents: 5000000),
        ],
        parts: [
          PartDraft(
            stockItemId: stock.id,
            nama: stock.nama,
            jumlah: 2,
            hargaCents: stock.hargaJualCents,
            modalCents: stock.hargaModalCents,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 45000000,
      );
      final noNota = (await owner.recordDetail(recordId))!.record.noNota;

      await device.setSetting('sync.relay_url', 'http://127.0.0.1:8120');
      await device.setSetting('device.nota_prefix', 'ZZZZ');
      await device.setSetting('bengkel.nama', 'BENGKEL LAMA');

      final signing = await generateSigningKey();
      final storeKey = List<int>.generate(32, (index) => index);
      final payload = await owner.createSnapshotPayload(
        storeId: 'utama',
        deviceId: 'device-owner',
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeSeq: 7,
      );
      final result = await device.applySnapshotPayload(
        payload,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'device-baru',
      );
      expect(result['applied'], isTrue);
      expect(result['store_seq'], 7);

      final detail = await device.recordDetail(1);
      expect(detail, isNotNull);
      expect(detail!.record.noNota, noNota);
      expect(detail.payments.single.nominalCents, 45000000);
      expect((await device.listStock()).single.jumlah, 4);
      expect(await device.getSetting('bengkel.nama'), 'BENGKEL SNAPSHOT');
      expect(
        await device.getSetting('sync.relay_url'),
        'http://127.0.0.1:8120',
      );
      expect(await device.getSetting('device.nota_prefix'), 'ZZZZ');
      expect((await device.db.query('owner_identity')).length, 0);
      final cursor = await device.db.query(
        'sync_cursor',
        where: 'store_id = ? AND device_id = ?',
        whereArgs: ['utama', 'device-baru'],
      );
      expect(cursor.single['last_seq'], 7);

      final tampered = Map<String, Object?>.from(payload)
        ..['id'] = 'snapshot-tamper'
        ..['checksum'] = '0' * 64;
      await expectLater(
        device.applySnapshotPayload(
          tampered,
          senderPublicKey: signing.publicKey,
          storeKey: storeKey,
          storeId: 'utama',
          deviceId: 'device-baru',
        ),
        throwsA(isA<StateError>()),
      );

      final duplicate = await device.applySnapshotPayload(
        payload,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'device-baru',
      );
      expect(duplicate['applied'], isFalse);
    } finally {
      await owner.close();
      await device.close();
      await dir.delete(recursive: true);
    }
  });

  test('snapshot ditolak saat outbox lokal masih pending', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_snap_pending_');
    final owner = AppDatabase();
    final device = AppDatabase();
    await owner.initForTest(p.join(dir.path, 'owner.db'));
    await device.initForTest(p.join(dir.path, 'device.db'));
    try {
      final signing = await generateSigningKey();
      final storeKey = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final payload = await owner.createSnapshotPayload(
        storeId: 'utama',
        deviceId: 'device-owner',
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeSeq: 1,
      );
      await device.db.insert('sync_outbox', {
        'device_id': 'device-baru',
        'seq': 1,
        'hlc_wall': 1,
        'hlc_counter': 0,
        'idempotency_key': 'pending-1',
        'entity': 'nota',
        'entity_id': 'x',
        'action': 'upsert',
        'payload_json': '{}',
        'status': 'pending',
        'created_at': nowIso(),
      });
      await expectLater(
        device.applySnapshotPayload(
          payload,
          senderPublicKey: signing.publicKey,
          storeKey: storeKey,
          storeId: 'utama',
          deviceId: 'device-baru',
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      await owner.close();
      await device.close();
      await dir.delete(recursive: true);
    }
  });
}
