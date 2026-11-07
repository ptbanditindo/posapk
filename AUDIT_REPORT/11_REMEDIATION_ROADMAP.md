# 11 — Peta Jalan Remediasi

**Metode:** disusun dari temuan statis di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md). Tidak ada perbaikan kode, migrasi, test, atau build yang dijalankan. Urutan di bawah adalah rekomendasi, bukan catatan pekerjaan yang sudah dilakukan.

**Prinsip urutan:**

1. Hentikan dulu kerusakan uang/stok yang sedang berjalan.
2. Perbaiki identitas dan otorisasi yang membuat kontrol bisnis tidak berlaku.
3. Perbaiki model data lintas perangkat dan idempotensi.
4. Samakan perhitungan/tampilan agar keputusan pemilik benar.
5. Perkuat backup/restore sebagai jaring pengaman terakhir.
6. Sisir temuan rendah dan area yang memerlukan validasi aturan bisnis.

---

## Fase 0 — Penghentian dampak (segera)

**Tujuan:** mencegah uang keluar ganda, stok berlebih/negatif, dan retur tidak sah yang sedang berpotensi terjadi di lapangan.

| ID | Tindakan inti | Alasan urutan |
|---|---|---|
| BL-02 | Validasi ulang retur/void di penerima: tolak retur pada nota VOID, batasi total retur per baris, hitung ulang restock void | Dampak langsung ke stok, refund, dan status nota |
| BL-01 | Kirim qty absolut opname (bukan hanya delta) atau sertakan qty sistem asal; tolak opname yang basisnya berbeda | Stok dapat menyimpang permanen |
| BL-03 | Tolak pembayaran gaji kedua untuk employee+cycle; jangan update baris lama secara diam-diam | Kas keluar dua kali untuk satu kewajiban |
| BL-14 | Validasi sisa tagihan terbaru di penerima; tolak pembayaran yang melebihi sisa | Piutang bisa negatif/overpaid |
| BL-13 | Tambahkan idempotency key retur dan pelunasan yang stabil dari UI | Retry jaringan/ketukan ganda menggandakan transaksi |
| BL-06 | Periksa `aktif` pada `_deviceAuth` dan `_employeeCanSend`; cabut perangkat saat akun dinonaktifkan; cek ulang saat unlock | Mantan karyawan masih dapat menulis |

**Kriteria keluar fase:**

- Retur/void/pelunasan/gaji kedua ditolak atau dianggap duplikat secara eksplisit, bukan diterapkan.
- Opname dua perangkat tidak lagi mengubah stok berdasarkan delta yang salah basis.
- Akun nonaktif tidak dapat mengirim amplop atau membuka sesi baru.

**Catatan:** BL-02 dan BL-01 berstatus SUSPECTED; sebelum menulis aturan final, konfirmasi aturan bisnis retur/opname (lihat bagian Validasi).

---

## Fase 1 — Identitas, akun, dan otorisasi

**Tujuan:** memastikan kontrol peran dan status akun berlaku sama di aplikasi, relay, dan perangkat lain.

| ID | Tindakan inti | Ketergantungan |
|---|---|---|
| BL-07 | Sertakan `employee_accounts` (tanpa kredensial) dalam snapshot; buat akun lokal saat login karyawan; salin saat buat toko | Fondasi untuk BL-04 dan payroll |
| BL-08 | Hitung ulang operator setelah `switchStore`; tolak akses bila toko tidak ada di `storeIds` | — |
| BL-10 | Kirim semua akun termasuk `aktif:false`; push otomatis setelah perubahan; hormati `permission_version` | BL-06 |
| BL-11 | Kirim role/izin/toko/username dalam envelope (tanpa PIN/password), dengan HLC dan validasi owner | BL-08, BL-10 |
| BL-09 | Gunakan izin `retur` di service dan relay, bukan `void` | — |
| BL-12 | Wajibkan izin untuk batal/revisi estimasi; cek status `aktif`; unique index `(nomor_estimasi, versi)` | Migrasi indeks |
| BL-27 | Tolak `actor == null` pada operasi yang memerlukan otorisasi | — |
| BL-37 | Samakan `createEstimate` dengan `createTransaction`: actor wajib | BL-27 |
| BL-31 | Teruskan operator, periksa izin, konsumsi kuota setelah commit, pertahankan tanggal yang masih relevan | — |
| BL-36 | Gunakan izin jenis order/`buat_order`, bukan hanya `buat_nota` | — |

