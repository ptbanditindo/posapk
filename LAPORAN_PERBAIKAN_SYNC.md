# Laporan Perbaikan Sinkronisasi Offline-First

Tanggal: 5 November 2026
Cakupan: `pusatkupos` (Flutter/sqflite) dan `relay` (Dart/Shelf + PostgreSQL)

## 1. Ringkasan

Sepuluh item perbaikan telah dikerjakan berurutan. Protokol amplop, format
tanda tangan Ed25519, dan skema server relay tidak diubah secara tidak
kompatibel. Server hanya mendapat tambahan pemeriksaan otorisasi di atas
field yang sudah ada; payload terenkripsi tetap tidak dibuka oleh server.

Hasil keseluruhan:

- **Selesai (8 item):** 1, 2, 3, 4, 5, 6, 7, 9.
- **Selesai dengan batasan (2 item):** 8 (sinkron otomatis hanya saat aplikasi
  hidup/foreground), 10 (SQLCipher belum diaktifkan; rekomendasi dan rencana
  migrasi didokumentasikan).
- **Tidak ada item yang dilewati sepenuhnya.**

Perubahan database naik dari versi 10 ke **versi 11**. Seluruh perubahan skema
bersifat aditif (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN`), sehingga data
lama tidak dihapus atau di-reset.

## 2. Tabel Perubahan per Item

| # | Status | File / fungsi utama | Ringkasan perubahan | Migrasi | Risiko / catatan |
|---|--------|--------------------|---------------------|---------|------------------|
| 1 | Selesai | `pusatkupos/lib/sync/sync_service.dart`: `_syncNow`, `_retryInbox`, `_rememberFailure`, `_upsertConflictForInbox`; `lib/sync/sync_conflict_rules.dart` | Amplop yang gagal diterapkan disimpan di `sync_inbox` (`last_error`, `retry_count`, `next_retry_at`, `status`). Retry memakai backoff eksponensial 1, 2, 4, ... menit (maksimal 8 percobaan). Setelah batas tercapai status menjadi `failed` dan baris konflik dibuat. Cursor tidak maju selama masih ada inbox pending/failed pada urutan tersebut (`blockedSeq`). Kegagalan dependensi seperti unit tanpa pelanggan melempar `RetryableSyncException` sehingga dicoba lagi, bukan dilewati. | Tabel `sync_inbox` + indeks `ix_sync_inbox_due`; kolom `sync_outbox.next_retry_at`; kolom `sync_conflicts.status/retry_count/last_error/inbox_id`. | Inbox yang macet menahan cursor secara sengaja. Pengguna harus menyelesaikan konflik agar sinkronisasi lanjut; ini perilaku yang diharapkan, bukan deadlock diam-diam. |
| 2 | Selesai | `sync_service.dart`: `enqueue`, `enqueueCustomer`, `enqueueUnit`, `enqueueStock`, `enqueueStockDelta`, `enqueueNote*`, `enqueueStockMovement`, `enqueueCatalog`, `enqueueSupplier*`, `enqueueCommission`, `enqueueDebt`, `enqueueSalary`, `enqueueNotePayment`, `_requireCleanBeforeUpload`; pemanggil di `data/note_sync.dart`, `data/supplier_service.dart`, `data/employee_service.dart`, UI pelanggan/stok/jasa/supplier/history | Semua penulisan data yang disinkronkan menerima `DatabaseExecutor? txn`, sehingga perubahan data dan baris outbox ditulis dalam satu transaksi. Jika enqueue gagal, perubahan data ikut rollback (tidak ada data tanpa outbox). Gate unggah tidak lagi hanya memeriksa outbox kosong: inbox pending, inbox gagal, dan konflik pemblokir juga menolak pembuatan cadangan. | Tidak ada skema baru (memakai kolom `sync_outbox` yang sudah ada). | Transaksi lebih lama sedikit karena menghitung `MAX(seq/hlc)` di dalam transaksi. Dampaknya kecil untuk volume POS. |
| 3 | Selesai | `sync_service.dart`: `syncNow`, `_runSync`, `_applyOnce` | `syncNow()` memakai satu future `_inflight` sebagai mutex global: pemanggilan bersamaan mengembalikan hasil yang sama dan tidak menjalankan dua putaran. Pemeriksaan `applied_deltas` dipindahkan **ke dalam transaksi** yang sama dengan penerapan delta. `sync_inbox` memiliki `UNIQUE(envelope_id)` dan `UNIQUE(idempotency_key)` sebagai pertahanan kedua. | `sync_inbox` dari item 1; `applied_deltas` sudah ada. | Mutex hanya berlaku dalam satu proses aplikasi (satu perangkat). Dua perangkat berbeda tetap aman karena idempotensi di level baris. |
| 4 | Selesai | `sync_service.dart`: `enqueueStockMovement`, `_apply` cabang `stock_movement`; `app_database.dart` migrasi `_addSyncIds` | `stock_movements` kini menjadi entity tersendiri dengan `sync_id`, `stock_sync_id`, `record_sync_id`, `jumlah_milli`, dan idempotensi per baris (cek `sync_id` sebelum insert). Stok lokal dihitung dari penjumlahan pergerakan; entity `stock` action `delta` lama tetap didukung agar data lama tidak terhitung dua kali. Snapshot tetap membawa stok akhir yang konsisten. | `stock_movements.sync_id` + unique index (sudah ada sejak migrasi v3, dipastikan idempoten). | Baris movement lama tanpa `sync_id` tidak dikirim ulang; nilainya sudah tercermin pada stok akhir snapshot. |
| 5 | Selesai | `sync_service.dart`: `enqueueCatalog`, `enqueueSupplier`, `enqueueSupplierFollowup`, `enqueueCommission`, `enqueueDebt`, `enqueueSalary`, `_enqueueNoteState`, `enqueueNoteWarranty`, `enqueueNoteTaken`, `enqueueNotePayment`; `_apply` untuk `supplier`, `supplier_followup`, `commission`, `debt`, `salary`, `harga_jasa`, `note` status; tombstone `customer`, `unit`, `stock`, `supplier`, `harga_jasa` | Entity delta diperluas: harga jasa, supplier, follow-up supplier, komisi, hutang, gaji, status klaim garansi, pengambilan unit, dan pembayaran tambahan. Penghapusan memakai `deleted_at` (soft delete) dan dikirim sebagai action `delete`. Pembaruan setelah nota final tidak lagi dianggap duplikat: aksi `warranty`, `taken`, dan `payment` memiliki jalur penerapan sendiri. | Kolom `deleted_at` dan `sync_hlc_wall/sync_hlc_counter` pada 10 tabel master (aditif). | Entitas yang tidak punya jalur delta otomatis memicu snapshot pada putaran unggah; didokumentasikan di bagian 6. |
| 6 | Selesai | `lib/sync/sync_conflict_rules.dart` (baru); `sync_service.dart`: `_remoteWins`, `_recordConflict`, `_apply` cabang `harga_jasa` | Aturan konflik terpusat di `SyncConflictRules`: harga jasa hanya boleh dimenangkan perangkat `owner`; data master lain memakai HLC terbesar yang dibandingkan **saat penerapan**, bukan saat kedatangan. HLC sama mempertahankan versi lokal dan mencatat konflik agar tidak ping-pong. Konflik yang belum selesai disimpan di `sync_conflicts` dengan status `open`/`review`. | Kolom HLC pada tabel master; kolom status konflik. | Perangkat lama dengan HLC (0,0) menerima versi pertama yang datang. Setelah itu HLC normal berlaku. |
| 7 | Selesai | `relay/lib/server.dart`: `_manageAuth`, `_employeeCanSend`, `_submitEnvelope`, `_ack`, seluruh endpoint `_manage*`; `relay/lib/auth_rules.dart`; `pusatkupos/lib/sync/protocol.dart`; `pusatkupos/lib/sync/sync_conflict_rules.dart`; `pusatkupos/lib/sync/sync_service.dart`: `_apply`; `relay/README.md`; `pusatkupos/lib/data/owner_access_api.dart`; `lib/ui/owner_viewer.dart`; `relay/tool/smoke.dart`; `test/owner_access_test.dart`; `test/sync_protocol_test.dart`; `test/sync_apply_test.dart`; `test/sync_peer_test.dart` | Endpoint manajemen tidak lagi memakai enroll token; memakai token perangkat (`X-Device-Token`) milik owner/viewer pada owner yang sama. Enroll token hanya untuk pairing awal. Perangkat `viewer` ditolak (403) saat mengirim amplop. Perangkat `employee` dibatasi berdasarkan entity/action dan izin akun (mis. `harga_jasa` butuh izin `ubah_harga_jasa`, stok butuh `ubah_stok`). Petunjuk `entity`/`action` kini ditandatangani (`hints_signature`) dan relay memverifikasinya; klien memeriksa ulang setelah dekripsi dan menolak entity yang tidak boleh dikirim peran pengirim yang sudah diverifikasi. `ack` memeriksa keanggotaan perangkat pada toko. Respons 401/403 memakai pesan generik tanpa membocorkan detail internal. | Tidak ada perubahan skema relay; `hints_signature` opsional agar perangkat lama tetap kompatibel. | Relay tidak dapat mendekripsi isi amplop, sehingga penolakan sisi klien adalah otoritas akhir. Perangkat yang dimodifikasi masih dapat memalsukan petunjuk; lihat bagian 6.3 dan risiko di bagian 7. |
| 8 | Selesai (batasan foreground) | `lib/sync/sync_scheduler.dart` (baru); `lib/main.dart`; `sync_service.dart`: `status`, `syncNow`, `_runSync`; `lib/ui/screens/premium_screen.dart`; `lib/ui/owner_viewer.dart` | Scheduler tanpa dependensi baru: `Timer.periodic` 2 menit + sinkron saat aplikasi kembali ke foreground. Semua jalur memakai mutex item 3. Kegagalan jaringan dicatat ke `sync.last_error` dan dicoba lagi pada tick berikutnya. Status menampilkan waktu sukses terakhir, jumlah outbox, inbox, konflik/gagal, percobaan terakhir, dan peringatan `stale` bila outbox tertahan lebih dari 24 jam. | Tidak ada. | Timer berhenti saat aplikasi dimatikan OS. Sinkron latar sejati butuh WorkManager/connectivity; sengaja tidak ditambahkan agar tidak menambah dependency besar. |
| 9 | Selesai | `lib/ui/screens/sync_conflicts_screen.dart` (baru); `sync_service.dart`: `conflicts`, `retryConflict`, `ignoreConflict`; `premium_screen.dart`; `owner_viewer.dart` | Layar konflik menampilkan semua jenis (stok negatif, gagal terapkan, tanda tangan, master data) beserta status, alasan, detail JSON, dan aksi **Coba lagi** / **Abaikan**. Tidak ada baris konflik yang dihapus otomatis; aksi abaikan menandai status dan menulis penanda `applied_deltas` agar amplop yang sama tidak diterapkan ulang. | Tidak ada tambahan baru (memakai kolom item 1). | Mengabaikan konflik adalah keputusan pengguna dan tercatat; data konflik tetap tersimpan untuk audit. |
| 10 | Selesai (SQLCipher belum diaktifkan) | `lib/data/session_service.dart`: `saveDeviceToken`; `sync_service.dart`: `configure`, `enrollToken`, `relayDeviceToken`; `lib/data/secure_store.dart`; `lib/ui/owner_viewer.dart` | Token perangkat tidak lagi ditulis polos ke `app_settings`; disimpan di `SecureStore` (Keychain/Keystore) dengan migrasi otomatis dari salinan lama yang kemudian dihapus. Enroll token juga dipindahkan ke `SecureStore` dengan fallback migrasi dari `app_settings`. | Tidak ada perubahan skema; migrasi data dilakukan saat pembacaan pertama. | SQLCipher tidak dipasang. Alasan, rekomendasi, dan rencana migrasi ada di bagian 6. |

## 3. Migrasi Database dan Bukti Keamanan Data

### Perubahan versi

- `AppDatabase.schemaVersion`: **10 → 11** (`pusatkupos/lib/data/app_database.dart:24`).
- `_upgradeV11` (`app_database.dart:464`) hanya melakukan operasi aditif:
  - `CREATE TABLE IF NOT EXISTS sync_inbox (...)`.
  - `CREATE INDEX IF NOT EXISTS ix_sync_inbox_due`.
  - `ALTER TABLE ... ADD COLUMN` untuk `next_retry_at`, `status`,
    `retry_count`, `last_error`, `inbox_id`, `sync_hlc_wall`,
    `sync_hlc_counter`, dan `deleted_at`.
- `_addColumn` memeriksa `PRAGMA table_info` terlebih dahulu, sehingga migrasi
  aman dijalankan ulang dan tidak menggagalkan database yang sudah sebagian
  termigrasi.
- Database baru juga menjalankan `_upgradeV11` pada `_createSchema`, jadi
  instalasi baru dan database lama berakhir pada bentuk yang sama.

### Bukti data lama tidak hilang

- Tidak ada `DROP TABLE`, `DELETE FROM`, atau `UPDATE` yang merusak data pada
  `_upgradeV11`.
- Kolom baru memiliki `DEFAULT` yang aman (`0`, `''`, `'open'`, `NULL`),
  sehingga baris lama tetap valid.
- Token lama di `app_settings` dihapus **setelah** nilainya disalin ke
  `SecureStore` (`enrollToken()` dan `relayDeviceToken()`). Jika `SecureStore`
  gagal, kode melempar error dan salinan lama tidak dihapus.
- Migrasi v10 → v11 diuji pada `test/migration_test.dart` dengan membuat
  database versi terbaru, menurunkan `PRAGMA user_version` ke 10, menghapus
  objek v11, lalu membuka ulang dan memastikan data pengguna tetap ada.

## 4. Dependensi

Tidak ada dependency baru.

- Sinkron otomatis memakai `dart:async` dan `WidgetsBindingObserver`.
- Penyimpanan aman memakai `flutter_secure_storage` yang sudah ada.
- Relay tetap memakai Shelf/PostgreSQL yang sudah ada.

## 5. Perubahan Perilaku yang Terlihat Pengguna

1. **Sinkron tidak lagi diam saat gagal.** Kegagalan muncul di kartu status
   sebagai pesan terakhir dan jumlah konflik. Outbox yang tertahan lebih dari
   24 jam diberi peringatan.
2. **Layar Konflik baru.** Pengguna dapat melihat detail, mencoba lagi, atau
   mengabaikan dengan sadar. Tidak ada penghapusan otomatis.
3. **Upload/cadangan lebih ketat.** Cadangan ditolak selama masih ada outbox,
   inbox tertunda, inbox gagal, atau konflik pemblokir.
4. **Perubahan master lebih tahan urutan.** Harga jasa hanya mengikuti owner;
   data master lain mengikuti HLC, bukan urutan kedatangan.
5. **Penghapusan tersinkron.** Pelanggan/unit/barang/supplier/harga jasa yang
   dihapus di satu perangkat ikut terhapus (soft delete) di perangkat lain.
6. **Nota final tetap final**, tetapi status garansi, pengambilan unit, dan
   pembayaran tambahan tetap tersinkron tanpa dianggap duplikat.
7. **Perangkat ringkasan (viewer)** tetap hanya membaca data toko, tetapi
   dapat memakai endpoint manajemen dengan token perangkatnya sendiri.
8. **Karyawan** tidak dapat mengubah harga jasa atau stok di luar izinnya.
9. **Sinkron otomatis** berjalan tiap 2 menit selama aplikasi aktif dan saat
   aplikasi dibuka kembali.
10. **Token perangkat tidak lagi terlihat di database biasa.**

## 6. Item yang Sengaja Tidak Dikerjakan atau Dibatasi

### 6.1 SQLCipher belum diaktifkan

- **Alasan:** mengganti driver enkripsi penuh membutuhkan dependency besar,
  perubahan inisialisasi database, dan jalur migrasi/backup yang harus diuji
  di perangkat nyata. Melakukannya tanpa itu berisiko merusak database
  pengguna.
- **Rekomendasi:** tambahkan `sqflite_sqlcipher` (atau driver setara) pada
  rilis besar berikutnya, dengan urutan: (1) buat backup terenkripsi dari DB
  lama, (2) buka DB baru dengan kunci perangkat dari `SecureStore`,
  (3) salin seluruh tabel dalam satu transaksi, (4) verifikasi jumlah baris,
  (5) hapus DB lama setelah sukses, (6) sediakan rollback ke DB lama.
- **Yang sudah dilakukan sekarang:** rahasia (token perangkat, enroll token,
  store key) tidak lagi disimpan polos di `app_settings`.

### 6.2 Sinkron latar sejati

Timer berhenti ketika OS mematikan aplikasi. Untuk sinkron latar sejati
diperlukan WorkManager/BackgroundTasks dan izin baterai. Ini sengaja tidak
ditambahkan karena termasuk dependency besar dan di luar cakupan perbaikan
protokol. Saat ini sinkron berjalan saat aplikasi hidup dan saat resume.

### 6.3 Otorisasi karyawan di relay bersifat kasar

Server tidak dapat mendekripsi payload, sehingga pembatasan entity/action
memakai petunjuk `entity`, `action`, dan `entity_id`. Petunjuk itu sekarang
ditandatangani perangkat sebagai `hints_signature` dan diverifikasi relay
(`relay/lib/server.dart:463`), tetapi perangkat yang dimodifikasi tetap dapat
menandatangani petunjuk yang tidak sesuai isi ciphertext. Karena itu klien
memeriksa ulang entity/action hasil dekripsi dan menolak berdasarkan jenis
perangkat pengirim yang sudah diverifikasi (`sync_service.dart:1966`); aturan
itu yang menjadi otoritas akhir dan mencatat konflik bila dilanggar. Klien
belum menerima daftar izin tambahan karyawan dari relay, sehingga `stock` dan
`supplier_followup` dari karyawan mengandalkan pemeriksaan izin di relay.

### 6.4 Enroll token belum one-time

Enroll token sengaja tidak dibuat sekali pakai karena satu token dipakai untuk
memasangkan beberapa perangkat pada toko yang sama. Token tetap berlaku 365
hari dan hanya diterima oleh endpoint `/relay/devices`. Mencabutnya lebih awal
dapat memutus proses pairing yang sedang berjalan.

## 7. Hasil Test

Seluruh test dijalankan pada 5 November 2026 setelah perubahan kode selesai.
Perintah dijalankan dari folder masing-masing.

- [x] `flutter analyze` (pusatkupos) — **No issues found!** (5,3–6,5 detik,
  dijalankan ulang setelah perubahan terakhir)
- [x] `dart analyze` (relay) — **No issues found!**
- [x] `flutter test` (pusatkupos) — **+96 ~1: All tests passed!**
  - Satu test dilewati adalah `test/sync_peer_test.dart` tanpa env
    `PEER_PHASE`/`PEER_CONFIG`; test tersebut dijalankan terpisah di bawah.
  - Jumlah naik dari 93 karena tiga test baru: tanda tangan petunjuk amplop,
    penolakan peran saat apply, dan mutex `syncNow` paralel.
- [x] `dart test` (relay) — **+24: All tests passed!**
  - Termasuk 5 test di `test/auth_rules_test.dart` (viewer ditolak, batas
    entity karyawan, izin harga/stok, aturan follow-up, field petunjuk yang
    ditandatangani).
- [x] `sync_peer_test` — **16 fase lulus** (`init`, `A1`, `B1`, `A2`, `B2`,
  `A3`, `A4`, `B3`, `M1`, `E1`, `A6`, `E2`, `R1`, `V1`, `A7`, `V2`) pada
  relay + PostgreSQL khusus. Fase E1 juga memastikan amplop `salary` dari
  karyawan ditolak `403`, dan fase V1 memastikan amplop `customer` dari
  viewer ditolak `403`.
- [x] `tool/smoke.dart` **tidak dijalankan** (sesuai instruksi; memakai
  database pengembangan).

### Cara menjalankan test peer

Relay dan PostgreSQL dapat dijalankan. Agar urutan `relay_seq` deterministik,
test peer memakai database khusus yang baru untuk setiap putaran; putaran
terakhir memakai `pusatkupos_relay_e2e_run2`, bukan database pengembangan:

1. `createdb -U relay -h 127.0.0.1 -p 55432 pusatkupos_relay_e2e_run2`
2. Jalankan relay dengan `RELAY_PORT=8789` dan
   `RELAY_DATABASE_URL=postgresql://relay@127.0.0.1:55432/pusatkupos_relay_e2e_run2`.
3. Buat owner lewat `dart run bin/relay.dart owner --owner-id <id>
   --public-key <kunci> --days 3650 --stores 10`, lalu masukkan `enroll_token`
   hasilnya ke konfigurasi sesi test.
4. Jalankan tiap fase dengan
   `flutter test test/sync_peer_test.dart
   --dart-define=PEER_PHASE=<fase>
   --dart-define=PEER_CONFIG=<file sesi>
   --dart-define=PUSATKU_LICENSE_PUBLIC_KEY=<kunci relay>`
   dan `PUSATKU_SECURE_DB=true`.

### Catatan perbaikan harness test peer

Empat penyesuaian harness diperlukan agar test mencerminkan aturan produksi
yang baru; tidak ada gate produksi yang dilonggarkan:

1. **A4** — setelah `startUploadCheck()`, perangkat B ikut disinkronkan
   sebelum `uploadSnapshot()`. Putaran unggah mensyaratkan semua perangkat
   sudah sinkron; sebelumnya harness hanya menyinkronkan A.
2. **M1 dan R1** — endpoint manajemen kini memakai `X-Device-Token` milik
   perangkat owner, bukan lagi `X-Relay-Enroll-Token` (item 7). Harness
   disesuaikan dan mengharapkan status `200` dari pembuatan undangan.
3. **V1 dan V2** — fase viewer memasang lisensi uji yang valid sebelum
   mendaftarkan/menyinkronkan perangkat, karena `registerRelayDevice` dan
   `syncNow` memang mensyaratkan lisensi premium. Sebelumnya baris lisensi
   ditulis dengan `token: null` sehingga tidak pernah lolos verifikasi.
4. **E1 dan V1** — ditambah pemeriksaan endpoint nyata: perangkat karyawan
   mengirim amplop `salary` dan perangkat viewer mengirim amplop `customer`
   ke `/relay/envelopes`; keduanya harus ditolak `403`. Probe ini memakai
   amplop bertanda tangan sah, jadi yang diuji adalah otorisasi peran, bukan
   validasi tanda tangan.

### Verifikasi tanda tangan petunjuk dan penegakan peran

Sebelum perbaikan ini, `entity`/`action` yang dipakai relay untuk membatasi
karyawan berada di luar tanda tangan:

- `pusatkupos/lib/sync/protocol.dart` (sebelum perubahan) hanya menandatangani
  field amplop—`store_id`, pengirim, `seq`, HLC, idempotency, ciphertext, dan
  nonce—sedangkan `entity`/`action`/`entity_id` ditempel setelah tanda tangan.
- `relay/lib/server.dart:464-471` (sebelum perubahan) membaca `entity` dan
  `action` dari body lalu memanggil aturan karyawan tanpa memverifikasi bahwa
  petunjuk itu benar-benar ditandatangani perangkat.

Perbaikan yang dilakukan:

1. **Petunjuk ikut ditandatangani.** `buildEnvelope` sekarang menandatangani
   `entity`, `action`, `entity_id`, `store_id`, `sender_device_id`, dan
   `idempotency_key` menjadi `hints_signature`
   (`pusatkupos/lib/sync/protocol.dart:30` dan `:89`). Relay memverifikasinya
   dengan kunci publik perangkat sebelum aturan peran dijalankan
   (`relay/lib/server.dart:448` dan `:463`; field bersama di
   `relay/lib/auth_rules.dart:12`). Perangkat lama yang tidak mengirim
   `hints_signature` tetap diterima agar tidak memutus sinkronisasi yang
   sedang berjalan.
2. **Petunjuk harus cocok dengan isi terenkripsi.** `verifyEnvelope` menolak
   amplop bila `entity`/`action`/`entity_id` terang berbeda dari nilai di
   dalam ciphertext (`pusatkupos/lib/sync/protocol.dart:142-181`).
3. **Klien menolak berdasarkan peran pengirim terverifikasi.** Identitas
   pengirim berasal dari `sender_device_id` yang ditandatangani dan kunci
   publik perangkat dari relay; jenis perangkat diambil dari daftar perangkat
   relay (`sync_service.dart:1902`). `_apply` memanggil
   `SyncConflictRules.senderViolation`
   (`pusatkupos/lib/sync/sync_service.dart:1966`; aturan di
   `pusatkupos/lib/sync/sync_conflict_rules.dart:43`) sebelum menulis data:
   - `viewer`: semua amplop ditolak (`peran_viewer_hanya_baca`).
   - `harga_jasa`: hanya `owner` (`harga_dikunci_owner`).
   - `employee`: hanya `nota`, `customer`, `unit`, `stock`, `stock_movement`,
     dan `supplier_followup`; entity lain seperti `supplier`, `commission`,
     `debt`, dan `salary` ditolak (`peran_tidak_berhak`).
   Penolakan dicatat di `sync_conflicts`, bukan dihapus diam-diam.

**Risiko tersisa:** relay tetap tidak dapat mendekripsi isi amplop. Perangkat
yang dimodifikasi masih dapat menandatangani petunjuk palsu; karena itu
penolakan di sisi klien (langkah 3) adalah otoritas akhir. Klien juga tidak
menerima daftar izin tambahan karyawan dari relay, sehingga `stock` dan
`supplier_followup` dari karyawan diizinkan di sisi apply dan mengandalkan
pemeriksaan izin relay. Test baru menutup kasus viewer, harga jasa, dan entity
owner-only; bukan seluruh kombinasi izin tambahan.

### Ringkasan hasil per skenario wajib

| Skenario | Test | Hasil |
|----------|------|-------|
| Gagal apply tidak memajukan cursor + backoff + batas percobaan | `test/sync_apply_test.dart` (kasus inbox/backoff) | Lulus: cursor tertahan di seq 7, `retry_count` naik, `next_retry_at` maju, status `failed` setelah batas |
| Crash di tengah tulis tetap menyisakan outbox | `test/sync_apply_test.dart` (rollback + reopen) | Lulus: enqueue gagal me-rollback data; outbox bertahan setelah `db.reopen()` |
| Dua sinkron paralel tidak menggandakan stok | `test/sync_apply_test.dart` (stock_movement paralel) | Lulus: penerapan kedua mengembalikan `false`, stok tetap 7000, satu baris movement |
| Dua `syncNow` paralel memakai satu putaran | `test/sync_apply_test.dart` (mutex) | Lulus: dua future identik, tidak ada putaran ganda |
| `stock_movements` idempoten per baris | `test/sync_apply_test.dart` | Lulus |
| Tombstone pelanggan (hapus/merge) | `test/sync_apply_test.dart` | Lulus: upsert basi ditolak dan dicatat `versi_lokal_lebih_baru` |
| Aturan konflik HLC dan harga owner | `test/sync_apply_test.dart` | Lulus: karyawan ditolak (`harga_dikunci_owner`), HLC 200 menang, HLC 50 diabaikan |
| Petunjuk `entity`/`action` ditandatangani dan tidak dapat diubah | `test/sync_protocol_test.dart` | Lulus: `hints_signature` wajib cocok; amplop lama tanpa petunjuk tetap diterima |
| Apply menolak viewer dan entity non-operasional karyawan | `test/sync_apply_test.dart` | Lulus: viewer `customer` dan karyawan `salary` ditolak + konflik; karyawan `customer` diterima |
| Relay menolak viewer dan membatasi karyawan | `relay/test/auth_rules_test.dart` (5 test) + probe endpoint E1/V1 | Lulus: unit test aturan dan HTTP `403` nyata dari relay |
| Idempotensi/dedupe amplop relay | fase peer `A2`/`A3` (amplop yang sama tidak diterapkan dua kali) | Lulus |
| Migrasi v10 → v11 menjaga data | `test/migration_test.dart` | Lulus |
| Skenario peer end-to-end (pairing, sync, void, snapshot, bootstrap, karyawan, viewer, revoke) | `test/sync_peer_test.dart` 16 fase | Lulus |

Tidak ada test yang dihapus atau dilemahkan. Kegagalan yang muncul selama
pengujian diperbaiki di kode produksi (perilaku void, hapus follow-up
supplier, deteksi duplikat nota) atau di harness (poin 1–4 di atas), lalu
seluruh suite dijalankan ulang.

### Risiko yang tersisa

1. **Perangkat lama tanpa `hints_signature`.** Amplop lama tetap diterima.
   Relay tidak dapat memaksa tanda tangan petunjuk untuk perangkat yang belum
   diperbarui; penolakan sisi klien tetap berlaku karena memakai entity hasil
   dekripsi.
2. **Izin tambahan karyawan tidak diketahui klien.** Daftar perangkat relay
   tidak membawa `role_base`/`extra_permissions`, sehingga klien hanya menolak
   entity owner-only dan viewer. `stock` dan `supplier_followup` dari karyawan
   masih bergantung pada gate relay.
3. **Test peer tidak otomatis.** `sync_peer_test` memerlukan relay,
   PostgreSQL, database khusus, dan kunci lisensi relay; test ini tidak ikut
   berjalan pada `flutter test` biasa.
4. **SQLCipher belum aktif** dan **sinkron latar sejati belum ada** (lihat
   6.1 dan 6.2).
5. **`tool/smoke.dart` belum dijalankan** karena memakai database
   pengembangan; verifikasi pada perangkat fisik masih diperlukan.
