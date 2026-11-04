import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/data/receipt_service.dart';
import 'package:pusatkupos/printer/printer_adapter.dart';
import 'package:pusatkupos/printer/printer_config.dart';
import 'package:pusatkupos/printer/printer_manager.dart';
import 'package:pusatkupos/printer/printer_service.dart';
import 'package:pusatkupos/printer/printer_storage.dart';

class _RecordingAdapter extends PrinterAdapter {
  _RecordingAdapter({this.failConnect = false});

  final bool failConnect;
  PrintPayload? payload;
  int connects = 0;
  int disconnects = 0;

  @override
  String get connectionType => 'NETWORK';

  @override
  Future<void> connect(PrinterConfig printer) async {
    connects++;
    if (failConnect) {
      throw PrinterException('Jaringan tidak tersedia.', code: 'OFFLINE');
    }
  }

  @override
  Future<void> disconnect(PrinterConfig printer) async {
    disconnects++;
  }

  @override
  Future<void> send(PrinterConfig printer, PrintPayload value) async {
    payload = value;
  }
}

void main() {
  test('manager mengarahkan cetak ke adapter dan menyimpan status', () async {
    final adapter = _RecordingAdapter();
    final manager = PrinterManager(adapters: {'NETWORK': adapter});
    final printer = PrinterConfig(
      id: 'net-1',
      nama: 'Kasir',
      host: '192.168.1.10',
      mode: 'ESCPOS',
    );
    await manager.send(
      printer,
      const PrintPayload(
        text: 'Halo',
        bytes: [1, 2, 3],
        width: 32,
        encoding: 'LATIN1',
      ),
    );
    expect(adapter.payload?.text, 'Halo');
    expect(manager.statusOf(printer).status, 'CONNECTED');

    await manager.disconnect(printer);
    expect(adapter.disconnects, 1);
    expect(manager.statusOf(printer).status, 'SAVED');
  });

  test('kegagalan koneksi menandai printer bermasalah', () async {
    final adapter = _RecordingAdapter(failConnect: true);
    final manager = PrinterManager(adapters: {'NETWORK': adapter});
    final printer = PrinterConfig(id: 'net-2', nama: 'Gudang', host: '10.0.0.2');
    await expectLater(manager.connect(printer), throwsA(isA<PrinterException>()));
    final status = manager.statusOf(printer);
    expect(status.status, 'ERROR');
    expect(status.message, contains('Jaringan'));
  });

  test('service membangun ESC/POS dan teks biasa', () async {
    final adapter = _RecordingAdapter();
    final manager = PrinterManager(adapters: {'NETWORK': adapter});
    final store = PrinterStore(storage: MemoryPrinterStorage());
    final service = PrinterService(manager: manager, store: store);
    final document = const ReceiptDocument(text: 'Baris é', width: 32);

    final escpos = PrinterConfig(
      id: 'escpos',
      nama: 'ESC',
      host: '192.168.1.11',
      mode: 'ESCPOS',
    );
    final first = await service.printReceipt(document, printer: escpos);
    expect(first.ok, isTrue);
    expect(adapter.payload!.bytes.take(2).toList(), [0x1b, 0x40]);
    expect(
      adapter.payload!.bytes.sublist(adapter.payload!.bytes.length - 4),
      [0x1d, 0x56, 0x42, 0x00],
    );

    final plain = PrinterConfig(
      id: 'plain',
      nama: 'Teks',
      host: '192.168.1.12',
      mode: 'TEXT',
    );
    final second = await service.printReceipt(document, printer: plain);
    expect(second.ok, isTrue);
    expect(latin1.decode(adapter.payload!.bytes), startsWith('Baris é'));
  });

  test('tanpa printer utama hasil cetak memberi pesan jelas', () async {
    final manager = PrinterManager(adapters: {'NETWORK': _RecordingAdapter()});
    final service = PrinterService(
      manager: manager,
      store: PrinterStore(storage: MemoryPrinterStorage()),
    );
    final result = await service.printReceipt(
      const ReceiptDocument(text: 'x', width: 32),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('Belum ada printer'));
  });

  test('draft mengikuti jenis koneksi dan mode yang diizinkan', () {
    final bluetooth = PrinterConfig.draft(connectionType: 'BLUETOOTH');
    expect(bluetooth.transport, 'SPP');
    expect(bluetooth.mode, 'ESCPOS');
    final system = PrinterConfig.draft(connectionType: 'SYSTEM');
    expect(system.mode, 'SYSTEM');
    expect(system.port, isNull);

    expect(
      () => PrinterConfig(
        id: 'bt-ble',
        nama: 'BLE',
        connectionType: 'BLUETOOTH',
        transport: 'BLE',
        address: 'AA:BB:CC:DD:EE:FF',
        mode: 'SYSTEM',
      ).validate(),
      throwsArgumentError,
    );
  });

  test('identitas printer unik per transport dan maksimal 8', () async {
    final store = PrinterStore(storage: MemoryPrinterStorage());
    final spp = PrinterConfig(
      id: 'bt-spp',
      nama: 'SPP',
      connectionType: 'BLUETOOTH',
      address: 'AA:BB:CC:DD:EE:FF',
    );
    final ble = PrinterConfig(
      id: 'bt-ble',
      nama: 'BLE',
      connectionType: 'BLUETOOTH',
      transport: 'BLE',
      address: 'AA:BB:CC:DD:EE:FF',
    );
    await store.saveAll([spp, ble]);
    expect((await store.load()).length, 2);

    await expectLater(
      store.saveAll([
        spp,
        PrinterConfig(
          id: 'dupe',
          nama: 'Dupe',
          connectionType: 'BLUETOOTH',
          address: 'AA:BB:CC:DD:EE:FF',
        ),
      ]),
      throwsArgumentError,
    );

    final many = List.generate(
      maxPrinters + 1,
      (index) => PrinterConfig(
        id: 'p$index',
        nama: 'Printer $index',
        host: '192.168.1.${index + 1}',
      ),
    );
    await expectLater(store.saveAll(many), throwsArgumentError);
  });

  test('konfigurasi bertahan di storage dan status hidup tidak disimpan', () async {
    final storage = MemoryPrinterStorage();
    final store = PrinterStore(storage: storage);
    await store.saveAll([
      PrinterConfig(
        id: 'bt-1',
        nama: 'BT',
        connectionType: 'BLUETOOTH',
        address: '11:22:33:44:55:66',
        utama: true,
      ).copyWith(lastStatus: 'CONNECTING'),
    ]);
    final raw = jsonDecode((await storage.read())!) as Map<String, dynamic>;
    final saved = (raw['printers'] as List).first as Map<String, dynamic>;
    expect(saved['last_status'], 'SAVED');
    expect(saved['transport'], 'SPP');
    expect(raw['primary_id'], 'bt-1');
    final loaded = await PrinterStore(storage: storage).load();
    expect(loaded.single.lastStatus, 'SAVED');
  });
}
