import '../printer/receipt_builder.dart';

/// Field informasi nota yang dapat dinyalakan/dimatikan di blok `meta`.
const receiptMetaFields = <String, String>{
  'no_nota': 'Nomor nota',
  'tanggal': 'Tanggal',
  'kasir': 'Kasir',
  'mekanik': 'Mekanik',
  'pelanggan': 'Pelanggan',
  'hp': 'Nomor HP',
  'unit': 'Unit',
  'keluhan': 'Keluhan',
  'catatan': 'Catatan',
  'jatuh_tempo': 'Jatuh tempo',
};

/// Field total yang dapat dinyalakan/dimatikan di blok `totals`.
const receiptTotalFields = <String, String>{
  'total_jasa': 'Total jasa',
  'total_part': 'Total part',
  'diskon': 'Diskon',
  'koreksi': 'Koreksi nota',
  'retur': 'Retur',
  'dpp': 'DPP',
  'ppn': 'PPN',
  'grand_total': 'Grand total',
  'metode': 'Metode bayar',
  'bayar': 'Dibayar',
  'kembalian': 'Kembalian',
  'status_bayar': 'Status bayar',
};

const receiptBlockOrder = <String>[
  'header',
  'meta',
  'items',
  'totals',
  'payment',
  'warranty',
  'bank',
  'footer',
];

const receiptBlockNames = <String, String>{
  'header': 'Kepala toko',
  'meta': 'Informasi nota',
  'items': 'Rincian jasa dan part',
  'totals': 'Total pembayaran',
  'payment': 'Riwayat pembayaran',
  'warranty': 'Garansi',
  'bank': 'Rekening bank',
  'footer': 'Penutup',
};

const receiptDefaultLabels = <String, String>{
  'no_nota': 'No. Nota',
  'tanggal': 'Tanggal',
  'kasir': 'Kasir',
  'mekanik': 'Mekanik',
  'pelanggan': 'Pelanggan',
  'hp': 'HP',
  'unit': 'Unit',
  'keluhan': 'Keluhan',
  'catatan': 'Catatan',
  'jatuh_tempo': 'Jatuh tempo',
  'total_jasa': 'Total jasa',
  'total_part': 'Total part',
  'diskon': 'Diskon',
  'koreksi': 'Koreksi',
  'retur': 'Retur',
  'dpp': 'DPP',
  'ppn': 'PPN',
  'grand_total': 'GRAND TOTAL',
  'metode': 'Metode',
  'bayar': 'Dibayar',
  'kembalian': 'Kembalian',
  'status_bayar': 'Status',
  'sisa': 'Sisa',
  'rekening': 'REKENING',
  'garansi': 'Garansi',
  'pelunasan': 'STRUK PELUNASAN',
};

const receiptCodepages = <String, String>{
  '': 'Ikuti printer',
  'ASCII': 'ASCII',
  'CP437': 'CP437 (Epson)',
  'CP850': 'CP850 (Latin-1 multilingual)',
  'CP1252': 'CP1252 (Windows)',
};

class ReceiptTextLine {
  ReceiptTextLine(
    this.text, {
    this.align = ReceiptAlign.center,
    this.bold = false,
  });

  String text;
  ReceiptAlign align;
  bool bold;

  Map<String, Object?> toJson() => {
        'text': text,
        'align': align.json,
        'bold': bold,
      };

  factory ReceiptTextLine.fromJson(Map<String, Object?> json) {
    return ReceiptTextLine(
      '${json['text'] ?? ''}'.trim(),
      align: ReceiptAlign.parse(json['align']),
      bold: json['bold'] == true,
    );
  }
}

