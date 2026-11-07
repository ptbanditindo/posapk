# 02 — Audit Penjualan dan Pembelian

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, atau simulasi runtime yang dijalankan. Seluruh temuan berasal dari pembacaan kode dan penelusuran call chain.

**Berkas utama:** `pusatkupos/lib/data/app_database.dart` (`createTransaction`, `allocateDocumentNumber`, `listRecords`, `recordDetail`, `reportSummary`), `pusatkupos/lib/data/price_rules.dart`, `pusatkupos/lib/ui/screens/pos_screen.dart`, `pusatkupos/lib/data/receipt_service.dart`, `pusatkupos/lib/data/supplier_service.dart`, `pusatkupos/lib/sync/sync_service.dart`, `pusatkupos/lib/data/note_sync.dart`.

---

## 1. Ringkasan cakupan

| Area | Status di aplikasi | Kedalaman audit |
|---|---|---|
| Penjualan jasa/part (POS) | Ada | Alur penuh: validasi, harga, diskon, pembayaran, stok, nomor nota, komisi, sinkronisasi |
| Penjualan sparepart saja | Ada (`transactionJualSparepart`) | Alur penuh |
| Order kerja (work order) | Ada | Pembuatan, status, konversi ke nota |
| Estimasi | Ada | Pembuatan, revisi, pembatalan, konversi (dibahas juga di 03 dan 08) |
| Pembelian / purchase order | **Tidak ada modul transaksi pembelian** | Hanya stok masuk dan follow-up supplier |
| Utang usaha / pembayaran supplier | **Tidak ada** | Tidak ada tabel atau alur pembayaran supplier |
| Nilai pembelian per transaksi | **Tidak ada** | `stockIn` hanya mengubah jumlah, bukan harga modal |

**Konsekuensi cakupan pembelian:** aplikasi tidak memiliki entitas pembelian, penerimaan barang bernilai, total pembelian, pembayaran pembelian, atau utang supplier. Karena itu tidak ada perhitungan pembelian yang dapat diaudit sebagai transaksi. Yang tersedia hanya:

- `stockIn` — menambah jumlah stok tanpa mencatat harga beli (`app_database.dart:955-976`, `_adjustStock` di `1054-1094`).
- `saveStockItem` — satu-satunya jalur yang menetapkan `harga_modal`, dan hanya pemilik yang boleh membuat/mengubah harga (`app_database.dart:794-953`, khususnya `816-831`).
- `supplier_service.dart` — master supplier, pemetaan barang, follow-up, status DIPESAN/DIKIRIM/TIDAK_TERSEDIA/ARSIP; tidak ada nilai uang.

Ketiadaan modul ini **bukan** cacat implementasi yang dapat dibuktikan sebagai kesalahan, melainkan batas cakupan produk. Bila pemilik menganggap pembelian sebagai kebutuhan bisnis, ini harus dikonfirmasi sebagai kebutuhan fitur, bukan diperlakukan sebagai bug.

---

## 2. Alur penjualan aktual (call chain)

### 2.1 Dari layar kasir ke database

1. `PosScreen` menyusun `JobDraft`/`PartDraft`, menghitung tampilan, lalu memanggil `AppDatabase.createTransaction` (`pusatkupos/lib/ui/screens/pos_screen.dart`, area `381-510`).
2. `createTransaction` (`app_database.dart:1186-1747`) memvalidasi:
   - jenis transaksi dikenal dan bukan `estimasi_saja` (`1225-1233`);
   - minimal satu jasa/part (`1234-1236`);
   - sparepart-only tidak boleh berisi jasa (`1237-1242`);
   - diskon dan nominal bayar tidak negatif (`1243-1248`);
   - metode hanya CASH/TRANSFER (`1249-1251`).
