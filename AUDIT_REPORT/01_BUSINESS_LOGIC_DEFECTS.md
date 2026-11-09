# 01 — REGISTRI DEFECT LOGIKA BISNIS

**Total temuan:** 59 — CRITICAL 7, HIGH 29, MEDIUM 18, LOW 5
**Status:** CONFIRMED 58, NEEDS VALIDATION 1
**Catatan:** Seluruh temuan berasal dari analisis statis. Nomor baris merujuk kondisi source saat audit. Tidak ada test/build/runtime yang dijalankan.

## Daftar Temuan

| ID | Nama singkat | Kategori | Risiko | Status |
|---|---|---|---|---|
| SAL-01 | Konversi estimasi memakai total termasuk PPN sebagai diskon | Pajak/Penjualan | CRITICAL | CONFIRMED |
| SAL-02 | Konversi estimasi selalu menjadi order kerja | Alur penjualan | HIGH | CONFIRMED |
| SAL-03 | Jasa bebas tanpa katalog melewati batas modal dan izin harga | Harga | HIGH | CONFIRMED |
| SAL-04 | Kredit tanpa izin, jatuh tempo wajib, atau limit | Penjualan | HIGH | CONFIRMED |
| SAL-05 | Konversi estimasi menghilangkan `jasaId` | Penjualan | HIGH | CONFIRMED |
| SAL-06 | Harga jasa bebas dicatat sebagai harga terdaftar | Pelaporan | MEDIUM | CONFIRMED |
| SAL-07 | Merge pelanggan mengubah atribusi nota historis | Integritas histori | HIGH | CONFIRMED |
| SAL-08 | Tampilan rupiah membulatkan sen | Tampilan | LOW | CONFIRMED |
| PUR-01 | Refund retur pembelian kumulatif dibukukan berulang | Kas/Pembelian | CRITICAL | CONFIRMED |
| PUR-02 | Utang awal supplier tidak dapat dibayar | Pembelian | HIGH | CONFIRMED |
| PUR-03 | Piutang awal pelanggan tidak dapat ditagih dan tidak masuk dashboard | Piutang | HIGH | CONFIRMED |
| PUR-04 | Refund retur pembelian selalu CASH | Kas | MEDIUM | CONFIRMED |
| PUR-05 | Nilai retur memakai harga bruto, bukan harga pokok teralokasi | Retur pembelian | HIGH | CONFIRMED |
| PUR-06 | `volumeQuery` tidak memfilter toko | Multi-toko | HIGH | CONFIRMED |
| PUR-07 | `purchaseTotals` mencampur utang pembelian dan saldo awal | Pelaporan | MEDIUM | CONFIRMED |
| RET-01 | Retur tidak memiliki jalur pembatalan/reversal | Retur | HIGH | CONFIRMED |
| RET-02 | Total retur mencampur nilai ditagih dan DPP | Pajak/Laporan | MEDIUM | CONFIRMED |
| RET-03 | Agregasi retur tidak memfilter status aktif | Integritas laporan | LOW | CONFIRMED |
| INV-01 | Koreksi stok kedua melanggar unique index movement | Persediaan | HIGH | CONFIRMED |
| INV-02 | Opname absolut tertunda menimpa penjualan sesudah hitung fisik | Persediaan | HIGH | CONFIRMED |
| INV-03 | Opname tidak memperbarui cost state | Persediaan | MEDIUM | CONFIRMED |
| INV-04 | Void saldo awal tidak memperbarui cost state | Persediaan | MEDIUM | CONFIRMED |
| INV-05 | Dua kolom kuantitas dengan fallback tidak konsisten | Skema | MEDIUM | CONFIRMED |
| INV-06 | Saldo awal stok tidak menyimpan modal per baris | Persediaan | MEDIUM | NEEDS VALIDATION |
| FIN-01 | Cost state tidak dipelihara penjualan, retur, dan void | Keuangan | CRITICAL | CONFIRMED |
| FIN-02 | HPP nota memakai modal master, bukan HPP rata-rata | Keuangan | HIGH | CONFIRMED |
| FIN-03 | Laporan PPN/omzet memakai nilai kotor tanpa retur | Pajak | HIGH | CONFIRMED |
| FIN-04 | Piutang dashboard mengabaikan saldo awal piutang | Piutang | HIGH | CONFIRMED |
| FIN-05 | Payroll tanpa aktor/izin dan kas dicatat atas nama karyawan | Payroll | HIGH | CONFIRMED |
| FIN-06 | Pembayaran PPN remote tidak dibatasi sisa kewajiban | Pajak/Kas | HIGH | CONFIRMED |
| FIN-07 | Pembagian integer SQL memotong pecahan | Pelaporan | LOW | CONFIRMED |
| BIZ-01 | Idempotensi `request_id` tidak memverifikasi payload | Idempotensi | MEDIUM | CONFIRMED |
| DB-01 | Snapshot tidak memuat `cash_ledger` dan `opname_holds` | Sinkronisasi | CRITICAL | CONFIRMED |
| DB-02 | Restore memaksa `user_version` dan melewati migrasi | Restore | CRITICAL | CONFIRMED |
| DB-03 | Database toko baru dibuat polos di platform SQLCipher | Enkripsi | CRITICAL | CONFIRMED |
| DB-04 | Backup/snapshot tidak membawa versi skema/aplikasi | Backup | HIGH | CONFIRMED |
| DB-05 | Validasi restore hanya memeriksa sebagian tabel inti | Restore | HIGH | CONFIRMED |
| DB-06 | Tidak ada `foreign_key_check` setelah restore/snapshot | Integritas | MEDIUM | CONFIRMED |
| DB-07 | Pembuatan stok dari nota memakai `kode` yang bisa bentrok | Sinkronisasi | HIGH | CONFIRMED |
| DB-08 | Pindah toko saat sinkronisasi berjalan menutup database | Multi-toko | HIGH | CONFIRMED |
| DB-09 | Movement stok ditulis sebelum keputusan opname absolut | Persediaan | MEDIUM | CONFIRMED |
| DB-10 | Dua sumber keanggotaan toko karyawan | Otorisasi data | MEDIUM | CONFIRMED |
| DB-11 | Tabel `sync_peer_digests` tidak pernah dipakai | Skema | LOW | CONFIRMED |
| BAK-01 | Restore berjalan saat sync/backup scheduler aktif | Backup | HIGH | CONFIRMED |
| BAK-02 | Ekspor database polos tanpa penghentian penulis | Backup | MEDIUM | CONFIRMED |
| FLW-01 | Startup tidak memiliki penanganan kegagalan | Alur aplikasi | HIGH | CONFIRMED |
| FLW-02 | Kegagalan nota setelah simpan dilaporkan sebagai gagal simpan | UX/Error | LOW | CONFIRMED |
| FLW-03 | Tidak ada pemulihan database rusak/tidak kompatibel | Alur aplikasi | MEDIUM | CONFIRMED |
| SEC-01 | Sign-out lalu onboarding memungkinkan pengambilalihan owner | Autentikasi | CRITICAL | CONFIRMED |
| SEC-02 | Account service memakai aktor `owner` default tanpa verifikasi | Otorisasi | HIGH | CONFIRMED |
| SEC-03 | Supplier service tidak memiliki otorisasi sama sekali | Otorisasi | HIGH | CONFIRMED |
| SEC-04 | Payroll tidak memeriksa aktor atau izin | Otorisasi | HIGH | CONFIRMED |
| SEC-05 | UI fallback ke `Operator.owner` saat state kosong | Otorisasi UI | HIGH | CONFIRMED |
| SEC-06 | PIN legacy lemah dan PIN pendek tetap diterima | Autentikasi | MEDIUM | CONFIRMED |
| SEC-07 | Database viewer dibuka read-write; cek viewer tidak konsisten | Otorisasi | MEDIUM | CONFIRMED |
| SEC-08 | Ekspor ringkasan owner tanpa pemeriksaan izin | Data sensitif | MEDIUM | CONFIRMED |
| SEC-09 | Sesi hilang disintesis menjadi owner dari PIN | Autentikasi | HIGH | CONFIRMED |
| FEAT-01 | Hanya pembelian yang menegakkan feature flag di service | Feature toggle | HIGH | CONFIRMED |
| FEAT-02 | Cache flag fallback ke `true` sebelum load/pindah toko | Feature toggle | MEDIUM | CONFIRMED |

---

# A. PENJUALAN

## SAL-01 — Konversi estimasi memakai total termasuk PPN sebagai diskon

- **Kategori:** Pajak / Alur penjualan
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/order_service.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `order_service.dart:405-425`, `order_service.dart:564`, `app_database.dart:1718-1736`
- **Bukti sumber:**
  ```dart
  // order_service.dart:405-425
  final pajak = PajakSnapshot.hitung(brutoCents: allocation.total, config: settings.pajakConfig);
  await txn.insert('estimates', { ..., 'total': pajak.totalCents, ... });

  // order_service.dart:564
  final diskon = (hargaTotal + partTotal) - estimate.totalCents;

  // app_database.dart:1719-1723
  final pajak = PajakSnapshot.hitung(brutoCents: bruto - diskon, config: settings.pajakConfig);
  final total = pajak.totalCents;
  ```
- **Alur sebab-akibat:** Estimasi menyimpan `pajak.totalCents`, yaitu **nilai yang ditagihkan** (DPP + PPN untuk EKSLUSIF/PEMBELI). Saat konversi, nilai itu dikurangkan dari harga item yang masih berupa DPP untuk menghasilkan `diskon`, lalu `createTransaction` menghitung PPN lagi dari `bruto - diskon`.
- **Skenario implementasi:** Pengguna membuat estimasi jasa Rp1.000.000, mode EKSLUSIF/PEMBELI, PPN 11%. `estimates.total` = Rp1.110.000. Konversi menghitung `diskon = 1.000.000 - 1.110.000 = -110.000`; validasi `if (diskon < 0)` melempar `StateError`, sehingga estimasi **tidak dapat dikonversi sama sekali**. Pada mode INKLUSIF, `total` sudah termasuk PPN yang tersembunyi; selisihnya diperlakukan sebagai diskon, lalu PPN dihitung ulang dari basis yang sudah dikurangi pajak → DPP dan PPN nota lebih kecil.
- **Dampak bisnis:** Alur estimasi → order kerja berhenti untuk transaksi ber-PPN; pada mode lain PPN yang tercatat tidak sesuai aturan pajak dan dapat menyebabkan kurang bayar.
- **Dampak integritas data:** `estimates.total`, `total_estimasi_terakhir`, `service_records.pajak_dpp`, dan `service_records.pajak` tidak lagi merujuk basis yang sama. Rekap PPN bulanan memakai nilai nota yang salah.
- **Rekomendasi:** Simpan basis estimasi secara eksplisit (`dpp`, `pajak`, `mode`, `penanggung`, `total_ditagihkan`) dan konversi dengan menyalin snapshot pajak, bukan mengubah selisih pajak menjadi diskon. Hitung diskon hanya dari harga sebelum pajak.

## SAL-02 — Konversi estimasi selalu menjadi order kerja

