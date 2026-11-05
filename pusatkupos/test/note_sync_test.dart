import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/note_sync.dart';

void main() {
  test('nota dan pembayaran tersinkron, void memulihkan stok', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_note_');
    final a = AppDatabase();
    final b = AppDatabase();
    await a.initForTest(p.join(dir.path, 'a.db'));
    await b.initForTest(p.join(dir.path, 'b.db'));
    try {
      final customerId = await a.addCustomer(
        nama: 'Budi Uji',
        nomorHp: '081200000001',
      );
      final unitId = await a.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 9 UJI',
        jenisMobil: 'Avanza',
      );
      await a.saveStockItem(
        kode: 'SP-100',
        nama: 'Radiator Uji',
        hargaModalCents: 20000000,
        hargaJualCents: 30000000,
        jumlah: 10,
        stokMinimum: 2,
      );
      final stockA = (await a.listStock()).first;
      final recordA = await a.createTransaction(
        unitId: unitId,
        keluhan: 'Radiator bocor',
        jobs: [
          JobDraft(deskripsi: 'Bongkar pasang', jumlah: 1, hargaCents: 10000000),
        ],
        parts: [
          PartDraft(
            stockItemId: stockA.id,
            nama: stockA.nama,
            jumlah: 3,
            hargaCents: stockA.hargaJualCents,
            modalCents: stockA.hargaModalCents,
          ),
        ],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 100000000,
        requestId: 'note-sync-1',
      );
      expect((await a.listStock()).first.jumlah, 7);

      final payload = await a.noteSyncPayload(recordA);
      expect(
        await b.applyNotePayload(b.db, payload, action: 'upsert'),
        'applied',
      );

      final detailB = await b.recordDetail(1);
      expect(detailB, isNotNull);
      expect(detailB!.record.totalCents, 100000000);
      expect(detailB.payments.length, 1);
      expect(detailB.payments.first.nominalCents, 100000000);
      expect((await b.listStock()).first.jumlah, 7);
      final partRows = await b.db.query('service_parts');
      expect(partRows.single['stock_item_id'], (await b.listStock()).first.id);

      expect(
        await b.applyNotePayload(b.db, payload, action: 'upsert'),
        'duplicate',
      );
      expect((await b.listStock()).first.jumlah, 7);
      expect((await b.db.query('service_payments')).length, 1);

      await a.voidRecord(recordA, 'Salah input');
      final voidPayload = await a.noteSyncPayload(recordA);
      expect(
        await b.applyNotePayload(b.db, voidPayload, action: 'void'),
        'void',
      );
      expect((await b.listStock()).first.jumlah, 10);
      final voidedB = await b.recordDetail(detailB.record.id);
      expect(voidedB!.record.isVoid, isTrue);
      expect(voidedB.voidReason, 'Salah input');

      expect(
        await b.applyNotePayload(b.db, voidPayload, action: 'void'),
        'duplicate',
      );
      expect((await b.listStock()).first.jumlah, 10);
    } finally {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    }
  });

  test('nomor nota berprefix perangkat dan tidak pernah dipakai ulang',
      () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_nota_no_');
    final db = AppDatabase();
    await db.initForTest(p.join(dir.path, 'nota.db'));
    try {
      Future<int> buatNota(String nama, String phone) async {
        final customerId = await db.addCustomer(
          nama: nama,
          nomorHp: phone,
        );
        final unitId = await db.addUnit(
          customerId: customerId,
          unitType: 'MOBIL',
          nopol: 'B 1 $nama',
        );
        return db.createTransaction(
          unitId: unitId,
          keluhan: 'Servis rutin',
          jobs: [
            JobDraft(deskripsi: 'Servis', jumlah: 1, hargaCents: 10000000),
          ],
          parts: const [],
          diskonCents: 0,
          metodeBayar: 'CASH',
          bayarCents: 10000000,
        );
      }

      final pertama = await buatNota('Andi', '081200000002');
      final kedua = await buatNota('Beni', '081200000003');
      final ketiga = await buatNota('Cici', '081200000004');
      Future<String> noNota(int id) async =>
          (await db.recordDetail(id))!.record.noNota;
      String urutan(String nomor) =>
          RegExp(r'-(\d{4})$').firstMatch(nomor)!.group(1)!;

      final nomorPertama = await noNota(pertama);
      final nomorKedua = await noNota(kedua);
      expect(nomorPertama, matches(RegExp(r'^[A-Z0-9]+-N\d{8}-0001$')));
      expect(urutan(nomorKedua), '0002');
      expect(urutan(await noNota(ketiga)), '0003');
      expect(nomorKedua.split('-').first, nomorPertama.split('-').first);

      await db.voidRecord(kedua, 'Salah input');
      final keempat = await buatNota('Dedi', '081200000005');
      expect(urutan(await noNota(keempat)), '0004');
      final semua = await db.db.query('service_records', columns: ['no_nota']);
      expect(semua.map((row) => row['no_nota']).toSet().length, semua.length);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('nomor nota lama tidak memengaruhi urutan perangkat', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_nota_seq_');
    final db = AppDatabase();
    await db.initForTest(p.join(dir.path, 'nota.db'));
    try {
      final customerId = await db.addCustomer(
        nama: 'Eka',
        nomorHp: '081200000003',
      );
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 2 EKA',
      );
      await db.db.insert('service_records', {
        'sync_id': 'legacy-note-41',
        'no_nota': '41',
        'unit_id': unitId,
        'waktu_service': '2026-01-01T00:00:00.000',
        'keluhan_awal': 'Nota lama',
        'biaya_jasa': 0,
        'total_part': 0,
        'diskon': 0,
        'total_servis': 0,
        'metode_bayar': 'CASH',
        'bayar': 0,
        'kembalian': 0,
        'status_bayar': 'LUNAS',
        'jenis_bayar': 'LUNAS',
        'total_dibayar': 0,
        'sisa_bayar': 0,
        'status': 'AKTIF',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-01T00:00:00.000',
      });
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Servis baru',
        jobs: [
          JobDraft(deskripsi: 'Servis', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
      );
      final nomor = (await db.recordDetail(recordId))!.record.noNota;
      expect(nomor, matches(RegExp(r'^[A-Z0-9]+-N\d{8}-0001$')));
      expect(nomor, isNot('42'));

      final customer2 = await db.addCustomer(
        nama: 'Fajar',
        nomorHp: '081200000006',
      );
      final unit2 = await db.addUnit(
        customerId: customer2,
        unitType: 'MOBIL',
        nopol: 'B 3 FJR',
      );
      final berikut = await db.createTransaction(
        unitId: unit2,
        keluhan: 'Servis kedua',
        jobs: [
          JobDraft(deskripsi: 'Servis', jumlah: 1, hargaCents: 1000000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000000,
      );
      final nomorBerikut = (await db.recordDetail(berikut))!.record.noNota;
      expect(nomorBerikut, matches(RegExp(r'^[A-Z0-9]+-N\d{8}-0002$')));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
