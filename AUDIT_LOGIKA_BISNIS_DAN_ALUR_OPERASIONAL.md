# Audit Logika Bisnis, Kelengkapan, dan Alur Operasional

**Aplikasi:** PusatkuPOS (Flutter offline-first + relay Dart/PostgreSQL)
**Pembanding:** POS bengkel Python di `D:/Downloads/aplikasiposbengkel`
**Tanggal audit:** 5 November 2026
**Sifat audit:** Baca kode menyeluruh. **Tidak ada kode yang diubah.** Tidak ada dependency yang dipasang. Tidak ada test otomatis yang dijalankan (pengujian dilakukan manual oleh pemilik).

---

## 1. Ringkasan Eksekutif

PusatkuPOS sudah memiliki kerangka POS bengkel yang lengkap: master pelanggan/unit, katalog jasa, stok, estimasi berversi, work order, transaksi dengan diskon per baris dan batas modal, retur append-only, void, garansi, piutang, payroll, follow-up WhatsApp, laporan, struk yang dapat dikustomisasi, backup terenkripsi, dan sinkronisasi multi-perangkat.

Namun ada **5 masalah P1 yang menyentuh uang, stok, atau sinkronisasi** dan harus diperbaiki sebelum dipakai multi-perangkat atau untuk tutup buku:

1. Void tetap diizinkan setelah retur, sehingga stok dikembalikan dua kali dan kas direfund penuh.
2. Retur tidak mengurangi piutang, tidak mencatat REFUND, dan tidak mengubah status bayar.
3. Unit bisa ditandai diambil walau masih ada sisa tagihan.
4. Pelanggan/unit yang dibuat lewat jalan pintas di layar POS tidak masuk outbox sinkronisasi.
5. Konversi estimasi menjadi nota kehilangan relasi pelanggan, unit, dan work order.

Sisanya adalah P2/P3: konsistensi laporan (diskon dan komisi), idempotensi pelunasan, aturan relay (snapshot, ack, undangan, storage), follow-up, dan beberapa fitur yang hanya ada di versi Python.

**Kesimpulan kesiapan:** layak untuk operasi harian satu perangkat. **Belum layak** untuk multi-perangkat dan tutup buku tanpa memperbaiki P1-01 sampai P1-05.

---

## 2. Daftar Temuan P1

| ID | Temuan | Dampak utama | Bukti |
|---|---|---|---|
| P1-01 | Void setelah retur tetap diizinkan | Stok dobel, kas lebih-refund, piutang retur tidak beres | `pusatkupos/lib/data/app_database.dart:2321` |
| P1-02 | Retur tidak menyentuh pembayaran/piutang | Piutang dan kas tidak mencerminkan barang yang dikembalikan | `pusatkupos/lib/data/sale_return_service.dart:56` |
| P1-03 | Ambil unit tanpa cek sisa tagihan | Unit keluar bengkel walau piutang masih ada | `pusatkupos/lib/data/app_database.dart:2086` |
| P1-04 | Pelanggan/unit quick-add di POS tidak di-enqueue | Master data tidak ikut sinkronisasi inkremental | `pusatkupos/lib/ui/screens/pos_screen.dart:212`, `:245` |
| P1-05 | Konversi estimasi ke nota kehilangan relasi | Nota tanpa pelanggan/unit, work order tidak tertutup | `pusatkupos/lib/data/order_service.dart:538` |
| P1-06 | Perangkat karyawan boleh mengunggah snapshot toko | Karyawan dapat menimpa cadangan seluruh toko | `relay/lib/server.dart:1297` |

---

## 3. Detail Temuan P1

### P1-01 Void setelah retur: stok kembali dua kali, kas direfund penuh

**Perilaku saat ini**

`voidRecord` langsung memproses void tanpa memeriksa apakah nota sudah memiliki retur:

- Stok dikembalikan untuk **seluruh** `service_parts` nota asal (`app_database.dart:2341-2378`), bukan sisa yang belum diretur.
- Refund dihitung dari `SUM(nominal)` seluruh pembayaran `PELUNASAN` (`app_database.dart:2379-2407`), bukan dari nilai nota setelah retur.
- Status diubah menjadi `VOID`, tetapi `sisa_bayar` tidak dinolkan (`app_database.dart:2408-2418`).

**Pembanding POS bengkel normal (Python)**

`services/void_return_service.py:69` menolak void jika `retur_count > 0` dengan pesan bahwa nota yang sudah memiliki retur tidak dapat di-void. Pada retur, Python juga menyesuaikan pembayaran (`refund_excess`, `services/void_return_service.py:361-369`) sehingga tidak ada saldo piutang negatif.

**Dampak**

- Retur sudah mengembalikan stok; void mengembalikan stok yang sama sekali lagi. Stok fisik di sistem menjadi lebih besar dari kenyataan.
- Pelanggan menerima refund penuh padahal sebagian barang sudah dikembalikan dan nilainya sudah dikreditkan.
- Nota berstatus `VOID` tetapi `sisa_bayar` lama masih tersimpan. Dashboard dan daftar piutang mengecualikan `VOID` (`app_database.dart:2127`, `:2765`), tetapi detail nota tetap menampilkan sisa yang menyesatkan.

