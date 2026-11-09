# 05 — AUDIT PERHITUNGAN KEUANGAN

**Cakupan:** HPP, laba kotor, PPN, kas, piutang, utang, payroll, komisi, dan konsistensi laporan.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Konvensi Uang dan Pajak

| Item | Representasi |
|---|---|
| Uang | integer **sen** (`*_cents` di Dart, `*` rupiah di SQL) |
| Kuantitas | milli-unit (`jumlah_milli`) |
| PPN | basis poin (`pajak_persen_bp`, 1100 = 11%) |
| Mode PPN | `TANPA`, `EKSLUSIF`, `INKLUSIF` |
| Penanggung | `PEMBELI`, `BENGKEL` |
| Diskon | sen, dialokasikan per baris |

**Catatan penting:** schema.dart mendokumentasikan “uang dalam rupiah integer”, sedangkan model Dart memakai sen dan membagi 100 saat format. Selama konversi konsisten di semua jalur, tidak menjadi cacat; tetapi dokumentasi yang salah meningkatkan risiko kesalahan pada penambahan modul.

### 1.1 Formula PPN yang dipakai

```
bruto          = total harga baris setelah diskon baris
dpp            = mode == INKLUSIF ? bruto / (1 + tarif) : bruto
pajak          = dpp * tarif
total_ditagih  = mode == INKLUSIF ? bruto : bruto + pajak   (penanggung PEMBELI)
                 mode == INKLUSIF ? bruto : bruto             (penanggung BENGKEL)
```

**Titik rawan:** `total_ditagih` dan `dpp` adalah dua angka berbeda. Setiap laporan harus memilih salah satu secara eksplisit.

---

## 2. HPP dan Laba Kotor

### 2.1 Tiga angka HPP

| Sumber | Kolom | Dipakai oleh |
|---|---|---|
| Master barang | `stock_items.harga_modal` | Snapshot `service_parts.harga_modal` saat penjualan |
| Cost state | `stock_cost_state.hpp_rata_milli` | Pembelian berikutnya, nilai persediaan |
| Snapshot baris | `service_parts.harga_modal` | Laporan laba per nota |

### 2.2 FIN-02 — snapshot HPP memakai master

`createTransaction`:

```dart
part..modalCents = stock.hargaModalCents;
...
'harga_modal': part.modalCents,
```

Pembelian memperbarui cost state tetapi **tidak** master. Master Rp10.000, pembelian baru @Rp15.000 → penjualan berikutnya tetap mencatat HPP Rp10.000; laba kotor overstated Rp5.000/unit.

### 2.3 FIN-01 — cost state tidak turun

Penjualan, retur penjualan, void, opname, dan koreksi tidak mengurangi/menyesuaikan `stock_cost_state.qty_milli`. Rata-rata pembelian berikutnya memakai qty yang terlalu besar.

**Contoh.** Beli 100 @10.000; jual 80; beli 20 @20.000:
- state: (100×10.000 + 20×20.000)/120 = 11.667
- qty nyata: 40
- nilai persediaan dilaporkan 40 × 11.667 = 466.680, bukan nilai yang dapat direkonsiliasi.

### 2.4 FIN-07 — pembagian integer SQL

```sql
SUM(((sp.jumlah_milli - sp.qty_retur_milli) * sp.harga_final) / 1000)
```

SQLite membagi per baris sebelum SUM; pecahan sen hilang di setiap baris. Total laporan dapat berbeda beberapa rupiah dari total nota.

**Perbaikan.** Kalikan dulu, jumlahkan, baru bagi; atau `CAST(... AS REAL)` dengan pembulatan sekali di akhir.

---

## 3. Laporan dan Basis Angka

### 3.1 Matriks sumber laporan

