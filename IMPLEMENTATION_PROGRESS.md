# PROGRES IMPLEMENTASI — 12_IMPLEMENTATION_ORDER

**Tujuan:** catatan hidup eksekusi `AUDIT_REPORT/12_IMPLEMENTATION_ORDER.md`. File ini memungkinkan pekerjaan dilanjutkan setelah berhenti di tengah jalan (API habis, sesi terputus, mesin mati).

**Sumber rencana:** [AUDIT_REPORT/12_IMPLEMENTATION_ORDER.md](AUDIT_REPORT/12_IMPLEMENTATION_ORDER.md)
**Registri temuan:** [AUDIT_REPORT/01_BUSINESS_LOGIC_DEFECTS.md](AUDIT_REPORT/01_BUSINESS_LOGIC_DEFECTS.md)
**Rencana remediasi & skema bersih:** [AUDIT_REPORT/11_REMEDIATION_ROADMAP.md](AUDIT_REPORT/11_REMEDIATION_ROADMAP.md)

---

## 1. ATURAN PEMBARUAN (WAJIB)

1. Satu task = satu baris di tabel tahap. **Setelah task selesai, langsung ubah file ini pada respons yang sama** — jangan menunda ke akhir tahap.
2. Status hanya boleh naik berdasarkan bukti nyata:
   - `✅` = perubahan ada di working tree/commit **dan** verifikasi dijalankan (atau dijelaskan mengapa verifikasi tidak bisa dijalankan).
   - `🔄` = sedang dikerjakan, belum ada bukti lengkap.
   - `⬜` = belum dikerjakan.
   - `⏸` = menunggu keputusan bisnis pemilik (lihat §4).
   - `⛔` = terblokir teknis (tuliskan alasan persis).
3. Kolom **Bukti** minimal berisi `file:baris` atau hash commit. Jangan menulis "sudah diperbaiki" tanpa bukti.
4. Setiap perubahan juga dicatat di **Riwayat** (§6) dengan tanggal, task, dan ringkasan.
5. Jangan menandai tahap selesai sebelum seluruh Definition of Done tahap itu terpenuhi.
6. Jangan mengklaim build/test lulus bila toolchain tidak tersedia. Tulis `TIDAK DIJALANKAN` + alasan.

## 2. LEGENDA

| Simbol | Arti |
|---|---|
| ✅ | Selesai + bukti |
| 🔄 | Sedang dikerjakan |
| ⬜ | Belum |
| ⏸ | Menunggu keputusan bisnis |
| ⛔ | Terblokir teknis |

## 3. TITIK LANJUT (perbarui setiap task)

- **Terakhir selesai:** 1.1 — kunci versi Flutter & dependency lock (2026-11-09)
- **Sedang dikerjakan:** —
- **Berikutnya:** 1.2 — harness unit test service + widget test alur kritis
- **Blocker aktif:** Flutter CLI tidak terdeteksi di PATH mesin ini (`command -v flutter` kosong). Verifikasi build/test lokal belum bisa dijalankan; CI GitHub Actions tetap menjadi jalur verifikasi.
- **Catatan lingkungan:** Windows 10.0.26200, Node v24.18.0, Git Bash. Flutter target proyek: 3.47.9 (Dart 3.13.7), JDK 17, Android SDK.

---

## 4. KEPUTUSAN BISNIS TERTUNDA

Task berikut tidak boleh diselesaikan dengan asumsi; tunggu keputusan pemilik (rujukan `12` §7).

| Task | Temuan | Pertanyaan |
|---|---|---|
| 4.3 | SAL-03 | Apakah jasa bebas diizinkan? Siapa boleh menetapkan harga? |
| 4.4 | SAL-04 | Batas kredit, izin kredit, dan jatuh tempo wajib? |
| 5.3 | PUR-04 | Refund mengikuti metode pembayaran asal atau pilihan pengguna? |
| 5.5 | RET-01 | Siapa boleh reversal dan perlu approval kedua? |
| 6.7 | INV-06 | Modal saldo awal boleh berbeda dari master? |
| 6.14 | FIN-06 | Carry-forward PPN / kompensasi kelebihan bayar? |
| 8.1 | SEC-01 | Sign-out menghapus database atau mengunci perangkat? |

