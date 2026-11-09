# 04 — AUDIT PERSEDIAAN

**Cakupan:** saldo stok, ledger pergerakan, opname, koreksi, saldo awal, HPP rata-rata bergerak, dan konsistensi antar-sumber kuantitas.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Model Persediaan Saat Ini

### 1.1 Tiga representasi kuantitas/nilai

| Representasi | Tabel/kolom | Peran |
|---|---|---|
| Saldo tampilan | `stock_items.jumlah`, `stock_items.jumlah_milli` | Dibaca UI dan sebagian service |
| Ledger | `stock_movements` | Riwayat perubahan, `stok_sebelum/sesudah` |
| Nilai HPP | `stock_cost_state.qty_milli`, `hpp_rata_milli` | Rata-rata bergerak untuk pembelian berikutnya |
| HPP master | `stock_items.harga_modal` | Dipakai penjualan sebagai snapshot HPP |

**Masalah struktural:** keempatnya tidak selalu diperbarui bersama. Tidak ada satu fungsi mutasi yang menjadi pintu masuk semua perubahan stok.

### 1.2 Sumber perubahan stok

| Operasi | `stock_items` | `stock_movements` | `stock_cost_state` | `harga_modal` master |
|---|---|---|---|---|
| Buat/edit barang | ya | KOREKSI | tidak | ya (manual) |
| Pembelian | ya | MASUK | ya | **tidak** |
| Retur pembelian | ya | KELUAR | ya (via `_applyStockIn`? perlu verifikasi) | tidak |
| Penjualan | ya | KELUAR | **tidak** | tidak |
| Retur penjualan | ya | MASUK | **tidak** | tidak |
| Void nota | ya | MASUK | **tidak** | tidak |
| Opname | ya | KOREKSI | **tidak** | tidak |
| Saldo awal stok | ya | MASUK | ya | tidak |
| Void saldo awal | ya | KELUAR | **tidak** | tidak |

Sel “tidak” pada cost state adalah akar **FIN-01**; sel “tidak” pada master modal adalah akar **FIN-02**.

---

## 2. Alur Opname

### 2.1 Rantai

```
OpnameScreen
  └─ AppDatabase.applyOpnameTx(...)             app_database.dart:1235-1300
       ├─ baca before.jumlahMilli
       ├─ delta = jumlahFisikMilli - before.jumlahMilli
       ├─ update stock_items.jumlah_milli = jumlahFisikMilli
       ├─ insert stock_movements(KOREKSI)
       └─ (tidak ada update stock_cost_state)
```

### 2.2 Sifat absolut

Opname menyimpan **nilai absolut** (`opname_absolut_milli`). Saat diterapkan di perangkat lain dengan HLC lebih baru, nilai itu menggantikan saldo terkini, bukan merekonsiliasi selisih.

**Skenario.** Pukul 10:00 perangkat A menghitung fisik 10 unit. Pukul 10:05 perangkat B menjual 2 unit (saldo 8). Pukul 10:10 opname A diterapkan dengan HLC lebih baru → saldo menjadi 10, seolah penjualan 2 unit tidak terjadi.

**Dampak.** Stok fisik dan sistem berbeda; kehilangan/penjualan tidak terdeteksi; movement opname mencatat `stok_sesudah = 10`, menghapus jejak penjualan dari saldo (movement penjualan tetap ada tetapi ledger tidak lagi konsisten).

**Perbaikan.** Terapkan opname sebagai delta terhadap saldo saat ini, atau sertakan saldo basis dan tolak/rekonsiliasi bila saldo berubah sejak hitung fisik. Simpan `saldo_saat_hitung` dan `waktu_hitung` pada hold.

### 2.3 Opname tidak memperbarui cost state

Setelah opname menemukan 5 unit hilang dari 100, `stock_items` menjadi 95, tetapi `stock_cost_state.qty_milli` tetap 100. Nilai persediaan dihitung dari qty lama; rata-rata pembelian berikutnya memakai basis yang salah.

### 2.4 Opname tertunda

Tabel `opname_holds` menyimpan status `TERTUNDA/SEMENTARA/DITERAPKAN/BATAL`. `opname_holds` **tidak termasuk** `snapshotTables` (DB-01), sehingga perangkat baru tidak menerima opname tertunda. Movement ditulis sebelum keputusan `applyQuantity` (DB-09), sehingga movement dapat “mengklaim” perubahan yang tidak pernah diterapkan.

---

## 3. Koreksi Stok

### 3.1 Jalur

`saveStockItem` menulis movement `KOREKSI` dengan:

```dart
'sumber_entity': 'stock_item',
'sumber_sync_id': stockSyncId,
'jenis': 'KOREKSI',
```

Unique index:

```sql
CREATE UNIQUE INDEX ux_stock_movement_source
ON stock_movements(store_id, sumber_entity, sumber_sync_id, jenis)
WHERE sumber_sync_id <> '';
```

### 3.2 Cacat INV-01

