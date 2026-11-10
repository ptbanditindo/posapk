# PusatkuPOS

PusatkuPOS adalah aplikasi kasir, servis, stok, dan pembukuan untuk bengkel
radiator/servis mobil. Aplikasi ditulis dengan Flutter dan bekerja
**offline-first**: setiap toko memiliki database SQLite lokal sendiri, sedangkan
internet hanya dipakai untuk layanan opsional seperti login Google premium,
lisensi, sinkronisasi terenkripsi, arsip dokumen, kuota follow-up, dan backup
Telegram.

Repo ini berisi dua bagian:

| Folder | Isi |
|---|---|
| [`pusatkupos/`](pusatkupos/) | Aplikasi Flutter. Target utama Android; Windows dan web tersedia untuk pengembangan; kode iOS/macOS/Linux ada tetapi folder platformnya belum disertakan. |
| [`relay/`](relay/) | Layanan pusat berbasis Dart + PostgreSQL untuk lisensi, akun, sinkronisasi E2EE, dan arsip. Dijalankan oleh maintainer, bukan oleh toko. |

## Empat jalur masuk

| Jalur | Untuk siapa | Hak akses |
|---|---|---|
| **Mulai gratis tanpa akun** | Pemilik toko tanpa akun | Seluruh kasir dan pembukuan lokal, 1 toko, kuota 20 kredit follow-up WhatsApp. |
| **Masuk dengan Google** | Pemilik premium | Kasir penuh, lisensi per toko, sinkronisasi, dan multi-toko sesuai `store_limit` lisensi. |
| **Masuk karyawan** | Kasir/mekanik | Hanya menu dan aksi yang diizinkan pemilik; memakai ID pemilik, nama pengguna, dan password. |
| **Ringkasan laporan toko** | Pemilik yang sudah masuk Google | Database salinan terpisah dan **hanya-baca**: ringkasan, riwayat, laporan, muat salinan cadangan, serta kelola akun dan perangkat. Tidak ada kasir, stok masuk, pengeditan nota, atau unggah cadangan. |

Mode ringkasan membuka `pusatkupos_viewer_<owner>.db` (atau `viewer_<owner>.db`
di desktop) sebagai database baca-saja pada level koneksi. Perangkat ringkasan
mendaftar sebagai perangkat `viewer`, tidak mengirim transaksi, dan tidak
mengunggah cadangan.

## Fitur aplikasi

Menu utama: **Ringkasan, Kasir, Riwayat, Pelanggan, Stok, Order, Jasa, Laporan,
Supplier dan reseller, Pengingat pelanggan, Karyawan, Pengaturan, Premium**.
Menu Order, Supplier dan reseller, serta Pengingat pelanggan dapat
disembunyikan lewat saklar fitur per toko. Karyawan hanya melihat menu yang
diizinkan untuk akunnya.

- **Kasir dan nota**
  - Nota berisi jasa dan sparepart, diskon tingkat nota, PPN eksklusif/inklusif,
    pembayaran tunai atau transfer, bayar sebagian, piutang, dan kredit penuh
    tanpa pembayaran awal.
  - Kredit hanya untuk peran dengan izin `beri_kredit`; sisa bayar wajib punya
    jatuh tempo. Diskon non-pemilik dibatasi oleh harga modal.
  - Retur penjualan mengembalikan stok dan kas secara inkremental; void dan
    pembatalan retur dicatat di audit. Nota dengan retur aktif tidak dapat
    di-void.
  - Estimasi dapat dicatat sebagai perkiraan biaya tanpa dihitung sebagai
    penjualan (fitur opsional).
- **Pelanggan dan pengingat**
  - Nomor HP dinormalisasi (`08…`/`+62…`), ada peringatan duplikat, gabung
    pelanggan, serta penanda izin WhatsApp/jangan dihubungi.
  - Pengingat pelanggan mencakup prospek, servis berkala, garansi, piutang, dan
    unit selesai. Pesan WhatsApp memakai format bergaya struk dan dapat dibuka
    per pelanggan atau per kelompok pengingat sejenis.
  - Kuota gratis 20 kredit WhatsApp; premium tanpa batas.
- **Stok dan pembelian**
  - Stok masuk, stok keluar manual (rusak/dipakai sendiri), opname, koreksi,
    dan riwayat mutasi. Saldo, HPP rata-rata, dan nilai persediaan berasal dari
    satu ledger stok.
  - Kuantitas disimpan dalam milli-unit sehingga liter/meter dapat memakai 1–3
    desimal tanpa kehilangan presisi.
  - Supplier, nota pembelian, stok masuk dari pembelian, pembayaran utang,
    retur pembelian, dan aging utang (fitur opsional, pembelian bergantung pada
    supplier).
