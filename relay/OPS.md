# Operasional Relay PusatkuPOS

Dokumen ini melengkapi [README.md](README.md) untuk menjalankan relay di luar
laptop pengembangan: pemantauan, backup/pemulihan, retensi, TLS, dan rotasi
kredensial.

Relay tidak menyimpan isi transaksi dalam bentuk terbaca. Amplop terenkripsi
per perangkat, sehingga backup PostgreSQL memulihkan antrean dan metadata,
bukan kunci toko. Kunci toko tetap berada di perangkat pemilik.

## 1. Health dan pemantauan

`GET /relay/health` tidak memerlukan token dan mengembalikan JSON:

```json
{
  "ok": true,
  "database": "ok",
  "google_login": true,
  "server_time": "2026-11-09T03:00:00.000Z",
  "uptime_seconds": 86400,
  "active_requests": 1,
  "write_queue": 0,
  "last_latency_ms": 12,
  "envelope_backlog": 120,
  "open_sync_rounds": 0,
  "license_public_key": "..."
}
```

- Status HTTP `200` berarti relay dan PostgreSQL dapat dijangkau.
- Status `503` dengan `"database": "unavailable"` berarti koneksi database
  gagal; periksa service PostgreSQL dan `RELAY_DATABASE_URL`.
- `envelope_backlog` adalah jumlah amplop yang belum dipangkas. Angka yang
  terus naik menandakan ada perangkat yang tidak pernah mengakui antrean
  (`POST /relay/feed/ack`) atau sedang offline lama.
- `open_sync_rounds` yang menumpuk menandakan putaran kelengkapan tidak
  ditutup karena perangkat belum ack.

Contoh pemeriksaan berkala (Task Scheduler/cron):

```powershell
$health = Invoke-RestMethod http://127.0.0.1:8787/relay/health
if (-not $health.ok) { throw "Relay tidak sehat: $($health.database)" }
if ($health.envelope_backlog -gt 50000) {
    Write-Warning "Backlog amplop besar: $($health.envelope_backlog)"
}
```

Log akses ditulis oleh `logRequests()` ke stdout. Arahkan stdout ke berkas
yang dirotasi harian (mis. `systemd`/Task Scheduler), simpan maksimal 30 hari,
dan jangan menyalin header `X-Device-Token`, `Authorization`, atau isi body ke
sistem log pihak ketiga.

## 2. Backup PostgreSQL dan uji restore

Backup memakai `pg_dump` format kustom. Skrip tersedia di
`relay/scripts/backup.ps1` dan membaca `RELAY_DATABASE_URL` dari `relay/.env`
bila parameter tidak diisi.

```powershell
cd relay
.\scripts\backup.ps1 -OutDir D:\backup\pusatkupos -KeepDays 30
```

Skrip menolak dump yang tidak dapat dibaca ulang oleh `pg_restore --list`.
Jadwalkan minimal sekali sehari dan simpan salinan di mesin/disk terpisah.

Uji restore wajib dilakukan sebelum rilis dan sesudah perubahan skema relay:

1. Buat database uji kosong, mis. `pusatkupos_relay_restore`.
2. Jalankan:

   ```powershell
   .\scripts\restore.ps1 -DumpFile D:\backup\pusatkupos\pusatkupos-relay-<stamp>.dump `
     -DatabaseUrl "postgresql://relay:<password>@127.0.0.1:5432/pusatkupos_relay_restore"
   ```

3. Verifikasi jumlah baris tabel inti pada database uji:

   ```sql
   SELECT 'owners' AS tabel, COUNT(*) FROM owners
   UNION ALL SELECT 'devices', COUNT(*) FROM devices
   UNION ALL SELECT 'envelopes', COUNT(*) FROM envelopes
   UNION ALL SELECT 'snapshots', COUNT(*) FROM snapshots
   UNION ALL SELECT 'retention', COUNT(*) FROM retention;
   ```

4. Jalankan relay sementara dengan `RELAY_DATABASE_URL` ke database uji dan
   pastikan `GET /relay/health` mengembalikan `ok: true`.
5. Hapus database uji setelah verifikasi.

Pemulihan darurat ke database produksi:

1. Hentikan relay agar tidak ada penulisan baru.
2. Simpan dump terbaru yang sudah diverifikasi.
3. Jalankan `restore.ps1` dengan `-Force` bila tidak interaktif.
4. Jalankan `dart run bin/relay.dart migrate` untuk memastikan skema terbaru.
5. Nyalakan relay dan periksa health.
6. Minta satu perangkat membuka sinkronisasi; perangkat dengan antrean lokal
   akan mengirim ulang data yang belum tercatat di relay.

## 3. Retensi

- **Amplop**: relay memangkas amplop yang sudah diakui semua perangkat tulis
  pada toko tersebut. Batas `pruned_through` disimpan di tabel `retention` dan
  dikirim ke perangkat, sehingga perangkat yang tertinggal menerima
  `snapshot_required`. Jangan menghapus amplop secara manual tanpa memastikan
  semua perangkat sudah ack.
- **Database aplikasi**: `cleanupSyncHistory()` menghapus outbox terkirim dan
  `applied_deltas` lebih lama dari 90 hari, serta membatasi `applied_deltas`
  maksimal 20.000 baris. Konflik yang sudah selesai tetap tersedia sampai
  dibersihkan lewat layar konflik.
- **Relay**: token pendaftaran kedaluwarsa, undangan kedaluwarsa, dan putaran
  sinkronisasi selesai dipangkas dengan:

  ```powershell
  dart run bin/relay.dart maintenance --days 90
  dart run bin/relay.dart maintenance --days 90 --dry-run
  dart run bin/relay.dart maintenance --days 90 --vacuum
  ```

  `--dry-run` hanya melaporkan jumlah baris. `--vacuum` menjalankan
  `VACUUM ANALYZE` setelah pemangkasan. Jalankan minimal sebulan sekali atau
  setelah musim ramai.

## 4. TLS

Build rilis aplikasi menolak `http://`. Letakkan relay di belakang reverse
proxy TLS; relay tetap mendengarkan HTTP di `127.0.0.1` atau jaringan privat.

Caddy (contoh di `relay/deploy/Caddyfile.example`):

```
relay.contoh.id {
    reverse_proxy 127.0.0.1:8787
    request_body {
        max_size 320MB
    }
}
```

Nginx (contoh di `relay/deploy/nginx.conf.example`) wajib menaikkan
`client_max_body_size` minimal sebesar `RELAY_STORAGE_LIMIT_BYTES` + 8 MB dan
`proxy_read_timeout` untuk unggahan snapshot.

Setelah TLS aktif, arahkan `PUSATKU_SERVICE_URL` aplikasi ke `https://...`.
Jangan pernah meneruskan token perangkat lewat URL.

## 5. Rotasi token dan kunci

| Kredensial | Kapan dirotasi | Langkah |
|---|---|---|
| `RELAY_ADMIN_TOKEN` | Bocor, ganti admin, atau tiap 90 hari | Ganti nilai di `.env`, restart relay, perbarui pemanggil admin API. |
| `enroll_token` | Perangkat baru tidak lagi diperlukan atau token bocor | Buat token baru dengan `dart run bin/relay.dart token --owner-id <ID>`; token lama tetap berlaku sampai kedaluwarsa. Untuk memutus akses, cabut perangkat yang sudah terdaftar. |
| Token perangkat | Perangkat hilang/dicuri | `POST /relay/manage/devices/<id>/revoke`. Token perangkat yang dicabut ditolak pada permintaan berikutnya. |
| Kunci lisensi server | Kunci privat server dicurigai bocor | Ganti kunci di database `server_keys` (hapus baris `name` terkait), jalankan `dart run bin/relay.dart key`, lalu perbarui `PUSATKU_LICENSE_PUBLIC_KEY` pada build aplikasi. Lisensi lama perlu diterbitkan ulang. |
| Kunci owner | Perangkat owner diganti | Terbitkan `owner_public_key` baru, perbarui owner dengan `--force`, lalu pasangkan ulang perangkat. |
| Kunci toko (`key_version`) | Perangkat dicabut/dicuri, atau karyawan keluar dengan salinan kunci | Dari layar Premium owner, tekan **Rotasi kunci toko**. Perangkat aktif menerima kunci baru otomatis pada sinkronisasi berikutnya (atau lewat **Selaraskan akses kunci**). Amplop lama tetap memakai versi kuncinya; relay menyimpan `key_version` per amplop dan menolak key-wrap versi lebih lama dengan `stale_key`. |

