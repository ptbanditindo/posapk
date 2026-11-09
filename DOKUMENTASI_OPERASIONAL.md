# Dokumentasi Operasional PusatkuPOS

Panduan ini untuk pemilik toko, admin, dan operator harian. Isinya mencakup
alur kerja per peran, backup dan pemulihan, penanganan konflik sinkronisasi,
serta kebijakan privasi dan retensi. Panduan teknis relay ada di
[relay/OPS.md](relay/OPS.md).

## 1. Peran dan akses

| Peran | Akses utama |
|---|---|
| Pemilik penuh | Semua modul, pengaturan, fitur toko, saldo awal, laporan, backup, kelola akun dan perangkat, pembatalan/void, ubah harga jasa. |
| Supervisor / admin | Nota, retur, stok, opname, estimasi, order kerja, follow up, koreksi, laporan (sesuai izin). Tidak dapat mengubah fitur toko, saldo awal, harga jasa, atau konfigurasi keamanan kecuali diberikan izin eksplisit. |
| Kasir | Nota, retur, estimasi, order kerja, stok keluar/masuk bila diizinkan, follow up. Izin tambahan diatur pemilik. |
| Mekanik | Status order kerja. Izin lain hanya bila ditambahkan pemilik. |
| Viewer / ringkasan laporan | Hanya membaca laporan pada salinan terpisah; tidak menulis ke pembukuan. |

Izin tambahan yang sering dipakai: `lihat_laporan`, `cetak_laporan`,
`ubah_stok`, `stok_masuk`, `stok_keluar`, `opname`, `diskon`, `retur`,
`void`, `ubah_harga_jasa`, `followup`, `lihat_pembelian`, `buat_pembelian`,
`bayar_utang`.

Aturan penting:

- Izin peran tidak dapat menghidupkan modul yang dimatikan pemilik. Fitur
  opsional diatur per toko.
- Viewer tidak dapat mengubah data walaupun tombol terlihat; service menolak.
- Aksi sensitif meminta konfirmasi ulang dan tercatat di audit bisnis.

## 2. SOP harian

### Buka toko

1. Masuk dengan PIN pemilik atau akun karyawan.
2. Periksa apakah toko yang aktif sudah benar (menu **Toko**).
3. Buka **Sinkronisasi** dan pastikan tidak ada antrean gagal. Bila ada
   konflik, selesaikan sebelum transaksi baru.
4. Periksa pengingat utang supplier (H-3 dan lewat jatuh tempo) bila fitur
   Pembelian & Utang aktif.

### Tutup toko

1. Selesaikan atau batalkan nota yang masih terbuka.
2. Lakukan opname bila stok fisik berubah.
3. Jalankan sinkronisasi dan pastikan tidak ada outbox tertunda.
4. Buat backup manual bila ada perubahan besar (lihat bagian 3).

### Nota dan pembayaran

- Nota yang sudah disimpan bersifat append-only. Koreksi dilakukan lewat retur,
  pelunasan piutang, atau void dengan alasan.
- Diskon tidak boleh melebihi total tagihan.
- Pembayaran tidak boleh melebihi sisa tagihan efektif. Kelebihan ditolak.
- VOID bersifat final; nota VOID tidak dapat diretur atau dikoreksi lagi.

### Pembelian dan utang supplier

Pembelian hanya tersedia bila pemilik mengaktifkan **Supplier & Reseller**
dan sub-fitur **Pembelian & Utang Supplier**.

1. Buka **Supplier & Reseller → Pembelian & Utang**.
2. Buat pembelian: pilih supplier dan barang, isi qty dan harga, atur diskon,
   ongkir, PPN, serta DP bila ada.
3. Pembelian KREDIT menambah utang supplier dan jatuh tempo sesuai termin.
4. Barang langsung masuk stok. HPP rata-rata bergerak diperbarui.
5. Pembayaran utang dicatat per pembelian dan dibatasi sisa utang.
6. Retur pembelian dibatasi qty per baris dan mengembalikan stok, utang, serta
   kas sesuai nilai retur.
7. Pembatalan pembelian (VOID) membalik stok dan utang; pembayaran yang sudah
   terjadi tetap tercatat sebagai riwayat.

### Saldo awal toko

Saldo awal diisi satu kali per toko sebelum transaksi berjalan:

1. **Pengaturan → Saldo awal toko**.
2. Tambahkan stok awal, utang supplier awal, dan piutang pelanggan awal.
3. Setelah disimpan, saldo awal tidak dapat diedit langsung. Gunakan
   **Koreksi saldo awal** (pemilik) yang membalik saldo lama dan membuat saldo
   baru; keduanya tercatat di audit.
4. Saldo awal ikut laporan stok, aging utang supplier, dan laporan saldo awal.

## 3. Backup dan pemulihan

### Backup

- **Backup otomatis** berjalan berkala sesuai pengaturan aplikasi. Berkas
  disimpan di folder backup aplikasi.
- **Backup manual**: **Pengaturan → Backup manual**. Gunakan passphrase yang
  kuat untuk ekspor terenkripsi dan simpan di perangkat terpisah.
- Backup memuat seluruh tabel pembukuan, pengaturan, fitur toko, saldo awal,
  pembelian/utang, dan konflik.

### Restore