- **Kategori:** Alur penjualan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/order_service.dart`
- **Baris:** `600`
- **Bukti sumber:**
  ```dart
  return AppDatabase.instance.createTransaction(
    ...
    jenisTransaksi: transactionOrderKerja,
  ```
- **Alur sebab-akibat:** `convertEstimate` tidak membaca jenis transaksi asal estimasi dan selalu mengirim `transactionOrderKerja` ke `createTransaction`.
- **Skenario implementasi:** Estimasi dibuat untuk “servis langsung” atau “jual sparepart”. Setelah disetujui, konversi menghasilkan nota order kerja, memakai nomor `O`, masuk antrean order, dan dilaporkan sebagai `order_kerja`.
- **Dampak bisnis:** Laporan per jenis transaksi salah; pekerjaan yang seharusnya selesai langsung masuk antrean; nomor dokumen dan alur status tidak sesuai.
- **Dampak integritas data:** `service_records.jenis_transaksi` tidak mencerminkan dokumen asal; relasi estimasi→nota tetap ada tetapi klasifikasi bisnis berubah.
- **Rekomendasi:** Simpan `jenis_transaksi` pada `estimates` (atau pada `mode_saat_dibuat_json`) dan gunakan saat konversi; jika tidak tersedia, minta pengguna memilih dan validasi terhadap `StoreSettings.typeEnabled`.

## SAL-03 — Jasa bebas tanpa katalog melewati batas modal dan izin harga

- **Kategori:** Harga / Otorisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/screens/pos_screen.dart`, `pusatkupos/lib/data/price_rules.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `pos_screen.dart:1620-1675`, `price_rules.dart:24-30`, `price_rules.dart:120-160`, `app_database.dart:1598-1626`
- **Bukti sumber:**
  ```dart
  // pos_screen.dart — dialog jasa bebas
  JobDraft(
    deskripsi: desc,
    jumlah: qty,
    hargaCents: harga,
    jasaId: _catalogId,
    modalCents: selected?.hargaModalCents ?? 0,
  )

  // price_rules.dart — batas per baris
  int get batasTotal => (hargaModal * qtyMilli / 1000).round();

  // app_database.dart — hanya jasa katalog yang divalidasi terhadap master
  if (job.jasaId != null) { ... if (job.hargaCents != hargaJual) throw ...; }
  ```
- **Alur sebab-akibat:** Jasa bebas dibuat dengan `jasaId = null` dan `modalCents = 0`. `PriceRules` memakai `hargaModal` sebagai batas; nol berarti tidak ada lantai harga. `createTransaction` tidak memeriksa izin `ubah_harga_jasa` untuk baris tanpa katalog, dan harga nol hanya meminta konfirmasi dialog.
- **Skenario implementasi:** Kasir menambah jasa “Servis AC” tanpa memilih tarif, mengisi harga Rp0 atau Rp10.000 padahal modal/jasa normal Rp150.000. Nota tersimpan; laporan `belowPriceSales` membandingkan `harga_final` dengan `harga_jual_terdaftar` yang diisi dari harga input itu sendiri, sehingga tidak pernah menandai pelanggaran.
- **Dampak bisnis:** Harga jasa dapat diturunkan tanpa otorisasi; margin hilang; owner tidak mendapat peringatan penjualan di bawah tarif.
- **Dampak integritas data:** `service_jobs` menyimpan `harga_batas_saat_transaksi = 0`, sehingga audit harga dan laporan di bawah modal tidak dapat merekonstruksi batas yang seharusnya.
- **Rekomendasi:** Wajibkan jasa dari katalog, atau untuk jasa bebas wajibkan input modal/estimasi biaya dan izin `ubah_harga_jasa`; simpan `harga_terdaftar` dari tarif acuan, bukan dari input; blokir harga nol kecuali owner dengan alasan dan audit.

## SAL-04 — Kredit tanpa izin, jatuh tempo wajib, atau limit

- **Kategori:** Penjualan / Piutang
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/screens/pos_screen.dart`, `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/access_control.dart`
- **Baris:** `pos_screen.dart:729-733`, `pos_screen.dart:1300-1312`, `app_database.dart:1733-1734`, `app_database.dart:1873-1874`
- **Bukti sumber:**
  ```dart
  jatuhTempo: (_total - _bayarCents) > 0 ? _jatuhTempo : null,
  ...
  if (_jatuhTempo == null) { ... 'Belum ditentukan' ... }
  ...
  final sisa = total - dibayar;
  final statusBayar = sisa == 0 ? 'LUNAS' : 'KREDIT';
  ...
  'jatuh_tempo': jatuhTempo == null ? null : dateOnly.format(jatuhTempo),
  ```
- **Alur sebab-akibat:** Nota dianggap KREDIT hanya berdasarkan selisih bayar. Tidak ada permission kredit di `permissions.dart`/`access_control.dart`, tidak ada validasi jatuh tempo wajib, dan tidak ada limit piutang per pelanggan.
- **Skenario implementasi:** Kasir dengan izin `buat_nota` mengosongkan nominal bayar, tidak memilih jatuh tempo, lalu menyimpan nota Rp5.000.000. Nota berstatus KREDIT tanpa tanggal jatuh tempo; dashboard memasukkan seluruh `sisa_bayar` sebagai piutang.
- **Dampak bisnis:** Piutang tak terbatas dan tak terjadwal; penagihan tidak dapat diprioritaskan; risiko kredit sepenuhnya bergantung pada kedisiplinan kasir.
- **Dampak integritas data:** `service_records.jatuh_tempo` NULL untuk kredit; laporan aging dan pengingat tidak memiliki dasar tanggal.
- **Rekomendasi:** Tambahkan izin `kredit`/`beri_kredit`, wajibkan jatuh tempo untuk sisa > 0, tetapkan limit per pelanggan (dan approval owner bila melebihi), serta audit pemberian kredit.

## SAL-05 — Konversi estimasi menghilangkan `jasaId`

- **Kategori:** Penjualan / Harga
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/order_service.dart`
- **Baris:** `548-556`
- **Bukti sumber:**
  ```dart
  jobs.add(
    JobDraft(
      deskripsi: item['deskripsi'] as String? ?? '',
      jumlah: jumlah,
      hargaCents: hargaTerdaftar,
      modalCents: modal,
      intervalBulan: ...,
    ),
  );
  ```
- **Alur sebab-akibat:** `JobDraft` dibuat tanpa `jasaId`, sehingga `createTransaction` memperlakukannya sebagai jasa bebas dan tidak memvalidasi harga terhadap `harga_jasa`.
- **Skenario implementasi:** Estimasi memuat jasa katalog “Ganti Oli” dengan harga final hasil negosiasi. Saat konversi, nota dibuat tanpa `jasaId`; master tarif berubah sebelum konversi, tetapi nota tetap memakai harga estimasi tanpa peringatan.
- **Dampak bisnis:** Harga jasa pada nota dapat menyimpang dari tarif aktif; laporan per jasa tidak dapat mengaitkan nota ke katalog.
- **Dampak integritas data:** `service_jobs.jasa_id`/`jasa_sync_id` kosong; relasi tarif hilang dan tidak dapat dipulihkan dari nota.
- **Rekomendasi:** Simpan `jasa_sync_id` pada `estimate_items` dan teruskan ke `JobDraft`; saat konversi, validasi harga terhadap master atau minta approval owner bila berbeda.

## SAL-06 — Harga jasa bebas dicatat sebagai harga terdaftar

- **Kategori:** Pelaporan / Audit harga
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/models.dart`
- **Baris:** `app_database.dart:1626`, `models.dart:344-374`, `app_database.dart:3664-3713`
- **Bukti sumber:**
  ```dart
  // app_database.dart
  lines.add(PriceLine(..., hargaTerdaftar: job.hargaCents, ...));
  // models.dart
  }) : hargaTerdaftarCents = hargaTerdaftarCents ?? hargaCents;
  ```
- **Alur sebab-akibat:** Untuk jasa tanpa katalog, `hargaTerdaftar` diisi dari harga yang diketik pengguna. Laporan `belowPriceSales` membandingkan `harga_final` dengan `harga_jual_terdaftar`; keduanya berasal dari angka yang sama.
- **Skenario implementasi:** Jasa bebas dimasukkan Rp50.000 padahal tarif normal Rp200.000. Laporan penjualan di bawah harga tidak menampilkan baris tersebut karena `harga_final == harga_terdaftar`.
- **Dampak bisnis:** Owner kehilangan alat deteksi underprice untuk jasa yang tidak dipilih dari katalog.
- **Dampak integritas data:** Kolom `harga_jual_terdaftar` tidak lagi bermakna “tarif acuan”, melainkan “harga input”, sehingga audit tidak dapat membedakan diskon dari harga manual.
- **Rekomendasi:** Pisahkan `harga_terdaftar` (dari katalog) dan `harga_input`; untuk jasa bebas, isi `harga_terdaftar` dengan tarif referensi yang dipilih owner atau tandai eksplisit sebagai “tanpa tarif”.

## SAL-07 — Merge pelanggan mengubah atribusi nota historis

- **Kategori:** Integritas histori
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`
- **Baris:** `794-837`, `2905`, `2930`
- **Bukti sumber:**
  ```dart
  await txn.update('service_records', {
    'customer_id': targetId,
    'sync_hlc_wall': recordHlc.wall,
    'sync_hlc_counter': recordHlc.counter,
    'updated_at': nowIso(),
  }, where: 'id IN (...)');
  ...
  LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)
  ```
- **Alur sebab-akibat:** Merge memindahkan seluruh nota dan unit pelanggan asal ke pelanggan tujuan, lalu menaikkan HLC. Nota tidak menyimpan snapshot nama pelanggan; tampilan dan cetak selalu join ke `customers.nama` saat ini.
- **Skenario implementasi:** Dua pelanggan “Budi” dan “Budi Santoso” digabung. Semua nota lama “Budi” berubah menampilkan “Budi Santoso”; nota yang sudah dicetak dan diserahkan tidak lagi cocok dengan database. HLC yang dinaikkan juga mengalahkan versi perangkat lain saat sync.
- **Dampak bisnis:** Riwayat pelanggan berubah setelah transaksi; sengketa garansi/piutang sulit dibuktikan; laporan pelanggan masa lalu berubah retroaktif.
- **Dampak integritas data:** Relasi historis `service_records → customers` termutasi; tidak ada jejak nama pelanggan pada nota. Merge tidak dapat dibatalkan.
- **Rekomendasi:** Tambahkan snapshot `customer_nama`/`customer_hp` pada nota dan gunakan untuk cetak/laporan; merge hanya untuk referensi ke depan, atau simpan alias pelanggan dan pertahankan ID asal pada nota lama.

## SAL-08 — Tampilan rupiah membulatkan sen

- **Kategori:** Tampilan
- **Risiko:** LOW
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/core/money.dart`
- **Baris:** `38-42`
- **Bukti sumber:**
  ```dart
  final NumberFormat _rupiah = NumberFormat.currency(
    locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0,
  );
  String formatRupiah(int cents) => _rupiah.format(cents / 100);
  ```
- **Alur sebab-akibat:** Database menyimpan sen, tetapi semua tampilan utama membulatkan ke rupiah penuh. Penjumlahan baris yang sudah dibulatkan dapat berbeda Rp1 dari total.
- **Skenario implementasi:** Tiga baris masing-masing Rp33,33 ditampilkan Rp33; total Rp99,99 ditampilkan Rp100. Struk menunjukkan jumlah baris yang tidak sama dengan total.
- **Dampak bisnis:** Ketidaksesuaian kecil pada struk dan laporan; potensi pertanyaan pelanggan.
- **Dampak integritas data:** Data tetap benar di database; hanya presentasi yang tidak konsisten.
- **Rekomendasi:** Tampilkan sen bila nilainya tidak bulat, atau bulatkan di tingkat nota secara eksplisit dan simpan nilai pembulatan.

---

# B. PEMBELIAN

## PUR-01 — Refund retur pembelian kumulatif dibukukan berulang

- **Kategori:** Kas / Pembelian
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `712-731`, `1897-1923`
- **Bukti sumber:**
  ```dart
  final refund = await _recalculateTotals(txn, purchaseId);
  if (refund > 0) {
    await txn.update('supplier_purchase_returns', {'total_kas_kembali': refund, ...});
    await _writeCash(txn, sumberSyncId: returnSyncId, nominal: refund, ...);
  }
  ...
  final net = total - retur;
  final refund = (paid - net) < 0 ? 0 : paid - net;
  ```
- **Alur sebab-akibat:** `_recalculateTotals` menghitung refund **kumulatif** seluruh retur (`paid - (total - total_retur)`). Nilai itu ditulis sebagai kas keluar untuk **setiap** dokumen retur dengan `sumber_sync_id = returnSyncId` yang unik. `ux_cash_ledger_source` tidak menahan karena sumbernya berbeda.
- **Skenario implementasi:** Pembelian Rp100.000 dibayar penuh. Retur pertama Rp30.000 → `net=70.000`, refund=30.000, kas keluar 30.000. Retur kedua Rp20.000 → `net=50.000`, refund kumulatif=50.000, kas keluar **50.000** lagi. Total kas keluar 80.000 padahal uang yang seharusnya kembali 50.000. `total_kas_kembali` dokumen kedua juga tercatat 50.000, bukan 20.000.
- **Dampak bisnis:** Kas hilang/tercatat keluar fiktif sebesar retur sebelumnya; saldo kas dan rekonsiliasi tidak dapat dipercaya.
- **Dampak integritas data:** `cash_ledger` berisi baris ganda yang tidak dapat dihapus; `supplier_purchase_returns.total_kas_kembali` salah per dokumen; laporan arus kas membengkak.
- **Rekomendasi:** Hitung refund **inkremental** per dokumen: `refund_dokumen = retur_dokumen - (sisa pembayaran yang belum dialokasikan)`, atau simpan `refund_terakumulasi` pada header pembelian dan tulis selisihnya saja. Tambahkan idempotensi per dokumen retur.

## PUR-02 — Utang awal supplier tidak dapat dibayar