Kunci toko tidak dapat dipulihkan dari relay. Pemulihan hanya lewat escrow
owner: frasa 12 kata (Argon2id) dan share admin Shamir 2-dari-3, keduanya
disimpan terpisah dari database aplikasi. Setelah rotasi, perangkat yang
dicabut tidak dapat membaca data baru meskipun masih memegang kunci lama.

Selalu rotasi di jendela pemeliharaan, backup sebelum perubahan, dan simpan
nilai lama sampai semua perangkat terhubung kembali.

## 6. Rate limit yang berlaku

- Login Google: 20 percobaan / 5 menit per alamat IP.
- Login karyawan: 15 percobaan / 5 menit per alamat IP.
- Ubah kata sandi karyawan: 10 percobaan / 10 menit.
- Klaim undangan: 10 percobaan / 10 menit.

Balasan `429` memakai kode `rate_limited`. Jika batas ini terlalu ketat untuk
satu kantor dengan banyak perangkat di balik satu IP NAT, naikkan batas di
`relay/lib/server.dart` dan catat perubahan tersebut.

## 7. Insiden

1. Periksa `/relay/health` dan log stdout.
2. Bila database gagal, hentikan relay, pulihkan PostgreSQL, lalu jalankan
   `migrate`.
3. Bila backlog amplop tinggi, minta setiap perangkat membuka aplikasi dan
   menyelesaikan sinkronisasi; periksa `open_sync_rounds`.
4. Bila token/kunci bocor, rotasi sesuai tabel di atas dan cabut perangkat
   yang tidak dikenal.
5. Setelah insiden, uji restore dari backup terbaru dan catat penyebab serta
   tindakan di log operasional.

## 8. Dua layanan dan dua URL

Sync dan arsip memakai build relay yang sama, tetapi wajib dijalankan sebagai
dua layanan terpisah agar gangguan arsip tidak menghentikan penjualan:

| Layanan | Endpoint | Variabel aplikasi | Isi |
|---|---|---|---|
| Sinkronisasi | `/relay/*` | `PUSATKU_SERVICE_URL` | Amplop, snapshot, lisensi, undangan |
| Arsip | `/archive/*` | `PUSATKU_ARCHIVE_URL` | Ciphertext nota, token indeks, receipt |

- Keduanya wajib `https://` pada build rilis; token perangkat dikirim lewat
  header, bukan URL.
- `PUSATKU_ARCHIVE_URL` boleh menunjuk host/VM berbeda dengan database
  PostgreSQL sendiri. Jangan arahkan ke host yang sama bila tujuannya
  memisahkan risiko kegagalan.
- Relay arsip tidak menyediakan endpoint hapus. Setelah premium berakhir,
  perangkat menerima token baca-saja dan tetap dapat mencari, membuka, serta
  mengekspor arsip.
- Backup arsip terdiri dari dua bagian: baris `archive_documents`/
  `archive_index_tokens` di PostgreSQL dan ciphertext pada direktori objek.
  Keduanya harus dipulihkan bersama; ciphertext tanpa metadata tidak dapat
  dicari, metadata tanpa ciphertext tidak dapat dibuka.

## 9. Snapshot penyedia, offsite, dan RPO/RTO

Durabilitas arsip tidak boleh bergantung pada satu VPS.

