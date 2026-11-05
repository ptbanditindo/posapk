# Laporan Perbaikan Sinkronisasi Offline-First — Tahap 2 dan Lanjutan

Tanggal: 5 November 2026
Cakupan: `pusatkupos` (Flutter/SQLite-SQLCipher) dan `relay` (Dart/Shelf + PostgreSQL)

Dokumen ini mencatat pekerjaan yang sudah selesai. Rencana dan butir yang masih
terbuka tidak lagi ditulis di sini; sisa pekerjaan ada di bagian 7.

## 1. Ringkasan

- **Tahap 2 selesai:** skema bersih, SQLCipher, aturan harga dan batas modal,
  koreksi append-only, jenis transaksi/tahap/preset/izin, estimasi dan
  konversinya, work order dan log status, sinkron terjadwal/batch/retensi/
  rekonsiliasi, serta peran dan kode pairing.
- **Tahap lanjutan selesai:** backup multi-toko format 3, retur penjualan
  tingkat baris beserta sinkronisasinya, dan tujuh fitur struk (logo raster,
  WhatsApp, ekspor/impor JSON, pratinjau debounce + validasi inline, jatuh
  tempo + banner pelunasan, diskon per baris, pratinjau 58/80 mm).
- **Skema naik ke versi 2 secara aditif.** Migrasi menambah kolom dan tabel
  retur tanpa menghapus data; database versi 1 tetap dapat dibuka.
- **Relay tetap buta isi.** Relay hanya menyimpan amplop terenkripsi dan tidak
  membaca transaksi, harga, atau tanggal transaksi.
- **Tidak ada dependency baru.** Seluruh fitur memakai paket yang sudah ada.

## 2. Pekerjaan yang sudah selesai

### 2.1 Sinkronisasi dan keamanan (tahap 2)

| Area | Hasil |
|---|---|
| Skema | Skema bersih dengan `sync_id`, `store_id`, `device_id`, pasangan HLC, timestamp, dan tombstone pada semua tabel data. Database viewer terpisah per owner. |
| Enkripsi lokal | SQLCipher dengan kunci acak di SecureStore pada Android/iOS/macOS. Windows/Linux/web memakai SQLite biasa dan menampilkan keterangan di Pengaturan → Keamanan. |
| Harga | Modal menjadi batas bawah mutlak bagi selain pemilik; diskon maksimal sebesar selisih harga jual dan modal; persetujuan tidak dapat membuka batas itu. |
| Persetujuan | Mode penyetuju `owner` (PIN pemilik) atau `penanggung_jawab` (akun aktif dengan izin `setujui`), dengan `LoginGuard` terpisah. Saklar persetujuan diskon default mati. |
| Koreksi nota | Baris `nota_adjustments` baru; nota asli tidak diubah. Total baru divalidasi terhadap modal baris asli. |
| Transaksi | Lima jenis transaksi, lima tahap order, tiga preset, izin per peran, dan snapshot mode saat transaksi dibuat. |
| Estimasi | Revisi append-only dengan `versi + 1` dan `revisi_dari_sync_id`; konversi ke nota menautkan `estimate_sync_id` dan `total_estimasi_terakhir`. |
| Work order | Nomor order dan nomor antrian harian per perangkat; log status append-only; status minimal saat tahap pengerjaan dimatikan. |
| Sinkron | Scheduler 15 menit (10–20 menit) dengan jitter, batch adaptif, retensi berbasis ack semua perangkat, peringatan penyimpanan relay, dan rekonsiliasi ringkasan harian. |
| Relay | Scope token per peran, pengelolaan akun hanya owner, hash password di server, `hints_signature` wajib, cek keanggotaan toko saat bootstrap, dan penolakan entity di luar izin. |
| Penerapan delta | Tri-state apply: delta yang ditolak tidak di-ack; snapshot lama tidak menimpa data yang lebih baru; `applied_deltas` dibersihkan bersama cursor. |
| Sesi | Logout dan pencabutan perangkat menghapus token serta kunci sync; rahasia disimpan per `store_id`. |
| Pairing | Kode karyawan enam karakter, berlaku 10 menit, sekali pakai; akun dipasang dari payload yang ditandatangani. |