| Laporan | Sumber | Termasuk retur? | Termasuk saldo awal? | PPN retur? |
|---|---|---|---|---|
| `reportSummary` omzet | `total_efektif + total_retur` | ya, sebagai pengurang | tidak | **tidak** |
| `reportSummary` DPP/PPN | `pajak_dpp`, `pajak` nota asli | **tidak** | tidak | **tidak** |
| `returCents` | item retur (DPP) | ya | tidak | tidak |
| `PajakReportService.rekap` | nota + retur dipisah | ya | tidak | ya |
| Dashboard piutang | `service_records.sisa_bayar` | ya | **tidak** | — |
| `purchaseTotals` | pembelian + utang awal | — | sebagian | — |
| Nilai persediaan | `stock_items` × HPP | — | ya (sebagian) | — |

### 3.2 FIN-03 — PPN/omzet kotor tanpa retur

`reportSummary` menjumlahkan `pajak_dpp`/`pajak` dari nota asli. Retur hanya mengurangi `returCents` (DPP), bukan DPP/PPN.

**Contoh.** Nota Rp1.110.000 diretur penuh:
- ringkasan: DPP 1.000.000, PPN 110.000, omzet neto 110.000;
- rekap PPN bulanan: kewajiban 0.

Dua laporan berbeda untuk transaksi yang sama. Owner dapat membayar PPN atas penjualan yang sudah diretur.

### 3.3 RET-02 — dua basis retur

`sale_returns.total` = nilai ditagih; `sale_return_items.subtotal` = DPP. Laporan yang mencampur keduanya menghasilkan omzet neto overstated sebesar PPN retur.

### 3.4 FIN-04 / PUR-03 — piutang awal tidak terlihat

Dashboard hanya membaca `service_records.sisa_bayar`; `opening_balance_items` jenis `PIUTANG_PELANGGAN` tidak dijumlahkan. Piutang awal Rp8.000.000 tidak tampil.

### 3.5 PUR-07 — utang campuran

`purchaseTotals` hanya menambahkan saldo awal ke `total_utang`, tidak ke `total_pembelian`/`total_dibayar`. Rasio pembayaran dan aging menjadi tidak sebanding.

---

## 4. Kas

### 4.1 Sumber kas

| Operasi | Tabel pembayaran | `cash_ledger` |
|---|---|---|
| Penjualan tunai | `service_payments` | ya |
| Pelunasan piutang | `service_payments` | ya |
| Refund penjualan | `service_payments` (REFUND) | ya |
| Pembelian | `supplier_payments` | ya |
| Refund pembelian | `supplier_purchase_returns` | ya (CASH) |
| Gaji | `salary_payments` | ya |
| PPN | `pajak_pembayaran` | ya |

`ux_cash_ledger_source(store_id, sumber_entity, sumber_sync_id)` mencegah duplikasi per sumber. Cacat muncul ketika **satu peristiwa** menghasilkan lebih dari satu baris kas dengan sumber berbeda (PUR-01) atau ketika insert memakai `ConflictAlgorithm.ignore` (FIN-06).

### 4.2 PUR-01 — kas fiktif

Refund kumulatif ditulis ulang per dokumen retur. Contoh dua retur: kas keluar 80.000 padahal seharusnya 50.000.

### 4.3 PUR-04 — metode refund

Refund pembelian selalu CASH; pembelian TRANSFER mencatat kas fisik masuk. Rekonsiliasi bank salah.

### 4.4 FIN-06 — pembayaran PPN remote

Jalur lokal membatasi `nominal <= sisaKewajiban`; jalur remote hanya memeriksa `masa` valid dan `nominal > 0`. `cash_sync_id` dari payload diterima apa adanya; insert kas memakai `ignore`, sehingga baris yang bentrok dibuang diam-diam.

**Contoh.** Perangkat A membayar Rp5.000.000 untuk masa dengan kewajiban Rp1.000.000. Remote menerima; kas keluar 5.000.000; kewajiban negatif tanpa carry-forward.

### 4.5 Kas awal

Tidak ada saldo kas awal di `opening_balances`; hanya STOK, UTANG_SUPPLIER, PIUTANG_PELANGGAN. Jika toko ingin memulai dengan saldo kas tertentu, tidak ada jalur resmi.

---

## 5. Piutang dan Utang

### 5.1 Penjualan kredit