**Rekomendasi**

Tolak void bila ada retur aktif, atau hitung ulang restock dan refund berdasarkan kuantitas yang belum diretur. Nolkan `sisa_bayar`/`total_dibayar` secara konsisten saat void.

---

### P1-02 Retur tidak mengurangi piutang, kas, dan status bayar

**Perilaku saat ini**

`SaleReturnService.createReturn` menghitung `net = subtotal - diskon_alokasi`, membentuk `refund`, menulis `sale_returns`/`sale_return_items`, mengembalikan stok, dan mencatat `stock_movements` MASUK (`sale_return_service.dart:56-205`). Tidak ada:

- update `service_records.sisa_bayar`, `total_dibayar`, atau `status_bayar`;
- baris `service_payments` berjenis `REFUND`;
- penyesuaian komisi mekanik.

**Pembanding Python**

`services/payment_service.py:29-43` menghitung `record_netto = total_servis - total_retur` dan `record_sisa = netto - total_dibayar`. Retur juga membuat baris REFUND melalui `refund_excess` (`void_return_service.py:361-369`). Jadi piutang, kas, dan status bayar selalu mengikuti nilai neto.

**Dampak**

- Nota yang seluruhnya diretur masih tampil sebagai piutang penuh.
- Laporan kas tidak mengurangi uang yang dikembalikan ke pelanggan, sehingga kas fisik dan laporan berbeda.
- Pemeriksaan “unit boleh diambil” memakai `sisa_bayar` lama, sehingga unit bisa tertahan padahal nilai netonya sudah nol (dan sebaliknya).
- Komisi mekanik tetap dihitung dari nilai sebelum retur.

**Rekomendasi**

Satu transaksi retur harus: hitung neto baru, buat REFUND bila sudah ada pembayaran, perbarui `total_dibayar`/`sisa_bayar`/`status_bayar`, lalu sesuaikan komisi. Ini juga prasyarat untuk P1-03.

---

### P1-03 Unit bisa diambil walau masih ada sisa tagihan

**Perilaku saat ini**

`markUnitTaken` hanya mengubah `diambil_at` selama `unit_ditinggal = 1` (`app_database.dart:2086-2104`). Tidak ada pemeriksaan `sisa_bayar`. Tombol di riwayat juga hanya mensyaratkan unit masih di bengkel (`history_screen.dart:341-368`).

**Pembanding Python**

`services/pengerjaan_service.py:234-236` menolak status `SUDAH_DIAMBIL` selama `record_sisa(marker.service_record) > 0`, dengan pesan “Unit belum bisa ditandai diambil selama masih ada sisa tagihan.”

**Dampak**

Praktik bengkel normal: unit tidak diserahkan sebelum tagihan lunas (kecuali kebijakan khusus). Aplikasi saat ini membolehkan unit keluar dengan piutang berjalan, sehingga penagihan menjadi jauh lebih sulit dan tidak ada jejak jaminan.

**Rekomendasi**

Tolak pengambilan bila `sisa_bayar > 0`; sediakan jalur override khusus pemilik dengan alasan dan audit log bila kebijakan toko mengizinkan.

---

### P1-04 Pelanggan/unit dari jalan pintas POS tidak ikut sinkronisasi

**Perilaku saat ini**

`pos_screen.dart:212-266` memanggil `AppDatabase.addCustomer` dan `addUnit` tanpa parameter `enqueue`. Padahal kedua fungsi hanya meng-enqueue bila callback diberikan (`app_database.dart:585-618`, `:751-789`). Sebagai pembanding, layar pelanggan yang benar mengirim `enqueueCustomer`/`enqueueUnit` (`customers_screen.dart:48-56`, `:459-468`).

**Dampak**

- Pelanggan/unit baru hanya ada di perangkat kasir.
- Perangkat lain, relay, dan pemulihan inkremental tidak menerima master data tersebut.
- Nota yang memuat snapshot pelanggan tetap tersinkron, tetapi master pelanggan/unit tidak, sehingga muncul duplikat atau data yatim di perangkat lain.
- Data baru terbawa hanya jika snapshot penuh diunggah/dipulihkan.

**Rekomendasi**

Samakan jalur: quick-add di POS wajib memakai `enqueueCustomer`/`enqueueUnit`, atau pindahkan enqueue ke dalam service agar tidak bisa terlewat.

---

### P1-05 Konversi estimasi ke nota kehilangan pelanggan, unit, dan work order

**Perilaku saat ini**

`EstimateRecord` menyimpan `customerSyncId`, `unitSyncId`, dan `workOrderSyncId` (`order_service.dart:37-96`). Tetapi `convertEstimateToNote` memanggil `createTransaction` tanpa `customerId`, `unitId`, maupun `workOrderSyncId` (`order_service.dart:538-555`), meskipun `createTransaction` menerima ketiganya (`app_database.dart:1183-1218`).

**Dampak**

- Nota hasil konversi tidak memiliki pelanggan/unit.
- Nomor HP pelanggan tidak muncul di struk karena lookup struk memakai join unit (`receipt_service.dart:69-81`).
- Follow-up dan laporan per pelanggan/unit tidak mengenali nota tersebut.
- Work order tetap terbuka karena `work_orders.nota_sync_id` hanya diisi bila `workOrderSyncId` dikirim (`app_database.dart:1693-1708`).