### 2.2 Lanjutan (5 November 2026)

| Pekerjaan | Hasil | Berkas utama |
|---|---|---|
| Backup multi-toko | Format arsip 3: `manifest.json` berisi `stores[]`; setiap toko punya payload terenkripsi AES-256-GCM, checksum SHA-256, dan metadata cipher. Restore memvalidasi seluruh payload, membuat safety `.bak`, mengganti berkas secara atomik, membangun ulang registry, lalu membuka toko aktif. Format 1 dan 2 tetap didukung. | `lib/data/backup_service.dart`, `lib/data/store_registry.dart`, `lib/data/app_database.dart`, `lib/data/backup_platform_io.dart` |
| Retur / penjualan neto | Tabel append-only `sale_returns` dan `sale_return_items`; retur per baris dengan sisa jumlah, refund proporsional dari harga neto, pengembalian stok part + `stock_movements`, audit `retur_nota`. Laporan memakai omzet neto, retur jasa/part, dan laba neto. | `lib/data/sale_return_service.dart`, `lib/data/schema.dart`, `lib/data/app_database.dart`, `lib/ui/screens/history_screen.dart`, `lib/ui/screens/reports_screen.dart` |
| Sinkron retur | Payload nota membawa `returns`; penerima membuat `sale_returns`/`sale_return_items`, memetakan stok lewat `stock_sync_id`, dan memakai `sync_id` pergerakan stok deterministik agar kedua sisi konvergen. Tabel retur ikut snapshot dan urutan hapus. | `lib/data/note_sync.dart`, `lib/sync/snapshot_sync.dart` |
| Logo raster struk | Logo file diubah menjadi bitmap 1-bit melalui `dart:ui`, lalu dicetak dengan `GS v 0` sebelum teks. Lebar logo 10–40 mm. Hanya berlaku untuk mode ESC/POS. | `lib/printer/printer_service.dart`, `lib/printer/escpos_builder.dart`, `lib/printer/logo_platform*.dart` |
| WhatsApp | Tombol membuka `https://wa.me/<nomor>?text=...`; nomor dinormalisasi 0/8 → 62 dan teks dipotong 3500 karakter. | `lib/ui/receipt_dialog.dart`, `lib/core/wa_link.dart` |
| Ekspor/impor template | Template v2 diekspor sebagai JSON dan diimpor kembali dengan validasi versi serta `validate()`. | `lib/ui/screens/receipt_settings_screen.dart`, `lib/data/receipt_template.dart` |
| Pratinjau debounce | Input dijadwalkan 300 ms; kesalahan validasi tampil sebagai strip peringatan, `errorText` per label, dan tombol simpan dinonaktifkan. | `lib/ui/screens/receipt_settings_screen.dart` |
| Jatuh tempo + pelunasan | POS meminta jatuh tempo selama masih ada sisa; tanggal disimpan, disinkronkan, dan dicetak. Banner `STRUK PELUNASAN` muncul untuk nota lunas hasil pelunasan order atau dengan lebih dari satu pembayaran. | `lib/ui/screens/pos_screen.dart`, `lib/data/app_database.dart`, `lib/data/note_sync.dart`, `lib/data/receipt_service.dart` |
| Diskon per baris | Setiap baris menyimpan harga terdaftar, harga final, dan alokasi diskon; struk mencetak harga terdaftar × jumlah lalu baris diskon. Harga neto dipakai untuk refund retur dan laporan. | `lib/data/models.dart`, `lib/data/app_database.dart`, `lib/data/receipt_service.dart` |
| Pratinjau 58/80 mm | Dialog struk memakai `SegmentedButton` 58/80 mm dan membangun ulang dokumen sesuai lebar kolom 32/48. | `lib/ui/receipt_dialog.dart` |

