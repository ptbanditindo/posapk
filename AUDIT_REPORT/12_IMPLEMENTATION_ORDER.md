# 12 — URUTAN IMPLEMENTASI

**Sifat:** rencana eksekusi. Tidak ada implementasi, test, build, atau perubahan source dalam audit ini.
**Rujukan:** `01_BUSINESS_LOGIC_DEFECTS.md`, `11_REMEDIATION_ROADMAP.md`.
**Asumsi:** tidak ada data produksi; database dapat dibuat ulang dari nol. Aplikasi tetap memerlukan `schema_version` untuk rilis berikutnya.

---

## 1. Prinsip Urutan

1. **Fondasi sebelum perbaikan:** tanpa build/test harness dan observabilitas, perbaikan tidak dapat diverifikasi.
2. **Skema sebelum logika:** perbaikan logika yang masih memakai kolom ganda akan sia-sia.
3. **Uang dan stok sebelum fitur:** CRITICAL keuangan/persediaan tidak boleh menunggu UI.
4. **Retur sebelum laporan:** laporan tidak dapat benar sebelum nilai retur benar.
5. **Backup sebelum rilis:** restore adalah jalur kehilangan data terbesar.
6. **Keamanan sebelum feature toggle:** gate fitur tidak berarti jika aktor dapat menjadi owner.
7. **UI terakhir:** tampilan mengikuti domain yang sudah benar, bukan menutupi kesalahan.

---

## 2. Peta Tahap

| Tahap | Nama | Sifat | Dapat paralel dengan |
|---|---|---|---|
| 1 | Fondasi aman dan observabilitas | Wajib | — |
| 2 | Database bersih dan identitas tunggal | Wajib | — |
| 3 | Integritas data dan sinkronisasi | Wajib | 4, 8 |
| 4 | Logika inti penjualan dan estimasi | Wajib | 3, 8 |
| 5 | Retur dan pembatalan | Wajib | 6 (setelah 4) |
| 6 | Persediaan dan keuangan | Wajib | 5 (subtrack), 9 (setelah 4–6) |
| 7 | Backup dan restore | Wajib | 8 |
| 8 | Keamanan dan error handling | Wajib | 3, 4, 7 |
| 9 | Feature toggle | Wajib | 10 (setelah 4–8) |
| 10 | UI/flow dan verifikasi akhir | Wajib | — |

**Alur kritis:** 1 → 2 → 4 → 5 → 6 → 9 → 10. Tahap 3, 7, 8 dapat berjalan paralel dengan alur ini setelah prasyaratnya.

---

## 3. Detail Tahap

### TAHAP 1 — Fondasi Aman dan Observabilitas

**Tujuan:** menyediakan lingkungan yang dapat membangun, menguji, dan mendiagnosis aplikasi tanpa mengubah perilaku bisnis.

**Temuan langsung:** tidak ada. Tahap ini adalah *enabler* untuk semua temuan.

**Modul/file:** seluruh proyek; `pubspec.yaml`, konfigurasi build, `main.dart` (hanya instrumentasi), skrip pengujian.

**Prasyarat:** tidak ada.

**Pekerjaan:**
1. Pastikan build Android dapat direproduksi (Flutter version terkunci, dependency lock).
2. Siapkan unit test harness untuk service dan widget test untuk alur kritis (belum menguji fitur, hanya kerangka).
3. Siapkan test database in-memory/SQLite sementara; jangan memakai data produksi.
4. Tambahkan logging terstruktur (kategori: database, sync, backup, auth, business).
5. Tambahkan mekanisme ekspor diagnostik (versi aplikasi, versi skema, status sync, error terakhir) tanpa data sensitif.
6. Buat baseline backup database kosong dan verifikasi dapat dibuka.
7. Dokumentasikan matriks perangkat/platform yang didukung.

**Definition of Done:**
- Build bersih dari commit yang sama di mesin bersih.
- Test harness berjalan (kerangka, belum harus lulus semua).
- Log dan diagnostik tidak memuat PIN, token, atau data pelanggan.
- Baseline database kosong dapat dibackup, direstore, dan dibuka.
- Tidak ada perubahan perilaku bisnis.

**Risiko jika dilewati:** perbaikan tidak dapat diverifikasi; regresi tidak terdeteksi; bug runtime baru muncul saat rilis.

