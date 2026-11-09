# 02 — AUDIT PENJUALAN DAN PEMBELIAN

**Cakupan:** alur nota penjualan, estimasi → konversi, order kerja, pembelian supplier, pembayaran utang, dan validasi harga.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** seluruh field wajib (bukti, alur sebab-akibat, skenario, dampak, rekomendasi) ada di `01_BUSINESS_LOGIC_DEFECTS.md`. Laporan ini menganalisis alur domain dan keterkaitannya.

---

## 1. Peta Alur Penjualan

### 1.1 Rantai pemanggilan

```
PosScreen (UI)
  ├─ validasi input & pilih pelanggan/unit          pos_screen.dart:395-480
  ├─ dialog jasa bebas / katalog                    pos_screen.dart:1600-1675
  ├─ _createWithApproval(...)                       pos_screen.dart:487-530
  │    └─ AppDatabase.createTransaction(...)        app_database.dart:1560-2010
  │         ├─ idempotensi request_id               app_database.dart:1574-1583
  │         ├─ validasi harga katalog               app_database.dart:1598-1626
  │         ├─ hitung PPN                           app_database.dart:1719-1723
  │         ├─ tulis service_records/jobs/parts     app_database.dart:1730-1860
  │         ├─ tulis pembayaran & kas               app_database.dart:1873-1960
  │         ├─ kurangi stok + movement              app_database.dart:1965-1995
  │         ├─ hitung komisi                        app_database.dart:1997-2010
  │         └─ enqueue outbox                       app_database.dart:2010
  ├─ recordDetail(id)                               app_database.dart
  └─ _showReceipt(detail)                           pos_screen.dart
```

### 1.2 Empat mode masuk yang memengaruhi aktor

| Mode | Aktor yang dikirim | Catatan |
|---|---|---|
| Gratis tanpa akun | `Operator.owner` sintetis | Tidak ada pemisahan kasir |
| Premium Google | Profil owner | Sesi bergantung `SessionService` |
| Login karyawan | `Operator` dari akun | Izin dari `role_base` + `extra_permissions` |
| Viewer ringkasan owner | `Operator` viewer | Service tidak selalu menolak viewer (SEC-07) |

### 1.3 Titik keputusan bisnis di jalur penjualan

1. **Jenis transaksi** (`servis_langsung`, `order_kerja`, `penjualan_part`) ditentukan UI/konversi; service menerima apa adanya.
2. **Harga final per baris** divalidasi hanya jika `jasaId != null`; jasa bebas tidak divalidasi terhadap master.
3. **Diskon** dialokasikan per baris dan disimpan sebagai snapshot; total nota dihitung ulang service.
4. **PPN** dihitung dari `bruto - diskon` memakai snapshot pengaturan toko saat transaksi.
5. **Kredit** ditentukan dari `sisa = total - dibayar`; tidak ada izin, jatuh tempo wajib, atau limit.
6. **Stok** dikurangi setelah nota ditulis, dalam transaksi database yang sama.
7. **Kas** ditulis dari pembayaran; `cash_ledger` menjadi sumber laporan kas.

---

## 2. Temuan Penjualan

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| SAL-01 | Konversi estimasi memakai total termasuk PPN sebagai diskon | CRITICAL | CONFIRMED | `order_service.dart:405-425,564`; `app_database.dart:1718-1736` |
| SAL-02 | Konversi estimasi selalu menjadi order kerja | HIGH | CONFIRMED | `order_service.dart:600` |
| SAL-03 | Jasa bebas melewati batas modal dan izin harga | HIGH | CONFIRMED | `pos_screen.dart:1620-1675`; `price_rules.dart:24-30,120-160`; `app_database.dart:1598-1626` |
| SAL-04 | Kredit tanpa izin, jatuh tempo wajib, atau limit | HIGH | CONFIRMED | `pos_screen.dart:729-733,1300-1312`; `app_database.dart:1733-1734,1873-1874` |
| SAL-05 | Konversi estimasi menghilangkan `jasaId` | HIGH | CONFIRMED | `order_service.dart:548-556` |
| SAL-06 | Harga jasa bebas dicatat sebagai harga terdaftar | MEDIUM | CONFIRMED | `app_database.dart:1626`; `models.dart:344-374` |
| SAL-07 | Merge pelanggan mengubah atribusi nota historis | HIGH | CONFIRMED | `app_database.dart:794-837,2905,2930` |
| SAL-08 | Tampilan rupiah membulatkan sen | LOW | CONFIRMED | `money.dart:38-42` |

