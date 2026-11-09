# 00 — RINGKASAN EKSEKUTIF

**Aplikasi:** PusatkuPOS (Flutter + SQLite/SQLCipher, offline-first)
**Cakupan:** Aplikasi APK Android di `pusatkupos/`; relay dan proyek web di luar cakupan temuan
**Metode:** Analisis statis source code, skema, trigger, dan alur UI → state → service → database
**Tanggal audit:** 9 November 2026
**Sifat audit:** Baca-saja. Tidak ada test, build, menjalankan aplikasi/server, simulasi runtime, instalasi dependensi, perubahan source, penghapusan file, atau perubahan konfigurasi.

---

## 1. Kesimpulan Utama

Aplikasi memiliki fondasi yang jauh di atas rata-rata untuk POS offline-first: uang disimpan dalam sen, kuantitas dalam milli-unit, nota append-only, trigger imutabilitas, idempotensi `request_id`, HLC, dan pemisahan database viewer. Namun ada **tiga kelas cacat struktural** yang membuat hasil pembukuan tidak dapat dipercaya tanpa perbaikan:

1. **HPP dan nilai persediaan tidak dipelihara oleh seluruh pergerakan stok.** `stock_cost_state` hanya diperbarui oleh pembelian dan saldo awal; penjualan, retur penjualan, void, dan koreksi stok tidak menguranginya. Rata-rata bergerak menjadi bias dan nilai persediaan membengkak.
2. **Pembukuan retur pembelian menggandakan kas.** Setiap retur membukukan ulang refund *kumulatif* sebagai arus kas baru, sehingga dua retur menghasilkan kas keluar yang jauh melebihi uang yang benar-benar diterima supplier.
3. **Sinkronisasi dan restore dapat menghilangkan atau menua-kan data secara diam-diam.** Snapshot tidak memuat `cash_ledger` dan `opname_holds`; restore memaksa `user_version` ke versi terbaru sehingga migrasi dilewati; pembuatan toko baru membuka database polos di platform SQLCipher.

Ditambah satu cacat otorisasi kritis: **keluar dari aplikasi menghapus PIN tetapi mempertahankan database dan identitas owner, lalu onboarding mengizinkan PIN baru dibuat untuk owner yang sama.** Siapa pun yang memegang perangkat dapat mengambil alih pembukuan.

---

## 2. Jumlah Temuan

| Tingkat | Jumlah |
|---|---:|
| CRITICAL | 7 |
| HIGH | 29 |
| MEDIUM | 18 |
| LOW | 5 |
| **Total** | **59** |

Status validitas:

| Status | Jumlah |
|---|---:|
| CONFIRMED | 58 |
| SUSPECTED | 0 |
| NEEDS VALIDATION | 1 |

Satu temuan berstatus NEEDS VALIDATION adalah INV-05 (nilai stok awal per baris), karena aturan bisnisnya tidak dinyatakan di source dan harus diputuskan pemilik.

---

## 3. Tujuh Temuan CRITICAL

| ID | Temuan | Modul | Risiko utama |
|---|---|---|---|
| SAL-01 | Konversi estimasi memakai total termasuk PPN sebagai diskon, lalu PPN dihitung ulang | Penjualan / Pajak | Estimasi PPN EKSLUSIF tidak dapat dikonversi; estimasi INKLUSIF menghasilkan DPP/PPN salah |
| PUR-01 | Retur pembelian membukukan refund kumulatif sebagai kas baru setiap kali retur | Pembelian | Kas keluar fiktif berulang; laporan kas dan utang tidak dapat direkonsiliasi |
| FIN-01 | `stock_cost_state` tidak diperbarui oleh penjualan, retur penjualan, void, dan koreksi stok | Keuangan / Persediaan | HPP rata-rata dan nilai persediaan salah permanen |
| DB-01 | Snapshot sinkronisasi tidak memuat `cash_ledger` dan `opname_holds` | Database / Sinkronisasi | Buku kas tiap perangkat berbeda; riwayat kas tidak berpindah saat bootstrap |
| DB-02 | `createEncryptedCopy` memaksa `PRAGMA user_version = schemaVersion` | Database / Restore | Restore backup lama melewati migrasi; kolom/tabel baru hilang, aplikasi error saat runtime |
| DB-03 | `createDatabaseAt` membuka database polos di platform SQLCipher | Database / Multi-toko | Toko baru tidak terenkripsi dan gagal dibuka oleh jalur SQLCipher |
| SEC-01 | Sign-out menghapus PIN, mempertahankan database, lalu onboarding membuat PIN owner baru | Keamanan | Pengambilalihan penuh oleh pemegang perangkat |

