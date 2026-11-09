# 01 — BUSINESS LOGIC DEFECTS

Dokumen ini memuat registry temuan business logic lintas domain. Setiap temuan memakai format wajib: ID/severity/judul, kategori, status, lokasi, fungsi/kelas, implementasi aktual, penyebab, dampak bisnis, skenario terdampak, rekomendasi, dependensi.

Kategori status yang dipakai:
`CONFIRMED DEFECT`, `POTENTIAL DEFECT`, `ARCHITECTURE GAP`, `MISSING FEATURE`, `SECURITY WEAKNESS`, `PERFORMANCE ISSUE`, `DATA INTEGRITY RISK`, `NEEDS CLARIFICATION`, `NEEDS VALIDATION`.

---

## A. Transaksi, Harga, dan Pembayaran

### TRX-01 — Harga jasa manual melewati kontrol izin dan laporan harga
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi di kode
- **Lokasi:** [pos_screen.dart:1742](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1742), [app_database.dart:2023](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2023), [app_database.dart:2101](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2101)
- **Fungsi/Kelas:** `_JobDialog` → `JobDraft(hargaTerdaftarCents: selected?.hargaCents ?? 0)`; `AppDatabase.createTransaction`; `PriceRules.allocate`
- **Implementasi saat ini:** Untuk jasa non-katalog, `_JobDialog` mengirim `hargaTerdaftarCents = 0`. Di `createTransaction`, pemeriksaan `Permissions.require(actor, permissionPriceOverride)` hanya dijalankan bila `job.hargaTerdaftarCents > 0`. Baris lalu dibangun dengan `hargaTerdaftar: job.hargaCents`. Akibatnya harga jasa manual dianggap "harga terdaftar = 0", tidak pernah dianggap di bawah harga, dan tidak masuk `belowPriceSales`.
- **Penyebab:** UI tidak membedakan "jasa tanpa katalog" dari "harga terdaftar nol"; service memakai nilai yang dikirim UI sebagai basis kontrol.
- **Dampak bisnis:** Kasir dapat menetapkan harga jasa apa pun tanpa izin, tanpa alasan, dan tanpa jejak pelanggaran harga. Pemilik kehilangan kontrol margin jasa dan laporan harga di bawah minimum tidak lengkap.
- **Skenario terdampak:** SC-01, seluruh transaksi jasa manual.
- **Rekomendasi:** Kirim harga terdaftar dari master/harga acuan, atau tambahkan penanda `hargaIstimewa` yang wajib disetujui dan dicatat; jalankan pemeriksaan izin berdasarkan `hargaFinal` vs acuan, bukan nilai UI.
- **Dependensi:** TRX-08, TRX-05, REP-01.