### SAL-01 — PPN pada estimasi dan konversi

**Alur.** `OrderService.createEstimate` menyimpan `estimates.total = pajak.totalCents`, yaitu **nilai ditagihkan**. `convertEstimate` menghitung `diskon = (hargaTotal + partTotal) - estimate.totalCents`. `createTransaction` kemudian menghitung PPN dari `bruto - diskon`.

**Masalah.** Dua basis nilai dicampur:
- `hargaTotal + partTotal` = DPP (harga sebelum pajak).
- `estimate.totalCents` = DPP + PPN untuk mode EKSLUSIF/penanggung PEMBELI.

**Skenario.** Estimasi jasa Rp1.000.000, PPN 11%, EKSLUSIF/PEMBELI → `estimates.total = 1.110.000`. Konversi: `diskon = 1.000.000 - 1.110.000 = -110.000`. Validasi diskon negatif menolak konversi. Pada INKLUSIF, `total` sudah termasuk PPN; selisih diperlakukan sebagai diskon lalu PPN dihitung ulang dari basis yang lebih kecil.

**Dampak.** Alur estimasi ber-PPN tidak dapat dikonversi (EKSLUSIF) atau menghasilkan DPP/PPN lebih kecil (INKLUSIF). Rekap PPN bulanan memakai angka nota yang salah.

**Perbaikan yang disarankan.** Simpan `dpp`, `pajak`, `total_ditagihkan`, `mode`, `penanggung` pada header estimasi; konversi menyalin snapshot pajak, bukan mengubah pajak menjadi diskon.

### SAL-02 — Semua estimasi menjadi order kerja

`convertEstimate` tidak membaca `jenis_transaksi` asal dan selalu mengirim `transactionOrderKerja`. Estimasi “servis langsung” atau “penjualan part” berubah menjadi order kerja, memakai nomor `O`, masuk antrean, dan dilaporkan di kategori yang salah.

**Perbaikan.** Simpan jenis transaksi pada estimasi dan gunakan saat konversi; validasi terhadap `StoreSettings.typeEnabled`.

### SAL-03 — Jasa bebas tanpa katalog

`JobDraft` jasa bebas memakai `jasaId = null` dan `modalCents = 0`. `PriceRules.batasTotal = hargaModal * qty`, sehingga nol berarti tidak ada lantai harga. `createTransaction` hanya memvalidasi harga bila `jasaId != null`; harga nol hanya meminta konfirmasi dialog.

**Skenario.** Kasir membuat “Servis AC” tanpa tarif, mengisi Rp0 atau Rp10.000 padahal tarif normal Rp150.000. Nota tersimpan; laporan underprice tidak menandai karena `harga_jual_terdaftar` diisi dari harga input (lihat SAL-06).

**Dampak.** Penurunan harga tanpa otorisasi, margin hilang, owner tidak mendapat peringatan. `service_jobs.harga_batas_saat_transaksi = 0` membuat audit tidak dapat merekonstruksi batas yang seharusnya.

### SAL-04 — Kredit tanpa kontrol

Status kredit hanya dihitung dari `sisa = total - dibayar`. Tidak ada:
- izin `kredit`/`beri_kredit` di `permissions.dart` maupun `access_control.dart`;
- kewajiban `jatuh_tempo` saat sisa > 0;
- limit piutang per pelanggan;
- persetujuan owner di atas limit.

**Skenario.** Kasir mengosongkan nominal bayar dan tidak memilih jatuh tempo; nota Rp5.000.000 tersimpan sebagai KREDIT tanpa tanggal. Dashboard memasukkan seluruh `sisa_bayar` sebagai piutang. Aging tidak memiliki dasar tanggal.

### SAL-05 — `jasaId` hilang saat konversi