---

## 4. Sepuluh Jawaban Wajib (Section 10)

### 4.1 Berapa total defect?
**59 temuan** yang dapat dilacak ke source: 7 CRITICAL, 29 HIGH, 18 MEDIUM, 5 LOW.

### 4.2 Berapa jumlah per tingkat keparahan?
CRITICAL 7; HIGH 29; MEDIUM 18; LOW 5. Rincian per modul ada di `01_BUSINESS_LOGIC_DEFECTS.md`.

### 4.3 Modul terburuk?
**Keuangan/persediaan (FIN-01 + FIN-02 + INV-03 + INV-04)**. Satu akar masalah—`stock_cost_state` tidak dipelihara—merembet ke HPP per nota, laba kotor, nilai persediaan, dan margin per barang. Modul terburuk kedua adalah **sinkronisasi database (DB-01/02/03)**, karena kerusakannya senyap dan baru terlihat saat restore atau bootstrap perangkat.

### 4.4 Risiko transaksi terbesar?
**PUR-01 (retur pembelian)**: setiap retur menulis refund kumulatif sebagai baris kas baru dengan `sumber_sync_id` berbeda, sehingga unique index tidak menahannya. Dalam dua retur, kas keluar bisa menjadi 80% dari nilai pembelian padahal uang yang diterima hanya 50%.

### 4.5 Risiko keuangan terbesar?
**FIN-01**: nilai persediaan dan HPP rata-rata memakai kuantitas yang tidak pernah dikurangi penjualan. Dalam operasi normal, `qty_milli` di `stock_cost_state` hanya bertambah; nilai persediaan dapat dilaporkan jauh di atas fisik, dan laba kotor per nota memakai modal master yang sudah usang.

### 4.6 Risiko integritas database terbesar?
**DB-02** (forced `user_version`) dan **DB-01** (snapshot tanpa `cash_ledger`). DB-02 membuat database lama tampak “versi terbaru” sehingga migrasi dilewati; DB-01 membuat buku kas tidak pernah ikut bootstrap dan berbeda antar perangkat. **DB-03** melengkapinya: database toko baru dibuat tanpa enkripsi.

### 4.7 Kesalahan logika yang berpotensi menghilangkan data?
1. DB-02 — restore backup lama tanpa migrasi; data baru ditulis ke skema yang tidak lengkap.
2. DB-03 — database toko baru polos lalu gagal dibuka jalur SQLCipher; toko tidak dapat dipakai.
3. DB-01 — `cash_ledger` dan `opname_holds` tidak ikut snapshot; bootstrap perangkat baru menghilangkan riwayat kas/opname dari perangkat lain.
4. INV-05 — pembelian pada baris lama dengan `jumlah_milli` NULL membaca 0 lalu menimpa saldo lama.
5. DB-08 — berpindah toko saat sinkronisasi berjalan menutup database di tengah transaksi.

### 4.8 Urutan perbaikan yang benar?
Ikuti `12_IMPLEMENTATION_ORDER.md`: (1) fondasi build/test yang aman, (2) database bersih dan migrasi, (3) integritas data & backup, (4) logika inti penjualan, (5) retur/pembatalan, (6) persediaan & keuangan, (7) backup/restore, (8) keamanan & error handling, (9) feature toggle, (10) UI/flow & verifikasi akhir. CRITICAL harus selesai di Tahap 1–4; jangan menunda DB-01/02/03 sampai setelah fitur baru.

### 4.9 Bagian mana yang memerlukan validasi aturan bisnis?
1. Nilai stok awal: apakah modal per baris boleh berbeda dari master (INV-05)?
2. Batas kredit: apakah kredit butuh izin, jatuh tempo wajib, dan limit per pelanggan (SAL-04)?
3. Jasa bebas: bolehkah harga di bawah modal/harga nol tanpa persetujuan owner (SAL-03)?
4. Konversi estimasi: apakah estimasi menyimpan DPP atau nilai ditagih termasuk PPN (SAL-01)?
5. Retur: bolehkah retur dibatalkan/direversal, atau hanya dokumen lawan (RET-01)?
6. Refund pembelian: ikut metode pembayaran asal atau selalu CASH (PUR-04)?
7. Saldo awal utang/piutang: apakah harus dapat diselesaikan, atau hanya laporan (PUR-02/PUR-03)?
8. PPN: carry-forward kelebihan bayar dan pembatasan pembayaran remote (FIN-06)?
9. Feature toggle: apakah OFF harus memblokir API/remote atau hanya menyembunyikan UI (FEAT-01)?
10. Kepemilikan perangkat: apakah sign-out harus menghapus database atau mempertahankannya (SEC-01)?

