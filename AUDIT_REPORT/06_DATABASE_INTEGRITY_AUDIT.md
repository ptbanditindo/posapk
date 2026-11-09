# 06 — AUDIT INTEGRITAS DATABASE

**Cakupan:** skema, trigger, index, foreign key, snapshot sinkronisasi, multi-toko, dan konsistensi struktur.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Struktur Skema

### 1.1 Dua fase pembuatan

| Fase | Fungsi | Sifat |
|---|---|---|
| Skema inti | `createCleanSchema` (`schema.dart:17-1623`) | Dibuat saat database baru |
| Skema operasional | `createOperationalSchema` (`schema.dart:1630-2065`) | `CREATE TABLE IF NOT EXISTS`, dipanggil setiap open |

**Implikasi.** Tabel baru dapat ditambahkan tanpa migrasi, tetapi **kolom baru pada tabel lama tidak**. Ini penting untuk DB-02: restore yang memaksa `user_version` terbaru tidak menjalankan `onUpgrade`, dan `createOperationalSchema` hanya menambah tabel, bukan kolom.

### 1.2 Versi skema

- `schemaVersion = 2`.
- `schemaMigrations = {2: _migratePpn}`.
- `.schema_version` sidecar menyimpan versi; `_rejectIncompatibleVersion` menolak database lebih baru.
- `createEncryptedCopy` menulis `PRAGMA user_version = schemaVersion` tanpa membaca versi asal (DB-02).

### 1.3 Klasifikasi tabel

| Kelas | Tabel |
|---|---|
| Identitas/lokal | `app_settings`, `owner_identity`, `license`, `login_guards`, `devices`, `permission_audits` |
| Master | `customers`, `vehicle_or_units`, `stock_items`, `harga_jasa`, `suppliers`, `supplier_items`, `supplier_followups`, `followup_items`, `followup_events`, `wa_message_logs` |
| Nota/penjualan | `service_records`, `service_jobs`, `service_parts`, `service_payments`, `nota_adjustments`, `sale_returns`, `sale_return_items`, `service_record_mechanics`, `service_record_commissions` |
| Kas/keuangan | `cash_ledger`, `employee_debts`, `salary_payments` |
| Persediaan | `stock_movements`, `stock_cost_state`, `opname_holds` |
| Pembelian | `supplier_purchases`, `supplier_purchase_items`, `supplier_payments`, `supplier_purchase_returns`, `supplier_purchase_return_items` |
| Saldo awal/pajak | `opening_balances`, `opening_balance_items`, `pajak_pembayaran`, `debt_reminder_logs` |
| Pengaturan/modul | `store_settings`, `store_features`, `estimates`, `estimate_items`, `work_orders`, `work_order_status_log`, `document_counters` |
| Rekonsiliasi | `day_digests`, `reconciliation_requests` |
| Sync | `sync_outbox`, `sync_inbox`, `sync_cursor`, `applied_deltas`, `sync_conflicts`, `device_sync_status`, `sync_peer_digests` |
| Audit | `business_audits` |

### 1.4 Kekuatan skema

- `sync_id` unik pada hampir semua entitas tersinkron.
- HLC (`sync_hlc_wall`, `sync_hlc_counter`) konsisten.
- `deleted_at` soft-delete untuk master.
- Uang dan qty memakai integer.
- Trigger imutabilitas pada nota, baris nota, retur, dan VOID.
- Unique index parsial untuk kode/barcode aktif, relasi supplier-barang, konflik sync, saldo awal aktif.
- `CHECK` pada nilai non-negatif dan enum penting.
- `cash_ledger` append-only dengan unique source.
- `stock_movements` menyimpan saldo sebelum/sesudah.

**Kesimpulan:** skema lebih baik dari rata-rata aplikasi POS lokal. Cacat terutama pada **jalur pemeliharaan** dan **sinkronisasi/restore**, bukan pada definisi tabel inti.

---

## 2. Trigger dan Integritas Append-Only

| Trigger | Fungsi | Catatan |
|---|---|---|
| `trg_service_records_komponen_immutable` | Melarang perubahan komponen biaya nota | Baik |
| `trg_service_records_void_final` | VOID terminal | Baik |
| `trg_service_jobs_snapshot_immutable` | Snapshot baris jasa final | Baik |
| `trg_service_parts_snapshot_immutable` | Snapshot baris part final | Baik |
| `trg_sale_returns_immutable` | Retur final | **Melarang reversal** (RET-01) |
| `trg_sale_returns_refund_sekali` | Refund hanya sekali | Baik |
| `trg_sale_return_items_immutable` | Baris retur final | Baik |
| `trg_sale_return_items_batas` | Batas qty lintas retur | Baik |
| `trg_purchase_void_final` | VOID pembelian terminal | Baik |
| `trg_purchase_return_batas` | Batas qty retur pembelian | Baik |
| `trg_pajak_pembayaran_void_final` | PPN VOID terminal | Baik |

