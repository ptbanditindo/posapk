import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/opening_balance_service.dart';
import 'package:pusatkupos/data/opname_service.dart';
import 'package:pusatkupos/data/purchase_service.dart';
import 'package:pusatkupos/data/stock_ledger.dart';
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

  /// Membuat barang lewat formulir stok sehingga saldo awal tercatat
  /// sebagai movement MASUK.
  Future<int> createStockItem({
    String kode = 'OLI-1',
    String nama = 'Oli mesin',
    int hargaJual = 20000,
    int hargaModal = 10000,
    int stokMilli = 0,
  }) {
    return AppDatabase.instance.saveStockItem(
      kode: kode,
      nama: nama,
      hargaModalCents: hargaModal,
      hargaJualCents: hargaJual,
      jumlah: stokMilli ~/ 1000,
      jumlahMilli: stokMilli,
      stokMinimum: 0,
      actor: Operator.owner,
    );
  }

  Future<int> createPurchase({
    required int supplierId,
    required int stockItemId,
    required int qtyMilli,
    required int hargaSatuan,
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
        jenisBayar: 'TUNAI',
        bayarAwal: (qtyMilli * hargaSatuan) ~/ 1000,
      ),
      actor: Operator.owner,
    );
  }

  Future<int> sellParts({
    required int stockItemId,
    required String nama,
    required int qtyMilli,
    required int hargaCents,
    required int modalCents,
  }) async {
    final customerId = await insertCustomer();
    final unitId = await insertUnit(customerId);
    return AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Jual sparepart',
      jobs: const [],
      parts: [
        PartDraft(
          stockItemId: stockItemId,
          nama: nama,
          jumlah: qtyMilli ~/ 1000,
          qtyMilli: qtyMilli,
          hargaCents: hargaCents,
          modalCents: modalCents,
        ),
      ],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: (qtyMilli * hargaCents) ~/ 1000,
      actor: Operator.owner,
    );
  }

  Future<Map<String, Object?>> rowAt(String table, int id) async {
    return (await db.query(table, where: 'id = ?', whereArgs: [id])).single;
  }

  Future<Map<String, Object?>?> balanceOf(int stockItemId) async {
    final stock = await rowAt('stock_items', stockItemId);
    final rows = await db.query(
      'stock_balances',
      where: 'store_id = ? AND stock_sync_id = ?',
      whereArgs: ['utama', stock['sync_id']],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  group('ledger persediaan', () {
    test('saldo, nilai, dan HPP rata-rata konsisten melewati harga modal '
        'yang berbeda', () async {
      final stockId = await createStockItem();
      final supplierId = await insertSupplier();

      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 100000,
        hargaSatuan: 10000,
      );
      var balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 100000);
      expect(balance?['value_cents'], 1000000);
      expect(balance?['avg_cost_cents'], 10000);

      await sellParts(
        stockItemId: stockId,
        nama: 'Oli mesin',
        qtyMilli: 80000,
        hargaCents: 20000,
        modalCents: 10000,
      );
      balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 20000);
      expect(balance?['value_cents'], 200000);
      expect(balance?['avg_cost_cents'], 10000);

      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 20000,
        hargaSatuan: 20000,
      );
      balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 40000);
      expect(balance?['value_cents'], 600000);
      expect(balance?['avg_cost_cents'], 15000);
      expect(
        (await rowAt('stock_items', stockId))['jumlah_milli'],
        balance?['qty_milli'],
      );
    });

    test('rebuild memulihkan saldo dan nilai dari riwayat movement', () async {
      final stockId = await createStockItem();
      final supplierId = await insertSupplier();

      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 100000,
        hargaSatuan: 10000,
      );
      await sellParts(
        stockItemId: stockId,
        nama: 'Oli mesin',
        qtyMilli: 80000,
        hargaCents: 20000,
        modalCents: 10000,
      );
      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 20000,
        hargaSatuan: 20000,
      );

      final rebuilt = await db.transaction(
        (txn) => StockLedger.instance.rebuild(txn),
      );
      expect(rebuilt, greaterThanOrEqualTo(1));

      final balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 40000);
      expect(balance?['value_cents'], 600000);
      expect(balance?['avg_cost_cents'], 15000);
      final costRows = await db.query(
        'stock_cost_state',
        where: 'store_id = ? AND stock_sync_id = ?',
        whereArgs: ['utama', (await rowAt('stock_items', stockId))['sync_id']],
      );
      expect(costRows.single['hpp_rata_milli'], 15000);
    });

    test('koreksi stok berulang memakai sync id movement yang unik', () async {
      final stockId = await createStockItem(stokMilli: 5000);

      Future<void> editStock(int jumlahMilli) {
        return AppDatabase.instance.saveStockItem(
          id: stockId,
          kode: 'OLI-1',
          nama: 'Oli mesin',
          hargaModalCents: 10000,
          hargaJualCents: 20000,
          jumlah: jumlahMilli ~/ 1000,
          jumlahMilli: jumlahMilli,
          stokMinimum: 0,
          alasan: 'Hitung ulang',
          actor: Operator.owner,
        );
      }

      await editStock(6000);
      await editStock(7000);

      final movements = await db.query(
        'stock_movements',
        where: "stock_item_id = ? AND jenis = 'KOREKSI'",
        whereArgs: [stockId],
      );
      expect(movements, hasLength(2));
      expect(
        movements.map((row) => row['sync_id']).toSet(),
        hasLength(2),
      );
      expect((await rowAt('stock_items', stockId))['jumlah_milli'], 7000);
      final balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 7000);
      expect(balance?['value_cents'], 70000);
      expect(balance?['avg_cost_cents'], 10000);
    });

    test('opname tertunda memakai basis saat hitung sehingga penjualan '
        'sesudahnya tidak tertimpa', () async {
      final stockId = await createStockItem(stokMilli: 100000);
      await db.insert('device_sync_status', {
        'device_id': 'perangkat-2',
        'nama': 'Kasir 2',
        'state': 'pending',
        'updated_at': nowIso(),
      });

      final gate = await OpnameService.instance.record(
        itemId: stockId,
        namaItem: 'Oli mesin',
        jumlahFisikMilli: 90000,
        alasan: 'Hitung fisik',
        actor: Operator.owner,
      );
      expect(gate.held, isTrue);
      final hold = (await db.query(
        'opname_holds',
        where: 'id = ?',
        whereArgs: [gate.holdId],
      )).single;
      expect(hold['basis_milli'], 100000);

      await sellParts(
        stockItemId: stockId,
        nama: 'Oli mesin',
        qtyMilli: 5000,
        hargaCents: 20000,
        modalCents: 10000,
      );
      expect((await rowAt('stock_items', stockId))['jumlah_milli'], 95000);

      await db.delete(
        'device_sync_status',
        where: 'device_id = ?',
        whereArgs: ['perangkat-2'],
      );
      final processed = await OpnameService.instance.processPending(
        actor: Operator.owner,
      );
      expect(processed, 1);

      expect((await rowAt('stock_items', stockId))['jumlah_milli'], 85000);
      expect(
        (await rowAt('opname_holds', gate.holdId!))['status'],
        OpnameService.statusApplied,
      );
      final correction = (await db.query(
        'stock_movements',
        where: "stock_item_id = ? AND jenis = 'KOREKSI'",
        whereArgs: [stockId],
      )).single;
      expect(correction['opname_basis_milli'], 100000);
      expect(correction['opname_absolut_milli'], 90000);
      expect(correction['jumlah_milli'], -10000);
      expect(correction['stok_sesudah_milli'], 85000);
      final balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 85000);
      expect(balance?['value_cents'], 850000);
    });

    test('opname dan pembatalan saldo awal memperbarui nilai persediaan',
        () async {
      final stockId = await createStockItem(stokMilli: 100000);

      await db.transaction(
        (txn) => AppDatabase.instance.applyOpnameTx(
          txn,
          itemId: stockId,
          namaItem: 'Oli mesin',
          jumlahFisikMilli: 90000,
          alasan: 'Hitung fisik',
          actor: Operator.owner,
        ),
      );
      var balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 90000);
      expect(balance?['value_cents'], 900000);
      expect(balance?['avg_cost_cents'], 10000);

      final otherStock = await createStockItem(
        kode: 'OLI-2',
        nama: 'Oli gardan',
      );
      await OpeningBalanceService.instance.post(
        items: [
          OpeningItemInput(
            jenis: 'STOK',
            refId: otherStock,
            jumlahMilli: 5000,
          ),
        ],
        actor: Operator.owner,
      );
      balance = await balanceOf(otherStock);
      expect(balance?['qty_milli'], 5000);
      expect(balance?['value_cents'], 50000);
      expect(balance?['avg_cost_cents'], 10000);

      await OpeningBalanceService.instance.voidActive(
        reason: 'Salah input',
        actor: Operator.owner,
      );
      expect((await rowAt('stock_items', otherStock))['jumlah_milli'], 0);
      balance = await balanceOf(otherStock);
      expect(balance?['qty_milli'], 0);
      expect(balance?['value_cents'], 0);
      expect(balance?['avg_cost_cents'], 0);
    });

    test('snapshot HPP nota memakai rata-rata berjalan, bukan harga modal '
        'master', () async {
      final stockId = await createStockItem(); // master modal 10.000
      final supplierId = await insertSupplier();
      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 100000,
        hargaSatuan: 10000,
      );
      await createPurchase(
        supplierId: supplierId,
        stockItemId: stockId,
        qtyMilli: 100000,
        hargaSatuan: 20000,
      );

      final recordId = await sellParts(
        stockItemId: stockId,
        nama: 'Oli mesin',
        qtyMilli: 1000,
        hargaCents: 20000,
        modalCents: 10000,
      );
      final part = (await db.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      )).single;
      expect(part['harga_modal'], 15000);
      expect(part['harga_batas_saat_transaksi'], 10000);

      final balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 199000);
      expect(balance?['avg_cost_cents'], 15000);
    });

    test('modal saldo awal boleh berbeda dari master dan dipakai ledger',
        () async {
      final stockId = await createStockItem(hargaModal: 40000);

      await OpeningBalanceService.instance.post(
        items: [
          OpeningItemInput(
            jenis: 'STOK',
            refId: stockId,
            jumlahMilli: 20000,
            unitCostCents: 50000,
          ),
        ],
        actor: Operator.owner,
      );

      final item = (await db.query('opening_balance_items')).single;
      expect(item['unit_cost_cents'], 50000);
      final balance = await balanceOf(stockId);
      expect(balance?['qty_milli'], 20000);
      expect(balance?['avg_cost_cents'], 50000);
      expect(balance?['value_cents'], 1000000);

      final stock = await rowAt('stock_items', stockId);
      final movement = (await db.query(
        'stock_movements',
        where: 'stock_sync_id = ? AND jenis = ?',
        whereArgs: [stock['sync_id'], 'MASUK'],
        orderBy: 'id DESC',
        limit: 1,
      )).single;
      expect(movement['harga_pokok_satuan_cents'], 50000);
    });

    test('modal saldo awal kosong memakai modal master', () async {
      final stockId = await createStockItem(hargaModal: 10000);

      await OpeningBalanceService.instance.post(
        items: [
          OpeningItemInput(
            jenis: 'STOK',
            refId: stockId,
            jumlahMilli: 5000,
          ),
        ],
        actor: Operator.owner,
      );

      final item = (await db.query('opening_balance_items')).single;
      expect(item['unit_cost_cents'], 10000);
      final balance = await balanceOf(stockId);
      expect(balance?['avg_cost_cents'], 10000);
      expect(balance?['value_cents'], 50000);
    });

    test('saldo awal remote memakai modal per baris dari payload', () async {
      final stockId = await createStockItem(hargaModal: 10000);
      final stock = await rowAt('stock_items', stockId);
      final now = nowIso();

      await db.transaction(
        (txn) => OpeningBalanceService.instance.applyRemote(
          txn,
          {
            'sync_id': newSyncId(),
            'store_id': 'utama',
            'device_id': 'perangkat-lain',
            'origin_device_id': 'perangkat-lain',
            'posted_at': now,
            'posted_by': 'Pemilik',
            'created_at': now,
            'items': [
              {
                'sync_id': newSyncId(),
                'jenis': 'STOK',
                'ref_sync_id': stock['sync_id'],
                'ref_nama_snapshot': stock['nama'],
                'jumlah_milli': 2000,
                'unit_cost_cents': 55000,
              },
            ],
          },
          wall: 1,
          counter: 1,
          action: 'upsert',
        ),
      );

      final item = (await db.query('opening_balance_items')).single;
      expect(item['unit_cost_cents'], 55000);
      final balance = await balanceOf(stockId);
      expect(balance?['avg_cost_cents'], 55000);
      expect(balance?['value_cents'], 110000);
    });
  });
}
