# PusatkuPOS

Aplikasi POS bengkel radiator/servis mobil yang **offline-first**. Semua data
transaksi disimpan di SQLite lokal; internet hanya dipakai untuk sinkronisasi
terenkripsi ke layanan pusat.

## Empat cara masuk

1. **Tanpa akun** — pemilik lokal, seluruh fitur kasir, gratis.
2. **Login Google** — pemilik premium, seluruh fitur kasir + sinkronisasi.
3. **Login karyawan** — kasir/mekanik sesuai izin dan toko yang ditugaskan.
4. **Ringkasan laporan toko** — pemilik yang sudah login Google, **hanya baca**
   pembukuan dan mengelola akun/perangkat karyawan.

Mode ringkasan memakai file database terpisah (`viewer_<owner_id>.db`) dan
tidak memasang layar kasir, stok masuk, atau pengeditan nota. Salinan toko
dimuat dari cadangan perangkat utama; unggah cadangan dan kelola akses tetap
tersedia.

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
- Printer: Bluetooth Classic (SPP), Bluetooth LE (GATT), Wi-Fi/LAN (port 9100
  + pencarian NSD), USB OTG (BULK OUT), cetak Android, dan dialog browser.
  Konfigurasi (MAC/IP) disimpan di `printer_config.json` terpisah agar tidak
  ikut backup/sinkronisasi; maksimal 8 printer dengan satu printer utama.

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
  Kasir offline tetap gratis; sinkronisasi dan multi-toko memerlukan
  lisensi valid (kuota toko mengikuti `store_limit` pada token) dan tidak
  terkunci saat kedaluwarsa (hanya sync yang mati). Tidak ada batas jumlah
  perangkat; harga premium dihitung per toko.
- Login Google opsional: isi `PUSATKU_GOOGLE_CLIENT_ID` (OAuth client tipe
  **Web application**) dengan nilai yang sama seperti `RELAY_GOOGLE_CLIENT_ID`
  di layanan pusat. Ada dua jalur: **Login Google** untuk pemilik premium
  (fitur penuh) dan **Ringkasan laporan toko** (read-only). Sesi aplikasi tetap
  memakai PIN. Untuk Android, daftarkan SHA-1 keystore di Google Cloud Console.
- Alamat layanan dan token pendaftaran ditanam saat build; pengguna tidak
  pernah melihat atau mengisi alamat relay. Relay adalah layanan premium yang
  disediakan pemilik aplikasi dan tidak perlu dipasang atau diatur toko.

## Build

Prasyarat: Flutter 3.47.9 (Dart 3.13.7), JDK 17, Android SDK.

Android meminta izin Bluetooth saat mencari/menghubungkan printer (API 31+:
`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`) dan izin USB saat pertama memakai printer
OTG. Izin fitur `bluetooth` dan `usb.host` ditandai tidak wajib sehingga
aplikasi tetap bisa dipasang di perangkat tanpa Bluetooth/USB OTG.

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

Sinkronisasi hanya aktif untuk akun premium. Alamat layanan sudah tertanam di
build; langkah berikut berjalan otomatis setelah Login Google.

1. Perangkat owner mendaftar dan membagikan kunci toko (key-wrap bertanda
   tangan).
2. Perangkat lain menerima key-wrap dan memverifikasi tanda tangan kunci
   owner yang dipin.
3. Delta dikirim terenkripsi; penerapan delta + `applied_deltas` dalam satu
   transaksi. Amplop rusak dicatat di `sync_conflicts` dan tidak menghentikan
   sinkronisasi. Pengirim tak dikenal menghentikan kursor sebelum amplop itu.
4. Snapshot/backup memakai `device.nota_prefix` baru setelah restore; seq
   outbox dilanjutkan dari batas tersimpan.
5. Unggah cadangan selalu didahului pemeriksaan kelengkapan. Aplikasi membuka
   satu putaran sinkron berisi semua perangkat tulis toko; setiap perangkat
   harus mengaku sudah menerima data terbaru dan tidak punya antrean lokal.
   Relay menolak snapshot bila masih ada perangkat yang belum sinkron, dan
   pemeriksaan diulang bila data baru masuk. Status "sudah/belum sinkron"
   disimpan di tabel `device_sync_status`.
6. Mode ringkasan mendaftar sebagai perangkat `viewer`, memuat salinan toko,
   dan tidak mengirim transaksi maupun mengunggah cadangan.

### Kontrak layanan pusat (`relay/`)

Kode relay ada di folder `relay/` dan hanya untuk maintainer. Aplikasi
mengharapkan layanan:

- Mengirim `owner_public_key` pada respons claim undangan.
- Menandatangani izin karyawan dengan kunci owner (signer harus sama dengan
  kunci yang dipin), bukan kunci akses lain.
- Mengembalikan `wrapped_key_signature` pada bootstrap.
- Menerbitkan `license_token` (Ed25519 kunci server) pada claim/pairing.
- Menyimpan/meneruskan snapshot dan delta tanpa menerapkan data bisnis.
- Menolak snapshot yang tidak menyertakan putaran sinkron lengkap dan
  memverifikasi tanda tangan perangkat pada metadata snapshot.
- Menjaga kuota follow-up gratis berdasarkan kode arsip database.

## Rencana Play Store shell

APK Play Store direncanakan sebagai cangkang yang mengunduh modul sesuai jalur
login: penuh untuk tanpa akun/Login Google, terbatas per peran untuk karyawan,
dan hanya modul laporan read-only untuk ringkasan. Pengguna menanggung biaya
data karena aplikasi offline; sync hanya untuk premium.

Saat ini layar sudah dibangun malas (hanya layar yang dibuka yang
diinisialisasi), tetapi pemisahan paket unduhan memerlukan Play Feature
Delivery/dynamic feature module atau artifact terpisah. Itu pekerjaan rilis
lanjutan, bukan perilaku yang sudah aktif.
