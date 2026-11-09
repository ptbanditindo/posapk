# 11 — ROADMAP REMEDIASI

**Sifat:** rencana. Tidak ada implementasi, migrasi, test, atau perubahan source dalam audit ini.
**Registri lengkap:** `01_BUSINESS_LOGIC_DEFECTS.md`.
**Urutan eksekusi:** `12_IMPLEMENTATION_ORDER.md`.

---

## 1. Prinsip Remediasi

1. **Perbaiki akar, bukan gejala.** Satu sumber kebenaran untuk total, pajak, HPP, kas, dan otorisasi.
2. **CRITICAL lebih dulu, tetapi jangan menunda fondasi.** Database bersih dan error boundary adalah prasyarat perbaikan lain.
3. **Append-only dipertahankan.** Koreksi/reversal menjadi dokumen baru, bukan update/hapus.
4. **Setiap perbaikan memiliki kriteria penerimaan yang dapat dibuktikan** tanpa mengandalkan UI.
5. **Jangan menambah fitur baru sebelum integritas data stabil.**
6. **Semua perubahan harus dapat diuji ulang pada database bersih** (tidak ada data produksi).

---

## 2. Ringkasan Prioritas

| Prioritas | Fokus | Temuan |
|---|---|---|
| P0 | Kehilangan data / kas / takeover | PUR-01, FIN-01, DB-01, DB-02, DB-03, SEC-01 |
| P1 | Salah hitung besar & otorisasi | SAL-01, SAL-03, SAL-04, SAL-05, SAL-07, PUR-02, PUR-03, PUR-05, PUR-06, RET-01, INV-01, INV-02, FIN-02, FIN-03, FIN-04, FIN-05, FIN-06, DB-04, DB-05, DB-07, DB-08, BAK-01, FLW-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-09, FEAT-01 |
| P2 | Konsistensi & operasi | SAL-02, SAL-06, PUR-04, PUR-07, RET-02, INV-03, INV-04, INV-05, INV-06, FIN-07, BIZ-01, DB-06, DB-09, DB-10, BAK-02, FLW-03, SEC-06, SEC-07, SEC-08, FEAT-02 |
| P3 | Kebersihan & tampilan | SAL-08, RET-03, DB-11, FLW-02 |

---

## 3. Rencana Remediasi per Temuan

### 3.1 Penjualan

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| SAL-01 | Simpan `dpp`, `ppn`, `total_ditagih`, mode, penanggung pada estimasi; konversi menyalin snapshot pajak; diskon hanya dari harga sebelum pajak | Estimasi EKSLUSIF/INKLUSIF dapat dikonversi; PPN nota = PPN estimasi; tidak ada diskon negatif |
| SAL-02 | Simpan `jenis_transaksi` pada estimasi dan gunakan saat konversi | Nota hasil konversi memiliki jenis yang sama dengan estimasi; nomor/antrean sesuai |
| SAL-03 | Wajibkan katalog atau modal/estimasi biaya + izin `ubah_harga_jasa`; blokir harga nol kecuali owner + alasan | Jasa bebas tanpa modal ditolak; harga di bawah batas memerlukan izin; audit tercatat |
| SAL-04 | Tambah izin kredit, wajib jatuh tempo, limit per pelanggan, approval owner | Kredit tanpa jatuh tempo ditolak; limit terlampaui ditolak/approval; audit tercatat |
| SAL-05 | Simpan `jasa_sync_id` pada `estimate_items`; teruskan ke `JobDraft` | Nota hasil konversi memiliki `jasa_id`; validasi tarif berjalan |
| SAL-06 | Pisahkan `harga_terdaftar` dan `harga_input`; jasa bebas memakai tarif referensi atau ditandai | Laporan underprice dapat mendeteksi harga manual |
| SAL-07 | Tambah snapshot `customer_nama`/`customer_hp` pada nota; merge hanya untuk referensi ke depan | Cetak/laporan nota lama tidak berubah setelah merge |
| SAL-08 | Tampilkan sen bila tidak bulat, atau bulatkan sekali di tingkat nota | Jumlah baris = total pada struk |

### 3.2 Pembelian

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| PUR-01 | Refund inkremental per dokumen; simpan `refund_terakumulasi` di header; tulis selisih; idempotensi per retur | Dua retur menghasilkan total kas = nilai retur seharusnya; tidak ada baris kas ganda |
| PUR-02 | Dokumen pembayaran utang awal atau konversi ke pembelian; ledger kas | Utang awal dapat dibayar sampai lunas; aging konsisten |
| PUR-03 | Dokumen tagihan/penerimaan piutang awal; masukkan ke dashboard/aging | Piutang awal dapat ditagih dan tampil di dashboard |
| PUR-04 | Simpan metode refund (default metode pembayaran asal) | Kas/bank sesuai dana sebenarnya |
| PUR-05 | Nilai retur dari `harga_pokok_satuan`/nilai bayar per unit | Refund proporsional terhadap kas yang dibayar |
| PUR-06 | Tambah `store_id` ke `volumeQuery` | Laporan toko A hanya memuat data A |
| PUR-07 | Pisahkan `utang_pembelian` dan `utang_awal` | Ringkasan tidak mencampur dua sumber |

### 3.3 Retur dan Pembatalan

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| RET-01 | Dokumen reversal append-only dengan otorisasi owner; transisi status terkontrol | Retur salah dapat dibatalkan; stok/kas kembali; audit lengkap |
| RET-02 | Simpan `dpp`, `ppn`, `total_ditagih` pada header dan item retur; gunakan basis konsisten | Omzet neto = total efektif; PPN retur mengurangi kewajiban |
| RET-03 | Tambah `AND status = 'AKTIF'` pada semua agregasi retur | Retur VOID/reversal tidak mengurangi nota |
| PUR-01 | Lihat 3.2 | — |
| PUR-04 | Lihat 3.2 | — |
| PUR-05 | Lihat 3.2 | — |

### 3.4 Persediaan

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| INV-01 | Movement KOREKSI memakai `sync_id` unik per koreksi | Koreksi kedua dan seterusnya berhasil |
| INV-02 | Opname berbasis delta + `basis_qty`; tolak/rekonsiliasi jika saldo berubah | Penjualan setelah hitung fisik tidak hilang |
| INV-03 | Perbarui `stock_balances`/cost state pada opname | Qty dan nilai konsisten setelah opname |
| INV-04 | Void saldo awal mengurangi cost state/balance | Nilai persediaan kembali sesuai |
| INV-05 | Backfill `jumlah_milli`; hapus `jumlah`; NOT NULL | Tidak ada pembacaan 0 pada data lama |
| INV-06 | Tambah `unit_cost_cents`/`value_cents` pada baris STOK (jika aturan bisnis mengizinkan) | Saldo awal dapat memakai modal historis |

