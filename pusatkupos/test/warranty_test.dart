import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';

Future<(Directory, AppDatabase, int)> _openWithUnit() async {
  final dir = await Directory.systemTemp.createTemp('pusatkupos_warranty_');
  final db = AppDatabase();
  await db.initForTest(p.join(dir.path, 'warranty.db'));
  final customerId = await db.addCustomer(
    nama: 'Pelanggan Garansi',
    nomorHp: '081200000777',
  );
  final unitId = await db.addUnit(
    customerId: customerId,
    unitType: 'MOBIL',
    nopol: 'B 777 GR',
  );
  return (dir, db, unitId);
}

Future<int> _note(
  AppDatabase db,
  int unitId, {
  bool bergaransi = true,
  int garansiBulan = 1,
  DateTime? garansiSampai,
  bool sparepartOnly = false,
  bool garansiBarangAktif = false,
  bool unitDitinggal = false,
}) async {
  int? stockId;
  if (sparepartOnly) {
    stockId = await db.saveStockItem(
      kode: 'GR-${DateTime.now().microsecondsSinceEpoch}',
      nama: 'Part Garansi',
      hargaModalCents: 1000000,
      hargaJualCents: 2000000,
      jumlah: 5,
      stokMinimum: 1,
    );
  }
  return db.createTransaction(
    unitId: unitId,
    keluhan: 'Uji garansi',
    jobs: sparepartOnly
        ? const []
        : [
            JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000000),
          ],
    parts: sparepartOnly
        ? [
            PartDraft(
              stockItemId: stockId!,
              nama: 'Part Garansi',
              jumlah: 1,
              hargaCents: 2000000,
              modalCents: 1000000,
            ),
          ]
        : const [],
    diskonCents: 0,
    metodeBayar: 'CASH',
    bayarCents: sparepartOnly ? 2000000 : 1000000,
    bergaransi: bergaransi,
    garansiBulan: garansiBulan,
    garansiSampai: garansiSampai,
    sparepartOnly: sparepartOnly,
    garansiBarangAktif: garansiBarangAktif,
    garansiBarangNilai: 7,
    unitDitinggal: unitDitinggal,
  );
}

void main() {
  test('garansi default 30 hari per bulan dan bisa diklaim sekali', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      final id = await _note(db, unitId, garansiBulan: 2);
      final detail = (await db.recordDetail(id))!;
      final record = detail.record;
      expect(record.bergaransi, isTrue);
      expect(record.statusKlaim, 'Belum claim');
      expect(record.warrantyActive, isTrue);
      expect(record.warrantyStatus, 'AKTIF');
      final today = DateTime.now();
      final expected = DateTime(today.year, today.month, today.day)
          .add(const Duration(days: 60));
      expect(
        record.garansiSampai,
        DateTime(expected.year, expected.month, expected.day),
      );

      await db.claimWarranty(id);
      final claimed = (await db.recordDetail(id))!.record;
      expect(claimed.statusKlaim, 'Sudah claim');
      expect(claimed.warrantyStatus, 'SUDAH CLAIM');
      expect(claimed.tanggalKlaim, isNotNull);
      await expectLater(
        db.claimWarranty(id),
        throwsA(isA<StateError>()),
      );

      final history = await db.listRecords(limit: 5);
      expect(history.single.warrantyStatus, 'SUDAH CLAIM');
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('nota tanpa garansi tidak bisa diklaim', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      final id = await _note(db, unitId, bergaransi: false);
      final record = (await db.recordDetail(id))!.record;
      expect(record.bergaransi, isFalse);
      expect(record.warrantyStatus, 'TANPA GARANSI');
      await expectLater(db.claimWarranty(id), throwsA(isA<StateError>()));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('garansi kedaluwarsa dan VOID tidak bisa diklaim', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      final id = await _note(db, unitId);
      await db.db.update(
        'service_records',
        {'garansi_sampai': '2020-01-01'},
        where: 'id = ?',
        whereArgs: [id],
      );
      final expired = (await db.recordDetail(id))!.record;
      expect(expired.warrantyStatus, 'KEDALUWARSA');
      await expectLater(db.claimWarranty(id), throwsA(isA<StateError>()));

      final second = await _note(db, unitId);
      await db.voidRecord(second, 'Salah input');
      final voided = (await db.recordDetail(second))!.record;
      expect(voided.warrantyStatus, 'DIBATALKAN');
      await expectLater(
        db.claimWarranty(second),
        throwsA(isA<StateError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('tanggal garansi lampau ditolak saat menyimpan nota', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      await expectLater(
        _note(
          db,
          unitId,
          garansiSampai: DateTime.now().subtract(const Duration(days: 1)),
        ),
        throwsA(isA<ArgumentError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('mode sparepart saja dan garansi barang', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      await expectLater(
        _note(db, unitId, sparepartOnly: true),
        completes,
      );
      final tanpaGaransi = (await db.listRecords(limit: 5)).first;
      expect(tanpaGaransi.bergaransi, isFalse);

      final withBarang = await _note(
        db,
        unitId,
        sparepartOnly: true,
        garansiBarangAktif: true,
      );
      final record = (await db.recordDetail(withBarang))!.record;
      expect(record.bergaransi, isTrue);
      expect(record.warrantyActive, isTrue);
      final today = DateTime.now();
      final expected = DateTime(today.year, today.month, today.day)
          .add(const Duration(days: 7));
      expect(
        record.garansiSampai,
        DateTime(expected.year, expected.month, expected.day),
      );

      await expectLater(
        db.createTransaction(
          unitId: unitId,
          keluhan: 'Salah mode',
          jobs: [JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000)],
          parts: const [],
          diskonCents: 0,
          metodeBayar: 'CASH',
          bayarCents: 1000,
          sparepartOnly: true,
        ),
        throwsA(isA<ArgumentError>()),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('unit ditinggal bisa ditandai sudah diambil', () async {
    final (dir, db, unitId) = await _openWithUnit();
    try {
      final id = await _note(db, unitId, unitDitinggal: true);
      expect((await db.recordDetail(id))!.record.unitDitinggal, isTrue);
      expect((await db.recordDetail(id))!.record.diambilAt, isNull);
      await db.markUnitTaken(id, diambil: true);
      expect((await db.recordDetail(id))!.record.diambilAt, isNotNull);
      await db.markUnitTaken(id, diambil: false);
      expect((await db.recordDetail(id))!.record.diambilAt, isNull);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
