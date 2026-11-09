# PusatkuPOS — Rencana Implementasi Satu Putaran (v2)

**Status:** desain selesai dan direvisi (v2), belum ada kode yang diubah.
**Tanggal:** 9 November 2026.
**Sumber:** 15 laporan `AUDIT_REPORT/` + keputusan pemilik pada sesi desain + keputusan revisi D22, D25, D28 yang disetujui pemilik.

Dokumen ini adalah satu-satunya sumber keputusan dan urutan kerja. `AUDIT_REPORT/`
tetap menjadi bukti kode. Jika ada pertentangan, dokumen ini menang untuk
keputusan, dan laporan audit menang untuk bukti implementasi.

## Riwayat Revisi v2

| Perubahan | Lokasi |
|---|---|
| Restore dua jalur (lokal + cloud), keduanya wajib autentikasi owner (D22, merevisi D8) | §2, §3.8, F0-3 |
| Gate purge diperketat: periode tutup, status final, escrow, uji restore arsip, premium aktif, stub lokal (D23) | §3.6, F7-5 |
| Tutup buku bulanan agar laporan tidak berubah setelah purge (D24) | §3.4, §3.6, F7-11 |
| Konflik void/retur deterministik + kompensasi + bantuan owner (D25) | §3.5, F6-3, F6-8, F6-9 |
| Versi protokol envelope (D26) | §3.5, F6-7 |
| Premium berakhir: arsip baca-saja 12 bulan + ekspor (D27) | §1.2, F7-10 |
| Recovery diperkuat: frasa pemulihan + Argon2id, Shamir 2-dari-3 (D28, merevisi D13) | §3.7, F8-1 |
| Aturan kerja no. 4 dikonfirmasi pemilik: belum ada toko/perangkat dengan data hidup | Aturan kerja |
| F3-5 dipindah ke F4-9; F8-9 dipindah ke F4-10 (dependensi) | §6 |
| Task baru: F3-9 (zona waktu, REP-05), F6-7, F6-8, F6-9, F7-10, F7-11, F8-10 | §6 |
| Banner/panel sync hanya untuk premium dengan sync aktif; sesi lokal tanpa TTL jaringan | §1.1, F0-10, F5-3 |
| Peta temuan dan definisi selesai diperbaiki (REP-05, TRX-06, ARC-02, F0–F10) | §7, §12 |
| Empat matriks rujukan ditambahkan: rahasia, sumber laporan, konflik, versi protokol | Lampiran A–D |

## Aturan kerja

1. Implementasi berjalan F0 → F10. Tidak ada pertanyaan bisnis baru di tengah
   jalan; semua default sudah ditetapkan di §2 dan Lampiran A–D.
2. Satu task selesai hanya jika kode, uji otomatis, dan skenario manualnya lulus.
3. Jika kode nyata berbeda dari bukti audit, berhenti dan perbarui dokumen ini
   sebelum mengubah perilaku. Jangan berimprovisasi.
4. Tidak ada migrasi bertahap. Schema ditulis ulang sebagai baseline baru.
   Syarat (dikonfirmasi pemilik 9 November 2026): tidak ada toko atau perangkat
   yang memegang data hidup. Jika ternyata ada, D18 batal dan F1-1 diganti
   migrasi satu arah dengan backup wajib.
5. Jangan mengubah data historis untuk memperbaiki laporan. Koreksi selalu
   dokumen baru.
6. Sebelum F0 dimulai, perbarui `00_EXECUTIVE_SUMMARY.md` §4.3 dan
   `13_REAL_WORLD_SCENARIO_AUDIT.md`: opsi B (jual dengan konfirmasi) diganti
   D3 (blokir), supaya hanya ada satu sumber kebenaran.

---

## 1. Batasan yang Tidak Berubah

- Aplikasi tetap **local-first** dan harus mampu beroperasi penuh minimal
  **24 jam tanpa jaringan**: jual, stok, riwayat, cetak, retur, dan void lokal.
  Offline bukan mode normal, tetapi harus aman dan tidak memutus kasir.
- **Sync adalah fitur utama premium, bukan polling terus-menerus.** Sync dipicu
  commit, reconnect, start/resume, manual, dan fallback ringan; status per
  dokumen terlihat dan konflik diselesaikan saat sync berjalan.
- Relay tidak pernah membaca plaintext transaksi. Semua payload tetap E2EE.
- Satu toko dapat memiliki banyak perangkat; tidak ada batas jumlah login.
  Setiap perangkat tetap harus disetujui owner dan dapat dicabut.
- Uang disimpan dalam sen integer; qty dalam milli; pembulatan hanya di
  tampilan/struk akhir.
- Tablet mekanik **tidak boleh** menulis stok, menjual, atau membuat nota.
- Retensi lokal 1 tahun untuk riwayat service/nota; VPS menyimpan arsip lengkap
  selamanya.
- Dua VPS: satu untuk komunikasi (relay), satu untuk penyimpanan (arsip).
- Tidak ada penghapusan otomatis data historis selain purge lokal yang lolos
  gate di §3.6.
- Tidak ada plaintext nama, telepon, item, harga, atau nominal di VPS arsip.

### 1.1 Model Operasi Premium

Pengguna premium normalnya online, tetapi aplikasi harus tetap **penuh selama
minimal 24 jam tanpa jaringan**. Local-first bukan alasan untuk sync terus-
menerus; sync dipicu oleh peristiwa penting, bukan polling rapat.

| Aturan | Target |
|---|---|
| Kemampuan offline | minimal 24 jam penuh: jual, stok, riwayat, cetak, retur/void lokal |
| Sesi lokal | tidak punya TTL jaringan; tidak ada logout paksa. Hanya sync, arsip, pairing, dan multi-toko yang memeriksa lisensi |
| Sync setelah commit | mulai setelah debounce 3 detik; beberapa commit dijadikan satu batch |
| Sync saat reconnect/start/resume | segera |
| Sync manual | tarik untuk menyegarkan |
| Fallback periodik | ringan setiap 15 menit saat foreground, bukan polling 60 detik |
| Perangkat lain menerima data | pada sync berikutnya; biasanya <= 15 menit, atau segera saat resume/manual |
| Banner offline | setelah 24 jam tanpa sync sukses; hanya untuk toko premium dengan sync aktif; aplikasi tetap dapat dipakai |
| Toko gratis | tidak ada banner sync; diganti indikator “terakhir backup” |
| Keputusan stok | selalu dari ledger lokal; tidak pernah menunggu sync |
| Beban baterai/jaringan | batch, backoff, dan tanpa sync di background |

Pemicu sync: commit lokal (debounce + batch), konektivitas kembali, start/resume
aplikasi, timer fallback 15 menit saat foreground, dan aksi manual. Deteksi
konektivitas memakai event jaringan + health check relay; event jaringan saja
tidak menjamin relay hidup.

Keputusan stok tidak menunggu jaringan. Saat aplikasi terbuka dan online, sync
berjalan tanpa menahan layar untuk menyegarkan data. Jika stok lokal kurang,
penjualan diblokir; jika sync belum selesai, kasir tetap dapat menjual selama
stok lokal cukup. Banner 24 jam adalah peringatan agar data segera dikirim,
bukan tombol berhenti operasi.

### 1.2 Batas Gratis dan Premium

Operasi offline sepenuhnya gratis. Premium membayar layanan server, bukan akses
ke data lokal atau fitur kasir dasar.

| Kemampuan | Gratis | Premium |
|---|---|---|
| Jual, servis, order, retur, void, cetak | ya | ya |
| Stok masuk/keluar/opname dan izin per peran | ya | ya |
| Riwayat lokal dan laporan | ya | ya |
| Akun lokal: kasir, gudang, supervisor, mekanik, viewer | ya | ya |
| Backup/restore lokal | ya | ya |
| Satu toko | ya | ya |
| Sync multi-perangkat | tidak | ya |
| Arsip VPS, pencarian server, recovery cloud | tidak | ya |
| Multi-toko | tidak | ya |
| Follow up otomatis | kuota terbatas | tanpa batas |

Aturan:

1. Tidak ada cek lisensi di jalur lokal: buka aplikasi, jual, stok, opname,
   cetak, riwayat, dan backup tetap jalan tanpa server.
2. Lisensi hanya diperiksa oleh sync, arsip, pencarian server, pairing
   perangkat, dan multi-toko.
3. Jika premium berakhir, data lokal tetap dapat dibuka dan dipakai. Sync
   berhenti; tidak ada logout paksa atau penghapusan data. Purge berhenti
   seketika. Arsip menjadi baca-saja selama 12 bulan dan ekspor arsip lengkap
   tersedia (D27).
4. Akun gratis tanpa arsip tidak boleh dipurge otomatis. Riwayat lokal tetap
   ada sampai pengguna mengekspor atau memilih hapus sendiri.
5. Data pengguna gratis harus dapat diekspor tanpa membayar.

---

## 2. Keputusan Final

Kolom **Sumber** membedakan keputusan eksplisit pemilik dan default kerja yang
dipakai agar implementasi tidak berhenti. Default hanya mengubah aturan
service/UI, bukan arah arsitektur.

