import 'dart:convert';

import '../core/ids.dart';
import '../data/app_database.dart';
import 'printer_storage.dart';
import 'printer_storage_stub.dart'
    if (dart.library.io) 'printer_storage_io.dart'
    if (dart.library.html) 'printer_storage_web.dart';

const printerTypes = <String, String>{
  'BLUETOOTH': 'Bluetooth',
  'NETWORK': 'Wi-Fi / LAN',
  'USB': 'USB OTG',
  'SYSTEM': 'Cetak Android',
  'WEB': 'Cetak browser',
};

const printerModes = <String, String>{
  'ESCPOS': 'ESC/POS',
  'TEXT': 'Teks biasa',
  'SYSTEM': 'Cetak sistem',
  'BROWSER': 'Dialog browser',
};

const printerAllowedModes = <String, Set<String>>{
  'BLUETOOTH': {'ESCPOS', 'TEXT'},
  'NETWORK': {'ESCPOS', 'TEXT'},
  'USB': {'ESCPOS', 'TEXT'},
  'SYSTEM': {'SYSTEM', 'TEXT'},
  'WEB': {'BROWSER', 'SYSTEM', 'TEXT'},
};

const printerDefaultModes = <String, String>{
  'BLUETOOTH': 'ESCPOS',
  'NETWORK': 'ESCPOS',
  'USB': 'ESCPOS',
  'SYSTEM': 'SYSTEM',
  'WEB': 'BROWSER',
};

const printerPapers = <int, String>{
  58: '58 mm (32 kolom)',
  80: '80 mm (48 kolom)',
};

const printerStatuses = <String>{
  'SAVED',
  'CONNECTED',
  'CONNECTING',
  'UNAVAILABLE',
  'ERROR',
};

const printerEncodings = <String, String>{
  'LATIN1': 'Latin-1',
  'CP437': 'CP437 (Epson)',
  'CP850': 'CP850 (Latin-1 multilingual)',
  'CP1252': 'CP1252 (Windows)',
  'ASCII': 'ASCII',
};

const bluetoothTransports = <String, String>{
  'SPP': 'Bluetooth Classic (SPP)',
  'BLE': 'Bluetooth LE (GATT)',
};

const maxPrinters = 8;

final _idPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _bluetoothPattern = RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');
final _encodingPattern = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
final _ipPattern = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

class PrinterConfig {
  PrinterConfig({
    required this.id,
    required this.nama,
    this.connectionType = 'NETWORK',
    this.address = '',
    String ip = '',
    String? host,
    this.port = 9100,
    this.paperMm = 58,
    this.mode = 'ESCPOS',
    this.encoding = 'LATIN1',
    String transport = '',
    this.utama = false,
    this.lastStatus = 'SAVED',
    this.lastConnectedAt,
    this.lastError,
  })  : ip = ip.isNotEmpty ? ip : (host ?? ''),
        transport = _normalizeTransport(
          connectionType.toUpperCase(),
          transport.isEmpty ? null : transport,
        );

  final String id;
  final String nama;
  final String connectionType;
  final String address;
  final String ip;
  final int? port;
  final int paperMm;
  final String mode;
  final String encoding;
  final String transport;
  final bool utama;
  final String lastStatus;
  final String? lastConnectedAt;
  final String? lastError;

  /// Kompatibilitas dengan konfigurasi jaringan lama.
  String get host => ip;

  int get width => paperMm == 80 ? 48 : 32;

  String get typeLabel => printerTypes[connectionType] ?? connectionType;

  String get targetLabel {
    switch (connectionType) {
      case 'NETWORK':
        return port == null ? ip : '$ip:$port';
      case 'BLUETOOTH':
      case 'USB':
        return address;
      default:
        return typeLabel;
    }
  }

