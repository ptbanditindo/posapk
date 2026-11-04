import 'package:flutter/foundation.dart';

/// Menormalkan alamat relay dan menolak http pada build non-debug.
/// http hanya diizinkan untuk localhost/127.0.0.1 saat build debug.
String normalizeRelayUrl(String raw, {bool? allowInsecureLocalhost}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Alamat relay wajib diisi.');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ArgumentError('Alamat relay tidak valid.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http') {
    final local = uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host == '::1';
    final allowed = allowInsecureLocalhost ?? kDebugMode;
    if (!allowed || !local) {
      throw ArgumentError(
        'Alamat relay harus memakai https://. http:// hanya diizinkan '
        'untuk localhost pada build debug.',
      );
    }
  } else if (scheme != 'https') {
    throw ArgumentError('Alamat relay harus memakai https://.');
  }
  return trimmed.replaceAll(RegExp(r'/+$'), '');
}
