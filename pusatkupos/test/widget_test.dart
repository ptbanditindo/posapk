import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/core/money.dart';

void main() {
  test('parse dan format rupiah', () {
    expect(parseRupiahToCents('Rp 150.000'), 15000000);
    expect(parseRupiahToCents(''), 0);
    expect(parseRupiahToCents('1.500,50'), 150050);
    expect(parseRupiahToCents('1500,5'), 150050);
    expect(parseRupiahToCents('1.500.000'), 150000000);
    expect(formatRupiahPlain(15000000), '150.000');
    expect(tryParseRupiahToCents('bukan angka'), isNull);
    expect(
      () => parseRupiahToCents('-5.000'),
      throwsA(isA<RupiahFormatException>()),
    );
    expect(
      () => parseRupiahToCents('1.5'),
      throwsA(isA<RupiahFormatException>()),
    );
    expect(
      () => parseRupiahToCents('1.500,555'),
      throwsA(isA<RupiahFormatException>()),
    );
  });
}