**Pola yang hilang:**
- Tidak ada trigger yang memelihara `stock_cost_state` saat `stock_movements` berubah.
- Tidak ada trigger yang memastikan `sale_returns.status` aktif pada agregasi.
- Tidak ada trigger yang mencegah qty stok negatif.
- Tidak ada trigger yang memastikan `opening_balance_items` STOK memiliki nilai modal.

---

## 3. Snapshot Sinkronisasi

### 3.1 Tabel yang disertakan

`snapshotTables` (42 tabel) memuat master, nota, retur, pembelian, saldo awal, `stock_cost_state`, `store_features`, `pajak_pembayaran`, dan tabel operasional lain.

### 3.2 Tabel yang **tidak** disertakan (DB-01)

Tidak ada di `snapshotTables` maupun `snapshotDeleteOrder`:

- `cash_ledger`
- `opname_holds`
- `business_audits`
- `debt_reminder_logs` (ada di required restore, tidak di snapshot)
- `pajak_pembayaran` **ada** di snapshot
- tabel sync lokal (memang sengaja lokal)

**Akibat.** Perangkat baru menerima nota/pembayaran tetapi **tidak** menerima `cash_ledger` dan opname tertunda. Laporan kas perangkat baru dimulai dari nol; riwayat kas antar perangkat berbeda.

**Catatan penting:** `service_payments` dan `supplier_payments` ikut snapshot, sehingga pembayaran ada, tetapi `cash_ledger` yang menjadi sumber laporan kas tidak. Ini menciptakan dua sumber kebenaran kas yang tidak sinkron.

### 3.3 Penerapan snapshot

`applySnapshotPayload`:

- memverifikasi checksum dan signature;
- menghapus tabel dalam `snapshotDeleteOrder`;
- memasukkan data dari payload;
- mempertahankan tabel lokal (kredensial, counter, outbox);
- menghapus `applied_deltas`.

**Risiko:** jika payload berasal dari versi skema berbeda, tidak ada metadata versi (DB-04). Jika payload terpotong, validasi hanya checksum; tidak ada pemeriksaan jumlah baris per tabel.

---

## 4. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| DB-01 | Snapshot tanpa `cash_ledger` dan `opname_holds` | CRITICAL | CONFIRMED | `snapshot_sync.dart:12-55,57-99,168-305` |
| DB-02 | Restore memaksa `user_version`, melewati migrasi | CRITICAL | CONFIRMED | `app_database.dart:462-481`; `backup_service.dart:910-922,1150-1170` |
| DB-03 | Database toko baru polos di platform SQLCipher | CRITICAL | CONFIRMED | `app_database.dart:154-186`; `store_service.dart:113` |
| DB-04 | Backup/snapshot tanpa versi skema/aplikasi | HIGH | CONFIRMED | `backup_service.dart:352-378`; `snapshot_sync.dart:122-168` |
| DB-05 | Validasi restore hanya sebagian tabel inti | HIGH | CONFIRMED | `backup_service.dart:35-56,910-922`; `app_database.dart:520-538` |
| DB-06 | Tidak ada `foreign_key_check` | MEDIUM | CONFIRMED | `app_database.dart:520-538`; `backup_service.dart:940-955` |
| DB-07 | Pembuatan stok dari nota memakai `kode` yang bisa bentrok | HIGH | CONFIRMED | `note_sync.dart:1025-1044`; `schema.dart:304-307` |
| DB-08 | Pindah toko saat sync menutup database | HIGH | CONFIRMED | `store_service.dart:137-163`; `app_database.dart:143-152`; `sync_service.dart:2113-2124` |
| DB-09 | Movement ditulis sebelum keputusan opname absolut | MEDIUM | CONFIRMED | `sync_service.dart:3495-3535` |
| DB-10 | Dua sumber keanggotaan toko karyawan | MEDIUM | CONFIRMED | `schema.dart:67-135`; `account_service.dart:155-185` |
| DB-11 | `sync_peer_digests` tidak pernah dipakai | LOW | CONFIRMED | `schema.dart:1611-1620` |
| INV-05 | Dua kolom kuantitas | MEDIUM | CONFIRMED | `schema.dart:274-300` |

### DB-02 — Forced user_version

```dart
await target.execute('PRAGMA user_version = $schemaVersion');
```

