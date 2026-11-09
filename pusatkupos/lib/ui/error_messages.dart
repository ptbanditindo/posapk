import '../data/escrow_service.dart';
import '../sync/relay_client.dart';
import '../sync/sync_conflict_rules.dart';

/// Pesan error yang dapat ditindaklanjuti pengguna.
///
/// Pesan teknis tetap dicatat di log; yang ditampilkan hanya penyebab singkat
/// dan langkah pemulihan yang relevan.
class UserError {
  const UserError(this.message, {this.action = ''});

  final String message;
  final String action;

  String get text => action.isEmpty ? message : '$message $action';

  @override
  String toString() => text;
}

UserError describeError(Object error) {
  if (error is RelayException) return _relayError(error);
  if (error is ProtocolVersionException) {
    return UserError(
      error.toString(),
      action: 'Perbarui aplikasi, lalu buka ulang halaman ini.',
    );
  }
  if (error is RetryableSyncException) {
    return UserError(
      error.message,
      action: 'Dokumen akan dicoba lagi otomatis saat sinkronisasi berikutnya.',
    );
  }
  if (error is EscrowException) {
    return UserError(
      error.message,
      action: 'Buka Pengaturan > Pemulihan kunci untuk memeriksa frasa, share, '
          'atau berkas escrow.',
    );
  }

  final raw = '$error';
  final text = raw.toLowerCase();
  bool has(List<String> parts) => parts.any(text.contains);

  if (has(const ['database is locked', 'database is busy'])) {
    return UserError(
      'Database sedang dipakai proses lain.',
      action: 'Tutup aplikasi lain yang membuka data yang sama, lalu coba lagi.',
    );
  }
  if (has(const ['kunci', 'decrypt', 'cipher', 'hmac', 'key version'])) {
    return UserError(
      raw,
      action: 'Minta pemilik membagikan ulang kunci toko, atau pulihkan kunci '
          'lewat Pengaturan > Pemulihan kunci.',
    );
  }
  if (has(const ['token', 'sesi', 'unauthorized', 'login'])) {
    return UserError(
      raw,
      action: 'Keluar lalu masuk kembali. Bila perangkat ini karyawan, minta '
          'pemilik memasangkan ulang perangkat.',
    );
  }
  if (has(const ['penuh', 'no space', 'disk full'])) {
    return UserError(
      raw,
      action: 'Kosongkan penyimpanan perangkat lalu coba lagi.',
    );
  }
  return UserError(raw);
}

String friendlyError(Object error) => describeError(error).text;

UserError _relayError(RelayException error) {
  final detail = error.message.trim();
  switch (error.code) {
    case 'device_revoked':
      return UserError(
        'Perangkat ini dicabut pemilik sehingga sinkronisasi dihentikan.',
        action: 'Ekspor antrean yang belum terkirim, lalu pasangkan ulang '
            'perangkat. Data lokal tidak dihapus otomatis.',
      );
    case 'protocol_unsupported':
    case 'upgrade_required':
      return UserError(
        'Versi aplikasi ini tidak lagi didukung relay.',
        action: 'Perbarui aplikasi. Data lokal tetap aman dan sinkronisasi '
            'dilanjutkan setelah aplikasi diperbarui.',
      );
    case 'stale_key':
      return UserError(
        'Kunci toko di perangkat ini sudah tidak berlaku.',
        action: 'Tunggu pembaruan kunci dari pemilik, lalu tekan Sinkron lagi.',
      );
    case 'license_expired':
    case 'license_inactive':
      return UserError(
        'Lisensi toko tidak aktif untuk layanan server.',
        action: 'Periksa masa berlaku lisensi di menu Premium. Data lokal dan '
            'penjualan tetap dapat dipakai.',
      );
    case 'storage_full':
      return UserError(
        'Penyimpanan relay penuh sehingga unggahan ditolak.',
        action: 'Hubungi pengelola relay untuk membersihkan ruang, lalu coba '
            'lagi. Dokumen tetap tersimpan lokal.',
      );
    case 'body_too_large':
      return UserError(
        'Dokumen terlalu besar untuk dikirim ke relay.',
        action: 'Periksa lampiran atau logo struk yang tidak wajar, lalu coba '
            'lagi.',
      );
    case 'rate_limited':
    case 'relay_sibuk':
      return UserError(
        'Relay sedang sibuk atau permintaan terlalu sering.',
        action: 'Tunggu beberapa saat; percobaan berikutnya otomatis '
            'dijadwalkan.',
      );
    case 'incomplete_store':
      return UserError(
        'Data toko di relay belum lengkap.',
        action: 'Minta pemilik menyelesaikan unggahan snapshot toko, lalu '
            'sinkronkan lagi.',
      );
    case 'origin_denied':
      return UserError(
        'Permintaan ditolak oleh kebijakan asal (CORS) relay.',
        action: 'Gunakan alamat relay resmi yang diizinkan pengelola.',
      );
  }
  if (error.code == 'timeout' || error.statusCode == 408) {
    return UserError(
      'Relay tidak merespons dalam batas waktu.',
      action: 'Periksa koneksi internet dan alamat relay, lalu tekan Sinkron '
          'lagi. Dokumen tetap tersimpan lokal.',
    );
  }
  if (error.statusCode == 401) {
    return UserError(
      'Sesi perangkat tidak diakui relay.',
      action: 'Masuk ulang, atau minta pemilik memasangkan ulang perangkat.',
    );
  }
  if (error.statusCode == 403) {
    return UserError(
      detail.isEmpty ? 'Akses perangkat ditolak relay.' : detail,
      action: 'Keluar lalu masuk kembali. Bila berulang, minta pemilik '
          'memeriksa daftar perangkat.',
    );
  }
  if (error.statusCode == 409) {
    return UserError(
      detail.isEmpty ? 'Terjadi konflik data dengan relay.' : detail,
      action: 'Buka layar Konflik untuk memilih penyelesaian; dokumen tidak '
          'dihapus.',
    );
  }
  if (error.statusCode == 426) {
    return UserError(
      'Relay meminta versi aplikasi yang lebih baru.',
      action: 'Perbarui aplikasi lalu sinkronkan lagi.',
    );
  }
  if (error.statusCode >= 500) {
    return UserError(
      detail.isEmpty ? 'Relay sedang bermasalah.' : detail,
      action: 'Coba lagi beberapa saat. Bila berulang, hubungi pengelola relay.',
    );
  }
  return UserError(detail.isEmpty ? 'Permintaan ke relay gagal.' : detail);
}