- **Laporan dan keuangan**
  - Omzet sebelum/sesudah retur, laba kotor part, uang masuk, piutang, kas per
    metode pembayaran, transaksi di bawah harga patokan, koreksi nota, margin
    per barang, nilai persediaan, dan saldo awal.
  - PPN per nota menyimpan snapshot DPP/PPN; pembayaran PPN tercatat dan rekap
    PPN memperhitungkan retur.
  - Tutup buku bulanan menyimpan snapshot periode yang tidak ikut berubah saat
    data lama dikoreksi.
- **Karyawan dan izin**
  - Akun karyawan memiliki peran dan izin eksplisit: void, retur, ubah harga
    jasa, ubah stok, stok masuk/keluar, opname, diskon, beri kredit, lihat/cetak
    laporan, backup, pembelian, bayar utang, bayar gaji, ubah supplier, dan
    kelola akun. Pemilik selalu memiliki seluruh izin; mode ringkasan selalu
    baca-saja.
  - Gaji mendukung pokok, komisi barang/jasa (persen atau nominal), periode
    mingguan/bulanan, pencatatan pembayar, dan audit.
- **Multi-toko dan perangkat**
  - Toko aktif dapat diganti dari menu; perpindahan diserialkan dan menunggu
    sinkronisasi idle.
  - Penambahan toko memerlukan premium, akun Google pemilik, dan sisa
    `store_limit` pada lisensi.
  - Perangkat karyawan dapat didaftarkan, diberi token sekali tampil, dan
    dicabut lewat menu Premium/Akses.
- **Printer**
  - ESC/POS 58 mm (32 kolom) atau 80 mm (48 kolom), maksimal 8 printer dengan
    satu printer utama.
  - Transport: Bluetooth Classic (SPP), Bluetooth LE (GATT), Wi-Fi/LAN port
    9100 + pencarian NSD, USB OTG (BULK OUT), cetak sistem Android, dan dialog
    browser.
  - Konfigurasi printer disimpan di `printer_config.json` terpisah sehingga
    tidak ikut backup atau sinkronisasi.
- **Backup dan pemulihan**
  - Backup lokal berupa `pusatkupos_<waktu>.zip`, mendukung banyak toko,
    dienkripsi AES-256-GCM dengan kunci PBKDF2-HMAC-SHA256.
  - Backup otomatis harian (jam dapat diatur), passphrase otomatis yang dapat
    ditampilkan pemilik, dan opsi unggah ke Telegram.
  - Restore memvalidasi versi skema, kontrak, checksum, identitas pemilik, dan
    antrean data yang belum terkirim sebelum mengganti database secara atomik.
    Database rusak dikarantina, bukan dihapus.
- **Arsip dokumen**
  - Nota dan dokumen diarsipkan ke layanan arsip dengan token indeks HMAC.
    Arsip adalah layanan tambahan untuk premium; kegagalan arsip tidak
    menggagalkan penjualan. Pencarian dan ekspor arsip tersedia dari aplikasi.

## Premium dan lisensi

- Aplikasi **tidak memiliki tombol atau flag build untuk membuka premium**.
  Status premium hanya berasal dari token lisensi yang ditandatangani server
  (Ed25519) dan diverifikasi memakai kunci publik yang ditanam saat build.
- Lisensi dapat dipasang lewat **Login Google** atau dengan menempel token
  lisensi server. Menambah toko memerlukan akun Google pemilik.
- Token membawa `plan`, status aktif, masa berlaku, dan `store_limit`; lisensi
  dihitung per toko.
- Tanpa lisensi: kasir tetap berjalan offline, 1 toko, kuota follow-up 20.
  Sinkronisasi, arsip, dan multi-toko memerlukan premium.
- Saat lisensi kedaluwarsa, data dan kasir lokal tetap dapat dipakai; hanya
  sinkronisasi dan multi-toko yang berhenti sampai lisensi diperbarui.
- Pemulihan akses memakai kode pemulihan pemilik (PBKDF2) untuk meminta token
  baru ke penerbit lisensi.

## Sinkronisasi dan keamanan data

Sinkronisasi hanya aktif untuk premium dan memerlukan alamat layanan yang
ditanam saat build. Alur intinya:

1. Perangkat pemilik mendaftar ke relay dan membagikan kunci toko dalam
   key-wrap bertanda tangan.
2. Perangkat lain menerima key-wrap dan memverifikasi tanda tangan kunci
   pemilik yang dipin (TOFU). Izin karyawan dan snapshot juga diverifikasi
   terhadap kunci yang dipin.
3. Delta dikirim dalam amplop terenkripsi: pertukaran kunci X25519, tanda
   tangan Ed25519, dan JSON kanonik. Protokol v2 membawa `key_version` agar
   rotasi kunci memilih kunci yang benar.