**Rekomendasi**

Resolusi `customerSyncId`/`unitSyncId` menjadi ID lokal dan teruskan `workOrderSyncId` saat konversi. Tambahkan validasi bahwa nota hasil konversi selalu memiliki pelanggan/unit seperti nota POS biasa.

---

### P1-06 Perangkat karyawan dapat mengunggah snapshot toko

**Perilaku saat ini**

`_createSnapshot` hanya memblokir `kind == 'viewer'` (`relay/lib/server.dart:1297-1312`). Perangkat `employee` lolos selama putaran sinkron selesai dan `store_seq` cocok. Snapshot kemudian di-upsert sebagai cadangan resmi toko.

**Dampak**

Snapshot adalah salinan penuh data toko (termasuk harga, pelanggan, transaksi). Karyawan yang perangkatnya disusupi dapat mengganti cadangan resmi dengan data buatan. Saat pemulihan, data palsu itu yang dipakai. Ini pelanggaran pemisahan wewenang: karyawan hanya boleh mengirim entitas operasional, bukan mengganti seluruh keadaan toko.

**Rekomendasi**

Batasi unggah snapshot ke perangkat `owner` (atau pemilik dengan izin eksplisit), dan verifikasi ulang tanda tangan terhadap kunci owner, bukan hanya kunci perangkat.

---

## 4. Temuan P2

| ID | Temuan | Bukti | Ringkasan |
|---|---|---|---|
| P2-01 | Laba tidak mengurangi diskon; komisi tidak neto retur | `app_database.dart:2507-2632`, `:1746-1797`, `reports_screen.dart:217-274` | Laba memakai subtotal sebelum diskon. Komisi memakai `harga - modal` sebelum diskon dan tidak dikurangi retur. Python juga memakai laba sebelum diskon, tetapi komisi Python sudah neto retur (`services/employee_service.py:371-430`). |
| P2-02 | Koreksi nota tidak bisa dibuat dari UI dan tidak memengaruhi uang | `nota_adjustment_service.dart:57`, grep UI | Service `create`/`createSelisih` tidak dipanggil layar mana pun. Koreksi hanya ditampilkan di riwayat/laporan; `sisa_bayar`, pembayaran, dan total laporan tidak berubah. |
| P2-03 | Pelunasan piutang tidak idempoten | `app_database.dart:2433-2505`, `history_screen.dart:274-305` | `requestId` diterima tetapi tidak dicek/di-unique-kan. UI tidak mengirim `requestId`. Ketukan ganda dapat mencatat dua pelunasan. |
| P2-04 | Kuota dan status follow-up terpakai sebelum pesan benar-benar terkirim | `followup_service.dart:727-790` | Kuota dikonsumsi dan status menjadi `SUDAH_FOLLOWUP` + `no_response_count` naik saat tautan WhatsApp dibuka, bukan saat pesan terkirim. Tidak ada pembeda “dibuka” dan “terkirim”. |
| P2-05 | Ack putaran dan cursor menerima `last_seq` sembarang | `relay/lib/server.dart:935-960`, `:1240-1295` | `GREATEST` tanpa batas `latest_seq`. Putaran bisa dianggap selesai padahal perangkat belum benar-benar menerapkan data; snapshot yang belum lengkap lalu boleh diunggah. Perangkat yang melapor salah juga dapat kehilangan amplop yang belum ia terapkan. |
| P2-06 | Klaim undangan tanpa validasi akun/toko dan tanpa rate limit | `relay/lib/server.dart:1414-1480` | Akun nonaktif tetap bisa dipasangkan; `store_id` undangan tidak divalidasi terhadap toko akun/owner; tidak ada pembatasan percobaan. |
| P2-07 | TTL undangan tidak dibatasi, toko tidak divalidasi | `relay/lib/server.dart:1936-1977` | `ttl_minutes` bebas (termasuk negatif/sangat besar); `store_id` bebas. |
| P2-08 | Setiap login karyawan membuat baris perangkat baru | `relay/lib/server.dart:1631-1660`, `employee_auth_service.dart:105-116` | Perangkat lama tetap aktif. Daftar perangkat membengkak dan pemangkasan amplop bisa macet. |
| P2-09 | Pemangkasan amplop memakai SEMUA perangkat aktif | `relay/lib/server.dart:805-841` | Perangkat karyawan lama yang tidak pernah ack membuat `MIN(cursor)` tidak pernah tercapai, amplop menumpuk. Pemilihan perangkat putaran hanya mengambil perangkat terbaru per akun (`:1075-1118`), sehingga perangkat lama tidak pernah menyelesaikan putaran. |
| P2-10 | Tabrakan `seq` dapat menghasilkan “sukses palsu” | `relay/lib/server.dart:690-745` | Bila `INSERT ... ON CONFLICT DO NOTHING` kena unique `(store, sender, seq)` dengan idempotency key berbeda, `SELECT` berikutnya kosong dan server mengembalikan id karangan. Klien menandai outbox `sent` padahal baris tidak ada. |
| P2-11 | Push massal akun memaksa semua karyawan ganti password | `premium_screen.dart:149-163`, `relay/lib/server.dart:1864-1866` | Klien selalu mengirim hash; server menetapkan `must_change = true` setiap kali hash dikirim. |
| P2-12 | Nomor HP struk hilang untuk nota tanpa unit | `receipt_service.dart:69-81` | `JOIN vehicle_or_units` (inner join). Nota sparepart-only tanpa unit tidak menemukan pelanggan, sehingga WhatsApp/struk kehilangan nomor. |
| P2-13 | Mapping supplier dan perubahan kompensasi tidak di-enqueue | `supplier_service.dart:165-201`, `employee_service.dart:71-133` | Perubahan hanya lokal sampai snapshot penuh berikutnya. |
| P2-14 | Jumlah part di POS hanya bilangan bulat | `pos_screen.dart:1622-1639` | Stok mendukung `jumlah_milli` dan desimal (`stock_screen.dart:83-84`), tetapi POS membatasi qty integer, sehingga part seperti oli/pelumas tidak bisa dijual 0,5. |
| P2-15 | Ringkasan viewer bisa diterima dari tanda tangan sendiri | `owner_viewer.dart:139-190`, `license_verifier.dart:7` | Bila `serverLicensePublicKey` kosong (build tanpa `--dart-define`), ringkasan yang ditandatangani viewer sendiri diterima. Hanya memengaruhi tampilan viewer, tetapi tetap melemahkan verifikasi. |
| P2-16 | Estimasi tidak punya aksi revisi/batal di UI | `estimates_screen.dart:553-564` | Versi/revisi sudah ada di service, tetapi detail estimasi hanya menyediakan “Tutup” dan “Jadikan nota”. Estimasi kedaluwarsa/aktif tidak bisa dibatalkan dari layar. |
| P2-17 | `sisa_bayar` tidak dinolkan saat void | `app_database.dart:2408-2418` | Laporan piutang mengecualikan `VOID`, tetapi detail nota tetap menampilkan sisa lama. |