### 3.5 Keuangan

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| FIN-01 | Pusatkan mutasi stok; perbarui balance/cost pada jual, retur, void, opname, koreksi; sediakan rebuild | `qty_balance` = `stock_items`; nilai persediaan dapat direkonsiliasi |
| FIN-02 | HPP snapshot dari balance/ledger, bukan master | Laba per nota sesuai HPP rata-rata |
| FIN-03 | Kurangkan DPP/PPN retur di ringkasan; satu sumber rekap PPN | Ringkasan = rekap PPN; tidak ada PPN atas retur penuh |
| FIN-04 | Sertakan piutang awal di dashboard/aging | Dashboard = nota + saldo awal |
| FIN-05 | Wajibkan aktor/izin; simpan `paid_by`; operator kas = aktor | Gaji hanya oleh berwenang; audit jelas |
| FIN-06 | Validasi sisa kewajiban di remote; hasilkan `cash_sync_id`; insert gagal keras | Tidak ada overpay; kas tidak hilang diam-diam |
| FIN-07 | Kalikan sebelum SUM; pembulatan sekali | Total laporan = total transaksi |

### 3.6 Lintas Modul dan Database

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| BIZ-01 | Simpan hash payload bersama `request_id`; tolak hash berbeda | Retry dengan payload berbeda ditolak |
| DB-01 | Sertakan `cash_ledger`/`opname_holds` di snapshot atau rekonsiliasi eksplisit | Bootstrap perangkat baru menghasilkan saldo kas/opname identik |
| DB-02 | Pertahankan `user_version` asli; jalankan migrasi; tolak versi tidak didukung | Restore backup lama berhasil dan skema lengkap |
| DB-03 | Semua database dibuka melalui jalur SQLCipher dengan password | Toko baru terenkripsi dan dapat dibuka |
| DB-04 | Tambah `schema_version`, `app_version`, `schema_contract_version` ke backup/snapshot | Versi tidak kompatibel ditolak sebelum menimpa |
| DB-05 | Validasi semua tabel non-lokal + jumlah baris/checksum | Backup terpotong ditolak |
| DB-06 | Jalankan `foreign_key_check` | Restore dengan baris yatim ditolak |
| DB-07 | Cari stok via `sync_id`; kode bentrok → kode sementara + konflik | Nota dari perangkat lain tetap masuk |
| DB-08 | Tunggu/hentikan sync sebelum switch; kunci global; rollback | Switch tidak memutus transaksi |
| DB-09 | Movement setelah keputusan opname; konflik di `sync_conflicts` | Ledger hanya mencatat perubahan yang diterapkan |
| DB-10 | `employee_store_access` satu-satunya sumber; `store_ids_json` cache turunan | Pencabutan akses langsung berlaku |
| DB-11 | Hapus `sync_peer_digests` | Skema tidak memiliki tabel mati |
| INV-05 | Lihat 3.4 | — |

### 3.7 Backup dan Restore

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| BAK-01 | Hentikan scheduler, tunggu sync, state machine restore | Restore tidak bersamaan dengan sync/backup |
| BAK-02 | Backup API/`VACUUM INTO` atau hentikan penulis | Salinan konsisten |
| DB-02 | Lihat 3.6 | — |
| DB-04 | Lihat 3.6 | — |
| DB-05 | Lihat 3.6 | — |
| DB-06 | Lihat 3.6 | — |
| FLW-03 | Layar pemulihan dan mode aman | Database rusak dapat direstore tanpa menghapus data |

### 3.8 Alur dan Error

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| FLW-01 | Error boundary startup + layar pemulihan | Kegagalan inisialisasi menampilkan opsi, bukan layar kosong |
| FLW-02 | Pisahkan `try` simpan dan struk | Pesan sukses simpan meski struk gagal |
| FLW-03 | Lihat 3.7 | — |

### 3.9 Keamanan

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| SEC-01 | Sign-out minta PIN owner atau kunci database; onboarding deteksi owner | Pemegang perangkat tidak dapat membuat PIN owner baru |
| SEC-02 | Aktor `Operator` + izin owner di account service | Akun/reset hanya oleh owner; audit benar |
| SEC-03 | Aktor + izin supplier; allow-list sync | Supplier hanya diubah berwenang dan tersinkron |
| SEC-04 | Aktor + izin payroll; `paid_by` | Gaji hanya oleh berwenang |
| SEC-05 | Hapus fallback owner; state tidak terautentikasi | Operator null tidak membuka menu owner |
| SEC-06 | PIN minimum 6 digit; paksa ganti legacy | PIN lemah tidak dapat dipakai |
| SEC-07 | Viewer `readOnly`; `Permissions.can` tolak viewer | Viewer tidak dapat menulis |
| SEC-08 | Ekspor owner-only + PIN; redaksi token | Karyawan tidak dapat mengekspor lisensi |
| SEC-09 | Jangan sintesis owner dari PIN | Sesi hilang tidak menjadi owner |

### 3.10 Feature Toggle

| ID | Tindakan | Kriteria penerimaan |
|---|---|---|
| FEAT-01 | `requireEnabled` di semua service fitur, termasuk remote | OFF memblokir semua jalur tulis |
| FEAT-02 | Cache fail-closed; blokir UI sampai load | Tidak ada akses fitur OFF sebelum state dimuat |

**Total: 59 temuan tercakup.** Setiap temuan juga dipetakan ke tahap implementasi di `12_IMPLEMENTATION_ORDER.md`.

---

## 4. CLEAN DATABASE IMPLEMENTATION PLAN

### 4.1 Prinsip Desain Database Bersih

1. **Tanpa migrasi data produksi.** Karena belum ada data produksi, skema dapat dibuat ulang dari nol. Namun aplikasi tetap memerlukan `schema_version` untuk upgrade di masa depan.
2. **Satu sumber kebenaran per domain:**
   - stok: ledger `stock_movements` + `stock_balances` turunan;
   - kas: `cash_ledger`;
   - piutang/utang: dokumen penjualan/pembelian + saldo awal + settlement;
   - pajak: kolom eksplisit `dpp`, `ppn`, `total_ditagih`;
   - otorisasi: `owner_identity` + `employee_accounts` + `employee_store_access`.