**Output:** build baseline, harness, logging, diagnostik, baseline backup.

**Sifat:** WAJIB. **Urutan:** sekuensial pertama.

---

### TAHAP 2 — Database Bersih dan Identitas Tunggal

**Tujuan:** membuat skema yang tidak memiliki duplikasi kuantitas/keanggotaan dan memastikan semua database dibuka melalui jalur enkripsi yang sama.

**Temuan:** INV-05, DB-03, DB-10, DB-11.

**Modul/file:** `lib/data/schema.dart`, `lib/data/app_database.dart`, `lib/data/store_service.dart`, `lib/data/account_service.dart`, `lib/data/backup_service.dart`, `lib/sync/snapshot_sync.dart`.

**Prasyarat:** Tahap 1.

**Pekerjaan:**
1. Terapkan skema bersih dari `11_REMEDIATION_ROADMAP.md` (bagian 4) sebagai versi baru.
2. Hapus `stock_items.jumlah`; `jumlah_milli NOT NULL`; backfill hanya untuk database pengembangan (bukan data produksi).
3. Hapus `employee_accounts.store_ids_json`; `employee_store_access` menjadi satu-satunya sumber keanggotaan.
4. Hapus `sync_peer_digests`.
5. Satukan jalur pembukaan database: `_open`, `createDatabaseAt`, `createEncryptedCopy`, viewer semuanya memakai SQLCipher jika platform mendukung.
6. Tambahkan `app_meta`/`licenses` (rename) dan metadata versi.
7. Tambahkan tabel baru yang menjadi fondasi: `stock_balances`, `audit_events`, `feature_audits`, `employee_payroll_profiles`, `salary_components`.
8. Pastikan `PRAGMA foreign_keys = ON` di semua koneksi.

**Definition of Done:**
- Database baru dapat dibuat di Android (SQLCipher) dan desktop/web (SQLite) tanpa error.
- Tidak ada kolom `jumlah`; semua kode membaca `jumlah_milli`.
- Hanya satu sumber keanggotaan toko.
- Tidak ada tabel `sync_peer_digests`.
- Toko baru dapat dibuka kembali melalui jalur enkripsi yang sama.
- Skema memiliki `schema_version` yang eksplisit dan dapat dibuka ulang.

**Risiko jika dilewati:** perbaikan stok/keuangan akan terus memakai data ganda; toko baru tetap tidak terenkripsi; keanggotaan toko tidak dapat dipercaya.

**Output:** skema v3 bersih, jalur buka database terpadu, tabel fondasi.

**Sifat:** WAJIB. **Urutan:** setelah Tahap 1; sekuensial.

---

### TAHAP 3 — Integritas Data dan Sinkronisasi

**Tujuan:** memastikan snapshot, sync, dan multi-toko tidak kehilangan atau mencampur data.

**Temuan:** DB-01, DB-07, DB-08, DB-09.

**Modul/file:** `lib/sync/snapshot_sync.dart`, `lib/sync/sync_service.dart`, `lib/data/note_sync.dart`, `lib/data/store_service.dart`, `lib/data/app_database.dart`, `lib/data/schema.dart`.

**Prasyarat:** Tahap 2.

**Pekerjaan:**
1. Hasilkan daftar tabel snapshot dari skema; sertakan `cash_ledger`, `opname_holds`, `audit_events` (atau dokumentasikan lokal dengan rekonsiliasi eksplisit).
2. Perbaiki `snapshotDeleteOrder` agar konsisten dengan daftar tabel.
3. Tambahkan metadata versi pada payload snapshot (lihat Tahap 7 untuk backup).
4. Perbaiki pembuatan stok dari nota: cari `sync_id`; kode bentrok → kode sementara unik + catat `sync_conflicts`; jangan gagalkan seluruh nota.
5. Tambahkan kunci global pada `switchStore`: tunggu `SyncService` selesai, hentikan scheduler sementara, rollback jika buka gagal.
6. Pindahkan insert `stock_movements` setelah keputusan `applyQuantity`; konflik hanya di `sync_conflicts`.
7. Tambahkan validasi `store_id` pada penerapan remote.

**Definition of Done:**
- Perangkat baru yang menerima snapshot memiliki `cash_ledger` dan opname yang sama dengan sumber.
- Nota dengan kode bentrok tetap masuk; konflik tercatat, bukan gagal total.
- Pindah toko tidak memutus transaksi sync.
- Tidak ada movement dengan `stok_sesudah` yang tidak diterapkan.
- Snapshot dapat diterapkan ulang (idempoten) tanpa duplikasi.

