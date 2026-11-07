# 04 — Audit Inventori

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, atau simulasi runtime yang dijalankan.

**Berkas utama:** `pusatkupos/lib/data/app_database.dart` (`listStock`, `saveStockItem`, `stockIn`, `stockOut`, `opname`, `_adjustStock`, `createTransaction`, `reportSummary`, `dashboard`), `pusatkupos/lib/sync/sync_service.dart` (`enqueueStock`, `enqueueStockMovement`, apply `stock`/`stock_movement`), `pusatkupos/lib/data/note_sync.dart` (retur/void), `pusatkupos/lib/ui/screens/stock_screen.dart`, `pusatkupos/lib/data/supplier_service.dart`.

---

## 1. Model inventori yang terdeteksi

| Konsep | Implementasi |
|---|---|
| Barang | `stock_items` (kode, nama, harga modal/jual, stok minimum, satuan, desimal, soft delete) |
| Kuantitas | Integer milli-unit (`jumlah_milli`), `jumlah` untuk tampilan |
| Mutasi | `stock_movements` (MASUK, KELUAR, KOREKSI; `service_record_id` opsional) |
| Stok masuk | `stockIn` — menambah qty, tanpa harga beli |
| Stok keluar | `stockOut` — mengurangi qty, alasan wajib |
| Opname | `opname` — menetapkan qty absolut, movement KOREKSI sebesar selisih |
| Penjualan | `createTransaction` — mengurangi stok dan movement KELUAR per part |
| Retur | menambah stok dan movement MASUK |
| Void | menambah stok dan movement MASUK (dikurangi retur yang diketahui) |
| Pembelian | **Tidak ada** — tidak ada penerimaan bernilai, utang, atau pembayaran supplier |
| Multi-toko | Satu database per toko; stok tidak dibagi antartoko |

---

## 2. Alur perubahan stok

### 2.1 Stok masuk (`app_database.dart:955-976` → `_adjustStock` `1054-1094`)

- Izin `stock_in` dicek bila actor ada (`964`).
- Qty harus > 0 (`965-966`).
- `_adjustStock` membaca qty terkini, menambah delta, menulis `stock_items`, membuat movement MASUK, lalu meng-enqueue barang dan movement (`1063-1093`).
- **Tidak** menerima atau menulis `harga_modal`. Harga beli hanya dapat diubah lewat `saveStockItem` oleh pemilik. Ini adalah keterbatasan fungsional, bukan bug: pembelian bernilai tidak dimodelkan.

### 2.2 Stok keluar (`978-1003`)

- Izin `stock_out`; qty > 0; alasan wajib.
- Memanggil `_adjustStock` dengan delta negatif.
- **Tidak** memeriksa apakah qty melebihi stok. Stok dapat menjadi negatif (BL-24).

### 2.3 Opname (`1005-1052`)

- Izin `opname`; qty fisik tidak boleh negatif.
- Menghitung `delta = fisik - sistem`, menulis qty absolut, membuat movement KOREKSI sebesar delta.
- **Tidak** memperbarui HLC `stock_items` dan tidak memperbarui `updated_at`.
- Meng-enqueue barang dan movement.

**Ini adalah akar BL-01:** `enqueueStock` tidak mengirim qty absolut (hanya metadata), sedangkan movement KOREKSI membawa delta. Penerima menjumlahkan delta ke stok lokalnya yang mungkin sudah berbeda.

### 2.4 Penjualan

- Validasi stok per barang dengan akumulasi baris (`1186-1400`).
- Pengurangan stok dan movement KELUAR ditulis dalam transaksi nota (`1637-1662`).
- Movement penjualan tidak di-enqueue terpisah; penerima mengurangi stok dari payload nota. Ini mencegah pengurangan ganda.

### 2.5 Retur dan void

- Retur lokal: stok +qty, movement `retur-<return>-<item>` (`sale_return_service.dart:163-193`).
- Void lokal: stok +qty penuh (lokal menolak void bila ada retur) (`app_database.dart:2634-2668`).
- Penerima retur: stok +qty **sebelum** dedupe movement (`note_sync.dart:998-1036`).
- Penerima void: stok + (qty − retur yang diketahui) (`note_sync.dart:337-380`).

