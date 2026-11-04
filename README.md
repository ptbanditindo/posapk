# PusatkuPOS

Repository ini berisi **satu aplikasi Flutter** PusatkuPOS dan server relay
pendukung. Aplikasi bersifat **offline-first**: seluruh transaksi disimpan di
SQLite lokal; internet hanya dipakai untuk sinkronisasi akun premium.

## Empat cara masuk

| Pilihan | Untuk siapa | Bisa transaksi? | Catatan |
|---|---|---|---|
| **Tanpa akun** | Pemilik toko tanpa akun | Ya | Gratis, 1 toko, kuota follow-up 20 |
| **Login Google** | Pemilik berlangganan premium | Ya | Lisensi per toko, sinkronisasi aktif |
| **Login karyawan** | Kasir / mekanik | Sesuai izin | Akun dibuat pemilik lewat mode ringkasan |
| **Ringkasan laporan toko** | Pemilik yang sudah login Google | **Tidak** | Hanya membaca pembukuan dan mengelola akses |

Mode **ringkasan laporan toko** memakai salinan database terpisah dari
pembukuan lokal perangkat. Mode ini tidak memiliki layar kasir, stok masuk,
atau pengeditan nota; yang bisa dilakukan hanya melihat ringkasan, riwayat,
laporan, memuat/mengunggah cadangan, serta mengelola akun dan perangkat
karyawan.

## Rencana distribusi (Play Store shell)

Rencana rilis: APK di Play Store hanya berupa **cangkang**. Setelah pengguna
memilih cara masuk, aplikasi memuat hanya resource yang dibutuhkan:

- **Tanpa akun / Login Google** — mengunduh seluruh fitur kasir dan pembukuan.
- **Karyawan** — hanya fitur sesuai peran.
- **Ringkasan laporan toko** — hanya modul laporan read-only dan kelola akses.

Biaya unduhan data ditanggung pengguna karena aplikasi bekerja offline. Sync
data hanya aktif untuk akun premium.

Catatan teknis: Flutter membungkus kode Dart ke dalam satu `libapp.so`, sehingga
pemisahan resource per jalur login di Android memerlukan **Play Feature
Delivery / dynamic feature module** (atau artifact terpisah per varian). Pada
tahap ini aplikasi sudah membangun layar secara malas (hanya layar yang dibuka
yang diinisialisasi), tetapi pemisahan paket unduhan penuh masih menjadi
pekerjaan rilis terpisah.

## Struktur

```
pusatkupos/   aplikasi Flutter (4 jalur login, offline-first)
relay/        server sinkronisasi + lisensi (deployment internal)
```

Relay adalah layanan premium yang disediakan pemilik aplikasi, bukan sesuatu
yang dipasang atau diatur toko. Alamatnya ditanam saat build
(`PUSATKU_SERVICE_URL`) dan **tidak pernah** diminta atau diatur pengguna.

## Kebutuhan build

- Flutter 3.47.9 (Dart 3.13.7)
- JDK 17
- Android SDK 36 + build-tools 36
- Untuk relay: Dart dari Flutter + PostgreSQL

## Build APK

```bash
cd pusatkupos
cp .env.example .env    # PowerShell: Copy-Item .env.example .env
flutter pub get
flutter build apk --debug
```

Hasil: `pusatkupos/build/app/outputs/flutter-apk/app-debug.apk`.

APK release memerlukan keystore/signing sendiri; lihat
[`pusatkupos/README.md`](pusatkupos/README.md).

## Tes

```bash
cd pusatkupos
flutter analyze
flutter test
```

Tes multi-device memerlukan relay yang berjalan dan file `.env` lokal; lihat
`pusatkupos/tool/run_sync_peer_e2e.sh`. File `.env` tidak pernah di-commit.

## Keamanan

- Jangan commit `.env`, token, private key, keystore, atau file APK.
- PIN owner disimpan dengan PBKDF2-HMAC-SHA256 600.000 iterasi.
- Mode ringkasan memakai kunci dan database terpisah sehingga tidak dapat
  membuat atau mengubah pembukuan.
- Salinan dan sinkronisasi diverifikasi dengan kunci owner yang dipin.
- Unggah cadangan memakai putaran sinkron: relay menolak snapshot sampai
  semua perangkat tulis toko mengaku sudah sinkron dan tidak menyisakan
  perubahan lokal. Status per perangkat disimpan di database lokal.
- Perangkat yang benar-benar hilang harus dicabut lewat menu Akses; setelah
  dicabut perangkat itu tidak lagi menahan unggahan.
- Rahasia perangkat disimpan di secure storage; snapshot mengecualikan
  pengaturan `secure.*`.