3. Pengaturan toko dibaca (`1252`), jenis transaksi harus aktif (`1254-1256`), peran harus boleh memilih jenis tersebut (`1257-1259`), dan diskon memerlukan izin `diskon` (`1260-1265`).
4. Persetujuan diskon non-pemilik diverifikasi **di luar transaksi** (`1276-1297`) agar penghitung gagal PIN tetap tersimpan.
5. Idempotensi nota memakai `request_id`: bila sudah ada, nota lama dikembalikan dan di-enqueue ulang (`1299-1312`). Kolom `service_records.request_id` memiliki `UNIQUE` (`schema.dart:468`).
6. Harga jasa dicek terhadap tarif katalog saat ini; bila berubah, transaksi ditolak (`1314-1337`). Harga part dicek terhadap `stock_items.harga_jual` (`1358-1374`).
7. Stok dicek per barang dengan akumulasi baris duplikat (`1350-1400`). Bila kurang, transaksi ditolak.
8. Diskon dialokasikan proporsional dan divalidasi terhadap modal per baris (`PriceRules.allocate`, `price_rules.dart:83-233`). Pemilik boleh di bawah modal; non-pemilik tidak (`1401-1423`).
9. Total dihitung: `bruto = biayaJasa + totalPart`, `total = bruto - diskon` (`1424-1434`). Transfer tidak boleh melebihi total (`1435-1439`). Tunai berlebih menjadi kembalian (`1440-1443`). Sisa menentukan LUNAS/KREDIT (`1444-1445`).
10. Nomor nota dibuat lewat `allocateDocumentNumber` dengan prefiks jenis (`1447-1457`).
11. Pelanggan/unit diresolusi; nota menyimpan `customer_id` sendiri (`1458-1493`, insert `1536-1541`).
12. Mekanik difilter `aktif = 1` (`1501-1519`).
13. Nota, baris jasa, baris part, pengurangan stok, movement KELUAR, dan pembayaran awal disimpan dalam satu transaksi database (`1536-1677`).
14. Audit izin ditulis bila ada diskon atau harga di bawah modal (`1679-1694`).
15. Komisi mekanik dihitung dan disimpan (`1695-1704`).
16. Bila berasal dari order kerja/estimasi, status sumber diperbarui (`1705-1743`).

### 2.2 Sifat atomik

Seluruh penulisan nota berada di dalam `db.transaction`. Bila salah satu langkah gagal, SQLite membatalkan seluruh perubahan. Ini adalah kontrol yang baik dan menutup banyak skenario "sebagian tersimpan". Pengecualian penting: verifikasi persetujuan dilakukan di luar transaksi (disengaja), dan sinkronisasi berjalan setelah commit melalui outbox, sehingga kegagalan sync tidak membatalkan nota lokal.

### 2.3 Nomor nota

`allocateDocumentNumber` memakai prefiks + kode perangkat + tanggal + urutan dari `document_counters`. `service_records.no_nota` memiliki `UNIQUE`. Konflik nomor saat penerimaan payload diselesaikan dengan renumber + baris `sync_conflicts` (`note_sync.dart:444-490`). Risiko bentrok kode perangkat dibahas sebagai **BL-33**.

---

## 3. Analisis aturan bisnis penjualan

### 3.1 Subtotal dan pembulatan

- Subtotal baris = `round(harga × qtyMilli / 1000)` (`price_rules.dart:39`).
- Total nota = `bruto - diskon teralokasi` (`price_rules.dart:225`; `app_database.dart:1432-1434`).
- Diskon dialokasikan proporsional dengan sisa pembulatan dipindahkan ke baris yang masih memiliki ruang (`price_rules.dart:162-189`). Total alokasi selalu sama dengan diskon nota.
- Nilai `harga_final` per baris dihitung dari total setelah diskon, sehingga dapat mengalami pembulatan berbeda dari `subtotal - diskon_alokasi`; laporan memakai `subtotal - diskon_alokasi`, bukan `harga_final`. Ini konsisten untuk laporan, tetapi perlu diingat saat merekonsiliasi struk per baris.

**Kesimpulan:** aritmetika dasar penjualan konsisten dan tidak ditemukan cacat pembulatan yang dapat dibuktikan sebagai salah hitung. Masalah yang ditemukan bukan pada aritmetika, melainkan pada **total efektif setelah koreksi** (BL-05) dan **tampilan struk** (BL-18).

### 3.2 Diskon dan batas modal

