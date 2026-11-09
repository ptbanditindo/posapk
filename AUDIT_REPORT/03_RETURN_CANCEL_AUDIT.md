# 03 — AUDIT RETUR DAN PEMBATALAN

**Cakupan:** retur penjualan, retur pembelian, void nota, void pembelian, koreksi nilai nota, dan jalur reversal.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md` untuk 12 field setiap temuan.

---

## 1. Prinsip Desain yang Sudah Ada

| Prinsip | Implementasi | Kekuatan |
|---|---|---|
| Append-only | `sale_returns`/`sale_return_items` immutable via trigger | Baris retur tidak dapat diubah diam-diam |
| Batas qty | `trg_sale_return_items_batas`, `trg_purchase_return_batas` | Mencegah retur melebihi qty terjual/dibeli |
| Refund sekali | `trg_sale_returns_refund_sekali` | Mencegah penulisan ulang `total_refund` |
| Void terminal | `trg_service_records_void_final`, `trg_purchase_void_final` | VOID tidak dapat diaktifkan kembali |
| Snapshot harga | `service_jobs`/`service_parts` immutable | Perubahan tarif master tidak mengubah nota lama |
| Koreksi terpisah | `nota_adjustments` | Koreksi nilai tidak menimpa komponen asal |

**Kesimpulan awal:** fondasi append-only kuat. Masalah utama bukan penghapusan data, melainkan **tidak adanya jalur reversal yang sah** dan **perhitungan nilai retur yang salah**.

---

## 2. Alur Retur Penjualan

### 2.1 Rantai pemanggilan

```
SaleReturnScreen
  └─ SaleReturnService.createReturn(...)        sale_return_service.dart:37-405
       ├─ validasi nota & qty                    sale_return_service.dart:75-145
       ├─ hitung DPP/PPN retur                   sale_return_service.dart:146-194
       ├─ tulis sale_returns
       ├─ tulis sale_return_items (subtotal)     sale_return_service.dart:241-259
       ├─ tulis stock_movements masuk            sale_return_service.dart:300-312
       ├─ tulis cash refund (clamp)              sale_return_service.dart:318-359
       ├─ recalculate totals nota                sale_return_service.dart:377-383
       └─ recalculate komisi                     sale_return_service.dart:383
```

### 2.2 Perhitungan pajak retur

```dart
final refundDitagihkan = penanggung == pajakPenanggungBengkel
    ? dppRetur
    : mode == pajakModeInklusif ? total : dppRetur + pajakRetur;
total = refundDitagihkan;
...
'subtotal': refund,
```

- `sale_returns.total` = **nilai ditagih** (termasuk PPN untuk penanggung PEMBELI).
- `sale_return_items.subtotal` = **refund per baris berbasis DPP**.
- `ReportSummary.returCents` menjumlahkan item (DPP), sedangkan `totalCents` menjumlahkan `total_efektif + total_retur` (termasuk PPN).

**Akibat:** nota Rp1.110.000 (DPP 1.000.000 + PPN 110.000) yang diretur penuh menghasilkan `total_retur = 1.110.000`, tetapi `returJasaCents/returPartCents = 1.000.000`. Pendapatan neto dihitung `1.110.000 - 1.000.000 = 110.000`, seolah masih ada pendapatan.

### 2.3 Refund kas

`SaleReturnService` menghitung refund kas dengan clamp terhadap pembayaran yang tersedia:

```dart
final refund = min(nilaiRefund, kasTersedia);
```

Ini mencegah kas keluar melebihi yang diterima, tetapi tidak menyelesaikan perbedaan basis DPP vs ditagih. Jika nota belum lunas, retur dapat menghasilkan **saldo piutang yang tidak wajar** karena nilai retur (ditagih) lebih besar dari pengurangan piutang berbasis DPP.

### 2.4 Stok

Retur menulis movement `MASUK` sebesar `jumlah_milli` dan menaikkan `stock_items`. **Tidak** memperbarui `stock_cost_state` (FIN-01), sehingga qty cost state tidak naik dan HPP rata-rata tidak kembali.

### 2.5 Tidak ada void/reversal

- `schema.dart:1028-1050` melarang perubahan `status`/`voided_at`.
- `SaleReturnService` tidak memiliki method void.
- Skema `sale_returns` mengizinkan `status = 'VOID'`, tetapi tidak ada jalur penulisan.
- Retur pembelian juga memiliki `status`/`voided_at`, tetapi tidak ada method void.

**Skenario.** Kasir salah memilih baris/qty; stok dan kas sudah berubah. Satu-satunya jalan adalah koreksi manual di luar aplikasi. Tidak ada dokumen “retur balik” yang append-only.

---

## 3. Alur Retur Pembelian

### 3.1 Rantai pemanggilan

```
PurchaseReturnScreen
  └─ PurchaseService.createReturn(...)          purchase_service.dart:545-750
       ├─ validasi qty terhadap sisa
       ├─ tulis supplier_purchase_returns
       ├─ tulis supplier_purchase_return_items
       ├─ _applyStockOut / movement KELUAR
       ├─ _recalculateTotals (kumulatif)        purchase_service.dart:1897-1933
       ├─ update total_kas_kembali
       └─ _writeCash(refund, metode CASH)       purchase_service.dart:712-731