`createEncryptedCopy` selalu menulis versi aplikasi saat ini. Backup dari skema v1 dipulihkan di aplikasi v2 → database diklaim v2, `onUpgrade` tidak berjalan, kolom baru tidak ada. Query gagal atau `createOperationalSchema` hanya menambah tabel sehingga kolom tetap hilang.

**Dampak.** Restore backup lama menghasilkan aplikasi error/crash; data lama tidak dapat dipulihkan dengan aman.

### DB-03 — Database toko baru polos

`createDatabaseAt` memakai `databaseFactory.openDatabase` (SQLite polos), bukan `sqlcipher.openDatabase` dengan password. Di Android, database utama memakai SQLCipher; toko baru tidak. Saat dibuka kembali melalui `_open` dengan SQLCipher, file dapat dianggap rusak atau gagal dibuka.

**Dampak.** Toko kedua tidak dapat digunakan; jika terbuka, data tidak terenkripsi.

### DB-04 — Tanpa metadata versi

Manifest backup:

```json
{"format": 3,"app": "PusatkuPOS","created_at": "...","active_store_id": "...","stores": [...]}
```

Tidak ada `schema_version`, `app_version`, atau `schema_contract_version`. Snapshot payload juga tidak membawa versi. Penerima tidak dapat menolak versi yang tidak kompatibel sebelum menimpa database.

### DB-05 — Daftar tabel wajib tidak lengkap

`_requiredRestoreTables` memuat 20 tabel, antara lain `app_settings`, `employee_accounts`, `service_records`, `store_features`, `opname_holds`, pembelian, `stock_cost_state`, saldo awal, `pajak_pembayaran`.

**Tidak memuat:**
`service_jobs`, `service_parts`, `service_payments`, `sale_returns`, `sale_return_items`, `cash_ledger`, `salary_payments`, `harga_jasa`, `suppliers`, `supplier_items`, `nota_adjustments`, `service_record_commissions`, `employee_debts`, `stock_movements`, `estimates`, `estimate_items`, `work_orders`, `store_settings`, `business_audits`, dan tabel lain.

**Akibat.** Backup yang kehilangan `service_parts`/`cash_ledger` tetap lolos karena semua tabel dalam daftar ada. Restore “berhasil” tetapi data inti hilang.

### DB-06 — Tanpa foreign_key_check

Validasi hanya `PRAGMA integrity_check` (struktur b-tree) dan keberadaan tabel. `PRAGMA foreign_key_check` tidak dijalankan. `foreign_keys=ON` hanya berlaku untuk penulisan baru, bukan data lama.

**Akibat.** Baris yatim (mis. `service_parts` menunjuk nota hilang) tidak terdeteksi; join kehilangan baris dan total nota tidak cocok.

### DB-07 — Kode stok bentrok saat sync

Saat menerapkan nota dari perangkat lain yang belum memiliki stok lokal, `note_sync.dart` membuat baris `stock_items` dengan `sync_id` payload dan `kode` payload. Jika kode itu sudah dipakai barang lokal lain (sync_id berbeda), `ux_stock_kode_aktif` menolak insert dan seluruh penerapan nota gagal.

**Dampak.** Nota dari perangkat lain tertahan; antrean sync macet pada entitas yang sama.

### DB-08 — Pindah toko saat sync

`switchStore` menutup database tanpa memeriksa `SyncService.isSyncing` atau menghentikan scheduler. Sinkronisasi yang sedang memakai `AppDatabase.instance.db` kehilangan koneksi, atau menulis ke database toko baru dengan `_storeId` yang sudah berubah.

### DB-09 — Movement sebelum keputusan

Movement stok ditulis sebelum `applyQuantity` diperiksa. Jika opname absolut kalah HLC, movement tetap tersimpan dengan `stok_sesudah` yang tidak pernah diterapkan. Ledger tidak dapat dijadikan bukti.

### DB-10 — Dua sumber keanggotaan

`employee_accounts.store_ids_json` dan `employee_store_access` sama-sama menyimpan keanggotaan toko. `createAccount` menulis keduanya, tetapi jalur lain dapat memperbarui salah satu saja. Jika pencabutan akses hanya memperbarui satu tabel, karyawan masih dapat mengakses toko.

### DB-11 — Tabel mati

`sync_peer_digests` dibuat tetapi tidak dibaca/ditulis. Tidak berdampak runtime; menambah beban skema dan kebingungan.

---

## 5. Multi-Toko

