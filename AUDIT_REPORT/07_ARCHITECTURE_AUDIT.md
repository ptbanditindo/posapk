# 07 — ARCHITECTURE AUDIT

Ruang lingkup: struktur proyek, pemisahan layer, arah dependensi, batas modul, isolasi fitur, duplikasi aturan bisnis, dan konsekuensi arsitektural terhadap integritas data.

---

## 1. Peta Arsitektur

```
lib/
  main.dart                → runZonedGuarded, entry
  app.dart                 → MaterialApp, busy overlay
  core/                    → startup, money, logging, utils
  data/                    → SQLite, model, service domain, backup
  sync/                    → SyncService, scheduler
  ui/                      → screen, widget, gate, recovery
relay/
  bin/relay.dart           → HTTP server, maintenance
  lib/server.dart          → route, auth, envelope
  lib/sync_round.dart      → ack/pruning
  lib/db.dart              → PostgreSQL
  lib/auth_rules.dart      → aturan autentikasi
```

**Penilaian:** Struktur layer jelas dan mudah ditelusuri. `ui` memanggil `data`/`sync`; `data` tidak memanggil `ui`. Enkripsi berada di boundary sync. Tidak ditemukan import melingkar yang merusak arsitektur.

---

## 2. Registry Temuan

### ARC-01 — Aturan harga/persetujuan terbelah antara UI dan service
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [pos_screen.dart:768](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L768), [app_database.dart:1884](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1884), [order_service.dart:774](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/order_service.dart#L774)
- **Fungsi/Kelas:** Alur persetujuan diskon/harga
- **Implementasi:** UI memutuskan kapan menampilkan PIN dan parameter apa yang dikirim; service memiliki dua mekanisme persetujuan (`ownerPin`/`approverSecret` vs `approvedByOverride`). Keduanya tidak berbagi kontrak yang sama.
- **Penyebab:** Persetujuan tumbuh sebagai tambalan di dua tempat.
- **Dampak:** PIN tidak mengizinkan harga bawah minimum (TRX-08); override dari estimasi dipercaya tanpa verifikasi (SEC-08); perilaku berbeda antar jalur.
- **Rekomendasi:** Satu objek `ApprovalGrant` yang diterbitkan service persetujuan, berisi scope (diskon/harga bawah minimum/harga nol), approver, waktu, dan bukti verifikasi. Semua jalur membuat nota memakai grant itu.
- **Dependensi:** TRX-07, TRX-08, SEC-08.

### ARC-02 — Dua sumber modal/HPP
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP / DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:2085](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2085), [stock_ledger.dart:324](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L324), [sale_return_service.dart:683](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/sale_return_service.dart#L683)
- **Implementasi:** Penjualan memakai `stock_items.harga_modal`; HPP laporan memakai rata-rata bergerak ledger; retur memakai master saat ini.
- **Dampak:** Batas harga, laba, dan nilai retur tidak berbicara tentang angka yang sama.
- **Rekomendasi:** Tetapkan `StockLedger.averageCostMilli` sebagai satu-satunya sumber modal; snapshot ke baris nota saat transaksi; gunakan snapshot itu untuk retur/laporan.
- **Dependensi:** TRX-06, INV-05, REP-01/02.

### ARC-03 — Logika penerapan sync menduplikasi aturan domain dengan hasil berbeda
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [note_sync.dart:400](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L400), [app_database.dart:3630](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3630), [sale_return_service.dart:526](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/sale_return_service.dart#L526)
- **Implementasi:** Void lokal menolak bila ada retur aktif; void remote menerapkan dengan konflik. Pembatalan retur lokal tanpa clamp; remote dengan clamp. Restock lokal memakai retur aktif; remote tanpa filter status.
- **Penyebab:** Dua implementasi aturan yang sama.
- **Dampak:** Divergensi data dan double refund (INV-03).
- **Rekomendasi:** Ekstrak satu fungsi domain `applyVoid`/`cancelReturn` yang dipakai lokal dan remote, dengan parameter kebijakan konflik eksplisit.
- **Dependensi:** INV-02, INV-03, INV-07.

### ARC-04 — Penulisan audit bisnis tidak konsisten antar modul
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP / SECURITY WEAKNESS
- **Status:** Terkonfirmasi
- **Lokasi:** [schema.dart:177](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema.dart#L177), [app_database.dart:1671](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1671), [app_database.dart:1769](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1769)
- **Implementasi:** Tabel `business_audits` **ada** dan ditulis oleh pembelian, retur penjualan, karyawan, saldo awal, pembayaran pajak, feature flag, dan pengaturan toko. Namun penyesuaian stok manual (`_adjustStock`), simpan/hapus katalog, dan void nota tidak menulis `business_audits`; `_adjustStock` bahkan tidak meneruskan `operator` ke ledger. `AppLog` hanya mencatat event teknis.
- **Penyebab:** Audit ditambahkan per modul, bukan sebagai kebijakan domain.
- **Dampak:** Sebagian aksi istimewa tidak memiliki jejak aktor/alasan yang dapat ditinjau; pemilik tidak dapat membandingkan siapa mengubah apa.
- **Rekomendasi:** Wajibkan `business_audits` untuk semua aksi istimewa (stok, katalog, void, restore, logout, pencabutan perangkat) melalui helper tunggal.
- **Dependensi:** INV-09, SEC-07, SEC-10.

### ARC-05 — Scheduler latar menelan kegagalan tanpa health surface
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_scheduler.dart), [backup_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_scheduler.dart)
- **Implementasi:** Kedua scheduler menangkap error dan menyimpannya sebagai status/`last_error`; tidak ada indikator kesehatan yang menonjol di UI.
- **Dampak:** Backup/sync dapat berhenti berhari-hari tanpa diketahui.
- **Rekomendasi:** Panel status operasional: last sync, last backup, pending count, storage relay, error terakhir.
- **Dependensi:** OFF-03.

### ARC-06 — Relay tidak memiliki layanan arsip/pencarian
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart), [relay/bin/relay.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/bin/relay.dart)
- **Implementasi:** Relay hanya auth, envelope ingest/feed/ack, snapshot, sync round, dan pruning. Tidak ada endpoint kueri dokumen.
- **Dampak:** SC-04 tidak dapat dipenuhi; riwayat jangka panjang bergantung pada perangkat.
- **Rekomendasi:** Rancang layanan arsip terenkripsi dengan indeks non-plaintext (lihat SEC-16) atau nyatakan di luar lingkup.
- **Dependensi:** SYN-02, SYN-07, SEC-16.

---

## 3. Batas Kepercayaan (Trust Boundary)

| Boundary | Apa yang dipercaya | Risiko |
|---|---|---|
| UI → Service | Parameter dari UI (harga terdaftar, approvedByOverride) | UI dapat melewati kontrol (TRX-01/08) |
| Lokal → Relay | Relay menyimpan ciphertext + metadata | Metadata bocor (SEC-16); relay kompromi dapat memaksa snapshot (SYN-04) |
| Relay → PostgreSQL | Kredensial DB dari env | TLS default mati (SEC-14) |
| Perangkat → Perangkat | Store key yang dibagikan owner | Tidak ada rotasi/escrow (SEC-12/13) |
| Restore → DB | File backup + passphrase | Tanpa auth owner, tanpa cek outbox (SEC-01/04) |

---

## 4. Kesimpulan Arsitektur

Arsitektur dasar sehat: layer jelas, transaksi atomik, boundary enkripsi nyata, dan relay tipis yang tidak membaca plaintext. Kelemahan utama bersifat **konsistensi aturan**: aturan domain diduplikasi antara UI, service lokal, dan penerap sync; modal/HPP punya dua definisi; dan operasi istimewa tidak memiliki audit trail. Perbaikan arsitektural yang paling berdampak adalah mengekstrak aturan domain tunggal (harga, approval, void/retur, valuasi) dan memakainya di semua jalur.
