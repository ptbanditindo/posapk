# Relay uji PusatkuPOS

Server relay lokal berbasis **Dart + PostgreSQL** untuk menguji sinkronisasi
dua aplikasi PusatkuPOS. Ini bukan relay produksi: tidak ada TLS, pembatasan
rate, atau rotasi kunci otomatis.

## Prasyarat

- PostgreSQL 17 (sudah terpasang di `C:\PostgreSQL\17` pada mesin ini).
- Dart dari Flutter (`C:\Users\sukron\flutter\bin\dart.exe`).

## 1. Siapkan database

Jalankan PowerShell **sebagai Administrator**:

```powershell
$env:PGPASSWORD = "relaypass"
& "C:\PostgreSQL\17\bin\psql.exe" -U postgres -h localhost -c "CREATE ROLE relay LOGIN PASSWORD 'relaypass';"
& "C:\PostgreSQL\17\bin\psql.exe" -U postgres -h localhost -c "CREATE DATABASE pusatkupos_relay OWNER relay;"
```

Jika peran/database sudah ada, lewati perintah yang error.

## 2. Konfigurasi

Salin contoh lalu isi nilainya:

```powershell
cd relay
Copy-Item .env.example .env
notepad .env
```

Isi `.env`:

```
RELAY_HOST=0.0.0.0
RELAY_PORT=8787
RELAY_DATABASE_URL=postgresql://relay:<password>@127.0.0.1:5432/pusatkupos_relay
RELAY_ADMIN_TOKEN=<token-admin-yang-kuat>
RELAY_GOOGLE_CLIENT_ID=<client-id-web-google>
```

`.env` tidak ikut di-commit (sudah ada di `.gitignore`). Relay membaca `.env`
dari direktori kerja, dan variabel environment sistem tetap menang jika diisi.

## 3. Jalankan

```powershell
cd relay
dart pub get
dart run bin/relay.dart migrate
dart run bin/relay.dart key
```

Di laptop ini cukup jalankan skrip yang sudah menyiapkan environment:

```powershell
cd relay
.\start-relay.ps1
```

Relay mendengarkan `0.0.0.0:8787`, jadi bisa diakses sebagai
`http://127.0.0.1:8787` dari laptop dan `http://<IP-LAN>:8787` dari perangkat
lain di jaringan yang sama. PostgreSQL berjalan sebagai service
`postgresql-x64-17` (startup otomatis).

Port masuk hanya dibuka untuk profil jaringan **Private**:

```powershell
netsh advfirewall firewall add rule name="PusatkuPOS Relay 8787" dir=in action=allow protocol=TCP localport=8787 profile=private
```

`key` mencetak `license_public_key`, `dart_define`, dan
`dart_define_from_file`. Salin nilai kuncinya ke `.env` aplikasi:

```powershell
# pusatkupos/.env
PUSATKU_LICENSE_PUBLIC_KEY=<license_public_key>
```

Build/run aplikasi memakai berkas itu, bukan argumen yang di-hardcode:

```powershell
flutter run --dart-define-from-file=.env
flutter build apk --dart-define-from-file=.env
```

Buat owner. Ambil `owner_id` dan `owner_public_key` dari ringkasan owner yang
diekspor aplikasi utama (payload `owner_id` dan `public_key` di file JSON):

```powershell
dart run bin/relay.dart owner --owner-id <OWNER_ID> --public-key <OWNER_PUBLIC_KEY> --days 30 --devices 5
```

Perintah ini mencetak `enroll_token` dan `license_token` untuk pengujian
internal. Alur aplikasi: kaitkan email pembeli ke owner (bagian Login Google),
lalu pilih **Login Google** di aplikasi. Aplikasi tidak pernah meminta alamat
relay atau token kepada pengguna.

Jalankan server:

```powershell
dart run bin/relay.dart serve
```

## 4. Menghubungkan Android

Build release menolak `http://`, dan build debug hanya mengizinkan `http://`
untuk `localhost`/`127.0.0.1`. Karena itu jangan memakai
`http://<IP-LAN>:8787` dari aplikasi: alamat itu ditolak sebelum request
dikirim. Gunakan port-forward USB sehingga relay terlihat sebagai localhost:

```powershell
adb reverse tcp:8787 tcp:8787
```

Lalu bangun aplikasi **debug** dengan
`--dart-define=PUSATKU_SERVICE_URL=http://127.0.0.1:8787` di `.env`.

Untuk akses Wi-Fi tanpa kabel, relay harus berada di belakang TLS (reverse
proxy dengan sertifikat yang dipercaya perangkat). Relay uji ini sengaja tidak
menangani TLS.

## Login Google premium (opsional)

Login Google hanya untuk pemulihan/aktivasi lisensi pelanggan premium. Sesi
aplikasi tetap memakai PIN owner.

1. Buat OAuth client **Web application** di Google Cloud Console, lalu isi
   `RELAY_GOOGLE_CLIENT_ID` dan `PUSATKU_GOOGLE_CLIENT_ID` di aplikasi dengan
   nilai yang sama. Daftarkan juga SHA-1 keystore Android dan client ID
   Android/iOS bila memakai build native.