## 3. Skema Akhir

### 3.1 Kelompok tabel

- **Identitas dan akses:** `app_settings`, `owner_identity`, `license`,
  `employee_accounts`, `permission_audits`, `devices`, `login_guards`.
- **Master:** `customers`, `vehicle_or_units`, `stock_items`, `harga_jasa`,
  `suppliers`, `supplier_items`, `supplier_followups`, `followup_items`,
  `followup_events`, `wa_message_logs`.
- **Transaksi:** `service_records`, `service_jobs`, `service_parts`,
  `service_payments`, `stock_movements`, `nota_adjustments`,
  `service_record_mechanics`, `service_record_commissions`, `employee_debts`,
  `salary_payments`, `sale_returns`, `sale_return_items`.
- **Aturan dan dokumen:** `store_settings`, `estimates`, `estimate_items`,
  `work_orders`, `work_order_status_log`, `document_counters`.
- **Sinkron dan rekonsiliasi:** `sync_outbox`, `sync_inbox`, `sync_cursor`,
  `applied_deltas`, `sync_conflicts`, `device_sync_status`, `day_digests`,
  `reconciliation_requests`, `sync_peer_digests`.

### 3.2 Tambahan versi 2

- `sale_returns`: `sync_id`, `service_record_id`, `nota_sync_id`, `no_nota`,
  `no_retur`, `total`, `alasan`, `dibuat_oleh`, pasangan HLC, timestamp.
- `sale_return_items`: `sync_id`, `return_id`, `line_type`, `line_sync_id`,
  `deskripsi`, `jumlah`, `harga_satuan`, `subtotal`, `modal_satuan`,
  `stock_item_id`, pasangan HLC, timestamp.
- `service_records.jatuh_tempo` untuk nota dengan sisa pembayaran.
- Migrasi memakai `migrateSchemaV2` + `_addColumnIfMissing` + `createReturnTables`
  dan menaikkan `schemaVersion` menjadi 2.

### 3.3 Kolom penting

- `service_records`: jenis transaksi, snapshot mode, referensi order/estimasi,
  `request_id` unik, status void, status pembayaran, dan jatuh tempo.
- `service_jobs` / `service_parts` / `estimate_items`: harga terdaftar, batas
  modal saat transaksi, harga final, alokasi diskon, alasan diskon, penyetuju.
- `nota_adjustments`: `nota_sync_id`, `nilai_selisih`, `nilai_baru`, `alasan`,
  `dibuat_oleh`, `disetujui_oleh`.
- `estimates`: nomor, versi, `revisi_dari_sync_id`, masa berlaku,
  `converted_nota_sync_id`, total estimasi terakhir.
- `work_orders`: nomor order, nomor antrian, status, mekanik, waktu masuk,
  snapshot mode, dan referensi nota.

## 4. Alur Akhir

### 4.1 Nota dan harga

1. Kasir memilih jenis transaksi dan barang/jasa. Harga modal tidak ditampilkan
   kepada kasir; untuk jasa dari daftar tarif, harga diverifikasi ulang.
2. `PriceRules.allocate` menyimpan harga final dan alokasi diskon per baris.
   Selain pemilik: harga akhir tidak boleh di bawah modal dan total diskon
   tidak boleh melebihi total margin.
3. Pemilik tetap dapat menjual di bawah modal; baris ditandai dan dicatat untuk
   audit.
4. Nota, baris, pembayaran, stok, audit, dan outbox ditulis dalam satu
   transaksi SQLite.

### 4.2 Persetujuan

- Batas modal dan margin tidak dapat dibuka oleh persetujuan siapa pun kecuali
  transaksi yang dibuat pemilik sendiri.