---

## 5. Temuan P3 dan Catatan Kecil

- Pembayaran sebagian selalu diberi label `PELUNASAN` (`app_database.dart:1652-1665`). Tidak ada label DP/uang muka.
- `salary_payments.cicilan_hutang` diisi **sisa utang setelah potong gaji**, bukan jumlah cicilan yang dibayar (`employee_service.dart:307-324`, `:457-495`). Kolom tidak dipakai di tempat lain, tetapi namanya menyesatkan.
- Follow-up yang sudah `SUDAH_BAYAR` tetap tampil di daftar “semua” karena filter hanya mengecualikan `ARSIP` (`followup_service.dart:549-573`).
- Tombol void/retur/pelunasan memakai izin `void`; tidak ada pemisahan izin retur vs void di UI.
- Batas toko sudah ditegakkan (`store_service.dart:70-110`), jadi tidak lagi menjadi temuan.
- Viewer sudah mengirim ack (`owner_viewer.dart:278-300`), sehingga macetnya pemangkasan berasal dari perangkat karyawan yatim, bukan viewer.
- `data_response` dan `day_digest` memang diizinkan untuk karyawan; bukan bug.

---

## 6. Matriks Kelengkapan: Flutter vs Python Bengkel

| Fitur | PusatkuPOS (Flutter) | Python bengkel | Catatan |
|---|---|---|---|
| Pelanggan + unit kendaraan | Ada | Ada | Flutter mewajibkan HP unik; unit mendukung radiator. |
| Katalog jasa + batas modal | Ada | Ada | Flutter punya validasi harga di bawah modal + PIN owner. |
| Stok + pergerakan | Ada | Ada | Flutter mendukung desimal; POS memakai desimal hingga 3 digit (P2-14). |
| Supplier + mapping supplier | Ada | Ada | Mapping Flutter ikut sinkronisasi (P2-13). |
| Barcode/scan produk | Tidak ada | Ada | Flutter hanya scan printer. |
| Estimasi + versi revisi | Ada | Ada (lebih sederhana) | Flutter lebih kaya; aksi revisi/batal tersedia (P2-16). |
| Work order + antrian harian | Ada | Ada | Flutter punya status log dan nomor antrian. |
| POS jasa + part + diskon per baris | Ada | Ada | Alokasi diskon dilakukan per baris. |
| Uang muka (DP) eksplisit | Sebagian | Ada | Pembayaran sebagian kini berlabel `DP`; rencana angsuran terjadwal belum ada. |
| Rencana bayar/angsuran terjadwal | Tidak ada | Ada | Python punya `rencana_bayar`. |
| Jatuh tempo piutang | Ada | Ada | Flutter punya banner dan daftar lewat tempo. |
| Pelunasan bertahap | Ada | Ada | Flutter belum idempoten. |
| Retur barang/jasa | Ada | Ada | Flutter belum menyesuaikan kas/piutang. |
| Void nota | Ada | Ada | Flutter belum memblokir void setelah retur. |
| Garansi servis | Ada | Ada | Klaim + masa berlaku + syarat. |
| Garansi tukar barang | Tidak ada | Ada | Python punya `garansi_tukar_hari`. |
| Janji ambil unit | Tidak ada | Ada | Python punya `janji_ambil` + peringatan. |
| Ambil unit wajib lunas | Tidak ada | Ada | Temuan P1-03. |
| Follow-up WhatsApp | Ada | Ada | Flutter punya kuota dan penggabungan pesan. |
| Payroll komisi + gaji + utang | Ada | Ada | Komisi Flutter belum neto retur. |
| Laporan harian/periode | Ada | Ada | Flutter: omzet, diskon, laba, komisi, gaji, kas, tipe, koreksi, estimasi. |
| Laporan semua waktu | Tidak ada | Ada | Python `all_time_report`. |
| Laporan part terjual/grup part | Tidak ada | Ada | Python `sold_parts_report`, `part_groups_report`. |
| Ekspor XLSX/CSV | Tidak ada | Ada | Flutter hanya backup JSON/ZIP terenkripsi. |
| Struk kustom (logo, blok, 58/80, WA) | Ada (lebih kaya) | Terbatas | Flutter unggul di editor struk. |
| Cetak Bluetooth/network/USB | Ada | Tergantung platform | Flutter punya adapter BLE, classic, network. |
| Backup terenkripsi portabel | Ada | SQLite/XLSX/CSV | Flutter format 3: ZIP per toko, AES-GCM, SHA-256. |
| Multi-toko | Ada | Tidak jelas | Batas toko premium ditegakkan. |
| Sinkronisasi multi-perangkat | Ada | Tidak ada | Relay + amplop terenkripsi + snapshot + putaran. |
| Mode viewer read-only | Ada | Tidak ada | Viewer tidak bisa mengirim amplop. |
| Koreksi nota append-only | Ada (service) | Tidak ada | Belum ada UI dan belum memengaruhi uang. |
| Audit izin (void, diskon, koreksi) | Ada | Sebagian | Flutter mencatat `permission_audits`. |

