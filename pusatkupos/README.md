# PusatkuPOS

Aplikasi POS bengkel radiator/servis mobil yang **offline-first**. Semua data
transaksi disimpan di SQLite lokal; internet hanya dipakai untuk sinkronisasi
terenkripsi ke relay.

## Fitur

- Kasir: jasa, sparepart, diskon, tunai/transfer, bayar sebagian (piutang),
  dan kredit penuh tanpa pembayaran awal.
- Piutang: filter riwayat, pelunasan sebagian/penuh, dan laporan piutang.
- Stok: stok masuk, stok keluar manual (rusak/dipakai sendiri), opname,
  koreksi dengan riwayat `stock_movements`, satuan liter/meter dengan 1–3
  desimal.
- Laporan: omzet, laba kotor part, piutang, kas per metode pembayaran
  (termasuk refund), dan paginasi transaksi.
- Pelanggan: normalisasi nomor HP (`08…`/`+62…`), peringatan duplikat,
  gabung pelanggan, izin WhatsApp / jangan dihubungi.
- Peran: Pemilik, Kasir, Mekanik, Kasir & Mekanik dengan izin eksplisit.
  Mekanik tidak dapat void, mengubah stok, harga jasa, atau diskon.
- Audit: setiap diskon, void, dan perubahan izin dicatat.
- Backup/restore database dengan validasi + ganti atomik.

## Keamanan

- PIN pemilik baru minimal 6 digit, disimpan dengan PBKDF2-HMAC-SHA256
  600.000 iterasi. PIN lama 4 digit masih diterima saat login lalu otomatis
  dimigrasikan (aplikasi menyarankan ganti).
- PIN dan login perangkat memakai lockout bertingkat (`login_guards`).
- Kunci privat perangkat/owner/store hanya di secure storage. Tidak ada
  fallback diam-diam ke database; untuk tes/desktop set
  `PUSATKU_SECURE_DB=true`.
- Relay wajib `https://`; `http://` hanya untuk localhost pada build debug.
- Kunci owner dipin (TOFU) saat pairing. Izin karyawan, key-wrap kunci toko,
  dan snapshot diverifikasi terhadap kunci owner/perangkat yang dipin.
- Lisensi **hanya** diterbitkan server dan diverifikasi dengan kunci publik
  server yang ditanam saat build. Salin `.env.example` menjadi `.env` lalu isi
  `PUSATKU_LICENSE_PUBLIC_KEY`; jangan menaruh kunci di kode atau perintah.
  Kasir offline tetap gratis; sinkronisasi dan multi-perangkat memerlukan
  lisensi valid dan tidak terkunci saat kedaluwarsa (hanya sync yang mati).
- Login Google premium opsional: isi `PUSATKU_GOOGLE_CLIENT_ID` (OAuth client
  tipe **Web application**) dengan nilai yang sama seperti
  `RELAY_GOOGLE_CLIENT_ID` di relay. Tombol **Masuk dengan Google** ada di
  layar Premium dan hanya memulihkan lisensi; sesi aplikasi tetap memakai PIN.
  Untuk Android, daftarkan SHA-1 keystore aplikasi di Google Cloud Console.

## Build

Prasyarat: Flutter 3.47.9 (Dart 3.13.7), JDK 17, Android SDK.

```bash
# Sekali saja: salin contoh konfigurasi build.
cp .env.example .env   # PowerShell: Copy-Item .env.example .env

flutter pub get
flutter analyze
flutter test
flutter build apk --debug --dart-define-from-file=.env
flutter run --dart-define-from-file=.env
```

### Release

Release **tidak pernah** memakai debug key. Buat `android/key.properties`:

```properties
storeFile=../keystore/pusatku.jks
storePassword=...
keyAlias=pusatku
keyPassword=...
```

Tanpa berkas itu, `assembleRelease`/`bundleRelease` gagal dengan pesan jelas.
Manifest release memakai `INTERNET`, `allowBackup=false`, dan
`usesCleartextTraffic=false`. Build debug mengizinkan clear-text hanya untuk
relay localhost.

## Sinkronisasi

1. Isi alamat relay HTTPS + token pendaftaran di Premium/Pengaturan.
2. Perangkat owner mendaftar ke relay dan membagikan kunci toko (key-wrap
   bertanda tangan).
3. Perangkat lain menerima key-wrap dan memverifikasi tanda tangan kunci
   owner yang dipin.
4. Delta dikirim terenkripsi; penerapan delta + `applied_deltas` dalam satu
   transaksi. Amplop rusak dicatat di `sync_conflicts` dan tidak menghentikan
   sinkronisasi. Pengirim tak dikenal menghentikan kursor sebelum amplop itu.
5. Snapshot/backup memakai `device.nota_prefix` baru setelah restore; seq
   outbox dilanjutkan dari batas tersimpan.

### Kewajiban relay (tidak ada di repo ini)

- Mengirim `owner_public_key` pada respons claim undangan.
- Menandatangani izin karyawan dengan kunci owner (signer harus sama dengan
  kunci yang dipin), bukan kunci akses lain.
- Mengembalikan `wrapped_key_signature` pada bootstrap.
- Menerbitkan `license_token` (Ed25519 kunci server) pada claim/pairing.
- Menyimpan/meneruskan snapshot dan delta tanpa menerapkan data bisnis.
