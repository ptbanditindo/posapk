# Laporan Perbaikan Sinkronisasi Offline-First — Tahap 2

Tanggal: 5 November 2026
Cakupan: `pusatkupos` (Flutter/SQLite-SQLCipher) dan `relay` (Dart/Shelf + PostgreSQL)

Laporan ini menggantikan laporan tahap sebelumnya. Isinya hanya keadaan kode
saat ini: apa yang selesai, apa yang dibatasi, bagaimana skema dan alurnya,
serta hasil pengujian yang benar-benar dijalankan pada tahap ini.

## 1. Ringkasan

Sebelas pekerjaan dikerjakan dalam satu rangkaian: sembilan butir spesifikasi
sinkronisasi dan dua arahan pemilik mengenai persetujuan kasir.

- **Selesai (9 butir spesifikasi):** skema bersih v1, SQLCipher, aturan harga
  minimal, koreksi append-only, jenis transaksi/tahap/preset/izin, estimasi dan
  konversinya, work order dan log status, sinkron terjadwal/batch/retensi/
  rekonsiliasi, serta peran + kode pairing.
- **Selesai (2 arahan pemilik):** saklar persetujuan kasir di bawah modal
  (default mati) dan peran penanggung jawab sebagai penyetuju alternatif.
- **Selesai dengan batasan platform:** SQLCipher hanya aktif di Android, iOS,
  dan macOS. Windows, Linux, dan web memakai SQLite biasa dan menampilkan
  keterangan tersebut di Pengaturan → Keamanan.
- **Tidak ada butir yang dilewati sepenuhnya.**
- **Sudah diuji pada tahap ini.** `flutter analyze` dan `dart analyze` bersih;
  `flutter test` 104 lulus (1 dilewati, yaitu fase peer tanpa konfigurasi);
  `dart test` 25 lulus; `sync_peer_test` 16 dari 16 fase lulus pada relay +
  PostgreSQL yang dibangun ulang dari nol. Uji perangkat fisik tetap belum
  dikerjakan.

Prinsip yang dipertahankan: relay tetap jembatan buta. Relay hanya menyimpan
amplop terenkripsi dan tidak membaca isi transaksi maupun tanggal transaksi.
Tidak ada kompatibilitas data lama karena belum ada pengguna dan database
nyata; skema dimulai bersih pada versi 1.

## 2. Tabel Perubahan per Tugas

