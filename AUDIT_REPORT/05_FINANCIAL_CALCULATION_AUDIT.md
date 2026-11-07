# 05 — Audit Perhitungan Keuangan

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, atau simulasi runtime yang dijalankan. Seluruh angka di laporan ini berasal dari rumus yang dibaca di kode, bukan dari hasil eksekusi.

**Berkas utama:** `pusatkupos/lib/data/app_database.dart` (`createTransaction`, `reportSummary`, `dashboard`, `recalculateRecordTotals`, `recalculateRecordCommissions`, `voidRecord`, `settleReceivable`), `pusatkupos/lib/data/price_rules.dart`, `pusatkupos/lib/data/models.dart` (`ReportSummary`), `pusatkupos/lib/data/employee_service.dart`, `pusatkupos/lib/data/receipt_service.dart`, `pusatkupos/lib/ui/screens/reports_screen.dart`, `pusatkupos/lib/ui/screens/dashboard_screen.dart`.

---

## 1. Ruang lingkup keuangan yang benar-benar ada

| Komponen | Status | Keterangan |
|---|---|---|
| Kas masuk dari penjualan | Ada | `service_payments` (DP/PELUNASAN) |
| Kas keluar refund | Ada | payment REFUND negatif (retur/void) |
| Pelunasan piutang | Ada | `settleReceivable` |
| Piutang | Ada | `service_records.sisa_bayar` |
| Komisi | Ada | `service_record_commissions` |
| Gaji | Ada | `salary_payments` |
| Hutang karyawan | Ada | `employee_debts` |
| Laba kotor | Ada | dari snapshot modal baris |
| Buku kas / saldo kas | **Tidak ada** | Tidak ada akun kas, saldo awal, atau ledger kas terpisah |
| Pengeluaran operasional | **Tidak ada** | Hanya gaji dan potongan hutang |
| Pembelian/utang supplier | **Tidak ada** | Tidak ada modul pembelian |
| Akuntansi double-entry | **Tidak ada** | Laporan bersifat laporan operasional, bukan neraca |

**Implikasi:** aplikasi tidak dapat menghasilkan saldo kas atau neraca. "Uang diterima neto" pada laporan adalah jumlah pembayaran pada rentang tanggal, bukan saldo kas. Setiap analisis saldo harus dilakukan di luar aplikasi. Ini adalah batas produk, bukan cacat implementasi yang dapat dibuktikan.

---

## 2. Rumus penjualan

### 2.1 Baris dan total

- Subtotal baris: `round(harga × qtyMilli / 1000)` (`price_rules.dart:39`).
- Bruto: jumlah subtotal seluruh baris (`130`).
- Diskon: dialokasikan proporsional, sisa pembulatan ke baris yang masih punya ruang (`162-189`).
- Total nota: `bruto − diskon teralokasi` (`225`).
- Total tersimpan: `service_records.total_servis` (`app_database.dart:1558`).
- Pembayaran: `dibayar = clamp(bayar, 0, total)`; `sisa = total − dibayar` (`1440-1445`).

**Penilaian:** aritmetika konsisten. Tidak ditemukan selisih pembulatan yang dapat dibuktikan sebagai salah hitung pada nota normal.

### 2.2 Modal (COGS)

- Part: `modalCents` diambil dari `stock_items.harga_modal` saat transaksi dan disimpan di `service_parts.harga_modal` serta `harga_batas_saat_transaksi` (`app_database.dart:1385-1399`, insert `1614-1636`).
- Jasa: `modalCents` diambil dari `harga_jasa.harga_modal` dan disimpan di `service_jobs.harga_batas_saat_transaksi` (`1314-1348`, insert `1592-1613`).
- Laporan memakai snapshot baris, bukan harga master saat ini (`2874-2896`). Ini implementasi yang benar: perubahan harga setelah transaksi tidak mengubah COGS historis.
- Retur: `retur_modal` dihitung dari `sale_return_items.modal_satuan` (`2937-2954`), dan `labaKotorNetCents` mengurangi laba dengan retur neto (`models.dart:535-536`).

**Penilaian:** COGS historis terjaga. Tidak ditemukan cacat pada perhitungan modal baris.

### 2.3 Laba kotor