| Aspek | Kondisi |
|---|---|
| Registry toko | `StoreRegistry` (file terpisah), bukan tabel database |
| Database per toko | Satu file SQLite/SQLCipher per toko |
| `store_id` | Ada di hampir semua tabel tersinkron |
| Filter toko | Tidak konsisten: `volumeQuery` tanpa filter (PUR-06); beberapa query memakai `_storeId` |
| Pindah toko | Menutup/membuka database tanpa menunggu sync (DB-08) |
| Fitur per toko | `store_features` dengan `store_id`, tetapi cache fallback true (FEAT-02) |

**Risiko utama:** laporan lintas toko dan penulisan ke toko yang salah saat sync/switch.

---

## 6. Skenario Kegagalan Integritas

### 6.1 Restore database versi lama

1. Backup v1 memiliki `user_version=1`, tanpa tabel/kolom PPN.
2. `createEncryptedCopy` menyalin lalu menulis `user_version=2` (DB-02).
3. Aplikasi membuka tanpa `onUpgrade`.
4. `createOperationalSchema` menambah tabel baru yang belum ada, tetapi kolom baru pada tabel lama tetap hilang.
5. Query ke kolom PPN gagal; aplikasi error.

### 6.2 Snapshot bootstrap perangkat baru

1. Perangkat baru menerima snapshot toko.
2. `cash_ledger` dan `opname_holds` tidak diganti (DB-01).
3. Nota dan pembayaran ada, laporan kas kosong; opname tertunda hilang.
4. Tidak ada peringatan bahwa snapshot tidak lengkap (DB-04/DB-05).

### 6.3 Sync nota dengan kode bentrok

1. Dua perangkat membuat barang “OLI-10” offline.
2. Nota B diterapkan di A yang sudah memiliki kode itu.
3. Unique index menolak; seluruh nota B gagal (DB-07).
4. Antrean mengulang dan gagal terus; tidak ada resolusi otomatis.

### 6.4 Pindah toko saat sync

1. Sync toko A sedang menerapkan nota.
2. Owner pindah ke toko B; database A ditutup (DB-08).
3. Transaksi A gagal/parsial; koneksi dibuka ke B.
4. Proses sync berikutnya dapat menulis data A ke B jika `_storeId` sudah berubah.

### 6.5 Opname absolut kalah HLC

1. Opname lama diterima setelah opname baru.
2. `applyQuantity` false, konflik dicatat.
3. Movement sudah ditulis dengan `stok_sesudah` yang tidak diterapkan (DB-09).
4. Audit ledger menyesatkan.

---

## 7. Rekomendasi Integritas

1. **Satu sumber tabel snapshot:** daftar tabel dihasilkan dari skema, bukan manual; sertakan `cash_ledger`/`opname_holds` atau dokumentasikan lokal dengan rekonsiliasi.
2. **Metadata versi** di manifest backup dan payload snapshot; tolak versi tidak kompatibel.
3. **Validasi restore lengkap:** semua tabel non-lokal, jumlah baris, `foreign_key_check`, dan `integrity_check`.
4. **Pertahankan `user_version` asli** saat restore; jalankan migrasi; tolak downgrade yang tidak didukung.
5. **Buka semua database melalui jalur enkripsi yang sama.**
6. **Satu sumber keanggotaan toko** (`employee_store_access`), `store_ids_json` hanya cache turunan.
7. **Kunci global saat pindah toko/restore**; tunggu sync selesai.
8. **`sync_peer_digests` dihapus** pada desain bersih.
9. **`jumlah` dihapus**; `jumlah_milli NOT NULL`.
10. **Foreign key `ON DELETE`** ditinjau: banyak relasi memakai `CASCADE` pada nota, yang dapat menghapus detail jika nota dihapus; karena nota append-only, ini tidak terpicu, tetapi berisiko jika ada hard delete di masa depan.

---

## 8. Pertanyaan Aturan Bisnis

1. Apakah `cash_ledger` harus global per toko atau per perangkat?
2. Apakah opname tertunda harus ikut snapshot atau diselesaikan sebelum bootstrap?
3. Apakah restore harus menolak backup dari versi lebih baru, atau mencoba migrasi?
4. Apakah karyawan dapat menjadi anggota beberapa toko, dan siapa yang berwenang mencabut?
5. Apakah data audit (`business_audits`) harus ikut backup/snapshot?

---

## 9. Ringkasan

- Skema inti kuat; cacat terbesar ada pada **snapshot yang tidak lengkap**, **restore yang memaksa versi**, dan **database toko baru tanpa enkripsi**.
- Multi-toko belum memiliki isolasi yang konsisten; beberapa query tidak memfilter `store_id`.
- Integritas referensial tidak divalidasi saat restore/snapshot.
- Desain bersih harus menjadikan ledger sebagai sumber kebenaran, menghapus duplikasi kuantitas, dan menyatukan jalur pembukaan database.