---

## 7. Urutan Operasional Baku (dari Menambah Pelanggan)

Urutan ini mengikuti alur yang benar untuk bengkel, sekaligus menandai titik yang perlu diperbaiki.

### Tahap 0 — Persiapan toko dan perangkat

1. Isi identitas toko: nama, alamat, telepon, tagline (`bengkel.*`).
2. Aktifkan premium dan identitas owner (kunci owner, lisensi).
3. Daftarkan perangkat owner ke relay (token pendaftaran, kunci perangkat, kunci toko).
4. Buat akun karyawan beserta peran dan izin (`void`, `diskon`, `koreksi`, `lihat_laporan`, `setujui`).
5. Pasangkan perangkat karyawan melalui kode undangan.
6. Pasang perangkat viewer bila diperlukan (hanya baca ringkasan).
7. Atur pajak/biaya lain, template struk, printer, dan pengaturan follow-up.

### Tahap 1 — Master data

8. **Tambah pelanggan**: nama, nomor HP (wajib, unik setelah normalisasi), alamat, consent WhatsApp, do-not-contact.
9. **Tambah unit pelanggan**: jenis unit, nopol, merek/tipe, jenis mobil, tahun, nomor rangka/mesin, tipe radiator.
10. **Tambah jasa**: deskripsi, harga jual, batas modal, interval servis.
11. **Tambah supplier**, lalu **tambah sparepart**: nama, satuan, harga modal, harga jual, stok awal, stok minimum, flag desimal.
12. **Petakan supplier ke sparepart** (mapping multi-supplier).

> Catatan audit: pelanggan/unit yang dibuat dari tombol cepat di layar POS tidak ikut sinkron (P1-04). Gunakan menu Pelanggan sampai diperbaiki.

### Tahap 2 — Estimasi dan work order (opsional)

13. Buat **estimasi**: pilih pelanggan + unit, tambah jasa/part, tetapkan masa berlaku.
14. Bila berubah, buat **revisi estimasi** (versi baru; versi lama tetap tersimpan).
15. Buat **work order**: keluhan, mekanik, prioritas, nomor antrian harian.
16. Ubah status pengerjaan (antri → dikerjakan → selesai) dengan catatan.
17. Estimasi aktif dapat **dijadikan nota**.

> Catatan audit: konversi sudah membawa pelanggan/unit/work order (P1-05) dan detail estimasi kini punya aksi Revisi/Batalkan (P2-16).

### Tahap 3 — Transaksi POS

18. Buka POS, pilih **pelanggan** dan **unit** (wajib; kecuali mode sparepart-only).
19. Tambah **jasa** dan **part**. Qty part mendukung desimal hingga 3 digit (mis. 0,5 L) sejak P2-14.
20. Terapkan **diskon** (per baris, dialokasikan ke item). Bila harga jatuh di bawah batas modal, minta PIN owner atau persetujuan penanggung jawab.
21. Pilih **metode bayar**: CASH atau TRANSFER.
22. Isi **jumlah dibayar**:
    - penuh → status `LUNAS`;
    - sebagian → status `KREDIT`, sisa menjadi piutang.
23. Isi keluhan, mekanik, garansi, unit ditinggal, dan catatan.
24. Simpan nota. Sistem menulis nota, item, pembayaran, pergerakan stok, komisi, audit diskon, dan outbox sinkronisasi.

