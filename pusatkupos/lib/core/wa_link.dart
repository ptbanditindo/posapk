import 'phone.dart';

String maskPhone(String raw) {
  final digits = normalizePhone(raw).replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '-';
  if (digits.length <= 4) return digits;
  final tail = digits.substring(digits.length - 4);
  final head = digits.substring(0, digits.length >= 8 ? 2 : 1);
  return '$head${'*' * (digits.length - head.length - 4)}$tail';
}

bool isValidWhatsApp(String raw) {
  final digits = normalizePhone(raw).replaceAll(RegExp(r'[^0-9]'), '');
  return digits.length >= 10 && digits.length <= 15 && digits.startsWith('0');
}

String waMeLink(String raw, String message) {
  var digits = normalizePhone(raw).replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.startsWith('0')) {
    digits = '62${digits.substring(1)}';
  }
  return 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
}