### 2.6 Edit barang (`saveStockItem` `794-953`)

- Non-pemilik tidak boleh membuat barang atau mengubah harga (`816-831`).
- Qty negatif ditolak (`834`, `880-882`).
- Edit memakai rumus selisih terhadap `stokAwalMilli` agar penjualan yang masuk setelah form dibuka tidak tertimpa (`877-879`).
- Perubahan qty menghasilkan movement KOREKSI (`897-917`).
- HLC `stock_items` dinaikkan pada edit (`883-891`).
- Pengecekan kode duplikat **memasukkan baris soft-deleted** (`839-851`).
- Update tidak menyertakan `deleted_at`, sehingga status hapus baris tidak diubah oleh edit; tidak ada jalur hapus barang di UI lokal.

---

## 3. Konsistensi stok vs riwayat mutasi

Bila semua jalur berjalan normal, `stock_items.jumlah_milli` sama dengan akumulasi seluruh `stock_movements` (stok awal + masuk − keluar + koreksi + retur + void).

Titik yang dapat memutus konsistensi:

1. **Opname lintas perangkat (BL-01):** penerima menambahkan delta, bukan menetapkan absolut. Stok sistem menyimpang dari fisik dan dari akumulasi movement di perangkat asal.
2. **Retur lintas perangkat (BL-02):** stok ditambah sebelum dedupe movement; retur ganda/retur pada nota VOID menambah stok tanpa mutasi yang seimbang.
3. **Void lintas perangkat (BL-02):** restock dihitung dari retur yang diketahui penerima; retur yang datang belakangan tidak mengurangi restock void.
4. **Stok negatif (BL-24):** `stockOut` dan penerima movement mengizinkan stok negatif; dashboard menandainya sebagai konflik, tetapi stok tetap negatif.
5. **Barang soft-deleted (BL-26):** query daftar stok dan dashboard tidak memfilter `deleted_at`, sehingga barang terhapus tetap dihitung.
6. **Penjualan bersamaan (BL-21):** dua perangkat dapat menjual stok yang sama; penerima mencatat konflik tetapi tetap menerapkan stok negatif.

---

## 4. Stok minimum, stok negatif, dan dashboard

- `dashboard()` menghitung stok menipis dengan `jumlah_milli <= stok_minimum * 1000` tanpa filter `deleted_at` (`app_database.dart:3128-3131`).
- Stok negatif dihitung dari `stock_items < 0` ditambah konflik `stok_negatif` yang belum diselesaikan (`3137-3144`, `3152-3154`). Ini dapat menghitung sumber yang sama dua kali (barang negatif dan konfliknya), sehingga angka "masalah stok" dapat lebih besar dari jumlah barang bermasalah.
- Tidak ada kebijakan stok negatif yang konsisten: `saveStockItem` menolak negatif, `stockOut` mengizinkan, penerima movement mengizinkan dengan konflik. Status: **BL-24** (NEEDS VALIDATION).

---

## 5. Penomoran dan multi-perangkat

- Nomor dokumen (nota, retur, estimasi, order) memakai kode perangkat 3 karakter + tanggal + urutan dari `document_counters`.
- `document_counters` tidak ikut snapshot (`snapshot_sync.dart:12-90`), sehingga perangkat hasil bootstrap memulai dari nol.
- Dua perangkat dengan kode sama dapat menghasilkan nomor identik pada hari yang sama; penerima melakukan renumber dan mencatat `no_nota_bentrok` (`note_sync.dart:444-490`).
- Status: **BL-33** (SUSPECTED, RENDAH).

### 5.1 Kode barang UNIQUE tanpa renumber (BL-41)

