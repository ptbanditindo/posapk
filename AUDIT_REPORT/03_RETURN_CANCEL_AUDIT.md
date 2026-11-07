# 03 — Audit Retur dan Pembatalan

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, atau simulasi runtime yang dijalankan.

**Berkas utama:** `pusatkupos/lib/data/sale_return_service.dart`, `pusatkupos/lib/data/app_database.dart` (`voidRecord`, `settleReceivable`, `recalculateRecordTotals`, `recalculateRecordCommissions`), `pusatkupos/lib/data/note_sync.dart` (`_upsertReturn`, cabang `action == 'void'`), `pusatkupos/lib/data/nota_adjustment_service.dart`, `pusatkupos/lib/data/order_service.dart`, `pusatkupos/lib/ui/screens/history_screen.dart`, `pusatkupos/lib/ui/screens/estimates_screen.dart`.

---

## 1. Ruang lingkup

| Jenis pembatalan | Ada | Catatan |
|---|---|---|
| Retur penjualan (per baris) | Ya | Mengurangi refund, menambah stok part, membuat payment REFUND |
| Void nota penjualan | Ya | Menolak bila sudah ada retur (lokal), menambah stok, refund penuh |
| Retur pembelian | **Tidak ada** | Tidak ada modul pembelian |
| Void pembelian | **Tidak ada** | — |
| Pembatalan estimasi | Ya | Status `batal`; tanpa otorisasi |
| Revisi estimasi | Ya | Versi baru; tanpa cek status dasar |
| Pembatalan order kerja | Sebagian | Lewat `changeStatus`; transisi dapat dilampaui pemilik |
| Koreksi nilai nota | Ya | Append-only `nota_adjustments`; bukan pembatalan |

---

## 2. Alur retur penjualan lokal

`SaleReturnService.createReturn` (`sale_return_service.dart:36-258`):

1. Validasi alasan, minimal satu baris, dan **izin `void`** (`45-61`). Izin `retur` hanya dipakai UI (BL-09).
2. Membaca nota; menolak bila nota sudah VOID (`63-73`).
3. Menghitung sisa yang dapat diretur per baris dari total terjual dikurangi retur yang sudah ada (`76-104`, `_returnableLines` `303-346`). Over-return lokal ditolak.
4. Refund per baris = proporsi nilai bersih baris (`subtotal - diskon_alokasi`) terhadap qty (`105-117`).
5. Membuat `sale_returns` dan `sale_return_items` (`126-162`).
6. Untuk baris part: menambah stok dan movement MASUK dengan `sync_id = 'retur-<returnSyncId>-<itemSyncId>'` (`163-193`).
7. Menghitung kas yang benar-benar diterima, membuat payment REFUND negatif bila ada kelebihan bayar (`195-234`).
8. Memanggil `recalculateRecordTotals` dan `recalculateRecordCommissions` (`235-240`).
9. Menulis audit `retur_nota` (`241-254`).

**Penilaian:** alur lokal relatif hati-hati — over-return dicegah, refund dibatasi kas yang diterima, dan total dikalkulasi ulang. Kelemahan utamanya adalah otorisasi (BL-09), idempotensi (BL-13), dan ketidakcocokan dengan penerima sinkronisasi (BL-02, BL-40).

---

## 3. Alur void nota lokal

`AppDatabase.voidRecord` (`app_database.dart:2593-2765`):

1. Alasan wajib; izin `void` bila actor ada (`2602-2606`).
2. Nota yang sudah void → keluar diam-diam (`2615`).
3. **Menolak void bila sudah ada retur** (`2616-2627`). Ini penting: void dan retur tidak boleh berlaku bersama pada perangkat yang sama.
4. Mengembalikan stok seluruh part dan membuat movement MASUK (`2628-2668`).
5. Menghitung total pembayaran positif non-REFUND; bila >0, membuat REFUND negatif dengan `request_id = void-<nota_sync_id>` (`2669-2700`).
6. Mengubah status menjadi VOID, `voided_at`, `void_reason`, `sisa_bayar=0` (`2701-2712`).
7. Membuka kembali estimasi/order yang terkait (`2713-2752`).
8. Menulis audit `void` (`2753-2762`).
9. Meng-enqueue nota void dan, bila ada refund, amplop payment terpisah (`2696-2699`, `2763`).