| # | Status | File / fungsi utama | Ringkasan perubahan | Catatan |
|---|--------|--------------------|---------------------|---------|
| 1 | Selesai | `pusatkupos/lib/data/schema.dart`; `lib/data/app_database.dart` | Skema bersih v1 tanpa jalur upgrade. Semua tabel yang disinkronkan membawa `sync_id`, `store_id`, `device_id`, `sync_hlc_wall`, `sync_hlc_counter`, `created_at`, `updated_at`, dan `deleted_at`. Database viewer tetap terpisah per owner. | `schemaVersion = 1`. Instalasi lama harus memasang ulang; ini disengaja. |
| 2 | Selesai (Android/iOS/macOS) | `app_database.dart`: `_usesSqlCipher`, `_databasePassword`, `_open`; `pubspec.yaml`: `sqflite_sqlcipher`; `settings_screen.dart` | Database dibuka dengan SQLCipher dan kunci 256-bit acak yang disimpan di SecureStore. Platform tanpa dukungan memakai SQLite biasa dan menampilkan `encryptionNote`. | Kunci tidak pernah ditulis ke database atau log. Windows/Linux/web belum terenkripsi. |
| 3 | Selesai | `lib/data/price_rules.dart`; `app_database.dart`: `createTransaction`, `saveStockItem`, `saveCatalog`; `lib/data/approval_service.dart`; `lib/ui/screens/pos_screen.dart`; `stock_screen.dart`; `store_settings_screen.dart` | Harga modal menjadi batas bawah. Harga jual, modal, dan tarif hanya dapat diubah pemilik. Setiap baris nota dan estimasi menyimpan `harga_jual_terdaftar`, `harga_batas_saat_transaksi`, `harga_final`, `diskon_alokasi`, `alasan_diskon`, dan `disetujui_oleh`. Di bawah modal dicatat di `permission_audits` sebagai `harga_bawah_modal`. Kasir tidak melihat kolom modal. | Saklar owner `approval_below_cost` default mati: kasir bebas menerbitkan nota dan selisih tetap diaudit. |
| 4 | Selesai | `app_database.dart`: `nota_adjustments`; `lib/data/nota_adjustment_service.dart`; `history_screen.dart`; `reports_screen.dart` | Koreksi adalah baris baru yang merujuk `nota_sync_id` asli; nota tidak pernah diubah atau dihapus. Nilai baru divalidasi terhadap total modal baris asli. Izin `koreksi` diperlukan untuk karyawan. | Koreksi ikut disinkronkan sebagai entity `nota_adjustment`. |
| 5 | Selesai | `lib/data/store_settings.dart`; `store_settings_screen.dart`; `pos_screen.dart` | Lima jenis transaksi (`jual_sparepart`, `servis_langsung`, `order_kerja`, `estimasi_saja`, `pelunasan_order`), lima tahap order, tiga preset (`layanan_langsung`, `order_lengkap`, `manual`), izin per peran (`setujui`, `jenis_<tipe>`, `buat_nota`, `ubah_status`, `koreksi`, `diskon`, `void`, `ubah_pengaturan`), dan snapshot mode saat transaksi dibuat (`mode_saat_dibuat_json`). | Preset "layanan langsung" mematikan order kerja dan status pengerjaan. |
| 6 | Selesai | `lib/data/order_service.dart`; `lib/ui/screens/estimates_screen.dart` (baru); `pos_screen.dart` | Estimasi append-only: revisi membuat baris baru dengan `revisi_dari_sync_id` dan `versi + 1`. Estimasi aktif dapat dikonversi menjadi nota; nota menyimpan `estimate_sync_id` dan `total_estimasi_terakhir`. Layar Estimasi menampilkan filter aktif/semua, rincian, status kedaluwarsa, dan konversi ke nota. | Laporan variansi 30 hari ditampilkan di layar Estimasi. |
| 7 | Selesai | `app_database.dart`: `allocateQueueNumber`, `work_orders`, `work_order_status_log`; `order_service.dart`; `lib/ui/screens/orders_screen.dart` (baru) | Order kerja mendapat nomor order dan nomor antrian harian per perangkat. Status memiliki log append-only berisi status, waktu, dan pembuat. Status minimal (`dibuka`, `selesai`, `diambil`, `batal`) dipakai bila tahap status pengerjaan dimatikan. | Owner dapat memaksa transisi di luar alur; perubahan dicatat sebagai konflik. |
| 8 | Selesai | `lib/sync/sync_scheduler.dart`; `sync_service.dart`; `relay/lib/server.dart`; `lib/data/reconciliation_service.dart` | Sinkron otomatis 15 menit (dapat 10–20 menit) dengan jitter, plus saat aplikasi resume/tutup. Outbox dikirim per batch adaptif (`sync.batch_size`, `sync.batch_bytes`). Relay menghapus amplop yang sudah diakui semua perangkat aktif, mengembalikan `used_bytes`/`limit_bytes`/`warning`, dan klien menampilkan peringatan penyimpanan. Ringkasan harian (`day_digests`) dibandingkan antarperangkat; selisih membuat `reconciliation_requests` dan konflik `rekonsiliasi_beda`. | Relay tidak menyimpan tanggal transaksi; rekonsiliasi dihitung dari SQLite masing-masing perangkat. |
| 9 | Selesai | `relay/lib/auth_rules.dart`; `relay/lib/server.dart`; `lib/sync/protocol.dart`; `lib/sync/sync_service.dart`; `lib/data/pairing_service.dart`; `lib/ui/onboarding.dart`; `lib/ui/screens/premium_screen.dart` | `hints_signature` wajib dan diverifikasi relay. Peran dasar (`KASIR`, `MEKANIK`, `KEDUANYA`) ditambah `extra_permissions` membatasi entity yang boleh dikirim karyawan. Kode pairing karyawan enam karakter berlaku 10 menit, sekali pakai; kode pairing perangkat owner berlaku 5–20 menit (default 15). Karyawan dapat mengklaim kode dari layar masuk. | Token enroll 365 hari tidak lagi dipakai untuk alur karyawan. Relay menyimpan dan mengembalikan `entity`, `action`, `entity_id`, dan `hints_signature` agar penerima dapat memverifikasi petunjuk yang ditandatangani. |
| A1 | Selesai | `store_settings.dart`: `approvalBelowCost`; `store_settings_screen.dart` | Saklar "Kasir wajib persetujuan di bawah modal". Default mati: kasir tidak perlu persetujuan untuk menerbitkan nota, dan selisih di bawah modal tetap dicatat sebagai anomali. | Sesuai arahan pemilik; perilaku lama yang selalu meminta persetujuan dihapus. |
| A2 | Selesai | `approval_service.dart`; `store_settings.dart`: `approverMode`, `approverEmployeeSyncId`; `store_settings_screen.dart`; `pos_screen.dart`; `estimates_screen.dart` | Pemilik memilih penyetuju: `owner` (PIN pemilik) atau `penanggung_jawab` (akun karyawan aktif dengan izin `setujui`, diverifikasi PIN/password akun). Bila pengaturan memakai penanggung jawab tetapi belum dipilih, persetujuan ditolak dengan pesan yang jelas. | Kunci percobaan persetujuan memakai `LoginGuard` terpisah per akun. |