- `stock_items.kode` adalah `TEXT NOT NULL UNIQUE` (`schema.dart:298`).
- Pemeriksaan duplikat di `saveStockItem` hanya memeriksa database lokal (`app_database.dart:839-851`).
- Penerima sync meng-insert barang baru berdasarkan `sync_id` tanpa memeriksa `kode` (`sync_service.dart:2890-2902`).
- Dua perangkat yang membuat barang dengan kode sama saat offline menyebabkan insert perangkat kedua melanggar UNIQUE. Envelope dicatat gagal, cursor tidak dimajukan (`sync_service.dart:1990-2015`), dan envelope berikutnya ikut tertahan.
- Berbeda dari nomor nota, tidak ada mekanisme renumber/penyelesaian otomatis untuk kode barang.
- Status: **BL-41** (SUSPECTED, SEDANG).

---

## 6. Supplier dan pengadaan (bukan pembelian)

`supplier_service.dart` menyediakan:

- Master supplier dengan status DIPESAN/DIKIRIM/TIDAK_TERSEDIA/ARSIP (`saveSupplier` `50-121`, `deleteSupplier` `123-153`).
- Pemetaan barang supplier (`syncItemSuppliers` `165-217`).
- Follow-up supplier dan daftar stok menipis (`lowStockItems` `219-241`).

Tidak ada total pembelian, harga beli per penerimaan, utang, atau pembayaran. `deleteSupplier` menghapus relasi secara fisik tanpa tombstone (BL-38). `lowStockItems` memfilter supplier terhapus tetapi tidak memfilter barang terhapus (terkait BL-26).

---

## 7. Temuan area inventori

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-01 | Opname absolut dikirim sebagai delta | KRITIS | SUSPECTED |
| BL-21 | Penjualan bersamaan stok yang sama | SEDANG | SUSPECTED |
| BL-24 | Kebijakan stok negatif tidak konsisten | SEDANG | NEEDS VALIDATION |
| BL-26 | Filter stok/kode abaikan soft delete | RENDAH | CONFIRMED |
| BL-33 | Kode perangkat 3 karakter dan counter lokal | RENDAH | SUSPECTED |
| BL-38 | Hapus supplier tanpa tombstone relasi | RENDAH | SUSPECTED |
| BL-41 | Kode barang duplikat lintas perangkat memblokir sinkronisasi | SEDANG | SUSPECTED |

Temuan retur/void yang memengaruhi stok ada di 03 (BL-02, BL-40). Detail lengkap di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 8. Skenario kegagalan yang dianalisis

| Skenario | Perilaku kode | Kesimpulan |
|---|---|---|
| Stok masuk gagal di tengah | `_adjustStock` dalam satu transaksi | Rollback |
| Opname di dua perangkat | Delta dikirim, bukan absolut | BL-01 |
| Stok keluar melebihi stok | Tidak dicek | BL-24 |
| Dua kasir menjual stok terakhir | Cek hanya lokal | BL-21 |
| Barang dihapus di perangkat lain | Daftar/dashboard tidak memfilter | BL-26 |
| Retur ganda lintas perangkat | Stok ditambah sebelum dedupe | BL-02 |
| Void setelah retur lintas perangkat | Restock memakai retur yang diketahui | BL-02 |
| Barang baru diterima lewat sync tanpa movement | Qty awal 0 | Perlu urutan movement; bukan temuan terpisah |
| Dua perangkat membuat nomor nota | Renumber + konflik | BL-33 |
| Dua perangkat membuat kode barang sama | UNIQUE menolak insert; envelope gagal, cursor tertahan | BL-41 |
| Aplikasi ditutup setelah stok berubah | Barang, movement, outbox dalam transaksi | Tidak ada kehilangan lokal |

---

## 9. Batas audit

- Dialog stok masuk/keluar/opname diperiksa pada bagian pemanggilan service; validasi input per field tidak diaudit menyeluruh.
- Tidak ada modul pembelian, sehingga tidak ada audit nilai pembelian/utang.
- Adapter printer label stok tidak diaudit.
- Tidak ada pengujian runtime untuk urutan amplop stok.

**Kesimpulan area:** pencatatan stok lokal atomik dan memiliki jejak movement. Kelemahan utama bersifat lintas perangkat (opname delta, retur/void, penjualan bersamaan, kode barang UNIQUE tanpa renumber) dan kebijakan stok negatif yang belum konsisten. Tidak ditemukan bukti bahwa stok berubah tanpa movement pada jalur lokal normal.