- **Kategori:** Pembelian / Utang
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/opening_balance_service.dart`, `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `opening_balance_service.dart:154-186`, `purchase_service.dart:930-953`
- **Bukti sumber:**
  ```dart
  // purchaseTotals
  'total_utang': ((row['total_utang'] as num?)?.toInt() ?? 0) + openingDebt,
  ```
- **Alur sebab-akibat:** Saldo awal `UTANG_SUPPLIER` hanya disimpan di `opening_balance_items.nominal`. Tidak ada dokumen pembayaran, penyesuaian, atau konversi ke `supplier_purchases`. `addPayment` hanya menerima `purchaseId` dari tabel pembelian.
- **Skenario implementasi:** Toko mencatat utang awal Rp25.000.000 ke supplier. Nilai itu muncul di total utang, tetapi UI pembayaran tidak memiliki nota pembelian untuk dipilih; pemilik tidak dapat mengurangi utang tersebut kecuali membuat pembelian fiktif.
- **Dampak bisnis:** Utang awal tidak pernah lunas; aging dan total utang membengkak permanen; pembayaran riil ke supplier tidak dapat dicatat.
- **Dampak integritas data:** Saldo utang tidak memiliki ledger pembayaran; `total_dibayar` dan `sisa_utang` tidak pernah konsisten dengan saldo awal.
- **Rekomendasi:** Buat entitas “tagihan awal” atau izinkan pembayaran langsung ke `opening_balance_items` dengan ledger kas; sediakan alur konversi saldo awal ke nota pembelian.

## PUR-03 — Piutang awal pelanggan tidak dapat ditagih dan tidak masuk dashboard

- **Kategori:** Piutang
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/opening_balance_service.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `opening_balance_service.dart:187-215`, `app_database.dart:3798-3800`
- **Bukti sumber:**
  ```dart
  // dashboard
  SELECT COALESCE(SUM(sisa_bayar), 0) AS total
  FROM service_records WHERE status != 'VOID' AND sisa_bayar > 0
  ```
- **Alur sebab-akibat:** Saldo awal `PIUTANG_PELANGGAN` hanya tersimpan sebagai nominal di `opening_balance_items`. Tidak ada jalur pembayaran, dan dashboard hanya menjumlahkan `service_records.sisa_bayar`.
- **Skenario implementasi:** Toko mencatat piutang awal Rp8.000.000. Dashboard menampilkan piutang Rp0 (bila belum ada nota kredit); pelanggan membayar, tetapi tidak ada tempat mencatat penerimaan.
- **Dampak bisnis:** Piutang awal tidak tertagih secara sistem; laporan piutang understate; kas masuk tidak tercatat.
- **Dampak integritas data:** Saldo piutang di luar nota tidak memiliki ledger; tidak dapat direkonsiliasi dengan pembayaran.
- **Rekomendasi:** Tambahkan dokumen tagihan/penerimaan untuk saldo awal, atau konversi ke nota kredit; sertakan saldo awal dalam dashboard dan aging.

## PUR-04 — Refund retur pembelian selalu CASH

- **Kategori:** Kas
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `720-731`
- **Bukti sumber:**
  ```dart
  await _writeCash(
    txn,
    sumberSyncId: returnSyncId,
    nominal: refund,
    metode: 'CASH',
    kategori: 'RETUR_PEMBELIAN',
    ...
  );
  ```
- **Alur sebab-akibat:** Metode refund di-hardcode `CASH`, tidak mengikuti metode pembayaran asal (`supplier_payments.metode`) atau pilihan pengguna.
- **Skenario implementasi:** Pembelian dibayar via TRANSFER. Retur menghasilkan `cash_ledger` CASH, sehingga laporan kas fisik menunjukkan uang masuk yang tidak ada; saldo bank tidak bertambah.
- **Dampak bisnis:** Rekonsiliasi kas dan bank salah; kas fisik terlihat lebih besar.
- **Dampak integritas data:** `cash_ledger.metode` tidak mencerminkan arus dana sebenarnya.
- **Rekomendasi:** Simpan metode refund per dokumen (default metode pembayaran asal) dan validasi terhadap saldo/pilihan pengguna.

## PUR-05 — Nilai retur memakai harga bruto, bukan harga pokok teralokasi

- **Kategori:** Retur pembelian / Keuangan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `622-642`, `712-731`, `1897-1923`
- **Bukti sumber:**
  ```dart
  final harga = (item['harga_satuan'] as num?)?.toInt() ?? 0;
  final modal = (item['harga_pokok_satuan'] as num?)?.toInt() ?? 0;
  final subtotal = _mulDiv(line.qtyMilli, harga, 1000);
  total += subtotal;
  ...
  final net = total - retur;
  final refund = (paid - net) < 0 ? 0 : paid - net;
  ```
- **Alur sebab-akibat:** `supplier_purchase_returns.total` memakai `harga_satuan` bruto, sedangkan nilai pembelian yang dibayar sudah dialokasikan diskon/ongkir ke `harga_pokok_satuan`. Refund dihitung dari `paid - (total - retur)` dengan `retur` berbasis harga bruto, bukan porsi biaya yang benar-benar dibayar.
- **Skenario implementasi:** Pembelian 100 unit, subtotal Rp150.000, diskon Rp50.000, total dibayar Rp100.000 (Rp1.000/unit efektif). Retur 50 unit dihitung Rp75.000 (50 × Rp1.500). `net = 100.000 - 75.000 = 25.000`, refund = Rp75.000, padahal porsi yang dibayar untuk 50 unit hanya Rp50.000 → lebih bayar Rp25.000.
- **Dampak bisnis:** Uang keluar melebihi hak supplier; potensi sengketa dan kerugian langsung.
- **Dampak integritas data:** `total_kas_kembali`, `cash_ledger`, dan `sisa_utang` tidak konsisten dengan nilai pembelian efektif.
- **Rekomendasi:** Hitung nilai retur dari `harga_pokok_satuan` (termasuk alokasi diskon/ongkir), atau simpan `nilai_bayar_per_unit`; refund harus proporsional terhadap kas yang benar-benar dibayar.

## PUR-06 — `volumeQuery` tidak memfilter toko

- **Kategori:** Multi-toko / Pelaporan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `930-935`, `1005-1017`
- **Bukti sumber:**
  ```dart
  static const volumeQuery = '''
    SELECT ... FROM supplier_purchases
    WHERE deleted_at IS NULL
  ''';
  ...
  final rows = await AppDatabase.instance.db.rawQuery(volumeQuery);
  ```
- **Alur sebab-akibat:** `purchaseTotals()` memanggil `volumeQuery` yang tidak memiliki `WHERE store_id = ?`. Di perangkat dengan beberapa toko, seluruh pembelian semua toko dijumlahkan.
- **Skenario implementasi:** Perangkat memiliki Toko A dan Toko B. Laporan pembelian Toko A menampilkan total gabungan A+B; keputusan restock dan utang menjadi salah.
- **Dampak bisnis:** Laporan per toko tidak dapat dipercaya; owner salah menilai kinerja/utang masing-masing toko.
- **Dampak integritas data:** Agregat tidak sesuai filter toko aktif; tidak ada kerusakan baris, tetapi laporan menyesatkan.
- **Rekomendasi:** Tambahkan parameter `storeId` ke `volumeQuery` dan gunakan `_storeId`.

## PUR-07 — `purchaseTotals` mencampur utang pembelian dan saldo awal

- **Kategori:** Pelaporan
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `930-953`
- **Bukti sumber:**
  ```dart
  return {
    'total_pembelian': ...,
    'total_utang': ((row['total_utang'] as num?)?.toInt() ?? 0) + openingDebt,
    'total_dibayar': ...,
    'jumlah_nota': ...,
  };
  ```
- **Alur sebab-akibat:** Hanya `total_utang` yang ditambah saldo awal; `total_pembelian`, `total_dibayar`, dan `jumlah_nota` tidak. Rasio pembayaran dan aging menjadi tidak sebanding.
- **Skenario implementasi:** Utang awal Rp10.000.000 + pembelian Rp5.000.000 dibayar Rp5.000.000. Total utang Rp10.000.000, total dibayar Rp5.000.000, tetapi total pembelian Rp5.000.000 → terlihat “utang lebih besar dari pembelian”.
- **Dampak bisnis:** Ringkasan pemilik membingungkan; keputusan pembayaran salah.
- **Dampak integritas data:** Kombinasi angka dari dua sumber tanpa pemisahan.
- **Rekomendasi:** Pisahkan `utang_pembelian` dan `utang_awal` dalam hasil, atau tampilkan keduanya sebagai dua baris.

---

# C. RETUR DAN PEMBATALAN

## RET-01 — Retur tidak memiliki jalur pembatalan/reversal

- **Kategori:** Retur
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/schema.dart`, `pusatkupos/lib/data/sale_return_service.dart`, `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `schema.dart:1028-1050`, `sale_return_service.dart:37-405`, `purchase_service.dart:545-745`
- **Bukti sumber:**
  ```sql
  CREATE TRIGGER trg_sale_returns_immutable
  BEFORE UPDATE OF ... status, ... voided_at ...
  WHEN ... OR NEW.status IS NOT OLD.status
    OR ... NEW.voided_at IS NOT OLD.voided_at
  BEGIN SELECT RAISE(ABORT, 'retur bersifat final'); END
  ```
- **Alur sebab-akibat:** `sale_returns` memiliki kolom `status`/`voided_at`, tetapi trigger melarang perubahannya. Tidak ada method void/reversal di `SaleReturnService`. Retur pembelian mengizinkan status VOID di skema, tetapi tidak ada jalur yang menulisnya.
- **Skenario implementasi:** Kasir salah memilih baris dan qty retur; nota dan stok sudah berubah. Pemilik tidak dapat membatalkan retur; satu-satunya jalan adalah koreksi manual di luar aplikasi.
- **Dampak bisnis:** Kesalahan retur permanen; stok dan kas tidak dapat dikembalikan ke kondisi benar melalui UI.
- **Dampak integritas data:** Histori retur tidak dapat direkonsiliasi; `sale_returns.status` hanya bernilai AKTIF selamanya.
- **Rekomendasi:** Tambahkan dokumen reversal (retur balik) yang append-only dan mengurangi/mengembalikan stok serta kas, dengan otorisasi owner; jangan mengubah baris retur asli.

## RET-02 — Total retur mencampur nilai ditagih dan DPP

- **Kategori:** Pajak / Laporan
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/sale_return_service.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `sale_return_service.dart:146-194`, `sale_return_service.dart:241-259`, `app_database.dart:3608-3621`
- **Bukti sumber:**
  ```dart
  final refundDitagihkan = penanggung == pajakPenanggungBengkel
      ? dppRetur
      : mode == pajakModeInklusif ? total : dppRetur + pajakRetur;
  total = refundDitagihkan;
  ...
  'subtotal': refund,
  ...
  COALESCE(SUM(CASE WHEN i.line_type = 'jasa' THEN i.subtotal ELSE 0 END), 0)
  ```
- **Alur sebab-akibat:** `sale_returns.total` berisi nilai ditagih (termasuk PPN untuk PEMBELI), sedangkan `sale_return_items.subtotal` berisi refund per baris berbasis DPP. `ReportSummary.returCents` menjumlahkan item (DPP), sementara `totalCents` menjumlahkan `total_efektif + total_retur` (termasuk PPN).
- **Skenario implementasi:** Nota Rp1.110.000 (DPP 1.000.000 + PPN 110.000) diretur penuh. `total_retur` = 1.110.000, tetapi `returJasaCents`/`returPartCents` = 1.000.000. Pendapatan neto dihitung `1.110.000 - 1.000.000 = 110.000`, seolah ada pendapatan tersisa padahal barang/jasa diretur penuh.
- **Dampak bisnis:** Omzet neto dan laba kotor overstated sebesar PPN retur; laporan penjualan tidak cocok dengan rekap PPN.
- **Dampak integritas data:** Dua basis nilai dalam satu dokumen retur; tidak ada kolom pemisah yang eksplisit antara DPP dan pajak pada level item.
- **Rekomendasi:** Simpan `dpp`, `pajak`, dan `total_ditagihkan` secara eksplisit pada header dan item; gunakan basis yang sama di semua laporan.

## RET-03 — Agregasi retur tidak memfilter status aktif

