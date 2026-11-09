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