Catatan: task lain yang menyentuh aturan bisnis tetap boleh dikerjakan memakai rekomendasi audit, lalu disesuaikan bila keputusan berbeda.

---

## 5. RINGKASAN TAHAP

| Tahap | Nama | Status | Progres | Commit | Berikutnya |
|---|---|---|---:|---|---|
| 1 | Fondasi aman dan observabilitas | 🔄 | 1/7 | — | 1.2 |
| 2 | Database bersih dan identitas tunggal | ⬜ | 0/8 | — | 2.1 |
| 3 | Integritas data dan sinkronisasi | ⬜ | 0/7 | — | 3.1 |
| 4 | Logika inti penjualan dan estimasi | ⬜ | 0/9 | — | 4.1 |
| 5 | Retur dan pembatalan | ⬜ | 0/8 | — | 5.1 |
| 6 | Persediaan dan keuangan | ⬜ | 0/15 | — | 6.1 |
| 7 | Backup dan restore | ⬜ | 0/8 | — | 7.1 |
| 8 | Keamanan dan error handling | ⬜ | 0/11 | — | 8.1 |
| 9 | Feature toggle | ⬜ | 0/9 | — | 9.1 |
| 10 | UI/flow dan verifikasi akhir | ⬜ | 0/8 | — | 10.1 |

**Total task:** 90.

---

## 6. DETAIL PER TAHAP

### TAHAP 1 — Fondasi Aman dan Observabilitas

**Prasyarat:** tidak ada. **Sifat:** WAJIB, sekuensial pertama.
**DoD:** build reproducible; harness berjalan; log/diagnostik bebas data sensitif; baseline DB kosong dapat dibackup/restore/dibuka; tidak ada perubahan perilaku bisnis.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 1.1 | Kunci versi Flutter & dependency lock (build reproducible) | — | ✅ | `.github/workflows/ci.yml` (3 blok `flutter-action` kini `flutter-version: '3.47.9'`); `pusatkupos/pubspec.lock` sudah terlacak git; `.metadata` revision `c197ca5199e9ee5661e865596c9c07294dfab51c` | `git ls-files pusatkupos/pubspec.lock` → ada; `git diff` → 3 penggantian; build lokal TIDAK DIJALANKAN (Flutter CLI tidak tersedia) | 2026-11-09 |
| 1.2 | Harness unit test service + widget test alur kritis (kerangka) | — | ⬜ | — | — | — |
| 1.3 | Database uji in-memory/SQLite sementara (bukan data produksi) | — | ⬜ | — | — | — |
| 1.4 | Logging terstruktur (database, sync, backup, auth, business) | — | ⬜ | — | — | — |
| 1.5 | Ekspor diagnostik (versi app/skema, status sync, error terakhir) tanpa data sensitif | — | ⬜ | — | — | — |
| 1.6 | Baseline backup database kosong + verifikasi dapat dibuka | — | ⬜ | — | — | — |
| 1.7 | Dokumentasi matriks perangkat/platform yang didukung | — | ⬜ | — | — | — |

**Checklist DoD Tahap 1:** ⬜ build reproducible · ⬜ harness jalan · ⬜ log bebas rahasia · ⬜ baseline backup/restore · ⬜ perilaku bisnis tidak berubah

**Catatan:** 1.2 dan 1.3 saling terkait; kerjakan 1.3 lebih dulu bila harness butuh database uji.

---

### TAHAP 2 — Database Bersih dan Identitas Tunggal

**Prasyarat:** Tahap 1. **Temuan:** INV-05, DB-03, DB-10, DB-11.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 2.1 | Terapkan skema bersih (`11` §4) sebagai versi baru | — | ⬜ | — | — | — |
| 2.2 | Hapus `stock_items.jumlah`; `jumlah_milli NOT NULL` (backfill hanya dev) | INV-05 | ⬜ | — | — | — |
| 2.3 | Hapus `employee_accounts.store_ids_json`; `employee_store_access` sumber tunggal | DB-10 | ⬜ | — | — | — |
| 2.4 | Hapus tabel `sync_peer_digests` | DB-11 | ⬜ | — | — | — |
| 2.5 | Satukan jalur buka DB (`_open`, `createDatabaseAt`, `createEncryptedCopy`, viewer) via SQLCipher | DB-03 | ⬜ | — | — | — |
| 2.6 | Tambah `app_meta`/`licenses` (rename) + metadata versi | — | ⬜ | — | — | — |
| 2.7 | Tambah tabel fondasi: `stock_balances`, `audit_events`, `feature_audits`, `employee_payroll_profiles`, `salary_components` | — | ⬜ | — | — | — |
| 2.8 | `PRAGMA foreign_keys = ON` di semua koneksi | — | ⬜ | — | — | — |

