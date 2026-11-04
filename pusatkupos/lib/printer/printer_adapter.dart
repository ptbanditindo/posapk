import 'printer_config.dart';
import 'printer_device.dart';

class PrinterException implements Exception {
  PrinterException(this.message, {this.code = 'PRINTER_ERROR'});

  final String code;
  final String message;

  @override
  String toString() => message;
}

class PrintPayload {
  const PrintPayload({
    required this.text,
    required this.bytes,
    required this.width,
    required this.encoding,
  });

  /// Struk teks siap kirim ke cetak sistem/browser.
  final String text;

  /// Byte ESC/POS untuk printer thermal.
  final List<int> bytes;
  final int width;
  final String encoding;
}

abstract class PrinterAdapter {
  String get connectionType;

  bool get supportsDiscovery => false;

  Future<List<PrinterDevice>> discover({
    String transport = '',
    String query = '',
  }) async =>
      const [];

  Future<void> connect(PrinterConfig printer) async {}

  Future<void> disconnect(PrinterConfig printer) async {}

  Future<void> send(PrinterConfig printer, PrintPayload payload);
}
