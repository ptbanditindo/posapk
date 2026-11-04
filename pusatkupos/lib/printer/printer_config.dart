import 'dart:convert';

import '../core/ids.dart';
import '../data/app_database.dart';

const printerModes = <String, String>{
  'ESCPOS': 'ESC/POS',
  'TEXT': 'Teks biasa',
};

const printerPapers = <int, String>{
  58: '58 mm (32 kolom)',
  80: '80 mm (48 kolom)',
};

class PrinterConfig {
  const PrinterConfig({
    required this.id,
    required this.nama,
    required this.host,
    this.port = 9100,
    this.paperMm = 58,
    this.mode = 'ESCPOS',
    this.utama = false,
  });

  final String id;
  final String nama;
  final String host;
  final int port;
  final int paperMm;
  final String mode;
  final bool utama;

  int get width => paperMm == 80 ? 48 : 32;

  PrinterConfig copyWith({
    String? nama,
    String? host,
    int? port,
    int? paperMm,
    String? mode,
    bool? utama,
  }) {
    return PrinterConfig(
      id: id,
      nama: nama ?? this.nama,
      host: host ?? this.host,
      port: port ?? this.port,
      paperMm: paperMm ?? this.paperMm,
      mode: mode ?? this.mode,
      utama: utama ?? this.utama,
    );
  }

  void validate() {
    if (nama.trim().isEmpty) {
      throw ArgumentError('Nama printer wajib diisi.');
    }
    if (host.trim().isEmpty) {
      throw ArgumentError('Alamat IP printer wajib diisi.');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError('Port printer harus 1-65535.');
    }
    if (!printerPapers.containsKey(paperMm)) {
      throw ArgumentError('Ukuran kertas hanya 58 atau 80 mm.');
    }
    if (!printerModes.containsKey(mode)) {
      throw ArgumentError('Mode printer tidak dikenal.');
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'nama': nama,
        'host': host,
        'port': port,
        'paper_mm': paperMm,
        'mode': mode,
        'utama': utama,
      };

  static PrinterConfig fromJson(Map<String, Object?> json) {
    return PrinterConfig(
      id: '${json['id'] ?? ''}',
      nama: '${json['nama'] ?? ''}',
      host: '${json['host'] ?? ''}',
      port: (json['port'] as num?)?.toInt() ?? 9100,
      paperMm: (json['paper_mm'] as num?)?.toInt() ?? 58,
      mode: '${json['mode'] ?? 'ESCPOS'}',
      utama: json['utama'] == true,
    );
  }

  static PrinterConfig draft({int paperMm = 58, String mode = 'ESCPOS'}) {
    return PrinterConfig(
      id: newSyncId(),
      nama: '',
      host: '',
      paperMm: paperMm,
      mode: mode,
    );
  }
}

/// Daftar printer disimpan sebagai JSON di app_settings agar ikut backup
/// tanpa tabel baru.
class PrinterStore {
  PrinterStore._();

  static final PrinterStore instance = PrinterStore._();

  static const _key = 'printer.daftar';

  Future<List<PrinterConfig>> load() async {
    final raw = await AppDatabase.instance.getSetting(_key);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => PrinterConfig.fromJson(item.cast<String, Object?>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAll(List<PrinterConfig> printers) async {
    final normalized = <PrinterConfig>[];
    var primarySeen = false;
    for (final printer in printers) {
      printer.validate();
      final primary = printer.utama && !primarySeen;
      if (primary) primarySeen = true;
      normalized.add(printer.copyWith(utama: primary));
    }
    await AppDatabase.instance.setSetting(
      _key,
      jsonEncode(normalized.map((item) => item.toJson()).toList()),
    );
  }

  Future<PrinterConfig?> primary() async {
    final printers = await load();
    for (final printer in printers) {
      if (printer.utama) return printer;
    }
    return printers.isEmpty ? null : printers.first;
  }
}
