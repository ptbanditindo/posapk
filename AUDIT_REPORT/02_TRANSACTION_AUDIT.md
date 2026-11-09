# 02 — TRANSACTION AUDIT

Ruang lingkup: pembuatan nota (jasa/part), qty, harga, negosiasi, diskon, pajak, biaya jasa, subtotal, grand total, pembayaran, kembalian, status, void, retur, riwayat, dan struk. Seluruh temuan memakai format wajib. Registry lengkap transaksi ada di [01_BUSINESS_LOGIC_DEFECTS.md](file:///C:/Users/Administrator/Downloads/posapk/AUDIT_REPORT/01_BUSINESS_LOGIC_DEFECTS.md); dokumen ini menambahkan bukti alur dan uji integritas.

---

## 1. Alur Nyata Transaksi (UI → Service → DB)

### 1.1 Entry dan state POS
- Layar: [pos_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart).
- State lokal menyimpan `_jobs`, `_parts`, `_diskonCents`, `_metode`, `_bayarCents`, `_requestId`.
- Simpan memanggil `_createWithApproval` → `AppDatabase.createTransaction`.

### 1.2 Validasi service
`createTransaction` ([app_database.dart:1793](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1793)) melakukan, berurutan:
1. Validasi jenis transaksi dan minimal part untuk `sparepartOnly`.
2. Validasi diskon/bayar tidak negatif, metode `CASH`/`TRANSFER`.
3. `StoreSettingsService.ensure` → cek `typeEnabled` dan `roleCanSelect`.
4. Izin diskon `Permissions.require(actor, permissionDiscount)` + `settings.roleAllows(role, 'diskon')`.
5. Validasi qty jasa > 0 dan harga jasa ≥ 0.
6. Perhitungan `isOwner`, `overrideApprover`, `allowBelowMinimum`, `hasDiscountReason`.
7. Verifikasi persetujuan diskon via `ApprovalService` (di luar transaksi DB, agar lockout tetap tercatat).
8. Bangun `requestHash` (SHA-256 canonical JSON) → idempotensi.
9. Buka `db.transaction`:
   - Cek `request_id` lama; hash sama → kembalikan id + enqueue ulang; hash beda → `request_payload_berbeda`.
   - Loop jasa: tolak harga nol tanpa izin+alasan; untuk katalog, harga wajib sama kecuali `hargaBebas == 1`; set modal & harga terdaftar.
   - Loop part: qty > 0, harga ≥ 0, harga master wajib sama; duplikat baris diakumulasi untuk kebutuhan stok.
   - `PriceRules.allocate` → harga final, diskon alokasi, batas modal.
   - Hitung pajak dari `bruto - diskon` → `PajakSnapshot.hitung`.
   - Validasi transfer tidak overpay; clamp `dibayar`; hitung kembalian/sisa/status.
   - Generate nomor nota dengan prefix S/N/O/P.
   - Insert `service_records`, job, part, pembayaran, `cash_ledger`, komisi, link work order/estimasi.
   - `StockLedger.apply` untuk setiap kebutuhan part (satu movement per part unik).
   - `enqueue` outbox nota dan komisi.

### 1.3 Atomisitas
Semua langkah 9 berada dalam satu `db.transaction`. Jika stok gagal (saldo negatif), seluruh nota dibatalkan. Ini **kontrol positif** dan memenuhi syarat "critical sale-flow atomicity".

### 1.4 Idempotensi
- Kunci: `request_id` unik pada `service_records` + `request_payload_hash`.
- Retry dengan payload identik mengembalikan id yang sama dan meng-enqueue ulang (aman untuk crash setelah commit sebelum enqueue).
- Retry dengan payload berbeda ditolak.
- Pembayaran dan cash ledger memakai request id turunan `'<requestId>-bayar'`.

**Celah:** UI POS mempertahankan satu `_requestId` per sesi nota; setelah sukses, id harus direset. Bila tidak, nota berikutnya dengan isi berbeda akan ditolak `request_payload_berbeda`. (Perilaku ini benar secara keamanan, tetapi UX harus memastikan reset — **NEEDS VALIDATION** untuk jalur UI.)

---

## 2. Perhitungan Harga dan Negosiasi

### 2.1 Jalur harga
| Kasus | Perilaku kode | Status |
|---|---|---|
| Jasa katalog, harga = master | Lolos, modal dari katalog | OK |
| Jasa katalog, harga ≠ master | Ditolak kecuali `hargaBebas == 1` | OK |
| Jasa bebas (non-katalog) | `hargaTerdaftar = 0`; izin dilewati; harga final = input kasir | **TRX-01** |
| Jasa harga 0 | Ditolak tanpa `alasanDiskon`; UI tidak pernah mengirim | **TRX-07** |
| Part, harga ≠ master | Ditolak | Membatasi nego (**TRX-05**) |
| Diskon nota | Dialokasikan proporsional; sisa pembagian didistribusikan | OK secara aritmetika |
| Harga di bawah minimum | Butuh `allowBelowMinimum`; PIN tidak mengaktifkannya | **TRX-08** |

### 2.2 Batas modal
`PriceRules.allocate` memeriksa margin per baris terhadap `hargaModal`. Namun modal part diambil dari `stock_items.harga_modal`, sedangkan HPP nyata memakai rata-rata bergerak ledger. Ini menyebabkan dua definisi modal (**TRX-06**).

### 2.3 Snapshot harga
- `service_record_items`/`service_record_parts` menyimpan harga terdaftar, harga final, diskon alokasi, dan batas saat transaksi.
- Trigger migrasi v4/v5 mencegah update snapshot pada nota aktif.
- Sync payload mengekspor `harga_final`, `diskon_alokasi`, `harga_batas_saat_transaksi` ([note_sync.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart)).
- **Kesimpulan:** harga final bertahan di DB lokal, payload sync, dan DB penerima. Masalahnya ada di **kontrol harga** dan **hilangnya harga acuan** (bukan penyimpanan harga final).

---

## 3. Pajak

`PajakSnapshot.hitung` ([pajak.dart:156](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/pajak.dart#L156)):
- Nonaktif → `dppCents = base`, `pajakCents = 0`, `totalCents = base`.
- Eksklusif → `pajak = roundHalfUp(base × bp / 10000)`; total = DPP + PPN (kecuali bengkel menanggung).
- Inklusif → `DPP = roundHalfUp(base × 10000 / (10000 + bp))`; PPN = base − DPP.
- Bengkel menanggung → pembeli membayar DPP.

Temuan terkait:
- **REP-03:** `dppCents` tetap diisi saat pajak nonaktif, sehingga rekap PPN headline ikut menjumlahkan nota `TANPA`. Lihat [04](file:///C:/Users/Administrator/Downloads/posapk/AUDIT_REPORT/04_DATABASE_INTEGRITY_AUDIT.md) dan [13](file:///C:/Users/Administrator/Downloads/posapk/AUDIT_REPORT/13_REAL_WORLD_SCENARIO_AUDIT.md).
- **TRX-12:** penyesuaian nota tidak memisahkan DPP/PPN penyesuaian.
- Pajak tidak dihitung ulang saat retur lokal; retur memakai proporsi DPP (lihat bagian 6).

---

## 4. Pembayaran, Kembalian, dan Status

| Elemen | Perilaku |
|---|---|
| Tunai | `dibayar = min(bayar, total)`; `kembalian = bayar - total` |
| Transfer | `bayar > total` ditolak |
| Total 0 | `dibayar = 0` |
| Sisa | `total - dibayar`; status `LUNAS`/`SEBAGIAN`/`BELUM` |
| Jatuh tempo | Hanya disimpan bila sisa > 0 |
| Piutang | `settleReceivable` idempoten per request id |
| Cash ledger | Append-only, request id turunan |

Temuan:
- **TRX-03:** struk mencetak bayar ter-clamp tetapi kembalian dari nilai mentah.
- **TRX-04:** tombol bayar penuh membulatkan nominal transfer.
- **FLW-04:** status piutang di beberapa layar memakai cakupan berbeda (lihat 08).

---

## 5. Void

`voidRecord` ([app_database.dart:3630](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3630)):
- Menolak bila ada retur `AKTIF` (lokal).
- Idempoten bila sudah `VOID`.
- Restock sebesar `qty - qty_retur_milli` untuk setiap part.
- Refund satu kali dengan request id `void-<syncId>`.
- Set status `VOID`, nolkan total, void komisi.

**Kontrol positif:** tidak ada double refund lokal; retur aktif memblokir void.

**Defect:** kebijakan ini hanya berlaku lokal. Jalur sync menerima void dari perangkat lain meskipun sudah ada retur, mencatat konflik, tetapi **tetap menerapkan void dan refund penuh** → **INV-03 (CRITICAL)**.

---

## 6. Retur Penjualan

`SaleReturnService.createReturn` + `_upsertReturn`:
- Validasi nota tidak void.
- Kumulatif qty retur ≤ qty terjual (trigger).
- Restock per item dengan kunci idempoten `retur-<returnSync>-<itemSync>`.
- Refund dicatat di `sale_returns` dan pembayaran.
- Retur dibatalkan (`_applyReturnVoidRemote`) mengurangi `qty_retur`, menarik restock dengan kunci `retur-void-...`; jalur remote membatasi qty, jalur lokal tidak (**INV-07**).

**Temuan kritis:** void setelah retur (INV-03) dan perbedaan biaya retur vs HPP (INV-05).

---

## 7. Struk

`ReceiptService`:
- `items()` mencetak `hargaTerdaftar` per baris, ditambah baris diskon bila `showLineDiscount` aktif. Pada jasa bebas, `hargaTerdaftar` baris = harga yang diketik (bukan harga acuan), sehingga struk menampilkan harga final secara langsung (TRX-02).
- `totals()` mencetak bayar ter-clamp dan kembalian dari kas mentah (TRX-03).
- Print tidak menulis DB → aman dari duplikasi.
- Kegagalan print hanya snackbar; nota tetap tersimpan ([pos_screen.dart:543](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L543)).

---

## 8. Riwayat Nota

`listRecords` ([app_database.dart:3397](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3397)):
- Rentang default 2000–2100.
- Pencarian `LIKE %term%` pada `no_nota` atau nama pelanggan.
- Urut `waktu_service DESC`; `LIMIT/OFFSET`.
- UI riwayat memanggil `limit: 200` tanpa paginasi dan tanpa filter tanggal ([history_screen.dart:53](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart#L53)).
- Nota `VOID` tetap tampil dengan total 0 tanpa badge status (REP-07).

**Kesimpulan:** transaksi lama tidak dihapus oleh kode, tetapi sulit ditemukan karena batas 200 dan tidak ada paginasi/tanggal. Lihat 05 dan 13 (SC-03/SC-04).

---

## 9. Matriks Uji Transaksi

| Uji | Hasil | Bukti |
|---|---|---|
| Nota + item + stok + bayar atomik | PASS | Satu `db.transaction` |
| Retry nota tidak ganda | PASS | `request_id` + hash |
| Payload retry berbeda ditolak | PASS | `request_payload_berbeda` |
| Nomor nota unik | PASS | Unique index/constraint |
| Harga final nego tersimpan | PASS | Kolom snapshot |
| Harga acuan nego tersimpan | **FAIL** | `PriceLine.hargaTerdaftar` diisi harga input (TRX-02) |
| Harga final tampil di struk | PASS untuk harga final; **PARTIAL** untuk bukti diskon | TRX-02 |
| Harga final dipakai di laporan margin | PASS untuk penjualan; **FAIL** untuk retur/koreksi | REP-01/02 |
| Izin harga manual | **FAIL** | TRX-01 |
| Persetujuan PIN harga bawah minimum | **FAIL** | TRX-08 |
| Jasa gratis | **FAIL** | TRX-07 |
| Void tanpa double refund (lokal) | PASS | Idempoten + blokir retur |
| Void lintas perangkat setelah retur | **FAIL** | INV-03 |
| Retur ≤ qty terjual | PASS | Trigger + validasi |
| Pembayaran transfer tanpa overpay | PASS di service; **FAIL** di UI bayar penuh | TRX-04 |
| Struk aritmetika konsisten | **FAIL** | TRX-03 |
| Printer gagal tidak menggandakan nota | PASS | Print read-only |

---

## 10. Lampiran — Temuan Pelaporan (REP)

### REP-01 — Baris retur memakai DPP, Total/Neto memakai nilai ditagih
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [reports_screen.dart:269](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/reports_screen.dart#L269), [models.dart:611](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/models.dart#L611), [app_database.dart:4106](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4106)
- **Fungsi/Kelas:** `ReportSummary`; query `reportSummary`
- **Implementasi:** `returJasaCents`/`returPartCents` memakai DPP, sedangkan `totalCents`/`totalNetCents` memakai nilai ditagih termasuk PPN. Baris "Retur" dan "Penjualan neto" tidak berada pada basis yang sama.
- **Penyebab:** Dua basis nilai dalam satu ringkasan.
- **Dampak:** Laporan tidak dapat direkonsiliasi dengan nota; omzet/laba setelah retur salah.
- **Skenario:** Semua nota ber-PPN dengan retur.
- **Rekomendasi:** Tampilkan DPP dan PPN terpisah; gunakan basis yang sama untuk omzet dan retur; tambahkan kolom "retur ditagih".
- **Dependensi:** INV-05.

### REP-02 — Koreksi nota mengubah omzet tetapi tidak HPP/laba/PPN
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:4012](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4012), [app_database.dart:4031](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4031)
- **Fungsi/Kelas:** `reportSummary`
- **Implementasi:** `total_koreksi` memengaruhi total/omzet, tetapi HPP dan laba dihitung dari baris nota asli; PPN tidak menyesuaikan koreksi.
- **Dampak:** Margin dan kewajiban PPN salah setelah koreksi.
- **Skenario:** Koreksi nilai nota.
- **Rekomendasi:** Simpan DPP/PPN koreksi; sesuaikan HPP/laba secara proporsional atau minta keputusan bisnis.
- **Dependensi:** TRX-12, REP-03.

### REP-03 — Rekap DPP headline menjumlahkan nota `TANPA` PPN; detail mengecualikannya
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [pajak.dart:161](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/pajak.dart#L161), [app_database.dart:2358](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L2358), [pajak_report_service.dart:158](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/pajak_report_service.dart#L158)
- **Fungsi/Kelas:** `PajakSnapshot.hitung`; `PajakReportService.rekap`
- **Implementasi:** Saat pajak nonaktif, `dppCents = base` tetap disimpan. Query rekap menjumlahkan `pajak_dpp` semua nota non-VOID tanpa filter `pajak_mode`; rincian memfilter `pajak_mode <> 'TANPA'`.
- **Dampak:** DPP dilaporkan terlalu besar; rekap tidak cocok dengan rincian/nota.
- **Skenario:** Penggunaan campuran nota ber-PPN dan non-PPN.
- **Rekomendasi:** Isi DPP 0 saat pajak nonaktif atau filter `pajak_mode` di semua agregasi; samakan definisi headline dan detail.
- **Dependensi:** TRX-11.

### REP-04 — Klarifikasi nilai di laporan memakai clamp nol, rekap pajak memakai nilai negatif
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:4156](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4156), [pajak_report_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/pajak_report_service.dart)
- **Implementasi:** Laporan membatasi total pada 0, rekap pajak dapat menerima nilai negatif dari retur/koreksi berlebih.
- **Dampak:** Dua laporan menunjukkan angka berbeda untuk transaksi yang sama.
- **Rekomendasi:** Tetapkan kebijakan clamp yang sama dan tampilkan komponen negatif secara eksplisit.
- **Dependensi:** REP-01, REP-03.

### REP-05 — `marginReport` membandingkan tanggal lokal dengan `waktu_service` UTC
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [purchase_service.dart:1170](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/purchase_service.dart#L1170)
- **Fungsi/Kelas:** `marginReport`
- **Implementasi:** `date(r.waktu_service) BETWEEN ? AND ?` memakai string tanggal lokal, sedangkan `waktu_service` disimpan UTC. Transaksi WIB 00:00–06:59 (UTC hari sebelumnya) masuk ke hari sebelumnya.
- **Dampak:** Margin harian/bulanan salah untuk transaksi pagi.
- **Skenario:** Laporan margin tanggal.
- **Rekomendasi:** Konversi zona waktu di query atau simpan tanggal lokal eksplisit; uji batas hari.
- **Dependensi:** REP-08.

### REP-06 — Cakupan piutang/kas berbeda antar layar
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:4009](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4009), [history_screen.dart:53](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart#L53)
- **Implementasi:** Laporan memasukkan piutang awal/opening dan kas dari `cash_ledger`; daftar piutang memakai `sisa_bayar` nota.
- **Dampak:** Total piutang/kas berbeda antar layar.
- **Rekomendasi:** Satu query/definisi bersama.
- **Dependensi:** FLW-04.

### REP-07 — Nota VOID tampil sebagai Rp 0 tanpa badge
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [history_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart), [app_database.dart:3397](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3397)
- **Implementasi:** Nota VOID tetap ditampilkan dengan total 0; status tidak selalu terlihat jelas.
- **Dampak:** Pengguna mengira ada transaksi Rp 0; total header vs baris tampak tidak cocok.
- **Rekomendasi:** Badge VOID + alasan/waktu + filter.
- **Dependensi:** —

### REP-08 — Selisih pembulatan 1–2 sen pada agregasi
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:4009](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4009), [purchase_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/purchase_service.dart)
- **Implementasi:** Campuran pembagian REAL/ROUND dan integer truncation.
- **Dampak:** Selisih kecil antar laporan.
- **Rekomendasi:** Standarkan aritmetika integer.
- **Dependensi:** DB-04.

### REP-09 — Ekspor ringkasan owner tidak memuat data keuangan lengkap
- **Severity:** LOW
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [reports_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/reports_screen.dart)
- **Implementasi:** Ekspor ringkasan tidak memuat seluruh komponen finansial (HPP, PPN, retur, kas per metode).
- **Dampak:** Pemilik tidak mendapat laporan lengkap untuk akuntansi.
- **Rekomendasi:** Tambahkan kolom/ekspor lengkap.
- **Dependensi:** REP-01/02/03.

---

## 11. Rekomendasi Urutan Perbaikan Transaksi

1. Perbaiki kontrak approval (TRX-08) dan kirim `alasanDiskon` (TRX-07) — membuka jalur harga nol secara aman.
2. Perbaiki sumber harga terdaftar jasa manual + audit izin (TRX-01).
3. Simpan serta tampilkan harga acuan dan harga final (TRX-02); perbaiki uang diterima/kembalian (TRX-03).
4. Hilangkan pembulatan nilai transaksi (TRX-04).
5. Satukan definisi modal/HPP (TRX-06), lalu selaraskan laporan (REP-01/02).
6. Tambahkan negosiasi per item (TRX-05) sebagai fitur, bukan tambalan.