**Risiko jika dilewati:** bootstrap perangkat baru tetap kehilangan kas; sync macet; data toko tercampur.

**Output:** snapshot lengkap, sync tahan konflik, switch toko aman.

**Sifat:** WAJIB. **Urutan:** setelah Tahap 2; dapat paralel dengan Tahap 4 dan 8.

---

### TAHAP 4 — Logika Inti Penjualan dan Estimasi

**Tujuan:** membuat perhitungan nota, PPN, harga, kredit, dan konversi estimasi konsisten serta dapat diaudit.

**Temuan:** SAL-01, SAL-02, SAL-03, SAL-04, SAL-05, SAL-06, SAL-07, BIZ-01.

**Modul/file:** `lib/data/order_service.dart`, `lib/data/app_database.dart`, `lib/data/price_rules.dart`, `lib/data/models.dart`, `lib/ui/screens/pos_screen.dart`, `lib/data/schema.dart`.

**Prasyarat:** Tahap 2, Tahap 3 (untuk idempotensi/sync).

**Pekerjaan:**
1. **SAL-01:** simpan `dpp_cents`, `ppn_cents`, `total_ditagih_cents`, `pajak_mode`, `pajak_penanggung` pada `estimates` dan `estimate_items`; konversi menyalin snapshot; diskon hanya dari harga sebelum pajak.
2. **SAL-02:** simpan `jenis_transaksi` pada estimasi; konversi memakainya; validasi `StoreSettings.typeEnabled`.
3. **SAL-03:** wajibkan katalog atau modal/estimasi biaya; izin `ubah_harga_jasa`; blokir harga nol kecuali owner + alasan.
4. **SAL-04:** tambah izin kredit, jatuh tempo wajib, limit pelanggan, approval owner.
5. **SAL-05:** simpan `jasa_sync_id` pada `estimate_items`; teruskan ke `JobDraft`.
6. **SAL-06:** pisahkan `harga_terdaftar` dan `harga_input`; jasa bebas memakai tarif referensi atau ditandai.
7. **SAL-07:** tambah snapshot `customer_nama`/`customer_hp`/`unit_nopol` pada nota; merge hanya untuk referensi ke depan.
8. **BIZ-01:** simpan `request_payload_hash`; tolak `request_id` dengan hash berbeda.
9. Pastikan semua validasi dijalankan di service, bukan hanya UI.

**Definition of Done:**
- Estimasi EKSLUSIF dan INKLUSIF dapat dikonversi tanpa error; PPN nota = snapshot estimasi.
- Jenis transaksi hasil konversi sama dengan estimasi.
- Jasa bebas tanpa modal ditolak; harga di bawah batas memerlukan izin.
- Kredit tanpa jatuh tempo ditolak; limit bekerja.
- Nota hasil konversi memiliki `jasa_sync_id`.
- Merge tidak mengubah cetak/laporan nota lama.
- Retry dengan payload berbeda ditolak.

**Risiko jika dilewati:** PPN dan harga tetap salah; kredit tak terkendali; histori pelanggan berubah.

**Output:** service penjualan/estimasi yang konsisten, test skenario konversi dan kredit.

**Sifat:** WAJIB. **Urutan:** setelah 2; paralel dengan 3 dan 8.

---

### TAHAP 5 — Retur dan Pembatalan

**Tujuan:** membuat retur dan reversal menghasilkan nilai, stok, kas, dan pajak yang benar.

**Temuan:** PUR-01, PUR-04, PUR-05, RET-01, RET-02, RET-03.

**Modul/file:** `lib/data/purchase_service.dart`, `lib/data/sale_return_service.dart`, `lib/data/app_database.dart`, `lib/data/opening_balance_service.dart` (terkait), `lib/data/schema.dart`, UI retur.

**Prasyarat:** Tahap 4 (nota dan pajak benar).