> Catatan audit: pembayaran sebagian berlabel `DP`, pelunasan penuh `PELUNASAN` (P3). Rencana angsuran terjadwal belum ada.

### Tahap 4 — Struk dan pengiriman

25. Pilih ukuran struk 58/80 mm dan template.
26. Cetak ke printer Bluetooth/network/USB, atau simpan/lihat pratinjau.
27. Kirim struk ke WhatsApp pelanggan (bila consent dan nomor tersedia).

> Catatan audit: nota tanpa unit kehilangan nomor HP karena inner join (P2-12).

### Tahap 5 — Piutang dan follow-up

28. Buka daftar piutang; lihat sisa, jatuh tempo, dan status lewat tempo.
29. Catat **pelunasan bertahap** (CASH/TRANSFER). Sisa dan status bayar diperbarui.
30. Buka **follow-up WhatsApp**: pilih pelanggan/unit, lihat pesan yang digabung, kirim.
31. Catat hasil: akan datang, masih kendala, janji bayar, sudah bayar, atau arsip.
32. Piutang hanya keluar dari daftar lewat pelunasan penuh, void, atau mekanisme arsip yang diizinkan.

> Catatan audit: pelunasan belum idempoten (P2-03); kuota follow-up terpakai saat tautan dibuka (P2-04).

### Tahap 6 — Pengambilan unit dan garansi

33. Setelah pekerjaan selesai dan pembayaran lunas, tandai **unit diambil**.
34. Catat **klaim garansi**: tanggal klaim, status, catatan syarat.
35. Bila unit dititipkan, pantau status “masih di bengkel” vs “sudah diambil”.

> Catatan audit: pengambilan tidak dicek terhadap sisa tagihan (P1-03).

### Tahap 7 — Retur, void, koreksi

36. **Retur**: pilih item jasa/part, qty, dan alasan. Sistem mengembalikan stok part dan mencatat retur append-only.
37. **Void**: hanya untuk nota yang salah total; wajib alasan dan izin.
38. **Koreksi nota**: mengubah nilai nota tanpa mengubah nota asli (append-only).

> Catatan audit: retur belum mengurangi piutang/kas (P1-02); void setelah retur masih diizinkan (P1-01); koreksi belum ada UI (P2-02).

### Tahap 8 — Tutup buku

39. Buka **Laporan** harian/periode: omzet jasa/part, diskon, total, retur, penjualan neto, modal, laba kotor, komisi, gaji, laba setelah komisi & gaji.
40. Periksa **kas per metode** dan **piutang**.
41. Periksa **estimasi aging** dan daftar koreksi.
42. Proses **payroll**: komisi periode, gaji pokok, bonus, potongan utang karyawan, lalu bayar.
43. Ekspor/cetak laporan bila diperlukan.

> Catatan audit: laba belum mengurangi diskon dan komisi belum neto retur (P2-01). Belum ada ekspor XLSX/CSV dan laporan semua waktu (bagian 6).

### Tahap 9 — Backup dan sinkronisasi

44. Jalankan sinkronisasi rutin (outbox → relay, feed → terapkan, ack).
45. Lengkapi **putaran sinkron** seluruh perangkat.
46. Unggah **snapshot** toko setelah putaran selesai dan cursor perangkat ini mutakhir.
47. Simpan backup lokal terenkripsi (ZIP per toko, AES-GCM, SHA-256) ke media terpisah.
48. Uji restore di perangkat lain secara berkala.

> Catatan audit: snapshot sebaiknya hanya dari perangkat owner (P1-06); pemangkasan bisa macet karena perangkat karyawan yatim (P2-08/P2-09).

---

## 8. Rekomendasi Urutan Perbaikan (menunggu perintah “mulai”)

1. **P1-02** Retur: sesuaikan piutang, kas (REFUND), status bayar, dan komisi.
2. **P1-01** Void: blokir bila ada retur; hitung restock/refund dari sisa yang belum diretur; nolkan sisa.
3. **P1-03** Pengambilan unit: blokir bila `sisa_bayar > 0`.
4. **P1-05** Konversi estimasi: teruskan pelanggan, unit, dan work order.
5. **P1-04** Quick-add POS: wajib enqueue pelanggan/unit.
6. **P1-06** Relay: batasi snapshot ke owner dan verifikasi tanda tangan owner.
7. **P2-03** Pelunasan idempoten (cek `request_id` unik).
8. **P2-05/P2-06/P2-07/P2-10** Perketat relay: batas ack, validasi undangan, tangani konflik seq.
9. **P2-08/P2-09** Perangkat karyawan: gunakan ulang perangkat saat login; hitung pemangkasan dari perangkat yang benar-benar aktif.
10. **P2-01** Laporan: putuskan kebijakan diskon (tampilkan laba sebelum dan sesudah diskon) dan neto-kan komisi terhadap retur.
11. **P2-02** Koreksi nota: tambahkan aksi UI dan hubungkan ke piutang/kas.
12. **P2-11/P2-12/P2-13/P2-14** Perbaikan kecil: push akun, join struk, enqueue supplier/kompensasi, qty desimal.
13. **P3** Kelengkapan: DP/rencana bayar, janji ambil, barcode, ekspor XLSX/CSV, laporan part terjual/grup/semua waktu.