`JobDraft` pada konversi tidak meneruskan `jasa_id`/`jasa_sync_id`. Nota diperlakukan sebagai jasa bebas, sehingga validasi tarif dilewati dan laporan per jasa tidak dapat mengaitkan nota ke katalog. Jika tarif master berubah antara estimasi dan konversi, tidak ada peringatan.

### SAL-06 — Harga input dicatat sebagai harga terdaftar

`models.dart` mengisi `hargaTerdaftarCents = hargaCents` bila tidak diberikan, dan `createTransaction` mengisi `harga_jual_terdaftar` dari `job.hargaCents` untuk jasa bebas. Laporan `belowPriceSales` membandingkan `harga_final` dengan `harga_jual_terdaftar`; keduanya identik, sehingga pelanggaran harga tidak pernah terdeteksi.

**Perbaikan.** Pisahkan `harga_terdaftar` (dari katalog) dan `harga_input`; jasa bebas harus memiliki tarif referensi atau ditandai “tanpa tarif”.

### SAL-07 — Merge pelanggan mengubah histori

`mergeCustomers` memindahkan `service_records.customer_id` dan `vehicle_or_units.customer_id` ke pelanggan tujuan, lalu menaikkan HLC. Nota tidak menyimpan snapshot nama pelanggan; cetak dan laporan selalu join ke `customers.nama` saat ini.

**Skenario.** “Budi” dan “Budi Santoso” digabung. Semua nota lama berubah menampilkan “Budi Santoso”; nota yang sudah dicetak tidak lagi cocok. HLC yang dinaikkan mengalahkan versi perangkat lain saat sync.

**Dampak.** Riwayat pelanggan berubah retroaktif; sengketa garansi/piutang sulit dibuktikan; merge tidak dapat dibatalkan.

### SAL-08 — Pembulatan tampilan

`formatRupiah` memakai `decimalDigits: 0`. Database menyimpan sen, tetapi tampilan membulatkan. Tiga baris Rp33,33 ditampilkan Rp33; total Rp99,99 ditampilkan Rp100. Data benar; hanya presentasi yang tidak konsisten. Risiko LOW.

---

## 3. Alur Estimasi → Order Kerja

```
createEstimate
  ├─ hitung PPN dari total jasa+part          (total = DPP + PPN)
  ├─ simpan estimates.total                   ← nilai ditagihkan
  └─ simpan estimate_items                    ← harga per baris
convertEstimate
  ├─ baca estimate.totalCents
  ├─ diskon = (hargaTotal + partTotal) - totalCents   ← SAL-01
  ├─ JobDraft tanpa jasaId                            ← SAL-05
  ├─ createTransaction(jenisTransaksi: order_kerja)   ← SAL-02
  └─ update estimates.converted_nota_sync_id
```

**Titik konsistensi yang hilang:**
- Tidak ada pemeriksaan bahwa `diskon >= 0` dan `diskon <= harga sebelum pajak`.
- Tidak ada penyalinan `mode_saat_dibuat_json` ke nota; nota memakai pengaturan toko saat konversi, bukan saat estimasi disetujui.
- Tidak ada hubungan eksplisit estimasi → baris nota; hanya `converted_nota_sync_id` di header.

---

## 4. Peta Alur Pembelian

### 4.1 Rantai pemanggilan

```
PurchaseScreen
  ├─ createPurchase(...)                 purchase_service.dart:85-330
  │    ├─ cek fitur & izin               purchase_service.dart:97
  │    ├─ validasi item/qty/harga        purchase_service.dart:100-200
  │    ├─ tulis supplier_purchases/items
  │    ├─ _applyStockIn (stok + cost state)  purchase_service.dart:1700-1745
  │    └─ tulis pembayaran awal & kas
  ├─ addPayment(...)                     purchase_service.dart:320-410
  ├─ createReturn(...)                   purchase_service.dart:545-750
  │    ├─ tulis retur + item
  │    ├─ _recalculateTotals (kumulatif) purchase_service.dart:1897-1933
  │    └─ _writeCash(refund)             purchase_service.dart:712-731
  └─ voidPurchase(...)                   purchase_service.dart:410-545
```