- **Kategori:** Integritas laporan
- **Risiko:** LOW
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`
- **Baris:** `2495-2498`, `3608-3620`
- **Bukti sumber:**
  ```sql
  SELECT COALESCE(SUM(total), 0) AS total FROM sale_returns
  WHERE service_record_id = ? AND deleted_at IS NULL
  ```
- **Alur sebab-akibat:** `recalculateRecordTotals` dan `reportSummary` menjumlahkan `sale_returns` tanpa `status = 'AKTIF'`. Skema mengizinkan status VOID meskipun saat ini tidak ada jalur penulisan VOID.
- **Skenario implementasi:** Jika reversal retur ditambahkan di masa depan dengan status VOID tanpa `deleted_at`, total efektif nota dan laporan akan tetap mengurangi nilai retur yang sudah dibatalkan.
- **Dampak bisnis:** Risiko laten; belum berdampak selama retur tidak dapat di-void.
- **Dampak integritas data:** Agregasi tidak konsisten dengan filter yang dipakai layar lain (`status='AKTIF'`).
- **Rekomendasi:** Tambahkan `AND status = 'AKTIF'` pada semua agregasi retur dan jadikan status sebagai satu-satunya sumber pembatalan.

---

# D. PERSEDIAAN

## INV-01 — Koreksi stok kedua melanggar unique index movement

- **Kategori:** Persediaan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/schema.dart`
- **Baris:** `app_database.dart:1081-1093`, `schema.dart:947-950`
- **Bukti sumber:**
  ```dart
  'sumber_entity': 'stock_item',
  'sumber_sync_id': stockSyncId,
  'jenis': 'KOREKSI',
  ...
  CREATE UNIQUE INDEX ux_stock_movement_source
  ON stock_movements(store_id, sumber_entity, sumber_sync_id, jenis)
  WHERE sumber_sync_id <> ''
  ```
- **Alur sebab-akibat:** Setiap edit stok dengan delta ≠ 0 menulis movement KOREKSI dengan sumber `(stock_item, stockSyncId)`. Edit kedua menghasilkan kombinasi yang sama dan melanggar unique index; seluruh transaksi edit di-rollback.
- **Skenario implementasi:** Barang dibuat dengan stok 10. Edit pertama menurunkan ke 8 (KOREKSI, sumber stockSyncId). Edit kedua menaikkan ke 9 → `UNIQUE constraint failed`; pengguna melihat error dan stok tidak berubah.
- **Dampak bisnis:** Koreksi stok hanya dapat dilakukan sekali per barang; pekerjaan stok berikutnya gagal.
- **Dampak integritas data:** Tidak ada baris ganda (transaksi rollback), tetapi operasi koreksi tidak dapat diselesaikan.
- **Rekomendasi:** Gunakan `sumber_sync_id` movement yang unik per koreksi (mis. `newSyncId()`), bukan ID barang; simpan ID barang pada `stock_sync_id` seperti saat ini.

## INV-02 — Opname absolut tertunda menimpa penjualan sesudah hitung fisik

- **Kategori:** Persediaan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/sync/sync_service.dart`
- **Baris:** `app_database.dart:1235-1300`, `sync_service.dart:3483-3535`
- **Bukti sumber:**
  ```dart
  // applyOpnameTx
  final delta = jumlahFisikMilli - before.jumlahMilli;
  await txn.update('stock_items', {'jumlah_milli': jumlahFisikMilli, ...});
  ...
  // sync_service
  final applyQuantity = absoluteMilli == null || isNewer;
  final nextMilli = absoluteMilli ?? before.jumlahMilli + qtyMilli;
  ```
- **Alur sebab-akibat:** Opname menyimpan nilai absolut. Saat diterapkan kemudian, nilai itu mengganti saldo terkini, bukan merekonsiliasi selisih antara waktu hitung dan waktu terapkan.
- **Skenario implementasi:** Pukul 10:00 perangkat A menghitung fisik 10 unit. Pukul 10:05 perangkat B menjual 2 unit (saldo 8). Pukul 10:10 opname A diterapkan dengan HLC lebih baru → saldo menjadi 10, seolah penjualan 2 unit tidak pernah terjadi.
- **Dampak bisnis:** Stok fisik dan sistem berbeda; barang hilang/terjual tidak terdeteksi; restock salah.
- **Dampak integritas data:** Movement opname mencatat `stok_sesudah = 10`, menghapus jejak penjualan 2 unit dari saldo (meski movement penjualan tetap ada).
- **Rekomendasi:** Terapkan opname sebagai penyesuaian delta terhadap saldo saat ini, atau sertakan saldo basis dan tolak/rekonsiliasi bila saldo berubah sejak hitung fisik.

## INV-03 — Opname tidak memperbarui cost state

- **Kategori:** Persediaan / Keuangan
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`
- **Baris:** `1235-1300`
- **Bukti sumber:**
  ```dart
  await txn.update('stock_items', {'jumlah_milli': jumlahFisikMilli, ...});
  await txn.insert('stock_movements', {... 'jenis': 'KOREKSI', ...});
  // tidak ada update stock_cost_state
  ```
- **Alur sebab-akibat:** `applyOpnameTx` hanya memperbarui `stock_items` dan `stock_movements`; `stock_cost_state.qty_milli` tidak disesuaikan.
- **Skenario implementasi:** Opname menemukan 5 unit hilang dari 100. Saldo stok menjadi 95, tetapi cost state tetap 100; nilai persediaan dihitung dari saldo × HPP (masih memakai qty lama untuk rata-rata berikutnya).
- **Dampak bisnis:** Nilai persediaan dan HPP rata-rata tidak mencerminkan kehilangan stok.
- **Dampak integritas data:** Dua sumber kuantitas (`stock_items` vs `stock_cost_state`) menyimpang.
- **Rekomendasi:** Perbarui cost state pada setiap opname (qty dan HPP), atau jadikan `stock_items.jumlah_milli` satu-satunya sumber kuantitas untuk perhitungan HPP.

## INV-04 — Void saldo awal tidak memperbarui cost state

- **Kategori:** Persediaan / Keuangan
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/opening_balance_service.dart`
- **Baris:** `236-310`
- **Bukti sumber:**
  ```dart
  await txn.update('stock_items', {'jumlah_milli': after, ...});
  await txn.insert('stock_movements', {... 'jenis': 'KELUAR', ...});
  // tidak ada update stock_cost_state
  ```
- **Alur sebab-akibat:** Posting saldo awal menaikkan cost state (`_stockIn`), tetapi `voidActive` hanya mengurangi stok dan menulis movement KELUAR.
- **Skenario implementasi:** Saldo awal 100 unit dibatalkan. Stok menjadi 0, cost state tetap 100; nilai persediaan tidak kembali nol.
- **Dampak bisnis:** Pembatalan saldo awal tidak membersihkan nilai persediaan; laporan valuation salah.
- **Dampak integritas data:** Cost state tidak reversibel.
- **Rekomendasi:** Kurangi cost state sebesar qty saldo awal saat void, atau hitung ulang cost state dari ledger.

## INV-05 — Dua kolom kuantitas dengan fallback tidak konsisten

- **Kategori:** Skema / Migrasi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/schema.dart`, `pusatkupos/lib/data/purchase_service.dart`, `pusatkupos/lib/sync/sync_service.dart`
- **Baris:** `schema.dart:274-300`, `purchase_service.dart:1700-1712`, `sync_service.dart:3790-3795`
- **Bukti sumber:**
  ```dart
  // purchase _applyStockIn
  final before = (rows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
  ...
  // sync_service
  COALESCE(jumlah_milli, jumlah * 1000)
  ```
- **Alur sebab-akibat:** Sebagian jalur membaca `COALESCE(jumlah_milli, jumlah*1000)`, sebagian lain hanya `jumlah_milli` dengan fallback 0. Baris lama yang belum memiliki `jumlah_milli` akan dibaca 0 oleh pembelian.
- **Skenario implementasi:** Baris stok lama memiliki `jumlah=50`, `jumlah_milli=NULL`. Pembelian 10 unit membaca `before=0`, menulis `jumlah_milli=10`; stok fisik 60 menjadi 10.
- **Dampak bisnis:** Kehilangan stok tercatat saat pembelian pertama pada data lama.
- **Dampak integritas data:** Saldo lama hilang tanpa movement koreksi; dua kolom menjadi tidak sinkron.
- **Rekomendasi:** Backfill `jumlah_milli` dari `jumlah*1000` sebelum migrasi, lalu jadikan `jumlah_milli` NOT NULL dan hapus `jumlah`, atau sentralkan seluruh pembacaan pada satu ekspresi.

## INV-06 — Saldo awal stok tidak menyimpan modal per baris

- **Kategori:** Persediaan / Aturan bisnis
- **Risiko:** MEDIUM
- **Status validitas:** NEEDS VALIDATION
- **File:** `pusatkupos/lib/data/opening_balance_service.dart`, `pusatkupos/lib/data/schema.dart`
- **Baris:** `opening_balance_service.dart:131-158`, `opening_balance_service.dart:659-686`, `schema.dart:1967-1994`
- **Bukti sumber:**
  ```dart
  await txn.insert('opening_balance_items', {
    'jenis': 'STOK', ... 'jumlah_milli': item.jumlahMilli, 'nominal': 0,
  });
  ...
  final modal = (stock['harga_modal'] as num?)?.toInt() ?? 0;
  final hpp = newQty <= 0 ? 0 : modal;
  ```
- **Alur sebab-akibat:** Saldo awal stok hanya menyimpan qty; nilai per unit diambil dari `stock_items.harga_modal` saat posting. Tidak ada kolom modal pada `opening_balance_items`.
- **Skenario implementasi:** Owner ingin mencatat 20 unit dengan modal awal Rp50.000/unit, sementara master barang berisi Rp40.000. Nilai saldo awal mengikuti master; tidak ada cara mencatat modal historis yang berbeda.
- **Dampak bisnis:** Nilai saldo awal tidak dapat disesuaikan dengan kondisi nyata; laba kotor periode awal dapat salah.
- **Dampak integritas data:** `opening_balance_items.nominal = 0` untuk stok; tidak ada jejak nilai per unit.
- **Rekomendasi:** Tambahkan `harga_pokok_satuan`/`nominal` pada baris STOK, validasi terhadap master, dan gunakan nilainya saat membentuk cost state. Keputusan ini memerlukan validasi aturan bisnis owner.

---

# E. KEUANGAN DAN PAJAK

## FIN-01 — Cost state tidak dipelihara penjualan, retur, dan void

- **Kategori:** Keuangan / Persediaan
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/sale_return_service.dart`, `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `app_database.dart:1965-1995` (penjualan), `sale_return_service.dart:300-312` (retur), `app_database.dart:3170-3200` (void), `purchase_service.dart:1808-1850` (satu-satunya updater)
- **Bukti sumber:**
  ```dart
  // penjualan: hanya update stock_items + movement
  await txn.update('stock_items', {'jumlah_milli': nextMilli, ...});
  await txn.insert('stock_movements', {... 'jenis': 'KELUAR', ...});
  // tidak ada _updateCostState
  ```
- **Alur sebab-akibat:** `stock_cost_state` hanya diperbarui di `PurchaseService._updateCostState` (pembelian/retur pembelian) dan `OpeningBalanceService._stockIn`. Seluruh pengurangan stok penjualan, pengembalian retur penjualan, dan void nota tidak menyentuh tabel itu.
- **Skenario implementasi:** Beli 100 unit @Rp10.000 (cost state qty=100, HPP=10.000). Jual 80 unit. Cost state tetap 100. Beli lagi 20 unit @Rp20.000: rata-rata dihitung dari 100×10.000 + 20×20.000 = 1.400.000/120 = Rp11.667, padahal qty nyata 40 dan nilai seharusnya berbeda. Nilai persediaan = 40 × 11.667 = Rp466.680, bukan nilai yang dapat direkonsiliasi.
- **Dampak bisnis:** HPP rata-rata, margin per barang, dan nilai persediaan salah permanen; keputusan harga dan restock berbasis angka palsu.
- **Dampak integritas data:** `stock_cost_state.qty_milli` tidak pernah turun karena penjualan; selisih terhadap `stock_items` terus membesar dan tidak dapat direkonsiliasi tanpa rebuild.
- **Rekomendasi:** Pusatkan semua mutasi stok melalui satu service yang selalu memperbarui cost state (termasuk penjualan, retur, void, opname, koreksi), atau hitung HPP dari ledger movement dan buang tabel state. Sediakan rebuild cost state dari `stock_movements`.

## FIN-02 — HPP nota memakai modal master, bukan HPP rata-rata

- **Kategori:** Keuangan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `app_database.dart:1674-1686`, `purchase_service.dart:1700-1714`
- **Bukti sumber:**
  ```dart
  // penjualan
  part..modalCents = stock.hargaModalCents;
  ...
  'harga_modal': part.modalCents,
  // pembelian: hanya qty
  await txn.update('stock_items', {'jumlah': ..., 'jumlah_milli': after, ...});
  ```
