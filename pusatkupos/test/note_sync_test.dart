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

  test('nomor nota dua perangkat berbeda', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_nota_no_');
    final a = AppDatabase();
    final b = AppDatabase();
    await a.initForTest(p.join(dir.path, 'a.db'));
    await b.initForTest(p.join(dir.path, 'b.db'));
    try {
      Future<String> buatNota(AppDatabase db, String nama) async {
        final customerId = await db.addCustomer(
          nama: nama,
          nomorHp: '081200000002',
        );
        final unitId = await db.addUnit(
          customerId: customerId,
          unitType: 'MOBIL',
          nopol: 'B 1 $nama',
        );
        final recordId = await db.createTransaction(
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
        return (await db.recordDetail(recordId))!.record.noNota;
      }

      final noA = await buatNota(a, 'Andi');
      final noB = await buatNota(b, 'Beni');
      expect(noA, startsWith('INV-'));
      expect(noB, startsWith('INV-'));
      expect(noA, isNot(noB));
    } finally {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    }
  });
}