**Penilaian:** kontrol lokal baik untuk mencegah retur+void ganda. Namun `total_dibayar` tidak direkalkulasi setelah REFUND (tetap nominal lama), dan komisi tidak dinolkan (BL-34). Status VOID juga tidak dijadikan terminal state di penerima (BL-02).

---

## 4. Alur penerimaan retur/void dari perangkat lain

### 4.1 Retur (`note_sync.dart:922-1039`)

- Dedupe hanya berdasarkan `sale_returns.sync_id` (`930-937`).
- **Tidak** memeriksa apakah nota sudah VOID.
- **Tidak** memeriksa over-return terhadap total yang sudah diretur.
- Menambah stok **sebelum** memeriksa dedupe movement (`998-1036`). Bila movement sudah ada tetapi return baru, stok tetap bertambah lagi.
- Tidak membuat payment REFUND sendiri; `_upsertReturn` hanya menangani baris retur dan stok. Payment REFUND ikut terkirim di daftar `payments` payload nota dan diterapkan oleh loop pembayaran pemanggil (`note_sync.dart:499-511`), sehingga bukan kekurangan pada alur normal.
- Tidak merekalkulasi komisi (BL-40), hanya total (`1041-1045`).

### 4.2 Void (`note_sync.dart:309-398`)

- Menolak bila nota induk belum ada (retryable) (`310-315`).
- Nota sudah void → `duplicate` (`316`).
- Menambah stok sebesar qty part **dikurangi retur yang diketahui penerima** (`337-380`).
- **Tidak** memeriksa retur yang datang belakangan; retur setelah void tetap diterapkan.
- **Mengabaikan** `payments` pada payload void; hanya `sisa_bayar=0` (`382-396`). Refund bergantung pada amplop payment terpisah (BL-15).
- Tidak merekalkulasi total/komisi.

### 4.3 Payload nota yang sudah ada (`note_sync.dart:444-526`)

Saat nota sudah ada (termasuk yang sudah VOID), penerima masih:

- menerapkan pembayaran baru (`499-511`),
- menerapkan retur baru (`512-525`),
- memperbarui nomor nota dan status pasca-jual.

Tidak ada pemeriksaan `voided_at` pada cabang ini. Inilah akar **BL-02**: retur dapat masuk ke nota yang sudah dibatalkan.

---

## 5. Analisis divergensi lintas perangkat

### 5.1 Timeline retur vs void

| Waktu | Perangkat A | Perangkat B | Efek setelah sinkron |
|---|---|---|---|
| t1 | Nota qty 1 dibuat | Belum menerima | — |
| t2 | Retur qty 1: stok +1, refund | Masih melihat nota aktif | — |
| t3 | — | Void nota: stok +1, refund penuh | — |
| t4 | A menerima void | B menerima retur | A: void melihat retur lokal → restock 0; B: retur diterapkan pada nota VOID → stok +1 lagi; refund B ditambah refund A |

Hasil: stok bertambah dua kali untuk satu barang keluar, dan pelanggan menerima dua refund. Ini adalah **BL-02** (KRITIS, SUSPECTED karena memerlukan konkurensi offline).

### 5.2 Over-return lintas perangkat

Perangkat A dan B masing-masing membuat retur qty 1 untuk baris qty 1. Lokal keduanya lolos karena sisa lokal masih 1. Penerima tidak memeriksa total retur dari perangkat lain; keduanya diterapkan. Stok +2, refund +2. Status: **BL-02**.

### 5.3 Retur setelah void

Nota di-void di A; retur dibuat di B sebelum menerima void. Saat sinkron, B menerima void lalu retur (atau sebaliknya). `_upsertReturn` tidak menolak nota VOID; stok dan refund retur tetap diterapkan. Status: **BL-02**.

### 5.4 Refund void

Void lokal mengirim dua amplop. Bila keduanya diterima, kas konsisten. Bila amplop payment tertunda/gagal, penerima tetap VOID dengan `total_dibayar` lama. Status: **BL-15** (SUSPECTED, SEDANG).

---

## 6. Pembatalan estimasi dan revisi

`cancelEstimate` (`order_service.dart:900-937`):

- `actor` diterima tetapi **tidak dipakai**; tidak ada `Permissions.require` dan tidak ada pemeriksaan peran.
- Hanya menolak estimasi yang sudah menjadi nota atau bukan `aktif`.
- Siapa pun yang dapat memanggil service dapat membatalkan.

`createEstimate` revisi (`order_service.dart:315-340`):

