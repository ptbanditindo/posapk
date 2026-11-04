/// Alamat layanan pusat ditanam saat build dan tidak pernah diminta ke
/// pengguna. Bangun dengan
/// `--dart-define=PUSATKU_SERVICE_URL=https://...` untuk produksi.
const String serviceBaseUrl = String.fromEnvironment(
  'PUSATKU_SERVICE_URL',
  defaultValue: '',
);

bool get serviceConfigured => serviceBaseUrl.trim().isNotEmpty;

String get normalizedServiceUrl {
  final raw = serviceBaseUrl.trim();
  if (raw.isEmpty) return '';
  return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
}