**Checklist DoD Tahap 2:** ⬜ DB baru terbuka di Android SQLCipher & desktop SQLite · ⬜ tidak ada kolom `jumlah` · ⬜ satu sumber keanggotaan · ⬜ `sync_peer_digests` hilang · ⬜ toko baru terbuka via jalur enkripsi · ⬜ `schema_version` eksplisit

---

### TAHAP 3 — Integritas Data dan Sinkronisasi

**Prasyarat:** Tahap 2. **Temuan:** DB-01, DB-07, DB-08, DB-09.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 3.1 | Generate daftar tabel snapshot dari skema; sertakan `cash_ledger`, `opname_holds`, `audit_events` (atau dokumentasikan lokal + rekonsiliasi) | DB-01 | ⬜ | — | — | — |
| 3.2 | Samakan `snapshotDeleteOrder` dengan daftar tabel snapshot | DB-01 | ⬜ | — | — | — |
| 3.3 | Metadata versi pada payload snapshot | DB-04 | ⬜ | — | — | — |
| 3.4 | Nota → stok: kode bentrok jadi kode sementara unik + `sync_conflicts`, nota tidak gagal | DB-07 | ⬜ | — | — | — |
| 3.5 | Kunci global `switchStore`: tunggu sync, hentikan scheduler, rollback bila gagal | DB-08 | ⬜ | — | — | — |
| 3.6 | Insert `stock_movements` setelah keputusan `applyQuantity` | DB-09 | ⬜ | — | — | — |
| 3.7 | Validasi `store_id` pada penerapan remote | DB-08 | ⬜ | — | — | — |

**Checklist DoD Tahap 3:** ⬜ snapshot membawa kas & opname · ⬜ nota kode bentrok tetap masuk · ⬜ switch toko tidak memutus sync · ⬜ tidak ada movement tidak diterapkan · ⬜ snapshot idempoten

---

### TAHAP 4 — Logika Inti Penjualan dan Estimasi

**Prasyarat:** Tahap 2 & 3. **Temuan:** SAL-01..07, BIZ-01.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 4.1 | Simpan `dpp_cents`, `ppn_cents`, `total_ditagih_cents`, `pajak_mode`, `pajak_penanggung`; konversi menyalin snapshot; diskon dari harga sebelum pajak | SAL-01 | ⬜ | — | — | — |
| 4.2 | Simpan `jenis_transaksi` estimasi; konversi memakainya; validasi `StoreSettings.typeEnabled` | SAL-02 | ⬜ | — | — | — |
| 4.3 | Wajibkan katalog atau modal; izin `ubah_harga_jasa`; blokir harga nol kecuali owner + alasan | SAL-03 | ⏸ | — | — | — |
| 4.4 | Izin kredit, jatuh tempo wajib, limit pelanggan, approval owner | SAL-04 | ⏸ | — | — | — |
| 4.5 | Simpan `jasa_sync_id` di `estimate_items`; teruskan ke `JobDraft` | SAL-05 | ⬜ | — | — | — |
| 4.6 | Pisahkan `harga_terdaftar` dan `harga_input`; jasa bebas ditandai | SAL-06 | ⬜ | — | — | — |
| 4.7 | Snapshot `customer_nama`/`customer_hp`/`unit_nopol` pada nota; merge hanya referensi ke depan | SAL-07 | ⬜ | — | — | — |
| 4.8 | Simpan `request_payload_hash`; tolak `request_id` dengan hash berbeda | BIZ-01 | ⬜ | — | — | — |
| 4.9 | Pastikan semua validasi dijalankan di service, bukan hanya UI | — | ⬜ | — | — | — |

