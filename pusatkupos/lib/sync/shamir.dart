import 'dart:math';

import 'crypto.dart';

/// Pembagian rahasia Shamir di GF(256) dengan polinomial AES (0x11b).
/// Dipakai untuk master recovery key admin 2-dari-3. Setiap share berdiri
/// sendiri; dua share diperlukan untuk merekonstruksi master.
class ShamirShare {
  const ShamirShare({required this.index, required this.value});

  final int index;
  final List<int> value;

  String encode() => 'shamir:v1:$index:${b64e(value)}';

  static ShamirShare decode(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 4 || parts[0] != 'shamir' || parts[1] != 'v1') {
      throw const FormatException('Format share admin tidak dikenal.');
    }
    final index = int.tryParse(parts[2]);
    if (index == null || index < 1 || index > 255) {
      throw const FormatException('Nomor share admin tidak valid.');
    }
    return ShamirShare(index: index, value: b64d(parts[3]));
  }
}

List<ShamirShare> splitSecret(
  List<int> secret, {
  int threshold = 2,
  int shareCount = 3,
  Random? random,
}) {
  if (threshold < 2 || threshold > shareCount || shareCount > 255) {
    throw ArgumentError('Parameter Shamir tidak valid.');
  }
  if (secret.isEmpty) throw ArgumentError('Rahasia kosong.');
  final rng = random ?? Random.secure();
  final coefficients = [
    for (var degree = 1; degree < threshold; degree++)
      List<int>.generate(secret.length, (_) => rng.nextInt(256)),
  ];
  final shares = <ShamirShare>[];
  for (var index = 1; index <= shareCount; index++) {
    final value = List<int>.generate(secret.length, (position) {
      var result = secret[position];
      for (var degree = 0; degree < coefficients.length; degree++) {
        final factor = _power(index, degree + 1);
        result ^= _mul(coefficients[degree][position], factor);
      }
      return result;
    });
    shares.add(ShamirShare(index: index, value: value));
  }
  return shares;
}

List<int> combineShares(List<ShamirShare> shares, {int threshold = 2}) {
  if (shares.length < threshold) {
    throw ArgumentError(
      'Butuh minimal $threshold share admin untuk membuka escrow.',
    );
  }
  final selected = shares.take(threshold).toList();
  final indexes = selected.map((share) => share.index).toSet();
  if (indexes.length != selected.length) {
    throw ArgumentError('Share admin tidak boleh berasal dari nomor yang sama.');
  }
  final length = selected.first.value.length;
  if (selected.any((share) => share.value.length != length)) {
    throw ArgumentError('Panjang share admin tidak sama.');
  }
  return List<int>.generate(length, (position) {
    var result = 0;
    for (var i = 0; i < selected.length; i++) {
      var basis = 1;
      for (var j = 0; j < selected.length; j++) {
        if (i == j) continue;
        basis = _mul(
          basis,
          _div(selected[j].index, selected[j].index ^ selected[i].index),
        );
      }
      result ^= _mul(selected[i].value[position], basis);
    }
    return result;
  });
}

int _mul(int a, int b) {
  var x = a & 0xFF;
  var y = b & 0xFF;
  var result = 0;
  while (y != 0) {
    if (y & 1 != 0) result ^= x;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11B;
    y >>= 1;
  }
  return result & 0xFF;
}

int _power(int base, int exponent) {
  var result = 1;
  var value = base & 0xFF;
  var power = exponent;
  while (power > 0) {
    if (power & 1 != 0) result = _mul(result, value);
    value = _mul(value, value);
    power >>= 1;
  }
  return result;
}

int _inv(int value) {
  if (value == 0) throw ArgumentError('Pembagi nol.');
  return _power(value, 254);
}

int _div(int numerator, int denominator) => _mul(numerator, _inv(denominator));