3. **Append-only untuk dokumen.** Koreksi/reversal adalah dokumen baru.
4. **Uang dalam sen** dengan sufiks `_cents`; kuantitas `_milli`; tarif `_bp`.
5. **Semua tabel tersinkron** memiliki `sync_id`, `store_id`, `device_id`, HLC, timestamps, `deleted_at`.
6. **Relasi eksplisit** dengan FK; polymorphic source hanya untuk ledger dan diberi unique index.
7. **Tidak ada tabel/kolom mati.**
8. **Setiap tabel dapat direbuild** dari dokumen/ledger untuk modul turunan (saldo, cost, laporan).

### 4.2 Evaluasi Setiap Tabel Saat Ini

| Tabel | Keputusan | Alasan |
|---|---|---|
| `app_settings` | **Rename → `app_meta`** | Nama lebih tepat; tetap key/value untuk konfigurasi lokal |
| `owner_identity` | **Keep** | Identitas tunggal owner |
| `license` | **Rename → `licenses`**, keep | Satu baris; tambah metadata verifikasi |
| `login_guards` | **Keep** | Diperlukan untuk rate limit |
| `employee_accounts` | **Simplify + Split** | Hapus `store_ids_json`; pindahkan konfigurasi payroll ke `employee_payroll_profiles` |
| `employee_store_access` | **Keep as single source** | Menghapus duplikasi keanggotaan (DB-10) |
| `permission_audits` | **Merge → `audit_events`** | Satu tabel audit dengan `business_audits` |
| `devices` | **Keep** | Perangkat dan kunci |
| `business_audits` | **Merge → `audit_events`** | Satu skema audit |
| `customers` | **Keep + snapshot on nota** | Merge tidak boleh mengubah histori (SAL-07) |
| `vehicle_or_units` | **Keep** | Unit pelanggan |
| `stock_items` | **Simplify** | Hapus `jumlah`; `jumlah_milli NOT NULL`; `harga_modal_cents` hanya default |
| `harga_jasa` | **Keep** | Tarif jasa |
| `suppliers` | **Keep** | Master supplier |
| `supplier_items` | **Keep** | Relasi supplier-barang |
| `supplier_followups` | **Merge → `followups`** | Duplikasi model follow-up dengan `followup_items` |
| `followup_items` | **Merge → `followups`** | Satu tabel dengan `scope` |
| `followup_events` | **Keep** | Riwayat tindakan follow-up |
| `wa_message_logs` | **Keep** | Log pesan opsional |
| `service_records` | **Recreate/simplify** | Kolom pajak/kredit/snapshot pelanggan eksplisit; hapus JSON yang redundan |
| `service_jobs` | **Keep + kolom baru** | `harga_terdaftar_cents`, `harga_input_cents`, `hpp_snapshot_cents`, `jasa_sync_id` wajib bila katalog |
| `service_parts` | **Keep + kolom baru** | `hpp_snapshot_cents`, `qty_milli` |
| `service_payments` | **Keep** | Pembayaran + `cash_sync_id` |
| `cash_ledger` | **Keep as authoritative** | Sertakan di snapshot; unique source |
| `stock_movements` | **Recreate/expand** | Tambah `qty_delta_milli`, `unit_cost_cents`, `value_delta_cents`, `balance_*`; unique per dokumen |
| `nota_adjustments` | **Keep** | Koreksi append-only |
| `sale_returns` | **Keep + reversal** | Tambah `dpp_cents`, `ppn_cents`, `total_ditagih_cents`, `refund_doc_cents` |
| `sale_return_items` | **Keep + nilai eksplisit** | `dpp_cents`, `ppn_cents`, `hpp_snapshot_cents` |
| `sale_return_reversals` | **New** | Menyelesaikan RET-01 |
| `service_record_mechanics` | **Keep** | Relasi mekanik |
| `service_record_commissions` | **Keep** | Snapshot komisi |
| `employee_debts` | **Keep** | Utang karyawan |
| `employee_debt_payments` | **New** | Jejak pembayaran/pemotongan |
| `salary_payments` | **Split header + components** | Pisahkan gaji/komisi/bonus/potongan; `paid_by` |
| `salary_components` | **New** | Rincian komponen gaji |
| `stock_cost_state` | **Merge → `stock_balances`** | Satu state qty/nilai yang dapat direbuild |
| `opname_holds` | **Keep + basis** | Tambah `basis_qty_milli`, `counted_at`; sertakan snapshot |
| `store_settings` | **Keep + simplify** | Hapus duplikasi flag; pajak eksplisit |
| `store_features` | **Keep as single flag source** | Cache turunan; owner-only |
| `estimates` | **Keep + eksplisit** | `dpp_cents`, `ppn_cents`, `total_ditagih_cents`, `jenis_transaksi`, mode/penanggung |
| `estimate_items` | **Keep + `jasa_sync_id`** | Perbaiki SAL-05 |
| `work_orders` | **Keep** | Order kerja |
| `work_order_status_log` | **Keep** | Riwayat status |
| `document_counters` | **Keep** | Nomor dokumen per perangkat |
| `day_digests` | **Keep** | Rekonsiliasi harian |
| `reconciliation_requests` | **Keep** | Permintaan rekonsiliasi |
| `sync_outbox` | **Keep** | Antrean kirim |
| `sync_inbox` | **Keep** | Antrean terima |
| `sync_cursor` | **Keep** | Cursor |
| `applied_deltas` | **Keep** | Idempotensi |
| `sync_conflicts` | **Keep** | Konflik |
| `device_sync_status` | **Keep** | Status perangkat |
| `sync_peer_digests` | **Delete** | Tidak pernah dipakai (DB-11) |
| `supplier_purchases` | **Keep + kolom refund** | `refund_accumulated_cents`, `paid_cents`, `sisa_cents` |
| `supplier_purchase_items` | **Keep** | `harga_pokok_satuan_cents`, `qty_retur_milli` |
| `supplier_payments` | **Keep** | Pembayaran utang |
| `supplier_purchase_returns` | **Keep + refund inkremental** | `total_nilai_cents`, `refund_doc_cents`, metode |
| `supplier_purchase_return_items` | **Keep + harga pokok** | `harga_pokok_satuan_cents` |
| `purchase_return_reversals` | **New** | Reversal retur pembelian |
| `opening_balances` | **Keep + KAS** | Tambah jenis KAS |
| `opening_balance_items` | **Simplify** | Hanya STOK dengan `unit_cost_cents`/`value_cents` |
| `opening_receivables` | **New** | Piutang awal dapat ditagih |
| `opening_payables` | **New** | Utang awal dapat dibayar |
| `receivable_payments` | **New** | Penerimaan piutang awal |
| `payable_payments` | **New** | Pembayaran utang awal |
| `debt_reminder_logs` | **Keep** | Pengingat |
| `pajak_pembayaran` | **Keep + validasi** | `sisa_kewajiban_cents`, `carry_forward`, `cash_sync_id` |