**Kriteria keluar fase:**

- Perubahan role/aktif/izin konsisten di pemilik, relay, dan semua perangkat setelah sinkronisasi.
- Tidak ada service yang menganggap `null` sebagai owner.
- Izin retur, estimasi, order, dan follow-up sesuai pengaturan peran.

---

## Fase 2 — Model data lintas perangkat dan integritas relasi

**Tujuan:** menghilangkan penimpaan data dan divergensi yang berasal dari aturan bisnis yang tidak divalidasi di penerima.

| ID | Tindakan inti | Catatan |
|---|---|---|
| BL-41 | Tangkap `UNIQUE(kode)` saat apply; catat konflik `kode_bentrok`; jangan tahan amplop independen | Perlu strategi gabung/renumber |
| BL-15 | Buat amplop void self-contained (total dibayar/refund) atau terapkan urutan yang dijamin | Bergantung pada desain envelope |
| BL-30 | Lempar retry bila nota belum ada; catat konflik bila nota void; jangan tandai selesai | — |
| BL-04 | Simpan snapshot tarif komisi saat nota dibuat; gunakan snapshot saat rekalkulasi; jangan nol-kan bila akun hilang | BL-07 |
| BL-40 | Penerima retur memanggil rekalkulasi komisi berbasis snapshot | BL-04 |
| BL-34 | Void menyesuaikan komisi dan pembayaran tersimpan secara konsisten | BL-04 |
| BL-16 | Merge pelanggan memindahkan `service_records.customer_id`, unit, follow-up, dan referensi WA | Migrasi data |
| BL-21 | Reservasi/aturan konflik stok di relay atau tolak finalisasi yang membuat stok negatif | Perlu keputusan bisnis |
| BL-33 | Perkuat identitas perangkat (kode lebih panjang/acak) dan counter yang tahan bootstrap | Migrasi pengaturan |

**Kriteria keluar fase:**

- Tidak ada amplop yang menahan seluruh antrean karena satu konflik yang tidak terkait.
- Retur/void/komisi menghasilkan nilai yang sama di semua perangkat.
- Merge pelanggan tidak meninggalkan nota tanpa nama pelanggan.

---

## Fase 3 — Konsistensi perhitungan dan laporan

**Tujuan:** memastikan angka yang dilihat pemilik di dashboard, riwayat, struk, dan laporan berasal dari definisi yang sama.

| ID | Tindakan inti | Dampak |
|---|---|---|
| BL-05 | Gunakan satu fungsi total efektif (total + koreksi − retur) di daftar, detail, struk, dan laporan | Keputusan harga/piutang |
| BL-17 | Join pelanggan memakai `COALESCE(service_records.customer_id, unit.customer_id)` di semua query | Riwayat/pencarian |
| BL-18 | Struk menampilkan total terkoreksi dan kembalian dari pembayaran yang relevan, atau hentikan cetak ulang yang menyesatkan | Bukti pelanggan |
| BL-19 | Definisikan "pendapatan hari ini" (bruto/neto/kas) dan terapkan konsisten | Dashboard |
| BL-23 | Rekonsiliasi membandingkan nilai, retur, dan pembayaran, bukan hanya ID nota | Deteksi divergensi |
| BL-25 | Penanda jatuh tempo memakai total efektif, bukan total asli | Penagihan |
| BL-39 | Kembalian per pembayaran tunai (termasuk pelunasan/refund) | Bukti kas |