- **Alur sebab-akibat:** Pembelian tidak memperbarui `stock_items.harga_modal`, dan penjualan mengambil HPP dari kolom master itu, bukan dari `stock_cost_state.hpp_rata_milli`.
- **Skenario implementasi:** Master modal Rp10.000. Pembelian baru @Rp15.000 memperbarui cost state tetapi tidak master. Penjualan berikutnya mencatat `harga_modal` Rp10.000; laba kotor per nota overstated Rp5.000/unit.
- **Dampak bisnis:** Laporan laba per nota dan margin per barang terlalu optimistis; keputusan diskon salah.
- **Dampak integritas data:** `service_parts.harga_modal` (snapshot HPP) tidak konsisten dengan `stock_cost_state` dan nilai persediaan.
- **Rekomendasi:** Ambil HPP snapshot dari cost state saat transaksi; perbarui master modal hanya sebagai harga default, bukan sumber HPP historis.

## FIN-03 — Laporan PPN/omzet memakai nilai kotor tanpa retur

- **Kategori:** Pajak / Laporan
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`
- **Baris:** `3511-3526`, `3597-3600`, `3654-3661`
- **Bukti sumber:**
  ```sql
  COALESCE(SUM(r.total_efektif + r.total_retur), 0) AS total,
  COALESCE(SUM(r.pajak_dpp), 0) AS total_dpp,
  COALESCE(SUM(r.pajak), 0) AS pajak,
  ```
- **Alur sebab-akibat:** `reportSummary` menjumlahkan `pajak_dpp`/`pajak` dari nota asli, tanpa mengurangi DPP/PPN retur. Retur hanya dikurangkan pada `returCents` (berbasis item/DPP), bukan pada DPP/PPN.
- **Skenario implementasi:** Nota Rp1.110.000 diretur penuh. Laporan ringkasan menampilkan DPP 1.000.000 dan PPN 110.000 tetap; omzet neto 110.000. Rekap PPN bulanan (yang memisahkan retur) menunjukkan kewajiban 0. Dua laporan berbeda untuk transaksi yang sama.
- **Dampak bisnis:** Owner dapat membayar PPN atas penjualan yang sudah diretur; laporan omzet dan pajak tidak konsisten.
- **Dampak integritas data:** DPP/PPN di ringkasan tidak dapat diturunkan dari jurnal retur; tidak ada kolom PPN retur di `ReportSummary`.
- **Rekomendasi:** Kurangkan `sale_returns.dpp`/`pajak` dari ringkasan dan dashboard, atau gunakan `PajakReportService.rekap` sebagai satu-satunya sumber angka PPN.

## FIN-04 — Piutang dashboard mengabaikan saldo awal piutang

- **Kategori:** Piutang
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`
- **Baris:** `3789-3800`
- **Bukti sumber:**
  ```sql
  SELECT COALESCE(SUM(sisa_bayar), 0) AS total
  FROM service_records
  WHERE status != 'VOID' AND sisa_bayar > 0
  ```
- **Alur sebab-akibat:** Dashboard hanya membaca nota; `opening_balance_items` jenis `PIUTANG_PELANGGAN` tidak dijumlahkan.
- **Skenario implementasi:** Piutang awal Rp8.000.000, belum ada nota kredit. Dashboard menampilkan piutang Rp0.
- **Dampak bisnis:** Owner mengira tidak ada piutang; penagihan terlewat.
- **Dampak integritas data:** Angka dashboard tidak mencakup seluruh kewajiban pelanggan.
- **Rekomendasi:** Jumlahkan piutang awal (dan pembayarannya) ke dashboard dan aging; satukan sumber piutang.

## FIN-05 — Payroll tanpa aktor/izin dan kas dicatat atas nama karyawan

- **Kategori:** Payroll / Otorisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/employee_service.dart`
- **Baris:** `283-370`
- **Bukti sumber:**
  ```dart
  Future<PayrollSummary> paySalary(String employeeSyncId, {...}) async {
    ...
    await txn.insert('salary_payments', {..., 'nominal': summary.grossCents, ...});
    await txn.insert('cash_ledger', {
      ..., 'operator': summary.nama,
      'catatan': 'Gaji ${summary.periode} ${summary.nama}',
    });
  ```
- **Alur sebab-akibat:** `paySalary` tidak menerima `Operator`, tidak memanggil `Permissions.require`, dan tidak mencatat aktor pembayar. `cash_ledger.operator` diisi nama karyawan yang dibayar, bukan pengguna yang menjalankan aksi.
- **Skenario implementasi:** Siapa pun yang dapat memanggil layanan (atau UI tanpa guard yang memadai) membayar gaji; audit kas menunjukkan karyawan sebagai operator, sehingga tidak ada jejak siapa yang menyetujui.
- **Dampak bisnis:** Pengeluaran gaji tidak terkontrol; sulit membuktikan siapa yang membayar.
- **Dampak integritas data:** `salary_payments` tanpa `created_by`; `cash_ledger.operator` salah atribusi.
- **Rekomendasi:** Wajibkan `Operator actor` dan izin `bayar_gaji`/owner; simpan aktor pembayar; isi operator kas dengan aktor, bukan penerima.

## FIN-06 — Pembayaran PPN remote tidak dibatasi sisa kewajiban

- **Kategori:** Pajak / Kas
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/pajak_payment_service.dart`
- **Baris:** `233-343`, `360-380`
- **Bukti sumber:**
  ```dart
  final nominal = (payload['nominal'] as num?)?.toInt() ?? 0;
  if (!PajakReportService.validMasa(masa) || nominal <= 0) return;
  ...
  final providedCash = '${payload['cash_sync_id'] ?? ''}'.trim();
  ...
  await txn.insert('cash_ledger', {...}, conflictAlgorithm: ConflictAlgorithm.ignore);
  ```
- **Alur sebab-akibat:** Jalur lokal memeriksa `nominal <= sisaKewajiban`; jalur remote hanya memeriksa format masa dan nominal > 0. `cash_sync_id` dari payload diterima apa adanya, dan insert kas memakai `ignore` sehingga baris yang bentrok dibuang diam-diam.
- **Skenario implementasi:** Perangkat A membayar PPN Rp5.000.000 untuk masa yang hanya memiliki kewajiban Rp1.000.000. Remote menerima seluruh nominal; kas keluar 5.000.000, kewajiban menjadi negatif/berlebih tanpa carry-forward. Jika `cash_sync_id` sama dengan baris lokal lain, kas tidak tercatat sama sekali.
- **Dampak bisnis:** Kas keluar berlebih dan tidak dapat dikembalikan; laporan PPN menunjukkan kelebihan bayar tanpa mekanisme kompensasi.
- **Dampak integritas data:** `pajak_pembayaran.nominal` melampaui kewajiban; `cash_ledger` bisa hilang karena `ignore`.
- **Rekomendasi:** Terapkan validasi sisa kewajiban yang sama di jalur remote, hasilkan `cash_sync_id` secara lokal bila tidak ada, dan gunakan insert yang gagal keras/tercatat konflik, bukan `ignore`.

## FIN-07 — Pembagian integer SQL memotong pecahan

- **Kategori:** Pelaporan
- **Risiko:** LOW
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/purchase_service.dart`
- **Baris:** `app_database.dart:3546-3562`, `purchase_service.dart:969-987`
- **Bukti sumber:**
  ```sql
  SUM(((sp.jumlah_milli - sp.qty_retur_milli) * sp.harga_final) / 1000) AS pendapatan
  ```
- **Alur sebab-akibat:** SQLite melakukan pembagian integer per baris sebelum SUM, sehingga pecahan sen hilang di setiap baris.
- **Skenario implementasi:** 1.500 unit × Rp333,33 → per baris dipotong; total laporan berbeda beberapa rupiah dari total nota.
- **Dampak bisnis:** Selisih kecil pada laporan margin.
- **Dampak integritas data:** Total laporan tidak sama dengan penjumlahan nilai transaksi.
- **Rekomendasi:** Kalikan terlebih dahulu, jumlahkan, baru bagi; atau gunakan `CAST(... AS REAL)` dengan pembulatan sekali di akhir.

---

# F. LINTAS MODUL

## BIZ-01 — Idempotensi `request_id` tidak memverifikasi payload

- **Kategori:** Idempotensi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/purchase_service.dart`, `pusatkupos/lib/data/sale_return_service.dart`
- **Baris:** `app_database.dart:1574-1583`, `purchase_service.dart:119-126`, `sale_return_service.dart:65-75`
- **Bukti sumber:**
  ```dart
  final existing = await txn.query('service_records', columns: ['id'],
    where: 'request_id = ?', whereArgs: [requestId], limit: 1);
  if (existing.isNotEmpty) {
    final id = existing.first['id'] as int;
    if (enqueue != null) await enqueue(txn, id);
    return id;
  }
  ```
- **Alur sebab-akibat:** Bila `request_id` sudah ada, layanan mengembalikan dokumen lama tanpa membandingkan payload baru. UI menganggap penyimpanan baru berhasil.
- **Skenario implementasi:** Pengguna mengubah item lalu menekan simpan ulang dengan `request_id` yang sama (mis. retry setelah jeda). Sistem mengembalikan nota lama; perubahan tidak tersimpan, tetapi layar menampilkan sukses.
- **Dampak bisnis:** Perubahan transaksi hilang diam-diam; pengguna mengira nota sudah diperbarui.
- **Dampak integritas data:** Tidak ada duplikasi, tetapi payload baru tidak pernah tercatat dan tidak ada peringatan.
- **Rekomendasi:** Simpan hash payload bersama `request_id`; jika hash berbeda, tolak dengan pesan “kunci idempotensi sudah dipakai untuk transaksi lain”.

---

# G. DATABASE, SNAPSHOT, DAN MULTI-TOKO

## DB-01 — Snapshot tidak memuat `cash_ledger` dan `opname_holds`

- **Kategori:** Sinkronisasi / Integritas
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/sync/snapshot_sync.dart`, `pusatkupos/lib/data/schema.dart`
- **Baris:** `snapshot_sync.dart:12-55`, `snapshot_sync.dart:57-99`, `snapshot_sync.dart:168-305`
- **Bukti sumber:**
  ```dart
  const snapshotTables = [ ... 'stock_movements', ... 'pajak_pembayaran' ];
  const snapshotDeleteOrder = [ ... ]; // tidak ada cash_ledger/opname_holds
  ```
- **Alur sebab-akibat:** `cash_ledger` dan `opname_holds` tidak ada di daftar snapshot maupun delete order. `applySnapshotPayload` hanya mengganti tabel yang tercantum; tabel lain dibiarkan. Akibatnya buku kas dan opname tertunda tetap lokal dan tidak pernah ikut bootstrap.
- **Skenario implementasi:** Perangkat baru menerima snapshot toko. Semua penjualan/pembelian masuk, tetapi seluruh riwayat kas (dan opname yang belum diterapkan) tidak ada. Laporan kas perangkat baru dimulai dari nol; perangkat lama memiliki riwayat penuh.
- **Dampak bisnis:** Saldo kas antar perangkat berbeda; rekonsiliasi kas tidak mungkin; opname yang belum selesai hilang dari perangkat baru.
- **Dampak integritas data:** Sumber kebenaran kas terpecah per perangkat; snapshot tidak lengkap tetapi dianggap sah.
- **Rekomendasi:** Masukkan `cash_ledger`, `opname_holds`, dan tabel audit ke snapshot (atau dokumentasikan sebagai lokal secara eksplisit dan sediakan rekonsiliasi kas terpisah). Uji bootstrap perangkat baru sampai saldo kas identik.

## DB-02 — Restore memaksa `user_version` dan melewati migrasi

- **Kategori:** Restore / Migrasi
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/backup_service.dart`
- **Baris:** `app_database.dart:462-481`, `backup_service.dart:910-922`, `backup_service.dart:1150-1170`
- **Bukti sumber:**
  ```dart
  await target.execute('PRAGMA user_version = $schemaVersion');
  ```
- **Alur sebab-akibat:** `createEncryptedCopy` menyalin database polos ke SQLCipher lalu **selalu** menulis `user_version` versi aplikasi saat ini, tanpa membaca versi asli. Saat database dibuka, `onUpgrade` tidak dijalankan karena versi dianggap sudah terbaru.
- **Skenario implementasi:** Backup dibuat pada skema v1 (tanpa kolom/tabel PPN). Restore di aplikasi v2: salinan diberi `user_version=2`; aplikasi membuka tanpa migrasi; query ke kolom v2 gagal, atau `createOperationalSchema` hanya menambah tabel sehingga kolom baru tetap hilang.
- **Dampak bisnis:** Restore backup lama menghasilkan aplikasi yang error/crash; data lama tidak dapat dipulihkan dengan aman.
- **Dampak integritas data:** Skema fisik tidak cocok dengan versi yang diklaim; migrasi tidak pernah berjalan; kolom baru NULL/absent.
- **Rekomendasi:** Baca `PRAGMA user_version` dari payload asli dan pertahankan; jalankan migrasi setelah restore; tolak restore bila versi sumber lebih baru dari aplikasi. Sertakan versi skema di manifest.

## DB-03 — Database toko baru dibuat polos di platform SQLCipher

- **Kategori:** Enkripsi / Multi-toko
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/store_service.dart`
- **Baris:** `app_database.dart:154-186`, `store_service.dart:113`
- **Bukti sumber:**
  ```dart
  final fresh = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onConfigure: (db) async { await db.execute('PRAGMA foreign_keys = ON'); },
      onCreate: _createSchema,
    ),
  );
  ```
- **Alur sebab-akibat:** `createDatabaseAt` memakai `databaseFactory` (SQLite polos), bukan `sqlcipher.openDatabase` dengan password. Di Android, `_usesSqlCipher` true untuk database utama, sehingga toko baru tidak mengikuti jalur enkripsi.
- **Skenario implementasi:** Owner menambah toko kedua. Database dibuat tanpa enkripsi; saat dibuka kembali, `_open` memakai SQLCipher dengan password → gagal membuka atau memperlakukan file sebagai database terenkripsi yang rusak.
- **Dampak bisnis:** Toko kedua tidak dapat digunakan; bila terbuka, data toko tersimpan tanpa enkripsi.
- **Dampak integritas data:** File database polos di lokasi yang seharusnya terenkripsi; risiko kebocoran dan korupsi saat dibuka jalur SQLCipher.
- **Rekomendasi:** Gunakan jalur pembukaan yang sama (`_usesSqlCipher ? sqlcipher.openDatabase(...) : databaseFactory...`) dan password yang sama; verifikasi `PRAGMA cipher_version`/keterbukaan setelah pembuatan.

## DB-04 — Backup/snapshot tidak membawa versi skema/aplikasi

- **Kategori:** Backup / Sinkronisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/backup_service.dart`, `pusatkupos/lib/sync/snapshot_sync.dart`
- **Baris:** `backup_service.dart:352-378`, `snapshot_sync.dart:122-168`
- **Bukti sumber:**
  ```dart
  final manifest = jsonEncode({
    'format': _backupFormat,
    'app': 'PusatkuPOS',
    'created_at': nowIso(),
    'active_store_id': ...,
    'stores': manifestStores,
  });
  ```