**Tidak ada tabel `users`.** Identitas terdiri dari `owner_identity` (pemilik) dan `employee_accounts` (karyawan). Jika kebutuhan “user” muncul, gunakan `employee_accounts` dengan `role_base`; jangan menambah tabel users paralel.

### 4.3 Struktur Baru yang Direkomendasikan

#### 4.3.1 Konvensi kolom

```sql
sync_id TEXT NOT NULL UNIQUE,
store_id TEXT NOT NULL,
device_id TEXT NOT NULL DEFAULT '',
sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
created_at TEXT NOT NULL,
updated_at TEXT NOT NULL,
deleted_at TEXT
```

#### 4.3.2 Tabel inti yang berubah

```sql
-- Identitas dan akses
CREATE TABLE employee_accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL DEFAULT '',
  device_id TEXT NOT NULL DEFAULT '',
  username TEXT NOT NULL,
  nama TEXT NOT NULL,
  role_base TEXT NOT NULL DEFAULT 'KASIR',
  extra_permissions_json TEXT NOT NULL DEFAULT '[]',
  password_hash TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  password_iterations INTEGER NOT NULL DEFAULT 210000,
  pin_hash TEXT,
  pin_salt TEXT,
  pin_iterations INTEGER NOT NULL DEFAULT 210000,
  must_change_password INTEGER NOT NULL DEFAULT 1,
  aktif INTEGER NOT NULL DEFAULT 1,
  permission_version INTEGER NOT NULL DEFAULT 1,
  last_login_at TEXT,
  last_permission_sync_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE employee_payroll_profiles (
  employee_sync_id TEXT PRIMARY KEY,
  jenis_imbalan TEXT NOT NULL DEFAULT 'KOMISI',
  gaji_bulanan_cents INTEGER NOT NULL DEFAULT 0,
  komisi_mode TEXT NOT NULL DEFAULT 'PERSEN',
  komisi_barang_bp INTEGER NOT NULL DEFAULT 0,
  komisi_jasa_bp INTEGER NOT NULL DEFAULT 0,
  payroll_period TEXT NOT NULL DEFAULT 'BULANAN',
  payroll_tanggal INTEGER NOT NULL DEFAULT 1,
  payroll_hari INTEGER NOT NULL DEFAULT 1,
  bank_nama TEXT,
  bank_nomor TEXT,
  bank_pemilik TEXT,
  tanggal_masuk TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE employee_store_access (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  employee_sync_id TEXT NOT NULL,
  role_base TEXT NOT NULL DEFAULT 'KASIR',
  extra_permissions_json TEXT NOT NULL DEFAULT '[]',
  aktif INTEGER NOT NULL DEFAULT 1,
  version INTEGER NOT NULL DEFAULT 1,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE (store_id, employee_sync_id)
);

-- Stok ledger-first
CREATE TABLE stock_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  device_id TEXT NOT NULL DEFAULT '',
  kode TEXT NOT NULL,
  barcode TEXT,
  nama TEXT NOT NULL,
  harga_modal_default_cents INTEGER NOT NULL DEFAULT 0,
  harga_jual_cents INTEGER NOT NULL DEFAULT 0,
  harga_jual_minimum_cents INTEGER NOT NULL DEFAULT 0,
  jumlah_milli INTEGER NOT NULL DEFAULT 0,
  stok_minimum_milli INTEGER NOT NULL DEFAULT 0,
  satuan TEXT NOT NULL DEFAULT 'pcs',
  desimal INTEGER NOT NULL DEFAULT 0,
  lokasi_rak TEXT,
  interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  CHECK (harga_modal_default_cents >= 0),
  CHECK (harga_jual_cents >= 0),
  CHECK (stok_minimum_milli >= 0)
);

CREATE TABLE stock_balances (
  store_id TEXT NOT NULL,
  stock_sync_id TEXT NOT NULL,
  qty_milli INTEGER NOT NULL DEFAULT 0,
  value_cents INTEGER NOT NULL DEFAULT 0,
  avg_cost_cents INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (store_id, stock_sync_id)
);

CREATE TABLE stock_movements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  device_id TEXT NOT NULL DEFAULT '',
  stock_sync_id TEXT NOT NULL,
  nama_snapshot TEXT,
  jenis TEXT NOT NULL,
  qty_delta_milli INTEGER NOT NULL,
  unit_cost_cents INTEGER NOT NULL DEFAULT 0,
  value_delta_cents INTEGER NOT NULL DEFAULT 0,
  balance_qty_milli INTEGER NOT NULL,
  balance_value_cents INTEGER NOT NULL,
  opname_basis_qty_milli INTEGER,
  source_entity TEXT NOT NULL DEFAULT '',
  source_sync_id TEXT NOT NULL DEFAULT '',
  service_record_sync_id TEXT,
  operator TEXT,
  reason TEXT,
  created_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  CHECK (qty_delta_milli <> 0)
);

CREATE UNIQUE INDEX ux_stock_movement_source
ON stock_movements(store_id, source_entity, source_sync_id, jenis)
WHERE source_sync_id <> '';
```

**Catatan:** `stock_balances` adalah cache yang harus dapat direbuild dari `stock_movements`. Setiap movement membawa nilai HPP sehingga ledger dapat menjadi sumber tunggal.

