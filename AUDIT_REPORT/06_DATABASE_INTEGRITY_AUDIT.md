# 06 — Audit Integritas Database

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, atau simulasi runtime yang dijalankan. Tidak ada migrasi yang dieksekusi.

**Berkas utama:** `pusatkupos/lib/data/schema.dart`, `pusatkupos/lib/data/app_database.dart` (open/migrate/transaction/CRUD), `pusatkupos/lib/data/store_registry.dart`, `pusatkupos/lib/sync/snapshot_sync.dart`, `pusatkupos/lib/sync/snapshot_platform_io.dart`, `pusatkupos/lib/data/note_sync.dart`, `pusatkupos/lib/sync/sync_service.dart`.

---

## 1. Teknologi dan konfigurasi database

| Aspek | Implementasi |
|---|---|
| Mesin | SQLite via `sqflite`; SQLCipher di Android/iOS/macOS |
| Versi skema | `schemaVersion` = 4 |
| Pembuatan | `createCleanSchema` (skema bersih v1 + seluruh tabel saat ini) |
| Migrasi | Aditif V2–V4 (`schema.dart:4-59`) |
| Downgrade | Ditolak dengan `StateError` (`app_database.dart:231-240`) |
| Foreign key | `PRAGMA foreign_keys = ON` pada setiap open (`226`, `169-171`) |
| Uang | Integer sen |
| Kuantitas | Integer milli-unit |
| Soft delete | `deleted_at` pada banyak tabel transaksi/master |
| Multi-toko | Satu berkas database per toko; registry terpisah |
| Viewer | Database salinan terpisah, bukan database pembukuan (`app_database.dart:91-147`) |

**Penilaian konfigurasi:** keputusan memakai skema bersih + migrasi aditif dan menolak downgrade adalah pendekatan yang aman untuk mencegah aplikasi berjalan di atas skema tidak lengkap. Tidak ditemukan migrasi destruktif (DROP/rename) pada V2–V4.

---

## 2. Peta tabel dan relasi

### 2.1 Tabel transaksi inti

| Tabel | Kunci unik | Foreign key | Catatan |
|---|---|---|---|
| `service_records` | `sync_id`, `no_nota`, `request_id` | `unit_id → vehicle_or_units`, `customer_id → customers` (`SET NULL`) | Nota append-only; total asli tidak diubah koreksi |
| `service_jobs` | `sync_id` | `service_record_id → service_records` CASCADE | Menyimpan snapshot harga/modal |
| `service_parts` | `sync_id` | `service_record_id → service_records` CASCADE | Menyimpan `jumlah_milli`, modal |
| `service_payments` | `sync_id`, `request_id` | `service_record_id → service_records` CASCADE | Refund negatif |
| `stock_items` | `sync_id`, `kode` | — | `kode TEXT NOT NULL UNIQUE` (`schema.dart:298`) |
| `stock_movements` | `sync_id` | — (hanya `stock_item_id` biasa) | Tidak ada FK ke barang/nota |
| `sale_returns` | `sync_id` | `service_record_id → service_records` CASCADE | Append-only |
| `sale_return_items` | `sync_id` | `return_id → sale_returns` CASCADE | — |
| `nota_adjustments` | `sync_id` | — (merujuk `nota_sync_id`) | Append-only, koreksi absolut |
| `employee_accounts` | `sync_id` | — | Data lokal per perangkat; tidak ikut snapshot |
| `service_record_mechanics` | `sync_id`, `(record, employee)` | `service_record_id` CASCADE | `employee_sync_id` tanpa FK |
| `service_record_commissions` | `sync_id`, `(record, employee)` | `service_record_id` CASCADE | `employee_sync_id` tanpa FK |
| `employee_debts` | `sync_id` | — | `employee_sync_id` tanpa FK |
| `salary_payments` | `sync_id`, `(employee, cycle_start)` | — | `employee_sync_id` tanpa FK |
| `estimates` | `sync_id` | — | Index `(nomor_estimasi, versi)` **tidak unik** |
| `work_orders` | `sync_id` | — | — |
| `document_counters` | — | — | Per perangkat/jenis/tanggal |
| `store_settings` | `sync_id`, `store_id` PK | — | Izin per toko |