**Checklist DoD Tahap 4:** ⬜ estimasi EKSLUSIF/INKLUSIF terkonversi benar · ⬜ jenis transaksi sama · ⬜ jasa bebas tanpa modal ditolak · ⬜ kredit tanpa jatuh tempo ditolak · ⬜ `jasa_sync_id` ada · ⬜ merge tidak mengubah histori · ⬜ retry payload beda ditolak

---

### TAHAP 5 — Retur dan Pembatalan

**Prasyarat:** Tahap 4. **Temuan:** PUR-01, PUR-04, PUR-05, RET-01, RET-02, RET-03.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 5.1 | Refund inkremental per dokumen + `refund_accumulated_cents` + idempotensi | PUR-01 | ⬜ | — | — | — |
| 5.2 | Nilai retur dari `harga_pokok_satuan`/nilai bayar per unit | PUR-05 | ⬜ | — | — | — |
| 5.3 | Simpan metode refund; default metode pembayaran asal | PUR-04 | ⏸ | — | — | — |
| 5.4 | Simpan `dpp_cents`, `ppn_cents`, `total_ditagih_cents` header + item retur | RET-02 | ⬜ | — | — | — |
| 5.5 | `sale_return_reversals`/`purchase_return_reversals`; transisi status; otorisasi owner; audit | RET-01 | ⏸ | — | — | — |
| 5.6 | `status = 'AKTIF'` pada semua agregasi retur | RET-03 | ⬜ | — | — | — |
| 5.7 | Larang void nota jika masih ada retur aktif; minta reversal dulu | RET-01 | ⬜ | — | — | — |
| 5.8 | Retur/void memperbarui `stock_balances` (bersama Tahap 6) | FIN-01 | ⬜ | — | — | — |

**Checklist DoD Tahap 5:** ⬜ dua retur tidak menggandakan kas · ⬜ nilai retur pakai harga pokok teralokasi · ⬜ metode refund benar · ⬜ reversal mengembalikan stok/kas + audit · ⬜ omzet neto & PPN konsisten · ⬜ retur reversal tidak mengurangi nota

---

### TAHAP 6 — Persediaan dan Keuangan

**Prasyarat:** Tahap 2, 4, 5. **Temuan:** INV-01..04, INV-06, FIN-01..07, PUR-02/03/06/07.
**Subtrack:** 6A = 6.1–6.6 (ledger/opname/koreksi); 6B = 6.3, 6.11, 6.12 (HPP/laporan/PPN); 6C = 6.8, 6.13 (saldo awal/payroll).

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 6.1 | Ledger-first: semua mutasi via `StockLedger.apply`; update movements + balances; rebuild | — | ⬜ | — | — | — |
| 6.2 | Penjualan, retur, void, opname, koreksi menyesuaikan balance; fungsi rebuild | FIN-01 | ⬜ | — | — | — |
| 6.3 | HPP snapshot dari `avg_cost_cents`, bukan master | FIN-02 | ⬜ | — | — | — |
| 6.4 | Movement KOREKSI memakai `sync_id` unik per koreksi | INV-01 | ⬜ | — | — | — |
| 6.5 | Opname berbasis delta + `basis_qty`; tolak/rekonsiliasi bila saldo berubah | INV-02 | ⬜ | — | — | — |
| 6.6 | Opname dan void saldo awal menyesuaikan balance | INV-03/04 | ⬜ | — | — | — |
| 6.7 | `unit_cost_cents`/`value_cents` pada baris STOK | INV-06 | ⏸ | — | — | — |
| 6.8 | `opening_payables`/`opening_receivables` + pembayaran + dashboard/aging | PUR-02/03 | ⬜ | — | — | — |
| 6.9 | Filter `store_id` di `volumeQuery` | PUR-06 | ⬜ | — | — | — |
| 6.10 | Pisahkan utang pembelian vs utang awal | PUR-07 | ⬜ | — | — | — |
| 6.11 | Kurangkan DPP/PPN retur di ringkasan; satu sumber rekap PPN | FIN-03 | ⬜ | — | — | — |
| 6.12 | Sertakan piutang awal di dashboard | FIN-04 | ⬜ | — | — | — |
| 6.13 | Payroll menerima aktor/izin, `paid_by`, komponen terpisah | FIN-05 | ⬜ | — | — | — |
| 6.14 | Validasi sisa kewajiban remote, `cash_sync_id` lokal, insert gagal keras | FIN-06 | ⏸ | — | — | — |
| 6.15 | Perbaiki pembagian integer SQL | FIN-07 | ⬜ | — | — | — |