## 3. Skema Akhir (versi 1)

Tidak ada migrasi bertahap. `createCleanSchema` membuat seluruh tabel sekaligus
dan `schemaVersion` bernilai 1.

### 3.1 Kelompok tabel

- **Identitas dan akses:** `app_settings`, `owner_identity`, `license`,
  `employee_accounts`, `permission_audits`, `devices`, `login_guards`.
- **Master:** `customers`, `vehicle_or_units`, `stock_items`, `harga_jasa`,
  `suppliers`, `supplier_items`, `supplier_followups`, `followup_items`,
  `followup_events`, `wa_message_logs`.
- **Transaksi:** `service_records`, `service_jobs`, `service_parts`,
  `service_payments`, `stock_movements`, `nota_adjustments`,
  `service_record_mechanics`, `service_record_commissions`, `employee_debts`,
  `salary_payments`.
- **Aturan dan dokumen:** `store_settings`, `estimates`, `estimate_items`,
  `work_orders`, `work_order_status_log`, `document_counters`.
- **Sinkron dan rekonsiliasi:** `sync_outbox`, `sync_inbox`, `sync_cursor`,
  `applied_deltas`, `sync_conflicts`, `device_sync_status`, `day_digests`,
  `reconciliation_requests`, `sync_peer_digests`.

### 3.2 Metadata sinkron

Setiap tabel data yang disinkronkan memiliki `sync_id` unik, `store_id`,
`device_id`, pasangan HLC, timestamp, dan `deleted_at` untuk tombstone. Tabel
infrastruktur sinkron (`sync_outbox`, `sync_inbox`, `applied_deltas`, dan
sejenisnya) memakai kunci idempotensi sendiri, bukan `sync_id` entity.

### 3.3 Kolom penting

- `service_records`: `jenis_transaksi`, `mode_saat_dibuat_json`,
  `work_order_sync_id`, `estimate_sync_id`, `total_estimasi_terakhir`,
  `request_id` unik, status void, dan status pembayaran.
- `service_jobs` / `service_parts` / `estimate_items`: harga terdaftar, batas
  modal saat transaksi, harga final, alokasi diskon, alasan diskon, penyetuju,
  dan interval servis.
- `nota_adjustments`: `nota_sync_id`, `nilai_selisih`, `nilai_baru`, `alasan`,
  `dibuat_oleh`, `disetujui_oleh`.
- `estimates`: `nomor_estimasi`, `versi`, `revisi_dari_sync_id`, `masa_berlaku`,
  `converted_nota_sync_id`, `total_estimasi_terakhir`, `disetujui_oleh`.
- `work_orders`: nomor order, nomor antrian, status, mekanik, waktu masuk,
  snapshot mode, dan referensi nota.