**Pekerjaan:**
1. **PUR-01:** hitung refund inkremental per dokumen; simpan `refund_accumulated_cents` di header pembelian; tulis selisih; idempotensi per retur.
2. **PUR-05:** nilai retur dari `harga_pokok_satuan`/nilai bayar per unit.
3. **PUR-04:** simpan metode refund; default metode pembayaran asal.
4. **RET-02:** simpan `dpp_cents`, `ppn_cents`, `total_ditagih_cents` pada header dan item retur; gunakan basis konsisten.
5. **RET-01:** tambah `sale_return_reversals` dan `purchase_return_reversals`; transisi status terkontrol; otorisasi owner; audit.
6. **RET-03:** tambahkan `status = 'AKTIF'` pada semua agregasi retur.
7. Larang void nota jika masih ada retur aktif; minta reversal terlebih dahulu.
8. Pastikan retur/void memperbarui `stock_balances` (bersama Tahap 6).

**Definition of Done:**
- Dua retur pembelian menghasilkan total kas sesuai nilai retur seharusnya, bukan kumulatif.
- Nilai retur pembelian memakai harga pokok teralokasi.
- Metode refund sesuai pembayaran asal/pilihan.
- Retur salah dapat direversal; stok dan kas kembali; audit lengkap.
- Omzet neto dan PPN retur konsisten dengan rekap.
- Retur VOID/reversal tidak mengurangi nota.

**Risiko jika dilewati:** kas fiktif berlanjut; kesalahan retur permanen; laporan pajak salah.

**Output:** dokumen retur/reversal, perhitungan refund inkremental, test kas.

**Sifat:** WAJIB. **Urutan:** setelah Tahap 4; sekuensial dengan Tahap 6.

---

### TAHAP 6 — Persediaan dan Keuangan

**Tujuan:** menjadikan stok dan HPP konsisten, menyelesaikan saldo awal, dan memperbaiki laporan keuangan/pajak/payroll.

**Temuan:** INV-01, INV-02, INV-03, INV-04, INV-06, FIN-01, FIN-02, FIN-03, FIN-04, FIN-05, FIN-06, FIN-07, PUR-02, PUR-03, PUR-06, PUR-07.

**Modul/file:** `lib/data/app_database.dart`, `lib/data/purchase_service.dart`, `lib/data/opening_balance_service.dart`, `lib/data/employee_service.dart`, `lib/data/pajak_payment_service.dart`, `lib/data/pajak_report_service.dart`, `lib/data/schema.dart`.

**Prasyarat:** Tahap 2 (skema), Tahap 4/5 (nota/retur benar).

**Pekerjaan:**
1. **Ledger-first stok:** semua mutasi melalui `StockLedger.apply`; perbarui `stock_movements` + `stock_balances`; `stock_balances` dapat direbuild.
2. **FIN-01:** penjualan, retur, void, opname, koreksi mengurangi/menyesuaikan balance; sediakan fungsi rebuild dari ledger.
3. **FIN-02:** HPP snapshot dari `avg_cost_cents`, bukan master.
4. **INV-01:** movement KOREKSI memakai `sync_id` unik per koreksi.
5. **INV-02:** opname berbasis delta + `basis_qty`; tolak/rekonsiliasi jika saldo berubah.
6. **INV-03/INV-04:** opname dan void saldo awal menyesuaikan balance.
7. **INV-06:** tambah `unit_cost_cents`/`value_cents` pada baris STOK (jika disetujui).
8. **PUR-02/PUR-03:** tambah `opening_payables`/`opening_receivables` + pembayaran; masukkan ke dashboard/aging.
9. **PUR-06:** filter `store_id` di `volumeQuery`.
10. **PUR-07:** pisahkan utang pembelian vs utang awal.
11. **FIN-03:** kurangkan DPP/PPN retur di ringkasan; satu sumber rekap PPN.
12. **FIN-04:** sertakan piutang awal di dashboard.
13. **FIN-05:** payroll menerima aktor/izin, `paid_by`, komponen terpisah.
14. **FIN-06:** validasi sisa kewajiban remote, `cash_sync_id` lokal, insert gagal keras.
15. **FIN-07:** perbaiki pembagian integer SQL.

**Definition of Done:**
- `stock_balances.qty_milli` = `stock_items.jumlah_milli` setelah semua operasi.
- Nilai persediaan dapat direkonsiliasi dari ledger.
- Opname tidak menimpa penjualan setelah hitung fisik.
- Koreksi stok kedua dan seterusnya berhasil.
- Saldo awal utang/piutang dapat dibayar/ditagih dan tampil di dashboard.
- Laba per nota memakai HPP rata-rata.
- Ringkasan PPN = rekap PPN; tidak ada PPN atas retur penuh.
- Gaji hanya oleh aktor berwenang dan audit jelas.
- PPN remote tidak overpay dan kas tidak hilang.
- Total laporan = total transaksi (tanpa selisih pembulatan per baris).