### 4.2 Perbedaan perlakuan dengan penjualan

| Aspek | Penjualan | Pembelian |
|---|---|---|
| Feature flag di service | Tidak (kecuali pembelian) | Ya (`requireEnabled`) |
| Izin service | Sebagian (payroll tidak) | Sebagian (supplier tidak) |
| HPP | Master `stock_items.harga_modal` | Cost state diperbarui |
| Retur | Append-only, tanpa void | Status VOID diizinkan skema, tanpa UI |
| Kas | `service_payments` + `cash_ledger` | `supplier_payments` + `cash_ledger` |
| Idempotensi | `request_id` | `request_id` |

---

## 5. Temuan Pembelian

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| PUR-01 | Refund retur kumulatif dibukukan berulang | CRITICAL | CONFIRMED | `purchase_service.dart:712-731,1897-1923` |
| PUR-02 | Utang awal supplier tidak dapat dibayar | HIGH | CONFIRMED | `opening_balance_service.dart:154-186`; `purchase_service.dart:930-953` |
| PUR-03 | Piutang awal pelanggan tidak dapat ditagih | HIGH | CONFIRMED | `opening_balance_service.dart:187-215`; `app_database.dart:3798-3800` |
| PUR-04 | Refund retur selalu CASH | MEDIUM | CONFIRMED | `purchase_service.dart:720-731` |
| PUR-05 | Nilai retur memakai harga bruto | HIGH | CONFIRMED | `purchase_service.dart:622-642,712-731` |
| PUR-06 | `volumeQuery` tidak memfilter toko | HIGH | CONFIRMED | `purchase_service.dart:930-935,1005-1017` |
| PUR-07 | `purchaseTotals` mencampur utang dan saldo awal | MEDIUM | CONFIRMED | `purchase_service.dart:930-953` |

### PUR-01 — Refund kumulatif (CRITICAL)

`_recalculateTotals` menghitung:

```dart
final net = total - retur;
final refund = (paid - net) < 0 ? 0 : paid - net;
```

Nilai `refund` adalah **kumulatif seluruh retur**, bukan nilai dokumen retur saat ini. Nilai itu ditulis ke `supplier_purchase_returns.total_kas_kembali` dan ke `cash_ledger` dengan `sumber_sync_id = returnSyncId` yang unik per dokumen. `ux_cash_ledger_source` tidak menahan karena sumbernya berbeda.

**Contoh.** Pembelian Rp100.000 dibayar penuh.
- Retur 1 Rp30.000 → `net=70.000`, refund=30.000, kas keluar 30.000.
- Retur 2 Rp20.000 → `net=50.000`, refund kumulatif=50.000, kas keluar **50.000** lagi.
- Total kas keluar 80.000; seharusnya 50.000.

**Dampak.** Kas keluar fiktif; `total_kas_kembali` dokumen kedua salah; laporan arus kas membengkak; tidak dapat dikoreksi karena `cash_ledger` append-only.

**Perbaikan.** Hitung refund inkremental per dokumen, simpan `refund_terakumulasi` di header pembelian, tulis selisihnya saja, dan tambahkan idempotensi per dokumen retur.

### PUR-02 — Utang awal tidak dapat dibayar

`opening_balance_items` jenis `UTANG_SUPPLIER` hanya menyimpan nominal. Tidak ada ledger pembayaran atau konversi ke `supplier_purchases`. `addPayment` hanya menerima `purchaseId`; UI tidak memiliki dokumen untuk dipilih.

**Dampak.** Utang awal muncul di total tetapi tidak pernah lunas. Owner harus membuat pembelian fiktif untuk membayar, yang mencemari stok dan HPP.

### PUR-03 — Piutang awal tidak dapat ditagih

Sama seperti PUR-02, tetapi untuk `PIUTANG_PELANGGAN`. Dashboard hanya menjumlahkan `service_records.sisa_bayar`, sehingga piutang awal tidak terlihat. Tidak ada jalur penerimaan kas untuk saldo awal.

### PUR-04 — Refund selalu CASH