class ReceiptTemplate {
  ReceiptTemplate({
    this.paperWidth = 58,
    this.copies = 1,
    this.blankLines = 3,
    this.codepage = '',
    List<String>? blockOrder,
    Map<String, bool>? blockVisible,
    Map<String, bool>? metaFields,
    Map<String, bool>? totalFields,
    this.showJasa = true,
    this.showPart = true,
    this.itemsDivider = true,
    this.showLineDiscount = true,
    this.showTagline = true,
    this.showAlamat = true,
    this.showKontak = true,
    this.headerBold = true,
    this.headerDouble = true,
    List<ReceiptTextLine>? headerExtra,
    this.paymentShowHistory = true,
    this.paymentShowSisa = true,
    this.warrantyShowStatus = true,
    this.warrantyShowNote = true,
    this.warrantyNote = '',
    this.bankNama = '',
    this.noRekening = '',
    this.atasNama = '',
    this.bankCatatan = '',
    List<String>? footerLines,
    List<ReceiptTextLine>? footerExtra,
    Map<String, String>? labels,
    this.voidBanner = true,
    this.pelunasanBanner = true,
    this.logoPath = '',
    this.logoWidthMm = 20,
    this.signature = '',
  })  : blockOrder = _order(blockOrder),
        blockVisible = {...defaultBlockVisible, ...?blockVisible},
        metaFields = {...defaultMetaFields, ...?metaFields},
        totalFields = {...defaultTotalFields, ...?totalFields},
        headerExtra = headerExtra ?? <ReceiptTextLine>[],
        footerLines = footerLines ?? <String>['Terima kasih'],
        footerExtra = footerExtra ?? <ReceiptTextLine>[],
        labels = {...receiptDefaultLabels, ...?labels};

  int paperWidth;
  int copies;
  int blankLines;
  String codepage;
  List<String> blockOrder;
  Map<String, bool> blockVisible;
  Map<String, bool> metaFields;
  Map<String, bool> totalFields;
  bool showJasa;
  bool showPart;
  bool itemsDivider;
  bool showLineDiscount;
  bool showTagline;
  bool showAlamat;
  bool showKontak;
  bool headerBold;
  bool headerDouble;
  List<ReceiptTextLine> headerExtra;
  bool paymentShowHistory;
  bool paymentShowSisa;
  bool warrantyShowStatus;
  bool warrantyShowNote;
  String warrantyNote;
  String bankNama;
  String noRekening;
  String atasNama;
  String bankCatatan;
  List<String> footerLines;
  List<ReceiptTextLine> footerExtra;
  Map<String, String> labels;
  bool voidBanner;
  bool pelunasanBanner;
  String logoPath;
  int logoWidthMm;
  String signature;

  int get width => paperWidth == 80 ? 48 : 32;

  String label(String key) => labels[key] ?? receiptDefaultLabels[key] ?? key;

  bool visible(String block) => blockVisible[block] ?? true;

  factory ReceiptTemplate.defaults() => ReceiptTemplate();

  factory ReceiptTemplate.fromJson(Map<String, Object?> json) {
    final rawBlocks = json['blocks'];
    final order = <String>[];
    if (rawBlocks is List) {
      for (final item in rawBlocks) {
        final id = '$item';
        if (receiptBlockOrder.contains(id) && !order.contains(id)) {
          order.add(id);
        }
      }
    }
    for (final id in receiptBlockOrder) {
      if (!order.contains(id)) order.add(id);
    }
    final header = _map(json['header']);
    final items = _map(json['items']);
    final payment = _map(json['payment']);
    final warranty = _map(json['warranty']);
    final bank = _map(json['bank']);
    final footer = _map(json['footer']);
    final rawLabels = _map(json['labels']);
    return ReceiptTemplate(
      paperWidth: _int(json['paper_width'], 58),
      copies: _int(json['copies'], 1),
      blankLines: _int(json['blank_lines'], 3),
      codepage: _codepage(json['codepage']),
      blockOrder: order,
      blockVisible: _flags(json['block_visible'], defaultBlockVisible),
      metaFields: _flags(
        _map(json['meta'])['fields'] ?? json['meta'],
        defaultMetaFields,
      ),
      totalFields: _flags(
        _map(json['totals'])['fields'] ?? json['totals'],
        defaultTotalFields,
      ),
      showJasa: _bool(items['show_jasa'], true),
      showPart: _bool(items['show_part'], true),
      itemsDivider: _bool(items['divider'], true),
      showLineDiscount: _bool(items['show_line_discount'], true),
      showTagline: _bool(header['show_tagline'], true),
      showAlamat: _bool(header['show_alamat'], true),
      showKontak: _bool(header['show_kontak'], true),
      headerBold: _bool(header['bold'], true),
      headerDouble: _bool(header['double'], true),
      headerExtra: _lines(header['extra']),
      paymentShowHistory: _bool(payment['show_history'], true),
      paymentShowSisa: _bool(payment['show_sisa'], true),
      warrantyShowStatus: _bool(warranty['show_status'], true),
      warrantyShowNote: _bool(warranty['show_note'], true),
      warrantyNote: '${warranty['note'] ?? ''}'.trim(),
      bankNama: '${bank['nama'] ?? ''}'.trim(),
      noRekening: '${bank['nomor'] ?? ''}'.trim(),
      atasNama: '${bank['atas_nama'] ?? ''}'.trim(),
      bankCatatan: '${bank['catatan'] ?? ''}'.trim(),
      footerLines: _stringLines(footer['lines']),
      footerExtra: _lines(footer['extra']),
      labels: {
        for (final entry in rawLabels.entries)
          if (receiptDefaultLabels.containsKey(entry.key))
            entry.key: '${entry.value}'.trim(),
      },
      voidBanner: _bool(json['void_banner'], true),
      pelunasanBanner: _bool(json['pelunasan_banner'], true),
      logoPath: '${json['logo_path'] ?? ''}'.trim(),
      logoWidthMm: _int(json['logo_width_mm'], 20),
      signature: '${json['signature'] ?? ''}'.trim(),
    ).._sanitize();
  }