### 4.10 Apakah audit ini lengkap?
Audit mencakup seluruh file Dart bisnis utama, skema, trigger, layanan sinkronisasi, backup, keamanan sesi, dan alur UI kasir/pembelian/retur/stok/laporan. **Tidak** mencakup relay server, proyek web, konfigurasi Gradle/AndroidManifest, sertifikat, library pihak ketiga, dan perilaku runtime nyata. Temuan yang membutuhkan pembuktian runtime ditandai NEEDS VALIDATION; tidak ada klaim kelengkapan untuk bagian yang tidak diperiksa.

---

## 5. Keterbatasan Metode dan Keterbukaan Skill

Empat repositori skill audit yang disebut dalam mandat diperiksa sebagai **referensi metodologi**, bukan sebagai skill lokal yang dipasang/dijalankan:

| Repositori | Akses | Yang dipakai |
|---|---|---|
| `pietz/skills` (code-audit) | Halaman repo/README dapat dibaca; sebagian berkas instruksi tidak dapat diambil utuh | Prinsip pemetaan alur, bukti baris, dan pemisahan temuan vs asumsi |
| `escoffier-labs/skillet` | Halaman repo dapat dibaca; isi skill tidak lengkap | Prinsip audit berbasis skenario dan dampak |
| `trailofbits/skills` (static-analysis, variant-analysis, sharp-edges) | Halaman repo/README dapat dibaca; sebagian SKILL tidak dapat diakses | Static analysis, variant analysis, dan “sharp edges” (API mudah disalahgunakan) |
| `cloudflare/security-audit-skill` | Halaman repo/README dapat dibaca; isi skill tidak lengkap | Checklist otorisasi, data sensitif, dan batas kepercayaan |

**Tidak ada skill yang dipasang, dijalankan, atau diklaim sebagai alat otomatis.** Semua temuan berasal dari pembacaan source di repositori ini. Bila sebuah berkas instruksi tidak dapat diakses, instruksi tersebut tidak diklaim telah diikuti.

---

## 6. Peta Laporan

| Berkas | Isi |
|---|---|
| `01_BUSINESS_LOGIC_DEFECTS.md` | Registri kanonik 59 temuan dengan 12 field wajib |
| `02_SALES_PURCHASE_AUDIT.md` | Alur penjualan, pembelian, estimasi, dan otorisasi harga |
| `03_RETURN_CANCEL_AUDIT.md` | Retur penjualan/pembelian, void, dan reversal |
| `04_INVENTORY_AUDIT.md` | Stok, opname, cost state, dan nilai persediaan |
| `05_FINANCIAL_CALCULATION_AUDIT.md` | HPP, laba kotor, pajak, kas, piutang, payroll |
| `06_DATABASE_INTEGRITY_AUDIT.md` | Skema, trigger, snapshot, restore, multi-toko |
| `07_BACKUP_RESTORE_AUDIT.md` | Backup, restore, validasi, dan kegagalan di tengah proses |
| `08_APPLICATION_FLOW_AUDIT.md` | Startup, alur UI, error, dan desinkronisasi state |
| `09_SECURITY_AUDIT.md` | Sesi, PIN, otorisasi service, viewer, ekspor owner |
| `10_ERROR_HANDLING_AUDIT.md` | Penanganan kegagalan, pesan, rollback, dan pemulihan |
| `11_REMEDIATION_ROADMAP.md` | Rencana remediasi + rencana database bersih + rencana feature toggle |
| `12_IMPLEMENTATION_ORDER.md` | Urutan implementasi 10 tahap dengan Definition of Done |

---

## 7. Catatan Akhir

Temuan disusun berdasarkan **apa yang benar-benar dapat dilakukan kode**, bukan berdasarkan asumsi tentang niat pengguna. Beberapa temuan bergantung pada urutan operasi (mis. opname tertunda, restore saat sync, sign-out lalu onboarding); skenario tersebut ditulis eksplisit di setiap entri. Tidak ada temuan yang dibuat untuk memenuhi jumlah, dan tidak ada test yang dijalankan untuk “membuktikan” temuan—validasi dilakukan dengan membaca jalur eksekusi dan constraint database.
