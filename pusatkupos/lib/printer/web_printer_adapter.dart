import 'browser_print.dart';
import 'printer_adapter.dart';
import 'printer_config.dart';

class WebPrinterAdapter extends PrinterAdapter {
  @override
  String get connectionType => 'WEB';

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) =>
      printInBrowser(payload.text);
}