| ID | Keputusan | Sumber | Konsekuensi |
|---|---|---|---|
| D1 | Stok adalah agregat seluruh movement, bukan angka yang diketik | Pemilik | `stock_items.jumlah_milli` hanya berubah lewat `StockLedger.apply` |
| D2 | Izin stok dipisah: `stok_keluar`, `stok_masuk`, `opname`, dan `ubah_stok`; masing-masing dapat diberikan ke peran berbeda | Pemilik | Contoh default: kasir keluar, gudang masuk, supervisor hitung; tablet mekanik tetap read-only |
| D3 | Saat offline stok lokal kurang, penjualan diblokir | Pemilik | Tidak ada penjualan negatif lokal; pesan menyebut sisa stok |
| D4 | Keputusan stok selalu memakai ledger lokal; sync berjalan di latar belakang dan tidak pernah menahan transaksi | Pemilik | “Stok server” = hasil konvergensi movement, bukan angka plaintext di relay |
| D5 | Opname adalah koreksi hitung fisik, berbeda dari penambahan barang | Pemilik | Opname disimpan sebagai delta dengan basis absolut; barang masuk lewat pembelian |
| D6 | Void ditolak selama retur aktif; retur harus dibatalkan lebih dulu | Pemilik | Tidak ada refund ganda lokal/remote. Void dan retur yang terjadi bersamaan di dua perangkat diselesaikan oleh D25 |
| D7 | Logout tidak menghapus data; penghapusan hanya lewat “Reset perangkat” | Pemilik | Logout = tutup sesi; reset = aksi terpisah dengan autentikasi owner |
| D8 | Restore wajib autentikasi owner dan toko yang sama; tidak ada restore pra-login. Direvisi oleh D22: ada dua jalur | Pemilik, direvisi D22 | Restore tidak menimpa toko lain |
| D9 | Lokal purge riwayat service/nota setelah 1 tahun | Pemilik | Master, ledger stok, ledger kas, audit, dan pembelian tetap lokal. Gate tambahan di D23 |
| D10 | VPS menyimpan seluruh data lengkap selamanya | Pemilik | Arsip per dokumen + stream envelope; tidak pernah dipangkas |
| D11 | Dua VPS: relay komunikasi dan arsip penyimpanan | Pemilik | Client mengunggah langsung ke arsip dengan token dari relay |
| D12 | Pencarian arsip: exact nomor nota, token nama, rentang tanggal | Default kerja | Tidak ada pencarian teks bebas di server; hasil didekripsi lokal |
| D13 | Recovery: akun Google + Drive app data + kunci pemulihan; admin memegang offline recovery key. Diperkuat oleh D28 | Pemilik, diperkuat D28 | Rotasi kunci wajib saat perangkat dicabut; kunci lama disimpan |
| D14 | Harga: acuan + final per baris; nego per item; di bawah modal/negosiasi butuh persetujuan owner | Default kerja | PIN hanya membuka grant; grant dicatat sebagai audit |
| D15 | Laporan: nilai ditagih untuk penjualan, DPP untuk pajak; koreksi = dokumen negatif | Default kerja | Zona waktu toko; tidak ada recompute snapshot lama |
| D16 | Platform: Android kasir, Windows owner, tablet Android mekanik | Default kerja | Tanpa batas jumlah perangkat; rilis pilot setelah F8, rilis umum setelah F10 |
| D17 | Status sync terlihat untuk toko premium dengan sync aktif; banner setelah 24 jam tanpa sync sukses adalah peringatan, bukan penghentian operasi. Toko gratis memakai indikator “terakhir backup” | Pemilik | Kasir tetap dapat bekerja; banner mendorong penyelesaian sync; toko gratis tidak melihat alarm sync yang tidak relevan |
| D18 | Schema ditulis ulang sebagai baseline, tanpa rantai migrasi | Pemilik | Sah selama syarat aturan kerja no. 4 terpenuhi (sudah dikonfirmasi) |
| D19 | Deteksi konektivitas memakai event jaringan (`connectivity_plus`) + health check relay; fallback periodik ringan 15 menit | Default kerja | Event jaringan saja tidak dianggap online sampai health check relay berhasil |
| D20 | Tidak ada polling 60 detik; commit dibatch dengan debounce 3 detik dan sync hanya saat foreground | Default kerja | Offline minimal 24 jam tetap aman; baterai dan relay tidak dibebani |
| D21 | Seluruh operasi offline gratis; premium hanya untuk layanan server (sync, arsip, pencarian server, multi-perangkat, multi-toko) | Pemilik | Tidak ada cek lisensi di jalur lokal; akun karyawan dan peran lokal harus gratis |
| D22 | Restore punya dua jalur, keduanya wajib autentikasi owner. Lokal: file backup terenkripsi + frasa backup (= frasa pemulihan yang sama, Lampiran A) + PIN owner bila DB aktif ada, tanpa jaringan, gratis. Cloud: Google Sign-In owner + store id sama | Pemilik (disetujui) | Pengguna gratis dan perangkat offline tetap bisa restore; tidak ada restore tanpa owner |
| D23 | Purge butuh gate tambahan: periode tutup buku, dokumen final, escrow terverifikasi, uji restore arsip lulus, premium aktif. Purge meninggalkan stub lokal; nota terpurge dibuka lewat arsip | Default kerja | Purge mati lewat flag `purge_enabled` sampai F8-8 lulus |
| D24 | Tutup buku bulanan: snapshot agregat per bulan (zona waktu toko) yang tidak ikut dipurge; laporan periode lama dibaca dari snapshot | Default kerja | Laporan tahunan dan pajak tidak berubah setelah purge; matriks sumber di Lampiran B |
| D25 | Konflik diselesaikan deterministik dengan urutan HLC; dokumen yang kalah dibalik dengan dokumen kompensasi oleh perangkat asalnya; jika sulit atau tidak dapat ditentukan, owner membantu menyelesaikan lewat layar Konflik | Pemilik (disetujui) | Semua perangkat konvergen; kasus sulit tidak diam-diam hilang; matriks lengkap di Lampiran C |
| D26 | Versi protokol di header envelope. Klien lama berhenti menerapkan envelope baru, tetap bisa jual lokal | Default kerja | Tidak ada penerapan aturan lama pada data baru; matriks versi di Lampiran D |
| D27 | Premium berakhir: purge berhenti seketika, arsip baca-saja 12 bulan, ekspor arsip tersedia | Default kerja | Tidak ada data terkunci |
| D28 | Recovery key diperkuat: blob di Drive dibuka dengan frasa pemulihan (>= 6 kata) + Argon2id, bukan PIN 6 digit. Master recovery key admin dibagi Shamir 2-dari-3 | Pemilik (disetujui) | Akun Google yang diambil alih tidak cukup untuk membuka riwayat; satu kunci admin tidak membuka semua toko; matriks rahasia di Lampiran A |

Default D12, D14, D15, D16, D19, D20, D23, D24, D26, dan D27 boleh diubah
setelah dokumen ini disetujui. Perubahan tersebut tidak membatalkan keputusan
pemilik dan tidak memerlukan perubahan arsitektur.

---

## 3. Aturan Domain

### 3.1 Stok

**Invarian:** untuk setiap `stock_items`, saldo = jumlah seluruh movement yang
tercatat. Tidak ada penulisan langsung ke `jumlah_milli` di luar
`StockLedger.apply`.

Sumber movement yang wajib ada:

| Jenis | Sumber | Arah |
|---|---|---|
| Penjualan | `service_record` | keluar |
| Retur penjualan | `sale_return` | masuk |
| Void penjualan | `service_record` | masuk, hanya qty yang tidak aktif diretur |
| Pembelian | `purchase` | masuk |
| Retur pembelian | `purchase_return` | keluar |
| Opname | `opname` | koreksi absolut |
| Saldo awal | `opening_balance` | masuk |
| Penyesuaian manual | `manual` | masuk/keluar, wajib alasan + operator |

**Izin stok terpisah.** Tidak ada satu izin “stok” yang mencakup semuanya:

| Aksi | Izin | Contoh default |
|---|---|---|
| Barang keluar / penjualan yang memakai stok | `stok_keluar` | KASIR |
| Barang masuk / penerimaan | `stok_masuk` | GUDANG |
| Hitung fisik dan opname | `opname` | SUPERVISOR |
| Ubah data master stok | `ubah_stok` | owner/supervisor |

Default contoh: KASIR hanya `stok_keluar`; GUDANG hanya `stok_masuk`;
SUPERVISOR `opname` + `ubah_stok`; MEKANIK dan VIEWER tanpa izin stok; owner
semua. Owner dapat memberi kombinasi lain ke peran kustom.

Aturan:

1. Setiap aksi memeriksa izinnya sendiri di service dan UI; izin tidak boleh
   saling menggantikan. Menjual barang yang mengurangi stok memerlukan
   `stok_keluar`; servis tanpa part tidak memerlukannya.
2. Penerimaan barang memerlukan `stok_masuk` dan tidak otomatis memerlukan
   `buat_pembelian`; pencatatan pembelian/utang tetap izin terpisah.
3. Opname memerlukan `opname`. Operator dengan izin ini boleh menghitung dan
   menerapkan delta; perubahan master tetap memerlukan `ubah_stok`.
4. Peran GUDANG ditambahkan sebagai peran bawaan dengan `lihat_stok` dan
   `stok_masuk`; peran kustom boleh diberi kombinasi izin apa pun oleh owner.
5. Tablet mekanik tetap read-only karena default-nya tidak memiliki izin stok.
   Perangkat gudang yang diberi `stok_masuk` boleh menerima barang.
6. Penjualan lokal memeriksa saldo sebelum commit. Jika `saldo - qty < 0`,
   transaksi ditolak (D3). Tidak ada dialog “lanjutkan”.
7. Penerapan sync boleh menghasilkan saldo negatif karena movement dari
   perangkat lain. Saldo negatif tidak diperbaiki otomatis; muncul di laporan
   dan memicu opname.
8. HPP memakai rata-rata bergerak. Movement keluar menyimpan
   `harga_pokok_satuan_cents`; movement retur memakai snapshot HPP penjualan,
   bukan harga master saat ini.
9. Jika saldo sebelum masuk <= 0, pemulihan stok tidak boleh menggelembungkan
   rata-rata. Nilai masuk tetap dipakai, tetapi HPP baris keluar berikutnya
   dihitung dari basis yang sudah dibersihkan; tidak ada HPP negatif.
10. Opname:
    - operator dengan izin `opname` (default supervisor) menghitung fisik;
    - sistem menyimpan `opname_absolut_milli` (hasil hitung) dan
      `opname_basis_milli` (saldo lokal saat hitung);
    - movement yang dikirim adalah delta idempoten, bukan angka absolut yang
      menimpa perangkat lain;
    - `request_id` wajib; hold yang gagal tidak memblokir hold lain.
11. Rekonsiliasi harian: saldo vs jumlah movement, saldo negatif, movement
    tanpa dokumen, dan dokumen tanpa movement. Laporan tidak mengubah data.
12. Tidak ada `CHECK (jumlah_milli >= 0)` pada saldo, karena sync sah dapat
    menghasilkan negatif. Yang ditegakkan adalah guard lokal dan laporan.

### 3.2 Harga dan Persetujuan

Data yang sudah tersedia di `service_jobs`: `harga_jual_terdaftar`,
`harga_batas_saat_transaksi`, `harga_final`, `diskon_alokasi`, `alasan_diskon`,
`disetujui_oleh`. Tidak perlu kolom baru untuk harga acuan.

Aturan:

1. **Harga acuan** = `harga_jual_terdaftar`.
   - Jasa katalog: harga katalog saat transaksi.
   - Jasa manual: kasir wajib mengisi “Harga normal” dan “Harga disepakati”.
   - Part: harga jual master saat transaksi.
2. **Harga final** = `harga_final`. Jika final < acuan, `alasan_diskon` wajib
   dan permission `permissionChangeServicePrice` diperlukan untuk non-owner.
3. Jika final < modal (part, atau jasa yang punya modal) atau final = 0:
   - owner PIN / approver secret diverifikasi di luar transaksi;
   - satu grant berlaku untuk seluruh baris di transaksi itu;
   - grant dicatat di `business_audits` dengan aksi
     `harga_di_bawah_modal`, berisi approver, alasan, daftar baris, waktu,
     dan masa berlaku;
   - nota menyimpan `disetujui_oleh` + `alasan_diskon` per baris.
4. PIN tidak pernah menjadi otorisasi itu sendiri. PIN hanya membuka layar
   persetujuan; grant yang memberi izin.
5. Modal baris = HPP rata-rata ledger saat transaksi, bukan harga master.
6. Struk menampilkan harga acuan, diskon, dan harga final bila berbeda.
7. Jasa manual dengan modal 0 adalah jasa tenaga kerja; laporan laba
   menampilkannya sebagai kelompok “jasa tanpa modal”, bukan laba 100% tanpa
   penjelasan.

### 3.3 Void dan Retur

1. Sebelum void lokal atau penerapan void remote, periksa `sale_returns`
   dengan `status = 'AKTIF'` untuk nota tersebut.
2. Jika ada retur aktif: tolak void. Kasir harus membatalkan retur lebih dulu.
3. Restock void hanya untuk qty yang belum diretur:
   `qty_jual - qty_retur_aktif`.
4. Pembatalan retur lokal membatasi qty pada stok yang masih tersedia; jika
   barang sudah terjual lagi, pembatalan ditolak dan ditampilkan sebagai
   konflik.
5. Penerapan remote memakai aturan yang sama. Void remote yang melanggar
   aturan tidak diterapkan sebagian; diselesaikan lewat aturan konflik §3.5
   butir 6 (kompensasi atau bantuan owner).
6. Refund void = nilai efektif nota - nilai retur aktif. Refund retur memakai
   snapshot DPP/PPN dan HPP penjualan.
7. Semua aksi void/retur menulis `business_audits`.
8. Nota yang sudah dipurge: void ditolak. Retur atau klaim atas nota terpurge
   boleh dilakukan secara online lewat “Buka dari arsip”. Retur adalah dokumen
   baru dengan `ref_doc_id`; bundle terdekripsi hanya dipakai sementara dan
   tidak ditulis ulang ke tabel nota.

### 3.4 Laporan dan Pajak

1. Snapshot pajak per nota (`pajak_snapshot_json`, `pajak_dpp`, `pajak`,
   `pajak_diserap`) adalah sumber kebenaran. Laporan tidak menghitung ulang
   dengan tarif saat ini.
2. Dua basis yang harus konsisten:
   - **Penjualan:** nilai ditagih (`total`/`total_efektif`).
   - **Pajak:** DPP dan PPN dari snapshot.
3. Retur adalah dokumen negatif: mengurangi DPP, PPN, omzet, dan HPP pada
   periode retur. Nota asal tidak diubah.
4. Penyesuaian nota memisahkan komponen jasa, part, diskon, DPP, dan PPN;
   koreksi juga mengubah HPP, laba, dan PPN, bukan hanya omzet. Nilai yang
   tidak ber-PPN (TANPA) tidak boleh masuk rekap DPP, baik headline maupun
   detail.
5. Laba kotor:
   - jika PPN aktif: DPP - HPP;
   - jika PPN tidak aktif: nilai ditagih - HPP.
6. Tanggal laporan memakai zona waktu toko (default `Asia/Jakarta`). Data
   disimpan UTC; semua filter tanggal (termasuk `marginReport`) dikonversi ke
   rentang UTC yang sama.
7. Semua agregasi uang memakai integer. Tidak ada pembagian REAL di SQL.
   Pembulatan hanya di tampilan/struk.
