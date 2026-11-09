/// Diagnosis awal kegagalan startup sebelum database dikarantina.
///
/// Tujuannya memberi penyebab yang dapat dibaca pemilik tanpa harus membuka
/// database. Diagnosis hanya memakai teks error yang sudah tersedia; tidak ada
/// berkas yang dipindahkan atau diubah di sini.
class StartupDiagnosis {
  const StartupDiagnosis(this.cause, this.action);

  final String cause;
  final String action;

  String get summary => '$cause $action';
}

StartupDiagnosis diagnoseStartupError(Object error) {
  final text = '$error'.toLowerCase();
  bool has(List<String> parts) => parts.any(text.contains);

  if (has(const ['database is locked', 'database is busy', 'database locked'])) {
    return const StartupDiagnosis(
      'Database masih dipakai proses lain.',
      'Tutup aplikasi lain yang membuka berkas yang sama, lalu pilih "Coba '
      'buka ulang". Mode aman belum diperlukan.',
    );
  }
  if (has(const [
    'disk i/o error',
    'database or disk is full',
    'sqlite_full',
    'no space left',
    'not enough space',
  ])) {
    return const StartupDiagnosis(
      'Ruang penyimpanan penuh atau media penyimpanan bermasalah.',
      'Kosongkan penyimpanan perangkat, lalu pilih "Coba buka ulang". Jangan '
      'buka mode aman sebelum berkas database diekspor.',
    );
  }
  if (has(const [
    'readonly',
    'read-only',
    'permission denied',
    'access is denied',
    'operation not permitted',
    'unable to open database file',
  ])) {
    return const StartupDiagnosis(
      'Aplikasi tidak memiliki izin membuka atau menulis berkas database.',
      'Periksa izin folder aplikasi dan pengaturan antivirus, lalu pilih '
      '"Coba buka ulang".',
    );
  }
  if (has(const [
    'malformed',
    'not a database',
    'file is encrypted or is not a database',
    'database disk image is malformed',
    'checksum mismatch',
  ])) {
    return const StartupDiagnosis(
      'Berkas database rusak atau bukan database yang dikenali.',
      'Ekspor berkas database lebih dulu, lalu pulihkan dari backup. Mode aman '
      'hanya dipakai bila tidak ada salinan lain.',
    );
  }
  if (has(const ['decrypt', 'cipher', 'wrong key', 'hmac', 'kunci perangkat'])) {
    return const StartupDiagnosis(
      'Kunci enkripsi perangkat tidak cocok dengan berkas database.',
      'Ekspor berkas database, lalu pulihkan dari backup atau pulihkan kunci '
      'lewat menu Pemulihan kunci. Mode aman tidak menghapus data lama.',
    );
  }
  if (has(const [
    'schema',
    'version',
    'downgrade',
    'newer version',
    'lebih baru',
    'lebih lama',
  ])) {
    return const StartupDiagnosis(
      'Versi database tidak cocok dengan versi aplikasi ini.',
      'Perbarui aplikasi ke versi terbaru atau gunakan versi aplikasi yang '
      'sama dengan saat database dibuat.',
    );
  }
  if (has(const ['no such table', 'file not found', 'cannot open'])) {
    return const StartupDiagnosis(
      'Berkas atau tabel database yang dibutuhkan tidak ditemukan.',
      'Pulihkan dari backup. Bila baru saja memindahkan folder aplikasi, '
      'kembalikan berkas database ke lokasi semula lalu coba buka ulang.',
    );
  }
  return const StartupDiagnosis(
    'Penyebab pasti belum dapat ditentukan dari pesan error.',
    'Ekspor berkas database dan salin diagnostik ini sebelum memilih mode '
    'aman, lalu hubungi dukungan.',
  );
}