```sql
-- Nota penjualan
CREATE TABLE service_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  device_id TEXT NOT NULL DEFAULT '',
  no_nota TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  request_payload_hash TEXT NOT NULL,           -- BIZ-01
  jenis_transaksi TEXT NOT NULL,
  customer_id INTEGER,
  customer_nama_snapshot TEXT NOT NULL DEFAULT '', -- SAL-07
  customer_hp_snapshot TEXT NOT NULL DEFAULT '',
  unit_id INTEGER,
  unit_nopol_snapshot TEXT,
  waktu_service TEXT NOT NULL,
  keluhan_awal TEXT NOT NULL DEFAULT '',
  biaya_jasa_cents INTEGER NOT NULL DEFAULT 0,
  total_part_cents INTEGER NOT NULL DEFAULT 0,
  diskon_cents INTEGER NOT NULL DEFAULT 0,
  dpp_cents INTEGER NOT NULL DEFAULT 0,
  ppn_cents INTEGER NOT NULL DEFAULT 0,
  total_ditagih_cents INTEGER NOT NULL DEFAULT 0,
  pajak_mode TEXT NOT NULL DEFAULT 'TANPA',
  pajak_persen_bp INTEGER NOT NULL DEFAULT 0,
  pajak_penanggung TEXT NOT NULL DEFAULT 'PEMBELI',
  total_efektif_cents INTEGER NOT NULL DEFAULT 0,
  total_retur_cents INTEGER NOT NULL DEFAULT 0,
  total_koreksi_cents INTEGER NOT NULL DEFAULT 0,
  metode_bayar TEXT NOT NULL DEFAULT 'CASH',
  dibayar_cents INTEGER NOT NULL DEFAULT 0,
  sisa_bayar_cents INTEGER NOT NULL DEFAULT 0,
  status_bayar TEXT NOT NULL DEFAULT 'LUNAS',
  jatuh_tempo TEXT,
  credit_approved_by TEXT,
  credit_limit_snapshot_cents INTEGER,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  void_reason TEXT,
  voided_at TEXT,
  void_refund_cents INTEGER NOT NULL DEFAULT 0,
  created_by TEXT,
  created_by_employee_sync_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  CHECK (pajak_mode IN ('TANPA','EKSLUSIF','INKLUSIF')),
  CHECK (pajak_penanggung IN ('PEMBELI','BENGKEL')),
  CHECK (status IN ('AKTIF','VOID')),
  CHECK (total_ditagih_cents >= 0),
  CHECK (dibayar_cents >= 0),
  CHECK (sisa_bayar_cents >= 0)
);
```

```sql
-- Retur penjualan + reversal
CREATE TABLE sale_returns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  service_record_sync_id TEXT NOT NULL,
  no_retur TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  request_payload_hash TEXT NOT NULL,
  total_ditagih_cents INTEGER NOT NULL DEFAULT 0,
  dpp_cents INTEGER NOT NULL DEFAULT 0,
  ppn_cents INTEGER NOT NULL DEFAULT 0,
  total_hpp_cents INTEGER NOT NULL DEFAULT 0,
  refund_doc_cents INTEGER NOT NULL DEFAULT 0,
  metode_refund TEXT NOT NULL DEFAULT 'CASH',
  alasan TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  dibuat_oleh TEXT,
  voided_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  CHECK (status IN ('AKTIF','REVERSED'))
);

CREATE TABLE sale_return_reversals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  return_sync_id TEXT NOT NULL,
  no_reversal TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  total_ditagih_cents INTEGER NOT NULL,
  total_hpp_cents INTEGER NOT NULL,
  refund_cents INTEGER NOT NULL,
  alasan TEXT NOT NULL,
  dibuat_oleh TEXT NOT NULL,
  created_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0
);
```

```sql
-- Pembelian + retur + reversal
CREATE TABLE supplier_purchases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  no_pembelian TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  request_payload_hash TEXT NOT NULL,
  supplier_id INTEGER NOT NULL,
  supplier_nama_snapshot TEXT NOT NULL DEFAULT '',
  tanggal TEXT NOT NULL,
  jatuh_tempo TEXT,
  jenis_bayar TEXT NOT NULL DEFAULT 'KREDIT',
  status TEXT NOT NULL DEFAULT 'AKTIF',
  subtotal_cents INTEGER NOT NULL DEFAULT 0,
  diskon_cents INTEGER NOT NULL DEFAULT 0,
  ongkir_cents INTEGER NOT NULL DEFAULT 0,
  ppn_cents INTEGER NOT NULL DEFAULT 0,
  total_cents INTEGER NOT NULL DEFAULT 0,
  dibayar_cents INTEGER NOT NULL DEFAULT 0,
  sisa_utang_cents INTEGER NOT NULL DEFAULT 0,
  refund_accumulated_cents INTEGER NOT NULL DEFAULT 0,
  void_reason TEXT,
  voided_at TEXT,
  created_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  CHECK (status IN ('AKTIF','VOID')),
  CHECK (dibayar_cents <= total_cents),
  CHECK (sisa_utang_cents >= 0)
);

CREATE TABLE supplier_purchase_returns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  purchase_sync_id TEXT NOT NULL,
  no_retur TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  request_payload_hash TEXT NOT NULL,
  total_nilai_cents INTEGER NOT NULL DEFAULT 0,
  total_hpp_cents INTEGER NOT NULL DEFAULT 0,
  refund_doc_cents INTEGER NOT NULL DEFAULT 0,
  metode_refund TEXT NOT NULL DEFAULT 'CASH',
  alasan TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  dibuat_oleh TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  CHECK (status IN ('AKTIF','REVERSED'))
);

CREATE TABLE purchase_return_reversals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  return_sync_id TEXT NOT NULL,
  no_reversal TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  total_nilai_cents INTEGER NOT NULL,
  total_hpp_cents INTEGER NOT NULL,
  refund_cents INTEGER NOT NULL,
  alasan TEXT NOT NULL,
  dibuat_oleh TEXT NOT NULL,
  created_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0
);
```

```sql
-- Kas
CREATE TABLE cash_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  device_id TEXT NOT NULL DEFAULT '',
  waktu TEXT NOT NULL,
  kategori TEXT NOT NULL,
  sumber_entity TEXT NOT NULL,
  sumber_sync_id TEXT NOT NULL,
  nominal_cents INTEGER NOT NULL,
  metode TEXT NOT NULL,
  kas_shift_id TEXT,
  operator TEXT NOT NULL,
  operator_employee_sync_id TEXT,
  catatan TEXT,
  created_at TEXT NOT NULL,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  CHECK (nominal_cents <> 0),
  CHECK (metode IN ('CASH','TRANSFER'))
);

CREATE UNIQUE INDEX ux_cash_ledger_source
ON cash_ledger(store_id, sumber_entity, sumber_sync_id);
```

```sql
-- Piutang/utang awal
CREATE TABLE opening_receivables (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  customer_sync_id TEXT NOT NULL,
  customer_nama_snapshot TEXT NOT NULL,
  nominal_cents INTEGER NOT NULL,
  terbayar_cents INTEGER NOT NULL DEFAULT 0,
  jatuh_tempo TEXT,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (nominal_cents > 0),
  CHECK (terbayar_cents <= nominal_cents)
);

CREATE TABLE receivable_payments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  receivable_sync_id TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  nominal_cents INTEGER NOT NULL,
  metode TEXT NOT NULL,
  waktu TEXT NOT NULL,
  operator TEXT NOT NULL,
  cash_sync_id TEXT,
  created_at TEXT NOT NULL,
  CHECK (nominal_cents > 0)
);

CREATE TABLE opening_payables (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  supplier_sync_id TEXT NOT NULL,
  supplier_nama_snapshot TEXT NOT NULL,
  nominal_cents INTEGER NOT NULL,
  terbayar_cents INTEGER NOT NULL DEFAULT 0,
  jatuh_tempo TEXT,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (nominal_cents > 0),
  CHECK (terbayar_cents <= nominal_cents)
);

CREATE TABLE payable_payments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  payable_sync_id TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  nominal_cents INTEGER NOT NULL,
  metode TEXT NOT NULL,
  waktu TEXT NOT NULL,
  operator TEXT NOT NULL,
  cash_sync_id TEXT,
  created_at TEXT NOT NULL,
  CHECK (nominal_cents > 0)
);
```