1. Pastikan aplikasi tidak sedang melakukan transaksi.
2. **Pengaturan → Pulihkan backup**, pilih berkas, masukkan passphrase.
3. Aplikasi memverifikasi isi backup, menolak berkas rusak atau versi yang
   tidak dikenal, lalu mengganti database secara atomik. Bila proses terputus,
   database lama dipulihkan otomatis saat aplikasi dibuka.
4. Setelah restore, periksa data contoh: satu nota lama, stok, saldo awal,
   pembelian terakhir, dan antrean sinkronisasi.

### Disaster recovery

1. Siapkan perangkat pengganti dan pasang aplikasi versi yang sama atau lebih
   baru.
2. Restore backup terbaru yang sudah diverifikasi.
3. Pasangkan perangkat ke relay bila memakai beberapa perangkat. Perangkat
   dengan data lokal lebih baru dapat mengirim ulang antreannya.
4. Bila database lokal tidak dapat dibuka, jangan membuat database baru di
   path yang sama. Salin berkas `.db` yang rusak untuk investigasi, lalu
   restore ke path baru.

## 4. Menangani konflik sinkronisasi

Buka **Sinkronisasi → Konflik**. Setiap konflik menampilkan alasan dan detail.

- **Versi lokal lebih baru / harga dikunci pemilik / harga di bawah batas**:
  periksa harga jasa atau barang. Perbaiki di sumbernya, lalu ulangi
  sinkronisasi.
- **Stok negatif**: periksa mutasi stok dan opname. Koreksi lewat opname,
  bukan dengan mengubah baris ledger.
- **Pembayaran melebihi total efektif**: catat ulang nominal yang benar.
- **Retur melebihi qty / retur pada nota VOID**: periksa nota asal. Retur
  harus mengacu pada qty yang tersisa.
- **Pembelian tanpa supplier / nomor pembelian bentrok**: lengkapi supplier
  atau ubah nomor dokumen.
- **Saldo awal stok berubah**: saldo awal hanya boleh dibuat sekali. Gunakan
  koreksi saldo awal agar jejak audit tetap utuh.
- **Data tidak dapat dibuka / tanda tangan tidak valid**: jangan paksakan.
  Cabut perangkat pengirim bila mencurigakan, lalu impor ulang dari perangkat
  tepercaya.
- **Pengirim dicabut / akun nonaktif**: data dari perangkat atau akun tersebut
  ditolak. Aktifkan kembali akses hanya bila memang sah.

Setelah konflik diperbaiki, tekan **Sinkronkan** ulang. Jangan menghapus baris
konflik sebelum masalahnya selesai.

## 5. Fitur opsional per toko

Pemilik dapat menyalakan atau mematikan fitur di **Pengaturan → Fitur toko**:

- Estimasi
- Antrian / Order Kerja
- Supplier & Reseller (induk)
- Pembelian & Utang Supplier (hanya efektif bila induk aktif)
- Follow Up Pelanggan
- Unit / Kendaraan
- WhatsApp

Aturan:

- Mematikan fitur tidak menghapus data. Riwayat dan laporan tetap dapat
  dibaca dan ikut backup.
- Fitur nonaktif berlaku untuk semua peran, termasuk pemilik.
- Hanya pemilik penuh yang dapat mengubah.
- Pilihan sub-fitur dipertahankan saat induk dimatikan.
- Perangkat yang belum menerima perubahan flag tetap dapat mengirim data lama;
  data yang dibuat setelah penonaktifan ditolak.

## 6. Privasi dan retensi

- Data transaksi disimpan terenkripsi di perangkat. Relay hanya menyimpan
  amplop terenkripsi dan metadata sinkronisasi.
- Log diagnostik tidak memuat kata sandi, token, passphrase, atau data pribadi
  lengkap. Ekspor diagnostik meredaksi nilai sensitif.
- **Diagnostik perangkat** menampilkan integritas database, ukuran berkas,
  antrean, dan ringkasan konflik. Bagikan hanya kepada tim dukungan.
- Retensi:
  - Outbox terkirim dan `applied_deltas` lama dibersihkan setelah 90 hari.
  - Konflik selesai tetap ada sampai dibersihkan dari layar konflik.
  - Backup lokal mengikuti pengaturan jumlah berkas; simpan salinan luar
    perangkat untuk pemulihan bencana.
  - Log relay disimpan maksimal 30 hari dan tidak memuat kredensial.
- Pemilik dapat meminta penghapusan data toko dengan menghapus toko dan
  seluruh backup terkait. Tindakan ini tidak dapat dibatalkan.

## 7. Checklist rilis dan serah terima

- [ ] Owner dan minimal satu admin sudah memiliki akun.
- [ ] PIN owner diganti dari bawaan dan dicatat aman.
- [ ] Toko, nama, alamat, dan fitur opsional sudah dipilih.
- [ ] Saldo awal toko sudah diisi dan direkonsiliasi.
- [ ] Backup otomatis aktif; satu backup manual sudah diuji restore.
- [ ] Relay (bila dipakai) sehat, TLS aktif, dan perangkat sudah dipasangkan.
- [ ] Konflik sinkronisasi nol.
- [ ] Pelatihan singkat per peran selesai (bagian 1 dan 2).
- [ ] Kontak dukungan dan prosedur insiden diketahui pemilik.