- Part: `omzet part (subtotal − diskon) − modal part` (`app_database.dart:2933-2934`, `2974-2975`).
- Jasa: `omzet jasa (subtotal − diskon) − modal jasa` (`2935-2936`, `2976-2977`).
- Laba kotor neto setelah retur: `labaKotorCents − (returJasa + returPart − returModal)` (`models.dart:535-536`).
- Laba setelah komisi & gaji: `labaKotorNetCents − komisi − gaji` (`reports_screen.dart:284-292`).

**Catatan tampilan:** baris "Laba kotor part/jasa (setelah diskon)" ditampilkan **sebelum retur**, sedangkan "Penjualan neto" dan "Laba setelah komisi & gaji" memakai retur. Ini bukan salah hitung, tetapi pembaca harus memahami bahwa baris laba kotor per komponen tidak sebanding dengan baris neto. Tidak dijadikan temuan tersendiri karena labelnya tidak mengklaim neto.

---

## 3. Laporan periode (`reportSummary`)

### 3.1 Sumber angka

| Angka | Query | Dasar tanggal |
|---|---|---|
| Jasa, Part, Diskon, Total, Dibayar, Piutang | `service_records` | `waktu_service` |
| Total setelah koreksi | `SUM(total_servis) + adjustmentTotal` | `waktu_service` |
| Omzet/modal part | `service_parts` join nota | `waktu_service` |
| Omzet/modal jasa | `service_jobs` join nota | `waktu_service` |
| Uang diterima per metode | `service_payments` | `waktu` pembayaran |
| Komisi | `service_record_commissions` join nota | `waktu_service` |
| Gaji | `salary_payments` | `tanggal` |
| Retur | `sale_return_items` join retur | `created_at` retur |
| Per jenis transaksi | `service_records` | `waktu_service` |

UI menyatakan perbedaan dasar tanggal ini secara eksplisit (`reports_screen.dart:229-234`). Ini praktik yang baik.

### 3.2 Inkonsistensi total setelah koreksi

- `totalJasaCents`, `totalPartCents`, `diskonCents` berasal dari kolom asli nota (`2862-2865`).
- `totalCents` menambahkan adjustment (`2956-2971`).
- Baris "Rincian" menampilkan Jasa + Part − Diskon, lalu "Total" yang sudah ditambah adjustment (`reports_screen.dart:240-248`).

Bila adjustment ada, **Jasa + Part − Diskon ≠ Total**. Selisihnya tidak dijelaskan sebagai baris koreksi. Ini adalah **BL-05** (TINGGI, CONFIRMED).

### 3.3 Total vs struk vs daftar

- Daftar/detail riwayat memakai `total_servis` asli (`app_database.dart:2399-2470`).
- Struk memakai `record.totalCents` asli (`receipt_service.dart:274-313`).
- Laporan memakai total+adjustment.
- Dashboard memakai `summary.totalCents` (sudah adjustment) (`3125-3147`).

Tiga angka berbeda untuk nota yang sama. **BL-05**, **BL-18**.

### 3.4 Retur dan penjualan neto

- `returCents = returJasa + returPart`; `totalNetCents = totalCents − returCents` (`models.dart:529-531`).
- Retur dihitung berdasarkan tanggal retur, bukan tanggal nota; UI menyatakannya.
- Retur tidak mengubah `total_servis`; ia mengurangi neto dan sisa piutang lewat `recalculateRecordTotals` (`app_database.dart:2022`).

**Penilaian:** definisi neto konsisten untuk laporan, tetapi tidak dipakai seragam di struk/daftar (BL-05, BL-18).

### 3.5 Kas per metode

`cashByMethod` menjumlahkan `service_payments` pada rentang tanggal **tanpa** memfilter status nota (`2897-2905`). Payment REFUND negatif ikut mengurangi. Bila refund void tidak diterapkan di penerima (BL-15), angka kas antardevice berbeda.

Tidak ada saldo awal/akhir kas, sehingga tidak ada rekonsiliasi kas fisik. Ini batas produk.

---

## 4. Komisi

### 4.1 Saat nota dibuat

`_insertMechanicsAndCommissions` (`app_database.dart:1761-1815`):

