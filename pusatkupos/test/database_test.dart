import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';

void main() {
  test('transaksi, laporan, dan void memulihkan stok', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_test_');
    final db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'test.db'));
    try {
      final customerId = await db.addCustomer(
        nama: 'Pelanggan Tes',
        nomorHp: '081200000000',
      );
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 1 TES',
        jenisMobil: 'Avanza',
      );
      await db.saveStockItem(
        kode: 'SP-001',
        nama: 'Radiator Tes',
        hargaModalCents: 30000000,
        hargaJualCents: 45000000,
        jumlah: 5,
        stokMinimum: 1,
      );
      final stock = (await db.listStock()).first;
      final id = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Tes transaksi',
        jobs: [
          JobDraft(
            deskripsi: 'Jasa Tes',
            jumlah: 1,
            hargaCents: 10000000,
          ),
        ],
        parts: [
          PartDraft(
            stockItemId: stock.id,
            nama: stock.nama,
            jumlah: 2,
            hargaCents: stock.hargaJualCents,
            modalCents: stock.hargaModalCents,
          ),
        ],
        diskonCents: 500000,
        metodeBayar: 'CASH',
        bayarCents: 100000000,
        requestId: 'test-request-1',
      );

      final detail = await db.recordDetail(id);
      expect(detail, isNotNull);
      expect(detail!.record.totalCents, 10000000 + 90000000 - 500000);
      expect(detail.record.statusBayar, 'LUNAS');
      expect((await db.listStock()).first.jumlah, 3);

      final summary = await db.reportSummary(
        DateTime.now(),
        DateTime.now(),
      );
      expect(summary.transaksi, 1);
      expect(summary.totalCents, detail.record.totalCents);

      final duplicate = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Tes transaksi',
        jobs: [
          JobDraft(
            deskripsi: 'Jasa Tes',
            jumlah: 1,
            hargaCents: 10000000,
          ),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 10000000,
        requestId: 'test-request-1',
      );
      expect(duplicate, id);
      expect((await db.listStock()).first.jumlah, 3);

      await db.voidRecord(id, 'Salah input');
      expect((await db.listStock()).first.jumlah, 5);
      final afterVoid = await db.recordDetail(id);
      expect(afterVoid!.record.isVoid, isTrue);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
