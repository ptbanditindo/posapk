import 'dart:convert';

import '../data/receipt_service.dart';
import 'escpos_builder.dart';
import 'printer_adapter.dart';
import 'printer_config.dart';
import 'printer_manager.dart';

class PrintResult {
  const PrintResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class PrinterService {
  PrinterService({PrinterManager? manager, PrinterStore? store})
      : _manager = manager ?? PrinterManager.instance,
        _store = store ?? PrinterStore.instance;

  static final PrinterService instance = PrinterService();

  final PrinterManager _manager;
  final PrinterStore _store;

  Future<PrintResult> printReceipt(
    ReceiptDocument document, {
    PrinterConfig? printer,
  }) async {
    final target = printer ?? await _store.primary();
    if (target == null) {
      return const PrintResult(
        ok: false,
        message: 'Belum ada printer. Tambahkan printer di Pengaturan.',
      );
    }
    return _print(target, document.text, document.width);
  }

  Future<PrintResult> printText(
    String text, {
    required PrinterConfig printer,
  }) =>
      _print(printer, text, printer.width);

  Future<PrintResult> testPrint(PrinterConfig printer) {
    final text = [
      'PUSATKU POS',
      'Tes printer',
      List.filled(printer.width, '-').join(),
      'Printer: ${printer.nama}',
      'Jenis: ${printer.typeLabel}',
      'Tujuan: ${printer.targetLabel}',
      'Kertas: ${printer.paperMm} mm',
      '',
    ].join('\n');
    return _print(printer, text, printer.width);
  }

  Future<PrintResult> _print(
    PrinterConfig printer,
    String text,
    int width,
  ) async {
    try {
      final payload = _payload(printer, text, width);
      if ((printer.connectionType == 'BLUETOOTH' ||
              printer.connectionType == 'USB') &&
          _manager.statusOf(printer).status != 'CONNECTED') {
        await _manager.connect(printer);
      }
      await _manager.send(printer, payload);
      return PrintResult(
        ok: true,
        message: _successMessage(printer),
      );
    } on PrinterException catch (error) {
      return PrintResult(ok: false, message: error.message);
    } on UnsupportedError catch (error) {
      return PrintResult(ok: false, message: '$error');
    } catch (error) {
      return PrintResult(
        ok: false,
        message: 'Gagal mencetak ke ${printer.nama}. '
            'Periksa koneksi printer. Detail: $error',
      );
    }
  }

  PrintPayload _payload(PrinterConfig printer, String text, int width) {
    switch (printer.mode) {
      case 'ESCPOS':
        final builder = EscPosBuilder(
          width: width,
          encoding: printer.encoding,
        )
          ..init()
          ..text(text)
          ..feed(3)
          ..cut();
        return PrintPayload(
          text: text,
          bytes: builder.bytes,
          width: width,
          encoding: printer.encoding,
        );
      case 'TEXT':
        return PrintPayload(
          text: text,
          bytes: _plainBytes(text, printer.encoding),
          width: width,
          encoding: printer.encoding,
        );
      case 'SYSTEM':
      case 'BROWSER':
        return PrintPayload(
          text: text,
          bytes: const [],
          width: width,
          encoding: printer.encoding,
        );
      default:
        throw PrinterException(
          'Mode cetak ${printer.mode} tidak dikenal.',
          code: 'INVALID_MODE',
        );
    }
  }

  String _successMessage(PrinterConfig printer) {
    switch (printer.mode) {
      case 'SYSTEM':
        return 'Dialog cetak Android dibuka untuk ${printer.nama}.';
      case 'BROWSER':
        return 'Dialog cetak browser dibuka.';
      default:
        return 'Struk dikirim ke ${printer.nama}.';
    }
  }

  List<int> _plainBytes(String text, String encoding) {
    final asciiOnly = encoding.toUpperCase() == 'ASCII';
    final buffer = StringBuffer();
    for (final rune in '$text\n\n\n'.runes) {
      if (rune == 0x0a) {
        buffer.writeCharCode(rune);
      } else if (rune >= 0x20 && rune <= 0x7e) {
        buffer.writeCharCode(rune);
      } else if (!asciiOnly && rune >= 0xa0 && rune <= 0xff) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
      }
    }
    return latin1.encode('$buffer');
  }
}