2. Kaitkan email pembeli ke owner setelah pembelian. Bisa lewat CLI:

   ```powershell
   dart run bin/relay.dart identity --email pembeli@example.com --owner-id <OWNER_ID>
   ```

   Atau lewat admin API (memakai `RELAY_ADMIN_TOKEN`):

   ```powershell
   curl -X POST http://127.0.0.1:8787/relay/admin/identities `
     -H "Authorization: Bearer <RELAY_ADMIN_TOKEN>" `
     -H "Content-Type: application/json" `
     -d "{\"email\":\"pembeli@example.com\",\"owner_id\":\"<OWNER_ID>\"}"
   ```

3. Aplikasi: pilih **Login Google** (fitur penuh) atau **Ringkasan laporan
   toko** (read-only). Relay memverifikasi ID token terhadap JWKS Google
   (`iss`, `aud`, `exp`, `sub`, `email_verified`), lalu menerbitkan
   `license_token`. Endpoint dibatasi 20 percobaan per 5 menit per alamat IP.
4. Mode ringkasan mengelola akun karyawan lewat token owner. Relay
   menandatangani izin akun dengan kunci lisensi server karena perangkat
   ringkasan tidak memegang kunci privat owner; perangkat karyawan menerima
   salah satu dari dua penandatangan tepercaya (owner atau server).

`GET /relay/admin/identities?owner_id=<OWNER_ID>` menampilkan pengaitan yang
ada. Jika email belum terhubung, login ditolak dengan kode
`identity_not_linked`; bila langganan berakhir, kode `license_inactive`.

## Endpoint yang tersedia

- `GET /relay/health`
- `POST /relay/devices` (enroll)
- `POST /relay/keys`
- `POST /relay/envelopes`
- `GET /relay/feed`
- `POST /relay/feed/ack`
- `GET /relay/bootstrap`
- `POST /relay/sync/rounds` (buka putaran kelengkapan)
- `GET /relay/sync/rounds/open`
- `GET /relay/sync/rounds/<id>`
- `POST /relay/sync/rounds/<id>/ack`
- `POST /relay/snapshots` (wajib `round_id` lengkap)
- `GET /relay/devices`
- `POST /relay/invites/claim`
- `GET /relay/permissions/me`
- `GET|POST /relay/manage/accounts`
- `GET|POST /relay/manage/invites`
- `GET /relay/manage/devices`
- `POST /relay/manage/devices/<id>/revoke`
- `POST /relay/auth/google`
- `GET|POST /relay/admin/identities`
- `POST /relay/admin/owners`
- `GET /relay/admin/license-public-key`
- `GET /relay/admin/license-public-key`
- `POST /relay/admin/owners` (header `Authorization: Bearer <RELAY_ADMIN_TOKEN>`)

Relay memverifikasi tanda tangan amplop perangkat dan menolak amplop yang
tidak cocok. Relay juga menolak akun karyawan yang izinnya tidak ditandatangani
kunci identitas owner (`409 owner_signer_required`).

### Gate unggah cadangan

`POST /relay/snapshots` tidak lagi menerima snapshot langsung. Alurnya:

1. Perangkat membuka putaran lewat `POST /relay/sync/rounds`. Relay mencatat
   `latest_seq` dan daftar perangkat tulis saat itu: semua perangkat owner dan
   satu perangkat terbaru per akun karyawan. Perangkat `viewer` dan yang sudah
   dicabut tidak dihitung.
2. Setiap perangkat mengakui putaran lewat ack setelah mengirim antrean lokal
   dan menerima data sampai `latest_seq`. Ack membawa `last_seq` dan
   `pending_count`.
3. Relay menandai putaran lengkap hanya bila semua perangkat tercatat sudah
   ack dengan `last_seq >= latest_seq`, `pending_count = 0`, dan tidak ada data
   baru setelah putaran dibuka. Data baru membuat putaran basi; buka ulang.
4. Snapshot ditolak (`409 incomplete_store` atau `stale_round`) bila putaran
   belum lengkap. Snapshot yang diterima menyimpan `round_id`,
   `device_manifest`, dan `complete = true`.
5. Relay memverifikasi tanda tangan Ed25519 perangkat atas metadata snapshot:
   `store_id`, `device_id`, `checksum`, `store_seq`, `hlc_wall`,
   `hlc_counter`.

Batasannya: gate ini mencegah cadangan tidak lengkap karena perangkat lupa
sinkron, bukan pertahanan terhadap perangkat yang sudah dikuasai penyerang.
Perangkat yang sah tetap memegang kunci toko dan dapat menulis data. Perangkat
hilang harus dicabut lewat `POST /relay/manage/devices/<id>/revoke`; setelah
dicabut, data yang belum terkirim dari perangkat itu tidak akan masuk.

## Batasan yang masih tersisa

- Perangkat ringkasan tidak memegang kunci privat owner. Izin akun yang dibuat
  dari mode ini ditandatangani ulang oleh kunci lisensi server setelah token
  owner diverifikasi. Perangkat yang dibangun tanpa
  `PUSATKU_LICENSE_PUBLIC_KEY` tidak dapat memverifikasi izin tersebut.
- `enroll_token` berlaku 30 hari. Setelah kedaluwarsa, pengguna harus memilih
  Login Google lagi; data lokal tidak hilang.
- Relay uji ini belum menangani TLS, rate limit menyeluruh, atau rotasi kunci.