- **Alur sebab-akibat:** Manifest tidak memuat `schema_version`, versi aplikasi, atau versi kontrak data. Penerima tidak dapat memutuskan migrasi/kompatibilitas sebelum menimpa database.
- **Skenario implementasi:** Backup dari aplikasi versi lebih baru dipulihkan di versi lama. `_rejectIncompatibleVersion` tidak berjalan karena versi tidak diketahui; query gagal atau data dibaca dengan kolom yang salah.
- **Dampak bisnis:** Restore lintas versi berisiko gagal total; dukungan pelanggan sulit menentukan kompatibilitas.
- **Dampak integritas data:** Tidak ada metadata untuk mencegah downgrade/upgrade yang tidak aman.
- **Rekomendasi:** Tambahkan `schema_version`, `app_version`, dan `schema_contract_version` ke manifest backup dan payload snapshot; tolak restore bila versi sumber tidak didukung.

## DB-05 — Validasi restore hanya memeriksa sebagian tabel inti

- **Kategori:** Restore / Integritas
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/backup_service.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `backup_service.dart:35-56`, `backup_service.dart:910-922`, `app_database.dart:520-538`
- **Bukti sumber:**
  ```dart
  const List<String> _requiredRestoreTables = [
    'app_settings', 'employee_accounts', ..., 'debt_reminder_logs',
  ];
  ```
- **Alur sebab-akibat:** Daftar wajib tidak memuat `service_jobs`, `service_parts`, `service_payments`, `sale_returns`, `sale_return_items`, `cash_ledger`, `salary_payments`, `harga_jasa`, `suppliers`, `supplier_items`, dan tabel lain. `_validateProbe` hanya memeriksa keberadaan tabel dalam daftar itu dan `integrity_check`.
- **Skenario implementasi:** Backup terpotong/rusak kehilangan `service_parts` dan `cash_ledger`, tetapi memiliki semua tabel dalam daftar. Restore menerima dan mengganti database; nota kehilangan rincian part dan kas.
- **Dampak bisnis:** Restore “berhasil” tetapi data inti hilang; pengguna baru menyadari saat membuka nota.
- **Dampak integritas data:** Database lolos validasi meskipun tidak lengkap; tidak ada pemeriksaan jumlah baris/relasi.
- **Rekomendasi:** Gunakan daftar tabel wajib yang dihasilkan dari skema (semua tabel non-lokal), atau simpan daftar tabel + jumlah baris di manifest dan bandingkan setelah restore.

## DB-06 — Tidak ada `foreign_key_check` setelah restore/snapshot

- **Kategori:** Integritas
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/data/backup_service.dart`
- **Baris:** `app_database.dart:520-538`, `backup_service.dart:940-955`
- **Bukti sumber:**
  ```dart
  final integrity = await probe.rawQuery('PRAGMA integrity_check');
  ...
  final tableRows = await probe.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
  ```
- **Alur sebab-akibat:** Validasi hanya memakai `integrity_check` (struktur b-tree) dan daftar tabel; `PRAGMA foreign_key_check` tidak dijalankan. `foreign_keys=ON` hanya berlaku untuk penulisan baru, bukan data yang sudah ada.
- **Skenario implementasi:** Backup berisi `service_parts.service_record_id` yang menunjuk nota yang hilang. `integrity_check` OK, restore diterima; join kehilangan baris dan total nota tidak cocok.
- **Dampak bisnis:** Data yatim tersembunyi; laporan dan detail nota tidak konsisten.
- **Dampak integritas data:** Foreign key yang rusak tidak terdeteksi saat restore.
- **Rekomendasi:** Jalankan `PRAGMA foreign_key_check` dan tolak restore bila ada pelanggaran; catat tabel/baris yang bermasalah.

## DB-07 — Pembuatan stok dari nota memakai `kode` yang bisa bentrok

- **Kategori:** Sinkronisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/note_sync.dart`, `pusatkupos/lib/data/schema.dart`
- **Baris:** `note_sync.dart:1025-1044`, `schema.dart:304-307`
- **Bukti sumber:**
  ```dart
  stockId = await txn.insert('stock_items', {
    'sync_id': stockSync,
    'kode': stock?['kode'] ?? stockSync,
    ...
  });
  ...
  CREATE UNIQUE INDEX ux_stock_kode_aktif ON stock_items(kode) WHERE deleted_at IS NULL
  ```
- **Alur sebab-akibat:** Saat stok dari perangkat lain belum ada, nota membuat baris baru dengan `sync_id` payload tetapi `kode` dari payload. Jika kode itu sudah dipakai barang lokal lain (sync_id berbeda), unique index aktif menolak insert dan seluruh penerapan nota gagal.
- **Skenario implementasi:** Dua perangkat membuat barang dengan kode “OLI-10” secara offline. Nota dari perangkat B diterapkan di A yang sudah memiliki kode itu → `UNIQUE constraint failed: stock_items.kode`; nota B tidak pernah masuk, sync berulang gagal.
- **Dampak bisnis:** Nota dari perangkat lain hilang/tertahan; stok dan penjualan tidak sinkron.
- **Dampak integritas data:** Transaksi penerapan nota gagal total; antrean sync macet pada entitas yang sama.
- **Rekomendasi:** Cari barang berdasarkan `sync_id`; bila tidak ada tetapi kode bentrok, buat kode sementara yang unik (mis. suffix sync_id) dan catat konflik untuk ditinjau, jangan gagalkan seluruh nota.

## DB-08 — Pindah toko saat sinkronisasi berjalan menutup database

- **Kategori:** Multi-toko / Sinkronisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/store_service.dart`, `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/sync/sync_service.dart`
- **Baris:** `store_service.dart:137-163`, `app_database.dart:143-152`, `sync_service.dart:2113-2124`
- **Bukti sumber:**
  ```dart
  // store_service
  await AppDatabase.instance.switchStore(record);
  // app_database
  Future<void> switchStore(StoreRecord store) async {
    ...
    await close();
    _path = store.databasePath;
    _activeStoreId = store.storeId;
    await _open();
  }
  ```
- **Alur sebab-akibat:** `switchStore` menutup database tanpa memeriksa `SyncService.isSyncing` atau menghentikan scheduler. Sinkronisasi yang sedang memakai `AppDatabase.instance.db` kehilangan koneksi, atau menulis ke database toko baru dengan `_storeId` yang sudah berubah.
- **Skenario implementasi:** Sinkronisasi toko A sedang menerapkan nota; owner berpindah ke toko B. Database A ditutup di tengah transaksi; proses sync melempar error, atau data A ditulis ke B bila koneksi dibuka ulang sebelum operasi selesai.
- **Dampak bisnis:** Sinkronisasi gagal/parsial; data toko bisa tercampur.
- **Dampak integritas data:** Transaksi terputus, antrean tidak konsisten, potensi penulisan ke toko yang salah.
- **Rekomendasi:** Tunggu/hentikan sync sebelum switch, gunakan kunci global, dan rollback ke toko lama bila `_open` gagal.

## DB-09 — Movement stok ditulis sebelum keputusan opname absolut

- **Kategori:** Persediaan / Sinkronisasi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/sync/sync_service.dart`
- **Baris:** `3495-3535`
- **Bukti sumber:**
  ```dart
  await txn.insert('stock_movements', {
    ...
    'stok_sesudah_milli': nextMilli,
    'opname_absolut_milli': absoluteMilli,
    ...
  });
  if (!applyQuantity) {
    await _recordConflict(...);
    return;
  }
  ```
- **Alur sebab-akibat:** Movement ditulis sebelum `applyQuantity` diperiksa. Bila opname absolut kalah HLC, movement tetap tersimpan dengan `stok_sesudah` yang tidak pernah diterapkan.
- **Skenario implementasi:** Opname lama diterima setelah opname baru. Movement tercatat “stok sesudah 50”, padahal saldo tetap 40; audit ledger menunjukkan perubahan yang tidak terjadi.
- **Dampak bisnis:** Riwayat stok menyesatkan saat investigasi selisih.
- **Dampak integritas data:** Ledger tidak konsisten dengan saldo; movement tidak dapat dijadikan bukti.
- **Rekomendasi:** Pindahkan insert movement setelah keputusan `applyQuantity`; untuk konflik, simpan di `sync_conflicts` saja atau tandai movement sebagai “ditolak”.

## DB-10 — Dua sumber keanggotaan toko karyawan

- **Kategori:** Otorisasi data
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/schema.dart`, `pusatkupos/lib/data/account_service.dart`
- **Baris:** `schema.dart:67-135`, `account_service.dart:155-185`
- **Bukti sumber:**
  ```sql
  CREATE TABLE employee_accounts (... 'store_ids_json' ...);
  CREATE TABLE employee_store_access (... store_id ...);
  ```
- **Alur sebab-akibat:** Keanggotaan toko disimpan di `employee_accounts.store_ids_json` dan di `employee_store_access`. `createAccount` menulis keduanya, tetapi perubahan lain dapat memperbarui salah satu saja.
- **Skenario implementasi:** Karyawan dicabut dari Toko B melalui satu jalur yang hanya memperbarui `employee_store_access`; `store_ids_json` masih memuat B. Sesi lokal atau sync memakai daftar lama dan tetap mengizinkan akses.
- **Dampak bisnis:** Karyawan dapat mengakses toko yang seharusnya dicabut.
- **Dampak integritas data:** Dua sumber otorisasi tidak konsisten; sulit menentukan kebenaran.
- **Rekomendasi:** Jadikan `employee_store_access` satu-satunya sumber, atau `store_ids_json` sebagai cache yang selalu diturunkan dan divalidasi ulang.

## DB-11 — Tabel `sync_peer_digests` tidak pernah dipakai

- **Kategori:** Skema
- **Risiko:** LOW
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/schema.dart`
- **Baris:** `1611-1620`
- **Bukti sumber:**
  ```sql
  CREATE TABLE sync_peer_digests (...);
  ```
  Pencarian referensi di `lib/` tidak menemukan pembacaan/penulisan selain definisi.