  String get identity {
    switch (connectionType) {
      case 'BLUETOOTH':
        return 'BLUETOOTH:$transport:${address.toUpperCase()}';
      case 'USB':
        return 'USB:${address.toUpperCase()}';
      case 'NETWORK':
        return 'NETWORK:$ip:$port';
      default:
        return '$connectionType:$id';
    }
  }

  bool get isLiveStatus =>
      lastStatus == 'CONNECTED' || lastStatus == 'CONNECTING';

  String get persistedStatus => isLiveStatus ? 'SAVED' : lastStatus;

  PrinterConfig copyWith({
    String? nama,
    String? connectionType,
    String? address,
    String? ip,
    Object? port = _unset,
    int? paperMm,
    String? mode,
    String? encoding,
    String? transport,
    bool? utama,
    String? lastStatus,
    Object? lastConnectedAt = _unset,
    Object? lastError = _unset,
  }) {
    return PrinterConfig(
      id: id,
      nama: nama ?? this.nama,
      connectionType: connectionType ?? this.connectionType,
      address: address ?? this.address,
      ip: ip ?? this.ip,
      port: identical(port, _unset) ? this.port : port as int?,
      paperMm: paperMm ?? this.paperMm,
      mode: mode ?? this.mode,
      encoding: encoding ?? this.encoding,
      transport: transport ?? this.transport,
      utama: utama ?? this.utama,
      lastStatus: lastStatus ?? this.lastStatus,
      lastConnectedAt: identical(lastConnectedAt, _unset)
          ? this.lastConnectedAt
          : lastConnectedAt as String?,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
    );
  }

  void validate() {
    if (!_idPattern.hasMatch(id)) {
      throw ArgumentError(
        'ID printer hanya boleh berisi huruf, angka, titik, garis bawah, '
        'atau tanda hubung (maksimal 64 karakter).',
      );
    }
    final cleanName = nama.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('Isi nama printer, misalnya Printer Kasir.');
    }
    if (cleanName.length > 80) {
      throw ArgumentError('Nama printer maksimal 80 karakter.');
    }
    if (!printerTypes.containsKey(connectionType)) {
      throw ArgumentError(
        'Jenis koneksi printer harus BLUETOOTH, NETWORK, USB, SYSTEM, atau WEB.',
      );
    }
    if (!printerPapers.containsKey(paperMm)) {
      throw ArgumentError('Lebar kertas printer harus 58 mm atau 80 mm.');
    }
    final allowed = printerAllowedModes[connectionType]!;
    final cleanMode = mode.trim().toUpperCase();
    if (!allowed.contains(cleanMode)) {
      throw ArgumentError(
        'Mode cetak ini tidak cocok dengan jenis koneksi printer. Pilih mode '
        'lain.',
      );
    }
    if (!_encodingPattern.hasMatch(encoding.trim())) {
      throw ArgumentError('Encoding printer tidak valid.');
    }
    if (!printerStatuses.contains(persistedStatus)) {
      throw ArgumentError('Status printer tidak dikenal.');
    }
    switch (connectionType) {
      case 'BLUETOOTH':
        if (!bluetoothTransports.containsKey(transport)) {
          throw ArgumentError(
            'Jenis Bluetooth printer harus SPP (Classic) atau BLE.',
          );
        }
        if (address.trim().isEmpty) {
          throw ArgumentError(
            'Isi alamat Bluetooth printer, misalnya AA:BB:CC:DD:EE:FF. Tekan '
            'Cari printer untuk memilih dari daftar.',
          );
        }
        if (!_bluetoothPattern.hasMatch(address.trim())) {
          throw ArgumentError(
            'Format alamat Bluetooth belum benar. Contoh: AA:BB:CC:DD:EE:FF.',
          );
        }
        break;
      case 'NETWORK':
        if (!_validIp(ip.trim())) {
          throw ArgumentError(
            'Alamat IP belum benar. Contoh: 192.168.1.9. Cek alamat printer '
            'di menu jaringan printer.',
          );
        }
        final value = port;
        if (value == null || value < 1 || value > 65535) {
          throw ArgumentError(
            'Port printer harus angka 1 sampai 65535. Port yang umum dipakai '
            'adalah 9100.',
          );
        }
        break;
      case 'USB':
        if (address.trim().isEmpty) {
          throw ArgumentError(
            'Isi identitas perangkat USB, misalnya usb:0416:5011. Tekan Cari '
            'printer untuk memilih dari daftar.',
          );
        }
        break;
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'nama': nama.trim(),
        'connection_type': connectionType,
        'address': address.trim(),
        'ip': ip.trim(),
        'port': port,
        'paper_mm': paperMm,
        'mode': mode,
        'encoding': encoding,
        'transport': transport,
        'last_status': persistedStatus,
        'last_connected_at': lastConnectedAt,
        'last_error': lastError,
      };

