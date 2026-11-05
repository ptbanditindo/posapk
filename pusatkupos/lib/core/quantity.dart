/// Kuantitas stok disimpan sebagai milli-unit (1/1000) agar liter/meter
/// bisa memakai 1-3 desimal tanpa kehilangan presisi.
String formatQuantity(int milli, int desimal, {String satuan = ''}) {
  final negative = milli < 0;
  final abs = milli.abs();
  final whole = abs ~/ 1000;
  final fraction = abs % 1000;
  final digits = desimal.clamp(0, 3);
  var text = '$whole';
  if (digits > 0) {
    final padded = fraction.toString().padLeft(3, '0').substring(0, digits);
    text = '$text,$padded';
  }
  if (negative) text = '-$text';
  final trimmed = text.replaceFirst(RegExp(r',0+$'), '');
  return satuan.isEmpty ? trimmed : '$trimmed $satuan';
}

int? parseQuantityToMilli(String raw, {int desimal = 0}) {
  var clean = raw.trim().replaceAll(' ', '');
  if (clean.isEmpty) return null;
  final digits = desimal.clamp(0, 3);
  if (clean.contains(',')) {
    if (','.allMatches(clean).length > 1) return null;
    clean = clean.replaceAll('.', '').replaceAll(',', '.');
  } else {
    final dots = '.'.allMatches(clean).length;
    if (dots > 1) {
      clean = clean.replaceAll('.', '');
    } else if (dots == 1) {
      final parts = clean.split('.');
      final fraction = parts[1];
      if (fraction.isEmpty) {
        clean = parts[0];
      } else if (digits > 0 && fraction.length <= digits) {
        // Satu titik dengan 1-3 digit di belakang dibaca sebagai desimal.
      } else if (digits == 0 && fraction.length == 3) {
        clean = clean.replaceAll('.', '');
      } else {
        return null;
      }
    }
  }
  if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(clean)) return null;
  final fraction = clean.split('.').length > 1 ? clean.split('.')[1] : '';
  if (fraction.length > digits) return null;
  final value = double.tryParse(clean);
  if (value == null || value.isNaN || value.isInfinite) return null;
  return (value * 1000).round();
}