  Map<String, Object?> toJson() => {
        'version': 2,
        'paper_width': paperWidth,
        'copies': copies,
        'blank_lines': blankLines,
        'codepage': codepage,
        'blocks': blockOrder,
        'block_visible': blockVisible,
        'header': {
          'show_tagline': showTagline,
          'show_alamat': showAlamat,
          'show_kontak': showKontak,
          'bold': headerBold,
          'double': headerDouble,
          'extra': headerExtra.map((line) => line.toJson()).toList(),
        },
        'meta': metaFields,
        'items': {
          'show_jasa': showJasa,
          'show_part': showPart,
          'divider': itemsDivider,
          'show_line_discount': showLineDiscount,
        },
        'totals': totalFields,
        'payment': {
          'show_history': paymentShowHistory,
          'show_sisa': paymentShowSisa,
        },
        'warranty': {
          'show_status': warrantyShowStatus,
          'show_note': warrantyShowNote,
          'note': warrantyNote.trim(),
        },
        'bank': {
          'nama': bankNama.trim(),
          'nomor': noRekening.trim(),
          'atas_nama': atasNama.trim(),
          'catatan': bankCatatan.trim(),
        },
        'footer': {
          'lines':
              footerLines.map((line) => line.trim()).where((line) => line.isNotEmpty).toList(),
          'extra': footerExtra.map((line) => line.toJson()).toList(),
        },
        'labels': labels,
        'void_banner': voidBanner,
        'pelunasan_banner': pelunasanBanner,
        'logo_path': logoPath.trim(),
        'logo_width_mm': logoWidthMm,
        'signature': signature.trim(),
      };

  void validate() {
    if (paperWidth != 58 && paperWidth != 80) {
      throw ArgumentError('Lebar kertas struk harus 58 atau 80 mm.');
    }
    if (copies < 1 || copies > 3) {
      throw ArgumentError('Jumlah salinan struk harus 1 sampai 3.');
    }
    if (blankLines < 0 || blankLines > 5) {
      throw ArgumentError('Baris kosong sebelum potong harus 0 sampai 5.');
    }
    if (!receiptCodepages.containsKey(codepage)) {
      throw ArgumentError('Codepage struk tidak dikenal.');
    }
    if (logoWidthMm < 10 || logoWidthMm > 40) {
      throw ArgumentError('Lebar logo struk harus 10 sampai 40 mm.');
    }
    if (headerExtra.length > maxCustomLines) {
      throw ArgumentError(
        'Baris tambahan kepala struk maksimal $maxCustomLines.',
      );
    }
    if (footerExtra.length > maxCustomLines) {
      throw ArgumentError(
        'Baris tambahan penutup maksimal $maxCustomLines.',
      );
    }
    for (final line in [...headerExtra, ...footerExtra]) {
      if (line.text.length > maxCustomLineLength) {
        throw ArgumentError(
          'Satu baris tambahan maksimal $maxCustomLineLength karakter.',
        );
      }
    }
    if (labels.length != receiptDefaultLabels.length) {
      throw ArgumentError('Label struk tidak lengkap.');
    }
    for (final entry in labels.entries) {
      if (entry.value.trim().isEmpty) {
        throw ArgumentError('Label "${receiptDefaultLabels[entry.key]}" '
            'tidak boleh kosong.');
      }
      if (entry.value.trim().length > maxLabelLength) {
        throw ArgumentError(
          'Label "${receiptDefaultLabels[entry.key]}" maksimal '
          '$maxLabelLength karakter.',
        );
      }
    }
  }