```

### 3.2 Dua cacat berlapis

**Lapis 1 — nilai retur (PUR-05).** `total` retur memakai `harga_satuan` bruto, bukan `harga_pokok_satuan` setelah alokasi diskon/ongkir.

**Lapis 2 — refund kumulatif (PUR-01).** `_recalculateTotals` menghitung refund seluruh retur, lalu menulisnya sebagai kas baru untuk setiap dokumen retur.

Kombinasi keduanya memperbesar kerugian: basis nilai terlalu tinggi **dan** nilai kumulatif ditulis berulang.

### 3.3 Contoh lengkap

Pembelian 100 unit, subtotal Rp150.000, diskon Rp50.000, dibayar Rp100.000 (efektif Rp1.000/unit).

| Dokumen | Qty retur | Nilai retur (bruto Rp1.500) | Refund kumulatif (paid - net) | Kas ditulis |
|---|---:|---:|---:|---:|
| Retur 1 | 30 | Rp45.000 | Rp100.000 - (Rp100.000 - Rp45.000) = Rp45.000 | Rp45.000 |
| Retur 2 | 20 | Rp30.000 | Rp100.000 - (Rp100.000 - Rp75.000) = Rp75.000 | Rp75.000 |
| **Total** | | **Rp75.000** | | **Rp120.000** |

Nilai retur seharusnya berbasis Rp1.000/unit: 50 unit = Rp50.000. Kas keluar seharusnya Rp50.000, bukan Rp120.000. Selisih Rp70.000 adalah uang fiktif.

### 3.4 Metode refund

`_writeCash` memakai `metode: 'CASH'` hardcoded. Pembelian TRANSFER yang diretur mencatat kas fisik masuk; saldo bank tidak berubah. Laporan kas dan rekonsiliasi bank menjadi salah.

### 3.5 Void pembelian

`voidPurchase` mengembalikan stok, menulis movement, dan membalik kas/pembayaran. Namun:
- `supplier_purchase_returns` aktif tidak di-void otomatis; retur tetap dihitung.
- `stock_cost_state` pembelian dikembalikan? Void mengurangi stok, tetapi cost state tidak dihitung ulang secara eksplisit; perlu verifikasi implementasi (lihat `purchase_service.dart:410-545`).
- `total_kas_kembali` yang sudah ditulis tidak dikoreksi; kas append-only.

---

## 4. Pembatalan Nota Penjualan (Void)

### 4.1 Rantai

```
voidRecord(id, reason, actor)
  ├─ validasi status != VOID
  ├─ kembalikan stok (movement MASUK)
  ├─ refund kas bila ada pembayaran
  ├─ void komisi
  ├─ set status VOID, voided_at, void_reason, void_refund
  └─ update total_efektif/total_koreksi/total_retur
