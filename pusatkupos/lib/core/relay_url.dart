/// Menormalkan alamat layanan. Alamat ditanam saat build, bukan diisi
/// pengguna, sehingga http hanya diterima untuk loopback (relay lokal).
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
    final allowed = allowInsecureLocalhost ?? true;
    if (!allowed || !local) {
      throw ArgumentError(
        'Alamat layanan harus memakai https://. http:// hanya diizinkan '
        'untuk localhost.',
      );
    }
  } else if (scheme != 'https') {
    throw ArgumentError('Alamat relay harus memakai https://.');
  }
  return trimmed.replaceAll(RegExp(r'/+$'), '');
}
