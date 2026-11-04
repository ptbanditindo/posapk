import 'printer_adapter.dart';
import 'printer_channel.dart';
import 'printer_config.dart';
import 'printer_device.dart';
import 'printer_transport_stub.dart'
    if (dart.library.io) 'printer_transport_io.dart';

class NetworkPrinterAdapter extends PrinterAdapter {
  NetworkPrinterAdapter({PrinterChannel? channel})
      : _channel = channel ?? PrinterChannel.instance;

  final PrinterChannel _channel;

  @override
  String get connectionType => 'NETWORK';

  @override
  bool get supportsDiscovery => true;

  @override
  Future<List<PrinterDevice>> discover({
    String transport = '',
    String query = '',
  }) =>
      _channel.scanNetwork();

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) =>
      sendNetwork(printer.ip, printer.port ?? 9100, payload.bytes);
}