**Risiko jika dilewati:** angka keuangan tidak dapat dipercaya; stok dan HPP terus menyimpang.

**Output:** ledger-first inventory, laporan keuangan konsisten, saldo awal dapat diselesaikan, payroll aman.

**Sifat:** WAJIB. **Urutan:** setelah 4/5. Subtrack yang dapat paralel:
- 6A: stock ledger + opname + koreksi;
- 6B: HPP + laporan + PPN;
- 6C: saldo awal + payroll.
Namun 6B/6C bergantung pada 6A untuk nilai stok; koordinasikan interface `StockLedger`.

---

### TAHAP 7 — Backup dan Restore

**Tujuan:** memastikan backup konsisten dan restore tidak kehilangan data atau merusak skema.

**Temuan:** DB-02, DB-04, DB-05, DB-06, BAK-01, BAK-02.

**Modul/file:** `lib/data/backup_service.dart`, `lib/data/app_database.dart`, `lib/sync/snapshot_sync.dart`, `lib/ui/screens/settings_screen.dart`.

**Prasyarat:** Tahap 2 (skema/versi), Tahap 3 (snapshot).

**Pekerjaan:**
1. Tambahkan `schema_version`, `app_version`, `schema_contract_version` ke manifest backup dan payload snapshot.
2. Simpan daftar tabel + jumlah baris + checksum per tabel.
3. Pertahankan `user_version` asli; jalankan migrasi setelah restore; tolak versi tidak didukung.
4. Validasi semua tabel non-lokal, jumlah baris, `integrity_check`, `foreign_key_check`.
5. Hentikan `SyncScheduler`/`BackupScheduler`; tunggu sync; state machine restore.
6. Gunakan file sementara + rename atomik; simpan file lama sampai reopen sukses; rollback jika gagal.
7. Backup polos memakai backup API/`VACUUM INTO` atau hentikan penulis.
8. Tampilkan status “restore dalam proses” yang memblokir aksi lain.

**Definition of Done:**
- Backup dari versi lama dapat direstore dan dimigrasikan, atau ditolak dengan pesan jelas.
- Backup terpotong/berisi baris yatim ditolak.
- Restore tidak berjalan bersamaan dengan sync/backup.
- Restore terputus dapat rollback ke database lama.
- Backup polos konsisten (transaksi terakhir ada).

**Risiko jika dilewati:** restore dapat menghilangkan data inti atau membuat aplikasi tidak dapat dibuka.

**Output:** format backup berversi, validasi lengkap, restore atomik.

**Sifat:** WAJIB. **Urutan:** setelah 2/3; paralel dengan 8.

---

### TAHAP 8 — Keamanan dan Error Handling

**Tujuan:** menutup jalur eskalasi hak dan memastikan kegagalan tidak mengunci pengguna atau menyesatkan.

**Temuan:** SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-06, SEC-07, SEC-08, SEC-09, FLW-01, FLW-02, FLW-03.

**Modul/file:** `lib/ui/entry_gate.dart`, `lib/ui/onboarding.dart`, `lib/ui/home_shell.dart`, `lib/auth/*`, `lib/data/account_service.dart`, `lib/data/supplier_service.dart`, `lib/data/employee_service.dart`, `lib/data/pin_service.dart`, `lib/data/app_database.dart`, `lib/main.dart`, `lib/sync/sync_conflict_rules.dart`.

**Prasyarat:** Tahap 1 (logging/build), Tahap 2 (identitas).

**Pekerjaan:**
1. **SEC-01:** sign-out minta PIN owner atau kunci database; onboarding deteksi `owner_identity`.
2. **SEC-09:** jangan sintesis owner dari PIN; simpan peran bersama PIN; verifikasi owner.
3. **SEC-05:** hapus fallback `Operator.owner`; state tidak terautentikasi.
4. **SEC-02/03/04:** wajibkan `Operator actor` + `Permissions.require`; supplier, akun, payroll owner-only; `paid_by`.
5. **SEC-06:** PIN minimum 6 digit; paksa ganti legacy.
6. **SEC-07:** viewer `readOnly`; `Permissions.can` tolak viewer.
7. **SEC-08:** ekspor owner-only + PIN; redaksi token.
8. **FLW-01:** error boundary startup; layar pemulihan.
9. **FLW-02:** pisahkan simpan dan struk; pesan akurat.
10. **FLW-03:** mode pemulihan database.
11. Perbaiki allow-list sync (`supplier`) dan audit aktor.

