import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/data/store_registry.dart';
import 'package:pusatkupos/data/store_service.dart';

import 'test_support.dart';

void main() {
  SecureStore.useMemoryForTests = true;
  late Directory dir;
  late AppDatabase db;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_store_');
    db = AppDatabase.instance;
  });

  tearDownAll(() async {
    await db.close();
    await StoreRegistry.instance.close();
    await dir.delete(recursive: true);
  });

  Future<void> openPrimary(String name) async {
    final root = Directory(p.join(dir.path, name));
    await root.create(recursive: true);
    await db.initForTest(p.join(root.path, 'store.db'));
  }

  test('tambah toko butuh lisensi premium', () async {
    await openPrimary('free');
    await expectLater(
      StoreService.instance.createStore(nama: 'Toko Baru'),
      throwsA(isA<StateError>()),
    );
    expect((await StoreService.instance.listStores()).length, 1);
  });

  test('dua toko tidak berbagi pelanggan, stok, dan pengaturan', () async {
    await openPrimary('utama');
    await db.setSetting('bengkel.nama', 'Toko Satu');
    final ownerId = await LicenseService.instance.ensureOwner();
    await installTestLicense(ownerId: ownerId, google: true);
    expect(await LicenseService.instance.isPremium(), isTrue);

    await db.saveStockItem(
      kode: 'T1-OLI',
      nama: 'Oli Toko Satu',
      hargaModalCents: 10000,
      hargaJualCents: 15000,
      jumlah: 4,
      stokMinimum: 0,
    );
    final stores = await StoreService.instance.listStores();
    expect(stores.length, 1);
    expect(stores.single.nama, 'Toko Satu');

    final second = await StoreService.instance.createStore(
      nama: 'Toko Dua',
      alamat: 'Jalan Dua',
    );
    expect((await StoreService.instance.listStores()).length, 2);

    await StoreService.instance.switchStore(second.storeId);
    expect(db.activeStoreId, second.storeId);
    expect(await db.getSetting('bengkel.nama'), 'Toko Dua');
    expect(await LicenseService.instance.isPremium(), isTrue);
    expect(
      (await db.db.query('stock_items')).length,
      0,
      reason: 'stok toko satu tidak boleh terbawa',
    );
    expect((await db.db.query('customers')).length, 0);

    await db.db.insert('customers', {
      'sync_id': newSyncId(),
      'nama': 'Pelanggan Toko Dua',
      'nomor_hp': '081200000002',
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    await db.saveStockItem(
      kode: 'T2-FILTER',
      nama: 'Filter Toko Dua',
      hargaModalCents: 20000,
      hargaJualCents: 30000,
      jumlah: 2,
      stokMinimum: 0,
    );

    await StoreService.instance.switchStore('utama');
    expect(
      (await db.db.query('customers')).length,
      0,
      reason: 'pelanggan toko dua tidak boleh masuk toko satu',
    );
    final primaryStock = await db.db.query('stock_items');
    expect(primaryStock.length, 1);
    expect(primaryStock.single['kode'], 'T1-OLI');

    await StoreService.instance.switchStore(second.storeId);
    final secondCustomers = await db.db.query('customers');
    expect(secondCustomers.length, 1);
    expect(secondCustomers.single['nama'], 'Pelanggan Toko Dua');
    expect((await db.db.query('stock_items')).single['kode'], 'T2-FILTER');
  });

  test('ganti toko berulang mempertahankan data toko', () async {
    await openPrimary('repeat');
    final ownerId = await LicenseService.instance.ensureOwner();
    await installTestLicense(ownerId: ownerId, google: true);
    final second = await StoreService.instance.createStore(nama: 'Toko Ulang');

    await StoreService.instance.switchStore(second.storeId);
    await db.setSetting('uji.marker', 'tersimpan');

    for (var i = 0; i < 3; i++) {
      await StoreService.instance.switchStore('utama');
      expect(db.activeStoreId, 'utama');
      await StoreService.instance.switchStore(second.storeId);
      expect(db.activeStoreId, second.storeId);
      expect(await db.getSetting('uji.marker'), 'tersimpan');
    }
  });

  test('karyawan tidak bisa pindah ke toko yang tidak ditugaskan', () async {
    await openPrimary('guard');
    final ownerId = await LicenseService.instance.ensureOwner();
    await installTestLicense(ownerId: ownerId, google: true);
    final second = await StoreService.instance.createStore(nama: 'Toko Lain');

    await expectLater(
      StoreService.instance.switchStore(
        second.storeId,
        allowedStoreIds: {'utama'},
      ),
      throwsA(isA<StateError>()),
    );
    expect(db.activeStoreId, 'utama');
  });
}