8. Laporan wajib: harian kasir, penjualan, laba kotor, stok, piutang, pajak,
   komisi. Piutang hanya nota kredit yang belum lunas dan tidak VOID; kas
   hanya mutasi CASH/TRANSFER.
9. Nota VOID tetap tampil dengan badge dan nilai 0, bukan hilang dari riwayat.
10. Periode tertutup (D24): laporan periode yang sudah ditutup dibaca dari
    `period_closings`; laporan di jendela lokal dibaca dari nota. Matriks
    sumber laporan ada di Lampiran B. Koreksi atas periode tertutup berupa
    dokumen koreksi di periode berjalan, tidak mengubah snapshot. Nota
    terlambat menerbitkan revisi snapshot `rev n+1`; snapshot lama tidak
    diubah.

### 3.5 Sync dan Idempotensi

1. Setiap dokumen punya `request_id` + hash payload. Request yang sama
   mengembalikan dokumen yang sama; payload berbeda ditolak.
2. Outbox memiliki status per dokumen: pending, sending, acked, failed,
   dead-letter. UI riwayat menampilkan status per dokumen.
3. Cursor hanya maju setelah envelope diterapkan. Envelope yang gagal
   diverifikasi masuk dead-letter setelah N percobaan dan tidak menahan
   envelope lain.
4. `applied_deltas` disimpan permanen (atau minimal selama umur arsip), bukan
   dipangkas 90 hari.
5. Snapshot hanya dipercaya jika HLC-nya tidak lebih tua dari cursor perangkat
   dan daftar perangkat aktif cocok. Snapshot tidak menggantikan arsip.
6. Konflik (D25). Semua perangkat memakai satu aturan di
   `sync_conflict_rules.dart`; tidak ada aturan lokal dan remote yang berbeda.
   HLC lebih awal menang; jika HLC sama, `device_id` terkecil menang. Matriks
   lengkap ada di Lampiran C.

| Konflik | Aturan |
|---|---|
| Void vs retur bersamaan | HLC lebih awal menang. Yang kalah dibalik dengan dokumen kompensasi. Jika retur sudah mengeluarkan uang, selisih kas dicatat sebagai item “perlu tindak lanjut owner”, tidak dihapus diam-diam |
| Penyesuaian nota vs void | Void menang bila HLC lebih awal. Penyesuaian pada nota VOID ditolak |
| Opname vs movement lain | Bukan konflik. Delta idempoten diterapkan; selisih terhadap hitung fisik masuk laporan opname |
| Feature flag | HLC terbaru menang; `device_id` sebagai tie-break |
| Saldo negatif hasil sync | Bukan konflik. Muncul di laporan dan memicu opname |

- Semua perangkat menghitung pemenang yang sama. Hanya perangkat asal dokumen
  yang kalah yang menerbitkan dokumen kompensasi, dengan `request_id` turunan
  dari id konflik, sehingga idempoten. Jika perangkat asal tidak menerbitkan
  dalam 7 hari, status menjadi “butuh bantuan owner”; owner dapat menerbitkan
  dari layar Konflik.
- Konflik tercatat di `sync_conflicts` dan terlihat di layar “Konflik” untuk
  owner.
- Bantuan owner: jika kompensasi otomatis gagal, tidak dapat ditentukan, atau
  menyangkut uang yang sudah dibayarkan, status menjadi “butuh bantuan owner”.
  Owner memilih penyelesaian (terima kompensasi, batalkan, atau buat dokumen
  koreksi manual); pilihan dan alasannya dicatat di `business_audits`. Selama
  belum selesai, saldo stok dan kas tetap tercatat apa adanya dan item muncul
  di laporan rekonsiliasi.

7. Pruning envelope relay hanya setelah semua perangkat aktif ack. Perangkat
   aktif = belum dicabut, heartbeat-nya <= 30 hari, dan belum melewati masa
   tenggang versi protokol (Lampiran D). Perangkat tanpa heartbeat > 30 hari
   tidak menahan pruning. Saat kembali, perangkat mengirim outbox lamanya lebih
   dulu (dengan aturan konflik di atas), baru re-enroll dan menerima snapshot;
   outbox tidak boleh dibuang oleh re-enroll. Tidak ada batas jumlah perangkat,
   tetapi daftar perangkat harus dapat dipaginasi dan diaudit.
8. Perubahan status work order dari tablet mencatat aktor, waktu, dan HLC.
9. Sync dipicu setelah commit (debounce 3 detik + batch), saat konektivitas
   kembali, start/resume aplikasi, fallback ringan 15 menit saat foreground,
   dan manual. Tidak ada polling 60 detik dan tidak ada sync di background.
   Event konektivitas diikuti health check relay sebelum dianggap online.
10. Aplikasi harus beroperasi penuh minimal 24 jam tanpa jaringan, termasuk
    jual, stok, riwayat, cetak, retur, dan void lokal. Sesi lokal tidak punya
    TTL jaringan; tidak ada logout paksa.
11. Keputusan stok tidak menunggu sync. Ledger lokal dipakai; jika stok lokal
    kurang, penjualan diblokir. Sync berikutnya mengkonvergensikan movement dan
    menandai konflik tanpa menghentikan kasir.
12. Arsip diunggah paralel setelah commit dengan prioritas rendah; arsip tidak
    menahan sync dan tidak memicu sync tambahan.
13. Banner muncul setelah 24 jam tanpa sync sukses, hanya untuk toko premium
    dengan sync aktif. Aplikasi tetap dapat dipakai; banner adalah peringatan,
    bukan batas keras.
14. Versi protokol (D26). Header envelope membawa `protocol_version`. Relay
    menolak versi di bawah `min_supported`. Klien yang menerima versi lebih
    tinggi dari yang dikenalnya berhenti menerapkan, menampilkan “Perbarui
    aplikasi”, dan operasi lokal tetap jalan. Matriks versi ada di Lampiran D.

### 3.6 Retensi, Arsip, dan Purge

1. Setiap nota diarsipkan **segera setelah commit**, bukan saat mau purge.
2. Arsip berisi dua lapis:
   - bundle per dokumen (nota + jobs + parts + payments + returns +
     commissions + adjustments + pajak + struk);
   - stream envelope lengkap untuk master, stok, kas, dan audit.
3. Bundle dienkripsi dengan store key; server hanya menyimpan ciphertext,
   hash, metadata minimal, dan token indeks HMAC.
4. Upload idempoten per `(store_id, doc_type, doc_id, content_hash)`. Respons
   berupa receipt bertanda tangan arsip: hash, waktu, object id, signature.
5. Purge lokal (D23) hanya jika semua benar:
   - umur dokumen >= 1 tahun dan periodenya sudah ditutup (D24);
   - status final (LUNAS atau VOID); tidak ada retur aktif, piutang, work order
     terbuka, konflik terbuka, atau dokumen pending;
   - receipt arsip tersimpan dan terverifikasi, relay sudah ack, outbox
     dokumen kosong;
   - `purge_enabled` aktif, yaitu escrow terverifikasi (F8-1), uji restore
     arsip lulus (F7-7), dan premium aktif;
   - revisi snapshot terakhir sudah stabil 7 hari tanpa perubahan.
6. Verifikasi lisensi, receipt, dan ack dilakukan saat purge berjalan. Tanpa
   jaringan, purge ditunda; tidak ada purge offline.
7. Purge menghapus pohon service/nota: `service_records`, `service_jobs`,
   `service_parts`, `payments`, `sale_returns`, `service_record_commissions`,
   `nota_adjustments`, struk, dan lampiran. Tidak menghapus `stock_movements`,
   `cash_ledger`, `business_audits`, master, pembelian, atau opname. Purge
   meninggalkan baris stub `purged_documents(doc_id, no_nota, tanggal, total,
   status, receipt_id)` agar ledger tidak merujuk dokumen yang hilang dan
   riwayat menampilkan “ada di arsip”.
8. Purge berjalan per dokumen dengan batas batch, menulis audit, dan tidak
   pernah memanggil endpoint hapus arsip.
9. VPS arsip tidak memiliki endpoint delete. Data hanya bisa ditambah dan
   dibaca.
10. “Selamanya” hanya sah jika ada snapshot penyedia + salinan offsite dan uji
    restore. Satu VPS penyimpanan tanpa backup bukan arsip permanen.
11. Akun gratis tanpa arsip tidak pernah dipurge otomatis. Tanpa receipt
    arsip, riwayat lokal dipertahankan; pengguna dapat mengekspor atau menghapus
    sendiri dengan konfirmasi.
12. Tutup buku bulanan (D24): `period_closings(periode, rev, zona, omzet, dpp,
    ppn, hpp, retur_*, kas_per_metode, komisi, hash, closed_at)`. Dibuat oleh
    perangkat owner dan disinkronkan sebagai dokumen. Menutup otomatis 7 hari
    setelah akhir bulan, atau lebih awal oleh owner. Nota terlambat menerbitkan
    revisi `rev n+1`; snapshot lama tidak diubah.
13. Premium berakhir (D27): purge berhenti; arsip baca-saja 12 bulan; ekspor
    arsip lengkap (didekripsi lokal) tersedia.

### 3.7 Kunci dan Recovery

1. Store key dibuat acak; setiap perangkat menerima wrapped key dengan
   X25519 + HKDF; payload AES-GCM; envelope ditandatangani Ed25519.
2. Jalur utama recovery: akun Google owner + wrapped key di Google Drive app
   data. Blob dibuka dengan KDF kuat (Argon2id) atas frasa pemulihan >= 6 kata
   yang terpisah dari PIN kasir (D28). PIN 6 digit saja bisa di-brute-force
   offline bila blob bocor. Frasa tidak dikirim ke server. Frasa pemulihan
   adalah frasa yang sama dengan frasa backup (Lampiran A).
3. Jalur darurat: offline recovery key admin dibagi Shamir 2-dari-3. Tiga
   pemegang share adalah admin berbeda, bukan owner toko. Pembukaan escrow
   butuh dua pemegang, verifikasi identitas owner, dan audit. Satu kunci tidak
   boleh membuka semua toko; escrow diturunkan per toko dengan HKDF master +
   `store_id`. Kunci ini tidak disimpan di VPS.
4. Rotasi store key wajib saat perangkat dicabut. Envelope dan arsip menyimpan
   `key_version`; kunci lama disimpan agar payload historis tetap terbaca.
5. Perangkat baru masuk lewat persetujuan owner, bukan pembagian kunci manual.
6. Pencabutan perangkat membatasi akses baru; token arsip yang masih berlaku
   kedaluwarsa maksimal 24 jam. Ini risiko yang diterima dan dicatat.
7. Metadata yang terlihat server: store id, jenis dokumen, tanggal, ukuran,
   dan token HMAC nama. Tidak ada plaintext isi.
8. Perangkat dicabut atau hilang: perangkat masuk mode terkunci: tidak bisa
   sync, menawarkan ekspor atau flush outbox ke owner, baru boleh reset. Tidak
   ada wipe otomatis (selaras D7). Database Android juga dienkripsi at-rest
   (F8-6).

### 3.8 Logout, Reset, dan Restore

1. **Logout:** hentikan sync, hapus sesi/PIN aktif, pertahankan database,
   outbox, kunci, dan lisensi lokal. Tampilkan ringkasan outbox dan konfirmasi.
2. **Reset perangkat:** aksi terpisah di menu perangkat. Wajib autentikasi
   owner, hitung outbox, tawarkan ekspor/flush, konfirmasi berlapis, cabut
   perangkat di relay, lalu hapus database dan kunci lokal.
3. **Restore (D22):** dua jalur, keduanya wajib autentikasi owner.
   - Jalur lokal: file backup terenkripsi + frasa backup (= frasa pemulihan
     yang sama, Lampiran A) + PIN owner bila DB aktif ada. Tanpa jaringan;
     gratis.
   - Jalur cloud: Google Sign-In owner + store id sama.
   - Keduanya: manifest diverifikasi; database saat ini di-backup; outbox yang
     lebih baru dipertahankan atau digabung; restore memakai staging +
     `recoverInterruptedRestore`.
4. Tidak ada restore dari layar pra-login tanpa autentikasi di atas.
5. Restore tidak boleh menimpa arsip VPS atau toko lain.

---

## 4. Arsitektur Target