  static PrinterConfig fromJson(Map<String, Object?> json) {
    final type = '${json['connection_type'] ?? 'NETWORK'}'.toUpperCase();
    final rawStatus = '${json['last_status'] ?? 'SAVED'}'.toUpperCase();
    return PrinterConfig(
      id: '${json['id'] ?? ''}',
      nama: '${json['nama'] ?? json['name'] ?? ''}',
      connectionType: type,
      address: '${json['address'] ?? ''}',
      ip: '${json['ip'] ?? json['host'] ?? ''}',
      port: (json['port'] as num?)?.toInt() ?? (type == 'NETWORK' ? 9100 : null),
      paperMm: (json['paper_mm'] as num?)?.toInt() ?? 58,
      mode: '${json['mode'] ?? printerDefaultModes[type] ?? 'ESCPOS'}',
      encoding: '${json['encoding'] ?? 'LATIN1'}',
      transport: _normalizeTransport(type, json['transport']),
      utama: json['utama'] == true,
      lastStatus: rawStatus == 'CONNECTED' || rawStatus == 'CONNECTING'
          ? 'SAVED'
          : rawStatus,
      lastConnectedAt: json['last_connected_at'] as String?,
      lastError: json['last_error'] as String?,
    );
  }

  static PrinterConfig draft({
    String connectionType = 'NETWORK',
    int paperMm = 58,
  }) {
    final type = printerTypes.containsKey(connectionType)
        ? connectionType
        : 'NETWORK';
    return PrinterConfig(
      id: newSyncId().toLowerCase(),
      nama: '',
      connectionType: type,
      port: type == 'NETWORK' ? 9100 : null,
      paperMm: paperMm,
      mode: printerDefaultModes[type] ?? 'ESCPOS',
      transport: type == 'BLUETOOTH' ? 'SPP' : '',
    );
  }
}

const _unset = Object();

String _normalizeTransport(String type, Object? value) {
  if (type != 'BLUETOOTH') return '';
  final raw = '${value ?? 'SPP'}'.toUpperCase();
  return bluetoothTransports.containsKey(raw) ? raw : 'SPP';
}

bool _validIp(String value) {  final match = _ipPattern.firstMatch(value);
  if (match == null) return false;
  for (var i = 1; i <= 4; i++) {
    final octet = int.tryParse(match.group(i)!);
    if (octet == null || octet < 0 || octet > 255) return false;
  }
  return true;
}

class PrinterStore {
  PrinterStore({PrinterStorage? storage})
      : _storage = storage ?? createPrinterStorage();

  static final PrinterStore instance = PrinterStore();

  final PrinterStorage _storage;

  Future<List<PrinterConfig>> load() async {
    final raw = await _storage.read();
    if (raw == null || raw.trim().isEmpty) {
      final legacy = await _loadLegacy();
      if (legacy.isNotEmpty) {
        await _write(legacy, _firstPrimary(legacy));
      }
      return legacy;
    }
    final parsed = _decode(raw);
    if (parsed != null) return parsed;
    final backup = await _storage.readBackup();
    if (backup != null && backup.trim().isNotEmpty) {
      final restored = _decode(backup);
      if (restored != null) {
        try {
          await _storage.write(backup);
        } catch (_) {
          // Pemulihan tetap dipakai walau penulisan ulang gagal.
        }
        return restored;
      }
    }
    return const [];
  }