Setiap edit stok dengan delta ≠ 0 menulis kombinasi `(stock_item, stockSyncId, KOREKSI)` yang sama. Edit kedua melanggar unique index; seluruh transaksi edit di-rollback.

**Skenario.** Barang dibuat stok 10. Edit pertama menurunkan ke 8 → movement KOREKSI. Edit kedua menaikkan ke 9 → `UNIQUE constraint failed`; pengguna melihat error dan stok tidak berubah.

**Perbaikan.** Gunakan `sync_id` unik per koreksi (mis. `newSyncId()`), bukan ID barang. Simpan ID barang pada `stock_sync_id` seperti sekarang.

### 3.3 Tidak ada cost state

Koreksi stok juga tidak memperbarui cost state; selisih qty tidak tercermin pada HPP. Jika koreksi menambah stok tanpa nilai, HPP rata-rata bisa turun secara tidak wajar.

---

## 4. Saldo Awal Stok

### 4.1 Posting

`OpeningBalanceService` menyimpan baris `STOK` dengan `nominal = 0` dan `jumlah_milli`. Nilai per unit diambil dari `stock_items.harga_modal` saat posting (`_stockIn`).

### 4.2 Cacat INV-06 (NEEDS VALIDATION)

Tidak ada kolom modal per baris pada `opening_balance_items`. Owner tidak dapat mencatat 20 unit dengan modal awal Rp50.000/unit bila master berisi Rp40.000. Nilai saldo awal mengikuti master; tidak ada jejak nilai historis.

**Status NEEDS VALIDATION** karena aturan bisnisnya tidak dinyatakan di source: apakah modal saldo awal wajib sama dengan master, atau boleh berbeda.

### 4.3 Void saldo awal

`voidActive` mengurangi `stock_items` dan menulis movement KELUAR, tetapi **tidak** memperbarui cost state. Saldo awal 100 unit dibatalkan → stok 0, cost state tetap 100; nilai persediaan tidak kembali nol.

### 4.4 Satu saldo awal aktif

`ux_opening_aktif` memastikan hanya satu `opening_balances` AKTIF per toko. Ini baik, tetapi tidak ada mekanisme “tutup buku” yang mengaitkan saldo awal dengan periode.

---

## 5. HPP Rata-Rata Bergerak

### 5.1 Pembelian

`PurchaseService._applyStockIn`:

1. menghitung `harga_pokok_satuan` setelah alokasi diskon/ongkir;
2. menambah `stock_items.jumlah_milli`;
3. memanggil `_updateCostState` untuk menambah qty dan menghitung rata-rata baru;
4. **tidak** memperbarui `stock_items.harga_modal`.

### 5.2 Penjualan

`createTransaction` mengambil `stock.hargaModalCents` (master) sebagai `modalCents`, bukan `stock_cost_state.hpp_rata_milli`. Ini adalah **FIN-02**: HPP snapshot tidak mencerminkan rata-rata sebenarnya.

### 5.3 Akar FIN-01

Karena penjualan tidak mengurangi `stock_cost_state.qty_milli`:

- Beli 100 @Rp10.000 → state qty 100, HPP 10.000.
- Jual 80 → state tetap 100.
- Beli 20 @Rp20.000 → rata-rata = (100×10.000 + 20×20.000)/120 = Rp11.667.
- Qty nyata 40; nilai persediaan = 40 × 11.667 = Rp466.680, bukan angka yang dapat direkonsiliasi.

Selisih `stock_cost_state.qty_milli` vs `stock_items.jumlah_milli` tumbuh terus dan tidak dapat dikoreksi tanpa rebuild.

### 5.4 Rebuild

Tidak ada fungsi rebuild cost state dari `stock_movements`. Satu-satunya jalan adalah menghitung ulang manual atau membuat database baru. Untuk desain bersih, cost state sebaiknya **diturunkan** dari ledger atau dihapus sebagai tabel state.

---

## 6. Dua Kolom Kuantitas

`stock_items` memiliki `jumlah` (integer) dan `jumlah_milli` (nullable). Beberapa jalur membaca:

- `COALESCE(jumlah_milli, jumlah * 1000)` (sync);
- `jumlah_milli ?? 0` (pembelian `_applyStockIn`);
- `jumlah_milli` langsung (penjualan).

**Skenario.** Baris lama `jumlah=50`, `jumlah_milli=NULL`. Pembelian 10 unit membaca `before=0`, menulis `jumlah_milli=10`; stok fisik 60 menjadi 10.

**Perbaikan.** Backfill `jumlah_milli` dari `jumlah*1000`, jadikan `NOT NULL`, hapus `jumlah`, atau sentralkan semua pembacaan pada satu ekspresi.

---

