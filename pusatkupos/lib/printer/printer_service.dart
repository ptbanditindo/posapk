import 'dart:convert';

import '../data/receipt_service.dart';
import 'escpos_builder.dart';
import 'printer_config.dart';
import 'printer_transport_stub.dart'
    if (dart.library.io) 'printer_transport_io.dart';

class PrintResult {
  const PrintResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class PrinterService {
  PrinterService._();

  static final PrinterService instance = PrinterService._();

  Future<PrintResult> printReceipt(
    ReceiptDocument document, {
    PrinterConfig? printer,
  }) async {
    final target = printer ?? await PrinterStore.instance.primary();
    if (target == null) {
      return const PrintResult(
        ok: false,
        message: 'Belum ada printer. Tambahkan printer di Pengaturan.',
      );
    }
    return printText(document.text, printer: target);
  }

  Future<PrintResult> printText(
    String text, {
    required PrinterConfig printer,
  }) async {
    try {
      printer.validate();
      final bytes = printer.mode == 'TEXT'
          ? _plainBytes(text)
          : _escposBytes(text, printer.width);
      await sendNetwork(printer.host, printer.port, bytes);
      return PrintResult(ok: true, message: 'Struk dikirim ke ${printer.nama}.');
    } on UnsupportedError catch (error) {
      return PrintResult(ok: false, message: '$error');
    } on FormatException {
      return const PrintResult(
        ok: false,
        message: 'Alamat printer tidak valid.',
      );
    } catch (error) {
      return PrintResult(
        ok: false,
        message: 'Gagal mencetak ke ${printer.nama} '
            '(${printer.host}:${printer.port}). Periksa jaringan printer. '
            'Detail: $error',
      );
    }
  }

  Future<PrintResult> testPrint(PrinterConfig printer) {
    final text = [
      'PUSATKU POS',
      'Tes printer',
      List.filled(printer.width, '-').join(),
      'Printer: ${printer.nama}',
      'Alamat: ${printer.host}:${printer.port}',
      'Kertas: ${printer.paperMm} mm',
      '',
    ].join('\n');
    return printText(text, printer: printer);
  }

  List<int> _escposBytes(String text, int width) {
    final builder = EscPosBuilder(width: width)
      ..init()
      ..text(text)
      ..feed(3)
      ..cut();
    return builder.bytes;
  }

  List<int> _plainBytes(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      buffer.writeCharCode(
        rune == 0x0a || (rune >= 0x20 && rune <= 0x7e) ? rune : 0x3f,
      );
    }
    return latin1.encode('$buffer\n\n\n');
  }
}
