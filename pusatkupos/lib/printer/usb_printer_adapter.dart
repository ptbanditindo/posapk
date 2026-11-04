import 'printer_adapter.dart';
import 'printer_channel.dart';
import 'printer_config.dart';
import 'printer_device.dart';

class UsbPrinterAdapter extends PrinterAdapter {
  UsbPrinterAdapter({PrinterChannel? channel})
      : _channel = channel ?? PrinterChannel.instance;

  final PrinterChannel _channel;

  @override
  String get connectionType => 'USB';

  @override
  bool get supportsDiscovery => true;

  @override
  Future<List<PrinterDevice>> discover({
    String transport = '',
    String query = '',
  }) =>
      _channel.scanUsb();

  @override
  Future<void> connect(PrinterConfig printer) =>
      _channel.connectUsb(printer.address);

  @override
  Future<void> disconnect(PrinterConfig printer) => _channel.disconnectUsb();

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) =>
      _channel.sendUsb(printer.address, payload.bytes);
}
