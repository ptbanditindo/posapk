import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String newNotaPrefix({int length = 6}) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => _alphabet[random.nextInt(_alphabet.length)],
  ).join();
}

/// Kode perangkat untuk nomor nota/antrian lokal.
///
/// Enam karakter acak dari alfabet 32 simbol memberi sekitar satu miliar
/// kombinasi, sehingga dua perangkat tidak mungkin memakai kode yang sama
/// secara tidak sengaja (kode tiga karakter hanya punya ~32 ribu kombinasi).
const deviceCodeLength = 6;
const _deviceCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
final _deviceCodePattern = RegExp(r'^[A-Z0-9]{6,12}$');

String newDeviceCode({int length = deviceCodeLength}) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => _deviceCodeAlphabet[random.nextInt(_deviceCodeAlphabet.length)],
  ).join();
}

/// Kode tersimpan hanya dipakai bila panjang dan karakternya aman; kode lama
/// tiga karakter dibuat ulang agar nomor dokumen tidak bentrok antardevice.
bool isStrongDeviceCode(String code) => _deviceCodePattern.hasMatch(code);

String newSyncId() {
  final random = Random.secure();
  var millis = DateTime.now().millisecondsSinceEpoch;
  final stamp = StringBuffer();
  for (var i = 0; i < 10; i++) {
    stamp.write(_alphabet[millis & 31]);
    millis >>= 5;
  }
  final timePart = stamp.toString().split('').reversed.join();
  final randomPart = List.generate(
    16,
    (_) => _alphabet[random.nextInt(_alphabet.length)],
  ).join();
  return '$timePart$randomPart';
}