- Membaca estimasi dasar tanpa memeriksa status (`aktif`/`batal`/`direvisi`/`dikonversi`).
- Menaikkan `versi = base.versi + 1`.
- Index `(nomor_estimasi, versi)` **tidak unik** (`schema.dart:800`).
- Dua perangkat dapat menghasilkan versi yang sama.

UI estimasi menampilkan tombol Batal/Revisi untuk semua peran selama status `aktif` (`estimates_screen.dart:747-757`), sehingga pembatasan tidak ada di lapisan UI maupun service. Status: **BL-12**.

---

## 7. Koreksi nilai nota (bukan pembatalan, tetapi terkait)

`NotaAdjustmentService` menyimpan koreksi append-only dan memanggil `recalculateRecordTotals`. Penerima `applyRemote` (`nota_adjustment_service.dart:286-329`) mengembalikan sukses tanpa error bila nota belum ada atau sudah VOID. Envelope dianggap selesai dan kursor maju; koreksi hilang permanen di perangkat itu. Status: **BL-30** (SUSPECTED, RENDAH).

Koreksi tidak mengubah `total_servis`; laporan menambahkan adjustment, sedangkan daftar/detail/struk tidak. Status: **BL-05**, **BL-18**.

---

## 8. Temuan area retur/pembatalan

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-02 | Retur/void lintas perangkat divergen | KRITIS | SUSPECTED |
| BL-09 | Otorisasi retur memakai izin `void` | SEDANG | CONFIRMED |
| BL-12 | Estimasi: batal tanpa otorisasi; revisi tanpa cek status/versi | SEDANG | CONFIRMED |
| BL-13 | Retur/pelunasan tanpa idempotensi/penjagaan ganda | SEDANG | SUSPECTED |
| BL-15 | Void tidak self-contained; refund bergantung amplop payment | SEDANG | SUSPECTED |
| BL-30 | Adjustment remote dibuang bila nota belum ada/void | RENDAH | SUSPECTED |
| BL-34 | Void tidak menyesuaikan komisi dan total_dibayar | RENDAH | CONFIRMED |
| BL-40 | Penerima retur tidak merekalkulasi komisi | RENDAH | CONFIRMED |

Detail lengkap di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 9. Skenario kegagalan yang dianalisis

| Skenario | Perilaku kode | Kesimpulan |
|---|---|---|
| Retur gagal di tengah | Seluruh retur dalam satu transaksi | Rollback; tidak ada stok/refund separuh |
| Void gagal di tengah | Seluruh void dalam satu transaksi | Rollback |
| Ketukan ganda tombol retur | Tidak ada busy guard; service tidak menerima request_id | BL-13 (SUSPECTED) |
| Retur setelah nota void (lokal) | Ditolak (`sale_return_service.dart:71-73`) | Terlindungi |
| Retur setelah nota void (remote) | Tidak diperiksa | BL-02 |
| Dua retur bersamaan lintas perangkat | Tidak ada batas total global | BL-02 |
| Void setelah retur (lokal) | Ditolak (`app_database.dart:2616-2627`) | Terlindungi |
| Void setelah retur (remote) | Restock dikurangi retur yang diketahui; retur belakangan tetap masuk | BL-02 |
| Refund tunai melebihi kas diterima | Dibatasi `refundable` (`sale_return_service.dart:214-219`) | Terlindungi |
| Aplikasi ditutup setelah retur lokal sebelum sync | Outbox tersimpan di transaksi yang sama | Retry saat sinkronisasi |
| Estimasi dibatalkan peran tanpa izin | `cancelEstimate` tidak memakai actor | BL-12 |
| Dua revisi estimasi bersamaan | Tidak ada unique index versi | BL-12 |

---

## 10. Batas audit

- Tidak ada pengujian runtime untuk urutan amplop; analisis urutan didasarkan pada kode apply dan outbox.
- Retur pembelian tidak ada, sehingga tidak dinilai.
- UI dialog retur diperiksa pada bagian pemanggilan service; validasi input per baris di dialog tidak diaudit menyeluruh.
- Relay tidak memiliki aturan retur khusus; yang diperiksa adalah aturan entitas nota dan izin.

**Kesimpulan area:** kontrol lokal retur/void cukup baik dan atomik. Risiko terbesar berada pada **penerimaan lintas perangkat**, karena status VOID tidak diperlakukan sebagai terminal state dan retur tidak dibatasi secara global. Ini adalah kombinasi yang dapat menyebabkan refund dan stok ganda (BL-02).
