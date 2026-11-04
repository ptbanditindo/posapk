import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/receipt_service.dart';
import 'package:pusatkupos/data/receipt_settings.dart';
import 'package:pusatkupos/printer/escpos_builder.dart';
import 'package:pusatkupos/printer/printer_config.dart';
import 'package:pusatkupos/printer/printer_storage.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late int recordId;

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    dir = await Directory.systemTemp.createTemp('pusatkupos_receipt_');
    db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'receipt.db'));
    await db.setSetting('bengkel.nama', 'BENGKEL UJI');
    await db.setSetting('bengkel.alamat', 'Jl. Uji No. 1');
    await db.setSetting('bengkel.tagline', 'Servis Cepat');
    await db.setSetting('bengkel.telepon', '081200000001');
    await db.setSetting('bengkel.rekening', 'BCA 1234567890');
    await db.setSetting('struk.footer', 'Terima kasih sudah servis');

    final customerId = await db.addCustomer(
      nama: 'Pelanggan Struk',
      nomorHp: '081200000555',
    );
    final unitId = await db.addUnit(
      customerId: customerId,
      unitType: 'MOBIL',
      nopol: 'B 555 ST',
    );
    final stockId = await db.saveStockItem(
      kode: 'STRUK-1',
      nama: 'Filter Oli',
      hargaModalCents: 50000,
      hargaJualCents: 75000,
      jumlah: 10,
      stokMinimum: 1,
    );
    recordId = await db.createTransaction(
      unitId: unitId,
      keluhan: 'Ganti oli rutin',
      jobs: [
        JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 100000),
      ],
      parts: [
        PartDraft(
          stockItemId: stockId,
          nama: 'Filter Oli',
          jumlah: 2,
          hargaCents: 75000,
          modalCents: 50000,
        ),
      ],
      diskonCents: 5000,
      metodeBayar: 'CASH',
      bayarCents: 250000,
      bergaransi: true,
      garansiBulan: 1,
      catatanGaransi: 'Garansi tidak berlaku untuk kerusakan akibat banjir.',
    );
    await db.db.update(
      'service_records',
      {'created_by': 'Kasir Uji', 'mechanic': 'Mekanik Uji'},
      where: 'id = ?',
      whereArgs: [recordId],
    );
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('struk memuat identitas, rincian, total, dan garansi', () async {
    final document = await ReceiptService.instance.build(recordId);
    expect(document.width, 32);
    final text = document.text;
    expect(text, contains('BENGKEL UJI'));
    expect(text, contains('Servis Cepat'));
    expect(text, contains('081200000001'));
    expect(text, contains('No. Nota'));
    expect(text, contains('Pelanggan Struk'));
    expect(text, contains('081200000555'));
    expect(text, contains('JASA'));
    expect(text, contains('SPAREPART'));
    expect(text, contains('GRAND TOTAL'));
    expect(text, contains('Garansi'));
    expect(text, contains('BCA 1234567890'));
    expect(text, contains('Terima kasih sudah servis'));
    for (final line in text.split('\n')) {
      expect(line.length, lessThanOrEqualTo(32));
    }
  });

  test('matikan bagian struk menghilangkan baris terkait', () async {
    await ReceiptSettings.instance.save('part', false);
    await ReceiptSettings.instance.save('hp', false);
    try {
      final text = (await ReceiptService.instance.build(recordId)).text;
      expect(text, isNot(contains('SPAREPART')));
      expect(text, isNot(contains('081200000555')));
      expect(text, contains('JASA'));
    } finally {
      await ReceiptSettings.instance.save('part', true);
      await ReceiptSettings.instance.save('hp', true);
    }
  });

  test('kasir dan mekanik mengikuti saklar fitur karyawan', () async {
    var text = (await ReceiptService.instance.build(recordId)).text;
    expect(text, contains('Kasir Uji'));
    expect(text, contains('Mekanik Uji'));

    await db.setSetting('fitur.karyawan', '0');
    try {
      text = (await ReceiptService.instance.build(recordId)).text;
      expect(text, isNot(contains('Kasir Uji')));
      expect(text, isNot(contains('Mekanik Uji')));
    } finally {
      await db.setSetting('fitur.karyawan', '1');
    }
  });

  test('lebar 48 kolom membungkus tanpa melewati batas', () async {
    final document = await ReceiptService.instance.build(recordId, width: 48);
    expect(document.width, 48);
    for (final line in document.text.split('\n')) {
      expect(line.length, lessThanOrEqualTo(48));
    }
    expect(
      () => ReceiptService.instance.build(recordId, width: 40),
      throwsArgumentError,
    );
  });

  test('wrapText memecah kata panjang dan menjaga lebar', () {
    expect(wrapText('satu dua tiga', 8), ['satu dua', 'tiga']);
    expect(
      wrapText('abcdefghijkl', 5),
      ['abcde', 'fghij', 'kl'],
    );
    expect(wrapText('', 10), isEmpty);
  });

  test('ESC/POS memakai init, Latin-1, dan perintah potong', () {
    final builder = EscPosBuilder(width: 32)
      ..init()
      ..text('Halo é — Rp')
      ..feed(2)
      ..cut();
    final bytes = builder.bytes;
    expect(bytes.take(2).toList(), [0x1b, 0x40]);
    expect(bytes, containsAllInOrder(latin1.encode('Halo é ? Rp')));
    expect(bytes.sublist(bytes.length - 4), [0x1d, 0x56, 0x42, 0x00]);
  });

  test('konfigurasi printer valid dan menyimpan satu printer utama', () async {
    final store = PrinterStore(storage: MemoryPrinterStorage());
    final first = PrinterConfig(
      id: 'p1',
      nama: 'Kasir',
      host: '192.168.1.10',
      paperMm: 80,
      utama: true,
    );
    final second = PrinterConfig(
      id: 'p2',
      nama: 'Gudang',
      host: '192.168.1.11',
      utama: true,
    );
    await store.saveAll([first, second]);
    final loaded = await store.load();
    expect(loaded.length, 2);
    expect(loaded.first.utama, isTrue);
    expect(loaded.last.utama, isFalse);
    expect(loaded.first.width, 48);
    expect((await store.primary())?.id, 'p1');

    expect(
      () => PrinterConfig(id: 'x', nama: '', host: 'h').validate(),
      throwsArgumentError,
    );
    expect(
      () => PrinterConfig(id: 'x', nama: 'n', host: '').validate(),
      throwsArgumentError,
    );
    expect(
      () => PrinterConfig(id: 'x', nama: 'n', host: 'h', port: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => PrinterConfig(
        id: 'b1',
        nama: 'BT',
        connectionType: 'BLUETOOTH',
        address: 'AA:BB',
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => store.saveAll([
        first,
        PrinterConfig(
          id: 'p3',
          nama: 'Duplikat',
          host: '192.168.1.10',
        ),
      ]),
      throwsArgumentError,
    );
  });
}