Status dan `sisa_bayar` dihitung saat transaksi; pelunasan melalui `service_payments`. Tidak ada:
- limit piutang per pelanggan;
- jatuh tempo wajib (SAL-04);
- aging berbasis tanggal jatuh tempo.

### 5.2 Utang supplier

`sisa_utang` dihitung dari pembelian dan pembayaran. Masalah:
- PUR-01 menggelembungkan refund;
- PUR-05 meninggikan nilai retur;
- PUR-02 tidak ada pembayaran untuk utang awal;
- PUR-07 mencampur saldo awal.

### 5.3 Rekonsiliasi

Tidak ada laporan yang mencocokkan:
```
saldo awal kas + kas masuk - kas keluar = saldo akhir kas
```
`cash_ledger` dapat dijumlahkan, tetapi tanpa saldo awal kas, hasilnya hanya arus bersih, bukan saldo.

---

## 6. Payroll dan Komisi

### 6.1 Alur

`EmployeeService.payrollSummary` menghitung gaji/komisi; `paySalary` menulis `salary_payments` dan `cash_ledger`.

### 6.2 FIN-05 — tanpa aktor/izin

`paySalary` tidak menerima `Operator`, tidak memanggil `Permissions.require`, dan tidak mencatat aktor pembayar. `cash_ledger.operator` diisi **nama karyawan yang dibayar**, bukan pengguna yang menjalankan aksi.

**Dampak.** Siapa pun yang dapat memanggil service dapat membayar gaji; audit kas tidak menunjukkan penyetuju. `salary_payments` tanpa `created_by`.

### 6.3 Nominal vs kas

`salary_payments.nominal = grossCents`, `kas_keluar = netCents`. Potongan hutang dan cicilan mengurangi kas, tetapi laporan gaji memakai gross. Ini bisa benar sebagai biaya, tetapi harus konsisten dengan laporan kas; saat ini tidak ada pemisahan komponen biaya vs kas.

### 6.4 Komisi

`service_record_commissions` menyimpan snapshot mode/nilai dan `nominal`. Void nota menandai komisi VOID, tetapi retur sebagian tidak menghitung ulang komisi secara proporsional? `recalculateRecordTotals`/commission recalc dipanggil setelah retur; perlu verifikasi apakah komisi atas qty retur dikurangi. Jika tidak, komisi dibayar atas penjualan yang diretur. **Perlu validasi lanjutan** (tidak dimasukkan sebagai temuan terpisah karena belum terbukti dari potongan source yang dibaca).

---

## 7. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| FIN-01 | Cost state tidak dipelihara penjualan/retur/void | CRITICAL | CONFIRMED | `app_database.dart:1965-1995,3170-3200`; `sale_return_service.dart:300-312` |
| FIN-02 | HPP nota memakai modal master | HIGH | CONFIRMED | `app_database.dart:1674-1686` |
| FIN-03 | Laporan PPN/omzet memakai nilai kotor | HIGH | CONFIRMED | `app_database.dart:3511-3526,3597-3600,3654-3661` |
| FIN-04 | Piutang dashboard mengabaikan saldo awal | HIGH | CONFIRMED | `app_database.dart:3789-3800` |
| FIN-05 | Payroll tanpa aktor/izin; kas atas nama karyawan | HIGH | CONFIRMED | `employee_service.dart:283-370` |
| FIN-06 | Pembayaran PPN remote tidak dibatasi sisa | HIGH | CONFIRMED | `pajak_payment_service.dart:233-343,360-380` |
| FIN-07 | Pembagian integer SQL memotong pecahan | LOW | CONFIRMED | `app_database.dart:3546-3562`; `purchase_service.dart:969-987` |
| SAL-01 | PPN estimasi/konversi | CRITICAL | CONFIRMED | lihat 02 |
| RET-02 | Total retur campur basis | MEDIUM | CONFIRMED | lihat 03 |
| PUR-01 | Refund kumulatif | CRITICAL | CONFIRMED | lihat 03 |
| PUR-05 | Nilai retur bruto | HIGH | CONFIRMED | lihat 03 |

---

## 8. Contoh Perhitungan Lengkap

