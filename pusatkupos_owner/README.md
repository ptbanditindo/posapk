# PusatkuPOS Owner

Aplikasi Flutter read-only untuk pemilik yang memiliki karyawan. Memakai core
data/sync dari `../pusatkupos` lewat path dependency.

- Impor ringkasan owner bertanda tangan (`owner_public_key` + `license_token`).
- Melihat ringkasan, riwayat, laporan, stok, dan pelanggan hasil sinkronisasi.
- Mengelola akun karyawan, izin, kode undangan, dan perangkat lewat relay.
- Mengunggah/mengambil snapshot backup.
- Tidak memiliki layar transaksi.

## Menjalankan

```bash
# Sekali saja: salin contoh konfigurasi build.
cp .env.example .env   # PowerShell: Copy-Item .env.example .env

flutter pub get
flutter analyze
flutter run --dart-define-from-file=.env
```

`.env` berisi `PUSATKU_LICENSE_PUBLIC_KEY` dari relay dan tidak ikut di-commit.

Relay harus HTTPS. Token pendaftaran disimpan di secure storage, bukan
SharedPreferences. Aplikasi ini hanya bisa sinkronisasi bila ringkasan owner
membawa token lisensi server yang valid.

Lihat `../README.md` dan `../pusatkupos/README.md` untuk model lisensi,
keamanan, dan kewajiban relay.