```sql
-- Payroll
CREATE TABLE salary_payments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL,
  employee_sync_id TEXT NOT NULL,
  employee_nama_snapshot TEXT NOT NULL,
  periode TEXT NOT NULL,
  cycle_start TEXT NOT NULL,
  cycle_end TEXT NOT NULL,
  gross_cents INTEGER NOT NULL,
  deduction_cents INTEGER NOT NULL DEFAULT 0,
  net_cents INTEGER NOT NULL,
  metode TEXT NOT NULL DEFAULT 'CASH',
  paid_by TEXT NOT NULL,
  paid_by_employee_sync_id TEXT,
  status TEXT NOT NULL DEFAULT 'AKTIF',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (gross_cents >= 0),
  CHECK (net_cents >= 0),
  CHECK (gross_cents - deduction_cents = net_cents)
);

CREATE TABLE salary_components (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  salary_sync_id TEXT NOT NULL,
  jenis TEXT NOT NULL,
  nominal_cents INTEGER NOT NULL,
  referensi_sync_id TEXT,
  created_at TEXT NOT NULL
);
```

```sql
-- Feature flags
CREATE TABLE store_features (
  store_id TEXT NOT NULL,
  feature_key TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL DEFAULT 1,
  updated_by TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sync_id TEXT NOT NULL UNIQUE,
  sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
  sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (store_id, feature_key)
);

CREATE TABLE feature_audits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  store_id TEXT NOT NULL,
  feature_key TEXT NOT NULL,
  before_enabled INTEGER,
  after_enabled INTEGER NOT NULL,
  actor TEXT NOT NULL,
  actor_employee_sync_id TEXT,
  reason TEXT,
  created_at TEXT NOT NULL
);
```

```sql
-- Audit terpadu
CREATE TABLE audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_id TEXT NOT NULL UNIQUE,
  store_id TEXT NOT NULL DEFAULT '',
  device_id TEXT NOT NULL DEFAULT '',
  actor TEXT NOT NULL,
  actor_employee_sync_id TEXT,
  actor_role TEXT NOT NULL,
  aksi TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL DEFAULT '',
  before_json TEXT NOT NULL DEFAULT '{}',
  after_json TEXT NOT NULL DEFAULT '{}',
  alasan TEXT,
  created_at TEXT NOT NULL
);
```

### 4.4 Relasi Utama

```
owner_identity 1─1 license
employee_accounts 1─N employee_store_access
employee_accounts 1─1 employee_payroll_profiles
employee_accounts 1─N employee_debts 1─N employee_debt_payments
employee_accounts 1─N salary_payments 1─N salary_components

customers 1─N vehicle_or_units
customers 1─N service_records
customers 1─N opening_receivables 1─N receivable_payments

stock_items 1─N stock_movements
stock_items 1─1 stock_balances
stock_items 1─N service_parts
stock_items 1─N supplier_purchase_items
stock_items 1─N opening_balance_items (STOK)
stock_items 1─N opname_holds

service_records 1─N service_jobs
service_records 1─N service_parts
service_records 1─N service_payments
service_records 1─N sale_returns 1─N sale_return_items
sale_returns 1─N sale_return_reversals
estimates 0..1─1 service_records (via source_estimate_sync_id)

suppliers 1─N supplier_purchases 1─N supplier_purchase_items
supplier_purchases 1─N supplier_payments
supplier_purchases 1─N supplier_purchase_returns 1─N supplier_purchase_return_items
supplier_purchase_returns 1─N purchase_return_reversals
suppliers 1─N opening_payables 1─N payable_payments

service_records / supplier_purchases / salary_payments / pajak_pembayaran
  → cash_ledger (polymorphic via sumber_entity + sumber_sync_id, unique)
```

### 4.5 Constraint dan Index Kunci

| Tujuan | Constraint/Index |
|---|---|
| Nota unik per toko | `UNIQUE(store_id, no_nota)` |
| Estimasi unik per toko/tahun | `UNIQUE(store_id, nomor_estimasi, versi)` |
| Retur unik per toko | `UNIQUE(store_id, no_retur)` |
| Pembelian unik per toko | `UNIQUE(store_id, no_pembelian)` |
| Idempotensi nota | `UNIQUE(request_id)` + `request_payload_hash` |
| Kas unik per sumber | `UNIQUE(store_id, sumber_entity, sumber_sync_id)` |
| Movement unik per sumber/jenis | `UNIQUE(store_id, sumber_entity, sumber_sync_id, jenis)` |
| Kode stok aktif | `UNIQUE(kode) WHERE deleted_at IS NULL` |
| Barcode aktif | `UNIQUE(barcode) WHERE barcode IS NOT NULL AND deleted_at IS NULL` |
| Keanggotaan toko | `UNIQUE(store_id, employee_sync_id)` |
| Fitur per toko | `PK(store_id, feature_key)` |
| Saldo awal aktif | `UNIQUE(store_id) WHERE status='AKTIF'` |
| Baris retur unik | `UNIQUE(return_sync_id, line_type, line_sync_id)` |
| Payroll per siklus | `UNIQUE(employee_sync_id, cycle_start)` |
| PPN per masa | `UNIQUE(store_id, masa, request_id)` |
| Konflik pending | `UNIQUE(entity, entity_id, reason) WHERE status IN ('open','review')` |
| Query laporan | `(store_id, waktu_service)`, `(store_id, status, waktu_service)`, `(store_id, stock_sync_id, created_at)` |
| FK | Semua relasi utama; `PRAGMA foreign_keys=ON` |

**CHECK penting:**
- `qty_delta_milli <> 0` untuk movement;
- `dibayar_cents <= total_cents`;
- `sisa_utang_cents >= 0`;
- `terbayar_cents <= nominal_cents`;
- `total_efektif_cents >= 0`;
- `ppn_cents >= 0`;
- status enum;
- `cash_ledger.nominal_cents <> 0`.