**Definition of Done:**
- Tidak ada jalur “keluar → onboarding → owner baru”.
- Sesi hilang tidak menjadi owner.
- Operator null tidak membuka menu owner.
- Semua service sensitif memeriksa aktor/izin.
- PIN lemah tidak dapat dipakai.
- Viewer tidak dapat menulis.
- Ekspor hanya owner.
- Startup gagal menampilkan layar pemulihan.
- Struk gagal tidak dilaporkan sebagai gagal simpan.

**Risiko jika dilewati:** pembukuan dapat diambil alih; pengguna terkunci dari data.

**Output:** identitas tunggal, otorisasi service, error boundary, recovery mode.

**Sifat:** WAJIB. **Urutan:** setelah 1/2; paralel dengan 3/4/7.

---

### TAHAP 9 — Feature Toggle

**Tujuan:** menjadikan fitur ON/OFF sebagai gerbang tunggal yang konsisten di semua jalur.

**Temuan:** FEAT-01, FEAT-02.

**Modul/file:** `lib/data/feature_flags.dart`, `lib/data/schema.dart`, `lib/data/purchase_service.dart`, `lib/data/order_service.dart`, `lib/data/followup_service.dart` (bila ada), `lib/data/employee_service.dart`, `lib/sync/sync_service.dart`, `lib/ui/screens/store_features_screen.dart`, `lib/ui/home_shell.dart`.

**Prasyarat:** Tahap 4–6 (service fitur), Tahap 8 (aktor/izin).

**Pekerjaan:**
1. Buat `FeatureCatalog` dengan key, default, dependencies, wajib/opsional.
2. `store_features` satu-satunya sumber; cache fail-closed.
3. `FeatureGate.require(key)` di setiap service tulis dan remote baru.
4. UI “Manajemen Modul dan Fitur”: status, dependensi, peringatan, riwayat.
5. Owner-only + PIN + `feature_audits`.
6. OFF tidak menghapus/mengubah data; histori tetap terbaca.
7. Dependensi: tolak menyalakan anak tanpa induk; konfirmasi mematikan induk.
8. Snapshot/restore membawa status fitur.
9. Remote: terima histori; tolak/queue dokumen baru saat OFF.

**Definition of Done:**
- Semua service fitur memanggil gate.
- Tidak ada fallback true sebelum load.
- OFF memblokir UI, service lokal, dan dokumen remote baru.
- Histori tetap terlihat.
- Perubahan hanya owner dan tercatat.
- Dependensi tidak dapat dilanggar.
- Snapshot/restore membawa status.

**Risiko jika dilewati:** fitur yang “dimatikan” tetap menulis data; laporan tidak dapat memisahkan periode.

**Output:** katalog fitur, gate service, layar pengaturan, audit.

**Sifat:** WAJIB (kebutuhan produk). **Urutan:** setelah 4–8; sebelum 10.

---

### TAHAP 10 — UI/Flow dan Verifikasi Akhir

**Tujuan:** menyelaraskan tampilan dengan domain yang sudah benar dan memverifikasi seluruh 59 temuan pada database bersih.

**Temuan:** SAL-08; verifikasi lintas semua temuan.

**Modul/file:** `lib/core/money.dart`, `lib/ui/screens/pos_screen.dart`, `lib/ui/home_shell.dart`, `lib/ui/screens/settings_screen.dart`, seluruh UI.

**Prasyarat:** Tahap 1–9.

**Pekerjaan:**
1. **SAL-08:** tampilkan sen bila tidak bulat, atau bulatkan sekali di tingkat nota.
2. Terapkan state machine UI: `starting`, `unauthenticated`, `ready`, `recovering`, `restoring`, `switching_store`.
3. Sinkronkan state setelah restore/pindah toko (operator, fitur, pengaturan, daftar).
4. Blokir aksi saat restore/switch.
5. Perbaiki pesan error dan receipt flow (verifikasi FLW-02).
6. Uji alur ujung-ke-ujung pada database bersih: onboarding, nota, retur, void, opname, pembelian, pembayaran, payroll, PPN, backup, restore, snapshot, multi-toko, fitur OFF.
7. Verifikasi setiap temuan memiliki bukti perbaikan (kode + skenario).
8. Perbarui dokumentasi pengguna dan catatan rilis.

