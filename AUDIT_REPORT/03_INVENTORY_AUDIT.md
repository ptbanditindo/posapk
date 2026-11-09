# 03 — INVENTORY AUDIT

Ruang lingkup: pengurangan stok saat penjualan, pembelian, retur penjualan/pembelian, void, koreksi, opname, stok minimum, stok awal, stok per barang/toko, kondisi offline, sync, riwayat pergerakan, double decrement, stok negatif, atomisitas, dan konsistensi ledger vs saldo.

---

## 1. Model Stok Nyata

- Saldo: `stock_items.jumlah_milli` (satuan 1/1000).
- Riwayat: `stock_movements` (append-only) dengan kolom saldo sebelum/sesudah, sumber entity/sync id, HLC.
- Penulis tunggal: `StockLedger.apply` ([stock_ledger.dart:88](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L88)).
- Idempotensi: `movementSyncId` unik; unique index `(store_id, sumber_entity, sumber_sync_id, jenis)`.
- Saldo negatif: ditolak di lokal (`delta < 0 && before + delta < 0`), diizinkan di jalur sync dengan `allowNegative: true` + pencatatan konflik `stok_negatif`.
- HPP: rata-rata bergerak di `_applyValuation` ([stock_ledger.dart:324](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L324)).

**Kontrol positif:** semua mutasi stok dalam transaksi DB yang sama dengan dokumen sumber; kunci idempoten mencegah double decrement pada retry.

**Keterbatasan:** `rebuild` tidak pernah dipanggil; tidak ada rekonsiliasi saldo vs jumlah movement; movement keluar menyimpan `harga_pokok_satuan_cents = 0`.

---

## 2. Registry Temuan Inventori

### INV-01 — Opname dengan basis basi gagal permanen dan memacetkan antrean
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [opname_service.dart:222](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/opname_service.dart#L222), [app_database.dart:1647](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1647), [sync_service.dart:2567](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2567)
- **Fungsi/Kelas:** `OpnameService.processPending`; `AppDatabase.applyOpnameTx`; `_syncNowBody`
- **Implementasi:** Hold opname menyimpan `opname_absolut_milli` + `opname_basis_milli`. Saat semua device sync, `applyOpnameTx` menghitung `delta = absolut - basis` lalu memanggil `StockLedger.apply` tanpa `allowNegative`. Bila saldo sudah berubah (mis. penjualan setelah opname), delta negatif dapat melebihi saldo → exception. `processPending` dipanggil setelah ack di `_syncNowBody` tanpa penanganan kegagalan; hold tidak pernah selesai dan antrean berikutnya dapat terus gagal.
- **Penyebab:** Basis absolut dipakai terhadap saldo yang bergerak; kegagalan tidak diisolasi per hold.
- **Dampak:** Opname tidak pernah diterapkan; outbox/hold menumpuk; pengguna melihat sync "berhasil" tetapi stok tidak terkoreksi.
- **Skenario:** SC-02, operasi opname multi-device.
- **Rekomendasi:** Terapkan opname sebagai koreksi absolut (bukan delta terhadap basis) pada titik commit, atau hitung ulang delta terhadap saldo terkini; bungkus per hold dengan status gagal + retry terpisah; jangan blokir ack berikutnya.
- **Dependensi:** INV-11.

### INV-02 — Restock void dari sync mengurangi retur tanpa filter status aktif
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [note_sync.dart:460](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L460), [note_sync.dart:474](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L474)
- **Fungsi/Kelas:** `applyNotePayloadTx` jalur void
- **Implementasi:** Subquery qty retur menjumlahkan baris retur tanpa `sr.status = 'AKTIF'`; restock dihitung `qty - returned`. Retur yang sudah dibatalkan tetap mengurangi qty yang dikembalikan.
- **Penyebab:** Filter status hilang pada subquery.
- **Dampak:** Stok tidak kembali penuh saat void; saldo menyimpang dari fisik.
- **Skenario:** SC-02, void setelah retur dibatalkan.
- **Rekomendasi:** Tambahkan filter status retur aktif dan `deleted_at IS NULL`; tambah uji regresi.
- **Dependensi:** INV-03.

### INV-03 — Void setelah retur: lokal menolak, sync menerapkan dan refund penuh (double refund)
- **Severity:** **CRITICAL**
- **Kategori:** CONFIRMED DEFECT / DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:3656](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3656), [note_sync.dart:412](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L412), [note_sync.dart:511](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L511)
- **Fungsi/Kelas:** `voidRecord`; `applyNotePayloadTx`
- **Implementasi:** Lokal menolak void bila ada retur aktif. Jalur sync hanya mencatat konflik `void_setelah_retur`, lalu **tetap** merestocking sisa qty, meng-upsert pembayaran refund void, dan menetapkan status VOID/nol total. Retur yang sudah direfund tidak dibatalkan.
- **Penyebab:** Dua kebijakan berbeda; konflik dicatat tetapi tidak menghentikan aplikasi.
- **Dampak:** Pelanggan menerima refund retur + refund void; nilai nota nol sementara uang sudah keluar dua kali. Integritas keuangan rusak dan sulit direkonsiliasi.
- **Skenario:** SC-02, multi-device.
- **Rekomendasi:** Pilih satu kebijakan: (a) tolak void remote bila ada retur aktif dan minta penyelesaian, atau (b) batalkan retur secara eksplisit sebelum void. Refund void hanya sebesar sisa yang belum direfund.
- **Dependensi:** INV-02, INV-07.

