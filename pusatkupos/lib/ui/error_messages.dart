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
      action: 'Perbarui aplikasi, lalu buka ulang layar ini.',
    );
  }
  if (error is RetryableSyncException) {
    return UserError(
      error.message,
      action: 'Data akan dicoba kirim lagi otomatis saat sinkronisasi berikutnya.',
    );
  }
  if (error is EscrowException) {
    return UserError(
      error.message,
      action: 'Buka Pengaturan > Pemulihan kunci untuk memeriksa frasa pemulihan '
          'atau berkas kunci Anda.',
    );
  }

  final raw = '$error';
  final text = raw.toLowerCase();
  bool has(List<String> parts) => parts.any(text.contains);

  if (has(const ['database is locked', 'database is busy'])) {
    return UserError(
      'Data sedang dipakai aplikasi lain.',
      action: 'Tutup aplikasi lain yang membuka data yang sama, lalu coba lagi.',
    );
  }
  if (has(const ['kunci', 'decrypt', 'cipher', 'hmac', 'key version'])) {
    return UserError(
      raw,
      action: 'Minta pemilik mengirim ulang kunci toko, atau pulihkan kunci lewat '
          'Pengaturan > Pemulihan kunci.',
    );
  }
  if (has(const ['token', 'sesi', 'unauthorized', 'login'])) {
    return UserError(
      raw,
      action: 'Keluar lalu masuk kembali. Bila ini perangkat karyawan, minta '
          'pemilik menghubungkan ulang perangkat.',
    );
  }
  if (has(const ['penuh', 'no space', 'disk full'])) {
    return UserError(
      raw,
      action: 'Hapus berkas yang tidak dipakai untuk mengosongkan penyimpanan, lalu '
          'coba lagi.',
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
        'Pemilik mencabut akses perangkat ini, jadi sinkronisasi berhenti.',
        action: 'Ekspor data yang belum terkirim, lalu hubungkan perangkat lagi. Data '
            'di perangkat tidak dihapus otomatis.',
      );
    case 'protocol_unsupported':
    case 'upgrade_required':
      return UserError(
        'Versi aplikasi ini tidak didukung server lagi.',
        action: 'Perbarui aplikasi. Data di perangkat tetap aman dan sinkronisasi '
            'berjalan lagi setelah aplikasi diperbarui.',
      );
    case 'stale_key':
      return UserError(
        'Kunci toko di perangkat ini sudah tidak berlaku.',
        action: 'Tunggu pemilik mengirim kunci baru, lalu tekan Sinkron lagi.',
      );
    case 'license_expired':
    case 'license_inactive':
      return UserError(
        'Lisensi toko tidak aktif, jadi layanan server tidak bisa dipakai.',
        action: 'Periksa masa berlaku lisensi di menu Premium. Penjualan dan data di '
            'perangkat tetap bisa dipakai.',
      );
    case 'storage_full':
      return UserError(
        'Penyimpanan server penuh, jadi unggahan ditolak.',
        action: 'Hubungi pengelola server untuk membersihkan ruang, lalu coba lagi. '
            'Data tetap tersimpan di perangkat.',
      );
    case 'body_too_large':
      return UserError(
        'Data terlalu besar untuk dikirim ke server.',
        action: 'Periksa lampiran atau logo struk yang ukurannya tidak wajar, lalu '
            'coba lagi.',
      );
    case 'rate_limited':
    case 'relay_sibuk':
      return UserError(
        'Server sedang sibuk atau permintaan terlalu sering.',
        action: 'Tunggu beberapa saat. Percobaan berikutnya dijadwalkan otomatis.',
      );
    case 'incomplete_store':
      return UserError(
        'Data toko di server belum lengkap.',
        action: 'Minta pemilik menyelesaikan unggahan cadangan data toko, lalu '
            'sinkronkan lagi.',
      );
    case 'origin_denied':
      return UserError(
        'Permintaan ditolak oleh pengaturan keamanan server.',
        action: 'Gunakan alamat server resmi yang diberikan pengelola.',
      );
  }
  if (error.code == 'timeout' || error.statusCode == 408) {
    return UserError(
      'Server tidak merespons dalam batas waktu.',
      action: 'Periksa koneksi internet dan alamat server, lalu tekan Sinkron lagi. '
          'Data tetap tersimpan di perangkat.',
    );
  }
  if (error.statusCode == 401) {
    return UserError(
      'Server tidak mengenali sesi perangkat ini.',
      action: 'Masuk ulang, atau minta pemilik menghubungkan ulang perangkat.',
    );
  }
  if (error.statusCode == 403) {
    return UserError(
      detail.isEmpty ? 'Server menolak akses perangkat ini.' : detail,
      action: 'Keluar lalu masuk kembali. Bila berulang, minta pemilik '
          'memeriksa daftar perangkat.',
    );
  }
  if (error.statusCode == 409) {
    return UserError(
      detail.isEmpty ? 'Ada data yang bentrok dengan server.' : detail,
      action: 'Buka layar Konflik untuk memilih data yang dipakai. Data tidak '
          'dihapus.',
    );
  }
  if (error.statusCode == 426) {
    return UserError(
      'Server meminta versi aplikasi yang lebih baru.',
      action: 'Perbarui aplikasi lalu sinkronkan lagi.',
    );
  }
  if (error.statusCode >= 500) {
    return UserError(
      detail.isEmpty ? 'Server sedang bermasalah.' : detail,
      action: 'Coba lagi beberapa saat. Bila masih gagal, hubungi pengelola server.',
    );
  }
  return UserError(detail.isEmpty ? 'Permintaan ke server gagal.' : detail);
}