- Basis jasa: total baris jasa setelah diskon (`job.lineTotalCents`, `1770`).
- Basis part: margin `(harga − modal) × qty/1000 − diskon_alokasi` (`1771-1777`).
- Tarif diambil dari baris `employee_accounts` mekanik yang dipilih (`1790-1793`).
- Mode `PERSEN`: `(shareJasa × jasaNilai)/100 + (shareMargin × barangNilai)/100` (`1796-1799`).
- Mode `NOMINAL`: nominal tetap per jenis (`1796-1799`).
- Pembagian antar mekanik memakai `_splitShare` dengan sisa ke indeks awal (`1817-1824`).
- Komisi hanya disimpan bila nominal > 0 (`1800-1812`).

### 4.2 Saat retur

`recalculateRecordCommissions` (`1828-1952`):

- Menghitung ulang dari baris nota, mengurangi porsi yang diretur (`1851-1905`).
- **Membaca tarif komisi saat ini** dari `employee_accounts` (`1912-1927`).
- Bila akun tidak ditemukan: mode `PERSEN`, nilai 0 → nominal 0 (`1919-1927`), lalu menimpa baris komisi (`1937-1947`).

**Cacat:** BL-04 (TINGGI, CONFIRMED) — tarif historis berubah; akun hilang membuat komisi 0. Tidak ada snapshot tarif pada baris komisi.

### 4.3 Saat void

`voidRecord` tidak menyentuh `service_record_commissions` (BL-34). Laporan komisi memfilter nota VOID (`2906-2913`), sehingga payroll tidak membayar komisi nota VOID, tetapi detail nota dan data komisi masih menampilkan nominal lama.

### 4.4 Saat penerimaan retur

Penerima retur tidak memanggil rekalkulasi komisi (BL-40). Bila amplop komisi dari perangkat asal tidak diterima, komisi penerima tetap penuh.

---

## 5. Gaji dan hutang karyawan

`paySalary` (`employee_service.dart:277-356`):

- `payrollSummary` menghitung komisi, gaji, bonus, hutang, dan potongan (`250-274`).
- Pembayaran ditolak bila siklus sudah ada **di database lokal** (`293-312`).
- Potongan hutang diterapkan lebih dulu (`314-319`), lalu `salary_payments` disimpan (`322-339`).
- Tabel memiliki `UNIQUE(employee_sync_id, cycle_start)` (`schema.dart:731`).
- Penerima sync mencocokkan `employee_sync_id + cycle_start` dan **memperbarui** baris yang ada (`sync_service.dart:3337-3386`).

**Cacat:** BL-03 (TINGGI, SUSPECTED) — dua perangkat dapat membayar siklus yang sama; saat sinkron satu pembayaran menimpa yang lain, sementara kas sudah keluar dua kali. Laporan gaji tidak dapat merekonsiliasi kas.

`payrollSummary` memakai `commission` dari nota dan `gaji` dari akun saat ini. Perubahan periode/gaji setelah nota dapat mengubah ringkasan siklus berjalan; ini perilaku yang perlu dikonfirmasi aturan bisnis (lihat 11).

---

## 6. Pelunasan piutang

`settleReceivable` (`app_database.dart:2767-2856`):

- Menolak nota VOID, nominal ≤ 0, metode tidak dikenal, dan nominal > sisa lokal (`2791-2819`).
- Idempoten bila `requestId` sama (`2796-2813`).
- Menulis payment dan menaikkan `total_dibayar`, menurunkan `sisa_bayar` secara langsung (`2820-2847`).
- Tidak merekalkulasi dari seluruh payment dan tidak memiliki kunci lintas perangkat.

**Cacat:** BL-14 (SEDANG, SUSPECTED) — dua perangkat dapat menerima pelunasan yang sama; `total_dibayar` dapat melebihi total efektif. UI membuat `request_id` baru setiap percobaan (`history_screen.dart:302-304`), sehingga ketukan ganda tidak terlindungi oleh idempotensi (BL-13).

---

## 7. Sinkronisasi angka keuangan