**Definition of Done:**
- Semua 59 temuan memiliki status perbaikan yang dapat ditelusuri.
- Alur utama berjalan pada database bersih tanpa error.
- Tidak ada regresi pada fitur yang tidak diubah.
- Backup/restore dan snapshot menghasilkan data identik.
- Feature toggle OFF tidak menulis data baru.
- UI tidak menampilkan angka yang berbeda dari database.

**Risiko jika dilewati:** perbaikan domain tidak terlihat pengguna; regresi UI; klaim perbaikan tidak terbukti.

**Output:** UI selaras, hasil verifikasi, dokumentasi rilis.

**Sifat:** WAJIB untuk verifikasi; SAL-08 adalah *enhancement*. **Urutan:** terakhir, sekuensial.

---

## 4. Peta Semua Temuan ke Tahap

| ID | Tahap | Klasifikasi |
|---|---:|---|
| SAL-01 | 4 | WAJIB |
| SAL-02 | 4 | WAJIB |
| SAL-03 | 4 | WAJIB |
| SAL-04 | 4 | WAJIB |
| SAL-05 | 4 | WAJIB |
| SAL-06 | 4 | PENTING |
| SAL-07 | 4 | WAJIB |
| SAL-08 | 10 | ENHANCEMENT |
| PUR-01 | 5 | WAJIB |
| PUR-02 | 6 | WAJIB |
| PUR-03 | 6 | WAJIB |
| PUR-04 | 5 | PENTING |
| PUR-05 | 5 | WAJIB |
| PUR-06 | 6 | WAJIB |
| PUR-07 | 6 | PENTING |
| RET-01 | 5 | WAJIB |
| RET-02 | 5 | PENTING |
| RET-03 | 5 | ENHANCEMENT |
| INV-01 | 6 | WAJIB |
| INV-02 | 6 | WAJIB |
| INV-03 | 6 | PENTING |
| INV-04 | 6 | PENTING |
| INV-05 | 2 | PENTING |
| INV-06 | 6 | PENTING (perlu validasi bisnis) |
| FIN-01 | 6 | WAJIB |
| FIN-02 | 6 | WAJIB |
| FIN-03 | 6 | WAJIB |
| FIN-04 | 6 | WAJIB |
| FIN-05 | 6 | WAJIB |
| FIN-06 | 6 | WAJIB |
| FIN-07 | 6 | ENHANCEMENT |
| BIZ-01 | 4 | PENTING |
| DB-01 | 3 | WAJIB |
| DB-02 | 7 | WAJIB |
| DB-03 | 2 | WAJIB |
| DB-04 | 7 | WAJIB |
| DB-05 | 7 | WAJIB |
| DB-06 | 7 | PENTING |
| DB-07 | 3 | WAJIB |
| DB-08 | 3 | WAJIB |
| DB-09 | 3 | PENTING |
| DB-10 | 2 | PENTING |
| DB-11 | 2 | ENHANCEMENT |
| BAK-01 | 7 | WAJIB |
| BAK-02 | 7 | PENTING |
| FLW-01 | 8 | WAJIB |
| FLW-02 | 8 | ENHANCEMENT |
| FLW-03 | 8 | PENTING |
| SEC-01 | 8 | WAJIB |
| SEC-02 | 8 | WAJIB |
| SEC-03 | 8 | WAJIB |
| SEC-04 | 8 | WAJIB |
| SEC-05 | 8 | WAJIB |
| SEC-06 | 8 | PENTING |
| SEC-07 | 8 | PENTING |
| SEC-08 | 8 | PENTING |
| SEC-09 | 8 | WAJIB |
| FEAT-01 | 9 | WAJIB |
| FEAT-02 | 9 | PENTING |

**Verifikasi jumlah:** 59 baris. Setiap temuan memiliki tepat satu tahap.

---

## 5. Pekerjaan Paralel dan Ketergantungan

### 5.1 Jalur kritis (sekuensial)

```
1 → 2 → 4 → 5 → 6 → 9 → 10
```