### 4.6 Tabel Usang/Diubah

| Aksi | Objek |
|---|---|
| **Delete** | `sync_peer_digests` |
| **Merge** | `permission_audits` + `business_audits` → `audit_events`; `supplier_followups` + `followup_items` → `followups`; `stock_cost_state` → `stock_balances` |
| **Split** | `employee_accounts` payroll columns → `employee_payroll_profiles`; `salary_payments` → header + `salary_components` |
| **Simplify** | `stock_items` (hapus `jumlah`); `opening_balance_items` (hanya STOK); `service_records` (kolom pajak/kredit eksplisit) |
| **Rename** | `app_settings` → `app_meta`; `license` → `licenses` |
| **Recreate** | `service_records`, `stock_movements`, `sale_returns`, `supplier_purchases`, `supplier_purchase_returns` (perubahan kolom besar) |
| **New** | `stock_balances`, `sale_return_reversals`, `purchase_return_reversals`, `opening_receivables`, `opening_payables`, `receivable_payments`, `payable_payments`, `salary_components`, `employee_debt_payments`, `feature_audits`, `audit_events` |

### 4.7 Urutan Pembuatan

1. `app_meta`, `owner_identity`, `licenses`, `login_guards`, `devices`
2. `audit_events`, `feature_audits`
3. `employee_accounts`, `employee_payroll_profiles`, `employee_store_access`
4. `customers`, `vehicle_or_units`
5. `stock_items`, `stock_balances`, `stock_movements`, `opname_holds`
6. `harga_jasa`, `suppliers`, `supplier_items`, `followups`, `followup_events`, `wa_message_logs`
7. `store_settings`, `store_features`
8. `service_records`, `service_jobs`, `service_parts`, `service_payments`, `nota_adjustments`, `service_record_mechanics`, `service_record_commissions`
9. `sale_returns`, `sale_return_items`, `sale_return_reversals`
10. `supplier_purchases`, `supplier_purchase_items`, `supplier_payments`, `supplier_purchase_returns`, `supplier_purchase_return_items`, `purchase_return_reversals`
11. `opening_balances`, `opening_balance_items`, `opening_receivables`, `receivable_payments`, `opening_payables`, `payable_payments`
12. `cash_ledger`, `pajak_pembayaran`, `salary_payments`, `salary_components`, `employee_debts`, `employee_debt_payments`
13. `estimates`, `estimate_items`, `work_orders`, `work_order_status_log`, `document_counters`
14. `day_digests`, `reconciliation_requests`, `debt_reminder_logs`
15. `sync_outbox`, `sync_inbox`, `sync_cursor`, `applied_deltas`, `sync_conflicts`, `device_sync_status`
16. Index, trigger, dan `PRAGMA foreign_keys=ON`
17. Seed `store_features` default dan `store_settings`

**Trigger wajib:**
- imutabilitas nota/baris/retur;
- VOID terminal;
- batas qty retur;
- update `stock_balances` dari `stock_movements` (atau service transaksi);
- larangan update/hapus `cash_ledger`;
- audit fitur.

### 4.8 Risiko Integritas yang Harus Dijaga

| Risiko | Mitigasi |
|---|---|
| `store_id` bukan FK karena registry eksternal | Validasi di service; CHECK `store_id <> ''` |
| Polymorphic `cash_ledger.sumber_*` | Unique index; validasi entity yang diizinkan |
| Ledger vs balance drift | Rebuild fungsi; trigger; rekonsiliasi harian |
| HLC konflik | Aturan konflik eksplisit; jangan menimpa tanpa catatan |
| Snapshot tidak lengkap | Daftar tabel dari skema; sertakan cash/opname/audit |
| Restore lintas versi | Metadata versi; migrasi; tolak downgrade |
| Multi-toko | Kunci global saat switch; filter `store_id` di semua query |
| Cost state | Turunkan dari ledger; jangan simpan angka yang tidak dapat direbuild |
| PPN | Satu fungsi pajak; kolom eksplisit; laporan dari satu sumber |
| Idempotensi | Hash payload; unique request_id |

### 4.9 Yang **Tidak** Dilakukan Audit Ini

- Tidak membuat/menghapus tabel.
- Tidak menjalankan migrasi.
- Tidak mengubah source.
- Tidak menjalankan test/build.
- Tidak menentukan apakah data lama harus dipertahankan (tidak ada data produksi).

---

## 5. FEATURE TOGGLE IMPLEMENTATION PLAN

### 5.1 Tujuan

- Satu sumber konfigurasi per toko.
- ON/OFF berlaku di **semua jalur akses**: UI, service, remote/sync, snapshot, ekspor.
- OFF tidak menghapus/mengubah data, saldo, atau histori.
- Hanya owner yang dapat mengubah.
- Ada audit dan peringatan dependensi.

### 5.2 Katalog Modul dan Fitur

| Key | Nama | Jenis | Default | Dependensi | Perilaku OFF |
|---|---|---|---|---|---|
| `penjualan` | Penjualan | Wajib | ON | — | Tidak dapat dimatikan |
| `pembelian` | Pembelian | Wajib | ON | — | Tidak dapat dimatikan |
| `persediaan` | Persediaan | Wajib | ON | — | Tidak dapat dimatikan |
| `kas` | Kas | Wajib | ON | — | Tidak dapat dimatikan |
| `laporan` | Laporan | Wajib | ON | — | Tidak dapat dimatikan |
| `pengaturan` | Pengaturan | Wajib | ON | — | Tidak dapat dimatikan |
| `backup` | Backup/Restore | Wajib | ON | — | Tidak dapat dimatikan |
| `sinkronisasi` | Sinkronisasi | Wajib | ON | — | Tidak dapat dimatikan |
| `estimasi` | Estimasi | Opsional | ON | — | Blokir buat/ubah/konversi; histori tetap terlihat |
| `order_kerja` | Order Kerja | Opsional | ON | `estimasi` (disarankan) | Blokir order baru; order lama tetap |
| `supplier_hub` | Supplier Hub | Opsional | ON | `pembelian` | Blokir master/relasi supplier baru; histori tetap |
| `purchase_debt` | Utang Pembelian | Opsional | ON | `supplier_hub` + `pembelian` | Blokir pembelian kredit; pembayaran utang lama tetap |
| `followup` | Follow-up | Opsional | ON | — | Blokir follow-up baru; histori tetap |
| `unit_kendaraan` | Unit Kendaraan | Opsional | ON | — | Sembunyikan input unit; nota lama tetap |
| `whatsapp` | WhatsApp | Opsional | ON | `followup` | Blokir kirim baru; log lama tetap |
| `payroll` | Payroll | Opsional | ON | akun karyawan | Blokir gaji baru; slip lama tetap |
| `komisi` | Komisi | Opsional | ON | `payroll` (disarankan) | Blokir komisi baru; snapshot lama tetap |
| `multi_toko` | Multi-toko | Opsional | ON (premium) | lisensi | Blokir tambah/pindah toko; data toko lama tetap |
| `ppn` | PPN | Opsional | ON | — | Blokir transaksi ber-PPN baru; nota lama tetap |