  List<PrinterConfig>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return _normalize(
          decoded
              .whereType<Map>()
              .map((item) => PrinterConfig.fromJson(
                    item.cast<String, Object?>(),
                  ))
              .toList(),
          null,
        );
      }
      if (decoded is! Map) return null;
      final primaryId = decoded['primary_id'] as String?;
      final printers = decoded['printers'];
      if (printers is! List) return null;
      return _normalize(
        printers
            .whereType<Map>()
            .map((item) => PrinterConfig.fromJson(item.cast<String, Object?>()))
            .toList(),
        primaryId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAll(List<PrinterConfig> printers) async {
    if (printers.length > maxPrinters) {
      throw ArgumentError('Maksimal $maxPrinters printer dapat disimpan.');
    }
    final ids = <String>{};
    final identities = <String>{};
    var primarySeen = false;
    final normalized = <PrinterConfig>[];
    for (final printer in printers) {
      printer.validate();
      final clean = printer.copyWith(
        connectionType: printer.connectionType.toUpperCase(),
        mode: printer.mode.toUpperCase(),
        encoding: printer.encoding.toUpperCase(),
        transport: printer.transport.toUpperCase(),
        utama: printer.utama && !primarySeen,
        lastStatus: printer.persistedStatus,
      );
      if (!ids.add(clean.id)) {
        throw ArgumentError('ID printer duplikat: ${clean.id}.');
      }
      if (!identities.add(clean.identity)) {
        throw ArgumentError(
          'Printer yang sama sudah tercatat. Ubah printer yang ada, jangan '
          'menambah dua kali.',
        );
      }
      if (clean.utama) primarySeen = true;
      normalized.add(clean);
    }
    await _write(normalized, _firstPrimary(normalized));
  }

  Future<PrinterConfig?> primary() async {
    final printers = await load();
    if (printers.isEmpty) return null;
    for (final printer in printers) {
      if (printer.utama) return printer;
    }
    return printers.first;
  }

  Future<List<PrinterConfig>> _loadLegacy() async {
    try {
      final raw = await AppDatabase.instance.getSetting('printer.daftar');
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final converted = <PrinterConfig>[];
      for (final item in decoded.whereType<Map>()) {
        final map = item.cast<String, Object?>();
        converted.add(
          PrinterConfig(
            id: '${map['id'] ?? newSyncId().toLowerCase()}',
            nama: '${map['nama'] ?? 'Printer'}',
            connectionType: 'NETWORK',
            ip: '${map['host'] ?? ''}',
            port: (map['port'] as num?)?.toInt() ?? 9100,
            paperMm: (map['paper_mm'] as num?)?.toInt() ?? 58,
            mode: '${map['mode'] ?? 'ESCPOS'}',
            utama: map['utama'] == true,
          ),
        );
      }
      return converted;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(
    List<PrinterConfig> printers,
    String? primaryId,
  ) async {
    final payload = {
      'version': 1,
      'printers': printers.map((item) => item.toJson()).toList(),
      'primary_id': primaryId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _storage.write(jsonEncode(payload));
  }

  List<PrinterConfig> _normalize(
    List<PrinterConfig> printers,
    String? primaryId,
  ) {
    var primary = primaryId;
    if (primary == null) {
      for (final item in printers) {
        if (item.utama) {
          primary = item.id;
          break;
        }
      }
    }
    return printers
        .map(
          (item) => item.copyWith(
            utama: item.id == primary,
            lastStatus: item.persistedStatus,
          ),
        )
        .toList();
  }

  String? _firstPrimary(List<PrinterConfig> printers) {
    for (final printer in printers) {
      if (printer.utama) return printer.id;
    }
    return printers.isEmpty ? null : printers.first.id;
  }
}