- `store_settings`: jenis transaksi, tahap order, `simpan_estimasi_lepas`,
  `approval_below_cost`, `approver_mode`, `approver_employee_sync_id`,
  `role_permissions_json`, dan preset.

## 4. Alur Akhir

### 4.1 Nota dan harga

1. Kasir memilih jenis transaksi dan barang/jasa. POS memuat daftar barang
   beserta harga jual; harga modal tidak ditampilkan kepada kasir.
2. `PriceRules.allocate` menghitung harga final per baris dan alokasi diskon.
   Harga di bawah modal hanya diterima bila transaksi disetujui, atau bila
   saklar `approval_below_cost` dimatikan.
3. Nota, baris jasa/part, pembayaran, pergerakan stok, audit, dan baris outbox
   ditulis dalam satu transaksi SQLite.

### 4.2 Persetujuan

- `approval_below_cost = true`: karyawan yang menekan tombol simpan menerima
  dialog persetujuan. Mode `owner` meminta PIN pemilik; mode
  `penanggung_jawab` meminta PIN akun yang ditunjuk dan memeriksa izin
  `setujui`.
- `approval_below_cost = false` (default): nota langsung tersimpan. Jika ada
  baris di bawah modal, `permission_audits` mencatat `harga_bawah_modal` beserta
  nomor nota, selisih, dan pembuatnya.
- Diskon di atas batas persen yang dikonfigurasi tetap meminta persetujuan,
  terlepas dari saklar di atas.

### 4.3 Koreksi nota

1. Pengguna membuka nota di Riwayat dan memilih koreksi.
2. Alasan wajib diisi. `NotaAdjustmentService` memvalidasi total baru terhadap
   modal baris asli dan izin `koreksi`.
3. Baris `nota_adjustments` baru ditambahkan; nota asli tidak berubah. Total
   setelah koreksi dihitung dari baris koreksi terakhir.

### 4.4 Estimasi

1. Estimasi disimpan sebagai baris baru. Revisi menaikkan `versi` dan menyimpan
   `revisi_dari_sync_id`; estimasi lama tetap ada.
2. Layar Estimasi menampilkan estimasi aktif/semua, status kedaluwarsa
   berdasarkan `masa_berlaku`, dan nomor nota hasil konversi.
3. Konversi meminta metode bayar dan nominal. `convertEstimateToNote` membuat
   nota order kerja, menautkan `estimate_sync_id`, menandai estimasi
   `converted_nota_sync_id`, dan mengantrekan ketiga entity dalam satu
   transaksi.
4. Selisih antara total nota dan total estimasi terakhir muncul di laporan
   variansi 30 hari dan di dialog rincian estimasi.

### 4.5 Work order

1. Order baru mendapat nomor order dan nomor antrian harian per perangkat
   (`document_counters`, prefix `WK`).
2. Perubahan status selalu menambah baris `work_order_status_log`. Status tidak
   ditimpa.
3. Bila tahap status pengerjaan dimatikan pada snapshot order, daftar status
   menyusut menjadi `dibuka`, `selesai`, `diambil`, `batal`.
4. Owner dapat memaksa transisi di luar alur; perubahan tetap disimpan dan
   dicatat sebagai konflik untuk ditinjau.

### 4.6 Sinkronisasi

1. Scheduler berjalan tiap 15 menit (10–20 menit sesuai pengaturan) dengan
   jitter dan sekali saat aplikasi resume/tutup.
2. Outbox dikirim per batch. Ukuran batch diturunkan saat relay sibuk dan
   dinaikkan kembali saat lancar; batas mengikuti `max_batch` dari relay.
3. Perangkat menarik delta secara berpaginasi. Penerapan delta dan penulisan
   `applied_deltas` berada dalam transaksi yang sama.
4. Relay menghapus amplop yang `relay_seq`-nya sudah diakui semua perangkat
   aktif. Perangkat yang dicabut tidak lagi menahan retensi.
5. Setelah unggah, relay mengembalikan pemakaian penyimpanan. Klien menyimpan
   dan menampilkan peringatan bila batas terlampaui.
6. `ReconciliationService` menerbitkan ringkasan harian. Perangkat yang
   menerima ringkasan berbeda membuat `reconciliation_requests`; pemilik dapat
   melihat daftarnya di kartu Sinkronisasi. Relay tidak perlu tahu tanggal
   transaksi.

