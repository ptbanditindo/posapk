import 'package:flutter/services.dart';

import 'printer_adapter.dart';
import 'printer_device.dart';

/// Jembatan MethodChannel ke transport native Android (SPP, USB, cetak sistem,
/// dan NSD). BLE memakai flutter_blue_plus, bukan channel ini.
class PrinterChannel {
  PrinterChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'pusatkupos/printer';

  static final PrinterChannel instance = PrinterChannel();

  final MethodChannel _channel;

  Future<void> requestPermissions({required bool discovery}) =>
      _invoke('requestPermissions', {'discovery': discovery});

  Future<List<PrinterDevice>> scanBluetoothClassic() async {
    final result = await _invoke('scanBluetoothClassic');
    return _devices(result, 'BLUETOOTH', transport: 'SPP');
  }

  Future<Map<String, Object?>> connectBluetoothClassic(String address) async {
    final result = await _invoke('connectBluetoothClassic', {'address': address});
    return _map(result);
  }

  Future<void> sendBluetoothClassic(List<int> bytes) =>
      _invoke('sendBluetoothClassic', {'bytes': Uint8List.fromList(bytes)});

  Future<void> disconnectBluetoothClassic() =>
      _invoke('disconnectBluetoothClassic');

  Future<List<PrinterDevice>> scanUsb() async {
    final result = await _invoke('scanUsb');
    return _devices(result, 'USB');
  }

  Future<void> connectUsb(String identity) =>
      _invoke('connectUsb', {'identity': identity});

  Future<void> sendUsb(String identity, List<int> bytes) => _invoke(
        'sendUsb',
        {'identity': identity, 'bytes': Uint8List.fromList(bytes)},
      );

  Future<void> disconnectUsb() => _invoke('disconnectUsb');

  Future<List<PrinterDevice>> scanNetwork() async {
    final result = await _invoke('scanNetwork');
    return _devices(result, 'NETWORK', transport: 'TCP');
  }

  Future<Map<String, Object?>> printSystem({
    required String title,
    required String text,
    required int paperMm,
  }) async {
    final result = await _invoke('printSystem', {
      'title': title,
      'text': text,
      'paperMm': paperMm,
    });
    return _map(result);
  }

  Future<Map<String, Object?>> status() async => _map(await _invoke('status'));

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw PrinterException(
        'Fitur printer ini hanya tersedia di aplikasi Android.',
        code: 'UNSUPPORTED',
      );
    } on PlatformException catch (error) {
      throw PrinterException(
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'Perintah printer gagal dijalankan.',
        code: error.code,
      );
    }
  }

  List<PrinterDevice> _devices(
    Object? result,
    String connectionType, {
    String transport = '',
  }) {
    final map = _map(result);
    final list = map['devices'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map(
          (item) => PrinterDevice.fromMap(
            connectionType,
            item.cast<Object?, Object?>(),
            transport: transport,
          ),
        )
        .where((device) => device.address.isNotEmpty)
        .toList();
  }

  Map<String, Object?> _map(Object? value) {
    if (value is Map) return value.cast<String, Object?>();
    return const {};
  }
}
