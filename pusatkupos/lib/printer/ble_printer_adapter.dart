import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'printer_adapter.dart';
import 'printer_channel.dart';
import 'printer_config.dart';
import 'printer_device.dart';

/// Printer Bluetooth Low Energy (GATT). Banyak printer thermal BLE memakai
/// layanan vendor FFE0/FF00/FF10/FF20/18F0 dengan karakteristik tulis.
class BlePrinterAdapter extends PrinterAdapter {
  BlePrinterAdapter({PrinterChannel? channel})
      : _channel = channel ?? PrinterChannel.instance;

  static const _preferredServices = <int>{
    0xffe0,
    0xff00,
    0xff10,
    0xff20,
    0x18f0,
  };

  final PrinterChannel _channel;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;

  @override
  String get connectionType => 'BLUETOOTH';

  @override
  bool get supportsDiscovery => true;

  @override
  Future<List<PrinterDevice>> discover({
    String transport = 'BLE',
    String query = '',
  }) async {
    await _ensurePermissions(discovery: true);
    if (!await FlutterBluePlus.isSupported) {
      throw PrinterException(
        'Bluetooth LE tidak tersedia di perangkat ini.',
        code: 'UNSUPPORTED',
      );
    }
    final results = <String, PrinterDevice>{};
    late final StreamSubscription<List<ScanResult>> subscription;
    try {
      subscription = FlutterBluePlus.scanResults.listen((items) {
        for (final item in items) {
          final address = item.device.remoteId.str;
          if (address.isEmpty) continue;
          final name = _nameOf(item);
          if (name.isEmpty) continue;
          results[address] = PrinterDevice(
            connectionType: 'BLUETOOTH',
            name: name,
            address: address,
            transport: 'BLE',
            detail: 'BLE',
          );
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((value) => value == false).first;
    } on FlutterBluePlusException catch (error) {
      final detail = error.description?.trim() ?? '';
      throw PrinterException(
        detail.isEmpty ? 'Pemindaian Bluetooth LE gagal.' : detail,
        code: 'BLE_SCAN',
      );
    } finally {
      await FlutterBluePlus.stopScan();
    }
    await subscription.cancel();
    final devices = results.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return devices;
  }

  @override
  Future<void> connect(PrinterConfig printer) async {
    await _ensurePermissions(discovery: false);
    final device = BluetoothDevice.fromId(printer.address);
    if (_device?.remoteId.str == device.remoteId.str &&
        _characteristic != null) {
      return;
    }
    await disconnect(printer);
    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
    } on FlutterBluePlusException catch (error) {
      final detail = error.description?.trim() ?? '';
      throw PrinterException(
        detail.isEmpty ? 'Gagal terhubung ke printer BLE.' : detail,
        code: 'BLE_CONNECT',
      );
    }
    final services = await device.discoverServices();
    final characteristic = _writable(services);
    if (characteristic == null) {
      await device.disconnect().catchError((_) {});
      throw PrinterException(
        'Printer BLE ini tidak menyediakan karakteristik tulis. '
        'Coba koneksi Bluetooth Classic (SPP).',
        code: 'BLE_NO_WRITE',
      );
    }
    _device = device;
    _characteristic = characteristic;
  }

  @override
  Future<void> disconnect(PrinterConfig printer) async {
    _characteristic = null;
    final device = _device;
    _device = null;
    if (device != null) {
      await device.disconnect().catchError((_) {});
    }
  }

  @override
  Future<void> send(PrinterConfig printer, PrintPayload payload) async {
    final connected = _device?.remoteId.str;
    final characteristic = _characteristic;
    if (connected != printer.address || characteristic == null) {
      await connect(printer);
    }
    final target = _characteristic;
    if (target == null) {
      throw PrinterException(
        'Printer BLE belum terhubung. Hubungkan lalu coba lagi.',
        code: 'BLE_DISCONNECTED',
      );
    }
    final withoutResponse = target.properties.writeWithoutResponse;
    const chunkSize = 180;
    for (var offset = 0; offset < payload.bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, payload.bytes.length);
      final chunk = payload.bytes.sublist(offset, end);
      try {
        await target.write(chunk, withoutResponse: withoutResponse);
      } on FlutterBluePlusException {
        if (!withoutResponse) rethrow;
        await target.write(chunk, withoutResponse: false);
      }
      if (end < payload.bytes.length) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  Future<void> _ensurePermissions({required bool discovery}) async {
    try {
      await _channel.requestPermissions(discovery: discovery);
    } on PrinterException catch (error) {
      if (error.code != 'UNSUPPORTED') rethrow;
    }
  }

  BluetoothCharacteristic? _writable(List<BluetoothService> services) {
    BluetoothCharacteristic? fallback;
    for (final service in services) {
      final preferred = _isPreferred(service.uuid);
      for (final characteristic in service.characteristics) {
        final props = characteristic.properties;
        if (!props.write && !props.writeWithoutResponse) continue;
        if (preferred) return characteristic;
        fallback ??= characteristic;
      }
    }
    return fallback;
  }

  bool _isPreferred(Guid uuid) {
    final value = uuid.toString().toLowerCase();
    for (final id in _preferredServices) {
      final hex = id.toRadixString(16).padLeft(4, '0');
      if (value.contains('-$hex-') || value.startsWith('0000$hex')) {
        return true;
      }
    }
    return false;
  }

  String _nameOf(ScanResult item) {
    final platform = item.device.platformName.trim();
    if (platform.isNotEmpty) return platform;
    final advertised = item.advertisementData.advName.trim();
    if (advertised.isNotEmpty) return advertised;
    return '';
  }
}