**Kriteria keluar fase:**

- Satu nota menunjukkan total yang sama di semua layar dan struk.
- Laporan penjualan, laba, dan dashboard dapat direkonsiliasi ke baris pembayaran/retur.
- Tidak ada angka "pendapatan" yang berubah definisi antarlayar.

---

## Fase 4 — Backup, restore, dan ketahanan proses

**Tujuan:** memastikan backup benar-benar dapat dipulihkan dan restore tidak menghilangkan data saat proses terhenti.

| ID | Tindakan inti | Catatan |
|---|---|---|
| BL-42 | Pertukaran atomik: rename DB lama → `.old`, rename baru → aktif, hapus `.old` setelah verifikasi; fsync; pemulihan startup dari `.bak`/`.restore.tmp` | Wajib sebelum mengandalkan restore |
| BL-20 | Terapkan batas total hasil dekompresi dan cek ruang disk sebelum menulis | Samakan dengan batas pembuatan arsip |
| BL-22 | Jangan tampilkan passphrase tanpa autentikasi ulang; sediakan alur ekspor yang aman | Kontrol akses |
| BL-32 | Checkpoint/buka sementara toko nonaktif sebelum dibaca pada semua platform | Kelengkapan backup |

**Kriteria keluar fase:**

- Restore yang terhenti di titik mana pun dapat dilanjutkan/dipulihkan tanpa intervensi manual.
- Backup tidak pernah "sukses" dengan data toko nonaktif yang tertinggal di WAL.
- Passphrase tidak dapat dibaca oleh orang yang hanya melihat layar.

---

## Fase 5 — Temuan rendah dan kebijakan residual

| ID | Tindakan inti |
|---|---|
| BL-24 | Tetapkan kebijakan stok negatif (blokir/konfirmasi owner) dan terapkan di semua jalur |
| BL-26 | Tambahkan filter `deleted_at` pada daftar stok, cek kode, validasi jual, dan dashboard |
| BL-28 | Tambahkan principal `viewer` yang menolak semua izin tulis; buka DB viewer read-only bila mungkin |
| BL-29 | Gunakan waktu server yang ditandatangani dan simpan waktu terakhir terlihat |
| BL-35 | Periksa masa lisensi pada `_deviceAuth` atau batasi endpoint premium |
| BL-38 | Soft-delete relasi supplier dengan tombstone yang disinkronkan, atau kirim penggantian penuh |

---

## Matriks cakupan seluruh temuan

| Fase | ID |
|---|---|
| 0 | BL-01, BL-02, BL-03, BL-06, BL-13, BL-14 |
| 1 | BL-07, BL-08, BL-09, BL-10, BL-11, BL-12, BL-27, BL-31, BL-36, BL-37 |
| 2 | BL-04, BL-15, BL-16, BL-21, BL-30, BL-33, BL-34, BL-40, BL-41 |
| 3 | BL-05, BL-17, BL-18, BL-19, BL-23, BL-25, BL-39 |
| 4 | BL-20, BL-22, BL-32, BL-42 |
| 5 | BL-24, BL-26, BL-28, BL-29, BL-35, BL-38 |

Tidak ada ID yang terlewat; total 42 temuan.

---

## Area yang memerlukan validasi aturan bisnis

Sebelum mengubah kode pada temuan berikut, pemilik harus memutuskan aturannya:

