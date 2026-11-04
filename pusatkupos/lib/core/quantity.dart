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
  final clean = raw.trim().replaceAll('.', '').replaceAll(',', '.');
  if (clean.isEmpty) return null;
  final value = double.tryParse(clean);
  if (value == null || value.isNaN || value.isInfinite) return null;
  return (value * 1000).round();
}
