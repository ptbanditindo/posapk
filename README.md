# PusatkuPOS APK

Repository ini berisi **dua aplikasi Flutter** PusatkuPOS. Kode web/Python lama
sengaja tidak disertakan agar aplikasi APK dapat dirawat terpisah.

## Aplikasi

| Folder | Aplikasi | Dipakai oleh | Bisa transaksi? |
|---|---|---|---|
| `pusatkupos/` | PusatkuPOS | Owner tanpa karyawan + karyawan | Ya |
| `pusatkupos_owner/` | PusatkuPOS Owner | Owner yang punya karyawan | Tidak (read-only + backup + kelola akses) |

### PusatkuPOS

- Aplikasi penuh: kasir, riwayat, pelanggan, stok, jasa, laporan, pengaturan.
- Owner tanpa karyawan memakai seluruh fitur.
- Karyawan dipasangkan lewat kode undangan dari aplikasi Owner, lalu login
  dengan username/password/PIN.
- Karyawan hanya melihat menu sesuai peran dan izinnya.

### PusatkuPOS Owner

- Replika **read-only** seluruh data toko: ringkasan, riwayat, laporan, stok,
  pelanggan.
- Menyimpan salinan lengkap dan dapat mengunggah snapshot backup ke relay.
- Memulihkan data ke perangkat toko lewat relay.
- **Kelola akses**: membuat akun karyawan, mengatur izin/toko, membuat kode
  undangan, melihat dan mencabut perangkat.
- Tidak memiliki layar transaksi.

## Struktur

```
pusatkupos/          aplikasi utama (owner + karyawan)
pusatkupos_owner/    aplikasi Owner (read-only + backup + kelola akses)
```

`pusatkupos_owner` memakai core data/sync dari `pusatkupos` melalui path
dependency. Karena itu kedua folder harus tetap bersebelahan.

## Kebutuhan build

- Flutter 3.47.9 (Dart 3.13.7)
- JDK 17
- Android SDK 36 + build-tools 36

Python, PostgreSQL, dan relay **tidak** ada di repository ini. Relay adalah
deployment terpisah; aplikasi menghubunginya lewat alamat relay dan token
pendaftaran yang diisi di layar Pengaturan.

## Build APK

```bash
cd pusatkupos
flutter pub get
flutter build apk --debug

cd ../pusatkupos_owner
flutter pub get
flutter build apk --debug
```

Hasil:

```
pusatkupos/build/app/outputs/flutter-apk/app-debug.apk
pusatkupos_owner/build/app/outputs/flutter-apk/app-debug.apk
```

APK release memerlukan keystore/signing sendiri.

## Tes

```bash
cd pusatkupos
flutter analyze
flutter test

cd ../pusatkupos_owner
flutter analyze
```

Tes multi-device membutuhkan relay yang berjalan dan file `.env` lokal; lihat
`pusatkupos/tool/run_sync_peer_e2e.sh`. File `.env` tidak pernah di-commit.

## Keamanan

- Jangan commit `.env`, token relay, private key, keystore, atau file APK.
- Rahasia perangkat disimpan di secure storage; snapshot mengecualikan
  pengaturan `secure.*`.
