import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/supplier_service.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  var sequence = 0;

  Future<int> addStock({
    required String nama,
    required int jumlah,
    int stokMinimum = 0,
  }) {
    sequence++;
    return db.saveStockItem(
      kode: 'SUP-$sequence',
      nama: nama,
      hargaModalCents: 10000,
      hargaJualCents: 15000,
      jumlah: jumlah,
      stokMinimum: stokMinimum,
    );
  }

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_supplier_');
    db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'supplier.db'));
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('validasi nama dan duplikat supplier', () async {
    expect(
      () => SupplierService.instance.saveSupplier(nama: 'A'),
      throwsArgumentError,
    );

    final id = await SupplierService.instance.saveSupplier(
      nama: 'Toko Sumber Jaya',
      nomorHp: '0812-3456-7890',
    );
    final row = (await db.db.query(
      'suppliers',
      where: 'id = ?',
      whereArgs: [id],
    ))
        .single;
    expect(row['nama'], 'Toko Sumber Jaya');
    expect(row['nomor_hp'], '081234567890');

    expect(
      () => SupplierService.instance.saveSupplier(nama: 'toko sumber jaya'),
      throwsStateError,
    );
    // Nama sama untuk supplier yang sedang diubah tidak dianggap duplikat.
    await SupplierService.instance.saveSupplier(
      id: id,
      nama: 'Toko Sumber Jaya',
    );
  });

  test('kaitan barang supplier disinkronkan tanpa duplikat', () async {
    final first = await SupplierService.instance.saveSupplier(nama: 'Sinar');
    final second = await SupplierService.instance.saveSupplier(nama: 'Abadi');
    final stockId = await addStock(nama: 'Oli Mesin', jumlah: 10);

    await SupplierService.instance.syncItemSuppliers(stockId, {first, second});
    var linked = await SupplierService.instance.supplierIdsForItem(stockId);
    expect(linked, {first, second});

    await SupplierService.instance.syncItemSuppliers(stockId, {second});
    linked = await SupplierService.instance.supplierIdsForItem(stockId);
    expect(linked, {second});

    await SupplierService.instance.syncItemSuppliers(stockId, {second});
    final rows = await db.db.query(
      'supplier_items',
      where: 'stock_item_id = ?',
      whereArgs: [stockId],
    );
    expect(rows.length, 1);
  });

  test('barang menipis memakai batas minimum atau bawaan 3', () async {
    final supplier = await SupplierService.instance.saveSupplier(
      nama: 'Mitra Part',
    );
    final lowDefault = await addStock(nama: 'Busi', jumlah: 3);
    final lowCustom = await addStock(nama: 'Filter', jumlah: 5, stokMinimum: 8);
    final cukup = await addStock(nama: 'Aki', jumlah: 9, stokMinimum: 8);
    await SupplierService.instance
        .syncItemSuppliers(lowDefault, {supplier});
    await SupplierService.instance.syncItemSuppliers(lowCustom, {supplier});
    await SupplierService.instance.syncItemSuppliers(cukup, {supplier});

    final rows = await SupplierService.instance.lowStockItems();
    final disaring = rows
        .where((row) => row['supplier_id'] == supplier)
        .map((row) => row['stock_item_id'])
        .toSet();
    expect(disaring, containsAll([lowDefault, lowCustom]));
    expect(disaring, isNot(contains(cukup)));

    final filtered =
        await SupplierService.instance.lowStockItems(supplierId: supplier);
    expect(
      filtered.map((row) => row['stock_item_id']).toSet(),
      disaring,
    );
    expect(
      filtered.firstWhere((row) => row['stock_item_id'] == lowDefault)['status'],
      'BELUM',
    );
  });

  test('status follow up tersimpan dan diperbarui', () async {
    final supplier = await SupplierService.instance.saveSupplier(nama: 'Jaya');
    final stockId = await addStock(nama: 'Kampas Rem', jumlah: 1);
    await SupplierService.instance.syncItemSuppliers(stockId, {supplier});

    await SupplierService.instance.setFollowupStatus(
      supplierId: supplier,
      stockItemId: stockId,
      status: 'DIPESAN',
      catatan: 'Pesan 1 dus',
    );
    final rows = await SupplierService.instance.followupRows();
    final row = rows.firstWhere(
      (item) =>
          item['supplier_id'] == supplier && item['stock_item_id'] == stockId,
    );
    expect(row['status'], 'DIPESAN');
    expect(row['catatan'], 'Pesan 1 dus');

    await SupplierService.instance.setFollowupStatus(
      supplierId: supplier,
      stockItemId: stockId,
      status: 'DIKIRIM',
    );
    final updated = (await db.db.query(
      'supplier_followups',
      where: 'supplier_id = ? AND stock_item_id = ?',
      whereArgs: [supplier, stockId],
    ))
        .single;
    expect(updated['status'], 'DIKIRIM');
    expect(updated['catatan'], isNull);

    expect(
      () => SupplierService.instance.setFollowupStatus(
        supplierId: supplier,
        stockItemId: stockId,
        status: 'HILANG',
      ),
      throwsArgumentError,
    );
  });

  test('hapus supplier ikut menghapus kaitan dan follow up', () async {
    final supplier = await SupplierService.instance.saveSupplier(nama: 'Lama');
    final stockId = await addStock(nama: 'Bearing', jumlah: 2);
    await SupplierService.instance.syncItemSuppliers(stockId, {supplier});
    await SupplierService.instance.setFollowupStatus(
      supplierId: supplier,
      stockItemId: stockId,
      status: 'DIPESAN',
    );

    await SupplierService.instance.deleteSupplier(supplier);
    expect(
      await db.db.query(
        'supplier_items',
        where: 'supplier_id = ?',
        whereArgs: [supplier],
      ),
      isEmpty,
    );
    expect(
      await db.db.query(
        'supplier_followups',
        where: 'supplier_id = ?',
        whereArgs: [supplier],
      ),
      isEmpty,
    );
  });
}