- **Alur sebab-akibat:** Tabel dibuat di setiap database, tetapi tidak ada kode yang menulis atau membacanya.
- **Skenario implementasi:** Tidak ada dampak runtime; tabel kosong selamanya.
- **Dampak bisnis:** Tidak ada dampak langsung; menambah beban skema dan kebingungan pemeliharaan.
- **Dampak integritas data:** Tidak ada.
- **Rekomendasi:** Hapus tabel pada desain database bersih, atau implementasikan fitur digest yang memang direncanakan.

---

# H. BACKUP DAN RESTORE

## BAK-01 — Restore berjalan saat sync/backup scheduler aktif

- **Kategori:** Backup / Sinkronisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/screens/settings_screen.dart`, `pusatkupos/lib/data/backup_service.dart`, `pusatkupos/lib/sync/sync_scheduler.dart`
- **Baris:** `settings_screen.dart:372-425`, `backup_service.dart:930-960`
- **Bukti sumber:**
  ```dart
  Future<void> _restore() async {
    ...
    final result = await BackupService.instance.restoreBackup(path: path, passphrase: ...);
  ```
  Tidak ada `SyncScheduler.instance.stop()` atau pemeriksaan `SyncService.isSyncing` sebelum restore.
- **Alur sebab-akibat:** Restore menutup dan mengganti database, sedangkan scheduler sync/backup tetap berjalan. Proses yang sedang berjalan dapat menulis ke database lama yang sudah ditutup atau ke file baru sebelum validasi selesai.
- **Skenario implementasi:** Restore dimulai saat sync mengirim outbox. Database ditutup; sync gagal di tengah, outbox tetap pending, dan setelah reopen status “terkirim” mungkin sudah tercatat untuk data yang sebenarnya belum masuk.
- **Dampak bisnis:** Restore tampak berhasil tetapi antrean sync/backup rusak; data dapat hilang atau terkirim ganda.
- **Dampak integritas data:** Penulisan bersamaan dengan penggantian file; status outbox tidak konsisten.
- **Rekomendasi:** Hentikan scheduler dan tunggu sync selesai sebelum restore; mulai ulang setelah reopen; tampilkan status “restore dalam proses” yang memblokir aksi lain.

## BAK-02 — Ekspor database polos tanpa penghentian penulis

- **Kategori:** Backup
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/backup_service.dart`, `pusatkupos/lib/data/app_database.dart`
- **Baris:** `backup_service.dart:299-318`, `app_database.dart:396-403`
- **Bukti sumber:**
  ```dart
  if (!db.databaseEncrypted) {
    await db.exportPortableCopy(db.databasePath);
    return platform.readDatabase(db.databasePath);
  }
  ...
  Future<void> checkpoint() async { await db.rawQuery('PRAGMA wal_checkpoint(FULL)'); }
  ```
- **Alur sebab-akibat:** Pada platform non-SQLCipher, `exportPortableCopy` hanya checkpoint lalu menyalin file database yang sedang terbuka. `wal_checkpoint(FULL)` tidak menghentikan penulis; penulisan setelah checkpoint dan selama pembacaan file dapat menghasilkan salinan tanpa WAL terkait.
- **Skenario implementasi:** Backup otomatis berjalan saat kasir menyimpan nota. Salinan database terbaca sebelum WAL terbaru dimerge; backup kehilangan transaksi terakhir atau berisi halaman yang tidak konsisten.
- **Dampak bisnis:** Backup “berhasil” tetapi tidak dapat dipulihkan dengan data lengkap.
- **Dampak integritas data:** Snapshot file tidak atomik terhadap penulisan.
- **Rekomendasi:** Gunakan `VACUUM INTO`/backup API SQLite, atau `wal_checkpoint(TRUNCATE)` di bawah kunci tulis; hentikan penulisan selama ekspor. Pada Android SQLCipher, pertahankan jalur ekspor sementara yang sudah ada.

---

# I. ALUR APLIKASI DAN ERROR

## FLW-01 — Startup tidak memiliki penanganan kegagalan

- **Kategori:** Alur aplikasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/main.dart`
- **Baris:** `1-25`
- **Bukti sumber:**
  ```dart
  Future<void> main() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('id_ID');
    await AppDatabase.instance.init();
    await seedDummyDataIfEnabled();
    await AppState.instance.load();
    BackupScheduler.instance.start();
    SyncScheduler.instance.start();
    runApp(const PusatkuApp());
  }
  ```
- **Alur sebab-akibat:** Seluruh inisialisasi dijalankan sebelum `runApp` tanpa `try/catch`, `runZonedGuarded`, atau layar error. Kegagalan database, sidecar versi, restore terputus, atau seed membuat `main` berhenti dan tidak ada UI yang dirender.
- **Skenario implementasi:** File database rusak atau `.schema_version` lebih baru. `_prepareSchemaUpgrade` melempar `StateError`; aplikasi menampilkan layar kosong/berhenti, tanpa jalan keluar selain menghapus data.
- **Dampak bisnis:** Aplikasi tidak dapat dibuka; pengguna kehilangan akses ke pembukuan dan tidak mendapat instruksi pemulihan.
- **Dampak integritas data:** Tidak ada kerusakan tambahan, tetapi data tidak dapat diakses/dipulihkan lewat UI.
- **Rekomendasi:** Bungkus inisialisasi dengan error boundary; tampilkan layar pemulihan (restore backup, ekspor diagnostik, buka mode aman) dan jangan menghapus database otomatis.

## FLW-02 — Kegagalan nota setelah simpan dilaporkan sebagai gagal simpan

- **Kategori:** UX / Error
- **Risiko:** LOW
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/screens/pos_screen.dart`
- **Baris:** `487-530`
- **Bukti sumber:**
  ```dart
  try {
    final id = await _createWithApproval(...);
    ...
    final detail = await AppDatabase.instance.recordDetail(id);
    ...
    if (detail != null) await _showReceipt(detail);
  } catch (error) {
    if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
  }
  ```
- **Alur sebab-akibat:** Nota disimpan lebih dulu, lalu detail dimuat dan struk ditampilkan. Kegagalan pada tahap setelah simpan (muat detail/cetak) masuk ke `catch` yang sama dan dilaporkan sebagai “Gagal menyimpan”.
- **Skenario implementasi:** Nota berhasil tersimpan, tetapi `recordDetail` gagal. Kasir melihat “Gagal menyimpan” dan mengulang; sistem mengembalikan nota lama (idempotensi), tetapi kasir dapat mengira transaksi belum tercatat.
- **Dampak bisnis:** Kebingungan dan potensi percobaan ganda; antrean pelanggan tertahan.
- **Dampak integritas data:** Data benar (idempoten), tetapi persepsi pengguna salah.
- **Rekomendasi:** Pisahkan `try` untuk simpan dan untuk struk; pesan setelah simpan sukses harus “Nota tersimpan, struk gagal dibuka” dengan tombol cetak ulang.

## FLW-03 — Tidak ada pemulihan database rusak/tidak kompatibel

- **Kategori:** Alur aplikasi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/ui/entry_gate.dart`
- **Baris:** `app_database.dart:301-343`, `app_database.dart:345-378`
- **Bukti sumber:**
  ```dart
  if (stored != null && stored > schemaVersion) {
    throw StateError('Versi skema ... tidak didukung.');
  }
  ...
  await _prepareSchemaUpgrade();
  ```
- **Alur sebab-akibat:** Versi lebih baru, file rusak, atau restore terputus melempar `StateError`. Tidak ada layar yang menangkap dan menawarkan restore/ekspor; `EntryGate` tidak pernah dirender karena `main` gagal lebih dulu.
- **Skenario implementasi:** Pengguna memasang APK versi lama setelah memakai versi baru; database memakai skema lebih baru. Aplikasi gagal start tanpa instruksi.
- **Dampak bisnis:** Pengguna terkunci dari data; dukungan harus menangani secara manual.
- **Dampak integritas data:** Data tetap ada tetapi tidak dapat diakses; risiko pengguna menghapus data untuk “memperbaiki”.
- **Rekomendasi:** Sediakan mode pemulihan saat startup: tampilkan versi DB, opsi restore backup, ekspor file mentah, dan konfirmasi sebelum tindakan destruktif.

---

# J. KEAMANAN

## SEC-01 — Sign-out lalu onboarding memungkinkan pengambilalihan owner

- **Kategori:** Autentikasi
- **Risiko:** CRITICAL
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/entry_gate.dart`, `pusatkupos/lib/ui/onboarding.dart`, `pusatkupos/lib/data/license_service.dart`
- **Baris:** `entry_gate.dart:74-96`, `onboarding.dart:96-107`, `onboarding.dart:323-358`, `license_service.dart:99-120`
- **Bukti sumber:**
  ```dart
  // signOutToOnboarding
  await SessionService.instance.clear();
  await PinService.instance.clear();
  await SecureStore.instance.delete('owner.enroll_token');
  ...
  // onboarding _startFree
  final ownerId = await LicenseService.instance.ensureOwner();
  ...
  await PinService.instance.setup(pin);
  await SessionService.instance.save(profile);
  ```
- **Alur sebab-akibat:** Sign-out menghapus sesi dan PIN, tetapi tidak menghapus database/`owner_identity`. Onboarding berikutnya memanggil `ensureOwner()`, yang mengembalikan owner yang sudah ada, lalu meminta PIN baru dan menyimpan sesi owner.
- **Skenario implementasi:** Karyudi memakai perangkat, menekan “Keluar”, lalu memilih “Mulai gratis” dan membuat PIN baru. Ia sekarang memiliki akses owner penuh ke seluruh pembukuan, termasuk backup, payroll, dan pengaturan.
- **Dampak bisnis:** Pengambilalihan penuh oleh siapa pun yang memegang perangkat; data dan kas dapat diekspor/diubah.
- **Dampak integritas data:** Tidak ada perubahan baris saat takeover, tetapi seluruh kontrol akses hilang.
- **Rekomendasi:** Sign-out harus meminta PIN owner sebelum mengizinkan onboarding ulang, atau menghapus/mengunci database; onboarding wajib mendeteksi `owner_identity` yang ada dan meminta kredensial owner, bukan membuat PIN baru.

## SEC-02 — Account service memakai aktor `owner` default tanpa verifikasi