1. **Retur:** apakah memakai izin `retur`, `void`, atau keduanya; apakah retur boleh melebihi qty per baris setelah retur sebelumnya; bagaimana retur pada nota yang sudah void (BL-02, BL-09, BL-13).
2. **Stok negatif:** apakah boleh, atau harus diblokir/dikonfirmasi owner (BL-21, BL-24).
3. **Opname:** apakah qty absolut harus menang atas penjualan yang belum tersinkron, atau opname ditolak bila basis berbeda (BL-01).
4. **Pelunasan:** apakah pembayaran yang tiba bersamaan boleh melebihi sisa dan menjadi saldo pelanggan, atau harus ditolak (BL-14).
5. **Gaji:** apakah satu siklus hanya boleh dibayar sekali secara global; bagaimana bila dua perangkat membayar bersamaan (BL-03).
6. **Komisi:** apakah memakai tarif snapshot saat nota atau tarif berlaku saat pembayaran; bagaimana bila akun dihapus (BL-04, BL-40).
7. **Akun karyawan:** apakah harus ikut snapshot dan dibuat otomatis saat login, atau tetap dikelola relay (BL-07).
8. **Viewer:** apakah boleh menulis apa pun ke salinan lokal (BL-28).
9. **Pendapatan:** definisi bruto, neto retur, atau kas diterima untuk dashboard (BL-19).
10. **Kode barang:** unik global per toko atau boleh berbeda antardevice dengan renumber otomatis (BL-41).
11. **Follow-up:** apakah perubahan status boleh menghapus tanggal servis/janji bayar (BL-31).
12. **Modul pembelian:** konfirmasi bahwa memang tidak ada pembelian bernilai/utang supplier, sehingga tidak ada yang perlu diaudit (laporan 02 dan 04).

---

## Dependensi dan risiko implementasi

| Perubahan | Dependensi | Risiko |
|---|---|---|
| Snapshot tarif komisi (BL-04) | Skema komisi + BL-07 | Data lama tidak memiliki snapshot; perlu nilai fallback dan migrasi hati-hati |
| Envelope role/izin (BL-11) | BL-08, BL-10 | Perlu validasi owner dan penolakan dari perangkat lama |
| Unique index estimasi (BL-12) | Migrasi indeks | Data duplikat yang sudah ada harus dibersihkan lebih dulu |
| Renumber kode barang (BL-41) | Kebijakan kode | Renumber dapat membingungkan pelanggan; perlu persetujuan owner |
| Restore atomik (BL-42) | Platform IO | Perilaku rename/fsync berbeda di Android/Windows/macOS |
| Reservasi stok (BL-21) | Relay/desain sync | Perlu keputusan online/offline; jangan memblokir kasir offline tanpa alternatif |

**Prinsip migrasi:** tambahkan kolom/tabel baru, isi data lama dengan nilai yang dapat dipertanggungjawabkan, baru aktifkan aturan baru. Jangan mengubah data historis tanpa jejak audit. Uji migrasi pada salinan database nyata sebelum rilis (rekomendasi, bukan pekerjaan yang dilakukan audit ini).

---

## Definisi selesai per tingkat risiko

- **KRITIS (BL-01, BL-02):** tidak ada lagi jalur yang dapat membuat stok/refund/status nota berbeda antardevice tanpa penolakan atau konflik eksplisit.
- **TINGGI (BL-03, BL-04, BL-05, BL-06, BL-07, BL-08, BL-42):** uang tidak dapat keluar dua kali untuk kewajiban yang sama; izin mengikuti akun/toko; laporan dan struk memakai total yang sama; restore tidak kehilangan database.
- **SEDANG:** retur/pelunasan/estimasi/opname memiliki validasi penerima dan idempotensi; sinkronisasi tidak berhenti total karena satu konflik; backup lolos batas ukuran dan tidak membocorkan passphrase.
- **RENDAH:** query menghormati soft delete, viewer benar-benar read-only, lisensi memakai waktu tepercaya, relasi supplier memiliki tombstone.

---

## Batas roadmap

- Roadmap ini tidak memperkirakan durasi, biaya, atau jumlah orang.
- Tidak ada perubahan kode/skema yang dilakukan; semua item adalah rekomendasi.
- Urutan dapat berubah bila pemilik memprioritaskan fitur tertentu, tetapi Fase 0 sebaiknya tidak ditunda karena melibatkan uang dan stok.
- Setiap perbaikan memerlukan verifikasi pada data nyata dan skenario multi-perangkat; audit statis tidak dapat membuktikan hasil akhirnya.
