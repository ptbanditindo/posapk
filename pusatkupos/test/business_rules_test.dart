import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/note_sync.dart';
import 'package:pusatkupos/data/pin_service.dart';
import 'package:pusatkupos/data/price_rules.dart';
import 'package:pusatkupos/data/secure_store.dart';

Future<(Directory, AppDatabase)> _open(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  final db = AppDatabase.instance;
  await db.initForTest(p.join(dir.path, 'test.db'));
  return (dir, db);
}

Future<int> _seedUnit(AppDatabase db, {String phone = '081200000001'}) async {
  final customerId = await db.addCustomer(nama: 'Pelanggan Uji', nomorHp: phone);
  return db.addUnit(
    customerId: customerId,
    unitType: 'MOBIL',
    nopol: 'B 1 UJI',
  );
}

Future<int> _seedStock(
  AppDatabase db, {
  String kode = 'SP-1',
  int qty = 10,
  int hargaJual = 10000000,
}) async {
  return db.saveStockItem(
    kode: kode,
    nama: 'Radiator $kode',
    hargaModalCents: 5000000,
    hargaJualCents: hargaJual,
    jumlah: qty,
    stokMinimum: 1,
  );
}

void main() {
  SecureStore.useMemoryForTests = true;

  test('piutang dapat dibuat dan dilunasi, dashboard sama dengan laporan',
      () async {
    final (dir, db) = await _open('pusatkupos_settle_');
    try {
      final unitId = await _seedUnit(db);
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Servis kredit',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 10000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 4000000,
      );
      var detail = await db.recordDetail(recordId);
      expect(detail!.record.statusBayar, 'KREDIT');
      expect(detail.sisaCents, 6000000);
      var dash = await db.dashboard();
      expect(dash.receivableCents, 6000000);

      await db.settleReceivable(
        recordId: recordId,
        nominalCents: 2000000,
        metode: 'CASH',
        actor: null,
      );
      detail = await db.recordDetail(recordId);
      expect(detail!.sisaCents, 4000000);
      expect(detail.record.statusBayar, 'KREDIT');

      await db.settleReceivable(
        recordId: recordId,
        nominalCents: 4000000,
        metode: 'TRANSFER',
        actor: null,
      );
      detail = await db.recordDetail(recordId);
      expect(detail!.sisaCents, 0);
      expect(detail.record.statusBayar, 'LUNAS');
      expect(detail.totalDibayarCents, 10000000);

      final summary = await db.reportSummary(DateTime.now(), DateTime.now());
      dash = await db.dashboard();
      expect(dash.todayRevenueCents, summary.totalCents);
      expect(dash.todayCount, summary.transaksi);
      expect(summary.piutangCents, 0);
      expect(summary.cashByMethod['CASH'], 6000000);
      expect(summary.cashByMethod['TRANSFER'], 4000000);

      final filtered = await db.listRecords(onlyReceivable: true);
      expect(filtered, isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('kredit penuh tanpa bayar dan transfer tidak boleh lebih bayar',
      () async {
    final (dir, db) = await _open('pusatkupos_credit_');
    try {
      final unitId = await _seedUnit(db);
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Kredit penuh',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 5000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 0,
      );
      final detail = await db.recordDetail(recordId);
      expect(detail!.record.statusBayar, 'KREDIT');
      expect(detail.payments, isEmpty);

      await expectLater(
        db.createTransaction(
          unitId: unitId,
          keluhan: 'Transfer lebih',
          jobs: [
            JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 5000000),
          ],
          parts: const [],
          diskonCents: 0,
          metodeBayar: 'TRANSFER',
          bayarCents: 6000000,
        ),
        throwsA(isA<ArgumentError>()),
      );

      final freeId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Gratis',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 5000000),
        ],
        parts: const [],
        diskonCents: 5000000,
        metodeBayar: 'CASH',
        bayarCents: 2000000,
      );
      final freeDetail = await db.recordDetail(freeId);
      expect(freeDetail!.record.totalCents, 0);
      expect(freeDetail.payments, isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('void mencatat refund dan kas kembali nol', () async {
    final (dir, db) = await _open('pusatkupos_refund_');
    try {
      final unitId = await _seedUnit(db);
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Void refund',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 7000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 7000000,
      );
      await db.voidRecord(recordId, 'Salah input');
      final detail = await db.recordDetail(recordId);
      expect(detail!.record.isVoid, isTrue);
      final refund = detail.payments.firstWhere((row) => row.jenis == 'REFUND');
      expect(refund.nominalCents, -7000000);
      final summary = await db.reportSummary(DateTime.now(), DateTime.now());
      expect(summary.cashByMethod['CASH'], 0);
      await expectLater(
        db.voidRecord(recordId, ''),
        throwsA(isA<ArgumentError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('stok desimal, koreksi, keluar manual, dan opname mencatat gerakan',
      () async {
    final (dir, db) = await _open('pusatkupos_stock_');
    try {
      final id = await db.saveStockItem(
        kode: 'OLI-1',
        nama: 'Oli',
        hargaModalCents: 5000000,
        hargaJualCents: 8000000,
        jumlah: 1,
        jumlahMilli: 1500,
        satuan: 'liter',
        desimal: 2,
        stokMinimum: 0,
      );
      var item = (await db.listStock()).first;
      expect(item.jumlahLabel, '1,50 liter');

      await db.stockIn(item: item, qty: 0, qtyMilli: 500);
      item = (await db.listStock()).first;
      expect(item.jumlahMilli, 2000);

      await db.saveStockItem(
        id: id,
        kode: 'OLI-1',
        nama: 'Oli',
        hargaModalCents: 5000000,
        hargaJualCents: 8000000,
        jumlah: 3,
        jumlahMilli: 3000,
        satuan: 'liter',
        desimal: 2,
        stokMinimum: 0,
      );
      await db.stockOut(
        item: item,
        qty: 0,
        qtyMilli: 1000,
        alasan: 'Dipakai sendiri',
      );
      await db.opname(item: item, jumlahFisikMilli: 500, alasan: 'Hitung ulang');
      item = (await db.listStock()).first;
      expect(item.jumlahMilli, 500);

      final movements = await db.db.query('stock_movements');
      expect(movements.where((row) => row['jenis'] == 'KOREKSI').length, 2);
      expect(movements.where((row) => row['jenis'] == 'KELUAR').length, 1);

      await expectLater(
        db.saveStockItem(
          kode: 'OLI-1',
          nama: 'Duplikat',
          hargaModalCents: 0,
          hargaJualCents: 0,
          jumlah: 0,
          stokMinimum: 0,
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('pelanggan dinormalisasi, duplikat ditolak, dan bisa digabung', () async {
    final (dir, db) = await _open('pusatkupos_customer_');
    try {
      final first = await db.addCustomer(
        nama: 'Andi',
        nomorHp: '0812-3456-7890',
      );
      final stored = await db.customerRow(first);
      expect(stored!['nomor_hp'], '081234567890');

      await expectLater(
        db.addCustomer(nama: 'Andi 2', nomorHp: '+62 812 3456 7890'),
        throwsA(isA<DuplicateCustomerException>()),
      );

      final second = await db.addCustomer(
        nama: 'Budi',
        nomorHp: '081200000002',
      );
      await db.addUnit(customerId: second, unitType: 'MOBIL', nopol: 'B 2');
      final merged = await db.mergeCustomers(
        sourceId: second,
        targetId: first,
      );
      expect(merged['units'], isNotEmpty);
      expect((await db.listUnits(first)).length, 1);
      expect((await db.listCustomers()).length, 1);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('izin mekanik ditolak di lapisan data', () async {
    final (dir, db) = await _open('pusatkupos_perm_');
    try {
      final unitId = await _seedUnit(db);
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Izin',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
      );
      const mekanik = Operator(
        kind: 'employee',
        role: 'MEKANIK',
        label: 'Mekanik',
        permissions: {},
      );
      await expectLater(
        db.voidRecord(recordId, 'Coba void', actor: mekanik),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        db.saveStockItem(
          kode: 'X',
          nama: 'X',
          hargaModalCents: 0,
          hargaJualCents: 0,
          jumlah: 1,
          stokMinimum: 0,
          actor: mekanik,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        db.saveCatalog(nama: 'Jasa', hargaCents: 1000, actor: mekanik),
        throwsA(isA<StateError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('nota bentrok nomor tetap masuk dan dicatat sebagai konflik', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_conflict_');
    final a = AppDatabase();
    final b = AppDatabase();
    await a.initForTest(p.join(dir.path, 'a.db'));
    await b.initForTest(p.join(dir.path, 'b.db'));
    try {
      final unitA = await _seedUnit(a, phone: '081200000010');
      final recordA = await a.createTransaction(
        unitId: unitA,
        keluhan: 'Nota A',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
      );
      final payload = await a.noteSyncPayload(recordA);
      final recordPayload = Map<String, Object?>.from(payload['record'] as Map);
      final noNota = recordPayload['no_nota'] as String;

      final unitB = await _seedUnit(b, phone: '081200000011');
      final recordB = await b.createTransaction(
        unitId: unitB,
        keluhan: 'Nota B',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
      );
      await b.db.update(
        'service_records',
        {'no_nota': noNota},
        where: 'id = ?',
        whereArgs: [recordB],
      );

      expect(await b.applyNotePayload(b.db, payload, action: 'upsert'),
          'applied');
      final conflicts = await b.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['no_nota_bentrok'],
      );
      expect(conflicts, isNotEmpty);
      final detail = jsonDecode(conflicts.single['detail_json']! as String)
          as Map<String, dynamic>;
      expect(detail['no_nota_asal'], noNota);
      final rows = await b.db.query(
        'service_records',
        where: 'sync_id = ?',
        whereArgs: [recordPayload['sync_id']],
      );
      expect(rows.single['no_nota'], isNot(noNota));
      expect(rows.single['no_nota'], detail['no_nota_baru']);
      expect(
        rows.single['no_nota'],
        matches(RegExp(r'^[A-Z0-9]+-N\d{8}-\d{4}$')),
      );
    } finally {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    }
  });

  test('stok negatif saat menerima nota dicatat sebagai konflik', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_negstock_');
    final a = AppDatabase();
    final b = AppDatabase();
    await a.initForTest(p.join(dir.path, 'a.db'));
    await b.initForTest(p.join(dir.path, 'b.db'));
    try {
      final unitA = await _seedUnit(a, phone: '081200000012');
      final stockId = await _seedStock(a, kode: 'SP-NEG', qty: 5);
      final itemA = (await a.listStock()).first;
      final recordA = await a.createTransaction(
        unitId: unitA,
        keluhan: 'Negatif',
        jobs: const [],
        parts: [
          PartDraft(
            stockItemId: stockId,
            nama: itemA.nama,
            jumlah: 3,
            hargaCents: itemA.hargaJualCents,
            modalCents: itemA.hargaModalCents,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 30000000,
      );
      final payload = await a.noteSyncPayload(recordA);

      await _seedUnit(b, phone: '081200000013');
      await b.saveStockItem(
        kode: 'SP-NEG',
        nama: 'Radiator SP-NEG',
        hargaModalCents: 5000000,
        hargaJualCents: 10000000,
        jumlah: 1,
        stokMinimum: 0,
      );
      final stockSync = (await b.listStock()).first;
      final partPayload = Map<String, Object?>.from(
        (payload['parts'] as List).first as Map,
      );
      // Samakan sync_id agar penerima memakai barang yang sama.
      await b.db.update(
        'stock_items',
        {'sync_id': partPayload['stock_sync_id']},
        where: 'id = ?',
        whereArgs: [stockSync.id],
      );

      await b.applyNotePayload(b.db, payload, action: 'upsert');
      final itemB = (await b.listStock()).first;
      expect(itemB.jumlahMilli, lessThan(0));
      final conflicts = await b.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['stok_negatif'],
      );
      expect(conflicts, isNotEmpty);
      final dash = await b.dashboard();
      expect(dash.negativeStockCount, greaterThan(0));
    } finally {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    }
  });

  test('pembuat nota menyimpan sync_id karyawan, bukan id lokal', () async {
    final (dir, db) = await _open('pusatkupos_actor_');
    try {
      const syncId = 'akun-sync-001';
      final localId = await db.db.insert('employee_accounts', {
        'sync_id': syncId,
        'username': 'kasir9',
        'nama': 'Kasir Sembilan',
        'role_base': 'KASIR',
        'password_hash': 'x',
        'password_salt': 'y',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      final unitId = await _seedUnit(db);
      final kasir = Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir Sembilan',
        employeeId: localId,
        employeeSyncId: syncId,
        permissions: {'diskon'},
      );
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Audit pembuat',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
        actor: kasir,
      );
      final row = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      ))
          .first;
      expect(row['created_by_employee_id'], syncId);
      expect(row['created_by_employee_id'], isNot('$localId'));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('diskon kasir maksimal selisih modal; pemilik boleh melewati', () async {
    final (dir, db) = await _open('pusatkupos_diskon_');
    try {
      final unitId = await _seedUnit(db);
      const kasir = Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir',
        permissions: {'diskon'},
      );
      Future<int> create(Operator? actor, {int diskon = 200000}) =>
          db.createTransaction(
            unitId: unitId,
            keluhan: 'Diskon',
            jobs: [
              JobDraft(
                deskripsi: 'Jasa',
                jumlah: 1,
                hargaCents: 1000000,
                modalCents: 600000,
              ),
            ],
            parts: const [],
            diskonCents: diskon,
            metodeBayar: 'CASH',
            bayarCents: 1000000 - diskon,
            actor: actor,
          );
      await expectLater(
        create(kasir, diskon: 400001),
        throwsA(
          isA<PriceRuleViolation>().having(
            (error) => error.code,
            'kode',
            'diskon_melebihi_margin',
          ),
        ),
      );
      final kasirRecord = await create(kasir);
      expect(kasirRecord, isPositive);
      final ownerRecord = await create(Operator.owner, diskon: 500000);
      expect(ownerRecord, isPositive);
      final audit = await db.db.query(
        'permission_audits',
        where: 'action = ?',
        whereArgs: ['diskon'],
      );
      expect(audit, isNotEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('PIN pemilik terkunci setelah percobaan berulang', () async {
    final (dir, db) = await _open('pusatkupos_pin_');
    try {
      await PinService.instance.setup('123456');
      for (var i = 0; i < 5; i++) {
        expect(
          await PinService.instance.verifyDetailed('000000'),
          PinVerification.wrong,
        );
      }
      expect(
        await PinService.instance.verifyDetailed('123456'),
        PinVerification.locked,
      );
      expect(await PinService.instance.verify('123456'), isFalse);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
