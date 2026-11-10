import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/note_sync.dart';
import 'package:pusatkupos/data/order_service.dart';
import 'package:pusatkupos/data/pajak.dart';
import 'package:pusatkupos/data/price_rules.dart';
import 'package:pusatkupos/data/store_settings.dart';
import 'package:pusatkupos/sync/sync_service.dart';

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

  Future<void> setPajak({
    required bool aktif,
    String mode = pajakModeEksklusif,
    int persenBp = 1100,
    String penanggung = pajakPenanggungPembeli,
  }) {
    return db.update('store_settings', {
      'pajak_aktif': aktif ? 1 : 0,
      'pajak_mode': mode,
      'pajak_persen_bp': persenBp,
      'pajak_penanggung': penanggung,
    });
  }

  Future<void> enableType(String type) async {
    final rows = await db.query(
      'store_settings',
      columns: ['transaction_types_json'],
      limit: 1,
    );
    final types = Map<String, Object?>.from(
      jsonDecode(rows.first['transaction_types_json'] as String? ?? '{}')
          as Map,
    );
    types[type] = true;
    await db.update(
      'store_settings',
      {'transaction_types_json': jsonEncode(types)},
    );
  }

  Future<int> insertCustomer({String nama = 'Budi'}) async {
    final now = nowIso();
    return db.insert('customers', {
      'sync_id': newSyncId(),
      'nama': nama,
      'nomor_hp': '08123456789',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> insertUnit(int customerId, {String nopol = 'B 1234 XY'}) async {
    final now = nowIso();
    return db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'nopol': nopol,
      'jenis_mobil': 'Avanza',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> insertCatalog({
    String nama = 'Servis ringan',
    int hargaJual = 80000,
    int hargaModal = 0,
  }) async {
    final now = nowIso();
    return db.insert('harga_jasa', {
      'sync_id': newSyncId(),
      'nama': nama,
      'harga_jual': hargaJual,
      'harga_modal': hargaModal,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> insertStock({
    String nama = 'Oli mesin',
    int hargaJual = 5000,
    int hargaModal = 10000,
    int stokMilli = 10000,
  }) async {
    final now = nowIso();
    return db.insert('stock_items', {
      'sync_id': newSyncId(),
      'kode': 'OLI-1',
      'nama': nama,
      'harga_jual': hargaJual,
      'harga_modal': hargaModal,
      'jumlah_milli': stokMilli,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<Map<String, Object?>>> estimateItems(String syncId) {
    return db.query(
      'estimate_items',
      where: 'estimate_sync_id = ?',
      whereArgs: [syncId],
    );
  }

  test('estimasi EKSLUSIF tersimpan, konversi menyalin snapshot PPN', () async {
    await setPajak(aktif: true);
    await enableType(transactionOrderKerja);
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);

    final estimate = await OrderService.instance.createEstimate(
      customerId: customerId,
      unitId: unitId,
      jenisTransaksi: transactionOrderKerja,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Jasa servis',
          jumlah: 1,
          hargaCents: 100000,
          modalCents: 0,
        ),
      ],
      actor: Operator.owner,
    );
    expect(estimate, isNotNull);
    expect(estimate!.jenisTransaksi, transactionOrderKerja);
    expect(estimate.dppCents, 100000);
    expect(estimate.ppnCents, 11000);
    expect(estimate.totalDitagihCents, 111000);
    expect(estimate.totalCents, 111000);

    final recordId = await OrderService.instance.convertEstimateToNote(
      estimateSyncId: estimate.syncId,
      metodeBayar: 'CASH',
      bayarCents: 111000,
      actor: Operator.owner,
    );

    final record = (await db.query(
      'service_records',
      where: 'id = ?',
      whereArgs: [recordId],
    )).first;
    expect(record['jenis_transaksi'], transactionOrderKerja);
    expect(record['pajak_mode'], pajakModeEksklusif);
    expect(record['pajak_dpp'], 100000);
    expect(record['pajak'], 11000);
    expect(record['total_servis'], 111000);
    final after = (await db.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [estimate.syncId],
    )).first;
    expect(after['status'], 'dikonversi');
  });

  test('estimasi INKLUSIF membagi DPP dan PPN konsisten saat konversi', () async {
    await setPajak(aktif: true, mode: pajakModeInklusif);
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);

    final estimate = await OrderService.instance.createEstimate(
      customerId: customerId,
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Jasa servis',
          jumlah: 1,
          hargaCents: 100000,
          modalCents: 0,
        ),
      ],
      actor: Operator.owner,
    );
    expect(estimate!.dppCents, 90090);
    expect(estimate.ppnCents, 9910);
    expect(estimate.totalDitagihCents, 100000);

    final recordId = await OrderService.instance.convertEstimateToNote(
      estimateSyncId: estimate.syncId,
      metodeBayar: 'CASH',
      bayarCents: 100000,
      actor: Operator.owner,
    );
    final record = (await db.query(
      'service_records',
      where: 'id = ?',
      whereArgs: [recordId],
    )).first;
    expect(record['pajak_mode'], pajakModeInklusif);
    expect(record['pajak_dpp'], 90090);
    expect(record['pajak'], 9910);
    expect(record['total_servis'], 100000);
  });

  test('jasa bebas tanpa modal boleh, barang di bawah modal tetap ditolak',
      () async {
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);

    final freeId = await AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Las bengkok',
      jobs: [
        JobDraft(deskripsi: 'Jasa las', jumlah: 1, hargaCents: 50000),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 50000,
      actor: Operator.owner,
    );
    final freeJob = (await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [freeId],
    )).first;
    expect(freeJob['harga_bebas'], 1);
    expect(freeJob['harga_batas_saat_transaksi'], 0);
    expect(freeJob['harga_jual_terdaftar'], 0);

    final stockId = await insertStock();
    final kasir = Operator(
      kind: 'employee',
      role: 'KASIR',
      label: 'Kasir',
      permissions: {'buat_nota', 'diskon', 'stok_keluar'},
    );
    await expectLater(
      AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Jual oli rugi',
        jobs: const [],
        parts: [
          PartDraft(
            stockItemId: stockId,
            nama: 'Oli mesin',
            jumlah: 1,
            hargaCents: 5000,
            modalCents: 10000,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 5000,
        actor: kasir,
      ),
      throwsA(isA<PriceRuleViolation>()),
    );

    final ownerId = await AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Jual oli rugi disetujui',
      jobs: const [],
      parts: [
        PartDraft(
          stockItemId: stockId,
          nama: 'Oli mesin',
          jumlah: 1,
          hargaCents: 5000,
          modalCents: 10000,
        ),
      ],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 5000,
      actor: Operator.owner,
      alasanDiskon: 'Harga obral pemilik',
    );
    final part = (await db.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [ownerId],
    )).first;
    expect(part['harga_batas_saat_transaksi'], 10000);
  });

  test('harga nol jasa wajib pemilik dan alasan', () async {
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);
    final kasir = Operator(
      kind: 'employee',
      role: 'KASIR',
      label: 'Kasir',
      permissions: {'buat_nota', 'diskon'},
    );
    Future<int> run({
      required Operator actor,
      String? alasan,
    }) {
      return AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Gratis',
        jobs: [
          JobDraft(deskripsi: 'Jasa gratis', jumlah: 1, hargaCents: 0),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 0,
        actor: actor,
        alasanDiskon: alasan,
      );
    }

    await expectLater(run(actor: kasir), throwsA(isA<PriceRuleViolation>()));
    await expectLater(
      run(actor: Operator.owner),
      throwsA(isA<PriceRuleViolation>()),
    );
    final id = await run(
      actor: Operator.owner,
      alasan: 'Promo pembukaan',
    );
    expect(id, greaterThan(0));
  });

  test('jasa_sync_id dan tarif acuan terbawa dari estimasi ke nota', () async {
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);
    final jasaId = await insertCatalog();
    final catalog = (await db.query(
      'harga_jasa',
      where: 'id = ?',
      whereArgs: [jasaId],
    )).first;

    final estimate = await OrderService.instance.createEstimate(
      customerId: customerId,
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Servis ringan',
          jumlah: 1,
          hargaCents: 80000,
          modalCents: 0,
          jasaId: jasaId,
        ),
      ],
      actor: Operator.owner,
    );
    final item = (await estimateItems(estimate!.syncId)).first;
    expect(item['jasa_sync_id'], catalog['sync_id']);
    expect(item['harga_jual_terdaftar'], 80000);
    expect(item['harga_input'], 80000);
    expect(item['harga_bebas'], 0);

    final recordId = await OrderService.instance.convertEstimateToNote(
      estimateSyncId: estimate.syncId,
      metodeBayar: 'CASH',
      bayarCents: 80000,
      actor: Operator.owner,
    );
    final job = (await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [recordId],
    )).first;
    expect(job['harga_jasa_sync_id'], catalog['sync_id']);
    expect(job['harga_jual_terdaftar'], 80000);
    expect(job['harga_bebas'], 0);
  });

  test('permintaan dengan request_id sama dan isi berbeda ditolak', () async {
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);
    Future<int> run(int harga) {
      return AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Servis',
        jobs: [
          JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: harga),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: harga,
        requestId: 'REQ-1',
        actor: Operator.owner,
      );
    }

    final first = await run(10000);
    final again = await run(10000);
    expect(again, first);
    await expectLater(
      run(12000),
      throwsA(
        isA<PriceRuleViolation>().having(
          (error) => error.code,
          'code',
          'request_payload_berbeda',
        ),
      ),
    );
  });

  test('payload sinkron estimasi membawa snapshot PPN dan tarif acuan',
      () async {
    await setPajak(aktif: true);
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);
    final jasaId = await insertCatalog();
    final estimate = await OrderService.instance.createEstimate(
      customerId: customerId,
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Servis ringan',
          jumlah: 1,
          hargaCents: 80000,
          modalCents: 0,
          jasaId: jasaId,
        ),
      ],
      actor: Operator.owner,
    );
    await SyncService.instance.enqueueEstimate(estimate!.syncId);

    final outbox = await db.query(
      'sync_outbox',
      where: 'entity = ? AND entity_id = ?',
      whereArgs: ['estimate', estimate.syncId],
      limit: 1,
    );
    expect(outbox, hasLength(1));
    final payload =
        jsonDecode(outbox.first['payload_json'] as String) as Map<String, dynamic>;
    expect(payload['jenis_transaksi'], transactionServisLangsung);
    expect(payload['dpp_cents'], 80000);
    expect(payload['ppn_cents'], 8800);
    expect(payload['total_ditagih_cents'], 88800);
    expect(payload['pajak_mode'], pajakModeEksklusif);
    final items = (payload['items'] as List).cast<Map<String, dynamic>>();
    expect(items.single['jasa_sync_id'], isNotNull);
    expect(items.single['harga_jual_terdaftar'], 80000);
    expect(items.single['harga_input'], 80000);
    expect(items.single['harga_bebas'], 0);
    expect(items.single['dpp_cents'], 80000);
    expect(items.single['ppn_cents'], 8800);
  });

  test('payload sinkron nota membawa hash request dan snapshot pelanggan',
      () async {
    final customerId = await insertCustomer(nama: 'Budi Santoso');
    final unitId = await insertUnit(customerId, nopol: 'B 9999 ZZ');
    final recordId = await AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Servis',
      jobs: [
        JobDraft(
          deskripsi: 'Jasa las',
          jumlah: 1,
          hargaCents: 30000,
          hargaBebas: true,
        ),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 30000,
      requestId: 'REQ-NOTA-1',
      actor: Operator.owner,
    );
    final payload = await AppDatabase.instance.noteSyncPayload(recordId);
    final record = payload['record'] as Map<String, Object?>;
    expect(record['request_id'], 'REQ-NOTA-1');
    expect(record['request_payload_hash'], isNotNull);
    expect(record['customer_nama'], 'Budi Santoso');
    expect(record['unit_nopol'], 'B 9999 ZZ');
    final jobs = (payload['jobs'] as List).cast<Map<String, Object?>>();
    expect(jobs.single['harga_bebas'], 1);
  });

  test('nama pelanggan dan nopol tersimpan sebagai snapshot nota', () async {
    final customerId = await insertCustomer(nama: 'Budi Santoso');
    final unitId = await insertUnit(customerId, nopol: 'B 9999 ZZ');
    final recordId = await AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Servis',
      jobs: [
        JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 20000),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 20000,
      actor: Operator.owner,
    );
    await db.update(
      'customers',
      {'nama': 'Nama Baru', 'nomor_hp': '0800000000'},
      where: 'id = ?',
      whereArgs: [customerId],
    );
    await db.update(
      'vehicle_or_units',
      {'nopol': 'B 0000 AA'},
      where: 'id = ?',
      whereArgs: [unitId],
    );

    final detail = await AppDatabase.instance.recordDetail(recordId);
    expect(detail, isNotNull);
    expect(detail!.record.customerNama, 'Budi Santoso');
    expect(detail.record.unitLabel, contains('B 9999 ZZ'));
  });
}