- Non-pemilik: harga jual tidak boleh di bawah modal, dan diskon tidak boleh melebihi total margin (`price_rules.dart:139-156`).
- Pemilik: boleh di bawah modal, dicatat di `permission_audits` (`app_database.dart:1679-1694`).
- Persetujuan non-pemilik memakai PIN pemilik atau approver yang didelegasikan (`approval_service.dart`).
- **Cacat terkait:** `actor == null` dianggap pemilik (BL-27), dan `createEstimate` juga memakai default pemilik (BL-37). Jalur normal dari UI selalu mengirim operator, sehingga ini adalah risiko jalur internal/refactor, bukan penyalahgunaan normal.

### 3.3 Pembayaran, kembalian, dan sisa

- `dibayar = clamp(bayar, 0, total)`; `sisa = total - dibayar` (`app_database.dart:1440-1445`).
- Tunai berlebih dicatat sebagai `kembalian`; transfer berlebih ditolak (`1435-1443`).
- Pembayaran awal disimpan sebagai `DP` atau `PELUNASAN` (`1664-1678`).
- **Cacat terkait:** pelunasan lintas perangkat dapat melebihi sisa (BL-14); pelunasan/retur tidak memiliki idempotensi yang stabil di UI (BL-13); struk mencetak kembalian hanya dari pembayaran awal (BL-18, BL-39).

### 3.4 Status dan duplikasi nota

- Status pembayaran: `LUNAS` bila sisa 0, `KREDIT` bila ada sisa (`1445`).
- Status nota: `AKTIF`/`VOID`; void mengisi `voided_at` dan `void_reason`.
- Duplikasi dicegah oleh `request_id` unik dan oleh commit tunggal. Namun UI harus mengirim `request_id` yang stabil; `pos_screen` menyimpannya sampai simpan berhasil. Ini adalah implementasi yang benar untuk penjualan.
- **Cacat terkait:** retur dan pelunasan tidak memakai pola yang sama (BL-13).

### 3.5 Stok saat penjualan

- Validasi lokal menjumlahkan qty per `stockItemId` dan menolak bila melebihi stok (`app_database.dart:1350-1400`).
- Pengurangan stok dan movement KELUAR ditulis dalam transaksi yang sama (`1637-1662`).
- Movement penjualan **tidak** di-enqueue terpisah; penerima mengurangi stok dari payload nota. Ini menghindari pengurangan ganda dan bukan cacat.
- **Cacat terkait:** dua perangkat offline dapat menjual stok terakhir yang sama (BL-21); validasi tidak memeriksa `deleted_at` barang (BL-26); penerima movement dapat menghasilkan stok negatif (BL-24).

### 3.6 Komisi penjualan

- Komisi dihitung dari baris jasa/part dan mekanik yang dipilih (`_insertMechanicsAndCommissions`).
- **Cacat terkait:** rekalkulasi memakai tarif saat ini dan dapat menimpa komisi lama, termasuk menjadi 0 bila akun hilang (BL-04); penerima retur tidak merekalkulasi (BL-40); void tidak menyesuaikan komisi (BL-34).

### 3.7 Tampilan total setelah koreksi

- `listRecords`/`recordDetail` mengembalikan `total_servis` asli (`app_database.dart:2399-2470`).
- `reportSummary` menambahkan `adjustmentTotal` ke total (`2956-2971`).
- Struk mencetak `record.totalCents` asli (`receipt_service.dart:274-313`).
- Dashboard memakai `summary.totalCents` (`3125-3147`).
- **Cacat:** BL-05 (total berbeda antara daftar/detail/struk dan laporan), BL-18 (struk), BL-19 (label pendapatan bruto).

### 3.8 Pencarian dan identitas pelanggan pada penjualan

- Nota menyimpan `customer_id` sendiri, termasuk untuk penjualan sparepart tanpa unit (`1536-1541`).
- `listRecords`/`recordDetail` melakukan join hanya lewat `unit_id` (`2400-2407`, `2417-2424`).
- **Cacat:** BL-17 — nota tanpa unit tampil tanpa nama pelanggan dan tidak ditemukan lewat pencarian nama pelanggan.

---

## 4. Temuan khusus area penjualan

