import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/core/money.dart';

void main() {
  test('parse dan format rupiah', () {
    expect(parseRupiahToCents('Rp 150.000'), 15000000);
    expect(parseRupiahToCents(''), 0);
    expect(formatRupiahPlain(15000000), '150.000');
  });
}