Setiap perbaikan sebaiknya disertai pengujian manual pada alur: pelanggan → unit → nota kredit → retur → pelunasan → ambil unit → laporan, dan alur sinkronisasi dua perangkat.

---

## 9. Cakupan File yang Dibaca

**Flutter (`pusatkupos/lib`)**

- `data/`: `app_database.dart`, `models.dart`, `schema.dart`, `sale_return_service.dart`, `nota_adjustment_service.dart`, `order_service.dart`, `receipt_service.dart`, `followup_service.dart`, `employee_service.dart`, `supplier_service.dart`, `store_service.dart`, `store_settings.dart`, `price_rules.dart`, `account_service.dart`, `owner_access_api.dart`, `pairing_service.dart`, `employee_auth_service.dart`, `license_verifier.dart`, `reconciliation_service.dart`, `note_sync.dart`
- `sync/`: `relay_client.dart`, `sync_service.dart`, `sync_scheduler.dart`, `sync_conflict_rules.dart`, `snapshot_sync.dart`
- `ui/screens/`: `pos_screen.dart`, `history_screen.dart`, `reports_screen.dart`, `estimates_screen.dart`, `customers_screen.dart`, `stores_screen.dart`, `premium_screen.dart`, `store_settings_screen.dart`
- `ui/`: `owner_viewer.dart`, `upload_backup_dialog.dart`
- `printer/`: adapter BLE, classic, network, channel

**Relay (`relay/lib`)**

- `server.dart`, `auth_rules.dart`, `sync_round.dart`, `db.dart`

**Python pembanding (`aplikasiposbengkel`)**

- `services/`: `pos_service.py`, `pricing_service.py`, `payment_service.py`, `void_return_service.py`, `pengerjaan_service.py`, `report_service.py`, `employee_service.py`, `followup_service.py`, `receipt_service.py`, `whatsapp_service.py`, `backup_service.py`, `stock_service.py`
- `api/schemas.py`, `api/stock_routes.py`

**Catatan:** audit ini hanya membaca kode. Tidak ada file aplikasi yang diubah dan tidak ada dependency yang dipasang.

---

## 10. Log Perbaikan

### Kelompok 1 — temuan mudah (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P1-03 | Sudah diperbaiki | Ambil unit ditolak bila `sisa_bayar > 0` atau nota sudah void. | `pusatkupos/lib/data/app_database.dart` (`markUnitTaken`) |
| P1-04 | Sudah diperbaiki | Pelanggan/unit yang dibuat dari POS ikut di-enqueue ke sinkronisasi. | `pusatkupos/lib/ui/screens/pos_screen.dart` |
| P1-05 | Sudah diperbaiki | Konversi estimasi meneruskan `customerId`, `unitId`, dan `workOrderSyncId`. | `pusatkupos/lib/data/order_service.dart` |
| P2-03 | Sudah diperbaiki | Pelunasan memeriksa `request_id`; UI mengirim id unik per percobaan. | `pusatkupos/lib/data/app_database.dart`, `ui/screens/history_screen.dart` |
| P2-05 | Sudah diperbaiki | Ack cursor dan ack putaran dibatasi sampai `latest_seq` toko/putaran. | `relay/lib/server.dart` |
| P2-11 | Sudah diperbaiki | Push akun tidak lagi memaksa ganti password bila hash/salt/iterasi tidak berubah. | `relay/lib/server.dart` |
| P2-12 | Sudah diperbaiki | Nomor HP struk memakai `LEFT JOIN` dan `COALESCE(r.customer_id, u.customer_id)`. | `pusatkupos/lib/data/receipt_service.dart` |
| P2-13 | Sudah diperbaiki | Mapping supplier ikut payload supplier dan di-enqueue saat diubah. Perubahan kompensasi karyawan kini menaikkan HLC dan meng-enqueue entitas `employee` sehingga diterapkan ke perangkat lain. | `sync/sync_service.dart`, `data/supplier_service.dart`, `data/employee_service.dart`, `ui/screens/stock_screen.dart` |
| P2-15 | Sudah diperbaiki | Ringkasan viewer ditolak bila kunci lisensi server tidak tersedia. | `pusatkupos/lib/ui/owner_viewer.dart` |
| P2-17 | Sudah diperbaiki | Void menetapkan `sisa_bayar = 0`. | `pusatkupos/lib/data/app_database.dart` |
| P3 | Sudah diperbaiki | Follow-up lunas dipindah ke filter arsip; `cicilan_hutang` diisi jumlah cicilan yang benar-benar dipotong. | `data/followup_service.dart`, `data/employee_service.dart` |

