import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/pajak.dart';
import 'package:pusatkupos/data/pajak_payment_service.dart';
import 'package:pusatkupos/data/store_settings.dart';

import '../support/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  late ServiceTestHarness harness;
  late Database db;

  setUp(() async {
    harness = ServiceTestHarness();
    await harness.setUp();
    db = harness.db;
    await StoreSettingsService.instance.ensure();
  });

  tearDown(() async {
    await harness.tearDown();
  });

  Future<void> setPajak() {
    return db.update('store_settings', {
      'pajak_aktif': 1,
      'pajak_mode': pajakModeEksklusif,
      'pajak_persen_bp': 1100,
      'pajak_penanggung': pajakPenanggungPembeli,
    });
  }

  Future<void> createNotaWithPpn() async {
    final now = nowIso();
    final customerId = await db.insert('customers', {
      'sync_id': newSyncId(),
      'nama': 'Budi',
      'nomor_hp': '08123456789',
      'created_at': now,
      'updated_at': now,
    });
    final unitId = await db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'nopol': 'B 1234 XY',
      'created_at': now,
      'updated_at': now,
    });
    await AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Servis berkala',
      jobs: [
        JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 100000),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 111000,
      actor: Operator.owner,
    );
  }

  Map<String, Object?> remotePayload({
    required String syncId,
    required String masa,
    required int nominal,
    String? cashSyncId,
  }) {
    final now = nowIso();
    return {
      'sync_id': syncId,
      'store_id': 'utama',
      'device_id': 'perangkat-lain',
      'origin_device_id': 'perangkat-lain',
      'request_id': 'REQ-$syncId',
      'masa': masa,
      'jenis': 'PPN',
      'metode': 'CASH',
      'nominal': nominal,
      'cash_sync_id': cashSyncId,
      'dibayar_at': now,
      'operator': 'Pemilik',
      'created_at': now,
      'updated_at': now,
    };
  }

  test('pembayaran remote melebihi sisa kewajiban ditolak tanpa data', () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);

    await expectLater(
      AppDatabase.instance.db.transaction(
        (txn) => PajakPaymentService.instance.applyRemote(
          txn,
          remotePayload(syncId: newSyncId(), masa: masa, nominal: 11001),
          wall: 1,
          counter: 1,
        ),
      ),
      throwsA(
        isA<PajakPaymentRejected>().having(
          (error) => error.reason,
          'reason',
          'pembayaran_ppn_melebihi_sisa',
        ),
      ),
    );

    expect(await db.query('pajak_pembayaran'), isEmpty);
    expect((await db.query('cash_ledger')).where(
      (row) => '${row['sumber_entity']}' == 'pajak_pembayaran',
    ), isEmpty);
  });

  test('pembayaran remote tepat sisa diterima dan menghasilkan kas', () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);
    final syncId = newSyncId();

    await AppDatabase.instance.db.transaction(
      (txn) => PajakPaymentService.instance.applyRemote(
        txn,
        remotePayload(syncId: syncId, masa: masa, nominal: 11000),
        wall: 1,
        counter: 1,
      ),
    );

    final payment = (await db.query('pajak_pembayaran')).single;
    expect(payment['nominal'], 11000);
    final cashId = payment['cash_sync_id'] as String?;
    expect(cashId, isNotNull);
    expect(cashId, isNotEmpty);
    final cash = (await db.query(
      'cash_ledger',
      where: 'sync_id = ?',
      whereArgs: [cashId],
    )).single;
    expect(cash['nominal'], -11000);
  });

  test('pembayaran remote kedua melebihi sisa setelah pembayaran pertama',
      () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);

    await AppDatabase.instance.db.transaction(
      (txn) => PajakPaymentService.instance.applyRemote(
        txn,
        remotePayload(syncId: newSyncId(), masa: masa, nominal: 6000),
        wall: 1,
        counter: 1,
      ),
    );

    await expectLater(
      AppDatabase.instance.db.transaction(
        (txn) => PajakPaymentService.instance.applyRemote(
          txn,
          remotePayload(syncId: newSyncId(), masa: masa, nominal: 5001),
          wall: 2,
          counter: 1,
        ),
      ),
      throwsA(isA<PajakPaymentRejected>()),
    );
    expect(await db.query('pajak_pembayaran'), hasLength(1));
  });

  test('cash_sync_id remote yang bentrok diganti agar kas tidak hilang',
      () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);
    final now = nowIso();
    await db.insert('cash_ledger', {
      'sync_id': 'CASH-LAMA',
      'store_id': 'utama',
      'device_id': '',
      'waktu': now,
      'kategori': 'LAIN',
      'sumber_entity': 'lain',
      'sumber_sync_id': 'sumber-lain',
      'nominal': 500,
      'metode': 'CASH',
      'created_at': now,
      'updated_at': now,
    });

    await AppDatabase.instance.db.transaction(
      (txn) => PajakPaymentService.instance.applyRemote(
        txn,
        remotePayload(
          syncId: newSyncId(),
          masa: masa,
          nominal: 11000,
          cashSyncId: 'CASH-LAMA',
        ),
        wall: 1,
        counter: 1,
      ),
    );

    final payment = (await db.query('pajak_pembayaran')).single;
    expect(payment['cash_sync_id'], isNot('CASH-LAMA'));
    final baru = await db.query(
      'cash_ledger',
      where: 'sync_id = ?',
      whereArgs: [payment['cash_sync_id']],
    );
    expect(baru, hasLength(1));
    expect(baru.single['nominal'], -11000);
    final lama = await db.query(
      'cash_ledger',
      where: 'sync_id = ?',
      whereArgs: ['CASH-LAMA'],
    );
    expect(lama.single['nominal'], 500);
  });

  test('pembayaran lokal melebihi sisa tetap ditolak', () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);

    await expectLater(
      PajakPaymentService.instance.createPayment(
        input: PajakPaymentInput(masa: masa, nominalCents: 11001),
        actor: Operator.owner,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await db.query('pajak_pembayaran'), isEmpty);
  });

  test('pembayaran lokal kedua memakai sisa yang tersisa di transaksi',
      () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);

    final first = await PajakPaymentService.instance.createPayment(
      input: PajakPaymentInput(masa: masa, nominalCents: 6000),
      actor: Operator.owner,
    );
    expect(first['sisa_kewajiban'], 5000);

    await expectLater(
      PajakPaymentService.instance.createPayment(
        input: PajakPaymentInput(masa: masa, nominalCents: 5001),
        actor: Operator.owner,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await db.query('pajak_pembayaran'), hasLength(1));
  });

  test('void pembayaran PPN mengembalikan kas dan menulis audit', () async {
    await setPajak();
    await createNotaWithPpn();
    final masa = nowIso().substring(0, 7);

    await PajakPaymentService.instance.createPayment(
      input: PajakPaymentInput(masa: masa, nominalCents: 6000),
      actor: Operator.owner,
    );
    final payment = (await db.query('pajak_pembayaran')).single;
    await PajakPaymentService.instance.voidPayment(
      paymentId: payment['id'] as int,
      alasan: 'Salah masa',
      actor: Operator.owner,
    );

    final voided = (await db.query('pajak_pembayaran')).single;
    expect(voided['status'], 'VOID');
    final masuk = await db.query(
      'cash_ledger',
      where: 'kategori = ?',
      whereArgs: ['BAYAR_PPN_VOID'],
    );
    expect(masuk.single['nominal'], 6000);
    final audits = await db.query(
      'business_audits',
      where: 'entity = ?',
      whereArgs: ['pajak_pembayaran'],
    );
    expect(audits, hasLength(2));
  });
}
