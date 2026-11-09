import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/employee_service.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/opening_balance_service.dart';
import 'package:pusatkupos/data/pajak.dart';
import 'package:pusatkupos/data/pajak_report_service.dart';
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

  Future<int> insertSupplier({String nama = 'Supplier Oli'}) async {
    final now = nowIso();
    return db.insert('suppliers', {
      'sync_id': newSyncId(),
      'nama': nama,
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

  Future<int> insertStock({
    String kode = 'OLI-1',
    int hargaJual = 15000,
    int hargaModal = 10000,
  }) async {
    final now = nowIso();
    return db.insert('stock_items', {
      'sync_id': newSyncId(),
      'kode': kode,
      'nama': 'Oli mesin',
      'harga_jual': hargaJual,
      'harga_modal': hargaModal,
      'jumlah_milli': 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> postOpening({
    required int supplierId,
    required int customerId,
    int utang = 50000,
    int piutang = 30000,
    String? jatuhTempo,
  }) {
    return OpeningBalanceService.instance.post(
      items: [
        OpeningItemInput(
          jenis: 'UTANG_SUPPLIER',
          refId: supplierId,
          nominal: utang,
          jatuhTempo: jatuhTempo,
        ),
        OpeningItemInput(
          jenis: 'PIUTANG_PELANGGAN',
          refId: customerId,
          nominal: piutang,
        ),
      ],
      actor: Operator.owner,
    );
  }

  group('saldo awal utang dan piutang', () {
    test('saldo awal tercatat sebagai dokumen yang dapat dibayar/ditagih',
        () async {
      final supplierId = await insertSupplier();
      final customerId = await insertCustomer();
      await postOpening(
        supplierId: supplierId,
        customerId: customerId,
        jatuhTempo: '2026-12-01',
      );

      final payable = (await db.query('opening_payables')).single;
      expect(payable['nominal_cents'], 50000);
      expect(payable['terbayar_cents'], 0);
      expect(payable['status'], 'AKTIF');
      expect(payable['jatuh_tempo'], '2026-12-01');
      expect(payable['supplier_nama_snapshot'], 'Supplier Oli');

      final receivable = (await db.query('opening_receivables')).single;
      expect(receivable['nominal_cents'], 30000);
      expect(receivable['customer_nama_snapshot'], 'Budi');

      final totals = await OpeningBalanceService.instance.financeTotals();
      expect(totals['utang'], 50000);
      expect(totals['piutang'], 30000);

      final purchaseTotals = await PurchaseService.instance.purchaseTotals();
      expect(purchaseTotals['total_utang_awal'], 50000);
      expect(purchaseTotals['total_utang'], 0);
      expect(purchaseTotals['total_utang_semua'], 50000);
    });

    test('pembayaran utang dan penagihan piutang awal memperbarui sisa + kas',
        () async {
      final supplierId = await insertSupplier();
      final customerId = await insertCustomer();
      await postOpening(supplierId: supplierId, customerId: customerId);
      final payable = (await db.query('opening_payables')).single;
      final receivable = (await db.query('opening_receivables')).single;

      await OpeningBalanceService.instance.payPayable(
        payableSyncId: '${payable['sync_id']}',
        nominal: 20000,
        metode: 'CASH',
        actor: Operator.owner,
        requestId: 'PAY-AWAL-1',
      );
      var updatedPayable = (await db.query('opening_payables')).single;
      expect(updatedPayable['terbayar_cents'], 20000);
      expect(updatedPayable['status'], 'AKTIF');
      final payCash = (await db.query(
        'cash_ledger',
        where: 'kategori = ?',
        whereArgs: ['BAYAR_UTANG_AWAL'],
      )).single;
      expect(payCash['nominal'], -20000);
      expect(await OpeningBalanceService.instance.financeTotals(), {
        'utang': 30000,
        'piutang': 30000,
      });

      await OpeningBalanceService.instance.collectReceivable(
        receivableSyncId: '${receivable['sync_id']}',
        nominal: 30000,
        metode: 'CASH',
        actor: Operator.owner,
        requestId: 'TAGIH-AWAL-1',
      );
      final updatedReceivable = (await db.query('opening_receivables')).single;
      expect(updatedReceivable['terbayar_cents'], 30000);
      expect(updatedReceivable['status'], 'LUNAS');
      final collectCash = (await db.query(
        'cash_ledger',
        where: 'kategori = ?',
        whereArgs: ['TAGIH_PIUTANG_AWAL'],
      )).single;
      expect(collectCash['nominal'], 30000);
      expect(await OpeningBalanceService.instance.financeTotals(), {
        'utang': 30000,
        'piutang': 0,
      });

      await OpeningBalanceService.instance.payPayable(
        payableSyncId: '${payable['sync_id']}',
        nominal: 30000,
        metode: 'TRANSFER',
        actor: Operator.owner,
      );
      updatedPayable = (await db.query('opening_payables')).single;
      expect(updatedPayable['terbayar_cents'], 50000);
      expect(updatedPayable['status'], 'LUNAS');
      expect(
        await db.query('cash_ledger', where: "kategori = 'BAYAR_UTANG_AWAL'"),
        hasLength(1),
      );
      final audits = await db.query(
        'business_audits',
        where: "aksi IN ('bayar_utang_awal', 'tagih_piutang_awal')",
      );
      expect(audits, hasLength(3));
    });

    test('saldo awal yang sudah dibayar tidak dapat dikoreksi', () async {
      final supplierId = await insertSupplier();
      final customerId = await insertCustomer();
      await postOpening(supplierId: supplierId, customerId: customerId);
      final payable = (await db.query('opening_payables')).single;
      await OpeningBalanceService.instance.payPayable(
        payableSyncId: '${payable['sync_id']}',
        nominal: 10000,
        metode: 'CASH',
        actor: Operator.owner,
      );
      await expectLater(
        OpeningBalanceService.instance.voidActive(
          reason: 'Salah input',
          actor: Operator.owner,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('sudah dibayar'),
          ),
        ),
      );
      expect(
        (await db.query(
          'opening_balances',
          where: "status = 'AKTIF'",
        )),
        hasLength(1),
      );
    });
  });

  group('sinkronisasi saldo awal keuangan', () {
    test('pembayaran pada payload remote diterapkan sekali', () async {
      final supplierId = await insertSupplier();
      final supplier = (await db.query(
        'suppliers',
        where: 'id = ?',
        whereArgs: [supplierId],
      )).single;
      final now = nowIso();
      final payload = {
        'sync_id': 'OPEN-REMOTE-1',
        'store_id': 'utama',
        'device_id': 'dev-1',
        'origin_device_id': 'dev-1',
        'status': 'AKTIF',
        'posted_at': now,
        'posted_by': 'Pemilik',
        'created_at': now,
        'items': [
          {
            'sync_id': 'ITEM-REMOTE-1',
            'jenis': 'UTANG_SUPPLIER',
            'ref_sync_id': supplier['sync_id'],
            'ref_nama_snapshot': 'Supplier Oli',
            'nominal': 40000,
            'jatuh_tempo': '2026-12-31',
          },
        ],
        'payments': [
          {
            'jenis': 'UTANG',
            'sync_id': 'PAY-REMOTE-1',
            'payable_sync_id': 'ITEM-REMOTE-1',
            'request_id': 'REQ-REMOTE-1',
            'nominal': 15000,
            'metode': 'CASH',
            'waktu': now,
            'operator': 'Kasir',
            'created_at': now,
          },
        ],
      };
      await db.transaction(
        (txn) => OpeningBalanceService.instance.applyRemote(
          txn,
          payload,
          wall: 5,
          counter: 1,
          action: 'upsert',
        ),
      );
      await db.transaction(
        (txn) => OpeningBalanceService.instance.applyRemote(
          txn,
          payload,
          wall: 5,
          counter: 2,
          action: 'upsert',
        ),
      );

      final payable = (await db.query('opening_payables')).single;
      expect(payable['terbayar_cents'], 15000);
      expect(payable['jatuh_tempo'], '2026-12-31');
      expect(await db.query('payable_payments'), hasLength(1));
      final cash = (await db.query(
        'cash_ledger',
        where: "kategori = 'BAYAR_UTANG_AWAL'",
      )).single;
      expect(cash['nominal'], -15000);
    });
  });

  group('payroll', () {
    Future<String> insertEmployee({
      String jenis = 'GAJI',
      int gajiBulanan = 3000000,
    }) async {
      final syncId = newSyncId();
      final now = nowIso();
      await db.insert('employee_accounts', {
        'sync_id': syncId,
        'username': 'budi',
        'nama': 'Budi Mekanik',
        'role_base': 'MEKANIK',
        'password_hash': 'hash',
        'password_salt': 'salt',
        'jenis_imbalan': jenis,
        'gaji_bulanan': gajiBulanan,
        'komisi_mode': 'PERSEN',
        'komisi_barang_nilai': 0,
        'komisi_jasa_nilai': 0,
        'payroll_period': 'BULANAN',
        'payroll_tanggal': 1,
        'payroll_hari': 1,
        'created_at': now,
        'updated_at': now,
      });
      return syncId;
    }

    test('pembayaran gaji menolak peran tanpa izin', () async {
      final employeeSync = await insertEmployee();
      final kasir = Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir',
        permissions: const {},
      );
      await expectLater(
        EmployeeService.instance.paySalary(employeeSync, actor: kasir),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('bayar_gaji'),
          ),
        ),
      );
      expect(await db.query('salary_payments'), isEmpty);
    });

    test('gaji menyimpan pembayar, komponen terpisah, dan kas atas nama aktor',
        () async {
      final employeeSync = await insertEmployee();
      final summary = await EmployeeService.instance.paySalary(
        employeeSync,
        actor: Operator.owner,
      );
      expect(summary.paid, isTrue);
      final payment = (await db.query('salary_payments')).single;
      expect(payment['nominal'], 3000000);
      expect(payment['gaji_pokok'], 3000000);
      expect(payment['komisi_total'], 0);
      expect(payment['paid_by'], 'Pemilik');
      expect(payment['store_id'], 'utama');
      final cash = (await db.query(
        'cash_ledger',
        where: "kategori = 'GAJI'",
      )).single;
      expect(cash['nominal'], -3000000);
      expect(cash['operator'], 'Pemilik');
      final audit = (await db.query(
        'business_audits',
        where: "aksi = 'bayar_gaji'",
      )).single;
      expect(audit['aktor'], 'Pemilik');
      expect('${audit['after_json']}', contains('"gaji_pokok":3000000'));
    });
  });

  group('laporan keuangan', () {
    test('filter toko pada rekap pembelian', () async {
      final supplierId = await insertSupplier();
      final stockId = await insertStock();
      Future<int> purchase(int harga) {
        return PurchaseService.instance.createPurchase(
          input: PurchaseInput(
            supplierId: supplierId,
            lines: [
              PurchaseLineInput(
                stockItemId: stockId,
                qtyMilli: 1000,
                hargaSatuan: harga,
              ),
            ],
            jenisBayar: 'KREDIT',
            bayarAwal: 0,
          ),
          actor: Operator.owner,
        );
      }

      final keep = await purchase(10000);
      final other = await purchase(20000);
      await db.update(
        'supplier_purchases',
        {'store_id': 'toko-lain'},
        where: 'id = ?',
        whereArgs: [other],
      );

      final totals = await PurchaseService.instance.purchaseTotals();
      expect(totals['total_pembelian'], 10000);
      expect(totals['total_utang'], 10000);
      expect(totals['jumlah_nota'], 1);
      final keepRow = (await db.query(
        'supplier_purchases',
        where: 'id = ?',
        whereArgs: [keep],
      )).single;
      expect(keepRow['store_id'], 'utama');
    });

    test('ringkasan DPP/PPN dikurangi retur dan sama dengan rekap', () async {
      await db.update('store_settings', {
        'pajak_aktif': 1,
        'pajak_mode': pajakModeEksklusif,
        'pajak_persen_bp': 1100,
        'pajak_penanggung': pajakPenanggungPembeli,
      });
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      final recordId = await AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Servis',
        jobs: [
          JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 100000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 111000,
        actor: Operator.owner,
      );
      final job = (await db.query(
        'service_jobs',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      )).single;
      await SaleReturnService.instance.createReturn(
        recordId: recordId,
        items: [
          ReturnLineInput(
            lineType: 'jasa',
            lineSyncId: '${job['sync_id']}',
            jumlah: 1,
          ),
        ],
        alasan: 'Jasa dibatalkan',
        actor: Operator.owner,
        requestId: newSyncId(),
      );

      final summary = await AppDatabase.instance.reportSummary(
        DateTime.now(),
        DateTime.now(),
      );
      final masa = nowIso().substring(0, 7);
      final rekap = await PajakReportService.instance.rekap(masa);
      expect(summary.totalDppCents, 0);
      expect(summary.pajakCents, 0);
      expect(summary.totalDppCents, rekap.dppNetoCents);
      expect(summary.pajakCents, rekap.pajakKeluaranCents - rekap.returPajakCents);
    });

    test('dashboard menghitung piutang awal yang belum ditagih', () async {
      final supplierId = await insertSupplier();
      final customerId = await insertCustomer();
      await postOpening(supplierId: supplierId, customerId: customerId);

      expect((await AppDatabase.instance.dashboard()).receivableCents, 30000);
      final receivable = (await db.query('opening_receivables')).single;
      await OpeningBalanceService.instance.collectReceivable(
        receivableSyncId: '${receivable['sync_id']}',
        nominal: 10000,
        metode: 'CASH',
        actor: Operator.owner,
      );
      expect((await AppDatabase.instance.dashboard()).receivableCents, 20000);
    });

    test('margin per barang dibulatkan sekali setelah penjumlahan', () async {
      final now = nowIso();
      final recordId = await db.insert('service_records', {
        'sync_id': newSyncId(),
        'no_nota': 'INV-ROUND-1',
        'waktu_service': now,
        'keluhan_awal': 'Uji pembulatan',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('service_parts', {
        'sync_id': newSyncId(),
        'service_record_id': recordId,
        'nama_part': 'Oli',
        'jumlah': 0,
        'jumlah_milli': 500,
        'harga_satuan': 333,
        'subtotal': 167,
        'harga_final': 333,
        'harga_modal': 100,
        'created_at': now,
        'updated_at': now,
      });
      final rows = await PurchaseService.instance.marginReport();
      expect(rows, hasLength(1));
      expect(rows.single['pendapatan'], 167);
      expect(rows.single['hpp'], 50);
      expect(rows.single['margin'], 117);
    });
  });
}