`_writeCash` memakai `metode: 'CASH'` hardcoded. Pembelian via TRANSFER yang diretur mencatat kas fisik masuk, padahal dana kembali ke bank. Rekonsiliasi kas/bank salah. Tidak ada pilihan metode refund.

### PUR-05 — Nilai retur memakai harga bruto

`supplier_purchase_returns.total` dihitung dari `harga_satuan` bruto, sedangkan pembelian dibayar berdasarkan `harga_pokok_satuan` setelah alokasi diskon/ongkir.

**Contoh.** 100 unit, subtotal Rp150.000, diskon Rp50.000, dibayar Rp100.000 (efektif Rp1.000/unit). Retur 50 unit dihitung 50 × Rp1.500 = Rp75.000; porsi yang benar-benar dibayar hanya Rp50.000 → lebih bayar Rp25.000.

**Dampak.** Uang keluar melebihi hak supplier; `total_kas_kembali`, `cash_ledger`, dan `sisa_utang` tidak konsisten.

### PUR-06 — `volumeQuery` lintas toko

`volumeQuery` tidak memiliki `WHERE store_id = ?`, dan `purchaseTotals` memanggilnya tanpa parameter. Di perangkat multi-toko, laporan pembelian Toko A menjumlahkan Toko A+B. Ini juga memengaruhi `total_utang` dan keputusan restock.

### PUR-07 — Pencampuran dua sumber utang

Hanya `total_utang` yang ditambahkan saldo awal; `total_pembelian`, `total_dibayar`, dan `jumlah_nota` tidak. Contoh: utang awal Rp10.000.000 + pembelian Rp5.000.000 dibayar Rp5.000.000 → total utang Rp10.000.000, total dibayar Rp5.000.000, total pembelian Rp5.000.000. Terlihat “utang lebih besar dari pembelian”.

**Perbaikan.** Pisahkan `utang_pembelian` dan `utang_awal`; tampilkan dua baris.

---

## 6. Logika yang Terduplikasi

| Logika | Lokasi | Risiko inkonsistensi |
|---|---|---|
| Perhitungan total nota | `createTransaction`, `recalculateRecordTotals`, `voidRecord` | Tiga jalur menghitung `total_efektif`/`total_retur` dengan filter status berbeda |
| Validasi harga | UI (`price_rules.dart`) dan service (`createTransaction`) | Jasa bebas hanya divalidasi UI; service melewatkan |
| PPN | `PajakSnapshot.hitung`, `PajakReportService.rekap`, `reportSummary` | Tiga basis: DPP, total ditagih, nilai retur |
| HPP | `service_parts.harga_modal`, `stock_cost_state.hpp_rata_milli`, `stock_items.harga_modal` | Tiga angka untuk barang yang sama |
| Refund retur | `_recalculateTotals` pembelian, `SaleReturnService` penjualan | Penjualan memakai clamp kas; pembelian memakai kumulatif |
| Pembayaran + kas | `service_payments`/`supplier_payments`, `cash_ledger`, `_writeCash` | Sumber kas dan status pembayaran dapat berbeda |
| Otorisasi | `Permissions.require`, `Operator.can`, cek manual UI | Tiga implementasi, viewer tidak konsisten |

**Konsekuensi.** Perbaikan pada satu jalur tidak otomatis memperbaiki jalur lain. Setiap temuan harus diperbaiki dengan satu sumber kebenaran (satu service mutasi, satu fungsi total, satu fungsi pajak).

---

## 7. Skenario Kegagalan Transaksi

### 7.1 Crash di tengah transaksi

`createTransaction` berjalan dalam satu transaksi database. Jika proses berhenti sebelum commit, SQLite rollback; tidak ada nota setengah jadi. Namun:
- `enqueue` outbox dilakukan di dalam transaksi yang sama; jika commit berhasil tetapi proses mati sebelum sync, outbox tetap ada dan aman.
- Pada restore/snapshot, penggantian file database tidak atomik terhadap scheduler (BAK-01), sehingga crash di tengah restore dapat meninggalkan database baru tanpa validasi penuh.

### 7.2 Double tap / retry

