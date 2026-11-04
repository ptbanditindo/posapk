String normalizePhone(String raw) {
  var text = raw.trim().replaceAll(RegExp(r'[^0-9+]'), '');
  if (text.startsWith('+62')) {
    text = '0${text.substring(3)}';
  } else if (text.startsWith('62') && text.length > 10) {
    text = '0${text.substring(2)}';
  } else if (text.startsWith('8')) {
    text = '0$text';
  }
  return text;
}

String escapeLike(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}