```

### 4.2 Kekuatan

- VOID bersifat terminal; trigger mencegah perubahan setelahnya.
- Stok dikembalikan dalam transaksi yang sama.
- Refund kas dibatasi `total_kas_diterima`.

### 4.3 Kekurangan

- **Cost state tidak dikembalikan** (FIN-01): stok naik, tetapi qty/HPP cost state tidak.
- **Retur aktif tidak otomatis dibatalkan**: nota VOID dengan retur AKTIF dapat meninggalkan qty retur yang tidak relevan; agregasi retur tidak memfilter status (RET-03), dan void nota tidak menandai retur.
- **Tidak ada void retur**; satu-satunya koreksi adalah void nota penuh, yang terlalu kasar.
- **Audit aktor** bergantung pada `Operator` yang dikirim UI; fallback owner (SEC-05) dapat mencatat aktor salah.

### 4.4 Urutan yang benar untuk pembatalan

1. Jika ada retur aktif, buat dokumen reversal retur terlebih dahulu (mengembalikan stok dan kas retur).
2. Baru void nota, dengan perhitungan kas dan stok berdasarkan kondisi setelah reversal.
3. Catat seluruh langkah dalam `business_audits` dengan aktor dan alasan.

Saat ini urutan itu tidak tersedia di UI maupun service.

---

## 5. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| RET-01 | Retur tidak memiliki jalur pembatalan/reversal | HIGH | CONFIRMED | `schema.dart:1028-1050`; `sale_return_service.dart:37-405`; `purchase_service.dart:545-745` |
| RET-02 | Total retur mencampur nilai ditagih dan DPP | MEDIUM | CONFIRMED | `sale_return_service.dart:146-194,241-259`; `app_database.dart:3608-3621` |
| RET-03 | Agregasi retur tidak memfilter status aktif | LOW | CONFIRMED | `app_database.dart:2495-2498,3608-3620` |
| PUR-01 | Refund retur pembelian kumulatif dibukukan berulang | CRITICAL | CONFIRMED | `purchase_service.dart:712-731,1897-1923` |
| PUR-04 | Refund retur pembelian selalu CASH | MEDIUM | CONFIRMED | `purchase_service.dart:720-731` |
| PUR-05 | Nilai retur memakai harga bruto | HIGH | CONFIRMED | `purchase_service.dart:622-642,712-731` |

### RET-01 — Tidak ada reversal

Detail di bagian 2.5. Dampak: kesalahan retur permanen; stok dan kas tidak dapat dikembalikan lewat UI; `sale_returns.status` selalu AKTIF.

### RET-02 — Dua basis nilai

Detail di bagian 2.2. Dampak: omzet neto dan laba kotor overstated sebesar PPN retur; laporan penjualan tidak cocok dengan rekap PPN.

### RET-03 — Filter status

`recalculateRecordTotals` dan `reportSummary` menjumlahkan `sale_returns` tanpa `status = 'AKTIF'`. Saat ini tidak ada jalur VOID, sehingga dampaknya laten. Jika reversal ditambahkan tanpa `deleted_at`, retur yang dibatalkan tetap mengurangi nilai nota.

**Perbaikan.** Tambahkan `AND status = 'AKTIF'` pada semua agregasi dan jadikan status satu-satunya sumber pembatalan.

### PUR-01/PUR-04/PUR-05

Detail di bagian 3. Ketiganya harus diperbaiki bersamaan; memperbaiki salah satu saja dapat mengubah arah kesalahan tanpa menghilangkan kerugian.

---

## 6. Matriks Efek Setiap Operasi

| Operasi | Stok | Cost state | Kas | Total nota | Piutang/utang | Audit |
|---|---|---|---|---|---|---|
| Retur jual | +qty | **tidak** | refund clamp | total_retur + | sisa_bayar turun? | tidak ada aktor eksplisit |
| Void nota | +qty | **tidak** | refund | total_efektif 0 | sisa_bayar 0 | reason + aktor UI |
| Retur beli | −qty | **tidak** | refund kumulatif | total_retur + | sisa_utang turun | dibuat_oleh string |
| Void beli | +qty | sebagian | balik pembayaran | status VOID | sisa_utang 0 | void_reason/voided_by |
| Koreksi nota | — | — | — | total_koreksi | sisa_bayar berubah | alasan/disetujui |

**Sel kosong “tidak” pada cost state adalah akar FIN-01.** Setiap operasi yang mengubah qty harus mengubah cost state atau cost state harus dihitung ulang dari ledger.

---

## 7. Skenario Kegagalan

### 7.1 Retur ganda (double submit)

`request_id` mencegah dokumen retur ganda. Namun refund pembelian tetap dapat berganda lewat dokumen retur berbeda (PUR-01). Pada retur penjualan, `trg_sale_return_items_batas` membatasi qty lintas retur, sehingga retur kedua dengan qty melebihi sisa akan gagal.

### 7.2 Retur saat nota sudah void

Tidak ada pemeriksaan eksplisit bahwa nota berstatus AKTIF sebelum retur? Validasi membaca nota; perlu memastikan `status` diperiksa. Jika tidak, retur dapat dibuat untuk nota VOID dan menambah stok/kas kembali. Ini perlu diverifikasi pada implementasi; saat ini tidak ada temuan terpisah karena belum terbukti dari source yang dibaca.

### 7.3 Crash setelah stok berubah

Seluruh operasi retur berada dalam satu transaksi database. Crash sebelum commit → rollback. Setelah commit, stok dan kas sudah berubah; tidak ada mekanisme kompensasi otomatis. Inilah alasan jalur reversal wajib ada.

### 7.4 Restore di tengah retur

Restore menutup database tanpa menghentikan sync/scheduler (BAK-01). Retur yang sedang berjalan dapat gagal; setelah reopen, status outbox dan movement dapat tidak konsisten.

### 7.5 DB unavailable

Retur gagal dengan error database; UI menampilkan error generik. Tidak ada retry aman selain menekan ulang, yang bergantung `request_id`.

---

## 8. Dampak Lintas Modul

| Temuan | Dampak |
|---|---|
| PUR-01 | Kas, utang supplier, laba, rekonsiliasi harian |
| PUR-05 | Nilai persediaan, HPP, margin |
| RET-02 | Omzet, PPN, laba kotor |
| RET-01 | Kemampuan koreksi operasional; kepercayaan pada histori |
| FIN-01 (terkait) | Nilai persediaan setelah retur/void |

---

## 9. Rekomendasi Desain Reversal

1. **Dokumen reversal append-only** (`sale_return_reversals`, `purchase_return_reversals`) yang merujuk retur asal.
2. Reversal menulis movement berlawanan, kas berlawanan, dan menandai `status = 'REVERSED'` pada retur asal melalui trigger yang mengizinkan satu transisi.
3. Otorisasi owner + alasan wajib + audit.
4. Agregasi hanya menjumlahkan retur `AKTIF` dan reversal `AKTIF`.
5. Larang void nota jika masih ada retur aktif; minta reversal terlebih dahulu.
6. Simpan `dpp`, `pajak`, `total_ditagihkan` pada header dan item retur.

---

## 10. Pertanyaan Aturan Bisnis

1. Apakah retur boleh dibatalkan? Jika ya, siapa yang berwenang dan apakah perlu persetujuan kedua?
2. Apakah refund retur pembelian mengikuti metode pembayaran asal atau pilihan pengguna?
3. Apakah nilai retur dihitung dari harga bruto atau harga pokok teralokasi?
4. Apakah retur penjualan mengembalikan PPN kepada pelanggan atau hanya mengurangi kewajiban?
5. Apakah nota yang sudah diretur sebagian boleh di-void seluruhnya?

---

## 11. Ringkasan

- Retur penjualan aman dari duplikasi qty, tetapi **tidak dapat dikoreksi** dan **mencampur basis DPP/ditagih**.
- Retur pembelian adalah **cacat kas kritis**: nilai bruto + refund kumulatif + metode CASH hardcoded.
- Void nota mengembalikan stok tetapi tidak cost state; void pembelian tidak membersihkan retur aktif.
- Perbaikan retur harus dilakukan sebagai satu paket: dokumen reversal, nilai inkremental, basis pajak eksplisit, dan pemeliharaan cost state.