| ID | Nama | Risiko | Validitas | Ringkasan |
|---|---|---|---|---|
| BL-05 | Total terkoreksi tidak konsisten | TINGGI | CONFIRMED | Daftar/detail/struk memakai total asli; laporan memakai total+adjustment |
| BL-13 | Retur/pelunasan tanpa submit guard | SEDANG | SUSPECTED | Ketukan ganda dapat membuat dua transaksi |
| BL-14 | Pelunasan lintas perangkat melebihi sisa | SEDANG | SUSPECTED | Dua perangkat menerima pembayaran yang sama |
| BL-17 | Join pelanggan hanya lewat unit | SEDANG | CONFIRMED | Nota tanpa unit kehilangan nama pelanggan di riwayat |
| BL-18 | Struk memakai total asli, kembalian awal | SEDANG | CONFIRMED | Cetak ulang tidak mencerminkan koreksi/retur |
| BL-19 | "Pendapatan hari ini" bruto | SEDANG | CONFIRMED | Label menyesatkan; retur tidak dikurangkan |
| BL-21 | Penjualan bersamaan stok yang sama | SEDANG | SUSPECTED | Tidak ada reservasi lintas perangkat |
| BL-26 | Filter stok abaikan deleted_at | RENDAH | CONFIRMED | Barang terhapus dapat dianggap aktif |
| BL-27 | Actor null = pemilik | RENDAH | CONFIRMED | Jalur tanpa operator mendapat hak penuh |
| BL-34 | Void tidak menyesuaikan komisi/pembayaran | RENDAH | CONFIRMED | Laporan komisi dan pembayaran tidak bersih |
| BL-36 | Order kerja memakai izin buat_nota | RENDAH | CONFIRMED | Izin jenis order tidak berlaku |
| BL-37 | Estimasi actor null = pemilik | RENDAH | CONFIRMED | Diskon di bawah modal lolos tanpa persetujuan |
| BL-39 | Kembalian struk hanya pembayaran awal | RENDAH | CONFIRMED | Pelunasan/refund tidak menampilkan kembalian |

Detail lengkap setiap temuan ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 5. Skenario kegagalan yang dianalisis (penjualan)

| Skenario | Perilaku kode | Kesimpulan |
|---|---|---|
| Aplikasi ditutup di tengah penyimpanan | Semua penulisan dalam satu `db.transaction` | Tidak ada nota separuh jadi; SQLite rollback |
| Penyimpanan gagal setelah stok dikurangi | Stok, movement, dan nota berada di transaksi yang sama | Ikut rollback; tidak ada pengurangan stok yatim |
| Ketukan ganda tombol simpan | `_saving` guard di `pos_screen`; `request_id` stabil | Terlindungi untuk penjualan |
| Retry setelah timeout | `request_id` sama mengembalikan nota lama | Tidak membuat nota duplikat |
| Harga katalog berubah saat form terbuka | Dicek ulang di server lokal; ditolak dengan pesan muat ulang | Konsisten |
| Dua kasir menjual barang terakhir | Validasi hanya lokal | BL-21 (SUSPECTED) |
| Diskon melebihi margin non-pemilik | `PriceRules.allocate` menolak | Terlindungi |
| Persetujuan PIN gagal | Transaksi tidak dibuat; penghitung gagal tetap tersimpan | Sesuai desain |
| Nota dikoreksi setelah pembayaran | Total asli tidak diubah; adjustment terpisah | BL-05, BL-18 |
| Nota di-void setelah retur | Void lokal menolak bila ada retur | Terlindungi lokal; lintas perangkat tidak (BL-02) |

---

## 6. Batas audit area ini

- Tidak ada eksekusi UI, sehingga perilaku tombol, dialog, dan printer tidak diverifikasi secara runtime.
- Adapter printer dan template struk hanya diperiksa pada bagian perhitungan total; pemetaan perintah printer tidak diaudit mendalam.
- Modul pembelian tidak ada, sehingga tidak ada analisis pembelian transaksional.
- Relay hanya diperiksa pada bagian yang memengaruhi penerimaan nota/izin; endpoint laporan premium tidak diaudit.

**Kesimpulan area:** alur penjualan inti memiliki kontrol atomik dan idempotensi yang baik. Cacat terbesar bukan pada pembuatan nota baru, melainkan pada **konsistensi setelah koreksi/retur/void** dan pada **perilaku lintas perangkat**. Tidak ditemukan bukti salah hitung aritmetika dasar pada penjualan normal.
