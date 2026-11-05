import 'dart:math' as math;

import '../core/money.dart';

enum ReceiptAlign {
  left,
  center,
  right;

  String get json => name;

  static ReceiptAlign parse(Object? value) => switch ('$value'.toLowerCase()) {
        'center' => ReceiptAlign.center,
        'right' => ReceiptAlign.right,
        _ => ReceiptAlign.left,
      };
}

class ReceiptLine {
  const ReceiptLine(
    this.text, {
    this.align = ReceiptAlign.left,
    this.bold = false,
    this.double = false,
  });

  final String text;
  final ReceiptAlign align;
  final bool bold;
  final bool double;
}

/// Menyusun baris struk dengan lebar tetap. Setiap baris sudah dibungkus dan
/// dirapikan, sehingga render teks, pratinjau, dan ESC/POS memakai hasil yang
/// sama.
class ReceiptBuilder {
  ReceiptBuilder(this.width);

  final int width;
  final List<ReceiptLine> _lines = <ReceiptLine>[];

  List<ReceiptLine> get lines => List<ReceiptLine>.unmodifiable(_lines);

  int _effectiveWidth(bool double) =>
      double ? math.max(1, width ~/ 2) : width;

  void add(
    String text, {
    ReceiptAlign align = ReceiptAlign.left,
    bool bold = false,
    bool double = false,
  }) {
    final effective = _effectiveWidth(double);
    final wrapped = wrapText(text, effective);
    if (wrapped.isEmpty) {
      _lines.add(ReceiptLine('', align: align, bold: bold, double: double));
      return;
    }
    for (final line in wrapped) {
      _lines.add(
        ReceiptLine(
          _align(line, effective, align),
          align: align,
          bold: bold,
          double: double,
        ),
      );
    }
  }

  void center(String text, {bool bold = false, bool double = false}) {
    add(text, align: ReceiptAlign.center, bold: bold, double: double);
  }

  void blank() => _lines.add(const ReceiptLine(''));

  void divider([String char = '-']) =>
      _lines.add(ReceiptLine(char * width));

  void field(String label, String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    final prefix = '$label: ';
    final available = math.max(8, width - prefix.length);
    final wrapped = wrapText(clean, available);
    _lines.add(ReceiptLine('$prefix${wrapped.first}'));
    for (final line in wrapped.skip(1)) {
      _lines.add(ReceiptLine('${' ' * prefix.length}$line'));
    }
  }

  void amount(String label, int cents, {bool bold = false}) {
    final value = formatRupiah(cents);
    final space = width - label.length - value.length;
    if (space >= 1) {
      _lines.add(
        ReceiptLine('$label${' ' * space}$value', bold: bold),
      );
    } else {
      _lines.add(ReceiptLine(label, bold: bold));
      _lines.add(ReceiptLine(value.padLeft(width), bold: bold));
    }
  }

  void item(String name, int qty, int priceCents, int subtotalCents) {
    for (final line in wrapText(name, math.max(1, width - 4))) {
      _lines.add(ReceiptLine('  $line'));
    }
    amount('  $qty x ${formatRupiah(priceCents)}', subtotalCents);
  }

  static String _align(String value, int width, ReceiptAlign align) {
    if (value.length >= width) return value;
    switch (align) {
      case ReceiptAlign.left:
        return value;
      case ReceiptAlign.center:
        return '${' ' * ((width - value.length) ~/ 2)}$value';
      case ReceiptAlign.right:
        return value.padLeft(width);
    }
  }
}

List<String> wrapText(String value, int width) {
  if (width < 1) return const [];
  final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return const [];
  final words = clean.split(' ');
  final lines = <String>[];
  var current = '';
  for (final word in words) {
    if (word.isEmpty) continue;
    if (current.isEmpty) {
      current = word;
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
      continue;
    }
    if (current.length + 1 + word.length <= width) {
      current = '$current $word';
    } else {
      lines.add(current);
      current = word;
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}