### TRX-02 — Harga acuan nego tidak tersimpan; baris jasa mencatat harga input sebagai "harga terdaftar"
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT / DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:2028](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2028), [receipt_service.dart:250](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/receipt_service.dart#L250)
- **Fungsi/Kelas:** `createTransaction` pembentukan `PriceLine`; `ReceiptService.items()`
- **Implementasi saat ini:** `PriceLine` jasa dibangun dengan `hargaTerdaftar: job.hargaCents` (harga yang diketik kasir), bukan `job.hargaTerdaftarCents` (harga master/acuan). Untuk jasa bebas, UI mengirim `hargaTerdaftarCents = 0`, tetapi baris tetap mencatat 325.000 sebagai "terdaftar". Struk mencetak nilai itu, sehingga tampil 325.000 dengan subtotal yang benar.
- **Penyebab:** Argumen `hargaTerdaftar` pada `PriceLine` diisi harga final, bukan harga acuan.
- **Dampak bisnis:** Tidak ada bukti bahwa harga normal 350.000; nego tidak dapat dibedakan dari harga normal, tidak masuk `belowPriceSales`, dan tidak dapat diaudit. Bila diskon nota dipakai, struk mencetak harga bruto + baris diskon (default `showLineDiscount=true`); mematikan opsi itu membuat jumlah baris tidak cocok dengan total. Tidak ditemukan cetakan "Rp 0" pada jalur ini.
- **Skenario terdampak:** SC-01.
- **Rekomendasi:** Simpan harga acuan/master dan harga final secara terpisah; baris struk menampilkan harga acuan, diskon, dan harga final; pastikan total baris = subtotal.
- **Dependensi:** TRX-01, TRX-05.

### TRX-03 — Nominal bayar dan kembalian di struk tidak konsisten
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [receipt_service.dart:340](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/receipt_service.dart#L340), [receipt_service.dart:346](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/receipt_service.dart#L346)
- **Fungsi/Kelas:** `ReceiptService.totals()`
- **Implementasi saat ini:** Baris "Bayar" mencetak `detail.totalDibayarCents` (nilai yang sudah di-clamp ke total), sedangkan "Kembalian" dihitung dari `record.bayarCents` mentah.
- **Penyebab:** Dua sumber angka berbeda dalam satu blok struk.
- **Dampak bisnis:** Untuk pembayaran tunai lebih, struk menampilkan "Bayar = total" dan "Kembalian = selisih", sehingga aritmetika tidak cocok dan kasir/pelanggan dapat mempertanyakan transaksi.
- **Skenario terdampak:** Pembayaran tunai dengan uang lebih.
- **Rekomendasi:** Cetak uang diterima mentah, lalu total, lalu kembalian; atau cetak keduanya secara eksplisit.
- **Dependensi:** TRX-04.

### TRX-04 — Tombol "Bayar penuh" membulatkan ke rupiah utuh sehingga transfer ditolak
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [pos_screen.dart:1332](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1332), [money.dart:87](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/core/money.dart#L87), [app_database.dart:2142](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2142)
- **Fungsi/Kelas:** `_bayar.text = formatRupiahPlain(_total)`; `formatRupiahPlain`; `createTransaction`
- **Implementasi saat ini:** `formatRupiahPlain` membulatkan sen ke rupiah utuh. Nilai itu dipakai sebagai nominal transfer. Service menolak transfer dengan `bayar > total` (overpay).
- **Penyebab:** Pembulatan tampilan dipakai sebagai nilai transaksi.
- **Dampak bisnis:** Nota dengan total ber-sen (mis. akibat PPN) tidak bisa dibayar penuh via transfer; kasir harus mengetik manual dan berisiko salah.
- **Skenario terdampak:** Pembayaran transfer, nota ber-PPN.
- **Rekomendasi:** Simpan nominal persis; tombol "Bayar penuh" mengisi nilai sen tanpa pembulatan; pembulatan hanya untuk tampilan.
- **Dependensi:** TRX-03.

### TRX-05 — Tidak ada negosiasi per item; diskon nota dialokasikan proporsional
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Sesuai desain tetapi tidak memenuhi kebutuhan umum bengkel
- **Lokasi:** [price_rules.dart:178](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/price_rules.dart#L178), [app_database.dart:2066](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2066)
- **Fungsi/Kelas:** `PriceRules.allocate`; jalur part `createTransaction`
- **Implementasi saat ini:** Diskon hanya satu nilai tingkat nota lalu dibagi proporsional ke baris. Harga part wajib sama dengan harga master; harga jasa bebas hanya untuk non-katalog.
- **Penyebab:** Model data tidak memiliki harga final per item sebagai input; harga final diturunkan dari diskon nota.
- **Dampak bisnis:** Kasir tidak bisa menegosiasi "part A 100.000, part B tetap" atau menurunkan satu part tertentu; nego harus lewat diskon nota yang mendistorsi margin per item.
- **Skenario terdampak:** SC-01 varian multi-item.
- **Rekomendasi:** Tambahkan input harga final per baris + alasan, validasi izin per baris, dan alokasi diskon eksplisit.
- **Dependensi:** TRX-01, TRX-06.

### TRX-06 — Batas harga memakai modal master, bukan HPP rata-rata
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT / DATA INTEGRITY RISK
- **Status:** Perlu validasi kebijakan bisnis
- **Lokasi:** [app_database.dart:2085](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2085), [app_database.dart:2441](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2441)
- **Fungsi/Kelas:** `createTransaction` (modal part) vs laporan HPP
- **Implementasi saat ini:** Baris part memakai `stock_items.harga_modal` sebagai modal untuk cek batas margin. Pembelian tidak memperbarui `stock_items.harga_modal`; HPP sebenarnya memakai rata-rata bergerak di `stock_ledger`.
- **Penyebab:** Dua sumber modal berbeda: master vs valuasi ledger.
- **Dampak bisnis:** Barang dengan harga beli naik dapat dijual di bawah HPP nyata tetapi lolos cek karena modal master lama; laporan laba memakai HPP berbeda dari dasar persetujuan.
- **Skenario terdampak:** Penjualan di bawah harga setelah kenaikan harga beli.
- **Rekomendasi:** Gunakan `StockLedger.averageCostMilli` sebagai modal baris; simpan snapshot modal final di baris nota.
- **Dependensi:** INV-05, INV-08.

### TRX-07 — Jasa harga nol mustahil dibuat lewat POS; `alasanDiskon` tidak pernah dikirim
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [pos_screen.dart:768](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L768), [app_database.dart:1892](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1892), [app_database.dart:1986](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1986)
- **Fungsi/Kelas:** `_createWithApproval`; `createTransaction`
- **Implementasi saat ini:** `createTransaction` menolak `hargaCents == 0` kecuali `allowBelowMinimum && hasDiscountReason`. `_createWithApproval` tidak pernah mengirim `alasanDiskon`. Bahkan owner (`allowBelowMinimum = true`) tetap gagal karena alasan kosong. Hanya jalur konversi estimasi yang mengirim alasan (mis. "Diskon estimasi"/"Konversi estimasi …").
- **Penyebab:** UI dan service tidak sinkron kontrak parameter.
- **Dampak bisnis:** Jasa gratis (garansi, bonus, servis internal) tidak bisa dibuat dari POS; kasir dipaksa memberi harga ≥ 1 atau memakai jalur lain. Ini juga mematikan fitur "harga nol dengan persetujuan" yang dirancang.
- **Skenario terdampak:** Servis garansi/bonus, SC-01.
- **Rekomendasi:** Kirim alasan dari dialog persetujuan; bedakan "gratis" dan "diskon 100%"; tampilkan di struk.
- **Dependensi:** TRX-08, TRX-02.

### TRX-08 — Persetujuan PIN/penanggung jawab tidak mengizinkan harga di bawah minimum
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:1884](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1884), [app_database.dart:1891](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1891), [pos_screen.dart:815](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L815)
- **Fungsi/Kelas:** `createTransaction`; `_createWithApproval`
- **Implementasi saat ini:** `allowBelowMinimum = isOwner || overrideApprover != null`. `overrideApprover` hanya berasal dari parameter `approvedByOverride` (dipakai konversi estimasi), bukan dari `ownerPin`/`approverSecret`. Retry UI mengisi `ownerPin`/`approverSecret`, tetapi keduanya tidak memengaruhi `allowBelowMinimum`.
- **Penyebab:** Dua mekanisme persetujuan berbeda (ApprovalService vs override string) tidak dihubungkan.
- **Dampak bisnis:** Kasir tidak dapat menjual di bawah margin meskipun owner menyetujui via PIN; alur persetujuan yang ditampilkan UI menyesatkan. Sebaliknya, `approvedByOverride` dari estimasi dipercaya tanpa verifikasi PIN.
- **Skenario terdampak:** Diskon/harga bawah minimum, konversi estimasi.
- **Rekomendasi:** Setelah `ApprovalService.verify` sukses, set `allowBelowMinimum = true` dan simpan approver; verifikasi ulang `approvedByOverride` atau batasi hanya untuk konversi yang sudah tersegel.
- **Dependensi:** TRX-07, SEC-08.

### TRX-09 — Pembulatan `harga_final` dapat berbeda 1 sen dari subtotal baris
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi secara aritmetika
- **Lokasi:** [price_rules.dart:39](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/price_rules.dart#L39), [price_rules.dart:205](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/price_rules.dart#L205)
- **Fungsi/Kelas:** `PriceLine.subtotal`; `PriceRules.allocate`
- **Implementasi saat ini:** `subtotal = (hargaTerdaftar * qtyMilli / 1000).round()`; `hargaFinal = (finalTotal * 1000 / qtyMilli).round()`. Perkalian balik dapat menghasilkan selisih ±1 sen.
- **Penyebab:** Pembulatan ganda pada harga satuan dan subtotal.
- **Dampak bisnis:** Minor; dapat memicu selisih rekonsiliasi pada qty besar.
- **Rekomendasi:** Simpan `harga_final` sebagai nilai turunan untuk tampilan dan gunakan `finalTotal` sebagai sumber resmi.
- **Dependensi:** —

### TRX-10 — Qty desimal diterima untuk satuan bulat; qty < 1 terpotong menjadi 0
- **Severity:** LOW
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [pos_screen.dart:1836](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1836), [pos_screen.dart:1853](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1853), [schema.dart:784](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema.dart#L784)
- **Fungsi/Kelas:** `_PartDialog`
- **Implementasi saat ini:** Input qty selalu memakai `desimal: 3` tanpa melihat `item.desimal`. Nilai `jumlah` (kolom baris nota) dihitung `qtyMilli ~/ 1000`, sehingga 0,5 pcs menjadi 0.
- **Penyebab:** UI tidak menghormati flag desimal item.
- **Dampak bisnis:** Baris dengan qty 0 pada kolom laporan; pembulatan qty yang tidak sesuai satuan.
- **Rekomendasi:** Batasi input sesuai `desimal`; simpan qty utama dalam milli; jangan memakai pembagian truncating untuk laporan.
- **Dependensi:** —

### TRX-11 — Total di layar dapat berbeda dari total tersimpan bila pengaturan pajak berubah
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** NEEDS VALIDATION
- **Lokasi:** [pos_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart), [app_database.dart:2128](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2128)
- **Fungsi/Kelas:** Perhitungan total di UI vs `PajakSnapshot.hitung` di service
- **Implementasi saat ini:** UI menghitung total dari snapshot pengaturan saat layar dimuat; service dapat memakai pengaturan terbaru saat simpan.
- **Penyebab:** Snapshot pajak tidak dikirim sebagai bagian kontrak final (bergantung pemanggil).
- **Dampak bisnis:** Kasir menagih angka A, nota tersimpan angka B.
- **Rekomendasi:** Kirim snapshot pajak yang dipakai UI dan validasi kesamaan; tolak simpan bila berubah tanpa konfirmasi.
- **Dependensi:** REP-03.

### TRX-12 — Penyesuaian nota mencampur komponen ber-PPN dan tidak ber-PPN
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** NEEDS VALIDATION
- **Lokasi:** [nota_adjustment_service.dart:226](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/nota_adjustment_service.dart#L226)
- **Fungsi/Kelas:** `NotaAdjustmentService`
- **Implementasi saat ini:** Penyesuaian menambah/mengurangi nilai nota; perlakuan PPN atas penyesuaian tidak memisahkan DPP/PPN secara eksplisit.
- **Penyebab:** Penyesuaian diperlakukan sebagai nilai total.
- **Dampak bisnis:** DPP dan PPN dapat bergeser tanpa jejak; laporan pajak tidak cocok dengan nota.
- **Rekomendasi:** Simpan DPP/PPN penyesuaian terpisah; tampilkan di rincian nota.
- **Dependensi:** REP-02, REP-03.

---

## B. Ringkasan Temuan Domain Lain

Registry lengkap ada di laporan domain masing-masing. Ringkasan:

| Domain | File | Jumlah | Severity tertinggi |
|---|---|---|---|
| Inventori | 03_INVENTORY_AUDIT.md | 14 | HIGH (4) |
| Database | 04_DATABASE_INTEGRITY_AUDIT.md | 6 | MEDIUM |
| Offline-first | 05_OFFLINE_FIRST_AUDIT.md | 5 | CRITICAL (via SEC-02) |
| Sync/multi-device | 06_SYNC_MULTI_DEVICE_AUDIT.md | 9 | HIGH |
| Arsitektur | 07_ARCHITECTURE_AUDIT.md | 5 | MEDIUM |
| Alur aplikasi | 08_APPLICATION_FLOW_AUDIT.md | 5 | HIGH (via SEC-01) |
| Keamanan/E2EE | 09_SECURITY_E2EE_AUDIT.md | 16 | CRITICAL (2) |
| Error handling | 10_ERROR_HANDLING_AUDIT.md | 7 | MEDIUM |
| Feature toggle | 11_FEATURE_TOGGLE_AUDIT.md | 4 | MEDIUM |

---

## C. Uji Konsistensi Lintas Fitur

| Uji | Hasil | Bukti |
|---|---|---|
| Harga nego konsisten di transaksi, stok, laporan, sync | **PARTIAL** | `harga_final` tersimpan & diekspor sync; struk & laporan harga bawah tidak konsisten (TRX-01/02) |
| Nota offline dapat ditemukan setelah sync | **PARTIAL** | Pencarian lokal hanya nomor/nama, limit 200 (FLW-02) |
| Arsip mempertahankan detail | **FAIL** | Tidak ada arsip server; snapshot hanya state terakhir (SYN-06) |
| Hapus lokal tidak menghapus arsip server | **PASS dengan catatan** | Tidak ada purge lokal; arsip server tidak ada, jadi tidak ada yang terhapus |
| E2EE tidak membuat pencarian arsip mustahil | **FAIL** | Tanpa blind index, server tidak bisa mencari ciphertext (SEC-16) |
| Retry tidak menggandakan | **PARTIAL** | Nota/retur penjualan idempoten; pembelian dari UI tanpa requestId (INV-12) |
| Print tidak membuat transaksi baru | **PASS** | Print hanya membaca record |
| Perubahan pelanggan/harga master tidak mengubah riwayat | **PASS** | Snapshot + trigger imutabilitas |
| Sync stok tidak menimpa data lokal belum terkirim | **PARTIAL** | Apply per-nota idempoten; opname/void-retur divergen (INV-01/03) |