`request_id` mencegah duplikasi nota, tetapi:
- payload baru dengan `request_id` lama tidak diverifikasi (BIZ-01) → perubahan hilang diam-diam;
- UI menampilkan sukses meski transaksi lama yang dikembalikan (FLW-02);
- retur pembelian tidak memiliki idempotensi per dokumen selain `request_id`, dan refund kumulatif menambah baris kas baru (PUR-01).

### 7.3 Data tidak valid

- Harga jasa bebas nol/bawah modal diterima (SAL-03).
- Kredit tanpa jatuh tempo diterima (SAL-04).
- Qty retur dibatasi trigger, tetapi qty jual tidak dibatasi terhadap stok; stok dapat negatif karena tidak ada `CHECK (jumlah_milli >= 0)` pada `stock_items`.
- `stock_items.jumlah_milli` NULL pada baris lama dibaca 0 oleh pembelian (INV-05).

### 7.4 Database tidak tersedia

Startup tidak memiliki error handling (FLW-01); database rusak/versi lebih baru melempar `StateError` sebelum UI dirender. POS tidak dapat dibuka dan tidak ada layar pemulihan.

### 7.5 UI/DB desync

- `HomeShell` memakai `Operator.owner` saat state kosong (SEC-05), sehingga UI menampilkan menu owner meski sesi belum siap.
- Setelah simpan nota, kegagalan struk dilaporkan sebagai “Gagal menyimpan” (FLW-02).
- Setelah restore, UI tidak memuat ulang state toko/operator secara eksplisit; data lama dapat tetap tampil sampai refresh.

---

## 8. Dampak Lintas Modul

| Temuan | Merembet ke |
|---|---|
| SAL-01 | Rekap PPN, laporan omzet, `pajak_pembayaran` |
| SAL-03/SAL-06 | Laporan margin, komisi, audit harga |
| SAL-04 | Dashboard piutang, aging, kas |
| SAL-07 | Cetak nota, garansi, laporan pelanggan, sync HLC |
| PUR-01 | Kas, utang supplier, laporan arus kas, rekonsiliasi |
| PUR-02/PUR-03 | Dashboard, aging, laporan owner |
| PUR-05 | Nilai persediaan, HPP, kas |
| PUR-06 | Laporan multi-toko, keputusan restock |
| FIN-01/FIN-02 | HPP, laba kotor, nilai persediaan |

---

## 9. Pertanyaan Aturan Bisnis untuk Pemilik

1. Apakah estimasi menyimpan DPP atau nilai ditagih termasuk PPN? (SAL-01)
2. Apakah semua estimasi boleh dikonversi menjadi order kerja, atau jenis transaksi harus dipertahankan? (SAL-02)
3. Apakah jasa bebas diizinkan? Jika ya, siapa yang boleh menetapkan harga dan apakah harga nol boleh? (SAL-03)
4. Apakah kredit memerlukan izin, jatuh tempo wajib, dan limit per pelanggan? (SAL-04)
5. Apakah merge pelanggan boleh mengubah nota lama, atau hanya referensi ke depan? (SAL-07)
6. Apakah refund retur pembelian mengikuti metode pembayaran asal? (PUR-04)
7. Apakah nilai retur dihitung dari harga bruto atau harga pokok teralokasi? (PUR-05)
8. Apakah saldo awal utang/piutang harus dapat diselesaikan melalui aplikasi? (PUR-02/PUR-03)
9. Apakah pembelian boleh menurunkan stok menjadi negatif? (Tidak ada CHECK saat ini.)

---

## 10. Ringkasan

- Penjualan memiliki fondasi append-only dan snapshot harga yang baik, tetapi **validasi harga, kredit, dan PPN estimasi** belum konsisten antara UI dan service.
- Pembelian memiliki perhitungan HPP yang lebih maju (cost state), tetapi **retur pembelian adalah cacat kas paling berbahaya** karena refund kumulatif ditulis berulang.
- Saldo awal utang/piutang adalah **dokumen yatim**: muncul di ringkasan tetapi tidak memiliki jalur penyelesaian.
- Perbaikan harus dimulai dari satu sumber kebenaran untuk total, pajak, HPP, dan kas; bukan menambal UI per layar.