### INV-04 — Pemulihan stok negatif menggelembungkan HPP rata-rata
- **Severity:** HIGH
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi dengan contoh aritmetika
- **Lokasi:** [stock_ledger.dart:324](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L324)
- **Fungsi/Kelas:** `StockLedger._applyValuation`
- **Implementasi:** `value = before <= 0 ? 0 : before × avg / 1000`; delta positif menambah `delta × usedUnitCost`; `avg = (value × 1000 + after/2) / after`. Saat saldo negatif (mis. −5), nilai dianggap 0. Masuk +10 @1.000 → value 10.000, after 5 → avg 2.000, bukan 1.000.
- **Penyebab:** Unit cost hanya dipakai untuk delta positif dan nilai sebelum negatif dibuang, tetapi kuantitas sesudahnya lebih kecil dari delta.
- **Dampak:** HPP dan laba salah setelah koreksi stok negatif; harga jual bisa di bawah HPP palsu.
- **Skenario:** SC-02, koreksi stok negatif.
- **Rekomendasi:** Definisikan valuasi saat saldo negatif (mis. gunakan unit cost masuk untuk seluruh delta, atau reset avg ke unit cost masuk ketika before ≤ 0 dan after > 0).
- **Dependensi:** INV-08, TRX-06.

### INV-05 — Biaya retur memakai harga master, bukan HPP penjualan
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [sale_return_service.dart:683](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/sale_return_service.dart#L683), [app_database.dart:4041](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4041)
- **Fungsi/Kelas:** `SaleReturnService`; `AppDatabase.reportSummary`
- **Implementasi:** Retur mengembalikan stok dengan nilai modal dari master/HPP saat ini; laporan mengurangi omzet/laba memakai angka yang dapat berbeda dari HPP baris nota asli.
- **Penyebab:** Retur tidak membaca snapshot modal baris nota.
- **Dampak:** Laba bersih setelah retur salah bila HPP berubah.
- **Skenario:** Semua retur.
- **Rekomendasi:** Gunakan snapshot `harga_modal` baris nota dan alokasi proporsional; simpan modal retur.
- **Dependensi:** REP-01, REP-02.

### INV-06 — Nota masuk menciptakan saldo tanpa movement masuk
- **Severity:** MEDIUM
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [note_sync.dart:1106](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L1106), [note_sync.dart:1116](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L1116)
- **Fungsi/Kelas:** `applyNotePayloadTx` jalur nota baru
- **Implementasi:** Bila stock item belum ada, dibuat dengan `jumlah_milli = postSale + qtyMilli`, lalu diterapkan movement KELUAR `-qtyMilli`. Tidak ada movement MASUK untuk saldo awal tersebut.
- **Penyebab:** Saldo awal disuntikkan langsung ke kolom, bukan lewat ledger.
- **Dampak:** Jumlah movement tidak sama dengan saldo; audit stok tidak dapat direkonstruksi; HPP rata-rata tidak mencerminkan biaya masuk.
- **Skenario:** SC-02, device menerima nota untuk barang yang belum ada.
- **Rekomendasi:** Buat movement MASUK eksplisit (sumber `nota_masuk` atau `stok_awal`) sebelum KELUAR, atau set saldo 0 lalu terapkan KELUAR dengan `allowNegative` dan koreksi terpisah.
- **Dependensi:** INV-08, INV-10.

### INV-07 — Pembatalan retur lokal tidak membatasi qty saat stok sudah terjual lagi
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [sale_return_service.dart:526](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/sale_return_service.dart#L526), [note_sync.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart) jalur `_applyReturnVoidRemote`
- **Fungsi/Kelas:** `SaleReturnService`; `_applyReturnVoidRemote`
- **Implementasi:** Jalur remote membatasi qty yang ditarik kembali; jalur lokal tidak. Jika stok hasil retur sudah terjual, penarikan dapat membuat saldo negatif/gagal atau meninggalkan selisih.
- **Penyebab:** Implementasi berbeda antar jalur.
- **Dampak:** Pembatalan retur gagal atau stok menjadi tidak konsisten.
- **Rekomendasi:** Satukan fungsi pembatalan dengan clamp dan konflik eksplisit.
- **Dependensi:** INV-03.

### INV-08 — Nilai keluar ledger 0 dan `rebuild` tidak pernah dipakai
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [stock_ledger.dart:88](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L88), [stock_ledger.dart:324](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L324)
- **Fungsi/Kelas:** `StockLedger`
- **Implementasi:** Movement keluar menyimpan `harga_pokok_satuan_cents = 0`; tidak ada pemanggilan `rebuild` untuk memulihkan saldo/HPP dari ledger.
- **Penyebab:** Ledger dipakai untuk riwayat, bukan sumber kebenaran yang dapat direkonstruksi.
- **Dampak:** Tidak ada jalur pemulihan bila saldo menyimpang; nilai keluar tidak dapat diaudit.
- **Rekomendasi:** Simpan unit cost keluar (HPP saat itu) dan sediakan rekonsiliasi/rebuild terkontrol.
- **Dependensi:** INV-10.

### INV-09 — Stok masuk/keluar manual tanpa jejak operator dan alasan wajib
- **Severity:** MEDIUM
- **Kategori:** SECURITY WEAKNESS / AUDIT GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:1671](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1671)
- **Fungsi/Kelas:** `_adjustStock`
- **Implementasi:** `_adjustStock` menulis movement dengan `alasan`, tetapi **tidak meneruskan `operator`** ke `StockLedger.apply` meskipun kolom tersedia, dan tidak menulis `business_audits`. Tidak ada validasi peran/approval di service; tidak ada laporan khusus.
- **Penyebab:** Kontrol hanya di UI; operator tidak dipetakan ke ledger.
- **Dampak:** Stok dapat diubah tanpa aktor yang tercatat; penyalahgunaan sulit dideteksi.
- **Rekomendasi:** Teruskan operator, wajibkan alasan + peran, tulis `business_audits`, dan tampilkan di riwayat pergerakan.
- **Dependensi:** INV-10.

### INV-10 — Tidak ada rekonsiliasi stok atau riwayat pergerakan di UI
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [stock_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/stock_screen.dart), [sync_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart) (rekonsiliasi hanya `nota`)
- **Fungsi/Kelas:** Modul stok
- **Implementasi:** Data movement ada, tetapi tidak ada layar riwayat pergerakan, saldo vs movement, atau peringatan selisih. Rekonsiliasi sync hanya untuk entity nota.
- **Penyebab:** Fitur belum dibangun.
- **Dampak:** Pemilik tidak dapat menelusuri penyebab selisih stok.
- **Rekomendasi:** Bangun laporan kartu stok + saldo vs ledger + deteksi anomali.
- **Dependensi:** INV-08.

### INV-11 — Hold opname tanpa idempotency key/request id
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [opname_service.dart:108](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/opname_service.dart#L108)
- **Fungsi/Kelas:** `OpnameService` pembuatan hold
- **Implementasi:** Hold memakai `sync_id` acak tanpa request id; retry pembuatan dapat membuat hold ganda.
- **Penyebab:** Tidak ada kunci idempotensi tingkat permintaan.
- **Dampak:** Opname ganda; koreksi stok berulang.
- **Rekomendasi:** Tambahkan request id unik dari UI + unique index.
- **Dependensi:** INV-01.

### INV-12 — Pembelian dan retur pembelian dari UI tanpa request id
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [purchase_screen.dart:86](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/purchase_screen.dart#L86), [purchase_screen.dart:355](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/purchase_screen.dart#L355), [purchase_service.dart:122](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/purchase_service.dart#L122)
- **Fungsi/Kelas:** `PurchaseService.createPurchase`/`createReturn`; UI pembelian
- **Implementasi:** Service mendukung `requestId` dan memeriksanya, tetapi UI pembelian/retur pembelian tidak mengirimkannya. Retur penjualan sudah mengirim `requestId`.
- **Penyebab:** UI belum memakai kontrak idempotensi.
- **Dampak:** Tap ganda/retry setelah timeout dapat membuat dua dokumen pembelian dan menambah stok dua kali.
- **Rekomendasi:** Generate request id di UI dan kirim; tambahkan unique index pada dokumen.
- **Dependensi:** —

### INV-13 — Opname basi dapat menimpa pergerakan yang belum terlihat
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** NEEDS VALIDATION
- **Lokasi:** [opname_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/opname_service.dart), [app_database.dart:1617](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1617)
- **Implementasi:** Nilai absolut opname diterapkan setelah semua device sync, tetapi bila ada movement yang tidak terlihat oleh perangkat pengusul, hasil absolut dapat menimpa.
- **Dampak:** Koreksi stok salah.
- **Rekomendasi:** Sertakan HLC/basis dan tolak bila basis tidak cocok, atau tampilkan pratinjau delta ke operator.
- **Dependensi:** INV-01.

### INV-14 — Tidak ada CHECK `jumlah_milli >= 0`
- **Severity:** INFO
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Default sementara: negatif diizinkan dengan konfirmasi + flag (opsi B)
- **Lokasi:** [schema.dart:275](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/schema.dart#L275)
- **Implementasi:** `stock_items` memiliki CHECK untuk harga dan stok minimum, tetapi tidak untuk `jumlah_milli`. Negatif diizinkan karena jalur sync membutuhkannya.
- **Keputusan:** Pemilik tidak memiliki preferensi; audit memakai opsi B (izinkan dengan konfirmasi, catat negatif/konflik). Karena itu CHECK keras belum dipasang.
- **Dampak:** Saldo negatif dapat bertahan tanpa penanda/alar.
- **Rekomendasi:** Tambahkan flag/laporan stok negatif dan batas waktu penyelesaian opname; bila kebijakan berubah ke blokir, tambahkan CHECK setelah data dibersihkan.
- **Dependensi:** INV-04, keputusan #3.

---

## 3. Uji Konsistensi Stok

| Uji | Hasil | Bukti |
|---|---|---|
| Penjualan mengurangi stok atomik | PASS | `StockLedger.apply` dalam transaksi nota |
| Double decrement saat retry | PASS | Kunci `sale-<partSync>` |
| Stok negatif lokal | PASS (diblokir) | Guard `allowNegative` |
| Stok negatif remote | Diizinkan + konflik | `note_sync.dart` |
| Retur mengembalikan stok | PASS dengan kunci idempoten | `retur-...` |
| Void mengembalikan stok | **PARTIAL/FAIL** | INV-02, INV-03 |
| Opname | **FAIL** | INV-01 |
| Ledger = saldo | **FAIL** | INV-06, INV-08 |
| HPP setelah koreksi negatif | **FAIL** | INV-04 |
| Riwayat pergerakan tersedia | Data ada; UI tidak ada | INV-10 |
| Pembelian menambah stok atomik | PASS | Transaksi purchase |
| Pembelian tanpa request id | **FAIL** | INV-12 |

---

## 4. Rekomendasi Prioritas

1. **INV-03** — hentikan double refund (CRITICAL).
2. **INV-01** — opname absolut + isolasi kegagalan.
3. **INV-02/INV-07** — satukan restock/pembatalan retur dengan filter status.
4. **INV-04** — definisi valuasi stok negatif.
5. **INV-12/INV-11** — idempotensi dokumen pembelian/opname.
6. **INV-06/INV-08/INV-10** — ledger lengkap + UI rekonsiliasi.