4. Penerapan delta dan pencatatan `applied_deltas` berjalan dalam satu
   transaksi. Amplop rusak dicatat di `sync_conflicts`; pengirim tak dikenal
   menghentikan kursor sebelum amplop tersebut.
5. Unggah snapshot didahului putaran sinkron: semua perangkat tulis toko harus
   mengaku sudah menerima data terbaru dan tidak memiliki antrean lokal. Relay
   menolak snapshot bila masih ada perangkat yang belum sinkron. Status per
   perangkat disimpan di `device_sync_status`.
6. Kunci privat perangkat/pemilik hanya ada di secure storage. Snapshot
   mengecualikan pengaturan `secure.*`.

Mode ringkasan memakai kunci dan database terpisah, hanya-baca, dan tidak
pernah mengirim transaksi maupun mengunggah cadangan.

## Platform dan enkripsi database

| Platform | Status | Database | Catatan |
|---|---|---|---|
| Android | Target utama | SQLCipher | Kunci database 256-bit dibuat acak dan disimpan di secure storage; printer Bluetooth/USB; APK rilis. |
| Windows | Desktop/pengembangan | SQLite FFI | Tidak terenkripsi; lindungi folder data dengan BitLocker/EFS dan ACL pengguna. |
| Web | Pengembangan | SQLite FFI web | Tidak terenkripsi; secure storage terbatas; bukan untuk data produksi. |
| iOS/macOS | Kode tersedia | SQLCipher | Folder platform belum dikonfigurasi di repo. |
| Linux | Kode tersedia | SQLite FFI | Tidak terenkripsi; gunakan LUKS dan ACL; folder platform belum dikonfigurasi. |

Database lokal hanya dienkripsi SQLCipher di Android/iOS/macOS. Di platform
lain, enkripsi volume dan pembatasan akses folder adalah tanggung jawab
operator. WAL dan `busy_timeout` aktif agar backup/sinkronisasi tidak membuat
layar kasir menerima pesan "database is locked" mentah.

PIN pemilik baru minimal 6 digit dan disimpan sebagai PBKDF2-HMAC-SHA256
600.000 iterasi di secure storage, bukan di database. PIN lama 4 digit masih
diterima saat login lalu dimigrasikan. Percobaan PIN dan login perangkat dibatasi
oleh `login_guards`.

## Struktur kode

```text
pusatkupos/
  lib/
    auth/       operator dan katalog izin
    core/       konfigurasi build, uang, kuantitas, URL relay, startup
    data/       database, skema, service domain, backup, lisensi, PIN
    sync/       protokol, kripto, relay client, scheduler, arsip
    printer/    ESC/POS dan transport printer
    state/      AppState
    ui/         onboarding, shell, layar, widget
  test/         21 berkas uji (SQLite in-memory di Dart VM)
  android/      target rilis
  windows/      target desktop
  web/          target pengembangan
relay/
  bin/relay.dart   CLI (migrate, key, owner, seed-demo, identity,
                   license, token, maintenance, serve)
  lib/             server, auth, lisensi, protokol, PostgreSQL
  tool/            uji end-to-end dan pembuat data demo
```

## Build aplikasi

Prasyarat: Flutter 3.47.9 (Dart 3.13.7), JDK 17, Android SDK 36 +
build-tools 36. Untuk relay: PostgreSQL dan Dart dari Flutter.

```bash
cd pusatkupos
cp .env.example .env    # PowerShell: Copy-Item .env.example .env
flutter pub get
flutter analyze
flutter run --dart-define-from-file=.env
```

Build APK debug:

```bash
flutter build apk --debug \
  --dart-define-from-file=.env \
  --dart-define=PUSATKU_SERVICE_URL=https://relay.contoh.id
```

Hasil: `pusatkupos/build/app/outputs/flutter-apk/app-debug.apk`.

Keterangan konfigurasi build:

- `.env.example` berisi `PUSATKU_LICENSE_PUBLIC_KEY` dan
  `PUSATKU_GOOGLE_CLIENT_ID`. Kunci publik lisensi ditampilkan oleh
  `dart run bin/relay.dart key` di folder relay.
- `PUSATKU_SERVICE_URL` adalah alamat relay dan **tidak pernah** diminta ke
  pengguna. `PUSATKU_ARCHIVE_URL` opsional; bila kosong, arsip memakai relay
  yang sama.
- `PUSATKU_GOOGLE_CLIENT_ID` harus memakai OAuth client tipe **Web
  application** dengan nilai yang sama seperti `RELAY_GOOGLE_CLIENT_ID` di
  relay. Bila kosong, jalur Login Google menampilkan pesan belum tersedia.