### 2.2 Konsekuensi relasi tanpa FK

- `service_record_commissions.employee_sync_id`, `salary_payments.employee_sync_id`, dan `employee_debts.employee_sync_id` tidak memiliki FK. Bila akun hilang (mis. perangkat baru tanpa `employee_accounts`), baris komisi/gaji tetap ada tetapi tidak dapat dihubungkan ke akun. Ini memperkuat **BL-07** dan **BL-04**.
- `stock_movements.stock_item_id` tidak memiliki FK; movement dapat menunjuk barang yang sudah dihapus. Ini laten karena tidak ada hapus barang di UI.
- `nota_adjustments.nota_sync_id` tidak memiliki FK; koreksi dapat menunjuk nota yang belum ada. Penerima menanganinya dengan membuang koreksi (BL-30).

**Penilaian:** FK diterapkan pada relasi parent-child inti (nota → baris → pembayaran/retur), sehingga penghapusan nota secara fisik akan CASCADE. Namun aplikasi memakai soft delete dan tidak menghapus nota, sehingga CASCADE jarang terpakai. Relasi lintas entitas bisnis (karyawan, supplier, adjustment) mengandalkan `sync_id` tanpa FK, sehingga integritasnya bergantung pada kode aplikasi.

---

## 3. Transaksi, rollback, dan konkurensi

### 3.1 Atomisitas

Penulisan multi-tabel dilakukan di dalam `db.transaction`:

- `createTransaction`: nota, baris, stok, movement, pembayaran, audit, komisi (`app_database.dart:1298-1746`).
- `voidRecord`: stok, movement, refund, status, estimasi/order, audit (`2607-2764`).
- `createReturn`: retur, item, stok, movement, refund, rekalkulasi, audit (`sale_return_service.dart:62-257`).
- `settleReceivable`: payment + update nota (`app_database.dart:2784-2855`).
- `paySalary`: hutang + gaji (`employee_service.dart:299-341`).
- `saveStockItem`, `stockIn/Out`, `opname`: barang + movement (`app_database.dart:865-1093`).

**Penilaian:** ini kontrol yang baik. Aplikasi yang ditutup atau error di tengah transaksi tidak meninggalkan nota/stok separuh jadi; SQLite rollback saat transaksi tidak selesai.

### 3.2 Konkurensi lokal

SQLite menserialisasi penulisan dalam satu koneksi. Tidak ditemukan penggunaan `BEGIN` manual atau koneksi tulis ganda. Risiko konkurensi yang tersisa adalah **antarperangkat**, bukan di dalam satu database (BL-01, BL-02, BL-03, BL-14, BL-21).

### 3.3 Idempotensi write

| Operasi | Kunci idempoten | Penilaian |
|---|---|---|
| Nota baru | `service_records.request_id` UNIQUE (`schema.dart:468`) | Baik |
| Pelunasan | `service_payments.request_id` UNIQUE, tetapi UI membuat ID baru tiap percobaan | Sebagian (BL-13) |
| Retur | Tidak ada | BL-13 |
| Gaji | UNIQUE(employee, cycle) per database, tetapi tidak lintas perangkat | BL-03 |
| Penerimaan sync | `sync_id` unik per baris; envelope cursor | Baik untuk duplikasi baris, kurang untuk aturan bisnis (BL-02, BL-30) |

---

## 4. Soft delete dan hard delete

- Nota, pelanggan, unit, barang, jasa, supplier, estimasi, dan follow-up memiliki `deleted_at`.
- Tidak ada jalur hapus nota di UI; nota dibatalkan lewat VOID.
- Tidak ada jalur hapus barang di UI; soft delete barang hanya mungkin dari payload sinkronisasi.
- `deleteSupplier` melakukan **hard delete** pada `supplier_items` dan `supplier_followups`, lalu soft delete supplier (`supplier_service.dart:123-153`). Relasi tidak memiliki tombstone → BL-38.
- `mergeCustomers` memindahkan unit, soft delete pelanggan asal, tetapi tidak memperbarui `service_records.customer_id` dan tidak memindahkan referensi follow-up → BL-16.
- Tabel dukungan (outbox/inbox/conflicts) dihapus/di-reset oleh mekanisme sinkronisasi; ini bukan data bisnis.