**Catatan default:** mempertahankan default ON sesuai perilaku saat ini (7 flag). Untuk instalasi baru, pemilik dapat memilih preset “ringkas” yang mematikan fitur opsional; keputusan ini bisnis, bukan teknis.

### 5.3 Arsitektur

```
FeatureCatalog (kode, immutable)
  ├─ key, nama, jenis, default, dependencies
  └─ validasi key

FeatureFlagsService
  ├─ load(storeId) → baca store_features + cache
  ├─ isEnabled(key) → cache; jika belum load → throw/block (fail closed)
  ├─ requireEnabled(key) → throw FeatureDisabled
  ├─ setEnabled(key, value, actor, reason)
  │    ├─ actor.isOwner
  │    ├─ cek dependensi
  │    ├─ cek fitur wajib
  │    ├─ tulis store_features + feature_audits
  │    └─ update cache
  └─ dependencies(key) → untuk warning UI
```

### 5.4 Sumber Tunggal

- **`store_features`** adalah satu-satunya sumber status per toko.
- `store_settings` tidak boleh menyimpan flag duplikat.
- `app_settings` tidak boleh menyimpan flag global.
- Cache hanya turunan; tidak boleh menjadi sumber keputusan jika belum dimuat.
- Snapshot menyertakan `store_features`; restore mengganti status.
- Remote `store_feature` hanya diterima dari owner (sudah ada di `ownerOnlyEntities`).

### 5.5 Penegakan di Semua Jalur

| Jalur | Penegakan |
|---|---|
| UI menu | Sembunyikan menu; jangan hanya disable |
| UI aksi | Cek `requireEnabled` sebelum membuka form |
| Service lokal | `FeatureGate.require(key, storeId)` di awal operasi tulis |
| Service remote | Tolak/queue `FeatureDisabled` untuk dokumen baru fitur OFF; histori tetap diterima |
| Snapshot | Terima semua data histori; status fitur dari payload |
| Backup/restore | Sertakan `store_features`; restore status |
| Sync outbox | Jangan membuat outbox untuk operasi yang ditolak |
| Ekspor/laporan | Tampilkan histori; tandai periode fitur OFF |
| Deep link/route | Cek fitur sebelum render layar |

**Aturan remote:** dokumen yang dibuat saat fitur ON harus tetap diterima meskipun fitur sekarang OFF. Untuk mencegah data baru saat OFF, gunakan metadata `feature_enabled_at_creation` atau waktu HLC; jika ragu, terima sebagai konflik untuk ditinjau, bukan dibuang diam-diam.

### 5.6 Dependensi dan Peringatan

- Menyalakan `purchase_debt` tanpa `supplier_hub` → tolak dengan pesan.
- Mematikan `supplier_hub` saat `purchase_debt` ON → minta konfirmasi; matikan anak atau blokir.
- Mematikan `estimasi` saat ada order kerja aktif → peringatan; histori tetap.
- Mematikan `whatsapp` tidak menghapus log.
- Mematikan `multi_toko` saat ada lebih dari satu toko → blokir (data tidak boleh hilang).
- Setiap perubahan menampilkan ringkasan dampak: fitur anak, data historis yang tetap terlihat, dan akses yang diblokir.

### 5.7 Perilaku OFF

**Yang tidak boleh terjadi:**
- menghapus data;
- mengubah saldo/histori;
- menyembunyikan laporan historis;
- membuat dokumen baru;
- menerima dokumen remote baru;
- mengubah total nota lama.

**Yang harus terjadi:**
- menu dan form disembunyikan;
- service menolak dengan error yang jelas;
- laporan tetap dapat membaca data lama;
- status “nonaktif” terlihat di pengaturan;
- audit mencatat siapa, kapan, alasan.

### 5.8 Otorisasi dan Audit

- Hanya `actor.isOwner` yang dapat mengubah.
- Minta PIN owner untuk perubahan.
- `feature_audits`: `store_id`, `feature_key`, `before_enabled`, `after_enabled`, `actor`, `reason`, `created_at`.
- Tampilkan riwayat perubahan di layar pengaturan.
- Perubahan dari remote harus ditandatangani owner dan dicatat.

### 5.9 UI “Manajemen Modul dan Fitur”

1. Daftar modul wajib (tidak dapat dimatikan) dan opsional.
2. Status ON/OFF, dependensi, dan peringatan.
3. Penjelasan singkat dampak OFF: “Data historis tetap tersimpan dan terlihat; pembuatan data baru diblokir.”
4. Konfirmasi sebelum mematikan fitur yang memiliki data aktif.
5. Riwayat perubahan.
6. Indikator “memuat” yang memblokir aksi sampai status pasti.

### 5.10 Kriteria Penerimaan

- Semua service fitur memanggil `requireEnabled`.
- Tidak ada fallback `true` sebelum load.
- OFF memblokir UI, service lokal, dan pembuatan dokumen remote baru.
- Histori tetap terbaca.
- Perubahan hanya owner + audit.
- Dependensi tidak dapat dilanggar.
- Snapshot/restore membawa status fitur.
- Ada uji statis bahwa setiap key fitur memiliki minimal satu pemanggilan gate di service.

---

## 6. Ringkasan Eksekutif Remediasi

- **P0** harus selesai sebelum rilis: PUR-01, FIN-01, DB-01/02/03, SEC-01.
- **P1** memperbaiki kepercayaan pada angka dan akses: SAL-01/03/04, PUR-02/03/05/06, RET-01, INV-01/02, FIN-02..06, DB-04/05/07/08, BAK-01, FLW-01, SEC-02..05/09, FEAT-01.
- **Database bersih** menghapus duplikasi qty, menyatukan audit, menjadikan ledger sumber kebenaran, dan menambahkan dokumen penyelesaian saldo awal.
- **Feature toggle** harus menjadi gerbang tunggal di service dan remote, bukan sekadar menu.
- Tidak ada implementasi yang dilakukan dalam audit ini.
