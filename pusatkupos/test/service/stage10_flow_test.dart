import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/core/money.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/employee_service.dart';
import 'package:pusatkupos/data/feature_flags.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/order_service.dart';
import 'package:pusatkupos/data/pajak.dart';
import 'package:pusatkupos/data/pajak_report_service.dart';
import 'package:pusatkupos/data/purchase_service.dart';
import 'package:pusatkupos/data/restore_lock.dart';
import 'package:pusatkupos/data/sale_return_service.dart';
import 'package:pusatkupos/data/store_settings.dart';
import 'package:pusatkupos/state/app_state.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';

import '../support/test_database.dart';
import '../support/test_harness.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // AppState.load() membaca PIN sesi lewat secure storage. Di lingkungan test
    // tidak ada plugin platform, jadi bacaan dikosongkan agar state machine
    // dapat diuji tanpa perangkat.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('presentasi rupiah', () {
    test('semua nominal tampil rupiah bulat tanpa sen', () {
      expect(formatRupiah(3333), 'Rp 33');
      expect(formatRupiah(9999), 'Rp 100');
      expect(formatRupiah(10000), 'Rp 100');
      expect(formatRupiah(500050), 'Rp 5.001');
      expect(formatRupiah(0), 'Rp 0');
      expect(formatRupiahPlain(150050), '1.501');
    });

    test('pembulatan hanya untuk tampilan, nilai tersimpan tetap sen', () {
      final lines = [3333, 3333, 3333];
      final total = lines.reduce((a, b) => a + b);
      expect(total, 9999);
      expect(formatRupiah(total), 'Rp 100');
      expect(formatRupiahPlain(total), '100');
    });
  });

  group('state machine UI', () {
    late ServiceTestHarness harness;
    late Database db;

    setUp(() async {
      harness = ServiceTestHarness();
      await harness.setUp();
      db = harness.db;
    });

    tearDown(() async {
      RestoreLock.instance.end();
      AppState.instance.endStoreSwitch();
      AppState.instance.setOperator(null);
      await harness.tearDown();
    });

    test('scene awal adalah starting sebelum boot selesai', () {
      expect(AppState.instance.scene, AppScene.starting);
    });

    test('scene mengikuti operator dan status PIN', () async {
      await AppState.instance.load();
      expect(AppState.instance.scene, AppScene.unauthenticated);

      AppState.instance.setOperator(Operator.owner);
      expect(AppState.instance.scene, AppScene.ready);

      AppState.instance.setOperator(null);
      await db.insert(
        'app_meta',
        {'key': 'auth.pin_hash', 'value': 'x'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await AppState.instance.load();
      expect(AppState.instance.scene, AppScene.recovering);

      await db.delete('app_meta', where: "key = 'auth.pin_hash'");
      await AppState.instance.load();
      expect(AppState.instance.scene, AppScene.unauthenticated);
    });

    test('restore dan pindah toko mendahului scene lain', () async {
      await AppState.instance.load();
      AppState.instance.setOperator(Operator.owner);
      expect(AppState.instance.scene, AppScene.ready);

      expect(RestoreLock.instance.begin(), isTrue);
      expect(AppState.instance.scene, AppScene.restoring);
      expect(RestoreLock.instance.begin(), isFalse);
      RestoreLock.instance.end();
      expect(AppState.instance.scene, AppScene.ready);

      AppState.instance.beginStoreSwitch();
      expect(AppState.instance.scene, AppScene.switchingStore);
      RestoreLock.instance.begin();
      expect(AppState.instance.scene, AppScene.restoring);
      RestoreLock.instance.end();
      expect(AppState.instance.scene, AppScene.switchingStore);
      AppState.instance.endStoreSwitch();
      expect(AppState.instance.scene, AppScene.ready);
    });

    test('reloadStore menyegarkan nama toko dan cache fitur', () async {
      await AppState.instance.load();
      final before = AppState.instance.storeRevision;
      await db.insert(
        'app_meta',
        {'key': 'bengkel.nama', 'value': 'Toko Uji'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final now = nowIso();
      await db.insert(
        'store_features',
        {
          'store_id': 'utama',
          'feature_key': featureEstimasi,
          'sync_id': newSyncId(),
          'enabled': 0,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Cache belum dimuat ulang: nilai lama masih dipakai.
      expect(FeatureFlagsService.instance.isEnabled(featureEstimasi), isTrue);

      await AppState.instance.reloadStore();

      expect(AppState.instance.storeName, 'Toko Uji');
      expect(AppState.instance.storeRevision, before + 1);
      expect(FeatureFlagsService.instance.isEnabled(featureEstimasi), isFalse);
    });
  });

  group('alur utama pada DB bersih', () {
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

    Future<void> setTransactionTypes() async {
      final rows = await db.query(
        'store_settings',
        columns: ['transaction_types_json'],
        limit: 1,
      );
      final types = Map<String, Object?>.from(
        jsonDecode(
              rows.first['transaction_types_json'] as String? ?? '{}',
            )
            as Map,
      );
      types[transactionEstimasiSaja] = true;
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

    Future<int> insertUnit(int customerId) async {
      final now = nowIso();
      return db.insert('vehicle_or_units', {
        'sync_id': newSyncId(),
        'customer_id': customerId,
        'nopol': 'B 1234 XY',
        'jenis_mobil': 'Avanza',
        'created_at': now,
        'updated_at': now,
      });
    }

    Future<int> insertCatalog() async {
      final now = nowIso();
      return db.insert('harga_jasa', {
        'sync_id': newSyncId(),
        'nama': 'Servis ringan',
        'harga_jual': 100000,
        'harga_modal': 0,
        'created_at': now,
        'updated_at': now,
      });
    }

    Future<int> insertStock({
      String kode = 'OLI-1',
      int stokMilli = 10000,
    }) async {
      final now = nowIso();
      return db.insert('stock_items', {
        'sync_id': newSyncId(),
        'kode': kode,
        'nama': 'Oli mesin',
        'harga_jual': 15000,
        'harga_modal': 10000,
        'jumlah_milli': stokMilli,
        'created_at': now,
        'updated_at': now,
      });
    }

    Future<int> insertSupplier() async {
      final now = nowIso();
      return db.insert('suppliers', {
        'sync_id': newSyncId(),
        'nama': 'Supplier Oli',
        'created_at': now,
        'updated_at': now,
      });
    }

    Future<String> insertEmployee() async {
      final syncId = newSyncId();
      final now = nowIso();
      await db.insert('employee_accounts', {
        'sync_id': syncId,
        'username': 'mekanik1',
        'nama': 'Budi Mekanik',
        'role_base': 'MEKANIK',
        'password_hash': 'hash',
        'password_salt': 'salt',
        'jenis_imbalan': 'GAJI',
        'gaji_bulanan': 3000000,
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

    Future<int> stockMilli(int stockId) async {
      final row = (await db.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [stockId],
      )).single;
      return (row['jumlah_milli'] as num?)?.toInt() ?? 0;
    }

    test('nota, pembayaran, retur, void, opname, pembelian, gaji, PPN, '
        'salinan, snapshot, dan fitur OFF konsisten', () async {
      await setPajak();
      await setTransactionTypes();
      final customerId = await insertCustomer();
      final unitId = await insertUnit(customerId);
      await insertCatalog();
      final stockId = await insertStock();

      // 1. Nota: jasa 100.000 + part 2 x 15.000, PPN 11% eksklusif.
      final recordId = await AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Servis berkala',
        jobs: [
          JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 100000),
        ],
        parts: [
          PartDraft(
            stockItemId: stockId,
            nama: 'Oli mesin',
            jumlah: 2,
            hargaCents: 15000,
            modalCents: 10000,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 50000,
        jatuhTempo: DateTime.now().add(const Duration(days: 14)),
        actor: Operator.owner,
      );
      var record = (await db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      )).single;
      expect(record['pajak_dpp'], 130000);
      expect(record['pajak'], 14300);
      expect(record['total_servis'], 144300);
      expect(await stockMilli(stockId), 8000);

      // 2. Struk: detail nota dapat dimuat utuh setelah simpan.
      final detail = await AppDatabase.instance.recordDetail(recordId);
      expect(detail, isNotNull);
      expect(detail!.record.noNota, isNotEmpty);
      expect(detail.parts, hasLength(1));
      expect(detail.jobs, hasLength(1));
      expect(detail.totalDibayarCents, 50000);
      expect(detail.sisaCents, 94300);

      // 3. Pelunasan piutang nota.
      await AppDatabase.instance.settleReceivable(
        recordId: recordId,
        nominalCents: 94300,
        metode: 'CASH',
        actor: Operator.owner,
        requestId: 'E2E-PELUNASAN-1',
      );
      record = (await db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      )).single;
      expect(record['sisa_bayar'], 0);
      expect(record['status_bayar'], 'LUNAS');

      // 4. Retur satu unit part: stok dan kas kembali, PPN retur tercatat.
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
      final retur = (await db.query(
        'sale_returns',
        where: 'id = ?',
        whereArgs: [returnId],
      )).single;
      expect(retur['dpp_cents'], 15000);
      expect(retur['ppn_cents'], 1650);
      expect(await stockMilli(stockId), 9000);

      // 5. Void nota kedua: stok kembali, nota tidak dihitung laporan.
      final voidId = await AppDatabase.instance.createTransaction(
        unitId: unitId,
        customerId: customerId,
        keluhan: 'Salah input',
        jobs: const [],
        parts: [
          PartDraft(
            stockItemId: stockId,
            nama: 'Oli mesin',
            jumlah: 1,
            hargaCents: 15000,
            modalCents: 10000,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 16650,
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 8000);
      await AppDatabase.instance.voidRecord(
        voidId,
        'Nota salah input',
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 9000);
      final voided = (await db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [voidId],
      )).single;
      expect(voided['voided_at'], isNotNull);

      // 6. Opname menyesuaikan stok ke jumlah fisik.
      final stockRow = (await db.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [stockId],
      )).single;
      await AppDatabase.instance.opname(
        item: StockItem.fromRow(stockRow),
        jumlahFisikMilli: 12000,
        alasan: 'Hitung fisik',
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 12000);

      // 7. Pembelian kredit dan pembayaran utang.
      final supplierId = await insertSupplier();
      final purchaseId = await PurchaseService.instance.createPurchase(
        input: PurchaseInput(
          supplierId: supplierId,
          lines: [
            PurchaseLineInput(
              stockItemId: stockId,
              qtyMilli: 5000,
              hargaSatuan: 10000,
            ),
          ],
          jenisBayar: 'KREDIT',
          bayarAwal: 0,
        ),
        actor: Operator.owner,
      );
      expect(await stockMilli(stockId), 17000);
      await PurchaseService.instance.addPayment(
        input: PurchasePaymentInput(
          purchaseId: purchaseId,
          nominal: 20000,
          metode: 'TRANSFER',
        ),
        actor: Operator.owner,
      );
      final purchaseTotals =
          await PurchaseService.instance.purchaseTotals();
      expect(purchaseTotals['total_utang'], 30000);

      // 8. Payroll.
      final employeeSync = await insertEmployee();
      final payroll = await EmployeeService.instance.paySalary(
        employeeSync,
        actor: Operator.owner,
      );
      expect(payroll.paid, isTrue);
      expect((await db.query('salary_payments')), hasLength(1));

      // 9. Laporan PPN sejalan dengan ringkasan laporan.
      final now = DateTime.now();
      final summary = await AppDatabase.instance.reportSummary(now, now);
      final rekap = await PajakReportService.instance.rekap(
        nowIso().substring(0, 7),
      );
      expect(summary.totalDppCents, 115000);
      expect(summary.pajakCents, 12650);
      expect(summary.totalDppCents, rekap.dppNetoCents);
      expect(
        summary.pajakCents,
        rekap.pajakKeluaranCents - rekap.returPajakCents,
      );

      // 10. Salinan polos memuat transaksi terakhir dengan versi skema sama.
      final dir = await Directory.systemTemp.createTemp('pusatkupos_e2e_');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {
          // Berkas masih dipakai proses lain; OS akan membersihkannya.
        }
      });
      final copyPath = '${dir.path}/salinan.db';
      await AppDatabase.instance.exportPortableCopy(copyPath);
      final inventory = await AppDatabase.instance.inspectPlainDatabase(
        copyPath,
      );
      expect(inventory.userVersion, AppDatabase.schemaVersion);
      expect(inventory.tables['customers']!.rows, 1);
      expect(inventory.tables['service_records']!.rows, 2);
      expect(inventory.tables['salary_payments']!.rows, 1);

      // 11. Snapshot dapat diterapkan ke DB bersih dengan isi yang sama.
      final signing = await generateSigningKey();
      final storeKey = List<int>.generate(32, (index) => index + 1);
      final snapshot = await AppDatabase.instance.createSnapshotPayload(
        storeId: 'utama',
        deviceId: 'e2e-sumber',
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeSeq: 1,
      );
      final trackedTables = [
        'customers',
        'vehicle_or_units',
        'service_records',
        'service_jobs',
        'service_parts',
        'sale_returns',
        'supplier_purchases',
        'supplier_payments',
        'salary_payments',
        'cash_ledger',
      ];
      final sourceCounts = await _counts(db, trackedTables);

      final target = await openTestDatabaseAt('${dir.path}/tujuan.db');
      await AppDatabase.instance.useTestDatabase(
        target,
        path: '${dir.path}/tujuan.db',
      );
      final applied = await AppDatabase.instance.applySnapshotPayload(
        snapshot,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
        storeId: 'utama',
        deviceId: 'e2e-tujuan',
      );
      expect(applied['applied'], isTrue);
      expect(await _counts(target, trackedTables), sourceCounts);

      // 12. Fitur OFF menolak penulisan lokal tanpa menghapus data lama.
      await FeatureFlagsService.instance.load();
      final estimatesBefore = (await target.query('estimates')).length;
      await FeatureFlagsService.instance.setEnabled(
        key: featureEstimasi,
        enabled: false,
        actor: Operator.owner,
        reason: 'uji E2E',
      );
      await expectLater(
        OrderService.instance.createEstimate(
          customerId: 1,
          unitId: 1,
          jenisTransaksi: transactionEstimasiSaja,
          items: [
            EstimateItemInput(
              jenis: 'jasa',
              deskripsi: 'Estimasi',
              jumlah: 1,
              hargaCents: 10000,
              modalCents: 0,
            ),
          ],
          actor: Operator.owner,
        ),
        throwsA(isA<StateError>()),
      );
      expect((await target.query('estimates')).length, estimatesBefore);
    });
  });
}

Future<Map<String, int>> _counts(Database db, List<String> tables) async {
  final result = <String, int>{};
  for (final table in tables) {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    result[table] = (rows.first['total'] as num?)?.toInt() ?? 0;
  }
  return result;
}