- **Kategori:** Otorisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/account_service.dart`
- **Baris:** `118-190`, `326-380`, `389-430`
- **Bukti sumber:**
  ```dart
  Future<Map<String, Object?>> createAccount({
    ...
    String actor = 'owner',
  }) async {
    if (!await LicenseService.instance.isPremium()) { ... }
    ...
    await recordAudit(actor: actor, ...);
  ```
- **Alur sebab-akibat:** Layanan tidak menerima `Operator` dan tidak memanggil `Permissions.require`; `actor` adalah string yang dapat diisi pemanggil, default “owner”.
- **Skenario implementasi:** Jalur UI yang lupa memeriksa peran, atau pemanggilan service dari fitur baru, dapat membuat akun/reset password/PIN dan mencatat audit seolah dilakukan owner.
- **Dampak bisnis:** Pembuatan akun dan reset kredensial tidak terlindungi di lapisan bisnis; audit tidak dapat dipercaya.
- **Dampak integritas data:** `permission_audits.actor` dapat dipalsukan.
- **Rekomendasi:** Wajibkan `Operator actor` dan verifikasi `actor.isOwner` di service; turunkan label aktor dari objek, bukan parameter string bebas.

## SEC-03 — Supplier service tidak memiliki otorisasi sama sekali

- **Kategori:** Otorisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/supplier_service.dart`, `pusatkupos/lib/sync/sync_conflict_rules.dart`
- **Baris:** `supplier_service.dart:51-159`, `sync_conflict_rules.dart:169-186`
- **Bukti sumber:**
  ```dart
  Future<int> saveSupplier({
    int? id, required String nama, ... Future<...>? enqueue,
  }) async { ... }
  ```
  Tidak ada `Operator`, `Permissions`, `actor`, atau `requireEnabled` di file.
- **Alur sebab-akibat:** Siapa pun yang dapat memanggil service dapat menambah/mengubah/menghapus supplier dan relasi barang. Sync allow-list karyawan tidak memuat `supplier`, sehingga perubahan lokal tidak dikirim ke perangkat lain.
- **Skenario implementasi:** Karyawan mengubah data supplier di perangkatnya; perubahan tersimpan lokal tetapi tidak pernah tersinkron, sementara data supplier master tetap berbeda.
- **Dampak bisnis:** Data supplier dapat diubah tanpa izin dan menyebabkan divergensi antar perangkat.
- **Dampak integritas data:** Perubahan lokal tidak dapat direkonsiliasi melalui sync; konflik data senyap.
- **Rekomendasi:** Tambahkan `Operator actor`, izin `ubah_supplier`, dan entri `supplier` pada allow-list sync dengan aturan owner-only atau izin eksplisit.

## SEC-04 — Payroll tidak memeriksa aktor atau izin

- **Kategori:** Otorisasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/employee_service.dart`
- **Baris:** `283-370`
- **Bukti sumber:**
  ```dart
  Future<PayrollSummary> paySalary(String employeeSyncId, {...}) async {
    ...
    await _applyDebtPayment(txn, employeeSyncId, summary.deductionCents, hlc: hlc);
    ...
  ```
- **Alur sebab-akibat:** Tidak ada parameter aktor/izin; pembayaran gaji, pemotongan hutang, dan kas keluar dapat dijalankan tanpa otorisasi.
- **Skenario implementasi:** Fitur payroll dipanggil dari layar yang salah peran atau dari kode baru; gaji dibayar dan hutang karyawan dipotong tanpa persetujuan owner.
- **Dampak bisnis:** Pengeluaran kas dan pemotongan hak karyawan tanpa kontrol.
- **Dampak integritas data:** `salary_payments` tanpa aktor; `employee_debts.terbayar` berubah tanpa jejak penyetuju.
- **Rekomendasi:** Wajibkan aktor owner/izin `bayar_gaji`, catat aktor, dan tambahkan persetujuan untuk pembayaran di luar siklus.

## SEC-05 — UI fallback ke `Operator.owner` saat state kosong

- **Kategori:** Otorisasi UI
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/home_shell.dart`
- **Baris:** `273-289`
- **Bukti sumber:**
  ```dart
  Operator get _operator => AppState.instance.operator ?? Operator.owner;
  ```
- **Alur sebab-akibat:** Jika operator belum dimuat (startup, sesi rusak, refresh gagal), UI menganggap pengguna adalah owner dan menampilkan seluruh menu. Aktor yang diteruskan ke service juga menjadi owner.
- **Skenario implementasi:** `AppState.load()` gagal atau sesi kosong sementara; HomeShell tetap dirender dengan `_operator = Operator.owner`; pengguna dapat membuka menu owner dan menjalankan aksi yang memakai aktor itu.
- **Dampak bisnis:** Kontrol akses bergantung pada keberhasilan pemuatan state, bukan pada identitas nyata.
- **Dampak integritas data:** Aksi tercatat atas nama “Pemilik” meskipun dilakukan pengguna lain.
- **Rekomendasi:** Ganti fallback dengan state “tidak terautentikasi” yang memblokir UI dan service; jangan pernah default ke owner.

## SEC-06 — PIN legacy lemah dan PIN pendek tetap diterima

- **Kategori:** Autentikasi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/pin_service.dart`
- **Baris:** `22-30`, `52-96`
- **Bukti sumber:**
  ```dart
  Future<bool> verify(String pin) async {
    final result = await verifyDetailed(pin);
    return result == PinVerification.ok || result == PinVerification.weakLegacyPin;
  }
  ...
  final legacy = storedIterations == null;
  final valid = legacy ? _legacyHash(salt, pin) == hash : ...;
  ```
- **Alur sebab-akibat:** PIN lama tanpa iterasi diverifikasi dengan hash legacy; PIN < 6 digit mengembalikan `weakLegacyPin` yang tetap dianggap berhasil. Tidak ada paksaan mengganti PIN pendek.
- **Skenario implementasi:** Perangkat lama memiliki PIN 4 digit; pengguna terus memakainya karena verifikasi mengembalikan sukses.
- **Dampak bisnis:** PIN mudah ditebak; keamanan perangkat lemah.
- **Dampak integritas data:** Tidak langsung, tetapi mempermudah akses tidak sah.
- **Rekomendasi:** Setelah verifikasi legacy/lemah, paksa layar ganti PIN sebelum mengizinkan akses; tolak PIN < 6 digit untuk semua jalur.

## SEC-07 — Database viewer dibuka read-write; cek viewer tidak konsisten

- **Kategori:** Otorisasi
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/app_database.dart`, `pusatkupos/lib/auth/permissions.dart`, `pusatkupos/lib/auth/operator.dart`
- **Baris:** `app_database.dart:98-114`, `permissions.dart:20-30`, `operator.dart:32`
- **Bukti sumber:**
  ```dart
  // openViewerDatabase
  await _open(); // membuka database dengan mode baca-tulis
  ...
  static bool can(Operator? operator, String permission) {
    if (operator == null) return false;
    if (operator.isOwner) return true;
    return operator.permissions.contains(permission);
  }
  // Operator
  bool can(String permission) => isOwner ? true : (isViewer ? false : permissions.contains(permission));
  ```
- **Alur sebab-akibat:** Database viewer dibuka seperti database biasa (read-write) dan `Permissions.can` tidak menolak viewer; hanya `Operator.can` yang menolak. Jalur yang memakai `Permissions.require` dapat mengizinkan viewer jika permission-nya ada.
- **Skenario implementasi:** Profil viewer memiliki daftar permission dari sesi; layanan yang memakai `Permissions.require` (bukan `Operator.can`) dapat menjalankan aksi tulis pada database viewer.
- **Dampak bisnis:** Mode “hanya baca” tidak dijamin di lapisan service.
- **Dampak integritas data:** Database ringkasan dapat berubah; laporan owner tidak lagi murni.
- **Rekomendasi:** Buka viewer dengan `readOnly: true`, dan satukan pemeriksaan izin di `Permissions.can` (tolak viewer secara eksplisit).

## SEC-08 — Ekspor ringkasan owner tanpa pemeriksaan izin

- **Kategori:** Data sensitif
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/screens/settings_screen.dart`, `pusatkupos/lib/data/owner_summary_service.dart`
- **Baris:** `settings_screen.dart:876-894`, `owner_summary_service.dart:20-72`
- **Bukti sumber:**
  ```dart
  onPressed: () async {
    final path = await OwnerSummaryService.instance.export();
    ...
  },
  ```
- **Alur sebab-akibat:** Tombol ekspor tidak memeriksa `AppState.can(...)` atau peran owner. `OwnerSummaryService` menandatangani payload berisi `license_token`, daftar perangkat, dan toko dengan kunci privat owner di perangkat.
- **Skenario implementasi:** Karyawan dengan akses menu Pengaturan menekan ekspor dan menyimpan token lisensi serta daftar perangkat.
- **Dampak bisnis:** Informasi lisensi/perangkat dapat disalahgunakan; data toko terekspos.
- **Dampak integritas data:** Tidak ada perubahan data, tetapi rahasia keluar dari perangkat.
- **Rekomendasi:** Batasi ekspor ke owner (`actor.isOwner`), minta PIN owner, dan jangan menyertakan token lisensi penuh dalam ekspor.

## SEC-09 — Sesi hilang disintesis menjadi owner dari PIN

- **Kategori:** Autentikasi
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/ui/entry_gate.dart`, `pusatkupos/lib/data/pin_service.dart`
- **Baris:** `entry_gate.dart:31-44`, `pin_service.dart:32-40`
- **Bukti sumber:**
  ```dart
  if (profile == null && AppState.instance.pinConfigured) {
    final ownerId = await LicenseService.instance.ownerId() ?? '';
    final premium = await LicenseService.instance.isPremium();
    profile = SessionProfile(
      mode: premium ? 'premium' : 'free',
      ownerId: ownerId,
      nama: 'Pemilik',
      role: 'owner',
      ...
    );
  }
  ```
- **Alur sebab-akibat:** Bila sesi tidak dapat dimuat tetapi PIN terkonfigurasi, aplikasi membuat profil owner sintetis. PIN karyawan disimpan di guard yang sama (`auth.pin_hash`/`session.pin_*`), sehingga PIN karyawan dapat membuka profil owner.
- **Skenario implementasi:** File sesi hilang/terhapus (bukan sign-out), mis. secure storage dibersihkan atau upgrade gagal. Karyawan memasukkan PIN-nya dan masuk sebagai “Pemilik” dengan akses penuh.
- **Dampak bisnis:** Eskalasi hak akses tanpa kredensial owner.
- **Dampak integritas data:** Aksi tercatat atas nama Pemilik.
- **Rekomendasi:** Jangan menyintesis owner dari keberadaan PIN; simpan mode/peran di storage yang sama dengan PIN, atau verifikasi ulang terhadap `owner_identity` dan minta kredensial owner.

---

# K. FEATURE TOGGLE

## FEAT-01 — Hanya pembelian yang menegakkan feature flag di service

- **Kategori:** Feature toggle
- **Risiko:** HIGH
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/feature_flags.dart`, `pusatkupos/lib/data/purchase_service.dart`, `pusatkupos/lib/ui/home_shell.dart`
- **Baris:** `feature_flags.dart:137-152`, `purchase_service.dart:97`, `home_shell.dart:279-289`
- **Bukti sumber:**
  ```dart
  void requirePurchaseDebt() {
    requireEnabled(featureSupplierHub);
    if (!isEnabled(featurePurchaseDebt)) { throw StateError(...); }
  }
  ```
  Pencarian `requireEnabled` hanya menemukan pemakaian di `purchase_service.dart`.
- **Alur sebab-akibat:** Flag `estimasi`, `order_kerja`, `followup`, `unit_kendaraan`, dan `whatsapp` hanya memengaruhi menu (`_featureAllows` untuk indeks 5, 8, 9) dan beberapa validasi UI. Service estimasi/order/followup/unit tidak memanggil `requireEnabled`.
- **Skenario implementasi:** Owner mematikan fitur “Estimasi”. Menu hilang, tetapi layar lain atau pemanggilan `OrderService.createEstimate` tetap membuat estimasi; data baru masuk meski fitur OFF.
- **Dampak bisnis:** Saklar fitur tidak dapat diandalkan; data dari fitur yang “dimatikan” tetap bertambah.
- **Dampak integritas data:** Data historis dan baru bercampur; laporan tidak dapat memisahkan periode fitur aktif.
- **Rekomendasi:** Panggil `requireEnabled` di setiap service fitur (create/update/convert/remote), bukan hanya UI; tambahkan pengujian bahwa semua jalur akses ditolak saat OFF.

## FEAT-02 — Cache flag fallback ke `true` sebelum load/pindah toko

- **Kategori:** Feature toggle
- **Risiko:** MEDIUM
- **Status validitas:** CONFIRMED
- **File:** `pusatkupos/lib/data/feature_flags.dart`
- **Baris:** `100-110`
- **Bukti sumber:**
  ```dart
  bool isEnabled(String key) {
    final definition = featureDefinition(key);
    final fallback = definition?.defaultEnabled ?? true;
    if (_storeId != _activeStoreId) return fallback;
    return _cache[key] ?? fallback;
  }
  ```
- **Alur sebab-akibat:** Sebelum `load()` atau saat toko aktif berubah, semua flag mengembalikan `defaultEnabled` (true). Fitur yang seharusnya OFF dianggap ON.
- **Skenario implementasi:** Owner berpindah ke toko yang mematikan fitur pembelian. Sebelum cache dimuat, layar menampilkan/mengizinkan fitur; aksi dapat dimulai sebelum `load` selesai.
- **Dampak bisnis:** Fitur OFF dapat dipakai sesaat setelah pindah toko/startup.
- **Dampak integritas data:** Data dibuat di periode ketika saklar seharusnya OFF.
- **Rekomendasi:** Gunakan fallback `false` saat cache belum dimuat untuk toko aktif, atau blokir UI sampai `load()` selesai; sediakan status “memuat fitur”.

---

# L. RINGKASAN PEMETAAN DOMAIN

| Domain | ID |
|---|---|
| Penjualan | SAL-01..SAL-08 |
| Pembelian | PUR-01..PUR-07 |
| Retur/pembatalan | RET-01..RET-03 |
| Persediaan | INV-01..INV-06 |
| Keuangan/pajak | FIN-01..FIN-07 |
| Lintas modul | BIZ-01 |
| Database/sinkronisasi | DB-01..DB-11 |
| Backup/restore | BAK-01..BAK-02 |
| Alur/error | FLW-01..FLW-03 |
| Keamanan | SEC-01..SEC-09 |
| Feature toggle | FEAT-01..FEAT-02 |