**Penilaian:** model soft delete konsisten untuk entitas utama. Masalah integritas muncul pada operasi yang memindahkan/menghapus relasi (merge pelanggan, hapus supplier), bukan pada mekanisme soft delete itu sendiri.

---

## 5. Query yang membaca data terhapus atau salah join

### 5.1 Riwayat pelanggan (BL-17)

`listRecords` dan `recordDetail` memakai:

```sql
LEFT JOIN customers c ON c.id = u.customer_id
```

Padahal nota menyimpan `service_records.customer_id` dan dapat memiliki `unit_id` NULL. Nota jual sparepart tanpa unit akan tampil tanpa nama pelanggan, dan pencarian berdasarkan nama pelanggan tidak menemukannya. `note_sync.dart:31` sudah memakai `COALESCE(r.customer_id, u.customer_id)`, sehingga ada inkonsistensi antar modul.

### 5.2 Stok terhapus (BL-26)

`listStock`, pengecekan kode duplikat, validasi stok penjualan, dan query dashboard tidak memfilter `deleted_at`. Saat ini belum ada UI hapus barang, sehingga dampaknya laten; tetap merupakan inkonsistensi query.

### 5.3 Query laporan

`reportSummary`, `dashboard`, dan `belowPriceSales` tidak memfilter `service_records.deleted_at`. Tidak ada jalur soft delete nota, sehingga belum berdampak. Bila fitur hapus nota ditambahkan nanti, query ini perlu disesuaikan.

---

## 6. Multi-toko dan database viewer

- `createDatabaseAt` membuat database baru dengan skema lengkap, lalu menyalin pengaturan, owner, dan lisensi sesuai opsi (`app_database.dart:149-192`).
- `createStore` menyalin owner dan lisensi, tetapi **tidak** menyalin `employee_accounts` (BL-07).
- Database viewer dibuka terpisah (`openViewerDatabase` `91-108`); pembatasan tulis hanya dari shell UI. Principal viewer dianggap owner (BL-28).
- Store registry menyimpan daftar toko di database kecil terpisah; operasi tulis registry memakai transaksi (`store_registry.dart:160-170`).

---

## 7. Penomoran dan penghitung

- `allocateDocumentNumber` membaca/menaikkan `document_counters` per perangkat/jenis/tanggal (`app_database.dart:2042-2076`).
- `document_counters` **tidak** ikut snapshot (`snapshot_sync.dart:12-90`).
- Kode perangkat 3 karakter dapat bentrok (BL-33).
- `service_records.no_nota` UNIQUE, sehingga bentrok antarperangkat diselesaikan dengan renumber + `sync_conflicts` (`note_sync.dart:444-490`).

### 7.1 Kode barang UNIQUE lintas perangkat (BL-41)

`stock_items.kode` adalah `TEXT NOT NULL UNIQUE` (`schema.dart:298`). Pemeriksaan duplikat di `saveStockItem` hanya berjalan lokal (`app_database.dart:839-851`). Saat penerapan sinkronisasi, barang baru di-insert berdasarkan `sync_id` tanpa memeriksa atau menomori ulang `kode` (`sync_service.dart:2890-2902`). Dua perangkat yang membuat kode sama saat offline akan membuat perangkat kedua gagal insert; kegagalan ini dicatat sebagai konflik, cursor tidak dimajukan (`sync_service.dart:1990-2015`), dan amplop berikutnya dalam urutan ikut tertahan. Berbeda dengan nomor nota yang memiliki jalur renumber, kode barang tidak memiliki mekanisme penyelesaian otomatis.

**Penilaian:** integritas nomor nota dijaga oleh UNIQUE, tetapi identitas nomor tidak stabil lintas perangkat. Ini masalah operasional/komunikasi, bukan korupsi database. Untuk kode barang, UNIQUE tanpa renumber justru menjadi titik macet sinkronisasi (BL-41).