- `approvalDiscount = true`: setiap diskon kasir meminta persetujuan sesuai
  mode penyetuju. `false` (default): diskon sampai margin langsung tersimpan
  dan tetap dicatat di `permission_audits`.

### 4.3 Retur

1. Pengguna membuka nota di Riwayat dan memilih **Retur penjualan**.
2. Dialog menampilkan sisa jumlah per baris (dikurangi retur sebelumnya).
   Jumlah dan alasan divalidasi; minimal satu baris harus dipilih.
3. `SaleReturnService.createReturn` menulis header + item, mengembalikan stok
   part, menambah `stock_movements` bertipe MASUK, dan menulis audit.
4. Nota asli tidak berubah. Laporan mengurangi omzet dan laba dengan nilai
   retur neto.
5. Retur ikut payload sinkronisasi nota sehingga perangkat lain menerima
   header, item, penyesuaian stok, dan pergerakan stok yang sama.

### 4.4 Estimasi dan work order

- Estimasi revisi membuat baris baru; konversi menautkan versi yang disetujui
  dan menampilkan selisih terhadap total estimasi terakhir.
- Perubahan status order selalu menambah baris log; status tidak ditimpa.

### 4.5 Sinkronisasi

1. Scheduler berjalan tiap 15 menit dengan jitter dan saat aplikasi
   resume/tutup.
2. Outbox dikirim per batch adaptif; relay mengembalikan pemakaian penyimpanan.
3. Perangkat menarik delta secara berpaginasi. Penerapan delta dan
   `applied_deltas` berada dalam transaksi yang sama.
4. Relay menghapus amplop yang sudah diakui semua perangkat aktif.
5. Ringkasan harian dibandingkan antarperangkat; selisih membuat permintaan
   rekonsiliasi dan konflik yang dapat ditinjau pemilik.

### 4.6 Backup multi-toko

```text
createBackup
  → daftar toko dari registry
  → ekspor setiap database menjadi plaintext sementara
  → SHA-256 + enkripsi AES-256-GCM per toko
  → ZIP: manifest.json + stores/<n>.db.enc

restoreBackup
  → baca manifest, validasi semua checksum dan header SQLite
  → siapkan salinan aman .bak
  → tulis berkas tujuan (plain atau SQLCipher) secara atomik
  → ganti registry, aktifkan toko dari manifest
  → reset seq/kode perangkat dan wajibkan bootstrap sync
```

Format 1 (database tunggal) dan format 2 (single-store dengan manifest) tetap
memiliki jalur restore.

### 4.7 Peran dan pairing

- Peran dasar `KASIR`, `MEKANIK`, `KEDUANYA` ditambah `extra_permissions`.
- Relay memverifikasi `hints_signature` dan menolak entity di luar izin.
- Kode pairing karyawan sekali pakai; kode owner berlaku 5–20 menit.
- Perangkat karyawan yang dicabut tidak dapat mengirim amplop lagi.

## 5. Keputusan

- **Batas modal dipisahkan dari persetujuan.** Persetujuan tidak boleh menjadi
  jalan pintas untuk menjual di bawah modal.
- **Harga disalin ke baris transaksi.** Perubahan harga master tidak mengubah
  nota lama.
- **Koreksi dan retur append-only.** Nota final tidak berubah sehingga
  sinkronisasi tidak menghasilkan konflik tulis dan audit tetap utuh.
- **Revisi estimasi membuat baris baru.** Riwayat penawaran tetap terlihat.
- **Nomor dokumen per perangkat.** Dua perangkat offline tidak menghasilkan
  nomor yang sama.
- **Rekonsiliasi dihitung lokal.** Relay tidak perlu mengetahui tanggal
  transaksi.
- **Backup multi-toko memakai satu arsip.** Pemilik dapat memindahkan seluruh
  usaha dalam satu berkas; setiap toko tetap memiliki kunci payload sendiri.
- **Retur disinkronkan sebagai bagian nota.** Retur selalu merujuk nota asli dan
  tidak menciptakan dokumen penjualan baru.