1. Aktifkan snapshot harian penyedia untuk VM sync dan VM arsip, retensi
   minimal 7 hari, dan snapshot sebelum perubahan skema.
2. Salin dump PostgreSQL dan direktori ciphertext arsip ke penyimpanan offsite
   (penyedia/region berbeda) minimal sekali sehari.
3. Uji restore triwulanan: pulihkan dump + ciphertext ke mesin uji, jalankan
   `dart run bin/relay.dart migrate`, lalu buka satu nota dari layar arsip
   aplikasi. Catat tanggal, jumlah dokumen, dan hasilnya.
4. Target pemulihan: **RPO ≤ 24 jam** (kehilangan data maksimal satu siklus
   backup) dan **RTO ≤ 4 jam** (layanan arsip dapat dibuka kembali).
5. Simpan salinan kunci lisensi publik dan konfigurasi `.env` di tempat aman
   terpisah; tanpa kunci tersebut receipt arsip tidak dapat diverifikasi.

## 10. CORS dan kuota arsip

- Relay hanya mengirim `Access-Control-Allow-Origin` untuk origin yang terdaftar
  di `RELAY_ALLOWED_ORIGINS` (pisahkan dengan koma). Daftar kosong berarti
  hanya klien native yang dilayani; permintaan preflight dari origin lain
  dibalas `403` dengan kode `origin_denied`. Jangan memakai `*`; autentikasi
  tetap memakai header token dan credential browser tidak diizinkan.
- Kesalahan tak terduga dibalas `500` generik (`internal_error`) tanpa detail
  internal; detail lengkap hanya masuk log server.
- Kuota penyimpanan sync memakai `RELAY_STORAGE_LIMIT_BYTES` per toko dan
  kuota arsip global memakai `RELAY_ARCHIVE_LIMIT_BYTES`. Saat kuota penuh,
  relay membalas `storage_full`/`archive_full`; unggahan arsip ditahan tetapi
  penjualan dan sync tetap berjalan.
- Pantau `envelope_backlog`, ukuran direktori arsip, dan sisa disk VM arsip
  setiap hari. Naikkan kuota hanya setelah kapasitas disk dan backup offsite
  ikut dinaikkan.

## 11. Kebocoran metadata dan blind index

Relay tidak dapat membaca isi transaksi, tetapi tetap melihat metadata
berikut. Anggap semuanya dapat diakses operator relay dan pihak yang
menguasai database:

- ID owner, ID perangkat, nama perangkat, waktu daftar, waktu sinkronisasi
  terakhir, dan status aktif/dicabut.
- `key_version` per perangkat dan per amplop, sehingga relay dapat mengetahui
  kapan rotasi terjadi dan perangkat mana yang belum menerima kunci baru.
- Jumlah, ukuran, dan waktu amplop; `seq` kursor; serta kelompok perangkat yang
  berbagi satu toko. Pola ini dapat memperkirakan volume transaksi per hari.
- Tabel `device_events` mencatat enroll, klaim undangan, key-wrap, dan
  pencabutan beserta aktor perangkat.
- Snapshot dan ciphertext arsip disimpan utuh, termasuk ukurannya.

Arsip memakai blind index: token HMAC-SHA256 dari nilai yang dinormalisasi
(huruf/angka saja, huruf besar), dipisahkan per jenis (`nota`, `nopol`,
`nama`). Relay hanya melihat token buram, bukan nomor nota atau nama pelanggan.
Namun token yang sama selalu menghasilkan nilai yang sama, sehingga relay
dapat melihat bahwa dua dokumen menyebut pelanggan yang sama atau frekuensi
sebuah nama. Mitigasi yang sudah berlaku: kunci indeks diturunkan dari kunci
toko (tidak dikirim ke relay) dan token tidak pernah dikembalikan ke perangkat
lain. Bila ancaman ini penting, rotasi kunci toko dan pisahkan periode arsip.

Jangan menambahkan kolom pencarian plaintext (nama, nopol, nomor nota) ke
relay; semua pencarian harus lewat token blind index.