```text
HP kasir / tablet / PC owner
   │                                   │
   │ HTTPS: auth, sync, envelope       │ HTTPS: upload/search arsip
   ▼                                   ▼
VPS 1 — Komunikasi                VPS 2 — Penyimpanan
relay + PostgreSQL operasional    API arsip + object storage
- Google login                    + indeks HMAC (append-only)
- enrollment perangkat            - ciphertext per dokumen
- ingest/feed/ack/snapshot        - stream envelope
- token arsip berumur pendek      - receipt bertanda tangan
   │                                   │
   └──────── token ────────────────────┘
        (relay menandatangani, arsip memverifikasi)
```

### 4.1 Tanggung Jawab

| Komponen | Boleh | Tidak boleh |
|---|---|---|
| Client | membuat nota, menghitung stok, enkripsi/dekripsi, upload arsip | mengirim plaintext, menghapus arsip |
| Relay | auth, envelope, feed, ack, snapshot, token arsip | membaca isi, menghitung stok, menghapus arsip |
| Arsip | simpan ciphertext, indeks HMAC, receipt, pencarian | dekripsi, kalkulasi bisnis, delete |
| Google | identitas owner, Drive app data | menyimpan PIN, frasa, atau plaintext |

### 4.2 Alur

**Penjualan:** kasir membuat nota → SQLite transaction (nota + baris + bayar +
kas + stok + komisi + audit + outbox) → UI langsung selesai → sync ke relay
dipicu (debounce 3 detik, dibatch) dan arsip upload berjalan paralel dengan
prioritas rendah.

**Sync:** outbox → envelope terenkripsi + tanda tangan + `protocol_version` →
relay verifikasi → feed perangkat lain → dekripsi lokal → apply idempoten
(aturan konflik §3.5) → ack → cursor maju. Sync menjadi jalur utama; arsip
tidak boleh menahan sync.

**Arsip:** bundle dokumen + envelope → enkripsi → upload ke arsip → receipt →
client simpan receipt. Jika arsip mati, penjualan dan sync tetap jalan; upload
di-retry.

**Pencarian:** cari lokal → jika kosong, tombol “Cari di server” → kirim exact
nota/token HMAC/rentang tanggal → arsip kembalikan ciphertext + metadata →
client dekripsi dan tampilkan struk.

**Purge:** dokumen lolos gate §3.6 butir 5 → hapus pohon lokal → tulis stub →
audit. Arsip tidak disentuh.

**Recovery:** Google Sign-In → unduh wrapped key dari Drive → frasa pemulihan →
unwrap → perangkat baru aktif. Jika Google hilang → admin (Shamir 2-dari-3) +
verifikasi identitas + audit.

### 4.3 API Arsip

| Endpoint | Fungsi | Otorisasi |
|---|---|---|
| `POST /v1/documents` | upload idempoten | token scope `archive:write` |
| `GET /v1/documents/{id}` | ambil ciphertext | token scope `archive:read` |
| `POST /v1/search` | cari exact nota/token/tanggal | token scope `archive:read` |
| `GET /v1/receipts/{id}` | receipt | token scope `archive:read` |
| `POST /v1/archive-token` | terbitkan token (di relay) | device token + store |

Token: JWT ditandatangani relay, `aud=archive`, `store_id`, `device_id`,
scope, `exp` 24 jam. Arsip memverifikasi tanda tangan dengan public key relay;
tidak ada scope delete. Relay tidak memegang kredensial tulis arsip. Setelah
premium berakhir, token hanya diberi scope `archive:read` selama 12 bulan
(D27).

### 4.4 Skema Arsip

```text
archive_documents
  id, store_id, doc_type, doc_id, request_id, content_hash,
  ciphertext_path, size_bytes, doc_date, key_version, schema_version,
  archived_at, receipt_signature

archive_index_tokens
  store_id, doc_type, token_hmac, doc_id
  (token = HMAC search_key atas nomor nota atau kata nama ternormalisasi)

archive_receipts
  store_id, doc_id, content_hash, object_id, archived_at, signature

archive_envelopes
  store_id, envelope_id, device_id, seq, hlc, ciphertext_path, received_at
```

Tidak ada kolom plaintext nama, telepon, item, harga, atau nominal.

### 4.5 Kegagalan

| Kondisi | Perilaku |
|---|---|
| Relay mati | jual tetap; sync tertunda; arsip upload jalan selama token cache berlaku; purge menunggu ack |
| Arsip mati | jual dan sync tetap; pencarian arsip dan purge tertunda; upload retry |
| Keduanya mati | operasi lokal penuh; tidak ada purge; tidak ada pencarian arsip |
| Storage arsip penuh | upload ditolak dengan pesan kuota; alert; jual tetap jalan |
| Kunci hilang | sync berhenti dengan pesan actionable; jalur recovery ditampilkan |
| Klien lebih lama dari protokol | sync berhenti dengan “Perbarui aplikasi”; operasi lokal tetap jalan |

### 4.6 Konfigurasi

- `PUSATKU_SERVICE_URL` — relay.
- `PUSATKU_ARCHIVE_URL` — arsip.
- Dua sertifikat TLS; health check terpisah.
- Port database tidak pernah publik; arsip di belakang HTTPS (opsional tunnel).
- Kuota per toko, alert kapasitas, snapshot penyedia, salinan offsite.

---

## 5. Urutan Eksekusi dan Gate

| Fase | Fokus | Menjaga | Tidak menjaga | Bypass jika dilewati |
|---|---|---|---|---|
| F0 | Guard data/keuangan | logout/restore tidak menghapus data; void-retur tidak double refund; DB aman | integritas schema, arsip | data hilang sebelum sempat diperbaiki |
| F1 | Baseline schema & integritas | model harga/stok/audit lengkap; duplikat terdeteksi | perilaku UI | bug baru menumpuk di schema lama |
| F2 | Konsistensi transaksi | satu aturan harga/approval/void | laporan dan arsip | aturan lokal/remote berbeda |
| F3 | Harga, pembayaran, zona waktu | struk dan total dapat direkonsiliasi; laporan harian benar | stok dan sync | selisih uang tidak terlacak |
| F4 | Stok & valuasi | saldo = movement; HPP konsisten; izin terpisah dan gratis | sync dan arsip | stok negatif/HPP salah menyebar |
| F5 | Offline 24 jam & outbox | operasi penuh tanpa jaringan; sync hemat daya; status per dokumen | relay dan arsip | kasir berhenti saat internet mati |
| F6 | Sync lanjutan, konflik, protokol | tidak ada duplikasi/kehilangan lintas perangkat; konflik konvergen | arsip permanen | konflik menyebar |
| F7 | Arsip, pencarian, tutup buku | data 2 tahun dapat dicari; purge aman (tetap mati sampai F8-8) | siklus kunci | purge menghapus satu-satunya salinan |
| F8 | E2EE & siklus kunci | perangkat dicabut tidak membuka payload baru; recovery terbukti | error UI | kunci hilang = riwayat hilang |
| F9 | Error & recovery | kegagalan tidak merusak data lain; pesan actionable | performa | error tersembunyi |
| F10 | Performa & pembulatan | query 2 tahun dan aritmetika integer | fitur baru | laporan lambat/selisih sen |

Gate rilis:

- **P0 (F0):** tidak ada jalur UI/service yang menghapus/mengganti DB tanpa cek
  outbox dan autentikasi owner; double refund tidak mungkin.
- **P1 (F1–F4):** nota nego punya acuan + grant + audit; opname tidak memacetkan
  antrean; laporan dapat direkonsiliasi ke nota; laporan harian benar pada
  batas zona waktu; akun gratis dapat memakai peran gudang/kasir/supervisor
  tanpa lisensi.
- **P2 (F5–F8):** offline 24 jam penuh dan aman; sync event-driven tanpa polling
  60 detik; tidak ada duplikasi/kehilangan; konflik void/retur konvergen;
  versi protokol menolak klien lama dengan jelas; arsip 2 tahun berfungsi;
  perangkat dicabut tidak membuka payload baru; `purge_enabled` hanya aktif
  setelah escrow dan uji restore arsip lulus.
- **Produksi:** P0–P2 lulus pada salinan data nyata dari pilot/dev, bukan hanya
  DB kosong. Aturan kerja no. 4 sudah dikonfirmasi.

---

## 6. Task

Nomor `#xx` merujuk task tracker yang sudah ada. Nomor `(baru)` adalah task
yang ditambahkan oleh dokumen ini dan harus dibuat di tracker saat fase dimulai.
Perubahan v2 ditandai `[v2]`.

