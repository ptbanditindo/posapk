# Rencana Pengembangan PusatkuPOS

Dokumen ini adalah satu-satunya rencana pengembangan aplikasi. Isinya dibagi
per modul agar rilis Play Store dapat memakai **Play Feature Delivery**:
pengguna memasang modul inti saat mengunduh aplikasi, lalu mengunduh modul
opsional hanya ketika dibutuhkan.

Status dokumen: kerangka modul dan aturan pemisahan sudah ditetapkan. Detail
perilaku tiap modul ditambahkan setelah pemilik menjelaskan kebutuhannya.
Nomor modul (`M0`, `O1`, dan seterusnya) dipakai sebagai acuan tetap.
Keputusan 2026-11-10: pembayaran fitur premium dilakukan lewat Google Play
Store. Premium dijual per paket bulanan: 1 sampai 5 toko dan paket unlimited,
tanpa paket tahunan. Harga Rp25.000 per toko per bulan untuk paket 1-5 toko;
harga paket unlimited Rp150.000 per bulan. Langganan diperpanjang otomatis
tiap bulan; bila tidak dibayar, pemilik memilih satu toko yang tetap aktif dan
toko lain menjadi baca-saja. Sebelum mode baca-saja berlaku, ada masa tenggang
7 hari dengan fitur premium tetap aktif untuk memperpanjang. Pilihan toko aktif
tidak dapat diganti selama mode baca-saja. Pengguna yang belum pernah
berlangganan memakai versi lokal gratis selamanya: satu perangkat, satu toko.

## Daftar isi

