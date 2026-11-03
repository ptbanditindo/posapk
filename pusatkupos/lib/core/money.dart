import 'package:intl/intl.dart';

final NumberFormat _rupiah = NumberFormat.currency(
  locale: 'id_ID',
  symbol: 'Rp ',
  decimalDigits: 0,
);

int parseRupiahToCents(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return 0;
  return int.parse(digits) * 100;
}

String formatRupiah(int cents) => _rupiah.format(cents / 100);

String formatRupiahPlain(int cents) {
  final value = (cents / 100).round();
  return NumberFormat.decimalPattern('id_ID').format(value);
}

int clampNonNegative(int value) => value < 0 ? 0 : value;
