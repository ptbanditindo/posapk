import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/note_sync.dart';
import 'package:pusatkupos/data/pajak.dart';
import 'package:pusatkupos/data/purchase_service.dart';
import 'package:pusatkupos/data/sale_return_service.dart';
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

  Future<int> insertSupplier({String nama = 'Supplier Oli'}) async {
    final now = nowIso();
    return db.insert('suppliers', {
      'sync_id': newSyncId(),
      'nama': nama,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> insertStock({
    String kode = 'OLI-1',
    String nama = 'Oli mesin',
    int hargaJual = 15000,
    int hargaModal = 10000,
    int stokMilli = 10000,
  }) async {
    final now = nowIso();
    return db.insert('stock_items', {
      'sync_id': newSyncId(),
      'kode': kode,
      'nama': nama,
      'harga_jual': hargaJual,
      'harga_modal': hargaModal,
      'jumlah_milli': stokMilli,
      'created_at': now,
      'updated_at': now,
    });
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

  Future<int> insertUnit(int customerId) async {
    final now = nowIso();
    return db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'nopol': 'B 1234 XY',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> createPurchase({
    required int supplierId,
    required int stockItemId,
    int qtyMilli = 1000,
    int hargaSatuan = 50000,
    String jenisBayar = 'KREDIT',
    int bayarAwal = 0,
    String metode = 'CASH',
    int diskon = 0,
    int ongkir = 0,
    int ppn = 0,
  }) {
    return PurchaseService.instance.createPurchase(
      input: PurchaseInput(
        supplierId: supplierId,
        lines: [
          PurchaseLineInput(
            stockItemId: stockItemId,
            qtyMilli: qtyMilli,
            hargaSatuan: hargaSatuan,
          ),
        ],
        jenisBayar: jenisBayar,
        bayarAwal: bayarAwal,
        metode: metode,
        diskon: diskon,
        ongkir: ongkir,
        ppn: ppn,
      ),
      actor: Operator.owner,
    );
  }

  Future<Map<String, Object?>> rowAt(String table, int id) async {
    return (await db.query(table, where: 'id = ?', whereArgs: [id])).single;
  }

  Future<int> sumCash(String kategori, {String? metode}) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM cash_ledger '
      'WHERE kategori = ?${metode == null ? '' : ' AND metode = ?'}',
      [kategori, ?metode],
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<int> stockMilli(int stockItemId) async {
    final row = await rowAt('stock_items', stockItemId);
    return (row['jumlah_milli'] as num?)?.toInt() ?? 0;
  }

  group('retur pembelian', () {
    test('memakai harga pokok alokasi dan refund inkremental per retur',
        () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();

      final purchaseId = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 10000,
        hargaSatuan: 10000,
        diskon: 10000,
        ongkir: 5000,
      );
      final item = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseId],
      )).single;
      expect(item['harga_pokok_satuan'], 9500);
      expect(item['subtotal'], 100000);

      await PurchaseService.instance.addPayment(
        input: PurchasePaymentInput(
          purchaseId: purchaseId,
          nominal: 60000,
          metode: 'TRANSFER',
        ),
        actor: Operator.owner,
      );

      final purchaseItemId = item['id'] as int;
      final firstReturn = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: purchaseItemId,
            qtyMilli: 4000,
          ),
        ],
        alasan: 'Barang rusak',
        actor: Operator.owner,
      );
      final firstRow = await rowAt('supplier_purchase_returns', firstReturn);
      expect(firstRow['total'], 38000);
      expect(firstRow['total_modal_kembali'], 38000);
      expect(firstRow['total_kas_kembali'], 3000);
      expect(firstRow['metode_refund'], 'TRANSFER');

      final secondReturn = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: purchaseItemId,
            qtyMilli: 2000,
          ),
        ],
        alasan: 'Sisa rusak',
        actor: Operator.owner,
      );
      final secondRow = await rowAt('supplier_purchase_returns', secondReturn);
      expect(secondRow['total'], 19000);
      // Refund kedua hanya selisih target kumulatif, bukan nominal kumulatif.
      expect(secondRow['total_kas_kembali'], 19000);

      final purchase = await rowAt('supplier_purchases', purchaseId);
      expect(purchase['refund_accumulated_cents'], 22000);
      expect(purchase['sisa_utang'], 0);
      expect(await sumCash('RETUR_PEMBELIAN'), 22000);
      final cashRows = await db.query(
        'cash_ledger',
        where: 'kategori = ?',
        whereArgs: ['RETUR_PEMBELIAN'],
      );
      expect(cashRows, hasLength(2));
      expect(cashRows.every((row) => row['metode'] == 'TRANSFER'), isTrue);
    });

    test('metode refund bawaan ikut pembayaran terakhir dan bisa dioverride',
        () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock(kode: 'OLI-A');

      final purchaseA = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        bayarAwal: 20000,
        metode: 'CASH',
      );
      await PurchaseService.instance.addPayment(
        input: PurchasePaymentInput(
          purchaseId: purchaseA,
          nominal: 30000,
          metode: 'TRANSFER',
        ),
        actor: Operator.owner,
      );
      final itemA = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseA],
      )).single;
      final returnA = await PurchaseService.instance.createReturn(
        purchaseId: purchaseA,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: itemA['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Salah beli',
        actor: Operator.owner,
      );
      expect(
        (await rowAt('supplier_purchase_returns', returnA))['metode_refund'],
        'TRANSFER',
      );
      expect(await sumCash('RETUR_PEMBELIAN', metode: 'TRANSFER'), 50000);

      final stockB = await insertStock(kode: 'OLI-B');
      final purchaseB = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockB,
        bayarAwal: 50000,
        metode: 'TRANSFER',
      );
      final itemB = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseB],
      )).single;
      final returnB = await PurchaseService.instance.createReturn(
        purchaseId: purchaseB,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: itemB['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Tukar barang',
        metodeRefund: 'CASH',
        actor: Operator.owner,
      );
      expect(
        (await rowAt('supplier_purchase_returns', returnB))['metode_refund'],
        'CASH',
      );
      expect(await sumCash('RETUR_PEMBELIAN', metode: 'CASH'), 50000);
    });

    test('reversal retur mengembalikan stok, kas, VOID, audit, dan idempoten',
        () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();
      final purchaseId = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        bayarAwal: 50000,
      );
      expect(await stockMilli(stockId), 11000);

      final item = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseId],
      )).single;
      final returnId = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: item['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Barang cacat',
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 10000);
      final retur = await rowAt('supplier_purchase_returns', returnId);
      expect(retur['total_kas_kembali'], 50000);

      await PurchaseService.instance.reverseReturn(
        returnId: returnId,
        alasan: 'Retur salah input',
        actor: Operator.owner,
      );

      final after = await rowAt('supplier_purchase_returns', returnId);
      expect(after['status'], 'VOID');
      expect(after['void_reason'], 'Retur salah input');
      expect(await stockMilli(stockId), 11000);
      final reversed = await rowAt('supplier_purchases', purchaseId);
      expect(reversed['refund_accumulated_cents'], 0);

      final reversal = (await db.query('purchase_return_reversals')).single;
      expect(reversal['return_id'], returnId);
      expect(reversal['total_kas_cents'], 50000);
      expect(await sumCash('REVERSAL_RETUR_PEMBELIAN'), -50000);
      final audits = await db.query(
        'business_audits',
        where: 'aksi = ?',
        whereArgs: ['reversal_retur_pembelian'],
      );
      expect(audits, hasLength(1));

      await expectLater(
        PurchaseService.instance.reverseReturn(
          returnId: returnId,
          alasan: 'Batal lagi',
          actor: Operator.owner,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await db.query('purchase_return_reversals')).length,
        1,
      );
      expect(await sumCash('REVERSAL_RETUR_PEMBELIAN'), -50000);
    });

    test('reversal retur pembelian hanya boleh pemilik', () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();
      final purchaseId = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
      );
      final item = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseId],
      )).single;
      final returnId = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: item['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Salah barang',
        actor: Operator.owner,
      );
      final employee = Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir',
        permissions: {'buat_pembelian', 'bayar_utang'},
      );
      await expectLater(
        PurchaseService.instance.reverseReturn(
          returnId: returnId,
          alasan: 'Coba batal',
          actor: employee,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await rowAt('supplier_purchase_returns', returnId))['status'],
        'AKTIF',
      );
    });

    test('pembelian dengan retur aktif tidak bisa void, setelah reversal bisa',
        () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();
      final purchaseId = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
      );
      final item = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseId],
      )).single;
      final returnId = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: item['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Tidak jadi dipakai',
        actor: Operator.owner,
      );

      await expectLater(
        PurchaseService.instance.voidPurchase(
          purchaseId: purchaseId,
          reason: 'Batal beli',
          actor: Operator.owner,
        ),
        throwsA(isA<StateError>()),
      );

      await PurchaseService.instance.reverseReturn(
        returnId: returnId,
        alasan: 'Reversal atas retur uji',
        actor: Operator.owner,
      );
      await PurchaseService.instance.voidPurchase(
        purchaseId: purchaseId,
        reason: 'Batal beli',
        actor: Operator.owner,
      );
      expect((await rowAt('supplier_purchases', purchaseId))['status'], 'VOID');
      expect(await stockMilli(stockId), 10000);
    });

    test('void retur dari perangkat lain idempoten', () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();
      final purchaseId = await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        bayarAwal: 50000,
      );
      final item = (await db.query(
        'supplier_purchase_items',
        where: 'purchase_id = ?',
        whereArgs: [purchaseId],
      )).single;
      final returnId = await PurchaseService.instance.createReturn(
        purchaseId: purchaseId,
        lines: [
          PurchaseReturnLineInput(
            purchaseItemId: item['id'] as int,
            qtyMilli: 1000,
          ),
        ],
        alasan: 'Barang salah',
        actor: Operator.owner,
      );
      final retur = await rowAt('supplier_purchase_returns', returnId);
      final purchase = await rowAt('supplier_purchases', purchaseId);
      final payload = <String, Object?>{
        'sync_id': retur['sync_id'],
        'purchase_sync_id': purchase['sync_id'],
        'status': 'VOID',
        'void_reason': 'Dibatalkan perangkat asal',
        'voided_by': 'Pemilik',
        'dibuat_oleh': 'Pemilik',
        'voided_at': nowIso(),
      };
      await db.transaction(
        (txn) => PurchaseService.instance.applyReturnRemote(
          txn,
          payload,
          wall: 10,
          counter: 1,
        ),
      );
      await db.transaction(
        (txn) => PurchaseService.instance.applyReturnRemote(
          txn,
          payload,
          wall: 10,
          counter: 2,
        ),
      );

      expect(
        (await rowAt('supplier_purchase_returns', returnId))['status'],
        'VOID',
      );
      expect(await stockMilli(stockId), 11000);
      expect((await rowAt('supplier_purchases', purchaseId))['refund_accumulated_cents'], 0);
      final reversals = await db.query(
        'cash_ledger',
        where: 'kategori = ?',
        whereArgs: ['REVERSAL_RETUR_PEMBELIAN'],
      );
      expect(reversals, hasLength(1));
      expect(reversals.single['nominal'], -50000);
    });
  });

  group('retur penjualan', () {
    Future<int> createJobNote({
      required int customerId,
      required int unitId,
      int harga = 100000,
      required int bayar,
    }) {
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
        bayarCents: bayar,
        actor: Operator.owner,
      );
    }

    Future<int> createPartNote({
      required int customerId,
      required int unitId,
      required int stockItemId,
    }) {
      return AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Jual oli',
        jobs: const [],
        parts: [
          PartDraft(
            stockItemId: stockItemId,
            nama: 'Oli mesin',
            jumlah: 2,
            hargaCents: 15000,
            modalCents: 10000,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 30000,
        actor: Operator.owner,
      );
    }

    Future<String> jobSyncId(int recordId) async {
      final row = (await db.query(
        'service_jobs',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      )).single;
      return '${row['sync_id']}';
    }

    test('retur nota EKSLUSIF menyimpan DPP, PPN, dan total ditagih',
        () async {
      await setPajak(aktif: true);
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      final recordId = await createJobNote(
        customerId: customerId,
        unitId: unitId,
        bayar: 111000,
      );
      final returnId = await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'jasa',
            lineSyncId: await jobSyncId(recordId),
            jumlah: 1,
          ),
        ],
        alasan: 'Jasa dibatalkan',
        actor: Operator.owner,
        requestId: newSyncId(),
      );
      final retur = await rowAt('sale_returns', returnId);
      expect(retur['dpp_cents'], 100000);
      expect(retur['ppn_cents'], 11000);
      expect(retur['total_ditagih_cents'], 111000);
      expect(retur['total'], 111000);
      expect(retur['metode_refund'], 'CASH');
      final item = (await db.query(
        'sale_return_items',
        where: 'return_id = ?',
        whereArgs: [returnId],
      )).single;
      expect(item['dpp_cents'], 100000);
      expect(item['ppn_cents'], 11000);
      expect(item['total_ditagih_cents'], 111000);
      expect(await sumCash('REFUND'), -111000);
    });

    test('retur nota INKLUSIF memisahkan DPP dan PPN dari nilai ditagih',
        () async {
      await setPajak(aktif: true, mode: pajakModeInklusif);
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      final recordId = await createJobNote(
        customerId: customerId,
        unitId: unitId,
        bayar: 100000,
      );
      final returnId = await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'jasa',
            lineSyncId: await jobSyncId(recordId),
            jumlah: 1,
          ),
        ],
        alasan: 'Batal jasa',
        actor: Operator.owner,
        requestId: newSyncId(),
      );
      final retur = await rowAt('sale_returns', returnId);
      expect(retur['dpp_cents'], 90090);
      expect(retur['ppn_cents'], 9910);
      expect(retur['total_ditagih_cents'], 100000);
      expect(retur['total'], 100000);
      expect(await sumCash('REFUND'), -100000);
    });

    test('reversal retur memulihkan stok, kas, nota, dan laporan RET-03',
        () async {
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      final stockId = await insertStock();
      final recordId = await createPartNote(
        customerId: customerId,
        unitId: unitId,
        stockItemId: stockId,
      );
      expect(await stockMilli(stockId), 8000);

      final part = (await db.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      )).single;
      final returnId = await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'part',
            lineSyncId: '${part['sync_id']}',
            jumlah: 1,
          ),
        ],
        alasan: 'Oli dikembalikan',
        actor: Operator.owner,
        requestId: newSyncId(),
      );
      expect(await stockMilli(stockId), 9000);
      final retur = await rowAt('sale_returns', returnId);
      expect(retur['total'], 15000);
      expect(retur['total_refund'], 15000);

      final now = DateTime.now();
      var report = await AppDatabase.instance.reportSummary(now, now);
      expect(report.returDitagihCents, 15000);
      expect(report.totalNetCents, 15000);

      await SaleReturnService.instance.reverseReturn(
        returnId: returnId,
        alasan: 'Retur salah input',
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 8000);
      expect((await rowAt('sale_returns', returnId))['status'], 'VOID');
      final reversal = (await db.query('sale_return_reversals')).single;
      expect(reversal['total_refund_cents'], 15000);
      expect(await sumCash('REVERSAL_RETUR'), 15000);
      final reversalPayments = await db.query(
        'service_payments',
        where: 'kas_kategori = ?',
        whereArgs: ['REVERSAL_RETUR'],
      );
      expect(reversalPayments, hasLength(1));
      expect(reversalPayments.single['jenis'], 'PELUNASAN');
      expect(reversalPayments.single['nominal'], 15000);
      final audits = await db.query(
        'business_audits',
        where: 'aksi = ?',
        whereArgs: ['reversal_retur'],
      );
      expect(audits, hasLength(1));

      report = await AppDatabase.instance.reportSummary(now, now);
      expect(report.returDitagihCents, 0);
      expect(report.returCents, 0);
      expect(report.totalNetCents, 30000);

      final employee = Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir',
        permissions: {'retur'},
      );
      final secondReturn = await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'part',
            lineSyncId: '${part['sync_id']}',
            jumlah: 1,
          ),
        ],
        alasan: 'Retur ulang',
        actor: Operator.owner,
        requestId: newSyncId(),
      );
      await expectLater(
        SaleReturnService.instance.reverseReturn(
          returnId: secondReturn,
          alasan: 'Kasir coba batal',
          actor: employee,
        ),
        throwsA(isA<StateError>()),
      );
      expect((await rowAt('sale_returns', secondReturn))['status'], 'AKTIF');
    });

    test('void retur dari perangkat lain idempoten dan stok tidak dobel',
        () async {
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      final stockId = await insertStock();
      final recordId = await createPartNote(
        customerId: customerId,
        unitId: unitId,
        stockItemId: stockId,
      );
      final part = (await db.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      )).single;
      final returnId = await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'part',
            lineSyncId: '${part['sync_id']}',
            jumlah: 1,
          ),
        ],
        alasan: 'Oli kembali',
        actor: Operator.owner,
        requestId: newSyncId(),
      );
      expect(await stockMilli(stockId), 9000);

      final payload = await AppDatabase.instance.noteSyncPayload(recordId);
      final returnSyncId = '${(await rowAt('sale_returns', returnId))['sync_id']}';
      final returns = (payload['returns'] as List).cast<Map>();
      final target = returns.firstWhere(
        (row) => '${row['sync_id']}' == returnSyncId,
      );
      target['status'] = 'VOID';
      target['void_reason'] = 'Dibatalkan perangkat asal';
      target['voided_by'] = 'Pemilik';
      target['voided_at'] = nowIso();

      final first = await AppDatabase.instance.applyNotePayload(
        db,
        payload,
        action: 'upsert',
      );
      expect(first, anyOf('applied', 'updated', 'duplicate'));
      expect(await stockMilli(stockId), 8000);
      expect((await rowAt('sale_returns', returnId))['status'], 'VOID');

      await AppDatabase.instance.applyNotePayload(
        db,
        payload,
        action: 'upsert',
      );
      expect(await stockMilli(stockId), 8000);
      final movements = await db.query(
        'stock_movements',
        where: 'sumber_entity = ?',
        whereArgs: ['sale_return_reversal'],
      );
      expect(movements, hasLength(1));
      expect(movements.single['jumlah_milli'], -1000);
      final record = await rowAt('service_records', recordId);
      expect(record['total_retur'], 0);
    });
  });
}