### 5.2 Pekerjaan yang dapat berjalan paralel

| Setelah | Dapat dimulai | Catatan |
|---|---|---|
| 2 | 3 (sync) | Tidak bergantung pada logika penjualan |
| 2 | 8 (keamanan/error) | Identitas dan error boundary |
| 4 | 5 (retur) | Membutuhkan nota/pajak yang benar |
| 4 | 6A (stock ledger) | Bisa dimulai dengan interface |
| 5/6A | 6B (HPP/laporan) | Butuh ledger dan retur |
| 2/6C | 6C (saldo awal/payroll) | Butuh skema dan aktor |
| 3 | 7 (backup) | Snapshot dan versi |
| 4–8 | 9 (feature toggle) | Butuh service dan otorisasi |

### 5.3 Larangan paralel

- Jangan mengerjakan 4 dan 5 bersamaan tanpa interface nilai retur yang disepakati.
- Jangan mengerjakan 6B sebelum 6A stabil; laporan akan memakai angka yang berubah.
- Jangan mengerjakan 9 sebelum 8; gate fitur tidak aman tanpa aktor.
- Jangan mengerjakan 10 sebelum 4–9; UI akan menutupi kesalahan domain.

---

## 6. Definition of Done Global

Rilis dianggap siap hanya jika:

1. Semua temuan WAJIB pada tahap 1–9 selesai dan diverifikasi.
2. Database bersih dapat dibuat, dibackup, direstore, dan disinkronkan tanpa kehilangan data.
3. `stock_balances` dapat direkonsiliasi dengan `stock_movements` dan `stock_items`.
4. `cash_ledger` konsisten dengan pembayaran di semua modul.
5. Laporan penjualan, retur, PPN, dan dashboard memakai basis yang sama.
6. Tidak ada jalur eskalasi owner dari sign-out/sesi hilang/operator null.
7. Feature toggle OFF tidak menulis data baru dan tidak menghapus histori.
8. Semua operasi global (restore, switch store) memblokir operasi lain.
9. 59 temuan memiliki catatan status: selesai, ditunda dengan alasan, atau memerlukan keputusan bisnis.
10. Tidak ada klaim “selesai” tanpa bukti kode dan skenario.

---

## 7. Temuan yang Memerlukan Keputusan Bisnis Sebelum Implementasi

| Temuan | Keputusan |
|---|---|
| INV-06 | Apakah modal saldo awal boleh berbeda dari master? |
| SAL-03 | Apakah jasa bebas diizinkan? Siapa yang boleh menetapkan harga? |
| SAL-04 | Batas kredit, izin, dan jatuh tempo |
| RET-01 | Siapa yang boleh reversal dan apakah perlu approval kedua? |
| PUR-04 | Metode refund: ikut asal atau pilihan pengguna? |
| PUR-05 | Nilai retur: bruto atau harga pokok teralokasi? |
| FIN-03/FIN-06 | Carry-forward PPN dan kompensasi kelebihan bayar |
| FEAT-01 | Apakah OFF harus memblokir remote atau hanya UI? (Rekomendasi: blokir semua jalur tulis) |
| SEC-01 | Apakah sign-out menghapus database atau mengunci perangkat? |

Tanpa keputusan ini, implementasi dapat berjalan secara teknis tetapi tidak sesuai aturan bisnis.

---

## 8. Ringkasan untuk Agen Coding

1. Mulai dari Tahap 1; jangan menyentuh logika bisnis sebelum harness siap.
2. Buat skema bersih (Tahap 2); hapus duplikasi qty/keanggotaan dan satukan enkripsi.
3. Selesaikan sync/snapshot (Tahap 3) sebelum mengandalkan data lintas perangkat.
4. Benahi penjualan/estimasi (Tahap 4), lalu retur (Tahap 5).
5. Satukan stok/keuangan (Tahap 6); ini tahap terbesar, pecah menjadi 6A/6B/6C.
6. Kunci backup/restore (Tahap 7) sebelum rilis.
7. Tutup keamanan/error (Tahap 8).
8. Terapkan feature toggle (Tahap 9).
9. Terakhir UI dan verifikasi (Tahap 10).
10. Setiap tahap harus memiliki bukti: kode, skenario, dan hasil verifikasi pada database bersih. Jangan mengklaim selesai tanpa bukti.
