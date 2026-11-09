import 'package:intl/intl.dart';

final NumberFormat _rupiahWhole = NumberFormat.currency(
  locale: 'id_ID',
  symbol: 'Rp ',
  decimalDigits: 0,
);

final NumberFormat _rupiahPlain = NumberFormat.decimalPattern('id_ID');

class RupiahFormatException implements Exception {
  RupiahFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Format Indonesia: titik = pemisah ribuan, koma = desimal.
/// Contoh: "1.500,50" -> 150050 cents. Nilai negatif/invalid ditolak.
int parseRupiahToCents(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return 0;
  if (text.contains('-') || text.startsWith('(')) {
    throw RupiahFormatException('Nominal tidak boleh negatif.');
  }
  text = text.replaceAll(RegExp(r'[Rr][Pp]\.?'), '').trim();
  text = text.replaceAll(RegExp(r'\s+'), '');
  if (text.isEmpty) return 0;
  if (!RegExp(r'^[0-9.,]+$').hasMatch(text)) {
    throw RupiahFormatException('Nominal hanya boleh berisi angka.');
  }

  var integerPart = text;
  var fractionPart = '';
  final comma = text.lastIndexOf(',');
  if (comma >= 0) {
    integerPart = text.substring(0, comma);
    fractionPart = text.substring(comma + 1);
    if (fractionPart.isEmpty || !RegExp(r'^\d+$').hasMatch(fractionPart)) {
      throw RupiahFormatException('Bagian desimal tidak valid.');
    }
    if (fractionPart.length > 2) {
      throw RupiahFormatException('Desimal rupiah maksimal 2 angka.');
    }
  }

  if (integerPart.contains('.')) {
    if (!RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(integerPart)) {
      throw RupiahFormatException(
        'Format ribuan tidak valid. Gunakan titik untuk ribuan dan koma '
        'untuk desimal (contoh: 1.500,50).',
      );
    }
    integerPart = integerPart.replaceAll('.', '');
  }
  if (integerPart.isEmpty || !RegExp(r'^\d+$').hasMatch(integerPart)) {
    throw RupiahFormatException('Nominal tidak valid.');
  }

  final rupiah = int.tryParse(integerPart);
  if (rupiah == null) {
    throw RupiahFormatException('Nominal terlalu besar.');
  }
  var cents = 0;
  if (fractionPart.isNotEmpty) {
    cents = int.parse(
      fractionPart.length == 1 ? '${fractionPart}0' : fractionPart,
    );
  }
  return rupiah * 100 + cents;
}

int? tryParseRupiahToCents(String raw) {
  try {
    return parseRupiahToCents(raw);
  } catch (_) {
    return null;
  }
}

/// Seluruh nominal ditampilkan dalam rupiah bulat tanpa sen. Pembulatan hanya
/// untuk tampilan; nilai tersimpan tetap dalam sen agar pajak dan HPP akurat.
String formatRupiah(int cents) => _rupiahWhole.format((cents / 100).round());

String formatRupiahPlain(int cents) =>
    _rupiahPlain.format((cents / 100).round());

int clampNonNegative(int value) => value < 0 ? 0 : value;