**Checklist DoD Tahap 6:** ⬜ balances = `stock_items.jumlah_milli` · ⬜ nilai persediaan rekonsiliasi dari ledger · ⬜ opname tidak menimpa penjualan · ⬜ koreksi kedua berhasil · ⬜ saldo awal dapat dibayar/ditagih · ⬜ laba per nota pakai HPP rata-rata · ⬜ ringkasan PPN = rekap · ⬜ payroll berizin · ⬜ PPN remote tidak overpay · ⬜ total laporan = total transaksi

---

### TAHAP 7 — Backup dan Restore

**Prasyarat:** Tahap 2 & 3. **Temuan:** DB-02, DB-04, DB-05, DB-06, BAK-01, BAK-02.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 7.1 | Metadata `schema_version`, `app_version`, `schema_contract_version` di manifest backup + payload snapshot | DB-04 | ⬜ | — | — | — |
| 7.2 | Daftar tabel + jumlah baris + checksum per tabel | DB-05 | ⬜ | — | — | — |
| 7.3 | Pertahankan `user_version` asli; migrasi setelah restore; tolak versi tak didukung | DB-02 | ⬜ | — | — | — |
| 7.4 | Validasi tabel non-lokal, row count, `integrity_check`, `foreign_key_check` | DB-06 | ⬜ | — | — | — |
| 7.5 | Hentikan `SyncScheduler`/`BackupScheduler`; tunggu sync; state machine restore | BAK-01 | ⬜ | — | — | — |
| 7.6 | File sementara + rename atomik; simpan file lama; rollback bila gagal | BAK-01 | ⬜ | — | — | — |
| 7.7 | Backup polos via backup API/`VACUUM INTO` atau hentikan penulis | BAK-02 | ⬜ | — | — | — |
| 7.8 | Status "restore dalam proses" memblokir aksi lain | BAK-01 | ⬜ | — | — | — |

**Checklist DoD Tahap 7:** ⬜ backup versi lama dimigrasikan/ditolak jelas · ⬜ backup terpotong/yatim ditolak · ⬜ restore tidak bersamaan sync/backup · ⬜ restore terputus rollback · ⬜ backup polos konsisten

---

### TAHAP 8 — Keamanan dan Error Handling

**Prasyarat:** Tahap 1 & 2. **Temuan:** SEC-01..09, FLW-01..03.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 8.1 | Sign-out minta PIN owner atau kunci DB; onboarding deteksi `owner_identity` | SEC-01 | ⏸ | — | — | — |
| 8.2 | Jangan sintesis owner; simpan peran bersama PIN; verifikasi owner | SEC-09 | ⬜ | — | — | — |
| 8.3 | Hapus fallback `Operator.owner`; state tidak terautentikasi | SEC-05 | ⬜ | — | — | — |
| 8.4 | `Operator actor` + `Permissions.require`; supplier/akun/payroll owner-only; `paid_by` | SEC-02/03/04 | ⬜ | — | — | — |
| 8.5 | PIN minimum 6 digit; paksa ganti PIN legacy | SEC-06 | ⬜ | — | — | — |
| 8.6 | Viewer `readOnly`; `Permissions.can` menolak viewer | SEC-07 | ⬜ | — | — | — |
| 8.7 | Ekspor owner-only + PIN; redaksi token lisensi | SEC-08 | ⬜ | — | — | — |
| 8.8 | Error boundary startup + layar pemulihan | FLW-01 | ⬜ | — | — | — |
| 8.9 | Pisahkan simpan nota dan tampil struk; pesan akurat | FLW-02 | ⬜ | — | — | — |
| 8.10 | Mode pemulihan database rusak | FLW-03 | ⬜ | — | — | — |
| 8.11 | Perbaiki allow-list sync (`supplier`) dan audit aktor | SEC-03/04 | ⬜ | — | — | — |

**Checklist DoD Tahap 8:** ⬜ tidak ada jalur keluar→owner baru · ⬜ sesi hilang bukan owner · ⬜ operator null tidak membuka menu owner · ⬜ service sensitif memeriksa aktor · ⬜ PIN lemah ditolak · ⬜ viewer tidak bisa menulis · ⬜ ekspor owner-only · ⬜ startup gagal menampilkan pemulihan · ⬜ struk gagal tidak dilabeli gagal simpan

