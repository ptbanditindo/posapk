# 04 — DATABASE INTEGRITY AUDIT

Ruang lingkup: primary key, foreign key, unique, index, nullability, default, tipe, migrasi, rollback, batas transaksi, integritas referensial, cascade, soft delete, inisialisasi, upgrade, korupsi, konkurensi, partial write, dan duplikasi. Fokus khusus: atomisitas alur penjualan.

---

## 1. Fakta Skema

| Aspek | Implementasi | Penilaian |
|---|---|---|
| Versi skema | `schemaVersion = 10` ([app_database.dart:41](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L41)) | OK |
| Marker versi | `.schema_version` di samping DB, dibaca sebelum buka | OK |
| Upgrade | `onUpgrade` → `runSchemaMigrations` v2–v10; setiap versi wajib ada | OK |
| Downgrade | `onDowngrade` → `_rejectIncompatibleVersion` | OK (fail-closed) |
| Backup pra-upgrade | `backupExistingDatabase` → `.bak-<stamp>` | OK, tapi manual recovery |
| Korupsi | `openSafeMode` memindahkan DB ke `.corrupt-*`, menghapus WAL/SHM, buka baru | **Cacat** (SEC-03) |
| FK | `PRAGMA foreign_keys = ON` ([app_database.dart:420](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L420)) | OK |
| Index | 52 `CREATE INDEX`, termasuk partial unique untuk kode/barcode aktif | OK |
| CHECK | Nominal utama, pajak, status, qty baris | Baik; `jumlah_milli` tidak |
| Soft delete | `deleted_at` di tabel master + partial unique | OK |
| Nomor nota | `no_nota TEXT NOT NULL UNIQUE` ([schema.dart:501](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema.dart#L501)) | OK |
| Immutability | Trigger mencegah update snapshot nota aktif | OK |
| Journal/WAL | Tidak ada `PRAGMA journal_mode`, `synchronous`, `busy_timeout` | **DB-02** |
| Integritas saldo | Tidak ada CHECK `jumlah_milli >= 0` | **DB-01 / INV-14** |

---

## 2. Atomisitas Alur Penjualan

`createTransaction` membungkus seluruh operasi berikut dalam satu `db.transaction`:
- insert `service_records`, item jasa, item part;
- insert pembayaran + `cash_ledger`;
- insert komisi;
- update link work order/estimasi;
- `StockLedger.apply` untuk setiap part;
- enqueue outbox.

Tidak ada `await` jaringan atau I/O eksternal di dalam transaksi. Persetujuan PIN diverifikasi **sebelum** transaksi dibuka, dengan alasan eksplisit agar penghitung gagal login tidak ikut rollback. Ini desain yang benar.

**Kesimpulan:** partial write pada nota tidak mungkin terjadi; kegagalan stok membatalkan seluruh nota.

---

## 3. Registry Temuan

### DB-01 — Skema tidak menegakkan saldo stok non-negatif
- **Severity:** MEDIUM
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Sesuai kebutuhan sync, tetapi tidak ada penanda kondisi
- **Lokasi:** [schema.dart:275](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema.dart#L275)
- **Fungsi/Kelas:** `createSchema` tabel `stock_items`
- **Implementasi:** Kolom `jumlah_milli INTEGER NOT NULL DEFAULT 0` tanpa CHECK. Nilai negatif hanya dicegah service lokal dan diizinkan sengaja oleh jalur sync (`allowNegative: true`).
- **Penyebab:** Keputusan stok negatif belum final.
- **Dampak:** Saldo negatif dapat bertahan tanpa status/alert; laporan stok dan HPP dapat aneh.
- **Skenario:** SC-02, keputusan bisnis #3.
- **Rekomendasi:** Putuskan kebijakan; bila negatif diizinkan, tambahkan kolom/flag dan laporan; bila tidak, tambahkan CHECK + tangani konflik sebelum insert.
- **Dependensi:** INV-14, INV-04.

### DB-02 — Tidak ada pragma konkurensi/journal eksplisit
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT
- **Status:** NEEDS VALIDATION (perilaku runtime)
- **Lokasi:** [app_database.dart:420](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L420)
- **Fungsi/Kelas:** `_configure`
- **Implementasi:** Hanya `PRAGMA foreign_keys = ON`. Tidak ada `journal_mode=WAL`, `synchronous`, atau `busy_timeout`. BackupScheduler, SyncScheduler, dan UI memakai instance DB yang sama; sqflite menyerialkan operasi dalam satu proses, tetapi proses lain (viewer DB terpisah, alat eksternal) dapat memicu `SQLITE_BUSY`.
- **Penyebab:** Mengandalkan default factory.
- **Dampak:** Potensi `database is locked` saat backup/restore/upgrade bersamaan.
- **Rekomendasi:** Set `busy_timeout`, pilih journal mode yang disengaja, dan uji beban sinkron.
- **Dependensi:** ERR-04.

### DB-03 — Database plaintext di Windows/Linux/web
- **Severity:** MEDIUM
- **Kategori:** SECURITY WEAKNESS
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:407](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L407), [app_database.dart:475](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L475)
- **Fungsi/Kelas:** `_databasePassword`, `_open`
- **Implementasi:** SQLCipher hanya dipakai pada Android/iOS/macOS. Di Windows/Linux/web, SQLite dibuka tanpa enkripsi.
- **Penyebab:** Keterbatasan dukungan platform.
- **Dampak:** Nama pelanggan, nomor telepon, harga, dan nominal terbaca dari file DB oleh siapa pun yang memiliki akses filesystem.
- **Rekomendasi:** Dokumentasikan sebagai batasan platform; gunakan enkripsi disk/OS atau SQLCipher desktop bila tersedia.
- **Dependensi:** SEC-09.

### DB-04 — Pembulatan REAL pada laporan dapat menghasilkan selisih 1–2 sen
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [purchase_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/purchase_service.dart), [app_database.dart:4009](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4009)
- **Fungsi/Kelas:** Query laporan
- **Implementasi:** Sebagian agregasi memakai pembagian REAL/`ROUND`, sebagian memakai integer division/truncation.
- **Dampak:** Selisih kecil antar laporan.
- **Rekomendasi:** Standarkan aritmetika integer (basis milli/cents) di semua agregasi.
- **Dependensi:** REP-08.

### DB-05 — Tidak ada jalur rollback migrasi terotomasi
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [schema_migrations.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema_migrations.dart), [app_database.dart:522](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L522)
- **Fungsi/Kelas:** `runSchemaMigrations`; `_prepareSchemaUpgrade`
- **Implementasi:** Tidak ada down-migration. Rollback hanya mungkin dengan memulihkan file `.bak-<stamp>` secara manual. Bila migrasi gagal di tengah, `onUpgrade` melempar dan DB mungkin tertinggal pada versi antara; marker baru ditulis setelah sukses.
- **Penyebab:** SQLite tidak mendukung DDL transaksional penuh untuk semua operasi.
- **Dampak:** Kegagalan upgrade dapat memaksa intervensi manual; pengguna awam tidak punya jalur pemulihan di UI.
- **Rekomendasi:** Tambahkan pemulihan otomatis dari `.bak` bila upgrade gagal, dengan konfirmasi; uji setiap langkah migrasi pada salinan data nyata.
- **Dependensi:** ERR-03, SEC-11.

### DB-06 — Safe mode menghapus WAL/SHM sehingga data ter-commit dapat hilang dari karantina
- **Severity:** MEDIUM
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Terkonfirmasi (kanonik: SEC-03)
- **Lokasi:** [app_database.dart:132](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L132), [backup_platform_io.dart:78](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_platform_io.dart#L78)
- **Fungsi/Kelas:** `openSafeMode`; `deleteDatabaseFiles`/quarantine helper
- **Implementasi:** DB utama dipindahkan ke `.corrupt-*`, lalu file `-wal`/`-shm` dihapus. Transaksi yang sudah commit tetapi belum checkpoint berada di WAL dan ikut hilang.
- **Penyebab:** Karantina hanya memindahkan file utama.
- **Dampak:** Kehilangan transaksi terakhir saat pemulihan korupsi; bertentangan dengan prinsip "recovery tidak menimpa data valid".
- **Rekomendasi:** Pindahkan WAL/SHM bersama DB ke folder karantina, lalu coba `PRAGMA wal_checkpoint` pada salinan sebelum membuka DB baru.
- **Dependensi:** ERR-03.

---

## 4. Duplikasi dan Konkurensi

| Risiko | Kontrol yang ada | Status |
|---|---|---|
| Nota ganda request id sama | `request_id` + hash | PASS |
| Nota ganda request id beda (tap ganda UI) | UI mempertahankan id; perlu reset | NEEDS VALIDATION |
| Pembelian ganda | Service mendukung requestId; UI tidak mengirim | **FAIL (INV-12)** |
| Movement stok ganda | `movementSyncId` unik | PASS |
| Retur ganda | `sync_id` unik + validasi kumulatif | PASS |
| Pembayaran ganda | `sync_id`/`request_id` + cash ledger ignore | PASS |
| Opname ganda | Tidak ada request id | **FAIL (INV-11)** |
| Dua penulis DB | Pragma konkurensi tidak diset | **DB-02** |
| Soft delete bentrok kode | Partial unique index aktif | PASS |

---

## 5. Kesimpulan Integritas

Skema jauh lebih disiplin daripada rata-rata aplikasi POS lokal: FK aktif, CHECK nominal, partial unique, trigger imutabilitas, dan seluruh mutasi kritikal berada dalam transaksi. Risiko utama bukan pada constraint dasar, melainkan pada:
1. kebijakan stok negatif yang belum ditegakkan/tercatat;
2. jalur pemulihan korupsi yang dapat membuang WAL;
3. migrasi tanpa rollback otomatis;
4. konkurensi yang tidak dikonfigurasi eksplisit;
5. enkripsi DB yang tidak merata antar platform.