- **Struk terstruktur, bukan template bebas.** Pengguna mengedit blok dan label
  agar perataan tidak rusak.

## 6. Pengujian

### 6.1 Hasil tahap 2 (historis)

Dijalankan sebelum sesi lanjutan, dengan SDK Flutter/Dart tersedia:

- `flutter analyze` — bersih.
- `flutter test` — 105 lulus, 2 dilewati (fase peer tanpa konfigurasi dan tes
  login dummy tanpa flag build).
- `dart analyze` (relay) — bersih.
- `dart test` (relay) — 25 lulus.
- `sync_peer_test` — 16 dari 16 fase lulus pada relay + PostgreSQL yang
  dibangun ulang.

### 6.2 Hasil sesi lanjutan (5 November 2026)

Mesin sesi ini tidak memiliki SDK Flutter/Dart dan pemilik melarang pemasangan
dependency, sehingga `dart format`, `flutter analyze`, dan `flutter test` tidak
dijalankan. Verifikasi yang dilakukan bersifat statis:

- Keseimbangan delimiter seluruh `lib/**/*.dart` (143 berkas).
- Penelusuran simbol baru antar-lapis: template struk → service → builder →
  printer → UI; retur → laporan → payload sync → snapshot; backup → registry →
  database.
- Pemeriksaan bahwa format backup 1/2/3 tetap memiliki jalur restore.
- Pemeriksaan bahwa tidak ada dependency baru pada `pubspec.yaml`.

Pengujian perilaku tetap dilakukan pemilik melalui APK atau localhost.

## 7. Yang Belum Dikerjakan

1. **Uji perangkat fisik.** SQLCipher, backup/restore lintas perangkat, dan
   printer thermal belum dijalankan pada perangkat nyata.
2. **Uji UI runtime.** Layar POS, Riwayat/Retur, Laporan, Pengaturan Struk, dan
   dialog struk belum dijalankan di emulator pada sesi ini.
3. **Sinkron latar sejati.** Timer berhenti saat OS mematikan aplikasi;
   WorkManager/BackgroundTasks tidak ditambahkan.
4. **Enkripsi di Windows/Linux/web.** SQLCipher belum aktif di platform
   tersebut; keterbatasan ditampilkan di Pengaturan.
5. **Kartu laporan estimasi per kasir.** Query tersedia, kartu khusus belum ada.

## 8. Risiko Tersisa

1. **Uji perangkat fisik belum dilakukan.** Pembuatan database terenkripsi,
   backup, restore, rotasi kunci, dan cetak thermal pada perangkat nyata belum
   dibuktikan.
2. **UI belum dijalankan pada sesi ini.** Perilaku dialog dan state layar baru
   diverifikasi lewat pembacaan kode, bukan runtime.
3. **Petunjuk terang tetap bisa dipalsukan perangkat yang dimodifikasi.**
   Pemeriksaan ulang entity di klien adalah otoritas akhir.
4. **Rekonsiliasi bergantung pada jam perangkat.** Tanggal salah memicu
   permintaan rekonsiliasi palsu.
5. **Retensi bergantung pada semua perangkat aktif mengakui.** Perangkat yang
   jarang online menahan penghapusan amplop.
6. **`relay_seq` bersifat global.** Nomor urut feed berlaku untuk seluruh
   database relay, bukan per toko.
7. **Rahasia E2E memakai backend file pada harness.** Hanya untuk test;
   produksi memakai secure storage.
8. **Jasa manual tanpa tarif master tidak punya modal acuan.** Gunakan jasa dari
   daftar tarif untuk transaksi yang tunduk pada aturan modal.
9. **Restore multi-toko mengganti registry.** Setelah restore, perangkat wajib
   bootstrap sync dan memakai kode perangkat baru; ini disengaja agar nomor
   dokumen tidak bertabrakan.