| Nilai | Sumber lokal | Perilaku penerima |
|---|---|---|
| `total_servis` | snapshot nota | tidak ditulis ulang untuk nota yang sudah ada (`note_sync.dart:444-447`) |
| `total_dibayar` | pembayaran | direkalkulasi setelah payment/retur (`note_sync.dart:409`, `510`, `524`) |
| `sisa_bayar` | pembayaran/retur | direkalkulasi, tetapi void hanya set 0 (`note_sync.dart:391`) |
| Komisi | perhitungan asal | diterima sebagai entitas, tidak direkalkulasi di retur (`BL-40`) |
| Gaji | pembayaran lokal | digabung per siklus, bukan konflik (`BL-03`) |
| Kas per metode | `service_payments` | payment diterapkan; refund void bergantung amplop terpisah (`BL-15`) |

---

## 8. Temuan area keuangan

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-03 | Gaji siklus sama dua perangkat saling menimpa | TINGGI | SUSPECTED |
| BL-04 | Komisi memakai tarif saat ini / akun hilang → 0 | TINGGI | CONFIRMED |
| BL-05 | Total terkoreksi tidak konsisten | TINGGI | CONFIRMED |
| BL-14 | Pelunasan lintas perangkat melebihi sisa | SEDANG | SUSPECTED |
| BL-15 | Refund void bergantung amplop payment terpisah | SEDANG | SUSPECTED |
| BL-18 | Struk memakai total asli | SEDANG | CONFIRMED |
| BL-19 | Dashboard "pendapatan" bruto | SEDANG | CONFIRMED |
| BL-23 | Rekonsiliasi hanya ID nota | SEDANG | CONFIRMED |
| BL-25 | Badge jatuh tempo memakai total asli | RENDAH | CONFIRMED |
| BL-34 | Void tidak menyesuaikan komisi/total_dibayar | RENDAH | CONFIRMED |
| BL-39 | Kembalian struk hanya pembayaran awal | RENDAH | CONFIRMED |

Detail lengkap di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 9. Skenario keuangan yang dianalisis

| Skenario | Perilaku | Kesimpulan |
|---|---|---|
| Nota normal | Total = bruto − diskon; dibayar di-clamp | Konsisten |
| Diskon non-pemilik melebihi margin | Ditolak | Terlindungi |
| Diskon pemilik di bawah modal | Diizinkan + audit | Sesuai desain |
| Retur sebagian | Total retur, refund dibatasi kas diterima, total direkalkulasi | Konsisten lokal |
| Retur setelah koreksi | Refund dihitung dari total terkoreksi | Konsisten lokal |
| Void nota tunai | Refund penuh, `sisa=0`, `total_dibayar` tidak direkalkulasi | BL-34 |
| Dua perangkat membayar gaji | Satu baris bertahan, kas keluar dua kali | BL-03 |
| Dua perangkat melunasi piutang | Dua payment dapat melebihi sisa | BL-14 |
| Retur mengubah komisi | Tarif saat ini dipakai | BL-04 |
| Akun mekanik hilang | Komisi menjadi 0 | BL-04 |
| Nota dikoreksi | Laporan menambah adjustment; daftar/struk tidak | BL-05, BL-18 |
| Retur di tanggal berbeda | Retur mengurangi periode retur, bukan periode nota | Sesuai disclosure UI |
| Gaji dibayar | Gaji mengurangi laba pada tanggal gaji | Sesuai desain |
| Kas fisik vs laporan | Tidak ada saldo kas | Batas produk |

---

## 10. Batas audit

- Tidak ada eksekusi laporan, sehingga tidak ada verifikasi angka runtime.
- Tidak ada modul buku kas/neraca; analisis saldo tidak dapat dilakukan.
- Pajak, diskon pajak, pembulatan pajak, dan laporan fiskal tidak ditemukan di kode yang dibaca.
- Laporan premium/owner summary di relay hanya diperiksa pada bagian yang terkait data aplikasi; perhitungan laporan server tidak diaudit mendalam.
- Tidak ada pembelian, sehingga tidak ada utang usaha atau harga pokok pembelian untuk diaudit.

**Kesimpulan area:** perhitungan nota dan COGS historis dirancang baik dan atomik. Masalah keuangan terbesar bukan pada aritmetika nota baru, melainkan pada **komisi historis** (BL-04), **konsistensi total setelah koreksi** (BL-05), **gaji lintas perangkat** (BL-03), dan **pelunasan lintas perangkat** (BL-14). Aplikasi tidak memiliki buku kas/saldo, sehingga laporan keuangan harus dipahami sebagai laporan operasional, bukan Neraca.