### 4.7 Peran dan pairing

1. Peran dasar karyawan ditentukan di server (`KASIR`, `MEKANIK`, `KEDUANYA`)
   dan dapat ditambah `extra_permissions`.
2. Payload delta membawa `entity`/`action` yang ditandatangani pada
   `hints_signature`; relay menolak amplop tanpa tanda tangan itu.
3. Owner membuat kode pairing karyawan di layar Premium → Akses karyawan.
   Kode berlaku 10 menit dan hangus setelah satu perangkat mengklaimnya.
4. Karyawan memilih "Punya kode pairing" di layar masuk. Perangkat membuat
   kunci tanda tangan/enkripsi, mengklaim kode, memverifikasi tanda tangan izin
   dari kunci owner yang dipin, lalu memasang akun dan token perangkat.
5. Perangkat karyawan yang dicabut tidak dapat mengirim amplop lagi.

## 5. Keputusan dan Alasan

- **Saklar persetujuan default mati.** Pemilik menginginkan kasir dapat
  menerbitkan nota tanpa menunggu owner. Keamanan dijaga dengan audit
  `harga_bawah_modal`, bukan dengan memblokir transaksi.
- **Penanggung jawab terpisah dari owner.** PIN owner tidak perlu dibagikan saat
  owner sibuk; akun yang ditunjuk tetap harus aktif dan memiliki izin
  `setujui`, dan percobaan PIN-nya dibatasi `LoginGuard`.
- **Harga disalin ke baris transaksi.** Perubahan harga master di kemudian hari
  tidak mengubah nota lama; laporan dan koreksi memakai batas modal saat
  transaksi terjadi.
- **Koreksi append-only.** Nota final tidak boleh berubah agar sinkronisasi
  tidak menghasilkan konflik tulis dan audit tetap utuh. Total baru selalu
  dapat dihitung ulang dari baris koreksi.
- **Revisi estimasi membuat baris baru.** Riwayat penawaran ke pelanggan tetap
  terlihat dan konversi selalu menunjuk versi yang disetujui.
- **Log status terpisah dari order.** Status order adalah keadaan terkini;
  riwayat tetap append-only agar dua perangkat tidak saling menimpa riwayat.
- **Nomor dokumen per perangkat.** `document_counters` memakai kode perangkat
  dan tanggal, sehingga dua perangkat offline tidak menghasilkan nomor yang
  sama.
- **Rekonsiliasi dihitung lokal.** Relay tidak boleh mengetahui tanggal
  transaksi, jadi ringkasan harian dibuat dari SQLite perangkat dan hanya
  hash/jumlah yang disinkronkan.
- **SQLCipher hanya di platform yang didukung paket.** Memaksa enkripsi di
  Windows/Linux/web akan menggagalkan pembukaan database. Keterbatasan
  ditampilkan di Pengaturan → Keamanan, bukan disembunyikan.
- **Petunjuk wajib ditandatangani.** Tanpa tanda tangan petunjuk, perangkat yang
  dimodifikasi dapat meminta relay memperlakukan payload sebagai entity lain.
  Relay tetap tidak dapat membaca isi amplop; klien memeriksa ulang entity hasil
  dekripsi sebagai otoritas akhir.
- **Kode pairing singkat dan sekali pakai.** Menggantikan token enroll 365 hari
  untuk alur karyawan. Kode owner tetap memakai TTL 5–20 menit agar proses
  pemasangan beberapa perangkat owner tidak terputus di tengah jalan.

## 6. Perubahan Harness dan Pengujian

Harness `sync_peer_test` tetap memakai relay + PostgreSQL khusus dengan satu
proses per fase. Pada tahap ini harness disesuaikan dengan skema dan alur baru:

1. **Token pendaftaran sekali pakai.** Setiap fase yang mendaftarkan perangkat
   (init, A1, B1, V1) meminta token baru ke `/relay/admin/owners` memakai
   Bearer admin, karena token enroll hanya dapat dipakai satu kali.
