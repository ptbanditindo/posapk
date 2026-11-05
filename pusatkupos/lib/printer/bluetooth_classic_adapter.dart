import 'printer_adapter.dart';
import 'printer_channel.dart';
import 'printer_config.dart';
import 'printer_device.dart';

class BluetoothClassicAdapter extends PrinterAdapter {
  BluetoothClassicAdapter({PrinterChannel? channel})
      : _channel = channel ?? PrinterChannel.instance;

  final PrinterChannel _channel;

  @override
  String get connectionType => 'BLUETOOTH';

  @override
  bool get supportsDiscovery => true;

  @override
  Future<List<PrinterDevice>> discover({
    String transport = 'SPP',
    String query = '',
  }) async {
    await _channel.requestPermissions(discovery: true);
    return _channel.scanBluetoothClassic();
  }

  @override
  Future<void> connect(PrinterConfig printer) async {
    await _channel.requestPermissions(discovery: false);
    await _channel.connectBluetoothClassic(printer.address);
  }

  @override
  Future<void> disconnect(PrinterConfig printer) =>
      _channel.disconnectBluetoothClassic();

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) =>
      _channel.sendBluetoothClassic(printer.address, payload.bytes);
}
