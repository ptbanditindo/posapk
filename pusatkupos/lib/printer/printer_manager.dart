import 'printer_adapter.dart';
import 'printer_config.dart';
import 'printer_device.dart';
import 'bluetooth_classic_adapter.dart';
import 'ble_printer_adapter.dart';
import 'network_printer_adapter.dart';
import 'system_print_adapter.dart';
import 'usb_printer_adapter.dart';
import 'web_printer_adapter.dart';

class PrinterRuntimeStatus {
  const PrinterRuntimeStatus(this.status, [this.message = '']);

  final String status;
  final String message;
}

/// Menentukan adapter transport dan menyimpan status koneksi selama aplikasi
/// berjalan. Status hidup (CONNECTED/CONNECTING) tidak pernah ditulis ke
/// konfigurasi agar tidak tersimpan sebagai klaim palsu saat aplikasi dibuka.
class PrinterManager {
  PrinterManager({
    Map<String, PrinterAdapter>? adapters,
    BlePrinterAdapter? ble,
    BluetoothClassicAdapter? classic,
  })  : _ble = ble ?? BlePrinterAdapter(),
        _classic = classic ?? BluetoothClassicAdapter(),
        _adapters = adapters ??
            {
              'NETWORK': NetworkPrinterAdapter(),
              'USB': UsbPrinterAdapter(),
              'SYSTEM': SystemPrintAdapter(),
              'WEB': WebPrinterAdapter(),
            };

  static final PrinterManager instance = PrinterManager();

  final Map<String, PrinterAdapter> _adapters;
  final BlePrinterAdapter _ble;
  final BluetoothClassicAdapter _classic;
  final Map<String, PrinterRuntimeStatus> _status = {};

  PrinterAdapter adapterFor(PrinterConfig printer) {
    if (printer.connectionType == 'BLUETOOTH') {
      return printer.transport == 'BLE' ? _ble : _classic;
    }
    final adapter = _adapters[printer.connectionType];
    if (adapter == null) {
      throw PrinterException(
        'Jenis koneksi printer ${printer.connectionType} belum didukung.',
        code: 'UNSUPPORTED',
      );
    }
    return adapter;
  }

  bool supportsDiscovery(String connectionType) =>
      connectionType == 'BLUETOOTH' ||
      (_adapters[connectionType]?.supportsDiscovery ?? false);

  PrinterRuntimeStatus statusOf(PrinterConfig printer) =>
      _status[printer.id] ?? PrinterRuntimeStatus(printer.persistedStatus);

  Future<List<PrinterDevice>> discover(
    String connectionType, {
    String transport = 'SPP',
  }) async {
    if (connectionType == 'BLUETOOTH') {
      return transport == 'BLE'
          ? _ble.discover()
          : _classic.discover(transport: 'SPP');
    }
    final adapter = _adapters[connectionType];
    if (adapter == null || !adapter.supportsDiscovery) return const [];
    return adapter.discover(transport: transport);
  }

  Future<void> connect(PrinterConfig printer) async {
    final adapter = adapterFor(printer);
    _status[printer.id] = const PrinterRuntimeStatus('CONNECTING');
    try {
      await adapter.connect(printer);
      _status[printer.id] = const PrinterRuntimeStatus('CONNECTED');
    } catch (error) {
      _status[printer.id] = PrinterRuntimeStatus(
        'ERROR',
        error is PrinterException ? error.message : '$error',
      );
      rethrow;
    }
  }

  Future<void> disconnect(PrinterConfig printer) async {
    try {
      await adapterFor(printer).disconnect(printer);
    } finally {
      _status[printer.id] = const PrinterRuntimeStatus('SAVED');
    }
  }

  Future<void> send(PrinterConfig printer, PrintPayload payload) async {
    final adapter = adapterFor(printer);
    try {
      await adapter.send(printer, payload);
      if (!printer.isLiveStatus) {
        _status[printer.id] = const PrinterRuntimeStatus('CONNECTED');
      }
    } catch (error) {
      _status[printer.id] = PrinterRuntimeStatus(
        'ERROR',
        error is PrinterException ? error.message : '$error',
      );
      rethrow;
    }
  }

  void markStatus(String printerId, String status, [String message = '']) {
    _status[printerId] = PrinterRuntimeStatus(status, message);
  }

  void forget(String printerId) {
    _status.remove(printerId);
  }
}