2. **Kunci lisensi dari relay.** Harness membaca `/relay/health` untuk
   mendapatkan `license_public_key`, lalu meneruskannya sebagai
   `--dart-define=PUSATKU_LICENSE_PUBLIC_KEY`. Tanpa itu token lisensi dari
   relay tidak dapat diverifikasi oleh build uji.
3. **Rahasia antarproses.** `SecureStore` mendapat backend uji berbasis file
   (`SecureStore.testBackend`) yang direktori perangkatnya dipilih dari
   database yang sedang terbuka. Setiap fase proses terpisah membaca kunci dan
   token yang sama, sedangkan fase yang membuka dua database (A4) tidak
   bertukar token perangkat. Backend ini hanya diisi oleh kode test; produksi
   tetap memakai `flutter_secure_storage`.
4. **Petunjuk tersimpan di relay.** Fase B2 menemukan relay memverifikasi
   `hints_signature` tetapi tidak menyimpan `entity`/`action`/`entity_id`,
   sehingga feed kehilangan petunjuk yang ditandatangani. Skema relay
   diperbaiki (kolom baru ditambah `ALTER TABLE ... IF NOT EXISTS`), dan
   `_ingestEnvelope` kini menyimpannya.
5. **Pemeriksaan posisi feed relatif.** `relay_seq` adalah BIGSERIAL global per
   database relay, bukan nomor urut per toko. A4 membandingkan
   `snapshot.store_seq` dengan cursor toko itu sendiri, dan B3 membandingkan
   cursor bootstrap dengan `store_seq` snapshot, sehingga test tetap sah pada
   database relay yang sudah pernah dipakai.
6. **Login pertama hasil pairing.** Fase E1 memeriksa bahwa akun hasil klaim
   kode pairing tidak dipaksa mengganti password (kode pairing adalah
   kredensial pemasangan). Penggantian password tetap diuji setelah login.
7. **Cakupan fase.** Peer test menjalankan init, A1, B1, A2, B2, A3, A4, B3,
   M1, E1, A6, E2, R1, V1, A7, V2: sinkron nota, void, snapshot, key wrap,
   pairing karyawan, penolakan klaim kedua, pencabutan perangkat, dan viewer.
   Estimasi, work order, koreksi, dan rekonsiliasi diuji di
   `stage3_rules_test.dart` (termasuk saklar persetujuan, PIN owner, dan
   penanggung jawab); aturan entity relay diuji di
   `relay/test/auth_rules_test.dart`.

Tidak ada gate produksi yang dilonggarkan untuk test. `tool/smoke.dart` tidak
dijalankan karena memakai database pengembangan dan menunggu konfirmasi.

## 7. Pengujian Sebelum dan Sesudah

### 7.1 Baseline tahap sebelumnya (bukan hasil tahap ini)

Pada tahap sebelumnya, suite dilaporkan sebagai berikut dan menjadi pembanding,
bukan klaim keadaan sekarang:

- `flutter analyze` (pusatkupos): bersih.
- `flutter test` (pusatkupos): 96 test lulus, 1 dilewati (test peer tanpa env).
- `dart analyze` / `dart test` (relay): bersih / 24 test lulus.
- `sync_peer_test`: 16 fase lulus pada relay + PostgreSQL khusus.

### 7.2 Hasil tahap ini

Semua perintah dijalankan pada 5 November 2026 setelah perubahan terakhir.
Relay E2E memakai PostgreSQL `pusatkupos_relay_e2e_stage3` yang dibuat ulang
dari nol dan relay pada port 8120.

- [x] `flutter analyze` (pusatkupos) — **No issues found! (ran in 6.3s)**.
- [x] `flutter test` (pusatkupos) — **104 lulus, 1 dilewati**
  (`01:00 +104 ~1: All tests passed!`). Yang dilewati adalah fase peer tanpa
  `PEER_PHASE`/`PEER_CONFIG`.
- [x] `dart analyze` (relay) — **No issues found!**.
- [x] `dart test` (relay) — **25 lulus** (`00:00 +25: All tests passed!`).
- [x] `sync_peer_test` — **16 dari 16 fase lulus** pada relay + PostgreSQL
  yang dibangun ulang; keluaran akhir `SEMUA FASE MULTI-DEVICE LULUS`.
