import 'printer_adapter.dart';
import 'printer_channel.dart';
import 'printer_config.dart';

class SystemPrintAdapter extends PrinterAdapter {
  SystemPrintAdapter({PrinterChannel? channel})
      : _channel = channel ?? PrinterChannel.instance;

  final PrinterChannel _channel;

  @override
  String get connectionType => 'SYSTEM';

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) async {
    await _channel.printSystem(
      title: 'Struk ${printer.nama}'.trim(),
      text: payload.text,
      paperMm: printer.paperMm,
    );
  }
}