  void _sanitize() {
    if (paperWidth != 58 && paperWidth != 80) paperWidth = 58;
    copies = copies.clamp(1, 3).toInt();
    blankLines = blankLines.clamp(0, 5).toInt();
    logoWidthMm = logoWidthMm.clamp(10, 40).toInt();
    headerExtra = headerExtra.take(maxCustomLines).map((line) {
      line.text = line.text.length > maxCustomLineLength
          ? line.text.substring(0, maxCustomLineLength)
          : line.text;
      return line;
    }).toList();
    footerExtra = footerExtra.take(maxCustomLines).map((line) {
      line.text = line.text.length > maxCustomLineLength
          ? line.text.substring(0, maxCustomLineLength)
          : line.text;
      return line;
    }).toList();
    labels = {
      for (final key in receiptDefaultLabels.keys)
        key: labels[key]!.trim().isEmpty
            ? receiptDefaultLabels[key]!
            : labels[key]!.trim().substring(
                  0,
                  labels[key]!.trim().length > maxLabelLength
                      ? maxLabelLength
                      : labels[key]!.trim().length,
                ),
    };
  }

  static const maxCustomLines = 5;
  static const maxCustomLineLength = 80;
  static const maxLabelLength = 20;
}

const defaultBlockVisible = <String, bool>{
  'header': true,
  'meta': true,
  'items': true,
  'totals': true,
  'payment': true,
  'warranty': true,
  'bank': true,
  'footer': true,
};

const defaultMetaFields = <String, bool>{
  'no_nota': true,
  'tanggal': true,
  'kasir': true,
  'mekanik': true,
  'pelanggan': true,
  'hp': true,
  'unit': true,
  'keluhan': true,
  'catatan': true,
  'jatuh_tempo': true,
};

const defaultTotalFields = <String, bool>{
  'total_jasa': true,
  'total_part': true,
  'diskon': true,
  'dpp': true,
  'ppn': true,
  'grand_total': true,
  'metode': true,
  'bayar': true,
  'kembalian': true,
  'status_bayar': true,
};

List<String> _order(List<String>? value) {
  final order = <String>[];
  for (final id in value ?? receiptBlockOrder) {
    if (receiptBlockOrder.contains(id) && !order.contains(id)) order.add(id);
  }
  for (final id in receiptBlockOrder) {
    if (!order.contains(id)) order.add(id);
  }
  return order;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  return const {};
}

int _int(Object? value, int fallback) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

bool _bool(Object? value, bool fallback) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  return '$value'.toLowerCase() == 'true' || '$value' == '1';
}

String _codepage(Object? value) {
  final clean = '${value ?? ''}'.trim().toUpperCase();
  return receiptCodepages.containsKey(clean) ? clean : '';
}

Map<String, bool> _flags(
  Object? raw,
  Map<String, bool> fallback,
) {
  final map = _map(raw);
  return {
    for (final key in fallback.keys)
      key: map.containsKey(key) ? _bool(map[key], fallback[key]!) : fallback[key]!,
  };
}

List<ReceiptTextLine> _lines(Object? raw) {
  if (raw is! List) return <ReceiptTextLine>[];
  final result = <ReceiptTextLine>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final line = ReceiptTextLine.fromJson(item.cast<String, Object?>());
    if (line.text.isEmpty) continue;
    result.add(line);
  }
  return result;
}

List<String> _stringLines(Object? raw) {
  if (raw is String) {
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }
  if (raw is! List) return <String>['Terima kasih'];
  final result = raw
      .map((item) => '$item'.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return result.isEmpty ? <String>[] : result;
}