## 7. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| INV-01 | Koreksi stok kedua melanggar unique index movement | HIGH | CONFIRMED | `app_database.dart:1081-1093`; `schema.dart:947-950` |
| INV-02 | Opname absolut tertunda menimpa penjualan | HIGH | CONFIRMED | `app_database.dart:1235-1300`; `sync_service.dart:3483-3535` |
| INV-03 | Opname tidak memperbarui cost state | MEDIUM | CONFIRMED | `app_database.dart:1235-1300` |
| INV-04 | Void saldo awal tidak memperbarui cost state | MEDIUM | CONFIRMED | `opening_balance_service.dart:236-310` |
| INV-05 | Dua kolom kuantitas dengan fallback tidak konsisten | MEDIUM | CONFIRMED | `schema.dart:274-300`; `purchase_service.dart:1700-1712`; `sync_service.dart:3790-3795` |
| INV-06 | Saldo awal stok tidak menyimpan modal per baris | MEDIUM | NEEDS VALIDATION | `opening_balance_service.dart:131-158,659-686`; `schema.dart:1967-1994` |
| FIN-01 | Cost state tidak dipelihara penjualan/retur/void | CRITICAL | CONFIRMED | `app_database.dart:1965-1995`; `sale_return_service.dart:300-312`; `app_database.dart:3170-3200` |
| FIN-02 | HPP nota memakai modal master | HIGH | CONFIRMED | `app_database.dart:1674-1686`; `purchase_service.dart:1700-1714` |
| DB-09 | Movement ditulis sebelum keputusan opname absolut | MEDIUM | CONFIRMED | `sync_service.dart:3495-3535` |

---

## 8. Skenario Kegagalan

### 8.1 Penjualan bersamaan

Dua kasir menjual barang yang sama secara bersamaan. `createTransaction` membaca stok lalu menulis `nextMilli` dalam transaksi. SQLite menyerialkan penulisan, tetapi nilai `nextMilli` dihitung dari bacaan sebelum lock; jika kedua transaksi membaca saldo yang sama, salah satu dapat menimpa hasil yang lain (lost update). Tidak ada `UPDATE ... WHERE jumlah_milli >= qty` yang atomik.

**Dampak.** Stok dapat menjadi negatif atau tidak sesuai penjualan. Perlu verifikasi runtime, tetapi secara statis tidak ada guard optimistik.

### 8.2 Opname saat penjualan berjalan

Opname absolut dan penjualan dapat saling menimpa; lihat INV-02.

### 8.3 Database penuh / I/O error

Transaksi stok rollback; UI menampilkan error generic. Tidak ada retry otomatis atau indikator “stok belum tersimpan”.

### 8.4 Sync gagal di tengah

Movement ditulis sebelum keputusan `applyQuantity` (DB-09); ledger dapat berisi perubahan yang tidak pernah diterapkan. Antrean sync dapat macet pada konflik yang sama (DB-07).

---

## 9. Dampak Lintas Modul

| Temuan | Dampak |
|---|---|
| FIN-01/INV-03/INV-04 | Nilai persediaan, HPP, laba kotor, margin per barang |
| FIN-02 | HPP nota, laporan laba per nota |
| INV-01 | Operasi koreksi stok berhenti setelah edit pertama |
| INV-02 | Stok fisik vs sistem, restock, audit kehilangan |
| INV-05 | Kehilangan saldo lama saat pembelian pertama |
| DB-09 | Ledger tidak dapat dijadikan bukti |

---

## 10. Prinsip Desain yang Disarankan

1. **Satu pintu mutasi stok:** semua operasi (jual, beli, retur, void, opname, koreksi, saldo awal) memanggil `StockLedger.apply(delta, ...)`.
2. **Ledger sebagai sumber kebenaran:** `stock_movements` menyimpan qty dan nilai (HPP) per pergerakan; saldo diturunkan atau dijaga oleh trigger.
3. **Hapus `stock_cost_state`** atau jadikan cache yang selalu dapat direbuild dari ledger.
4. **Satu kolom kuantitas** (`jumlah_milli`), `NOT NULL`, dengan `jumlah` hanya view.
5. **Opname berbasis delta** dengan `saldo_basis` dan konflik eksplisit.
6. **Koreksi memakai `sync_id` unik per dokumen**, bukan ID barang.
7. **HPP snapshot penjualan** diambil dari ledger saat transaksi, bukan master.

---

## 11. Pertanyaan Aturan Bisnis

1. Apakah modal saldo awal boleh berbeda dari master? (INV-06)
2. Apakah stok boleh negatif? Saat ini tidak ada `CHECK` pada `stock_items`.
3. Apakah opname harus menimpa penjualan yang terjadi setelah hitung fisik, atau menghasilkan konflik?
4. Apakah koreksi stok memerlukan persetujuan owner dan alasan wajib?
5. Apakah HPP memakai rata-rata bergerak, FIFO, atau harga terakhir?

---

## 12. Ringkasan

- Persediaan memiliki ledger yang baik, tetapi **tiga sumber kebenaran** (saldo, cost state, master modal) tidak dipelihara bersama.
- Opname absolut dan koreksi stok memiliki cacat yang mencegah operasi normal.
- Dua kolom kuantitas meninggalkan risiko kehilangan saldo lama.
- Perbaikan harus dimulai dari satu service mutasi dan satu sumber HPP; menambal penjualan saja tidak cukup.