### Kelompok 2 — retur, void, koreksi, dan uang (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P1-01 | Sudah diperbaiki | Void ditolak bila nota sudah memiliki retur aktif. Refund void kini dicek per `request_id` sehingga tidak bentrok dengan refund retur. | `pusatkupos/lib/data/app_database.dart` (`voidRecord`) |
| P1-02 | Sudah diperbaiki | Retur kini: (1) menghapus piutang lebih dulu, (2) membuat baris pembayaran `REFUND` negatif hanya untuk kelebihan yang harus dikembalikan tunai, (3) menghitung ulang `total_dibayar`, `sisa_bayar`, dan `status_bayar`, (4) ikut diterapkan saat retur masuk dari perangkat lain. | `pusatkupos/lib/data/sale_return_service.dart`, `data/app_database.dart` (`recalculateRecordTotals`), `data/note_sync.dart` |
| P2-02 | Sudah diperbaiki | Koreksi nota bisa dibuat dari riwayat (tombol “Koreksi total nota”, dengan PIN pemilik/penanggung jawab bila di bawah batas modal). Koreksi langsung mengubah piutang/status bayar, ikut disinkronkan, dan total laporan memakai nilai setelah koreksi. | `pusatkupos/lib/ui/screens/history_screen.dart`, `data/nota_adjustment_service.dart`, `data/app_database.dart` |
| P2-01 | Sudah diperbaiki | Omzet part/jasa di laporan memakai `subtotal - diskon_alokasi`, sehingga laba kotor sudah setelah diskon. Label laporan diperjelas “(setelah diskon)”. | `data/app_database.dart` (`reportSummary`), `ui/screens/reports_screen.dart` |

### Kelompok 3 — relay, perangkat, dan undangan (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P1-06 | Sudah diperbaiki | Snapshot toko hanya boleh diunggah perangkat owner (`owner_device_required`). | `relay/lib/server.dart` |
| P2-06 | Sudah diperbaiki | Klaim undangan: rate limit per IP, akun harus aktif, kunci perangkat wajib, toko harus terdaftar pada owner dan termasuk toko akun. | `relay/lib/server.dart` (`_claimInvite`, `_ownerStoreAllowed`) |
| P2-07 | Sudah diperbaiki | Pembuatan undangan menolak TTL di luar 1–1440 menit, akun nonaktif, dan toko yang tidak terdaftar/tidak menjadi hak akun. | `relay/lib/server.dart` (`_createInvite`) |
| P2-08 | Sudah diperbaiki | Relay memakai ulang baris perangkat karyawan yang sama (owner+akun+kunci publik) saat login; aplikasi memakai ulang pasangan kunci lokal sehingga login berulang tidak menambah perangkat. | `relay/lib/server.dart` (`_employeeLogin`), `pusatkupos/lib/data/employee_auth_service.dart` |
| P2-09 | Sudah diperbaiki | Pemangkasan amplop hanya menghitung perangkat relevan: semua perangkat owner + satu perangkat karyawan terbaru per akun, sehingga perangkat lama yang tidak pernah ack tidak menahan pemangkasan. | `relay/lib/server.dart` (`_pruneAcknowledged`) |
| P2-10 | Sudah diperbaiki | Bentrok `seq` menghasilkan `409 seq_conflict`, bukan id karangan; klien memberi nomor seq baru agar amplop dikirim ulang, bukan ditandai terkirim. | `relay/lib/server.dart` (`_ingestEnvelope`), `pusatkupos/lib/sync/sync_service.dart` (`_failOutbox`) |

### Kelompok 4 — estimasi, kompensasi, laporan, dan qty desimal (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P2-01 | Sudah diperbaiki | Laba kotor part dan jasa dihitung dari `subtotal - diskon_alokasi`; label laporan menyebut “setelah diskon”. | `pusatkupos/lib/data/app_database.dart` (`reportSummary`), `ui/screens/reports_screen.dart` |
| P2-13 | Sudah diperbaiki | Perubahan kompensasi karyawan (gaji, komisi, payroll, bank, status aktif) menaikkan HLC lalu meng-enqueue entitas `employee`; perangkat pasangan menerapkannya. | `data/employee_service.dart`, `sync/sync_service.dart` |
| P2-16 | Sudah diperbaiki | Detail estimasi memiliki aksi **Revisi** (qty, diskon, alasan) dan **Batalkan**; keduanya menulis status/HLC dan meng-enqueue sinkronisasi. | `data/order_service.dart` (`cancelEstimate`), `ui/screens/estimates_screen.dart` |
| P2-14 | Sudah diperbaiki | Qty part menerima desimal hingga 3 digit (mis. 0,5 L) di POS, revisi estimasi, retur, struk, detail nota, dan laporan. Kolom `jumlah_milli` ditambahkan ke `service_parts`, `sale_return_items`, dan `estimate_items` lewat skema v3 + backfill; sisa stok, pergerakan stok, komisi, dan sinkronisasi memakai milli. | `data/schema.dart`, `data/app_database.dart`, `data/models.dart`, `data/price_rules.dart`, `data/order_service.dart`, `data/sale_return_service.dart`, `data/note_sync.dart`, `data/receipt_service.dart`, `printer/receipt_builder.dart`, `ui/screens/pos_screen.dart`, `ui/screens/estimates_screen.dart`, `ui/screens/history_screen.dart` |
| P3 | Sudah diperbaiki | Pembayaran sebagian diberi label `DP` dan pelunasan penuh `PELUNASAN`; izin retur dipisahkan dari `void` (peran kasir/keduanya mendapat `retur`). | `data/app_database.dart`, `data/account_service.dart`, `ui/screens/history_screen.dart` |