---

## 8. Temuan integritas database

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-16 | Merge pelanggan tidak memindahkan nota tanpa unit/referensi | SEDANG | CONFIRMED |
| BL-17 | Riwayat join pelanggan hanya lewat unit | SEDANG | CONFIRMED |
| BL-26 | Query stok/kode abaikan soft delete | RENDAH | CONFIRMED |
| BL-27 | `actor == null` diperlakukan pemilik | RENDAH | CONFIRMED |
| BL-28 | Viewer dianggap owner; database viewer dapat ditulis | RENDAH | SUSPECTED |
| BL-33 | Kode perangkat/counter dokumen berpotensi bentrok | RENDAH | SUSPECTED |
| BL-07 | `employee_accounts`/`document_counters` tidak ikut snapshot | TINGGI | SUSPECTED |
| BL-30 | Adjustment remote dibuang bila nota belum ada/void | RENDAH | SUSPECTED |
| BL-41 | Kode barang duplikat lintas perangkat memblokir sinkronisasi | SEDANG | SUSPECTED |

Detail lengkap di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 9. Skenario kegagalan database

| Skenario | Mekanisme | Kesimpulan |
|---|---|---|
| Aplikasi ditutup mid-transaction | SQLite rollback | Tidak ada data separuh |
| Simpan gagal di tengah | `db.transaction` membatalkan seluruh langkah | Aman untuk nota/retur/void/stok |
| Dua perangkat menulis entitas sama | HLC + aturan konflik per entitas | Sebagian tertangani; aturan bisnis retur/gaji/stok belum |
| Database tidak dapat dibuka | `onDowngrade` menolak; error dilempar | Tidak berjalan di skema salah |
| Migrasi V2–V4 gagal | Migrasi aditif; error membatalkan open | Tidak ada DROP; namun tidak ada backup otomatis sebelum migrasi |
| Restore database rusak | Validasi tabel + `PRAGMA integrity_check` + rollback | Baik (lihat 07) |
| Snapshot menimpa data lokal | Tabel lokal di-drop dari snapshot | Sebagian data lokal hilang (BL-07) |
| Baris anak yatim | FK CASCADE untuk anak nota; tanpa FK untuk karyawan/supplier | Sebagian terlindungi |
| Nomor nota bentrok | UNIQUE + renumber + konflik | Nomor unik, tetapi tidak stabil |
| Kode barang bentrok | UNIQUE tanpa renumber; envelope gagal dan cursor tertahan | Sinkronisasi berhenti sampai konflik diselesaikan (BL-41) |
| Hapus supplier | Hard delete relasi tanpa tombstone | BL-38 |
| Merge pelanggan | Soft delete sumber, tidak update nota | BL-16 |

**Catatan migrasi:** tidak ada bukti bahwa migrasi membuat backup otomatis sebelum `ALTER TABLE`. Migrasi V2–V4 hanya menambah kolom/tabel dan mengisi nilai, sehingga risiko rendah; namun untuk migrasi destruktif di masa depan, mekanisme backup pra-migrasi perlu dipastikan.

---

## 10. Batas audit

- Tidak ada eksekusi `PRAGMA integrity_check` atau query database nyata.
- Skema dibaca dari kode; database pengguna dapat memiliki data/versi berbeda.
- Tabel relay PostgreSQL tidak diperiksa sebagai database; hanya alur aplikasi yang memakainya.
- Tidak ada pengujian migrasi dari database v1 nyata.
- Tidak ada analisis indeks performa; fokus audit adalah integritas, bukan kecepatan.

**Kesimpulan area:** fondasi database (skema, FK inti, transaksi, migrasi aditif, validasi restore) cukup kuat. Kelemahan integritas terkonsentrasi pada **relasi yang tidak memiliki FK**, **query yang mengabaikan soft delete/identitas pelanggan**, **operasi penggabungan/penghapusan yang tidak memindahkan referensi**, dan **batasan UNIQUE kode barang yang tidak memiliki jalur rekonsiliasi antardevice**. Tidak ditemukan bukti korupsi database pada jalur lokal normal.