- [ ] Test perangkat fisik untuk SQLCipher dan printer — belum dijalankan.

Hasil rinci fase peer: A1 menerbitkan nota `TEQZ-N20261105-0001`; A4
`store_seq` 3; B3 memulihkan 2 nota (1 void), stok 9, 2 pembayaran, cursor 3;
E1 mengklaim kode sekali pakai dan klaim kedua ditolak 409; E2 dan V2 menerima
snapshot penuh.

### 7.3 Yang diuji lewat harness dan yang belum

- Harness peer menjalankan alur nyata lewat database dan HTTP: sinkron nota,
  void, snapshot, key wrap, pairing karyawan, pencabutan perangkat, dan
  viewer.
- Aturan peran relay dan aturan bisnis lokal (harga, persetujuan, estimasi,
  order, koreksi, rekonsiliasi) diuji unit dengan database sungguhan.
- Layar Flutter (POS, Estimasi, Order, Riwayat, Premium) belum dijalankan di
  emulator/perangkat pada tahap ini. Klaim tampilan UI belum diverifikasi
  lewat runtime.

## 8. Yang Sengaja Tidak Dikerjakan

1. **Migrasi data lama.** Sesuai instruksi, tidak ada pengguna atau database
   nyata; skema dimulai dari versi 1 tanpa jalur upgrade. Database lama harus
   dipasang ulang.
2. **Sinkron latar sejati.** Timer berhenti saat OS mematikan aplikasi.
   WorkManager/BackgroundTasks tidak ditambahkan.
3. **Enkripsi di Windows/Linux/web.** Paket SQLCipher tidak mendukung platform
   tersebut pada konfigurasi sekarang. Aplikasi menampilkan keterbatasan ini.
4. **Relay membaca isi transaksi.** Relay tetap buta isi. Validasi bisnis,
   harga, dan tanggal hanya terjadi di perangkat.
5. **UI laporan "estimasi belum dikonversi per kasir".** Query
   `unconvertedByCashier` tersedia di service, tetapi belum punya kartu khusus
   di layar Laporan; ringkasan variansi sudah tampil di layar Estimasi.
6. **Uji perangkat fisik.** SQLCipher dan printer thermal belum diuji pada
   perangkat nyata dalam tahap ini.

## 9. Risiko Tersisa

1. **Uji perangkat fisik belum dilakukan.** SQLCipher dan printer thermal baru
   diuji lewat kode dan test unit. Pembuatan database terenkripsi, backup,
   restore, dan rotasi kunci pada Android/iOS/macOS nyata belum dibuktikan.
2. **UI belum dijalankan di emulator.** Perilaku layar (POS, Estimasi, Order,
   Riwayat, Premium) dan dialog persetujuan belum diverifikasi lewat runtime.
3. **Petunjuk terang tetap bisa dipalsukan perangkat yang dimodifikasi.**
   Relay hanya memverifikasi tanda tangan petunjuk, bukan isi ciphertext.
   Pemeriksaan ulang entity di klien adalah otoritas akhir.
4. **Rekonsiliasi bergantung pada jam perangkat.** `tanggal` dihitung dari
   waktu lokal; perangkat dengan tanggal salah akan menghasilkan ringkasan
   yang berbeda dan memicu permintaan rekonsiliasi palsu.
5. **Kebijakan retensi bergantung pada semua perangkat aktif mengakui.**
   Perangkat yang jarang online menahan penghapusan amplop, sehingga
   penyimpanan relay dapat tumbuh sampai batas peringatan.
6. **`relay_seq` bersifat global.** Nomor urut feed berlaku untuk seluruh
   database relay, bukan per toko. Test E2E memakai perbandingan relatif;
   laporan atau alat operasional tidak boleh menganggapnya nomor urut toko.
7. **Rahasia E2E memakai backend file.** Harness peer menyimpan rahasia uji di
   direktori sementara karena setiap fase berjalan sebagai proses terpisah.
   Ini hanya berlaku untuk test; produksi tetap memakai secure storage.
8. **`tool/smoke.dart` belum dijalankan.** Verifikasi pada database
   pengembangan dan perangkat fisik masih diperlukan sebelum rilis.