- `APP_VERSION` dapat ditimpa saat build; nilai bawaan `1.0.0+1`.
- Alamat relay wajib `https://`; `http://` hanya diterima untuk
  localhost/loopback. Build release Android memakai
  `usesCleartextTraffic=false`, sedangkan manifest debug mengizinkan
  clear-text untuk relay localhost.

### Build release

Release tidak pernah memakai debug key. Buat `android/key.properties`:

```properties
storeFile=../keystore/pusatku.jks
storePassword=...
keyAlias=pusatku
keyPassword=...
```

Tanpa berkas itu, `assembleRelease`/`bundleRelease` gagal dengan pesan yang
menjelaskan keystore yang kurang. Manifest release memakai `INTERNET`,
`allowBackup=false`, dan `usesCleartextTraffic=false`; manifest debug
mengizinkan clear-text untuk relay localhost. Izin Bluetooth/USB ditandai
tidak wajib agar aplikasi tetap dapat dipasang di perangkat tanpa Bluetooth
atau USB OTG.

## Menjalankan relay

Relay adalah layanan internal untuk maintainer. Petunjuk lengkap ada di
[`relay/README.md`](relay/README.md), operasi produksi di
[`relay/OPS.md`](relay/OPS.md).

```bash
cd relay
cp .env.example .env    # isi RELAY_DATABASE_URL dan RELAY_ADMIN_TOKEN
dart run bin/relay.dart migrate
dart run bin/relay.dart key
dart run bin/relay.dart serve
```

Variabel lingkungan utama: `RELAY_DATABASE_URL`, `RELAY_ADMIN_TOKEN`,
`RELAY_HOST`, `RELAY_PORT`, `RELAY_GOOGLE_CLIENT_ID`,
`RELAY_ALLOWED_ORIGINS`, `RELAY_MIN_PROTOCOL`, `RELAY_STORAGE_LIMIT_BYTES`,
`RELAY_STORAGE_WARN_RATIO`, `RELAY_DEVICE_ACTIVE_DAYS`, dan
`RELAY_ARCHIVE_LIMIT_BYTES`.

Endpoint publik mencakup `/relay/health`, pendaftaran perangkat, pairing,
key-wrap, amplop delta (tunggal/batch), feed dan ack, bootstrap, putaran
sinkron, snapshot, arsip dokumen/pencarian/ekspor, klaim undangan, izin,
manajemen akun/perangkat, login Google/karyawan, kuota follow-up, serta
endpoint admin yang memakai `RELAY_ADMIN_TOKEN`. Daftar lengkap dan aturan
otorisasinya ada di [`relay/README.md`](relay/README.md).

## Pengujian

```bash
cd pusatkupos
flutter test
```

Tes berjalan di Dart VM dengan SQLite in-memory (`test/support/test_database.dart`)
dan tidak menyentuh database pengguna. Cakupannya mencakup alur penjualan,
kredit, retur, ledger stok, keuangan/pajak, fitur opsional, sinkronisasi,
backup, keamanan sesi, dan diagnostik.

## Keamanan operasional

- Jangan commit `.env`, token admin, private key, keystore, atau file APK.
- Jangan menaruh kunci privat atau kunci publik lisensi di kode atau perintah
  shell; gunakan `.env` yang tidak ikut di-commit.
- Cadangkan kunci/passphrase backup di tempat aman. Tanpa passphrase, arsip
  backup tidak dapat dipulihkan.
- Keluar dari sesi tidak menghapus database toko, antrean keluar, atau kunci
  identitas; pemilik dapat membuka data yang sama lagi dengan PIN perangkat.
  Reset perangkat menghapus database lokal, kunci identitas, dan data yang
  belum terkirim secara permanen, jadi buat backup dan ekspor antrean lebih
  dahulu.
- Perangkat yang hilang harus dicabut lewat menu Akses agar tidak lagi menahan
  unggahan snapshot.

## Dokumen lain

- [`pusatkupos/README.md`](pusatkupos/README.md) — detail aplikasi, izin,
  backup, sinkronisasi, dan catatan rilis.
- [`relay/README.md`](relay/README.md) — setup relay, endpoint, dan otorisasi.
- [`relay/OPS.md`](relay/OPS.md) — pemantauan, backup/pemulihan, TLS, retensi.
- [`RENCANA_PENGEMBANGAN.md`](RENCANA_PENGEMBANGAN.md) — rencana
  pengembangan.
- [`AUDIT_REPORT/`](AUDIT_REPORT/) — hasil audit internal dan roadmap remediasi.
- [`UI_COPY_CATALOG.md`](UI_COPY_CATALOG.md) — katalog teks antarmuka.

Lisensi kode: MIT, lihat [`LICENSE`](LICENSE).