---

### TAHAP 9 — Feature Toggle

**Prasyarat:** Tahap 4–6 dan 8. **Temuan:** FEAT-01, FEAT-02.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 9.1 | `FeatureCatalog`: key, default, dependencies, wajib/opsional | FEAT-01 | ⬜ | — | — | — |
| 9.2 | `store_features` satu-satunya sumber; cache fail-closed | FEAT-02 | ⬜ | — | — | — |
| 9.3 | `FeatureGate.require(key)` di setiap service tulis dan remote baru | FEAT-01 | ⬜ | — | — | — |
| 9.4 | UI "Manajemen Modul dan Fitur": status, dependensi, peringatan, riwayat | FEAT-01 | ⬜ | — | — | — |
| 9.5 | Owner-only + PIN + `feature_audits` | FEAT-01 | ⬜ | — | — | — |
| 9.6 | OFF tidak menghapus/mengubah data; histori tetap terbaca | FEAT-01 | ⬜ | — | — | — |
| 9.7 | Tolak menyalakan anak tanpa induk; konfirmasi mematikan induk | FEAT-01 | ⬜ | — | — | — |
| 9.8 | Snapshot/restore membawa status fitur | FEAT-01 | ⬜ | — | — | — |
| 9.9 | Remote: terima histori; tolak/queue dokumen baru saat OFF | FEAT-01 | ⬜ | — | — | — |

**Checklist DoD Tahap 9:** ⬜ semua service memanggil gate · ⬜ tidak ada fallback true sebelum load · ⬜ OFF memblokir UI + service + remote · ⬜ histori terlihat · ⬜ perubahan owner tercatat · ⬜ dependensi terjaga · ⬜ snapshot membawa status

---

### TAHAP 10 — UI/Flow dan Verifikasi Akhir

**Prasyarat:** Tahap 1–9. **Temuan:** SAL-08 + verifikasi seluruh 59.

| ID | Task | Temuan | Status | Bukti perubahan | Verifikasi | Tanggal |
|---|---|---|---|---|---|---|
| 10.1 | Tampilkan sen bila tidak bulat, atau bulatkan sekali di tingkat nota | SAL-08 | ⬜ | — | — | — |
| 10.2 | State machine UI: `starting`, `unauthenticated`, `ready`, `recovering`, `restoring`, `switching_store` | — | ⬜ | — | — | — |
| 10.3 | Sinkronkan state setelah restore/pindah toko (operator, fitur, pengaturan, daftar) | — | ⬜ | — | — | — |
| 10.4 | Blokir aksi saat restore/switch | — | ⬜ | — | — | — |
| 10.5 | Perbaiki pesan error dan receipt flow (verifikasi FLW-02) | FLW-02 | ⬜ | — | — | — |
| 10.6 | E2E pada DB bersih: onboarding, nota, retur, void, opname, pembelian, pembayaran, payroll, PPN, backup, restore, snapshot, multi-toko, fitur OFF | — | ⬜ | — | — | — |
| 10.7 | Verifikasi tiap temuan punya bukti perbaikan (kode + skenario) | — | ⬜ | — | — | — |
| 10.8 | Perbarui dokumentasi pengguna dan catatan rilis | — | ⬜ | — | — | — |

**Checklist DoD Tahap 10:** ⬜ 59 temuan punya status perbaikan · ⬜ alur utama lulus di DB bersih · ⬜ tidak ada regresi · ⬜ backup/restore & snapshot identik · ⬜ fitur OFF tidak menulis · ⬜ UI = database

---

## 7. RIWAYAT PERUBAHAN (APPEND-ONLY)

| Waktu | Task | Ringkasan | Bukti (file/commit) | Catatan |
|---|---|---|---|---|
| 2026-11-09 | 1.1 | Membuat file progres; mengunci versi Flutter 3.47.9 di seluruh job CI | `IMPLEMENTATION_PROGRESS.md`; `.github/workflows/ci.yml` | `pubspec.lock` sudah terlacak; build lokal tidak dijalankan karena Flutter CLI tidak tersedia |