### 8.1 Nota dengan diskon dan PPN

Barang:
- Part A: 2 × Rp100.000 = Rp200.000
- Jasa B: Rp300.000
- Diskon nota: Rp50.000 dialokasikan proporsional
- PPN 11% EKSLUSIF, pembeli

```
bruto          = 500.000
diskon         = 50.000
dpp            = 450.000
ppn            = 49.500
total_ditagih  = 499.500
```

Yang disimpan:
- `service_parts.subtotal`/`service_jobs.subtotal` = nilai sebelum diskon baris
- `diskon_alokasi` per baris
- `service_records.diskon` = 50.000
- `pajak_dpp` = 450.000
- `pajak` = 49.500
- `total_servis`/`total_efektif` = 499.500

**Risiko:** jika laporan menjumlahkan `subtotal` baris tanpa mengurangi `diskon_alokasi`, omzet menjadi 500.000. Perlu memastikan semua laporan memakai `total_efektif`, bukan jumlah baris.

### 8.2 Retur sebagian

Nota di atas, retur Part A 1 unit (harga jual Rp100.000, diskon alokasi Rp10.000, DPP Rp90.000, PPN Rp9.900).

```
nilai retur ditagih = 99.900
DPP retur           = 90.000
PPN retur           = 9.900
```

- `sale_returns.total` = 99.900
- `sale_return_items.subtotal` = 90.000
- `reportSummary.returCents` = 90.000
- omzet neto = 499.500 - 90.000 = 409.500 (overstated 9.900)
- PPN yang benar = 49.500 - 9.900 = 39.600, tetapi ringkasan tetap 49.500.

### 8.3 Retur pembelian dengan diskon

Pembelian subtotal 150.000, diskon 50.000, ongkir 0, dibayar 100.000, qty 100 → `harga_pokok_satuan` 1.000.
Retur 50 unit:
- nilai benar = 50.000
- nilai saat ini = 50 × 1.500 = 75.000
- refund kumulatif = 75.000
- kas keluar = 75.000 (bukan 50.000)

---

## 9. Skenario Kegagalan

| Skenario | Efek keuangan |
|---|---|
| Double submit nota | `request_id` mencegah duplikasi; payload berbeda hilang (BIZ-01) |
| Double submit retur beli | Kas keluar berulang karena refund kumulatif (PUR-01) |
| Retur penjualan penuh | PPN tetap di ringkasan (FIN-03) |
| Opname hilang | Cost state tidak turun (INV-03) |
| Void nota | Cost state tidak naik (FIN-01) |
| PPN remote berlebih | Kas keluar melebihi kewajiban (FIN-06) |
| Payroll tanpa izin | Kas keluar tanpa aktor (FIN-05) |
| Restore backup lama | Skema tidak cocok, laporan error (DB-02) |

---

## 10. Pertanyaan Aturan Bisnis

1. Apakah PPN retur mengurangi kewajiban bulan berjalan atau harus dikompensasi bulan berikutnya?
2. Apakah kelebihan bayar PPN boleh carry-forward?
3. Apakah HPP memakai rata-rata bergerak, FIFO, atau harga terakhir?
4. Apakah komisi dihitung dari nilai sebelum atau sesudah retur?
5. Apakah gaji pokok, komisi, bonus, dan potongan harus dipisah di laporan?
6. Apakah saldo awal kas diperlukan?
7. Apakah piutang awal harus masuk aging dan dashboard?

---

## 11. Ringkasan

- Perhitungan uang memiliki fondasi integer yang baik, tetapi **basis angka tidak konsisten** antara nota, retur, ringkasan, dan rekap pajak.
- Tiga cacat CRITICAL/HIGH saling memperkuat: cost state tidak turun (FIN-01), HPP memakai master (FIN-02), dan PPN retur tidak mengurangi ringkasan (FIN-03).
- Kas memiliki unique source index, tetapi refund kumulatif dan metode hardcoded merusak rekonsiliasi.
- Perbaikan harus menyatukan sumber HPP, PPN, dan kas; bukan menambal masing-masing laporan.
