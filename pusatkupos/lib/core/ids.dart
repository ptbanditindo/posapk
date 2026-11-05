import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String newNotaPrefix({int length = 6}) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => _alphabet[random.nextInt(_alphabet.length)],
  ).join();
}

/// Kode perangkat 3 karakter untuk nomor nota/antrian lokal.
String newDeviceCode({int length = 3}) {
  final random = Random.secure();
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(
    length,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

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