### F0 — Guard (tanpa schema)

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F0-1 | Ringkasan outbox sebelum logout (#26) | `entry_gate.dart`, `home_shell.dart`: hitung pending/failed, dialog konfirmasi, opsi ekspor | Logout dengan pending selalu menampilkan ringkasan; tidak ada logout diam-diam | — |
| F0-2 | Hentikan hapus DB saat logout (#27) | `signOutSession`: jangan hapus DB/kunci; tambah alur `resetDevice` terpisah | Logout mempertahankan DB dan outbox; reset hanya lewat aksi owner | F0-1 |
| F0-3 | Autentikasi owner sebelum restore (#28) `[v2]` | `backup_service.dart`, layar pra-login: dua jalur D22. Lokal: file backup + frasa backup + PIN owner bila DB aktif ada. Cloud: Google Sign-In owner + store id | Restore lokal tanpa jaringan lulus; restore tanpa autentikasi ditolak; toko berbeda ditolak | — |
| F0-4 | Restore tidak membuang outbox baru (#29) | Bandingkan manifest/outbox; merge atau tahan restore; staging | Outbox lebih baru tidak hilang setelah restore | F0-3 |
| F0-5 | Satukan aturan void/retur (#30) | `sale_return_service.dart`, `note_sync.dart`, `sync_conflict_rules.dart`: tolak void saat retur aktif | Void lokal/remote sama-sama ditolak saat retur aktif | — |
| F0-6 | Filter retur aktif saat restock void (#31) | Query restock memakai qty retur aktif | Qty yang sudah diretur tidak diretur dua kali | F0-5 |
| F0-7 | Karantina WAL/SHM (#32) | Safe mode memindahkan `.db`, `-wal`, `-shm` bersama | Tidak ada transaksi commit yang hilang dari karantina | — |
| F0-8 | `busy_timeout` + journal mode (#33) | `AppDatabase.open`: `busy_timeout`, journal eksplisit, pesan sibuk | Backup/restore bersamaan tidak memicu `database is locked` mentah | — |
| F0-9 | Audit trail aksi istimewa (#34) | Satu service audit untuk void, stok manual, katalog, restore, reset, grant | Setiap aksi istimewa punya aktor, alasan, before/after | — |
| F0-10 | Banner offline 24 jam (#35) `[v2]` | `home_shell.dart` + `SyncService.status()`: pakai waktu sync sukses terakhir; jika belum pernah, pakai `created_at` dokumen pending tertua. Hanya untuk premium dengan sync aktif; toko gratis memakai indikator “terakhir backup” | Banner muncul setelah 24 jam tanpa sync sukses; pesan berbeda untuk “belum pernah sync” vs “sync terakhir > 24 jam”; tidak muncul di toko gratis | D17 |

### F1 — Baseline Schema & Integritas

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F1-1 | Baseline schema baru (baru) `[v2]` | `schema.dart`: kolom/indeks yang kurang; tabel lokal `purged_documents`, `period_closings`, `sync_conflicts`, salinan `archive_receipts`; `protocol_version` di `app_meta`; versi baseline baru; tanpa rantai migrasi | DB baru membuat seluruh tabel; tidak ada kolom legacy | F0 |
| F1-2 | Deteksi duplikat sebelum unique index (baru) | Query audit `request_id`, `no_nota`, movement; laporan duplikat; dedupe manual | Tidak ada index yang gagal karena data duplikat | F1-1 |
| F1-3 | Rekonsiliasi ledger vs saldo (baru) | Laporan selisih stok/kas; tidak mengubah data | Saldo = jumlah movement terlihat; selisih punya daftar | F1-1 |
| F1-4 | Kebijakan non-negatif (baru) | Guard lokal + laporan; tidak memasang CHECK saldo | Penjualan lokal tidak negatif; sync negatif tetap terlihat | F1-1 |

Catatan: aturan kerja no. 4 sudah dikonfirmasi (belum ada toko/perangkat dengan
data hidup). Database dev lama di-backup lalu dibuat ulang. Tidak ada
`ALTER TABLE` bertahap.

### F2 — Konsistensi Transaksi

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F2-1 | Harga acuan dan final (#21) | `JobDraft` + dialog POS: jasa manual punya “Harga normal” dan “Harga disepakati”; `createTransaction` memakai acuan, bukan harga final | Nota nego menyimpan acuan 350.000 dan final 325.000; struk menampilkan keduanya | F1 |
| F2-2 | Grant persetujuan tunggal (#21/#34) | `approval_service.dart` mengembalikan grant; `createTransaction` memakai grant; audit mencatat approver/alasan/baris | Satu PIN mengizinkan semua baris di bawah modal pada transaksi itu; tidak ada `approvedByOverride` tanpa verifikasi | F2-1 |
| F2-3 | Alasan diskon dari POS (#21) | Kirim `alasanDiskon`; wajib saat final < acuan; bedakan gratis vs diskon 100% | Tidak ada diskon tanpa alasan; laporan bisa membedakan | F2-1 |
| F2-4 | Idempotensi pembelian/retur pembelian (baru) | `purchase_service.dart`: `request_id` + hash untuk purchase dan purchase return | Retry UI tidak menggandakan pembelian/retur | F1 |
| F2-5 | Audit katalog/stok/void (#34) | Panggil audit service dari `saveCatalog`, `deleteCatalog`, stok manual, void | Semua aksi punya jejak aktor dan alasan | F0-9 |
| F2-6 | Hapus jalur approval palsu (baru) | Hapus/validasi `approvedByOverride` yang dipercaya tanpa verifikasi | Tidak ada approver string yang bisa dipalsukan UI | F2-2 |

### F3 — Harga, Pembayaran, Zona Waktu

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F3-1 | Struk acuan vs final (#51 baru) | `receipt_service.dart`: tampilkan acuan, diskon, final | Struk dapat direkonsiliasi ke baris nota | F2-1 |
| F3-2 | Uang diterima vs kembalian (#51) | Simpan/print nominal mentah dan ter-clamp; jangan menampilkan angka yang tidak tersimpan | Struk dan DB menunjukkan angka yang sama | F3-1 |
| F3-3 | Bayar penuh tanpa pembulatan (#51) | Tombol bayar penuh memakai total sen; transfer tidak ditolak karena pembulatan | Total 325.001 dapat dibayar penuh via transfer | F3-2 |
| F3-4 | Negosiasi per item (#21) | UI mengizinkan final berbeda per baris; alokasi diskon nota tetap proporsional | Dua baris dapat punya final berbeda dengan alasan masing-masing | F2-1 |
| F3-5 | Dipindah ke F4-9 `[v2]` | Bergantung pada F4-3/F4-4 yang berjalan setelah F3 | — | — |
| F3-6 | Snapshot pajak UI = service (#22) | Layar memakai `PajakSnapshot.hitung` yang sama dengan service; tidak ada hitung ganda | Angka layar = angka tersimpan | F2-1 |
| F3-7 | DPP/PPN penyesuaian (#22) `[v2]` | `nota_adjustment_service.dart` memisahkan jasa/part/diskon dan DPP/PPN; koreksi mengubah HPP/laba/PPN (REP-02); rekap DPP mengecualikan TANPA (REP-03) | Rekap pajak cocok dengan detail penyesuaian; margin tidak salah setelah koreksi | F3-6 |
| F3-8 | Qty sesuai satuan (#51) | Validasi qty bulat/desimal per satuan; qty < 1 ditolak, bukan dipotong 0 | Tidak ada baris qty 0 karena pembulatan | F1 |
| F3-9 | Zona waktu toko (baru) `[v2]` | Semua filter tanggal laporan (termasuk `marginReport`) dikonversi dari zona toko ke rentang UTC; menutup REP-05 | Transaksi WIB 00:00–06:59 masuk hari yang benar; ada uji batas tengah malam | F3-6 |

### F4 — Stok & Valuasi

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F4-1 | Opname absolut + isolasi (#37) | `opname_service.dart`: absolut + basis + request id; hold gagal tidak memblokir | Opname basi masuk konflik, antrean lain tetap jalan | F1 |
| F4-2 | Retur: clamp & filter (#31/#52 baru) | Pembatalan retur membatasi qty; restock void memfilter retur aktif | Tidak ada stok ganda dari retur/void | F0-5 |
| F4-3 | HPP saldo negatif (#38) | `stock_ledger.dart`: jangan menggelembungkan rata-rata saat saldo <= 0 | HPP setelah koreksi negatif tidak melonjak | F1 |
| F4-4 | Movement masuk/keluar eksplisit (#39) | Nota baru menulis movement masuk; keluar menyimpan unit cost; rebuild terkontrol | Saldo = movement; tidak ada saldo tanpa asal | F1 |
| F4-5 | Retur memakai snapshot modal (#39) | Retur membaca HPP dari movement penjualan, bukan master | Refund modal akurat setelah harga master berubah | F4-4 |
| F4-6 | Kartu stok + rekonsiliasi (#52) | `stock_screen.dart`: riwayat movement per item, saldo, selisih | Kasir dapat melihat asal saldo dan menandai negatif | F4-4 |
| F4-7 | Pemisahan izin stok (#41/#42/#43) | `access_control.dart` + `permissions.dart`: tambah peran GUDANG; tegakkan `stok_keluar`, `stok_masuk`, `opname`, `ubah_stok` terpisah di service dan UI; keputusan stok dari ledger lokal tanpa menunggu sync; blokir qty > saldo | Kasir tidak bisa menerima barang tanpa izin; gudang tidak bisa menjual; supervisor dapat opname; tablet mekanik tetap read-only | F4-1 |
| F4-8 | Uji stok & matriks izin (#44) | Skenario offline 24 jam, reconnect, opname, retur, void, force close; uji tiap kombinasi izin dan percobaan bypass; jalankan di tier gratis dan premium | Tidak ada selisih saldo; setiap aksi hanya lolos dengan izinnya sendiri | F4-7, F4-10 |
| F4-9 | Modal baris = HPP ledger (#38) `[v2, dari F3-5]` | `PriceLine.hargaModal` dari HPP rata-rata; movement keluar menyimpan unit cost (TRX-06, ARC-02) | Laba baris memakai HPP, bukan harga master | F4-3, F4-4 |
| F4-10 | Akun lokal gratis (baru) `[v2, dari F8-9]` | `account_service.dart`: hapus gate premium untuk akun karyawan dan peran lokal (kasir, gudang, supervisor, mekanik, viewer); gate premium hanya untuk sync/arsip/pairing/multi-toko | Toko gratis dapat memakai semua peran lokal tanpa lisensi server | F4-7 |

### F5 — Offline 24 Jam, Outbox, Riwayat

Aplikasi harus tetap penuh saat internet mati minimal 24 jam. Sync adalah fitur
premium, tetapi dijalankan hemat daya: dipicu peristiwa, dibatch, dan tidak
memakai polling rapat.

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F5-0 | Sync event-driven & offline 24 jam (baru) | `sync_scheduler.dart` + `sync_service.dart`: hapus interval 60 detik; event reconnect/start/resume/manual, debounce 3 detik + batch, fallback ringan 15 menit saat foreground, tanpa sync background; sesi lokal tanpa TTL jaringan | 24 jam tanpa jaringan tetap bisa jual/stok/cetak; tidak ada polling 60 detik; reconnect memicu sync | F0-1 |
| F5-1 | Status sync per dokumen (baru) | `sync_service.dart` + riwayat: badge pending/acked/failed/dead-letter | Kasir tahu dokumen mana yang belum terkirim | F5-0 |
| F5-2 | Paginasi & filter riwayat (baru) | `listRecords` + `history_screen.dart`: limit/offset, tanggal, nomor, nama | Nota ke-201 dapat dibuka; filter tanggal bekerja | F1 |
| F5-3 | Panel status sync utama (baru) `[v2]` | HomeShell: waktu sync terakhir, jumlah pending/failed, online/offline relay, aksi sync manual; banner 24 jam dari F0-10. Hanya premium dengan sync aktif; toko gratis melihat indikator “terakhir backup” | Kasir tahu ada data tertunda tanpa alarm palsu saat offline normal; banner muncul setelah 24 jam | F5-1 |
| F5-4 | Guard logout/restore (#26/#29) | Lihat F0-1/F0-4; tambah uji regresi | Tidak ada jalur kehilangan outbox | F0 |
| F5-5 | Uji force close & offline 24 jam (#44) | Matikan proses di setiap titik transaksi/sync/restore; simulasikan 24 jam tanpa jaringan | Nota commit bertahan; sync mengulang tanpa duplikasi; operasi tetap penuh selama 24 jam | F5-0 |
| F5-6 | Cakupan laporan & VOID (baru) | Piutang/kas satu definisi; badge VOID; ekspor owner lengkap | Angka antar layar sama; nota VOID terlihat | F3 |

### F6 — Sync Lanjutan, Konflik, Protokol

Fase ini menangani kasus yang lebih sulit dari sync normal: retry panjang,
envelope rusak, konflik domain, versi aplikasi campuran, dan perangkat yang lama
tidak aktif. Offline harus tetap aman minimal 24 jam, dan setiap kegagalan sync
harus terlihat serta pulih otomatis saat jaringan kembali.

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F6-1 | Dead-letter & error kripto (baru) | `sync_service.dart`: batas retry, dead-letter, pesan kunci/token | Envelope rusak tidak menahan cursor; pesan actionable | F5-1 |
| F6-2 | Kuota & pruning relay (baru) `[v2]` | `relay/config.dart`, `server.dart`: alert 413, pruning setelah ack perangkat aktif; heartbeat 30 hari; perangkat kembali mengirim outbox lama dulu, baru re-enroll + snapshot | Perangkat mati lama tidak menahan pruning dan tidak kehilangan outbox; storage penuh tidak menghentikan pengiriman diam-diam | F6-1 |
| F6-3 | Konflik domain & feature flag (baru) `[v2]` | `sync_conflict_rules.dart`, `feature_flags.dart`: terapkan tabel konflik §3.5 butir 6 dan Lampiran C; induk mati = anak mati | Tidak ada dua aturan berbeda; semua perangkat memilih pemenang yang sama | F4 |
| F6-4 | Idempotensi permanen & snapshot (baru) | `applied_deltas` jangka panjang; verifikasi HLC snapshot | Retry lama tidak menggandakan; snapshot basi ditolak | F6-3 |
| F6-5 | Audit status tablet (#34) | Status work order mencatat aktor/waktu/HLC | Perubahan tablet dapat diaudit | F6-3 |
| F6-6 | Uji dua perangkat & offline 24 jam (baru) | Simulasi 24 jam tanpa jaringan, putus-nyambung, retry, perangkat mati, konflik | Tidak ada duplikasi/kehilangan; operasi lokal tetap penuh; sync pulih saat reconnect | F6-9 |
| F6-7 | Versi protokol (baru) `[v2]` | `protocol_version` di envelope; `min_supported` di relay; klien lama berhenti menerapkan dengan pesan “Perbarui aplikasi” (D26) | Klien lama tidak menerapkan envelope baru; operasi lokal tetap jalan | F6-1 |
| F6-8 | Dokumen kompensasi (baru) `[v2]` | Perangkat asal dokumen yang kalah menerbitkan dokumen kompensasi dengan `request_id` turunan dari id konflik (D25) | Void di A vs retur di B konvergen ke saldo kas dan stok yang sama pada kedua urutan HLC | F6-3 |
| F6-9 | Layar “Konflik” & bantuan owner (baru) `[v2]` | Daftar `sync_conflicts`, badge di riwayat, status “butuh bantuan owner”, pilihan penyelesaian + audit | Owner melihat konflik dan item “perlu tindak lanjut”, dapat menyelesaikannya, dan semua pilihan tercatat | F6-8 |

### F7 — Arsip, Pencarian, Tutup Buku

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F7-1 | Payload arsip lengkap (#49) | Dokumen kanonik per nota + envelope stream; schema/key version | Komisi dan penyesuaian ikut terarsip | F1 |
| F7-2 | Skema arsip (#9) | Tabel `archive_documents`, `archive_index_tokens`, `archive_receipts`, `archive_envelopes` | Skema immutable; tidak ada kolom plaintext | F7-1 |
| F7-3 | API arsip (#10) | Upload/receipt/search/get; token relay; tanpa delete; token baca-saja setelah premium berakhir | Upload idempoten; token tidak bisa menghapus | F7-2 |
| F7-4 | ArchiveClient (#11) | Base URL arsip, token, retry, simpan receipt | Upload tidak memblokir jual/sync | F7-3 |
| F7-5 | Purge bertahap (#40) `[v2]` | `purge_service.dart`: gate §3.6 butir 5 (umur + periode tutup + status final + receipt + ack + outbox kosong + `purge_enabled`); tulis stub `purged_documents`; audit. Flag `purge_enabled` default off sampai F8-8 lulus | Purge hanya setelah arsip terverifikasi; ditolak untuk nota kredit belum lunas; akun gratis tanpa arsip tidak kehilangan riwayat | F7-4, F7-11 |
| F7-6 | Uji e2e arsip (#12) | Dua layanan terpisah; backlog, duplikat, search, arsip mati, purge tertahan | Semua skenario lulus | F7-5 |
| F7-7 | Durabilitas arsip (#48) | Snapshot penyedia + offsite + uji restore; RPO/RTO | Kerusakan satu VPS tidak menghapus arsip | F7-2 |
| F7-8 | Pencarian arsip & riwayat (#54 baru) | Tombol “Cari di server”, paginasi, dekripsi lokal, tampilan struk | Nota 2 tahun ditemukan saat online | F7-4 |
| F7-9 | Operasional relay/arsip (#23/#13) | TLS, CORS, kuota, monitoring, backup PostgreSQL, dua URL | Deployment dua VPS terdokumentasi dan teruji | F7-7 |
| F7-10 | Ekspor arsip lengkap (baru) `[v2]` | Unduh arsip, dekripsi lokal, ekspor; dipakai juga saat premium berakhir (D27) | Pengguna dapat mengekspor seluruh arsip tanpa server melakukan dekripsi | F7-8 |
| F7-11 | Tutup buku bulanan & “Buka dari arsip” (baru) `[v2]` | `period_closings` oleh perangkat owner (otomatis 7 hari setelah akhir bulan atau manual); laporan periode lama dari snapshot; retur atas nota terpurge via arsip dengan `ref_doc_id` | Laporan tahunan identik sebelum dan sesudah purge; retur atas nota terpurge berjalan online | F7-4 |

### F8 — E2EE & Siklus Kunci

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F8-1 | Escrow recovery (#45) `[v2]` | Google Drive wrapped key dibuka frasa pemulihan >= 6 kata + Argon2id; master key admin Shamir 2-dari-3; audit | Drive yang bocor tidak bisa di-brute-force dengan PIN; perangkat hilang dapat dipulihkan; satu admin tidak bisa membuka escrow sendirian | F7 |
| F8-2 | Rotasi kunci (baru) | `key_version`, rewrap perangkat aktif, simpan kunci lama | Perangkat dicabut tidak membuka payload baru | F8-1 |
| F8-3 | Enrollment perangkat (baru) | Persetujuan owner; daftar perangkat paginasi + audit; hapus pembagian kunci manual | Tidak ada batas jumlah perangkat; perangkat baru tidak memegang kunci tanpa izin | F8-2 |
| F8-4 | Metadata & blind index (baru) | Token HMAC nama/nota; dokumentasi kebocoran | Pencarian tanpa plaintext | F7-2 |
| F8-5 | Transport & error (baru) | TLS default, CORS terbatas, error server minimal | Tidak ada endpoint permisif | F7-9 |
| F8-6 | PIN & DB at-rest (baru) `[v2]` | Hapus hash PIN dari `app_meta`; desktop: SQLCipher/BitLocker + ACL; Android: SQLCipher dengan kunci di Keystore | DB desktop dan Android tidak plaintext | F1 |
| F8-7 | Viewer & role (baru) | `runViewerWrite` dikunci; `role_base=owner` divalidasi; katalog berizin | Viewer tidak bisa menulis; role tidak escalates | F1 |
| F8-8 | Uji recovery (baru) | Google hilang, perangkat hilang, akun diambil alih, rotasi, uji restore arsip; setelah lulus, `purge_enabled` boleh diaktifkan | Semua jalur recovery terbukti | F8-1 |
| F8-9 | Dipindah ke F4-10 `[v2]` | Akun lokal gratis harus tersedia sejak F4 | — | — |
| F8-10 | Mode perangkat dicabut/terkunci (baru) `[v2]` | Perangkat dicabut tidak bisa sync, menawarkan ekspor/flush outbox ke owner, baru boleh reset; tanpa wipe otomatis | Perangkat dicabut tidak bisa sync, outbox dapat diekspor, tidak ada wipe otomatis | F8-2 |

### F9 — Error & Recovery

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F9-1 | Diagnosis sebelum safe mode (baru) | Startup membaca error sebelum memindahkan DB | Penyebab terlihat; data tidak langsung dikarantina | F0-7 |
| F9-2 | Antrean cetak (baru) | Status cetak per nota, retry, cetak ulang | Printer gagal tidak menghilangkan struk | F3 |
| F9-3 | Pesan kripto/token (baru) | Petakan error ke instruksi; arahkan ke recovery | Pengguna tahu langkah berikutnya | F6-1 |
| F9-4 | Uji kegagalan (baru) | Storage penuh, DB locked, token kedaluwarsa, arsip mati | Tidak ada data lain yang rusak | F8 |
| F9-5 | Health surface (baru) | Ringkasan backup/sync/arsip di HomeShell | Kegagalan berkepanjangan terlihat | F5-3 |

### F10 — Performa & Pembulatan

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F10-1 | Index & query 2 tahun (baru) | Index pencarian/paginasi; ukur laporan pada data 2 tahun | Riwayat/pencarian dalam batas waktu | F7 |
| F10-2 | Aritmetika integer (baru) | Hilangkan REAL di agregasi; satu aturan pembulatan | Tidak ada selisih 1–2 sen | F3 |
| F10-3 | Snapshot/feed (baru) | Ukur dan optimasi snapshot/feed | Sync besar tetap wajar | F6 |

---

## 7. Peta Temuan ke Fase

Semua temuan audit harus punya rumah. Tabel ini yang menjamin tidak ada yang
terlewat. Catatan: isi REP-04 tidak terlihat saat revisi ini disusun; verifikasi
terhadap laporan audit sebelum F3 dimulai.

| Temuan | Fase/Task |
|---|---|
| SEC-01, FLW-01 | F0-3 |
| SEC-02, OFF-01 | F0-1, F0-2 |
| SEC-03, DB-06, ERR-03 | F0-7 |
| SEC-04, OFF-02 | F0-4 |
| SEC-05, FLW-06 | F8-7 |
| SEC-06, SEC-07 | F8-7 |
| SEC-08 | F2-2 |
| SEC-09, SEC-10 | F8-6 |
| SEC-11, FLW-03 | F9-1 |
| SEC-12 | F8-2, F8-10 |
| SEC-13 | F8-1 |
| SEC-14, SEC-15 | F8-5 |
| SEC-16 | F8-4 |
| TRX-01, TRX-02 | F2-1 |
| TRX-03, TRX-04 | F3-1, F3-2, F3-3 |
| TRX-05 | F3-4 |
| TRX-06 | F4-9 |
| TRX-07 | F2-1, F2-3 |
| TRX-08 | F2-2 |
| TRX-09 | F10-2 |
| TRX-10 | F3-8 |
| TRX-11, TRX-12 | F3-6, F3-7 |
| REP-01, REP-04 | F3-6, F3-7 (REP-04 perlu verifikasi) |
| REP-02, REP-03 | F3-7 |
| REP-05 | F3-9 |
| REP-06, FLW-04 | F5-6 |
| REP-07, REP-09 | F5-6 |
| REP-08, DB-04 | F10-2 |
| INV-01, INV-11, INV-13 | F4-1 |
| INV-02 | F0-6 |
| INV-03 | F0-5, F6-3, F6-8, F6-9 |
| INV-04 | F4-3 |
| INV-05 | F4-5 |
| INV-06, INV-08 | F4-4 |
| INV-07 | F4-2 |
| INV-09 | F0-9, F2-5 |
| INV-10 | F4-6 |
| INV-12 | F2-4 |
| INV-14, DB-01 | F1-4 |
| DB-02, ERR-04 | F0-8 |
| DB-03, OFF-05 | F8-6 |
| DB-05 | F1-1 |
| OFF-03, SYN-08 | F5-1 |
| OFF-04 | F5-5 |
| OFF-06 | F0-7 |
| SYN-01, ERR-06 | F6-2 |
| SYN-02, SYN-03, ARC-06 | F7 (F7-1 s.d. F7-11) |
| SYN-04 | F6-4 |
| SYN-05 | F8-3 |
| SYN-06 | F6-4 |
| SYN-07 | F7-8 |
| SYN-09 | F6-5 |
| ARC-01 | F2-1 |
| ARC-02 | F4-9 |
| ARC-03 | F0-5 |
| ARC-04 | F0-9, F2-5 |
| ARC-05, ERR-05 | F5-3, F9-5 |
| FLW-02 | F5-2, F7-8 |
| FLW-05 | F0-1 |
| ERR-01 | F9-2 |
| ERR-02, ERR-07, ERR-08 | F6-1, F9-3 |
| FLG-01, FLG-02, FLG-03 | F6-3 |
| FLG-04 | Uji regresi F6-3 |
| SC-01 | F2, F3 |
| SC-02 | F0, F4, F6 (termasuk F6-7, F6-8, F6-9) |
| SC-03 | F5, F7 (termasuk F7-10, F7-11) |
| SC-04 | F7 |
| SC-05 | F8 |

---

## 8. Rencana Uji

### 8.1 Lapisan

| Lapisan | Isi | Lokasi |
|---|---|---|
| Unit | harga, pajak, alokasi diskon, HPP, opname, retur, purge, payload arsip | `pusatkupos/test/` |
| Integrasi | transaksi SQLite, apply sync, endpoint relay, API arsip | `pusatkupos/test/`, `relay/test/`, `archive/test/` |
| E2E | dua perangkat, dua VPS, force close, restore, recovery | harness baru |
| Data nyata | salinan DB pilot/dev yang berisi data, bukan DB kosong | manual + skrip uji |

### 8.2 Uji wajib per fase

- **F0:** logout dengan outbox; restore pra-login ditolak; restore lokal tanpa
  jaringan dengan frasa backup; restore toko berbeda ditolak; void saat retur;
  WAL/SHM; DB locked.
- **F1:** schema baru; deteksi duplikat; rekonsiliasi ledger.
- **F2:** nego 350.000 → 325.000; harga di bawah modal; harga nol; grant
  tunggal; audit.
- **F3:** struk vs DB vs laporan; bayar penuh transfer; pajak inklusif/
  eksklusif; penyesuaian; batas zona waktu 00:00–06:59 WIB.
- **F4:** opname basi; stok negatif; retur/void; movement sources; matriks izin
  keluar/masuk/opname; percobaan bypass; tablet mekanik read-only; reconnect;
  matriks izin dijalankan di tier gratis.
- **F5:** 24 jam tanpa jaringan (jual, stok, cetak, retur/void) → 50+ nota →
  tutup paksa → restart → tetap penuh → reconnect → sync; tidak ada polling
  60 detik; riwayat 201+; filter tanggal; banner tidak muncul di toko gratis.
- **F6:** dua perangkat; offline 24 jam lalu reconnect; putus-nyambung; retry;
  envelope rusak; feature flag; void di A vs retur di B pada kedua urutan HLC;
  kompensasi idempoten; kasus “butuh bantuan owner”; klien lama menerima
  envelope baru; perangkat kembali setelah 30 hari dengan outbox.
- **F7:** upload backlog; duplikat; search 2 tahun; arsip mati; purge tertahan;
  restore arsip; purge ditolak untuk nota kredit belum lunas, periode belum
  ditutup, atau `purge_enabled` off; laporan tahunan sebelum dan sesudah purge
  identik; retur atas nota terpurge; ekspor arsip lengkap.
- **F8:** perangkat dicabut; Google hilang; admin recovery; rotasi; blob Drive
  bocor tidak terbuka dengan PIN; dua pemegang Shamir diperlukan; perangkat
  dicabut masuk mode terkunci dan outbox dapat diekspor.
- **F9:** storage penuh; cetak gagal; token kedaluwarsa.
- **F10:** query 2 tahun; selisih pembulatan.

### 8.3 Skenario SC-01..SC-05

| Skenario | Target |
|---|---|
| SC-01 nego offline | acuan + final + grant + struk + laporan |
| SC-02 multi-device | tidak ada duplikasi/kehilangan; void/retur/opname konsisten; konflik konvergen |
| SC-03 riwayat 1 tahun | lokal 1 tahun + purge aman + stub; arsip VPS lengkap; laporan periode lama dari tutup buku |
| SC-04 cari 2 tahun | pencarian server + dekripsi lokal + struk |
| SC-05 E2EE | server buta isi; recovery/rotasi terbukti |

---

## 9. Peta File

| Area | File utama |
|---|---|
| Transaksi/harga | `lib/data/app_database.dart`, `lib/data/price_rules.dart`, `lib/data/models.dart`, `lib/ui/screens/pos_screen.dart` |
| Pajak/laporan | `lib/data/pajak.dart`, `lib/data/nota_adjustment_service.dart`, layar laporan |
| Stok | `lib/data/stock_ledger.dart`, `lib/data/opname_service.dart`, `lib/data/sale_return_service.dart`, `lib/ui/screens/stock_screen.dart` |
| Izin/peran | `lib/auth/permissions.dart`, `lib/auth/operator.dart`, `lib/data/access_control.dart`, `lib/data/account_service.dart`, `lib/data/store_settings.dart` |
| Sync | `lib/sync/sync_service.dart`, `lib/sync/sync_scheduler.dart`, `lib/sync/sync_conflict_rules.dart`, `lib/sync/relay_client.dart`, `lib/sync/crypto.dart` |
| Offline/backup | `lib/ui/entry_gate.dart`, `lib/data/backup_service.dart`, `lib/ui/home_shell.dart` |
| E2EE/identitas | `lib/data/google_auth_service.dart`, `lib/data/session_service.dart`, `lib/data/secure_store.dart` |
| Relay | `relay/lib/server.dart`, `relay/lib/db.dart`, `relay/lib/config.dart`, `relay/lib/auth_rules.dart` |
| Arsip baru | `archive/` (service, schema, API, test) |
| Uji | `pusatkupos/test/`, `relay/test/`, `archive/test/` |

---

## 10. Yang Tidak Dilakukan

- Tidak ada rantai migrasi/kolom legacy.
- Tidak ada ketergantungan jaringan untuk jual, stok, cetak, retur, void, atau
  riwayat selama minimal 24 jam.
- Tidak ada sync otomatis terus-menerus di background atau polling 60 detik.
- Tidak ada plaintext transaksi di relay atau arsip.
- Tidak ada perhitungan stok di server.
- Tidak ada auto-perbaikan data historis.
- Tidak ada notifikasi OS untuk peringatan 24 jam.
- Tidak ada endpoint hapus arsip.
- Tidak ada pencarian teks bebas di server.
- Tidak ada penjualan negatif lokal.
- Tidak ada restore tanpa autentikasi owner.
- Tidak ada logout yang menghapus data.
- Tidak ada wipe otomatis pada perangkat yang dicabut.
- Tidak ada purge sebelum `purge_enabled` aktif.
- Tidak ada purge saat offline.

---

## 11. Risiko dan Mitigasi

| Risiko | Mitigasi |
|---|---|
| Satu VPS arsip rusak = arsip hilang | Snapshot + offsite + uji restore (F7-7) |
| Token arsip dicabut terlambat (24 jam) | TTL pendek, audit, rotasi kunci (F8-2) |
| Satu perangkat offline lama menahan pruning | Perangkat aktif = heartbeat <= 30 hari; kirim outbox lama dulu, lalu re-enroll + snapshot (F6-2) |
| Data tertunda tidak terlihat | Status pending langsung + banner setelah 24 jam (F5-1/F5-3) |
| Offline lebih dari 24 jam | Outbox durable, status terlihat, operasi tetap jalan; uji 24 jam (F5-5) |
| Sesi/lisensi kedaluwarsa saat offline | Sesi lokal tanpa TTL jaringan; lisensi hanya diperiksa layanan server (F5-0/F4-10) |
| Sync terlalu sering menguras baterai/relay | Event-driven, batch, fallback 15 menit, tanpa sync background (F5-0) |
| Stok basi karena perangkat lain menulis | Ledger lokal, konvergensi saat sync, konflik terlihat (F4-7/F6-3) |
| Opname basi karena izin stok dipegang peran lain | Opname absolut + HLC + konflik; jangan mengandalkan asumsi satu penulis (F4-1) |
| Payload arsip tidak lengkap | Kontrak payload + uji komisi/penyesuaian (F7-1) |
| Storage tumbuh selamanya | Kuota, monitoring, rencana ekspansi (F7-9) |
| Akun gratis tanpa arsip kehilangan riwayat | Purge hanya dengan receipt; tanpa arsip tidak pernah purge (F7-5) |
| Offline gratis menurunkan konversi premium | Premium dijual lewat sync, arsip, multi-perangkat, dan multi-toko; data lokal tidak dikunci (D21) |
| Reset schema menghapus DB dev | Backup wajib sebelum upgrade; sah karena belum ada data hidup (dikonfirmasi) |
| Kunci hilang | Google + frasa pemulihan + admin Shamir + uji recovery (F8-1/F8-8) |
| Laporan lama tidak dapat direkonsiliasi setelah purge | Tutup buku bulanan + arsip + pencarian + dekripsi lokal (F7-8/F7-11) |
| Konflik void/retur menyisakan selisih kas yang sudah dibayar fisik | Kompensasi otomatis + item “perlu tindak lanjut” + bantuan owner (F6-8/F6-9) |
| Blob Drive bocor, PIN lemah | Frasa pemulihan + Argon2id (F8-1) |
| Satu kunci admin membuka semua toko | Shamir 2-dari-3 (F8-1) |
| Klien lama menerapkan aturan lama pada data baru | Versi protokol (F6-7) |
| Purge sebelum recovery terbukti | Flag `purge_enabled` + gate (F7-5/F8-8) |
| Premium berakhir setelah data lama dipurge | Arsip baca-saja 12 bulan + ekspor (D27, F7-10) |

---

## 12. Definisi Selesai

Satu putaran implementasi dinyatakan selesai jika:

1. F0–F10 lulus gate dan seluruh temuan di §7 punya bukti uji. Rilis pilot
   boleh setelah P2 (F8); rilis umum setelah F9–F10.
2. Target §1.1 terbukti: offline 24 jam tetap penuh (jual, stok, cetak,
   retur/void), sesi tidak terputus, sync hanya event-driven tanpa polling
   60 detik, dan reconnect memicu sync.
3. Tidak ada jalur kehilangan data yang tersisa: logout, restore, reset, purge,
   void/retur, opname, sync, kunci. Tidak ada aksi stok yang lolos tanpa izin
   `stok_keluar`, `stok_masuk`, atau `opname` yang sesuai.
4. Skenario SC-01..SC-05 lulus pada salinan data nyata dari pilot/dev.
5. Dua VPS berjalan terpisah: relay tidak bisa menghapus arsip; arsip tidak
   bisa membaca plaintext.
6. Riwayat 1 tahun lokal + pencarian 2 tahun via arsip bekerja.
7. Semua default di §2 dan Lampiran A–D tercatat; jika ada yang diubah,
   dokumen ini diperbarui sebelum kode berubah.
8. Batas §1.2 terbukti: operasi offline gratis tanpa cek lisensi; premium hanya
   untuk sync, arsip, pencarian server, multi-perangkat, dan multi-toko.
9. Konflik void/retur konvergen tanpa selisih stok atau kas yang tak tercatat;
   kasus sulit tampil di layar Konflik untuk owner.
10. Purge tidak pernah aktif sebelum escrow dan restore arsip terbukti; laporan
    periode lama tidak berubah setelah purge; revisi snapshot stabil 7 hari
    sebelum purge.

---

## Lampiran A–D. Matriks Rujukan (normatif)

Empat matriks ini menutup ambiguitas di §3. Jika ada pertentangan dengan teks
§3, berhenti dan perbarui keduanya sebelum kode berubah (aturan kerja no. 3).
Sel bertanda (default) adalah default kerja baru yang boleh diubah pemilik tanpa
mengubah arsitektur; daftarnya ada di akhir lampiran.

### Lampiran A. Matriks Rahasia

| Rahasia | Pemegang | Fungsi | Disimpan di | Tidak boleh | Rotasi / pencabutan |
|---|---|---|---|---|---|
| PIN kasir (tiap operator) | Operator: kasir, gudang, supervisor, mekanik | Membuka sesi operator dan mengunci layar; mengotorisasi aksi sesuai izin perannya | Hash PBKDF2 600k + salt di secure store perangkat (bukan `app_meta`, F8-6); lockout setelah gagal berulang | Dikirim ke server; dipakai menyetujui grant harga, reset, atau restore; menjadi kunci enkripsi | Operator mengganti sendiri; owner dapat mereset; menonaktifkan akun operator mengakhiri sesinya. Rotasi tidak mengubah kunci apa pun |
| PIN owner | Owner toko | Membuka layar persetujuan (grant di bawah modal), reset perangkat, restore lokal (bersama frasa backup), persetujuan enrollment perangkat, tutup buku manual, penyelesaian konflik | Hash PBKDF2 600k + salt di secure store; lockout | Dikirim ke server; menjadi otorisasi itu sendiri (otorisasi tetap berupa grant, §3.2 butir 4); menjadi kunci enkripsi | Owner mengganti dengan PIN lama; bila lupa, lewat Google Sign-In + frasa pemulihan. Rotasi tidak merotasi store key |
| Frasa pemulihan (>= 6 kata) | Owner; salinan fisik offline | Argon2id → membuka wrapped store key di Google Drive app data (jalur recovery utama, D28) | Tidak disimpan di perangkat, server, atau Google | Dikirim ke server; disimpan digital bersama akun Google; sama dengan PIN | Owner membuat frasa baru → re-wrap store key → blob baru berversi n+1 → blob lama dihapus. Wajib bila akun Google diduga diambil alih, frasa bocor, atau owner berganti. Tidak mengubah store key |
| Frasa backup | Owner | Mengenkripsi file backup (AES-256-GCM + KDF) untuk restore lokal (D22) | Tidak disimpan; manifest backup memuat `backup_key_id`, bukan frasanya | — | Dipakai ulang sebagai frasa pemulihan (membatasi dampak kebocoran). Frasa baru berlaku untuk backup baru; backup lama tetap butuh frasa lama, ditandai `backup_key_id` |
| Share admin Shamir 2-dari-3 | Tiga admin berbeda (bukan owner toko) | Membuka master recovery key → membuka escrow darurat saat Google hilang | Offline, terpisah antar pemegang; tidak di VPS | Dipegang satu orang lebih dari satu share; membuka escrow tanpa verifikasi identitas dan audit | Re-split dengan master key baru bila pemegang berganti, share hilang/bocor, atau setelah dipakai; escrow lama di-rewrap. Escrow diturunkan per toko (HKDF master + `store_id`) sehingga satu pembukaan tidak membuka toko lain |
| Device key (Ed25519 tanda tangan + X25519 wrapping) | Perangkat itu sendiri; tidak terlihat manusia | Menandatangani envelope; membuka wrapped store key; meminta token arsip | Android Keystore (non-exportable bila didukung); Windows DPAPI/credential store; bukan plaintext di DB | Diekspor, disalin antar perangkat, atau ikut backup | Perangkat dicabut: kunci dibuang dan store key dirotasi. Perangkat baru membuat pasangan kunci baru dan masuk lewat persetujuan owner |
| Store key (AES-GCM) | Semua perangkat aktif (wrapped per perangkat) + escrow | Mengenkripsi payload envelope dan bundle arsip | Hanya dalam bentuk wrapped; kunci lama disimpan wrapped untuk membaca riwayat | Disimpan plaintext; dikirim ke relay atau arsip | Wajib dirotasi saat perangkat dicabut; envelope dan arsip membawa `key_version` |
| Search key (HMAC) | Diturunkan dari store key (HKDF, label search) | Membuat token indeks arsip (nomor nota, token nama) | Diturunkan saat dipakai; tidak disimpan terpisah | Dikirim ke server | Mengikuti `key_version`. Klien mengirim token untuk setiap versi yang aktif; server tidak dapat mengindeks ulang, jadi tidak ada reindex (default) |
| Token arsip (JWT) | Perangkat | Akses upload/baca arsip | Memori/secure store, TTL 24 jam | Dipakai untuk delete (tidak ada scope delete) | Kedaluwarsa otomatis; relay berhenti menerbitkan setelah pencabutan; premium berakhir → hanya `archive:read` |

Aturan lintas: PIN dan frasa tidak pernah meninggalkan perangkat atau kepala
owner; tidak ada rahasia di atas yang boleh muncul di log, backup tidak
terenkripsi, atau pesan error; setiap rotasi dan pembukaan escrow menulis
`business_audits`.

### Lampiran B. Matriks Sumber Laporan

Istilah: **berjalan** = bulan yang belum ditutup; **tertutup-lokal** = ada
`period_closings` dan nota masih ada di perangkat; **tertutup-purge** = ada
`period_closings` dan nota sudah dipurge (tinggal stub). Semua batas bulan
memakai zona toko.

| Laporan | Berjalan | Tertutup-lokal | Tertutup-purge | Catatan |
|---|---|---|---|---|
| Harian kasir | Nota + payments + cash_ledger | Nota + payments + cash_ledger | Kas dari cash_ledger; item nota via “Buka dari arsip” (online) | Snapshot bulanan tidak memuat rincian harian |
| Penjualan / omzet | Nota (`total_efektif`) | Angka: snapshot omzet; rincian: nota | Angka: snapshot; rincian: arsip online | Nota VOID bernilai 0 dengan badge |
| Laba kotor | Nota + HPP dari `stock_movements` (`harga_pokok_satuan_cents`) | Angka: snapshot (dpp/omzet, hpp); rincian: nota | Angka: snapshot; rincian: arsip online | Jasa tanpa modal ditampilkan sebagai kelompok sendiri |
| Pajak (DPP/PPN) | Snapshot pajak per nota (`pajak_snapshot_json`) | Snapshot dpp, ppn | Snapshot dpp, ppn | Tidak pernah dihitung ulang dengan tarif saat ini; nota TANPA tidak masuk DPP |
| Retur | `sale_returns` sebagai dokumen negatif di periode retur | Snapshot `retur_*`; rincian: `sale_returns` | Snapshot `retur_*`; retur atas nota terpurge adalah dokumen baru di periode berjalan | Retur tidak mengubah periode nota asal |
| Koreksi / penyesuaian | `nota_adjustments` di periode berjalan | Tidak mengubah snapshot; koreksi dicatat di periode berjalan | Sama | Aturan D15 dan aturan kerja no. 5 |
| Stok (saldo, kartu stok) | `stock_items` + `stock_movements` | Sama | Sama (ledger tidak dipurge) | Rekonsiliasi saldo = jumlah movement |
| Kas | `cash_ledger` (CASH/TRANSFER) | `cash_ledger`; snapshot `kas_per_metode` sebagai pembanding | Sama | Satu definisi di seluruh layar (F5-6) |
| Piutang | Nota kredit belum lunas | Nota kredit belum lunas | Tidak ada: nota non-final tidak boleh dipurge | Hanya status belum lunas dan bukan VOID |
| Komisi | `service_record_commissions` | Snapshot komisi; rincian: nota | Snapshot; rincian: arsip online | — |
| Opname / saldo negatif | Ledger + laporan opname | Sama | Sama | Hanya membaca, tidak mengubah data |

Aturan:

1. Tutup buku dihitung dari nota + ledger dengan aritmetika integer, menyimpan
   zona dan hash, dibuat perangkat owner dan disinkronkan sebagai dokumen.
2. Nota terlambat: nota yang tiba setelah periodenya ditutup tetap diterapkan,
   lalu menerbitkan revisi snapshot berikutnya (`rev n+1`). Snapshot lama tidak
   diubah; revisi dicatat audit; purge periode itu ditunda sampai revisi tidak
   berubah selama 7 hari (default).
3. Rekonsiliasi: pada tertutup-lokal, hasil dari nota harus sama dengan
   snapshot. Selisih memunculkan peringatan “rekonsiliasi gagal” tanpa mengubah
   data.
4. Rentang lintas bulan (tahunan dan sejenisnya): jumlah snapshot bulan
   tertutup + bulan berjalan dari nota. Rentang yang tidak selaras batas bulan
   hanya dapat dihitung dari nota lokal atau arsip online; jika sudah dipurge
   dan offline, laporan menolak dengan pesan jelas, bukan angka parsial.

### Lampiran C. Matriks Konflik

Aturan umum: HLC lebih awal menang; bila HLC sama, `device_id` terkecil menang.
Kompensasi diterbitkan hanya oleh perangkat asal dokumen yang kalah, dengan
`request_id` turunan dari id konflik (hash dari id dokumen terurut), sehingga
idempoten. Dokumen kompensasi tidak pernah menjadi sisi konflik baru. Jika
perangkat asal tidak menerbitkannya dalam 7 hari (default), status menjadi
“butuh bantuan owner” dan owner dapat menerbitkannya dari layar Konflik.

| Konflik | Urutan HLC | Pemenang | Dokumen kompensasi | Stok | Kas | Bantuan owner bila |
|---|---|---|---|---|---|---|
| Void vs retur | Void lebih awal | Void | Pembatalan retur (oleh perangkat retur) | Movement masuk retur dibalik | Refund retur dibalik; karena uang sudah keluar, dicatat “perlu tindak lanjut” | Stok hasil pembalikan negatif karena sudah terjual lagi |
| Void vs retur | Retur lebih awal | Retur (void dinyatakan melanggar D6) | Pembatalan void (oleh perangkat void) | Restock void dibalik; stok mengikuti retur aktif | Refund void dibalik; selisih yang sudah dibayarkan “perlu tindak lanjut” | Refund void sudah diserahkan ke pelanggan |
| Void vs void (nota sama) | Yang lebih awal | Void pertama | Tidak ada (refund hanya sekali) | Tidak ada | Tidak ada | Tidak pernah |
| Retur vs retur (qty total melebihi nota) | Yang lebih awal | Retur pertama | Pembatalan retur yang kalah, utuh (tidak parsial) | Movement masuk dibalik | Refund dibalik; “perlu tindak lanjut” | Stok pembalikan negatif |
| Penyesuaian vs void | Void lebih awal | Void | Pembatalan penyesuaian (bila sudah diterapkan di perangkat lain) | Tidak ada | Selisih ikut nilai void; tidak ada kas baru | Penyesuaian sudah dibayarkan |
| Penyesuaian vs void | Penyesuaian lebih awal | Keduanya valid | Tidak ada; void memakai nilai efektif pasca penyesuaian | Tidak ada | Refund = nilai efektif - retur aktif | Tidak pernah |
| Penyesuaian vs retur | Penyesuaian lebih awal | Keduanya valid | Tidak ada; refund retur dihitung dari nilai efektif saat penerapan | Tidak ada | Refund dibatasi nilai efektif | Retur melebihi nilai efektif baru |
| Pembatalan retur vs penjualan baru atas stok yang sama | Penjualan lebih awal dan stok habis | Penjualan | Pembatalan retur ditolak, tampil sebagai konflik (§3.3 butir 4) | Tidak ada | Tidak ada | Selalu (owner memutuskan: biarkan retur atau koreksi stok) |
| Opname vs movement lain | Urutan apa pun | Keduanya valid | Tidak ada; delta idempoten | Selisih masuk laporan opname | Tidak ada | Tidak pernah |
| Penjualan dua perangkat menghabiskan stok yang sama | Urutan apa pun | Keduanya valid | Tidak ada | Saldo negatif tercatat; memicu opname | Tidak ada | Tidak pernah (bukan konflik) |
| Feature flag | Yang lebih baru | Yang lebih baru | Tidak ada | Tidak ada | Tidak ada | Tidak pernah |
| Status work order (tablet vs perangkat lain) | Yang lebih baru | Yang lebih baru; kedua perubahan tercatat dengan aktor | Tidak ada | Tidak ada | Tidak ada | Tidak pernah |
| Master data (katalog, harga master) | Yang lebih baru (default) | Yang lebih baru | Tidak ada; nota lama tetap memakai snapshot harga | Tidak ada | Tidak ada | Tidak pernah |

Aturan tambahan:

1. Kompensasi tidak pernah menghapus atau mengubah dokumen yang kalah; ia
   dokumen baru yang membalik efeknya.
2. Setiap baris “perlu tindak lanjut” terlihat di layar Konflik, badge riwayat,
   dan laporan rekonsiliasi sampai owner menandainya selesai dengan alasan.
3. Semua perangkat menghitung pemenang yang sama dari data yang sama; hasil
   yang berbeda dianggap bug dan wajib diuji (F6-3).

### Lampiran D. Matriks Versi Protokol

Istilah: **N** = versi terkini; **min_supported** = versi terendah yang diterima
relay. Header envelope membawa `protocol_version`; bundle arsip membawa
`schema_version`. `key_version` terpisah dan tidak termasuk matriks ini.

| Versi klien | Kirim | Terima / terapkan | Ack | Pruning relay | Perilaku lokal dan UI |
|---|---|---|---|---|---|
| N | Ya, header N | Semua envelope berversi <= N | Setelah diterapkan | Dihitung sebagai perangkat aktif | Normal |
| Lebih rendah dari N, tetapi >= min_supported | Ya, header versi klien; outbox tidak boleh tertahan | Envelope berversi <= versi klien; berhenti pada envelope pertama berversi lebih tinggi (cursor tidak maju melewatinya) | Hanya untuk envelope yang diterapkan | Dihitung aktif selama heartbeat <= 30 hari; menahan pruning dan memicu alert kuota | Operasi lokal penuh; banner “Perbarui aplikasi”; status sync “tertahan versi”, bukan dead-letter |
| Lebih rendah dari min_supported | Ditolak relay (426 Upgrade Required) | Feed ditolak | Tidak ada | Tidak menahan pruning setelah masa tenggang 30 hari (default) sejak `min_supported` dinaikkan | Operasi lokal penuh; sync berhenti; setelah upgrade: kirim outbox lama lebih dulu (envelope dibentuk ulang dari dokumen outbox, diverifikasi di F6-7), baru re-enroll + snapshot |
| Lebih tinggi dari yang dikenal relay | Ditolak; urutan rollout dilanggar | Tidak berlaku | Tidak ada | Tidak berlaku | Klien tetap lokal; insiden rollout, bukan perilaku normal |
| Snapshot berversi lebih tinggi dari klien | Tidak berlaku | Ditolak; klien meminta upgrade | Tidak ada | Tidak berlaku | Tetap lokal |
| Bundle arsip `schema_version` lama | Tidak berlaku | Klien terbaru wajib punya pembaca untuk semua `schema_version` yang pernah ada; server tidak pernah memigrasi bundle | Tidak berlaku | Arsip tidak dipangkas | Pencarian dan “Buka dari arsip” selalu bisa membaca nota lama |

Aturan rollout:

1. Urutan: arsip dan relay (kompatibel mundur) → klien → naikkan
   `min_supported` belakangan.
2. `min_supported` hanya dinaikkan dengan pengumuman minimal 30 hari (default)
   sebelum efektif.
3. Perubahan aturan domain (void/retur, konflik) yang mengubah arti envelope
   wajib menaikkan `protocol_version`.
4. Klien yang berhenti menerapkan tidak pernah membuang envelope: envelope
   tetap di relay sampai semua perangkat aktif ack atau perangkat dinyatakan
   tidak aktif.

### Dampak ke Task

| Matriks | Task terdampak |
|---|---|
| A. Rahasia | F0-3 (frasa backup, PIN owner), F8-1 (frasa pemulihan, Shamir), F8-2/F8-10 (device dan store key), F8-4 (search key), F8-6 (PIN di secure store) |
| B. Sumber laporan | F3-6, F3-7, F3-9, F5-6, F7-5, F7-11 (revisi snapshot dan rekonsiliasi) |
| C. Konflik | F6-3, F6-8, F6-9 (layar Konflik dan penerbitan oleh owner) |
| D. Versi protokol | F6-1, F6-2, F6-7, F7-3 (token), F7-8 (pembaca `schema_version`) |

### Default baru yang perlu dikonfirmasi

| Default | Nilai |
|---|---|
| Batas waktu perangkat asal menerbitkan kompensasi sebelum owner dapat mengambil alih | 7 hari |
| Masa tenggang sebelum perangkat di bawah `min_supported` berhenti menahan pruning | 30 hari |
| Konflik master data | Yang lebih baru menang |
| Search key berversi, tanpa reindex arsip | Klien mengirim token untuk semua versi aktif |
| Penundaan purge setelah revisi snapshot terakhir | 7 hari tanpa perubahan |