1. [Tujuan dan batasan](#1-tujuan-dan-batasan)
2. [Keputusan arsitektur](#2-keputusan-arsitektur)
3. [Peta modul](#3-peta-modul)
4. [Modul inti](#4-modul-inti)
5. [Modul opsional](#5-modul-opsional)
6. [Bagian yang tidak dipecah](#6-bagian-yang-tidak-dipecah)
7. [Mekanisme modul saat berjalan](#7-mekanisme-modul-saat-berjalan)
8. [Syarat teknis Play Store](#8-syarat-teknis-play-store)
9. [Ukuran unduhan dan target](#9-ukuran-unduhan-dan-target)
10. [Fase pengembangan](#10-fase-pengembangan)
11. [Risiko dan mitigasi](#11-risiko-dan-mitigasi)
12. [Slot modul baru](#12-slot-modul-baru)
13. [Keputusan bisnis premium](#13-keputusan-bisnis-premium)

## 1. Tujuan dan batasan

Tujuan:

- Unduhan awal dari Play Store hanya berisi modul yang wajib untuk berjualan
  secara offline.
- Modul opsional diunduh saat pemilik membukanya, bukan saat memasang
  aplikasi.
- Modul yang tidak diunduh tidak boleh menghalangi kasir, stok, laporan, atau
  pemulihan data.

Batasan yang tidak boleh dilanggar:

- Satu aplikasi, satu database SQLite/SQLCipher per toko, satu lisensi per
  toko. Modul bukan aplikasi terpisah dan tidak memiliki database sendiri.
- Skema database, migrasi, sinkronisasi, backup/restore, dan audit tetap di
  modul inti. Modul opsional hanya memuat layar dan alur yang memakainya.
- Kasir harus tetap berjalan tanpa internet, tanpa modul opsional, dan tanpa
  relay.
- Data modul yang sudah tersinkron tetap diterima walaupun modulnya belum
  diunduh di perangkat tersebut.
- Fitur premium tetap ditentukan token lisensi, bukan oleh ada/tidaknya modul.

## 2. Keputusan arsitektur

| Kode | Keputusan | Alasan |
|---|---|---|
| AD-01 | Modul adalah potongan layar dan alur, bukan potongan data. | Satu database dan satu ledger stok tidak dapat dipecah tanpa merusak konsistensi. |
| AD-02 | Semua tabel, migrasi, sinkronisasi delta, backup, dan audit berada di modul inti. | Perangkat tanpa modul opsional tetap harus menerima dan menyimpan data dari perangkat lain. |
| AD-03 | Hanya layar opsional yang menjadi dynamic feature module. | Pemotongan sebagian layar (tab, tombol, bagian laporan) tidak didukung delivery Play. |
| AD-04 | Setiap modul opsional mempunyai satu titik masuk berupa pembungkus di inti. | Kode inti tidak boleh mengimpor pustaka deferred secara langsung; pembungkus yang memanggil `loadLibrary()`. |
| AD-05 | Ketersediaan modul dan saklar fitur adalah dua hal berbeda. | Modul bisa terpasang tetapi fitur dimatikan pemilik, atau sebaliknya. Menu hanya tampil bila keduanya aktif dan akun berizin. |
| AD-06 | Build non-Play (APK sideload, Windows, Linux, web, iOS) memuat semua modul. | Play Feature Delivery hanya berlaku untuk AAB lewat Play Store; build lain tetap utuh dan tidak menampilkan unduhan modul. |
| AD-07 | Kegagalan unduh modul tidak pernah menghentikan aplikasi. | Kasir offline adalah fungsi utama; unduhan bersifat tambahan dan bisa diulang. |
| AD-08 | Modul tidak mengubah aturan uang, stok, izin, atau lisensi. | Modul hanya memindahkan UI; aturan tetap di inti agar konsisten dengan data tersinkron. |
| AD-09 | Pembelian premium memakai Google Play Billing; token lisensi tetap satu-satunya bukti hak. | Play menangani pembayaran, relay memverifikasi pembelian, dan perangkat tetap dapat memeriksa lisensi secara offline. |

## 3. Peta modul

Kolom **Delivery** menunjukkan cara modul dikirim ke perangkat:

- **Base**: menyatu di modul aplikasi utama dan ikut saat pemasangan.
- **On-demand**: dynamic feature module yang diunduh saat dibutuhkan.
- **Tidak dipecah**: tetap di base walau secara logis bagian dari modul lain.

| Kode | Modul | Isi utama | Delivery | Dependensi | Saklar fitur |
|---|---|---|---|---|---|
| M0 | Fondasi dan keamanan | startup, database, skema, sesi, PIN, operator, izin, tema, navigasi, registry modul | Base | - | - |
| M1 | Ringkasan | dasbor, pengingat jatuh tempo, pintasan menu | Base | M0 | - |
| M2 | Kasir dan nota | POS, pembayaran, kredit, retur, void, PPN per nota, cetak nota | Base | M0, M5, M6 | - |
| M3 | Riwayat | daftar nota, pencarian, pembukaan arsip | Base | M2 | - |
| M4 | Pelanggan | data pelanggan, normalisasi nomor, gabung, izin WhatsApp, unit kendaraan | Base | M0 | `unit_kendaraan`, `whatsapp` |
| M5 | Stok | ledger stok, HPP, opname, koreksi, mutasi | Base | M0 | - |
| M6 | Jasa | daftar jasa dan harga | Base | M0 | - |
| M7 | Laporan dan pajak | omzet, laba, kas, piutang, PPN, tutup buku, saldo awal | Base | M0, M2, M5 | - |
| M8 | Karyawan | akun karyawan, peran, izin, gaji dan komisi | Base | M0 | - |
| M9 | Pengaturan dan data | pengaturan toko, printer, struk, fitur per toko, diagnostik, backup/restore | Base | M0 | - |
| M10 | Premium dan sinkronisasi | pembelian Play per paket toko, lisensi per toko, login Google, multi-toko, perangkat, pemulihan kunci, sinkronisasi, arsip | Base | M0 | - |
| O1 | Order kerja dan estimasi | antrean, status pengerjaan, estimasi biaya | On-demand | M0, M2 | `order_kerja`, `estimasi` |
| O2 | Supplier dan pembelian | supplier, reseller, nota pembelian, utang, retur pembelian | On-demand | M0, M5 | `supplier_hub`, `purchase_debt` |
| O3 | Tindak lanjut pelanggan | pengingat servis, garansi, piutang, unit selesai, kuota WhatsApp | On-demand | M0, M4, M10 | `followup` |
| O4 | Pencarian arsip dokumen | pencarian dan ekspor dokumen arsip | On-demand | M0, M10 | - |

## 4. Modul inti

Modul inti wajib ada di setiap pemasangan. Pengguna tidak dapat menghapusnya
dan tidak melihat proses unduhannya.

### M0 Fondasi dan keamanan

- **Cakupan**: startup dan pemulihan, pembukaan database SQLCipher, skema dan
  migrasi, PIN/login/logout, sesi dan kunci otomatis, katalog izin operator,
  tema, navigasi utama, registry modul, pencatatan log lokal.
- **Data**: seluruh tabel dan migrasi, termasuk tabel milik modul opsional.
- **Delivery**: base.
- **Kriteria selesai**: aplikasi dapat dibuka dan dipakai tanpa modul opsional,
  tanpa relay, dan tanpa internet.

### M1 Ringkasan

- **Cakupan**: dasbor, kartu ringkasan, pengingat jatuh tempo supplier, pintasan
  ke menu lain.
- **Catatan**: pintasan ke modul opsional hanya tampil bila modul terpasang.
- **Delivery**: base.

### M2 Kasir dan nota

- **Cakupan**: layar kasir, keranjang jasa dan sparepart, diskon, PPN, tunai,
  transfer, bayar sebagian, kredit, retur, void, dialog struk, dan cetak.
- **Ketergantungan**: memakai layanan stok dan jasa yang tetap di base.
- **Delivery**: base. Kasir tidak boleh bergantung pada unduhan modul.
- **Kriteria selesai**: seluruh alur penjualan berjalan pada perangkat baru yang
  hanya memiliki modul inti.

### M3 Riwayat

- **Cakupan**: daftar nota, filter, pembukaan detail, dan titik masuk pencarian
  arsip dokumen.
- **Delivery**: base.
- **Catatan**: tombol arsip hanya tampil bila modul O4 terpasang dan premium
  aktif.

### M4 Pelanggan

- **Cakupan**: data pelanggan, peringatan duplikat, gabung pelanggan, izin
  WhatsApp, dan bagian unit kendaraan.
- **Delivery**: base.
- **Catatan**: unit kendaraan adalah bagian dari satu layar pelanggan, sehingga
  tidak dapat dijadikan modul unduhan terpisah; statusnya diatur saklar fitur.

### M5 Stok

- **Cakupan**: stok masuk/keluar, opname, koreksi, mutasi, saldo, HPP rata-rata,
  nilai persediaan.
- **Delivery**: base. Modul pembelian (O2) menulis ke ledger yang sama.

### M6 Jasa

- **Cakupan**: daftar jasa, harga, dan pemakaian di kasir.
- **Delivery**: base.

### M7 Laporan dan pajak

- **Cakupan**: omzet, laba kotor, kas per metode, piutang, margin, PPN, tutup
  buku, saldo awal, dan transaksi di bawah harga patokan.
- **Delivery**: base.
- **Catatan**: laporan membaca tabel modul opsional bila datanya ada; modul
  opsional yang tidak terpasang tidak boleh membuat laporan gagal.

### M8 Karyawan

- **Cakupan**: akun karyawan, peran dan izin eksplisit, akses per toko, gaji dan
  komisi.
- **Delivery**: base.

### M9 Pengaturan dan data

- **Cakupan**: pengaturan toko, saklar fitur, printer, struk, diagnostik,
  backup/restore lokal, dan pemulihan database.
- **Delivery**: base.
- **Catatan**: konfigurasi printer tetap di berkas terpisah dan tidak ikut
  backup maupun sinkronisasi.

### M10 Premium dan sinkronisasi

- **Cakupan**: login Google, pembelian premium per paket toko lewat Google Play,
  token lisensi per toko, pembatasan perangkat, pemulihan kunci owner,
  sinkronisasi E2EE, kuota follow-up, arsip, dan status perangkat.
- **Delivery**: base.
- **Alur pembelian**:
  - Pemilik memilih paket bulanan 1, 2, 3, 4, 5 toko, atau unlimited, memilih
    toko yang dicakup (kecuali unlimited), lalu membeli lewat Google Play
    Billing di dalam aplikasi. Tidak ada tautan pembayaran di luar Play.
  - Harga Rp25.000 per toko per bulan. Harga paket 1-5 toko: Rp25.000,
    Rp50.000, Rp75.000, Rp100.000, dan Rp125.000. Harga paket unlimited
    Rp150.000 per bulan.
  - Satu pembelian mengaktifkan seluruh toko dalam paket. Tidak ada pembelian
    terpisah per toko di dalam satu paket.
  - Pembelian melekat pada akun Google yang membayar (owner). Hanya akun
    Google itu yang dapat memulihkan paket di perangkat lain; akun karyawan
    tidak dapat memulihkan atau memindahkan lisensi.
  - Aplikasi mengirim purchase token, jenis paket, dan daftar `store_id` ke
    relay. Relay memverifikasi token ke Google Play Developer API, mengikat
    paket ke toko-toko yang dipilih, lalu menerbitkan token lisensi Ed25519
    untuk setiap toko yang dicakup.
  - Pembelian diakui (acknowledge) dan dapat dipulihkan (restore) lewat Play.
    Langganan diperpanjang otomatis setiap bulan. Pembatalan, refund, dan
    perubahan status subscription diperbarui lewat Real-time Developer
    Notifications ke relay.
  - Bila perpanjangan gagal, langganan masuk masa tenggang 7 hari. Fitur
    premium tetap aktif selama masa tenggang agar pemilik dapat memperpanjang.
    Setelah 7 hari tanpa pembayaran, relay menonaktifkan lisensi toko dan
    aplikasi masuk mode terbatas: pemilik memilih satu toko yang tetap aktif,
    sisanya baca-saja. Pilihan itu tidak dapat diganti sampai langganan
    berjalan lagi.
  - Selama token lisensi masih berlaku, perangkat dapat membuka kasir tanpa
    internet. Setelah masa berlaku habis, aturan baca-saja di bawah berlaku.
- **Aturan**:
  - Token lisensi tetap satu-satunya bukti hak premium di perangkat. Klaim
    pembelian dari klien tidak pernah dipercaya tanpa verifikasi relay.
  - Satu paket mengaktifkan toko yang dipilih; paket unlimited mengaktifkan
    seluruh toko yang aktif selama masa langganan, termasuk toko baru yang
    dibuat atau diaktifkan selama periode itu. Plan, masa berlaku, dan status
    aktif melekat pada tiap `store_id` yang tercakup, bukan pada satu kuota
    toko global.
  - Pengguna yang belum pernah berlangganan mendapat versi lokal gratis
    selamanya: satu perangkat, satu toko, dan transaksi penuh secara offline.
    Fitur server (sinkronisasi, arsip, multi-toko, kuota follow-up tanpa batas)
    tetap premium.
  - Toko yang tidak tercakup paket mengikuti status lisensi toko masing-masing.
    Aturan pembuatan dan alokasi toko di luar paket masih terbuka (PB-08 dan
    PB-10).
  - Masa tenggang 7 hari berlaku sebelum mode baca-saja: fitur premium tetap
    aktif dan belum ada toko yang dibatasi selama pemilik memperpanjang.
  - Setelah masa tenggang berakhir tanpa pembayaran, pemilik memilih satu toko
    yang tetap aktif. Toko itu tetap dapat mencatat transaksi; toko lain menjadi
    baca-saja:
    penjualan (barang keluar) tetap dapat dicatat agar karyawan dapat melayani
    pelanggan, tetapi penambahan stok, pembelian, dan perubahan data lain
    diblokir. Laporan, ekspor, backup, dan cetak data lama tetap diizinkan agar
    data tidak terkunci.
  - Karyawan tidak dikunci dari akun saat mode baca-saja. Aplikasi tetap dapat
    dibuka dan karyawan masih dapat melayani penjualan, tetapi tidak dapat
    menambah stok, membuat pembelian, atau mengubah data lain.
  - Aturan ini menggantikan perilaku lama "kasir lokal tetap berjalan saat
    lisensi kedaluwarsa".
  - Fitur premium tidak berubah: sinkronisasi, arsip, multi-toko, dan kuota
    follow-up tanpa batas.
  - Refund atau pembatalan menghentikan fitur server seluruh toko dalam paket
    setelah status lisensi diperbarui, tanpa menghapus data lokal.
  - Build non-Play (APK sideload, desktop, web) tidak dapat membeli lewat Play;
    jalur token manual tetap tersedia untuk pengujian dan pemulihan, bukan
    sebagai kanal penjualan.
- **Catatan**: modul opsional tidak menambah syarat lisensi baru.

## 5. Modul opsional

Modul opsional adalah dynamic feature module yang diunduh lewat Play Store.
Setiap modul memiliki satu titik masuk di inti. Bila belum terpasang, menu
menampilkan kartu "Unduh modul" dengan ukuran perkiraan; bila unduhan gagal,
kasir tetap berjalan dan pengguna dapat mencoba lagi.

### O1 Order kerja dan estimasi

- **Cakupan**: layar order kerja, nomor antrean, status pengerjaan, riwayat
  order, dan layar estimasi biaya.
- **Delivery**: on-demand.
- **Dependensi**: M2 untuk data nota dan pelanggan.
- **Prasyarat teknis**: layanan order saat ini dipakai layar kasir, sehingga
  layanan tetap di base dan hanya layar yang dipindahkan. Bila kelak layanan
  ikut dipindahkan, kasir harus memakai antarmuka di base.
- **Kriteria selesai**: modul dapat diunduh, dibuka, ditutup, dan dihapus tanpa
  mengubah data nota yang sudah ada.

### O2 Supplier dan pembelian

- **Cakupan**: layar supplier dan reseller, nota pembelian, pembayaran utang,
  retur pembelian, dan aging utang.
- **Delivery**: on-demand.
- **Dependensi**: M5 untuk ledger stok.
- **Prasyarat teknis**: layanan pembelian dipakai sinkronisasi, ringkasan, dan
  laporan; layanan tetap di base. Hanya layar supplier dan pembelian yang
  dipindahkan.
- **Kriteria selesai**: menonaktifkan atau menghapus modul tidak menghilangkan
  data pembelian yang sudah tersinkron dan tidak membuat laporan gagal.

### O3 Tindak lanjut pelanggan

- **Cakupan**: layar pengingat pelanggan, pengaturan pengingat, pesan WhatsApp
  bergaya struk, kuota follow-up, dan pembukaan chat per pelanggan.
- **Delivery**: on-demand.
- **Dependensi**: M4 untuk data pelanggan, M10 untuk kuota dan premium.
- **Prasyarat teknis**: layanan follow-up dipakai riwayat dan kasir; layanan
  tetap di base. Pemakaian WhatsApp tetap mengikuti saklar `whatsapp`.
- **Kriteria selesai**: modul terpasang menampilkan menu pengingat; tanpa modul,
  menu tersembunyi tetapi data jadwal yang tersinkron tetap utuh.

### O4 Pencarian arsip dokumen

- **Cakupan**: pencarian, pembukaan, dan ekspor dokumen arsip premium.
- **Delivery**: on-demand.
- **Dependensi**: M10 untuk token arsip dan premium.
- **Kriteria selesai**: tanpa modul, riwayat tetap berjalan dan tombol arsip
  tidak ditampilkan.

## 6. Bagian yang tidak dipecah

Bagian berikut tetap di modul inti walaupun secara logis terkait modul lain:

| Bagian | Alasan |
|---|---|
| Unit kendaraan | Berada di dalam layar pelanggan, bukan layar tersendiri. |
| Saklar WhatsApp | Hanya membuka tautan dan dipakai beberapa layar. |
| Printer ESC/POS | Dipakai kasir dan struk; pustaka native tetap ikut inti. |
| Backup, restore, pemulihan kunci | Menyentuh seluruh database, termasuk data modul opsional. |
| Sinkronisasi dan penerapan delta | Harus berjalan tanpa memandang modul yang terpasang. |
| Laporan dan pajak | Membaca tabel dari semua modul. |
| Multi-toko dan perangkat | Mengatur database dan lisensi, bukan fitur toko. |
| Diagnostik dan log | Dibutuhkan saat modul gagal dimuat. |

## 7. Mekanisme modul saat berjalan

- **Registry modul** di inti menyimpan status setiap modul: `base`, `tersedia`,
  `mengunduh`, `terpasang`, `gagal`, dan `tidak didukung`.
- Status `tidak didukung` dipakai build non-Play; semua menu modul langsung
  dianggap tersedia karena seluruh kode ikut terpasang.
- Menu modul hanya tampil bila tiga syarat terpenuhi: modul terpasang, akun
  memiliki izin, dan saklar fitur toko aktif.
- Bila modul belum terpasang, menu menampilkan kartu unduhan. Unduhan memakai
  mekanisme Play; aplikasi tidak mengunduh kode dari server sendiri.
- Modul yang dihapus pengguna tidak menghapus tabel atau data. Data tetap
  diterima sinkronisasi dan tetap masuk backup.
- Perpindahan toko tidak mengubah status modul karena status melekat pada
  perangkat, bukan pada toko.
- Unduhan modul dicatat di diagnostik agar kegagalan dapat ditelusuri tanpa
  membuka database.

## 8. Syarat teknis Play Store

- Build Play memakai **Android App Bundle (AAB)**, bukan APK universal.
- Modul opsional memakai dynamic feature module dan pustaka Play Feature
  Delivery/Play Core yang didukung versi Flutter saat implementasi.
- Kode modul memakai `import ... deferred` dan hanya dipanggil setelah
  `loadLibrary()` berhasil.
- Aplikasi Android memakai kelas aplikasi Flutter yang mendukung split compat
  agar modul dapat dimuat setelah dipasang.
- Validator deferred components harus lolos pada setiap build rilis; impor
  langsung dari inti ke pustaka modul dianggap kesalahan.
- Deferred components tidak berlaku di mode debug dan tidak berlaku untuk APK
  sideload. Pengujian unduhan hanya sah lewat rilis AAB di track internal Play.
- Windows, Linux, web, iOS, dan APK lokal tetap memakai satu paket utuh.
- Pembelian fitur digital memakai Google Play Billing; tidak ada tautan atau
  arahan pembayaran ke luar Play.
- Versi modul mengikuti versi aplikasi; menaikkan versi aplikasi menaikkan versi
  modul yang dipasang.

## 9. Ukuran unduhan dan target

- Ukuran debug 180 MB bukan dasar perhitungan karena memuat mesin debug dan tiga
  arsitektur CPU.
- Perkiraan rilis arm64 saat ini 30-36 MB; mesin Flutter dan pustaka native
  (SQLCipher, printer, penyimpanan aman) adalah penyumbang terbesar.
- Pemindahan layar opsional ke modul diperkirakan hanya memangkas 1-4 MB dari
  unduhan awal karena pustaka native dan layanan tetap di inti. Angka pasti
  diukur di Fase 0 memakai laporan ukuran Play Console.
- Target yang diukur, bukan diasumsikan:
  - unduhan awal perangkat arm64;
  - ukuran tiap modul opsional;
  - waktu buka pertama modul setelah unduhan;
  - ukuran total setelah semua modul terpasang.

## 10. Fase pengembangan

### Fase 0 - Pengukuran dan percobaan

- Ukur baseline AAB per perangkat dan petakan impor antar-modul.
- Percobaan satu modul (O1) sebagai dynamic feature di track internal Play.
- Verifikasi perilaku pustaka native dan plugin di dalam modul.
- Hasil: keputusan lanjut atau batalkan pemisahan, beserta angka ukuran nyata.

### Fase 1 - Pemisahan logis

- Kelompokkan layar dan layanan per modul tanpa mengubah perilaku.
- Pasang antarmuka di inti untuk layanan yang dipakai lintas modul.
- Build APK debug dan platform lain tetap utuh dan dapat diuji seperti sekarang.

### Fase 2 - Deferred components

- Ubah modul opsional satu per satu menjadi dynamic feature module.
- Setiap modul mendapat pembungkus di inti, status registry, dan kartu unduhan.
- Uji lewat track internal Play, bukan APK sideload.

### Fase 3 - Pembelian premium lewat Play

- Tetapkan produk Play untuk paket bulanan 1-5 toko dan unlimited, serta
  pemetaan paket ke daftar toko yang diaktifkan.
- Sambungkan Play Billing di aplikasi dengan verifikasi purchase token di
  relay, acknowledge, dan restore.
- Sambungkan Real-time Developer Notifications untuk pembaruan, pembatalan,
  refund, dan masa tenggang, lalu uji di sandbox sebelum rilis.
- Terapkan status langganan otomatis: perpanjangan, pembayaran gagal, masa
  tenggang 7 hari, pembatalan, dan mode baca-saja dengan satu toko aktif.

### Fase 4 - UX unduhan dan ketahanan

- Lengkapi status unduh, gagal, ulangi, dan hapus modul.
- Pastikan kasir, laporan, sinkronisasi, dan backup tetap berjalan tanpa modul.
- Lengkapi diagnostik unduhan.

### Fase 5 - Rilis

- Rilis bertahap di Play, pantau ukuran unduhan dan kegagalan pemuatan modul.
- Siapkan rollback dengan mematikan modul bermasalah dari registry, tanpa
  menurunkan versi aplikasi.

## 11. Risiko dan mitigasi

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Mesin Flutter dan pustaka native tetap di inti | Penghematan ukuran lebih kecil dari harapan | Ukur di Fase 0; sampaikan angka nyata sebelum rilis |
| Modul memakai layanan yang juga dipakai kasir atau laporan | Modul tidak dapat benar-benar dilepas | Layanan tetap di inti; pindahkan hanya layar |
| Impor langsung dari inti ke modul | Kode modul ikut masuk ke inti | Validator deferred components wajib lolos |
| Unduhan hanya lewat Play | APK sideload dan desktop tidak bisa menguji modul | Build non-Play memuat semua modul; uji unduhan di track internal |
| Pengguna offline membuka modul | Modul tidak dapat diunduh | Kartu unduhan menjelaskan kebutuhan internet; kasir tetap jalan |
| Versi modul tertinggal dari aplikasi | Modul gagal dimuat setelah update | Versi modul mengikuti versi aplikasi; registry memeriksa kecocokan |
| Modul dihapus pengguna | Menu hilang, data tetap ada | Data tidak dihapus; menu menampilkan unduhan ulang |
| Relay tidak terjangkau saat pembelian atau pembaruan lisensi | Status premium tidak langsung berubah | Token lisensi terakhir tetap dipakai; verifikasi diulang saat online |
| Refund atau chargeback tidak tercatat | Fitur premium tetap aktif padahal sudah dibayar balik | Real-time Developer Notifications dan pemeriksaan berkala purchase token |

## 12. Slot modul baru

Bagian ini menampung modul yang belum dijelaskan pemilik. Isinya belum
mengikat dan akan ditetapkan sebelum Fase 1.

| Kode | Calon modul | Status |
|---|---|---|
| M11 | Login dan logout akun | Menunggu penjelasan |
| M12 | Satuan dan konversi | Menunggu penjelasan |
| M13 | Pemindai barcode | Menunggu penjelasan |
| M14 | Ganti toko aktif | Menunggu penjelasan |

## 13. Keputusan bisnis premium

Tabel ini mencatat keputusan premium beserta statusnya. Keputusan yang masih
berstatus Menunggu tidak boleh diisi diam-diam.

| Kode | Keputusan | Status | Dampak |
|---|---|---|---|
| PB-01 | Paket bulanan 1, 2, 3, 4, 5 toko, dan unlimited | Ditetapkan 2026-11-10 | Enam produk Play bulanan |
| PB-02 | Harga Rp25.000 per toko per bulan untuk paket 1-5 toko (Rp25.000/Rp50.000/Rp75.000/Rp100.000/Rp125.000); paket unlimited Rp150.000 per bulan | Ditetapkan 2026-11-10 | Harga tiap produk di Play Console |
| PB-03 | Satu pembelian = satu paket, bukan pembelian terpisah per toko | Ditetapkan 2026-11-10 | Checkout dan klaim lisensi per paket |
| PB-04 | Pembelian melekat pada akun Google yang membayar (owner); hanya akun itu yang dapat memulihkan paket | Ditetapkan 2026-11-10 | Restore lintas perangkat dan pemulihan akses |
| PB-05 | Masa tenggang 7 hari saat pembayaran gagal; fitur premium tetap aktif selama masa tenggang untuk memperpanjang | Ditetapkan 2026-11-10 | Status premium sementara dan RTDN grace period |
| PB-06 | Kebijakan refund di luar kebijakan Play | Menunggu | Pencabutan lisensi dan audit |
| PB-07 | Langganan diperpanjang otomatis (subscription bulanan) | Ditetapkan 2026-11-10 | Produk subscription Play, RTDN, dan status langganan |
| PB-08 | Toko baru wajib berlisensi sebelum dibuat, atau dibuat gratis lalu diaktifkan | Menunggu | Alur tambah toko dan multi-toko |
| PB-09 | Paket durasi 3 bulan dan tahunan | Ditetapkan 2026-11-10: tidak ada | Hanya produk bulanan yang dibuat |
| PB-10 | Cara memilih/mengganti toko dalam paket dan batas toko di atas 5 | Menunggu | Alokasi lisensi dan upgrade paket |
| PB-11 | Toko dihitung selama masa aktif berlangganan; paket unlimited mencakup seluruh toko yang aktif selama periode itu, termasuk toko baru | Ditetapkan 2026-11-10 | Cakupan lisensi per toko |
| PB-12 | Paket 5 toko (Rp125.000) dan unlimited (Rp150.000); kedua paket tetap ditawarkan | Ditetapkan 2026-11-10 | Susunan produk dan harga di Play Console |
| PB-13 | Saat langganan tidak dibayar, pemilik memilih satu toko yang tetap aktif; toko lain baca-saja (penjualan/barang keluar tetap dapat dicatat; penambahan stok, pembelian, dan perubahan data lain diblokir; laporan, ekspor, backup, dan cetak data lama tetap diizinkan); karyawan tidak dikunci, dapat membuka aplikasi dan melayani penjualan, tetapi tidak dapat menambah stok atau membuat pembelian | Ditetapkan 2026-11-10 | Penegakan lisensi dan pengalaman karyawan |
| PB-14 | Toko aktif tidak dapat diganti selama mode baca-saja | Ditetapkan 2026-11-10: tidak dapat diganti | Alur pemilihan toko hanya tersedia saat langganan berjalan |
| PB-15 | Pengguna yang belum pernah berlangganan memakai versi lokal gratis selamanya: 1 perangkat, 1 toko, transaksi penuh offline; fitur server tetap premium | Ditetapkan 2026-11-10 | Versi gratis dan konversi ke premium |

Catatan teknis: karena jumlah toko menjadi bagian dari produk paket, satu akun
Google dapat membeli paket berbeda tanpa membeli produk yang sama dua kali.
Paket unlimited mencakup seluruh toko yang aktif selama masa langganan,
termasuk toko baru. Karena PB-07 memilih subscription otomatis, perpindahan
paket memakai alur upgrade/downgrade Play dan status langganan diperbarui lewat
RTDN; penumpukan masa prabayar tidak berlaku. Detailnya diverifikasi di sandbox
Fase 3.

Keputusan PB-01, PB-02, PB-03, PB-04, PB-05, PB-07, PB-09, PB-11, PB-12, PB-13,
PB-14, dan PB-15 sudah mengikat.
Keputusan lain di atas belum, dan alur lisensi token yang ada tetap berlaku
sampai implementasi Play dimulai.
