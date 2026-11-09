# IMPLEMENTATION PLAN — PUSATKUPOS

**Sumber:** hasil audit logika bisnis (42 temuan; rekap ada di Bagian 1). Berkas laporan audit lama sudah dihapus dari repo setelah temuannya dipetakan ke tugas.
**Tahap:** implementasi kode. Tidak ada audit ulang.
**Kondisi data:** belum ada pengguna maupun data produksi. Skema baru dimulai bersih; tidak ada migrasi pemindahan data lama, tidak ada user/data palsu, dan tidak ada lapisan kompatibilitas database lama.
**Produk utama:** APK Android PusatkuPOS (Flutter). Relay diperbaiki hanya untuk autentikasi, sinkronisasi, lisensi, dan kontrak data yang dibutuhkan APK.
**Larangan selama fase implementasi:** unit/integration/widget/automated test, test suite, build APK/debug/release, menjalankan aplikasi/server, simulasi runtime, pengujian database/sinkronisasi/perangkat. Pengujian hanya dilakukan pada FASE 7 setelah seluruh kode selesai.

**Legenda status:** `[ ]` belum, `[x]` selesai kode, `[!]` terhambat/keputusan bisnis, `[-]` tidak diperlukan (dengan alasan).

---

## 1. Ringkasan seluruh temuan audit

| ID | Temuan | Risiko | Validitas | Fase implementasi |
|---|---|---|---|---|
| BL-01 | Opname absolut dikirim sebagai delta | KRITIS | SUSPECTED | 3 |
| BL-02 | Retur/void lintas perangkat menghasilkan stok/nilai berbeda | KRITIS | SUSPECTED | 3 |
| BL-03 | Gaji siklus sama dapat dibayar dua perangkat lalu saling menimpa | TINGGI | SUSPECTED | 3 |
| BL-04 | Komisi dihitung ulang memakai tarif saat ini, bukan snapshot | TINGGI | CONFIRMED | 3 |
| BL-05 | Total nota terkoreksi tidak konsisten daftar/detail/struk/laporan | TINGGI | CONFIRMED | 4 |
| BL-06 | Karyawan nonaktif masih dapat menulis lewat token relay dan membuka sesi | TINGGI | CONFIRMED | 2 |
| BL-07 | Akun karyawan tidak ikut snapshot/toko baru dan tidak dibuat saat login | TINGGI | SUSPECTED | 2 |
| BL-08 | Izin operator tidak dihitung ulang saat berpindah toko | TINGGI | CONFIRMED | 2 |
| BL-09 | Otorisasi retur memakai izin `void`, bukan `retur` | SEDANG | CONFIRMED | 2 |
| BL-10 | Perubahan/deaktivasi akun lokal tidak otomatis dikirim ke relay | SEDANG | CONFIRMED | 2 |
| BL-11 | Role/izin/toko karyawan tidak ikut envelope sinkronisasi | SEDANG | CONFIRMED | 2 |
| BL-12 | Estimasi: batal tanpa otorisasi, revisi tanpa cek status/versi unik | SEDANG | CONFIRMED | 2 |
| BL-13 | Retur dan pelunasan tanpa idempotensi/penjagaan submit ganda | SEDANG | SUSPECTED | 3 |
| BL-14 | Pelunasan piutang lintas perangkat dapat melebihi sisa tagihan | SEDANG | SUSPECTED | 3 |
| BL-15 | Amplop void tidak self-contained; total dibayar bergantung amplop payment | SEDANG | SUSPECTED | 3 |
| BL-16 | Merge pelanggan tidak memindahkan nota tanpa unit dan referensi lain | SEDANG | CONFIRMED | 3 |
| BL-17 | Daftar/detail riwayat mengabaikan `service_records.customer_id` | SEDANG | CONFIRMED | 4 |
| BL-18 | Struk mencetak total asli, bukan total efektif | SEDANG | CONFIRMED | 4 |
| BL-19 | "Pendapatan hari ini" adalah omzet bruto, bukan neto retur/kas | SEDANG | CONFIRMED | 4 |
| BL-20 | Restore multi-toko tidak membatasi total ukuran dekompresi | SEDANG | CONFIRMED | 6 |
| BL-21 | Penjualan bersamaan lintas perangkat dapat menjual stok yang sama | SEDANG | SUSPECTED | 3 |
| BL-22 | Passphrase backup otomatis ditampilkan dalam teks jelas | SEDANG | CONFIRMED | 6 |
| BL-23 | Rekonsiliasi hanya membandingkan ID nota, bukan nilai/retur/pembayaran | SEDANG | CONFIRMED | 4 |
| BL-24 | Kebijakan stok negatif tidak konsisten | SEDANG | NEEDS VALIDATION | 3 |
| BL-25 | Penanda jatuh tempo memakai total asli dan mengabaikan retur/koreksi | RENDAH | CONFIRMED | 4 |
| BL-26 | Filter stok dan pemeriksaan kode mengabaikan status hapus | RENDAH | CONFIRMED | 4 |
| BL-27 | `actor == null` diperlakukan sebagai pemilik | RENDAH | CONFIRMED | 2 |
| BL-28 | Principal viewer dianggap owner dan database viewer dapat ditulis | RENDAH | SUSPECTED | 2 |
| BL-29 | Masa berlaku lisensi memakai jam perangkat | RENDAH | SUSPECTED | 6 |
| BL-30 | Penyesuaian nota dari relay dibuang diam-diam bila nota belum ada/void | RENDAH | SUSPECTED | 4 |
| BL-31 | Follow-up: tanpa aktor/izin, kuota sebelum commit, tanggal terhapus | RENDAH | SUSPECTED | 2 |
| BL-32 | Backup toko nonaktif dibaca tanpa checkpoint | RENDAH | SUSPECTED | 6 |
| BL-33 | Kode perangkat 3 karakter dan penghitung dokumen berpotensi bentrok | RENDAH | SUSPECTED | 3 |
| BL-34 | Void tidak menyesuaikan komisi dan pembayaran tersimpan | RENDAH | CONFIRMED | 3 |
| BL-35 | Relay menerima token perangkat tanpa memeriksa status lisensi | RENDAH | SUSPECTED | 6 |
| BL-36 | Pembuatan order kerja memakai izin `buat_nota`, mengabaikan jenis order | RENDAH | CONFIRMED | 2 |
| BL-37 | `createEstimate` memperlakukan actor null sebagai pemilik | RENDAH | CONFIRMED | 2 |
| BL-38 | Hapus supplier menghapus relasi tanpa tombstone | RENDAH | SUSPECTED | 4 |
| BL-39 | Kembalian struk hanya mencerminkan pembayaran awal | RENDAH | CONFIRMED | 4 |
| BL-40 | Penerima retur tidak merekalkulasi komisi | RENDAH | CONFIRMED | 3 |
| BL-41 | Kode barang duplikat lintas perangkat memblokir sinkronisasi | SEDANG | SUSPECTED | 3 |
| BL-42 | Restore mengganti database non-atomik dan tidak pulih otomatis | TINGGI | SUSPECTED | 6 |

**Total: 42 temuan** (2 KRITIS, 7 TINGGI, 17 SEDANG, 16 RENDAH).

---

## 2. Prinsip desain database baru

Database dirancang ulang sebagai satu skema bersih kanonik. Tidak ada `migrateSchemaV*` dan tidak ada pembacaan database lama.

1. **Identitas:** setiap entitas tersinkron memiliki `sync_id` (UUID) unik, `store_id`, `device_id`, HLC, dan `deleted_at`. Primary key lokal tetap `INTEGER` untuk kecepatan query; referensi lintas perangkat memakai `sync_id`.
2. **Uang:** disimpan sebagai integer rupiah. Tidak ada pembulatan ganda di UI dan service.
3. **Kuantitas:** disimpan sebagai `jumlah_milli` (1/1000) untuk barang desimal; `jumlah` utuh diturunkan.
4. **Transaksi append-only:** nota, baris, pembayaran, retur, koreksi, dan mutasi stok tidak dihapus fisik. Pembatalan adalah state eksplisit (`VOID`) dengan jejak.
5. **Total efektif satu sumber:** `service_records.total_efektif` dihitung ulang dari komponen tersimpan oleh satu fungsi dan dipakai semua layar, struk, dan laporan.
6. **Snapshot:** tarif komisi, harga jual, harga modal, diskon, dan PPN disimpan pada baris transaksi saat dibuat; perubahan master tidak mengubah transaksi lama.
7. **Stok sebagai ledger:** `stock_movements` adalah catatan append-only dengan `stok_sebelum_milli`, `stok_sesudah_milli`, sumber transaksi, dan kunci idempoten unik. `stock_items.jumlah_milli` adalah saldo yang diturunkan dari ledger.
8. **Pembayaran:** setiap pembayaran memiliki `request_id` unik; total dibayar/sisa dihitung dari seluruh pembayaran dan retur, bukan ditambah manual.
9. **Gaji:** kunci unik global `employee_sync_id + cycle_start`; pembayaran kedua untuk siklus yang sama menjadi konflik yang ditinjau, bukan menimpa.
10. **Retur:** dibatasi per baris terhadap jumlah terjual yang belum diretur; nota `VOID` bersifat terminal.
11. **Akun/role/permission:** akun melekat pada user; akses toko dan izin per toko eksplisit; perubahan memiliki `permission_version` dan audit.
12. **Sinkronisasi:** amplop idempoten, `applied_deltas` mencegah penerapan ganda, konflik yang tidak terkait tidak menahan seluruh antrean, dan urutan HLC hanya dipakai untuk metadata—bukan untuk uang/stok tanpa aturan bisnis.
13. **Backup/restore:** pertukaran berkas atomik, pemulihan startup, batas ukuran agregat, checkpoint sebelum salinan.
14. **Saldo awal:** stok, utang supplier, dan piutang pelanggan awal dicatat lewat mekanisme khusus per toko, bukan lewat pembelian/nota palsu; dapat diaudit, dikoreksi, disinkronkan, dan ikut backup.
15. **Valuasi:** HPP memakai rata-rata bergerak per toko per barang; snapshot harga modal per baris tetap disimpan untuk audit dan tidak berubah surut.
16. **Fitur opsional per toko:** modul yang tidak dipakai dapat dinonaktifkan per toko oleh pemilik; penonaktifan tidak menghapus data, hanya menyembunyikan menu/aksi baru; flag ditegakkan di service, UI, dan penerima sinkronisasi, serta ikut snapshot/backup.

---

## 3. Fase dan tugas implementasi

### FASE 1 — FONDASI SKEMA BERSIH DAN KONTRAK DATA

**Tujuan:** mengganti fondasi data lama dengan skema bersih yang mendukung snapshot, ledger, idempotensi, dan integritas relasi. Fase ini menjadi ketergantungan utama fase transaksi dan sinkronisasi.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-001 | Fondasi | Hapus `migrateSchemaV2/V3/V4`, jadikan `createCleanSchema` satu-satunya jalur, naikkan versi skema, tolak database lama dengan pesan jelas (tanpa migrasi data) | `pusatkupos/lib/data/schema.dart`, `pusatkupos/lib/data/app_database.dart` | Database baru selalu dibuat dari skema kanonik; tidak ada jalur upgrade lama | — | KRITIS |
| TASK-002 | BL-26, BL-41 | Redesain tabel master: `customers`, `vehicle_or_units`, `stock_items`, `harga_jasa`, `suppliers`, `supplier_items`; index soft-delete, uniqueness yang tepat, FK dan check constraint | `schema.dart`, `app_database.dart`, `supplier_service.dart` | Master data tidak mengembalikan baris terhapus; kode barang tidak menjadi sumber deadlock sinkronisasi | TASK-001 | TINGGI |
| TASK-003 | BL-05, BL-15, BL-34 | Redesain `service_records`: komponen biaya immutable, `total_efektif`, state VOID terminal, kolom snapshot mode/diskon/pajak, index laporan | `schema.dart`, `app_database.dart`, `models.dart` | Satu total efektif untuk semua layar; void memiliki state dan jejak yang jelas | TASK-001 | TINGGI |
| TASK-004 | BL-02, BL-04, BL-18 | Redesain `service_jobs`, `service_parts`, `estimate_items`: snapshot harga/modal/tarif, `jumlah_milli`, `jumlah_retur_milli`, check qty positif | `schema.dart`, `app_database.dart`, `models.dart`, `price_rules.dart` | Baris transaksi dapat diaudit dan dibatasi returnya | TASK-003 | TINGGI |
| TASK-005 | BL-13, BL-14, BL-15, BL-39 | Redesain `service_payments`: `request_id` wajib unik, `jenis`, `metode`, `nominal`, alokasi, waktu, operator, `kas_shift_id` opsional; tambah ledger kas | `schema.dart`, `app_database.dart`, `models.dart` | Pembayaran idempoten dan dapat direkonsiliasi ke kas | TASK-003 | TINGGI |
| TASK-006 | BL-04, BL-34, BL-40 | Redesain `service_record_commissions`: snapshot mode/nilai/dasar, status VOID, sumber perhitungan, unique per nota+karyawan | `schema.dart`, `app_database.dart` | Komisi tidak berubah surut saat tarif berubah | TASK-004 | TINGGI |
| TASK-007 | BL-01, BL-21, BL-24 | Redesain `stock_movements` sebagai ledger: saldo sebelum/sesudah, jenis, sumber, opname absolut, kunci idempoten; index per barang dan waktu | `schema.dart`, `app_database.dart` | Stok dapat direkonsiliasi dan opname absolut dapat diterapkan | TASK-002 | KRITIS |
| TASK-008 | BL-03 | Redesain `salary_payments` dan `employee_debts`: kunci siklus global, referensi pembayaran, status konflik, jejak potongan | `schema.dart`, `employee_service.dart`, `app_database.dart` | Satu kewajiban gaji tidak dapat dibayar dua kali tanpa konflik eksplisit | TASK-001 | TINGGI |
| TASK-009 | BL-02, BL-13, BL-41 | Redesain `sale_returns`/`sale_return_items`: state, idempotency key, batas per baris, referensi baris nota, unique per line | `schema.dart`, `sale_return_service.dart`, `app_database.dart` | Retur tidak dapat menggandakan stok/refund | TASK-004 | KRITIS |
| TASK-010 | BL-07, BL-08, BL-10, BL-11, BL-28 | Redesain akun/role/izin: `employee_accounts`, akses toko eksplisit, versi izin, audit, principal viewer; normalisasi izin yang dibutuhkan | `schema.dart`, `access_control.dart`, `account_service.dart`, `store_settings.dart` | Izin melekat pada user dan toko, bukan perangkat | TASK-001 | TINGGI |
| TASK-011 | BL-15, BL-30, BL-33, BL-41 | Redesain tabel sinkronisasi: konflik unik, `applied_deltas`, urutan/retry, counter perangkat tahan bootstrap; selaraskan skema PostgreSQL relay | `schema.dart`, `sync_service.dart`, `sync_conflict_rules.dart`, `relay/lib/db.dart` | Kontrak SQLite dan relay konsisten; konflik tidak menahan antrean | TASK-001 | TINGGI |
| TASK-012 | Semua | Sesuaikan model Dart dan mapper baris untuk kolom/tabel baru; hapus field lama yang tidak dipakai | `models.dart`, seluruh service yang membaca baris | Tidak ada query yang menunjuk kolom/tabel yang tidak ada | TASK-002..011 | TINGGI |

**Kriteria keluar fase:** skema bersih dapat dibuat tanpa migrasi; seluruh service memakai kolom baru; tidak ada referensi ke fungsi migrasi lama; relay memiliki kontrak tabel yang selaras.

---

### FASE 2 — OTORISASI, AKUN, DAN IDENTITAS

**Tujuan:** memastikan aktor, status akun, peran, izin, dan mode viewer berlaku sama di service, UI, perangkat lain, dan relay.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-013 | BL-27 | Wajibkan `Operator` pada semua operasi tulis; `null` ditolak atau menjadi principal sistem tanpa hak istimewa | `app_database.dart`, `order_service.dart`, `sale_return_service.dart`, `approval_service.dart` | Tidak ada jalur yang otomatis menjadi pemilik | — | SEDANG |
| TASK-014 | BL-37 | Samakan `createEstimate` dengan `createTransaction`: actor wajib, persetujuan di bawah modal | `order_service.dart` | Estimasi tidak dapat dibuat tanpa operator | TASK-013 | RENDAH |
| TASK-015 | BL-09 | Gunakan `permissionRetur` dan `roleAllows(role,'retur')` di service, UI, dan relay | `sale_return_service.dart`, `history_screen.dart`, `access_control.dart`, `relay/lib/server.dart` | Izin retur konsisten di semua lapisan | — | SEDANG |
| TASK-016 | BL-36 | Order kerja memakai `roleCanSelect(role, order_kerja)`/`buat_order`, bukan hanya `buat_nota` | `order_service.dart`, `store_settings.dart` | Jenis order per peran berlaku | — | RENDAH |
| TASK-017 | BL-12 | Wajibkan izin batal/revisi estimasi, cek status `aktif`, unique `(store_id, nomor_estimasi, versi)`, audit pembatalan | `order_service.dart`, `estimates_screen.dart`, `schema.dart` | Estimasi tidak dapat dibatalkan sembarang peran; versi tidak ganda | TASK-010 | SEDANG |
| TASK-018 | BL-31 | Teruskan operator dan periksa izin follow-up; konsumsi kuota setelah commit/kompensasi; pertahankan tanggal lama yang masih relevan | `followup_service.dart`, `followup_screen.dart` | Kuota dan jadwal tidak hilang karena kegagalan/izin | — | RENDAH |
| TASK-019 | BL-08 | Hitung ulang operator setelah `switchStore`, baca ulang akun aktif, tolak toko di luar `storeIds` | `home_shell.dart`, `app_state.dart`, `employee_auth_service.dart`, `store_settings.dart` | Izin mengikuti toko aktif | TASK-010 | TINGGI |
| TASK-020 | BL-28 | Tambah principal `kind: 'viewer'` yang menolak semua izin tulis; buka database viewer read-only bila platform mendukung; validasi service | `session_service.dart`, `pin_gate.dart`, `app_database.dart`, `access_control.dart` | Mode viewer benar-benar hanya baca | TASK-010 | RENDAH |
| TASK-021 | BL-06 | Periksa `aktif` pada `_deviceAuth`/`_employeeCanSend`, cabut perangkat saat akun dinonaktifkan, cek ulang saat unlock lokal | `relay/lib/server.dart`, `pin_gate.dart`, `employee_auth_service.dart` | Akun nonaktif tidak dapat menulis/membuka sesi | TASK-010 | TINGGI |
| TASK-022 | BL-10 | Kirim semua akun termasuk `aktif:false`, push otomatis setelah perubahan, hormati `permission_version` | `premium_screen.dart`, `account_service.dart`, `relay/lib/server.dart` | Relay dan perangkat memiliki status akun yang sama | TASK-021 | SEDANG |
| TASK-023 | BL-11 | Kirim role/izin/toko/username (tanpa kredensial) dalam envelope karyawan dengan HLC dan validasi owner; penerima memperbarui seluruh field | `sync_service.dart`, `sync_conflict_rules.dart`, `account_service.dart` | Perubahan peran/izin tersebar antarperangkat | TASK-010, TASK-022 | SEDANG |
| TASK-024 | BL-07 | Sertakan akun karyawan tanpa kredensial dalam snapshot, buat akun lokal saat login karyawan, salin akun saat membuat toko | `snapshot_sync.dart`, `snapshot_platform_io.dart`, `employee_auth_service.dart`, `store_service.dart` | Perangkat baru mengenali karyawan dan komisi tidak menjadi nol | TASK-010 | TINGGI |

**Kriteria keluar fase:** tidak ada `actor == null` yang menjadi owner; izin retur/estimasi/order/follow-up sesuai pengaturan; akun nonaktif ditolak di relay dan lokal; perpindahan toko memuat ulang izin; snapshot membawa akun.

---

### FASE 3 — TRANSAKSI, KEUANGAN, INVENTORI, DAN KONFLIK DATA

**Tujuan:** memperbaiki aritmetika dan aturan penerapan transaksi agar uang, stok, retur, komisi, dan gaji tidak dapat digandakan atau ditimpa diam-diam.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-025 | BL-13 | Tambah `request_id` stabil untuk retur dan pelunasan dari UI; unique constraint; tombol busy; retry memakai kunci yang sama | `sale_return_service.dart`, `history_screen.dart`, `app_database.dart`, `schema.dart` | Ketukan ganda/retry tidak menggandakan transaksi | TASK-005, TASK-009 | SEDANG |
| TASK-026 | BL-14 | Hitung ulang total dibayar/sisa dari seluruh pembayaran setelah apply; tolak/konflik bila melebihi total efektif; kunci idempoten | `app_database.dart`, `note_sync.dart`, `sync_service.dart` | Piutang tidak negatif dan kas tidak tercatat ganda | TASK-005 | SEDANG |
| TASK-027 | BL-03 | Periksa siklus gaji secara global; pembayaran kedua menjadi konflik `gaji_ganda`, bukan menimpa baris; jejak kas | `employee_service.dart`, `sync_service.dart`, `employees_screen.dart` | Satu siklus tidak dibayar dua kali tanpa peringatan | TASK-008 | TINGGI |
| TASK-028 | BL-02 | Penerima retur: tolak retur pada nota VOID, batasi per baris terhadap jumlah terjual dikurangi retur sebelumnya, idempoten, catat konflik | `note_sync.dart`, `sale_return_service.dart`, `sync_service.dart` | Stok/refund tidak berlipat; VOID terminal | TASK-009, TASK-025 | KRITIS |
| TASK-029 | BL-34 | Void menandai komisi VOID, menghitung ulang pembayaran/refund, dan menampilkan status konsisten | `app_database.dart`, `note_sync.dart`, laporan komisi | Tidak ada komisi yatim pada nota VOID | TASK-006 | RENDAH |
| TASK-030 | BL-15 | Jadikan void self-contained: terapkan refund/rekalkulasi total di cabang void secara idempoten; payment envelope tetap cadangan | `note_sync.dart`, `sync_service.dart`, `app_database.dart` | Penerima void langsung konsisten meski amplop payment tertunda | TASK-026 | SEDANG |
| TASK-031 | BL-01 | Kirim opname absolut (`opname_absolut_milli`) + HLC; penerima menetapkan nilai absolut, bukan menjumlahkan delta; movement mencatat selisih | `app_database.dart`, `sync_service.dart`, `schema.dart` | Opname dua perangkat mengarah ke angka fisik yang sama; kebijakan tahan-sinkron dilanjutkan di TASK-064 | TASK-007 | KRITIS |
| TASK-032 | BL-21 | Cegah stok negatif saat finalisasi atau tandai konflik yang membatalkan penjualan kedua; reservasi/aturan relay bila online | `app_database.dart`, `sync_service.dart`, `relay/lib/server.dart` | Barang terakhir tidak terjual dua kali; pembatalan penjualan kedua mengikuti BD-13 di TASK-033 | TASK-007, TASK-033 | SEDANG |
| TASK-033 | BL-24, BD-13 | Terapkan kebijakan BD-13: batalkan otomatis penjualan yang tiba belakangan dan membuat stok negatif; penjualan batal tidak boleh mengurangi stok, menambah piutang/kas, atau memberi komisi; simpan jejak nota dan konflik | `app_database.dart`, `stock_screen.dart`, `sync_service.dart`, `note_sync.dart` | Perilaku stok negatif konsisten; penjualan kedua tidak diterapkan diam-diam | TASK-007 | SEDANG |
| TASK-034 | BL-04 | Simpan snapshot tarif komisi saat nota dibuat; rekalkulasi memakai snapshot; akun hilang mempertahankan nominal lama + konflik | `app_database.dart`, `schema.dart`, `models.dart` | Komisi tidak berubah surut | TASK-006 | TINGGI |
| TASK-035 | BL-40 | Penerima retur memanggil rekalkulasi komisi berbasis snapshot secara idempoten | `note_sync.dart`, `app_database.dart` | Komisi penerima sama dengan perangkat asal | TASK-034 | RENDAH |
| TASK-036 | BL-41 | Tangkap pelanggaran `UNIQUE(kode)` saat apply; catat konflik `kode_bentrok`; jangan menahan amplop independen; opsi gabung/renumber | `sync_service.dart`, `sync_conflict_rules.dart`, `app_database.dart` | Satu kode bentrok tidak menghentikan seluruh sinkronisasi | TASK-002, TASK-011 | SEDANG |
| TASK-037 | BL-16 | Merge pelanggan memindahkan `service_records.customer_id` (termasuk unit NULL), unit, follow-up, WA, lalu enqueue semua perubahan | `app_database.dart`, `customer` service/UI | Riwayat pelanggan tujuan lengkap | TASK-002 | SEDANG |
| TASK-038 | BL-33 | Perkuat kode perangkat (lebih panjang/acak) dan sertakan counter dokumen dalam snapshot; nomor internal berbasis ULID | `app_database.dart`, `snapshot_sync.dart`, `schema.dart` | Nomor dokumen tidak bentrok antardevice | TASK-011 | RENDAH |
| TASK-064 | BL-01, BD-03 | Tahan opname sampai semua perangkat aktif yang terakhir sinkron sebelum waktu opname sudah mengirim data; tandai opname menunggu, beri peringatan perangkat offline 24 jam, terapkan opname sementara + catatan setelah 7 hari, lalu rekonsiliasi otomatis saat perangkat kembali | `app_database.dart`, `sync_service.dart`, `stock_screen.dart`, `relay/lib/server.dart` | Opname tidak mendahului data yang belum masuk; pemilik melihat perangkat tertinggal dan hasil rekonsiliasi | TASK-031 | SEDANG |

**Kriteria keluar fase:** retur/void/pelunasan/gaji/opname memiliki validasi penerima dan idempotensi; opname menunggu sinkron sesuai BD-03; penjualan kedua yang membuat stok negatif dibatalkan otomatis sesuai BD-13; stok dan kas dapat direkonsiliasi; komisi memakai snapshot; konflik tidak menahan antrean.

---

### FASE 4 — PERHITUNGAN, TAMPILAN, DAN LAPORAN

**Tujuan:** memastikan dashboard, riwayat, struk, laporan, dan rekonsiliasi memakai definisi angka yang sama.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-039 | BL-05 | Gunakan `total_efektif` di `listRecords`, `recordDetail`, struk, dashboard, laporan; alokasikan koreksi per baris | `app_database.dart`, `receipt_service.dart`, `models.dart`, layar terkait | Satu nota menunjukkan total sama di semua layar | TASK-003 | TINGGI |
| TASK-040 | BL-17 | Join pelanggan memakai `COALESCE(service_records.customer_id, unit.customer_id)` di daftar/detail/pencarian | `app_database.dart` | Nota tanpa unit menampilkan pelanggan | TASK-002 | SEDANG |
| TASK-041 | BL-18 | Struk mencetak total efektif, koreksi, retur; kembalian dari kas yang benar-benar diterima | `receipt_service.dart`, `receipt_template.dart` | Struk sesuai state efektif | TASK-039 | SEDANG |
| TASK-042 | BL-39 | Tampilkan kembalian per pembayaran tunai (awal, pelunasan, refund) atau hentikan cetak ulang yang menyesatkan | `receipt_service.dart` | Bukti kas jelas | TASK-005 | RENDAH |
| TASK-043 | BL-19 | Definisikan dan tampilkan omzet bruto, neto retur, dan kas diterima; samakan dengan laporan | `app_database.dart`, `dashboard_screen.dart`, `reports_screen.dart` | Dashboard tidak menyesatkan | TASK-039 | SEDANG |
| TASK-044 | BL-23 | Digest rekonsiliasi memuat hash nilai efektif, total retur, pembayaran, dan status void | `reconciliation_service.dart`, `day_digests` | Divergensi keuangan terdeteksi | TASK-039 | SEDANG |
| TASK-045 | BL-25 | Penanda jatuh tempo memakai `sisa_bayar`/total efektif | `models.dart`, `history_screen.dart` | Badge piutang akurat | TASK-039 | RENDAH |
| TASK-046 | BL-26 | Tambah `deleted_at IS NULL` pada semua query stok, cek kode, validasi jual, dashboard; jangan revive saat edit | `app_database.dart`, `stock_screen.dart` | Baris terhapus tidak aktif | TASK-002 | RENDAH |
| TASK-047 | BL-30 | Lempar `RetryableSyncException` bila nota belum ada; catat konflik bila nota void; jangan tandai selesai | `nota_adjustment_service.dart`, `sync_service.dart` | Koreksi tidak hilang diam-diam | TASK-011 | RENDAH |
| TASK-048 | BL-38 | Soft-delete relasi supplier dengan tombstone yang disinkronkan atau penggantian penuh dari payload | `supplier_service.dart`, `sync_service.dart` | Relasi supplier konsisten | TASK-002 | RENDAH |

**Kriteria keluar fase:** total nota, laporan, dashboard, struk, piutang, dan rekonsiliasi memakai definisi yang sama dan dapat direkonsiliasi.

---

### FASE 5 — SINKRONISASI DUA ARAH DAN KONFLIK MULTI-PERANGKAT

**Tujuan:** menutup sisa divergensi antarperangkat, memastikan amplop diterapkan tepat sekali, dan konflik tidak memblokir data independen.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-049 | BL-01, BL-02, BL-15, BL-30, BL-41 | Terapkan kontrak amplop baru: urutan aman, idempotensi `applied_deltas`, konflik terpisah, cursor tidak menahan amplop independen | `sync_service.dart`, `sync_conflict_rules.dart`, `relay/lib/sync_round.dart`, `relay/lib/server.dart` | Sinkronisasi tidak berhenti karena satu konflik | TASK-011, TASK-028, TASK-030, TASK-036 | KRITIS |
| TASK-050 | BL-11, BL-24 | Penerima memvalidasi ulang izin/role pengirim, status akun, dan aturan stok sebelum apply | `sync_service.dart`, `sync_conflict_rules.dart`, `relay/lib/server.dart` | Perubahan tidak sah ditolak di penerima | TASK-023, TASK-033 | TINGGI |
| TASK-051 | BL-03, BL-14 | Konflik gaji/pelunasan lintas perangkat dicatat dan ditinjau, bukan ditimpa; UI konflik menampilkan detail | `sync_service.dart`, `sync_conflicts_screen.dart`, `employee_service.dart` | Uang ganda terlihat dan dapat diselesaikan | TASK-027, TASK-026 | TINGGI |
| TASK-052 | BL-07 | Snapshot/bootstrap membawa akun, counter dokumen, dan status perangkat dengan aman | `snapshot_sync.dart`, `snapshot_platform_io.dart`, `backup_service.dart` | Perangkat hasil restore/bootstrap lengkap | TASK-024, TASK-038 | TINGGI |
| TASK-053 | BL-29, BL-35 | Relay mengembalikan waktu server dan status lisensi; perangkat menyimpan waktu terakhir terlihat | `relay/lib/server.dart`, `license_verifier.dart`, `sync_service.dart` | Lisensi tidak dapat diperpanjang dengan jam mundur | TASK-021 | RENDAH |

**Kriteria keluar fase:** dua perangkat dengan transaksi bersamaan konvergen atau menghasilkan konflik eksplisit; tidak ada amplop independen yang tertahan; akun/izin konsisten.

---

### FASE 6 — BACKUP, RESTORE, KEAMANAN, DAN KETAHANAN PROSES

**Tujuan:** menjadikan backup/restore sebagai jaring pengaman yang benar-benar dapat dipulihkan dan tidak membocorkan kunci.

| ID | Temuan | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|---|
| TASK-054 | BL-42 | Ganti `replaceDatabase` dengan pertukaran atomik (rename lama → `.old`, rename baru → aktif, verifikasi, hapus `.old`), fsync, dan pemulihan startup dari `.bak`/`.restore.tmp` | `backup_platform_io.dart`, `backup_service.dart`, `main.dart`/startup | Restore terhenti dapat dipulihkan otomatis | — | TINGGI |
| TASK-055 | BL-20 | Batas agregat dekompresi restore, cek ruang disk, staging directory, verifikasi sebelum mengganti | `backup_service.dart`, `backup_platform_io.dart` | Restore multi-toko tidak memenuhi disk | TASK-054 | SEDANG |
| TASK-056 | BL-22 | Jangan tampilkan passphrase; gunakan aksi salin dengan konfirmasi PIN/owner atau tampilkan sekali | `settings_screen.dart`, `backup_service.dart` | Passphrase tidak terbaca dari layar | — | SEDANG |
| TASK-057 | BL-32 | Checkpoint/buka sementara toko nonaktif sebelum dibaca pada semua platform | `backup_service.dart`, `app_database.dart` | Backup toko nonaktif lengkap | TASK-054 | RENDAH |
| TASK-058 | BL-29 | Gunakan `server_time` tepercaya dan simpan `last_seen_server_time`; tolak mundur waktu tidak wajar | `license_verifier.dart`, `relay/lib/server.dart`, `schema.dart` | Lisensi memakai waktu tepercaya | TASK-053 | RENDAH |
| TASK-059 | BL-35 | Periksa lisensi owner pada `_deviceAuth` atau batasi endpoint premium | `relay/lib/server.dart`, `relay/lib/license.dart` | Token kedaluwarsa tidak dapat sinkronisasi premium | TASK-021 | RENDAH |

**Kriteria keluar fase:** restore tidak kehilangan database pada titik henti mana pun; backup nonaktif lengkap; passphrase tidak tampil; lisensi memakai waktu tepercaya.

---

### MODUL PEMBELIAN DAN UTANG SUPPLIER (BD-12)

**Tujuan:** menambah pembelian bernilai dan utang supplier sebagai modul baru di luar 42 temuan audit. Seluruh tugas modul ini wajib selesai sebelum TASK-061.

| ID | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|
| TASK-065 | Skema pembelian: `supplier_purchases`, `supplier_purchase_items`, `supplier_payments`; nomor pembelian unik per toko, status, jatuh tempo, total/sisa, snapshot supplier/barang, HLC, soft-delete; indeks/constraint; selaraskan skema PostgreSQL relay dan daftar tabel snapshot/backup | `schema.dart`, `relay/lib/db.dart`, `snapshot_sync.dart` | Tabel pembelian/utang konsisten di SQLite, relay, dan snapshot | TASK-001, TASK-002, TASK-005 | TINGGI |
| TASK-066 | Izin dan aktor: `lihat_pembelian`, `buat_pembelian`, `bayar_utang`; operator wajib; **tidak semua role** — default hanya pemilik, izin diberikan eksplisit per peran; viewer, kasir, dan mekanik tidak otomatis; pemetaan peran relay; menu dan aksi hanya muncul bila berizin **dan** `purchase_debt` aktif | `permissions.dart`, `access_control.dart`, `store_settings.dart`, `relay/lib/auth_rules.dart`, `home_shell.dart` | Hanya peran berizin yang dapat melihat/membuat/membayar pembelian; akses default pemilik | TASK-010, TASK-013 | TINGGI |
| TASK-067 | Service pembelian: buat nota + baris, stok masuk lewat ledger bersumber pembelian, total dari baris (diskon/ongkir dialokasikan ke harga pokok, PPN dicatat terpisah), tunai/kredit/DP, sumber dana kas/transfer, jatuh tempo, utang awal, audit, idempoten `request_id`, tolak penulisan baru bila `purchase_debt` nonaktif | `purchase_service.dart` (baru), `app_database.dart`, `models.dart`, `supplier_service.dart` | Pembelian menambah stok dan utang secara atomik dan dapat diaudit | TASK-065, TASK-066, TASK-007 | TINGGI |
| TASK-068 | Pembayaran utang supplier: `request_id` unik, tidak boleh melebihi sisa, rekalkulasi sisa dari ledger pembayaran, kas keluar tunai/transfer, konflik, larangan VOID bila sudah ada pembayaran, stok tidak cukup untuk dikembalikan, atau barang sudah terjual; sisa stok diselesaikan lewat retur pembelian; pembayaran baru ditolak bila `purchase_debt` nonaktif | `purchase_service.dart`, `app_database.dart` | Utang tidak negatif; pembayaran tidak ganda; VOID aman | TASK-067, TASK-005 | TINGGI |
| TASK-069 | UI pembelian: daftar nota pembelian, form barang/qty/modal, status tunai/kredit, daftar utang + jatuh tempo, dialog pembayaran, laporan pembelian/kas keluar/utang, aksi sesuai izin; isi tab "Pembelian & Utang" di hub Supplier & Reseller, bukan menu terpisah | `supplier_screen.dart`, `purchases_screen.dart` (baru), `home_shell.dart`, `reports_screen.dart`, `models.dart` | Pemilik/karyawan berizin dapat mengelola pembelian dan utang dari aplikasi | TASK-067, TASK-068 | SEDANG |
| TASK-070 | Sinkronisasi pembelian: amplop `supplier_purchase`, `supplier_purchase_item`, `supplier_payment`; idempoten, validasi izin/akun, ledger stok/kas, rekalkulasi utang, konflik nomor ganda/pembayaran berlebih/VOID setelah bayar; ikut snapshot; penerima tetap menerima data lama saat `purchase_debt` nonaktif, tetapi menolak data baru setelah flag berlaku | `sync_service.dart`, `sync_conflict_rules.dart`, `sync_conflicts_screen.dart`, `snapshot_sync.dart`, `relay/lib/server.dart` | Pembelian/utang konvergen antarperangkat tanpa penggandaan | TASK-065, TASK-067, TASK-068, TASK-049 | TINGGI |
| TASK-071 | Backup/restore: tabel pembelian/utang menjadi tabel wajib termasuk saat `purchase_debt` nonaktif; verifikasi restore; tolak salinan tanpa tabel tersebut | `backup_service.dart`, `snapshot_sync.dart` | Pembelian dan utang ikut backup/restore/snapshot | TASK-065, TASK-052, TASK-054 | SEDANG |

**Kriteria keluar modul:** nota pembelian menambah stok dan utang secara atomik; pembayaran utang idempoten dan tidak melebihi sisa; hanya peran berizin yang dapat melihat/membuat/membayar; sinkronisasi dan backup membawa seluruh data pembelian; pengujian modul masuk TASK-061.

---

### MODUL TAMBAHAN — SALDO AWAL, VALUASI, RETUR PEMBELIAN, DAN KESIAPAN OPERASIONAL

**Tujuan:** menutup celah di luar 42 temuan audit dan modul pembelian awal: saldo awal toko, valuasi persediaan, retur pembelian, pengingat utang, diagnostik, operasional relay, jalur upgrade skema, dan dokumentasi operasional. TASK-072 sampai TASK-079 wajib selesai sebelum TASK-061. TASK-080 bersifat pasca-rilis dan tidak menahan TASK-061.

| ID | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|
| TASK-072 | Saldo awal toko: penanda/tabel `opening_balances` per toko; stok awal lewat ledger sumber `saldo_awal`; utang supplier awal tanpa kas keluar; piutang pelanggan awal tanpa nota palsu; satu kali per toko, dapat dikoreksi lewat opname/koreksi; audit, sinkronisasi, backup | `schema.dart`, `opening_balance_service.dart` (baru), `app_database.dart`, `models.dart`, `stock_screen.dart`, `purchases_screen.dart`, `snapshot_sync.dart`, `backup_service.dart` | Laporan stok/utang/piutang hari pertama cocok dengan kenyataan tanpa transaksi palsu | TASK-002, TASK-003, TASK-007, TASK-065 | TINGGI |
| TASK-073 | Valuasi HPP rata-rata bergerak per toko/barang: hitung ulang saat pembelian, retur pembelian, void, dan saldo awal; snapshot harga modal per baris tetap; laporan HPP dan margin per barang; konflik bila data modal tidak cukup | `schema.dart`, `app_database.dart`, `purchase_service.dart`, `models.dart`, `reports_screen.dart` | HPP dan margin konsisten serta dapat diaudit | TASK-004, TASK-067, TASK-072 | TINGGI |
| TASK-074 | Retur pembelian: nota retur + baris, batas qty per nota, kurangi stok lewat ledger dan utang/kas, idempoten, aturan VOID, sinkronisasi, backup, laporan | `schema.dart`, `purchase_service.dart`, `sync_service.dart`, `snapshot_sync.dart`, `purchases_screen.dart`, `reports_screen.dart` | Barang rusak dapat dikembalikan tanpa merusak stok, utang, dan kas | TASK-067, TASK-068, TASK-073 | TINGGI |
| TASK-075 | Aging utang supplier dan pengingat jatuh tempo: bucket 0–30/31–60/61–90/>90 hari, rekap per supplier, notifikasi lokal H-3 dan saat lewat jatuh tempo tanpa push server, akses mengikuti izin `lihat_pembelian` | `purchases_screen.dart`, layanan notifikasi lokal (baru), `reports_screen.dart` | Utang yang jatuh tempo terlihat dan diingatkan tanpa infrastruktur tambahan | TASK-069 | SEDANG |
| TASK-076 | Diagnostik perangkat: ekspor log aplikasi/sinkronisasi/relay terakhir, `PRAGMA integrity_check`, ukuran database/WAL/outbox/inbox/backup, redaksi kredensial/token/passphrase/data pribadi, berbagi berkas | `diagnostics_service.dart` (baru), `settings_screen.dart`, `app_database.dart` | Masalah pengguna dapat ditelusuri tanpa membocorkan rahasia | TASK-060 | SEDANG |
| TASK-077 | Operasional relay: health endpoint, backup PostgreSQL + uji restore, retensi `applied_deltas`/envelope/konflik, monitoring error/uptime, TLS, rotasi token/kunci, rate limit | `relay/lib/server.dart`, `relay/lib/db.dart`, dokumen operasional relay | Relay dapat dipulihkan, dipantau, dan tidak membengkak | TASK-011, TASK-049, TASK-053 | SEDANG |
| TASK-078 | Kebijakan upgrade skema pasca-rilis: migrasi berversi dari skema v1, backup otomatis sebelum migrasi, rollback, penolakan database versi lebih baru, uji migrasi | `schema.dart`, `app_database.dart`, `backup_service.dart` | Versi rilis berikutnya dapat meningkatkan skema tanpa kehilangan data | TASK-001 | SEDANG |
| TASK-079 | Dokumentasi operasional: SOP owner/admin, panduan backup/restore dan disaster recovery, panduan penyelesaian konflik, kebijakan privasi/retensi, panduan singkat per peran | dokumen operasional (baru) | Pemilik dan admin dapat menjalankan toko tanpa pendampingan langsung | TASK-060, TASK-072..078 | SEDANG |
| TASK-080 | CI/CD otomatis pasca-rilis: analyze + test + build otomatis setelah larangan pengujian dicabut, artefak bertanda tangan, tidak menahan TASK-061 | `.github/workflows` atau setara, `pusatkupos`, `relay` | Rilis berikutnya dapat diverifikasi otomatis | TASK-062 | RENDAH |

**Kriteria keluar modul tambahan:** saldo awal, HPP, retur pembelian, aging/pengingat utang, diagnostik, operasional relay, dan dokumentasi tersedia; seluruh data baru ikut sinkronisasi dan backup; TASK-080 boleh menyusul setelah rilis.

---

### FITUR OPSIONAL PER TOKO (BD-26)

**Tujuan:** pemilik dapat menyesuaikan modul yang dipakai tiap toko tanpa menghapus data atau bercabang kode. Contoh: bengkel yang tidak memakai estimasi dan antrian dapat mematikan keduanya; toko lain tetap memakainya.

**Katalog awal:**

| Fitur | Default | Boleh dimatikan? | Ketergantungan |
|---|---|---|---|
| Kasir/nota, stok, pelanggan, pembayaran/piutang, retur/void, laporan, backup/restore, akun/akses, sinkronisasi, lisensi, pengaturan | ON | Tidak (wajib) | — |
| Estimasi | ON | Ya | — |
| Antrian/order kerja | ON | Ya | — |
| Supplier + Follow Up Reseller (`supplier_hub`) | ON | Ya | Menjadi induk pembelian/utang |
| Pembelian & Utang Supplier (`purchase_debt`) | ON | Ya | Sub-fitur `supplier_hub`; membutuhkan `supplier_hub`; retur pembelian membutuhkan pembelian |
| Follow-up | ON | Ya | — |
| Unit/kendaraan | ON | Ya | — |
| WhatsApp | ON | Ya | — |
| Komisi dan gaji | ON | Tidak pada iterasi ini | Terkait kas/laporan; perlu keputusan terpisah |

**Aturan:** flag per toko, bukan per owner; hanya pemilik penuh yang dapat mengubah (viewer read-only, karyawan ditolak); semua fitur opsional default ON; menonaktifkan tidak menghapus data dan data lama tetap terlihat di riwayat/laporan serta ikut backup; fitur nonaktif berlaku untuk semua peran dan tidak dapat dihidupkan oleh izin peran; perangkat yang belum menerima flag tetap dapat mengirim data lama dan penerima menyimpannya, tetapi pembuatan data baru ditolak setelah flag diterapkan; perubahan flag dicatat dalam audit dan disinkronkan dengan versi/HLC.

**Aturan fitur induk dan sub-fitur:** `supplier_hub` adalah induk yang menaungi Supplier, Follow Up Reseller, dan tab Pembelian & Utang dalam satu layar; `purchase_debt` adalah sub-fitur yang hanya efektif bila `supplier_hub` aktif. Mematikan `supplier_hub` menyembunyikan seluruh hub (ketiga tab), menonaktifkan `purchase_debt` secara efektif, tetapi menyimpan nilai pilihannya sehingga kembali seperti semula saat induk dinyalakan lagi. Menyalakan `purchase_debt` saat induk mati ditolak dengan pesan ketergantungan. Izin `lihat_supplier`, `lihat_followup`, `lihat_pembelian`, `buat_pembelian`, dan `bayar_utang` tidak dapat menghidupkan fitur yang dimatikan pemilik; izin hanya membatasi di dalam fitur yang aktif.

| ID | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|
| TASK-081 | Skema dan sinkronisasi fitur opsional: tabel `store_features` per toko (feature_key, enabled, versi/HLC, updated_by), default katalog, audit perubahan, kontrak relay, snapshot/backup | `schema.dart`, `app_database.dart`, `relay/lib/db.dart`, `snapshot_sync.dart`, `backup_service.dart` | Flag fitur konsisten di SQLite, relay, snapshot, dan backup | TASK-001, TASK-011, TASK-052 | TINGGI |
| TASK-082 | Layanan pusat `FeatureFlags`: `isEnabled`/`requireEnabled`, validasi ketergantungan, penegakan di service dan UI, owner-only, viewer read-only, penerimaan data lama saat fitur nonaktif, audit/konflik | `feature_flags_service.dart` (baru), `app_database.dart`, `access_control.dart`, `home_shell.dart`, `sync_service.dart`, `relay/lib/server.dart` | Fitur nonaktif tidak dapat dipakai untuk data baru; data lama tidak hilang | TASK-081, TASK-010, TASK-013 | TINGGI |
| TASK-083 | UI Fitur Toko dan penerapan ke modul opsional: layar pengaturan owner, switch, konfirmasi dampak, fitur wajib terkunci, pesan ketergantungan, audit; sembunyikan menu/aksi estimasi, antrian/order kerja, supplier, pembelian/utang, follow-up, unit/kendaraan, WhatsApp; riwayat/laporan data lama tetap terbuka; tawaran pilihan saat membuat toko | `store_features_screen.dart` (baru), `settings_screen.dart`, `home_shell.dart`, layar modul terkait, `store_service.dart` | Pemilik dapat menyalakan/mematikan fitur per toko tanpa kehilangan data | TASK-082, TASK-069 | SEDANG |
| TASK-084 | Integrasi hub Supplier & Reseller: satu layar bertab Supplier, Follow Up Reseller, dan Pembelian & Utang; ganti setting lokal `fitur.supplier` dengan flag `supplier_hub`/`purchase_debt`; kunci premium tetap berlaku; menu/route/tombol mengikuti flag dan izin; penegakan di service, sinkronisasi penerima, dan relay; data lama tetap tampil; hapus dead code setting lama | `supplier_screen.dart`, `settings_screen.dart`, `stock_screen.dart`, `home_shell.dart`, `feature_flags_service.dart`, `supplier_service.dart`, `purchase_service.dart`, `sync_service.dart`, `relay/lib/server.dart` | Satu hub dengan toggle nyata: modul nonaktif benar-benar tidak bisa dipakai untuk data baru dan data lama tetap utuh | TASK-083, TASK-065..071, TASK-020 | TINGGI |

**Kriteria keluar fitur opsional:** flag per toko tersimpan, tersinkron, dan ikut backup; fitur wajib tidak dapat dimatikan; fitur nonaktif menyembunyikan menu/aksi dan menolak data baru; data lama tetap tersedia; hanya pemilik penuh yang dapat mengubah; hub Supplier & Reseller menjadi satu pintu dengan tiga tab dan toggle yang benar-benar menegakkan batas; pengujian toggle masuk TASK-061.

---

### MODUL PPN / PAJAK PENJUALAN (BD-28)

**Tujuan:** pemilik dapat menyalakan atau mematikan PPN per toko, mengisi tarif, dan memilih siapa yang menanggung PPN — pembeli atau bengkel. PPN tampil di struk dan disimpan sebagai snapshot pada nota sehingga nota lama tidak berubah ketika pengaturan diubah.

**Aturan yang sudah diputuskan:**

- Saklar PPN disimpan di `store_settings` per toko, default **OFF**. Hanya pemilik penuh yang dapat mengubah; viewer dan karyawan read-only.
- Tarif diisi pemilik saat mengaktifkan (persen dengan dua desimal, disimpan sebagai basis poin 0–10000). Aplikasi tidak mengisi tarif legal secara otomatis.
- Penanggung: `PEMBELI` menambahkan PPN ke tagihan pelanggan; `BENGKEL` menyerap PPN sehingga total pelanggan tidak berubah, tetapi PPN tetap dicetak sebagai informasi.
- Dasar pengenaan pajak (DPP) = biaya jasa + total part - diskon, memakai nilai setelah alokasi diskon. PPN pembelian (BD-16) tetap terpisah dan tidak dihitung ulang oleh fitur ini.
- Berlaku untuk nota penjualan `jual_sparepart`, `servis_langsung`, dan `order_kerja`. Nota `pelunasan_order` tidak menghitung ulang PPN. Estimasi belum menagih PPN sampai BD-30 diputuskan.
- `pajak` dan `pajak_snapshot_json` dibekukan saat nota dibuat. Snapshot memuat tarif, DPP, nominal, penanggung, dan mode perhitungan; cetak ulang selalu memakai snapshot, bukan pengaturan terbaru.
- PPN bukan pendapatan: omzet memakai DPP, kas/piutang memakai total yang benar-benar ditagih, dan komisi memakai DPP.
- Retur membalik PPN secara proporsional; VOID penuh membalik seluruh PPN yang sudah ditagih. VOID tetap terminal.
- Perangkat offline memakai konfigurasi terakhir yang diketahui. Penerima sinkronisasi menerima snapshot PPN dari perangkat lama apa pun status saklar saat ini; nota tanpa snapshot PPN saat nominal pajak > 0 dicatat sebagai konflik untuk ditinjau.
- PPN tidak dijadikan flag `store_features` karena membutuhkan tarif dan penanggung; saklar, tarif, dan penanggung disimpan di `store_settings` agar menjadi satu sumber kebenaran yang sudah tersinkron dan diaudit.

**Keputusan terbuka:** BD-29 (harga inklusif/eksklusif) dan BD-30 (perlakuan akuntansi PPN ditanggung bengkel serta rekap pajak). Implementasi sementara memakai default konservatif yang tercatat pada tabel keputusan.

| ID | Uraian | Berkas/modul | Hasil | Ketergantungan | Prioritas |
|---|---|---|---|---|---|
| TASK-085 | Konfigurasi dan sinkronisasi PPN per toko: kolom `store_settings` (`pajak_aktif`, `pajak_persen_bp`, `pajak_penanggung`, `pajak_inklusif`), default OFF, validasi tarif 0–10000 bp dan penanggung `PEMBELI`/`BENGKEL`, pemetaan `StoreSettings`, `modeSnapshot`, `toPayload`, `applyRemote`, HLC, audit owner-only, backup/snapshot; `pajak_inklusif` default 0 dan belum diekspos di UI sampai BD-29 diputuskan | `schema.dart`, `store_settings.dart`, `app_database.dart`, `backup_service.dart`, `sync/snapshot_sync.dart` | Konfigurasi PPN tersimpan per toko, tersinkron, diaudit, dan ikut backup | TASK-003, TASK-011, TASK-039 | TINGGI |
| TASK-086 | Perhitungan dan snapshot PPN: hitung DPP/PPN saat nota dibuat, bedakan `PEMBELI`/`BENGKEL`, isi `pajak` + `pajak_snapshot_json`, sesuaikan total/piutang/kas, komisi memakai DPP, retur/void proporsional, penerima sinkronisasi menyalin `pajak` dan snapshot, konflik snapshot hilang, nota lama tidak berubah | `app_database.dart`, `note_sync.dart`, `sync/sync_service.dart`, `sale_return_service.dart`, `receipt_service.dart`, `models.dart` | PPN dihitung benar, tidak menggandakan uang, dan konsisten antar perangkat | TASK-085, TASK-028, TASK-033, TASK-039 | TINGGI |
| TASK-087 | UI dan struk PPN: layar pengaturan owner (saklar, tarif, penanggung, konfirmasi, contoh hitung), ringkasan kasir (DPP/PPN/total), baris PPN di struk cetak/share/WhatsApp, keterangan "ditanggung bengkel" bila diserap, detail riwayat memakai snapshot, PPN disembunyikan saat nonaktif, nota lama tetap tampil apa adanya | `settings_screen.dart`, `pos_screen.dart`, `receipt_template.dart`, `receipt_service.dart`, `receipt_dialog.dart`, `history_screen.dart` | Pemilik dapat menyalakan/mematikan PPN dan hasilnya terlihat benar di layar serta struk | TASK-085, TASK-086, TASK-041, TASK-042 | SEDANG |

**Kriteria keluar PPN:** saklar per toko tersimpan, tersinkron, dan ikut backup; tarif serta penanggung hanya dapat diubah pemilik; PPN pembeli menambah tagihan sedangkan PPN bengkel tidak mengubah total pelanggan; struk menampilkan PPN beserta penanggungnya; nota lama tetap memakai snapshot-nya; retur/void/piutang/kas/komisi konsisten; fitur nonaktif tidak menampilkan PPN dan tidak menghitung pajak baru; analisis statis bersih setelah TASK-087; pengujian PPN masuk TASK-061.

---

### FASE 7 — VERIFIKASI STATIS, PENGUJIAN AKHIR, DAN LAPORAN

| ID | Uraian | Berkas | Hasil | Ketergantungan |
|---|---|---|---|---|
| TASK-060 | Sapu konsistensi statis: semua pemanggil, query, kolom, dan tipe setelah perubahan skema; dijalankan ulang setelah TASK-087 | seluruh `pusatkupos/lib`, `relay/lib` | Tidak ada referensi mati/kolom hilang | Semua fase, modul pembelian, modul tambahan, fitur opsional, dan modul PPN |
| TASK-061 | Jalankan pengujian akhir sesuai teknologi repo (setelah seluruh implementasi selesai): matriks UAT per peran dan perangkat; test suite, SQLite, PostgreSQL relay, offline/online, offline 7 hari, sinkronisasi dua arah, konflik dua perangkat, relay mati, restore gagal di tiap tahap, lisensi kedaluwarsa, retur/void/stok/payroll/pembayaran/laporan, pembelian/utang supplier, saldo awal, HPP, retur pembelian, aging/pengingat, backup/restore, toggle fitur per toko (dua perangkat, offline, data lama, re-enable), toggle `supplier_hub`/`purchase_debt` pada hub Supplier & Reseller (induk mati, sub-fitur tertahan, data lama, perangkat telat sinkron), PPN per toko (aktif/nonaktif, tarif berubah di tengah periode, `PEMBELI` vs `BENGKEL`, struk cetak/share/WhatsApp, retur/void, piutang/kas/komisi, dua perangkat, perangkat offline, nota lama tetap memakai snapshot, backup/restore), serta data besar/performa | `pusatkupos`, `relay` | Seluruh pengujian lulus atau tercatat dengan bukti | TASK-060, TASK-065..079, TASK-081..087 |
| TASK-062 | Kesiapan rilis dan build APK: keystore/signing, versionCode/versionName, checklist rilis, rollback, distribusi (sideload/Play Store), build APK dan verifikasi akhir | `pusatkupos/android`, `pusatkupos` | APK bertanda tangan, dapat dipasang, dan memiliki jalur rollback | TASK-061 |
| TASK-063 | Tulis `IMPLEMENTATION_FINAL_REPORT.md` termasuk hasil pengujian, batasan yang diketahui, dan keputusan yang masih terbuka | root | Laporan akhir lengkap dan jujur | TASK-061, TASK-062 |

> TASK-061 sampai TASK-063 **tidak boleh dimulai** sebelum seluruh tugas FASE 1–6, modul pembelian TASK-065–071, modul tambahan TASK-072–079, fitur opsional TASK-081–084, dan modul PPN TASK-085–087 berstatus selesai. TASK-080 bersifat pasca-rilis dan tidak menahan TASK-061.

---

## 4. Ketergantungan utama

```text
TASK-001 (skema bersih)
  ├─ TASK-002 (master) ─ TASK-007 (stock ledger) ─ TASK-031/032/033/064
  ├─ TASK-003 (nota) ─ TASK-004 (baris) ─ TASK-006 (komisi) ─ TASK-034/035
  │     └─ TASK-005 (pembayaran) ─ TASK-025/026/030
  ├─ TASK-008 (gaji) ─ TASK-027
  ├─ TASK-009 (retur) ─ TASK-028
  ├─ TASK-010 (akun/izin) ─ TASK-019/020/021/022/023/024
  └─ TASK-011 (sync) ─ TASK-036/047/049/050/051/052
TASK-013 (actor wajib) ─ TASK-014/017/018
TASK-039 (total efektif) ─ TASK-041/043/044/045
TASK-054 (restore atomik) ─ TASK-055/057
TASK-065 (skema pembelian) ─ TASK-067 (service pembelian) ─ TASK-068 (pembayaran utang)
TASK-010/013 ─ TASK-066 (izin pembelian) ─ TASK-067
TASK-067/068 ─ TASK-069 (UI pembelian)
TASK-065/067/068 + TASK-049 ─ TASK-070 (sync pembelian)
TASK-065 + TASK-052/054 ─ TASK-071 (backup pembelian)
TASK-002/007/065 ─ TASK-072 (saldo awal) ─ TASK-073 (HPP) ─ TASK-074 (retur pembelian)
TASK-069 ─ TASK-075 (aging/pengingat utang)
TASK-060 ─ TASK-076 (diagnostik perangkat)
TASK-011/049/053 ─ TASK-077 (operasional relay)
TASK-001 ─ TASK-078 (upgrade skema pasca-rilis)
TASK-060/072..078 ─ TASK-079 (dokumentasi operasional)
TASK-062 ─ TASK-080 (CI/CD pasca-rilis)
TASK-001/011/052 ─ TASK-081 (skema fitur opsional) ─ TASK-082 (layanan fitur) ─ TASK-083 (UI fitur)
TASK-069 ─ TASK-083
TASK-083/065..071/020 ─ TASK-084 (integrasi hub Supplier & Reseller)
TASK-003/011/039 ─ TASK-085 (konfigurasi PPN) ─ TASK-086 (perhitungan/snapshot PPN)
TASK-028/033/039 ─ TASK-086
TASK-086/041/042 ─ TASK-087 (UI dan struk PPN)
```

Tidak ada tugas yang menunggu fase berikutnya kecuali yang tercantum di atas. Modul pembelian TASK-065–071, modul tambahan TASK-072–079, fitur opsional TASK-081–084, dan modul PPN TASK-085–087 harus selesai sebelum TASK-061. TASK-080 boleh menyusul setelah rilis. Tugas tanpa ketergantungan dapat dikerjakan lebih dulu.

---

## 5. Keputusan bisnis

Keputusan pemilik per **2026-11-07** dicatat pada kolom terakhir. BD-14 sampai BD-25 adalah keputusan tambahan dari analisis celah setelah seluruh tugas kode awal tersusun; BD-26 mengatur fitur opsional per toko; BD-27 mengatur penggabungan hub Supplier & Reseller dengan on/off modul pembelian/utang; BD-28 sampai BD-30 dicatat pada **2026-11-09** untuk fitur PPN penjualan; BD-23 ditunda tanpa tugas.

| Kode | Pertanyaan | Default konservatif | Keputusan pemilik (2026-11-07) | Tugas |
|---|---|---|---|---|
| BD-01 | Apakah retur boleh melebihi qty terjual per baris (setelah retur sebelumnya)? | Tidak; total retur per baris ≤ qty terjual | **Dikonfirmasi**: tetap. Retur tidak boleh melebihi qty terjual per baris. | TASK-028 |
| BD-02 | Apakah retur pada nota VOID boleh? | Tidak; VOID terminal | **Dikonfirmasi**: tetap. Nota VOID tidak boleh diretur. | TASK-028 |
| BD-03 | Apakah opname absolut menang atas penjualan yang belum tersinkron? | Opname dengan HLC lebih baru menang; konflik dicatat | **Dipilih (b)**: opname ditahan sampai semua perangkat aktif yang terakhir sinkron sebelum waktu opname sudah mengirim data. Perangkat yang offline 24 jam diberi peringatan agar segera tersambung; setelah 7 hari opname diterapkan sebagai opname sementara dengan catatan perangkat yang belum sinkron, lalu direkonsiliasi otomatis saat perangkat kembali. | TASK-031, TASK-064 |
| BD-04 | Apakah pelunasan yang melebihi sisa menjadi saldo pelanggan atau ditolak? | Ditolak; kelebihan menjadi konflik | **Dikonfirmasi**: tetap. Kelebihan ditolak dan dicatat sebagai konflik. | TASK-026 |
| BD-05 | Apakah satu siklus gaji hanya boleh dibayar sekali secara global? | Ya; pembayaran kedua menjadi konflik | **Dikonfirmasi**: tetap. | TASK-027 |
| BD-06 | Komisi memakai tarif saat nota atau saat pembayaran? | Tarif saat nota (snapshot) | **Dikonfirmasi**: tetap. Komisi memakai tarif yang berlaku saat nota dibuat. | TASK-034 |
| BD-07 | Apakah akun karyawan ikut snapshot dan dibuat saat login? | Ya, tanpa kredensial | **Dikonfirmasi**: tetap. | TASK-024 |
| BD-08 | Apakah viewer boleh menulis ke salinan lokal? | Tidak; viewer read-only | **Dikonfirmasi dengan penegasan**: viewer dipakai pemilik untuk melihat ringkasan dan mengelola akun/akses karyawan (tambah, ubah, nonaktifkan, ubah akses) melalui mode ringkasan owner. Pembukuan (nota, stok, pembayaran, retur, gaji, pengaturan toko) tetap read-only. | TASK-020 |
| BD-09 | Definisi "pendapatan hari ini": bruto, neto retur, atau kas? | Tampilkan ketiganya dengan label jelas | **Dikonfirmasi**: tetap. | TASK-043 |
| BD-10 | Kode barang unik global per owner atau boleh renumber otomatis? | Unik per toko; konflik dicatat, tidak memblokir antrean | **Dipilih (a)**: tetap unik per toko. Barang kedua masuk dengan kode pembeda dan konflik dicatat agar pemilik menggabungkan atau mengganti kode. | TASK-036 |
| BD-11 | Apakah perubahan status follow-up boleh menghapus tanggal servis/janji bayar? | Tidak; tanggal dipertahankan kecuali status baru membutuhkan dan dikonfirmasi | **Diputuskan**: tanggal servis/janji bayar dipertahankan; perubahan status follow-up tidak menghapusnya. Tanggal hanya boleh diubah lewat aksi terpisah yang tercatat dan dikonfirmasi. | TASK-018 |
| BD-12 | Apakah ada modul pembelian bernilai/utang supplier? | Tidak ada; tidak ada tugas pembelian baru | **Diputuskan**: ya, tambahkan modul pembelian bernilai dan utang supplier. Cakupan: nota pembelian, stok masuk, pembelian tunai/kredit, daftar utang dan jatuh tempo, pembayaran utang, laporan pembelian/kas keluar/utang, sinkronisasi, dan backup. Retur pembelian diatur terpisah pada BD-14. **Tidak semua role**: default hanya pemilik; izin `lihat_pembelian`, `buat_pembelian`, dan `bayar_utang` diberikan eksplisit per peran; viewer, kasir, dan mekanik tidak otomatis mendapat akses. Pembayaran tidak boleh melebihi sisa; pembelian VOID ditolak bila sudah ada pembayaran atau stok tidak cukup untuk dikembalikan. | TASK-065 sampai TASK-071 |
| BD-13 | Bila dua perangkat menjual barang terakhir sehingga stok menjadi negatif, apakah penjualan kedua dibatalkan, dipenuhi lewat stok masuk, atau dibiarkan negatif? | Penjualan tidak dibatalkan otomatis: penulisan lokal menolak stok negatif, penerima tetap menerapkan penjualan sah dan mencatat konflik `stok_negatif` untuk ditinjau pemilik | **Diputuskan**: penjualan yang tiba belakangan dan membuat stok negatif **dibatalkan otomatis**. Penjualan itu tidak boleh mengurangi stok, menambah piutang/kas, atau memberi komisi; nota asal tetap tersimpan sebagai jejak dan konflik pembatalan dicatat untuk ditinjau pemilik. | TASK-032, TASK-033 |
| BD-14 | Apakah retur pembelian diaktifkan? | Tidak ada retur; hanya VOID | **Diputuskan**: retur pembelian diaktifkan, berbasis nota asli, dibatasi qty yang dibeli dan belum diretur; stok berkurang lewat ledger, utang/kas menyesuaikan; retur pada pembelian VOID ditolak. | TASK-074 |
| BD-15 | Bagaimana valuasi harga pokok persediaan? | Harga modal per baris saja | **Diputuskan**: HPP memakai rata-rata bergerak per toko per barang; snapshot harga modal per baris tetap disimpan untuk audit. | TASK-073 |
| BD-16 | Bagaimana perlakuan pajak, diskon, dan ongkir pada nota pembelian? | Semua masuk total apa adanya | **Diputuskan**: diskon dan ongkir dialokasikan ke harga pokok baris secara proporsional; PPN dicatat terpisah dan tidak dihitung sebagai pendapatan atau HPP. | TASK-067, TASK-073 |
| BD-17 | Apakah pembelian boleh memakai DP/pembayaran sebagian? | Tunai penuh atau kredit penuh | **Diputuskan**: boleh; DP dicatat sebagai pembayaran dengan `request_id`, sisanya menjadi utang supplier. | TASK-067, TASK-068 |
| BD-18 | Sumber dana pembayaran pembelian? | Kas tunai saja | **Diputuskan**: kas tunai dan transfer bank; ledger kas mencatat metode pembayaran. | TASK-067, TASK-068 |
| BD-19 | Bolehkah pembelian di-VOID setelah barangnya terjual? | VOID hanya bila stok bisa dikembalikan | **Diputuskan**: VOID ditolak bila sudah ada pembayaran atau barang sudah terjual; sisa stok diselesaikan lewat retur pembelian, bagian yang terjual lewat koreksi/konflik yang ditinjau pemilik. | TASK-068, TASK-074 |
| BD-20 | Bagaimana jatuh tempo pembelian dihitung? | Diisi manual | **Diputuskan**: tanggal nota + termin hari (default 0 atau 30), masih dapat diubah sebelum nota disimpan. | TASK-065, TASK-069 |
| BD-21 | Apakah jatuh tempo diingatkan? | Hanya ditampilkan di daftar | **Diputuskan**: notifikasi lokal H-3 dan saat lewat jatuh tempo; tanpa push server. | TASK-075 |
| BD-22 | Bagaimana memasukkan stok, utang supplier, dan piutang pelanggan yang sudah ada saat toko mulai memakai aplikasi? | Tidak ada mekanisme; mulai dari nol | **Diputuskan**: sediakan mekanisme saldo awal khusus per toko; tidak boleh lewat pembelian/nota palsu; satu kali, dapat dikoreksi lewat opname/koreksi, diaudit, disinkronkan, dan ikut backup. | TASK-072 |
| BD-23 | Apakah stok dapat dipindahkan antar toko? | Tidak ada transfer | **Ditunda**: belum ada kebutuhan nyata; tidak ada tugas sampai diputuskan. | — |
| BD-24 | Bagaimana upgrade skema setelah rilis pertama? | Skema v1 bersih tanpa migrasi | **Diputuskan**: migrasi berversi resmi dari v1 untuk rilis berikutnya (bukan migrasi database lama), backup otomatis sebelum migrasi, rollback, dan penolakan database versi lebih baru. | TASK-078 |
| BD-25 | Apa batas data pribadi/rahasia pada log dan diagnostik? | Tidak diatur | **Diputuskan**: log/diagnostik tidak memuat kredensial, token, passphrase, atau data pribadi lengkap; retensi log lokal dibatasi dan dapat dihapus pemilik; kebijakan privasi/retensi didokumentasikan. | TASK-076, TASK-079 |
| BD-26 | Apakah pemilik dapat memilih fitur yang dipakai tiap toko? | Semua fitur selalu tampil | **Diputuskan**: pemilik penuh dapat menonaktifkan fitur opsional per toko. Fitur wajib: kasir/nota, stok, pelanggan, pembayaran/piutang, retur/void, laporan, backup/restore, akun/akses, sinkronisasi, lisensi, pengaturan. Fitur opsional default ON: estimasi, antrian/order kerja, `supplier_hub`, `purchase_debt`, follow-up, unit/kendaraan, WhatsApp. Komisi dan gaji tetap wajib pada iterasi ini. Penonaktifan tidak menghapus data; data lama tetap di riwayat/laporan dan ikut backup; fitur nonaktif berlaku untuk semua peran; hanya pemilik penuh yang mengubah (viewer read-only); `purchase_debt` membutuhkan `supplier_hub`; perubahan disinkronkan dan diaudit; data lama dari perangkat yang belum menerima flag tetap diterima dan disimpan. | TASK-081 sampai TASK-084 |
| BD-27 | Apakah modul pembelian/utang supplier dan Follow Up Reseller digabung, dan bagaimana on/off-nya bekerja? | Terpisah: supplier lokal, pembelian modul baru | **Diputuskan**: Supplier, Follow Up Reseller, dan Pembelian & Utang Supplier menjadi satu hub "Supplier & Reseller" dengan tiga tab. `supplier_hub` adalah saklar induk untuk seluruh hub; `purchase_debt` adalah sub-saklar untuk tab Pembelian & Utang yang hanya efektif bila induk aktif. Setting lokal lama `fitur.supplier` diganti flag per toko; kunci premium lama tetap berlaku untuk seluruh hub. Menonaktifkan induk menyembunyikan seluruh hub dan menahan sub-fitur tanpa menghapus nilai pilihannya; menyalakan sub-fitur saat induk mati ditolak. Izin peran hanya membatasi di dalam fitur aktif dan tidak dapat menghidupkan fitur yang dimatikan pemilik. Data lama tetap tampil di riwayat/laporan dan ikut backup; penegakan dilakukan di service, UI, route/menu, sinkronisasi penerima, dan relay. | TASK-069, TASK-081 sampai TASK-084 |
| BD-28 | Apakah PPN/pajak penjualan dapat diaktifkan per toko, siapa yang menanggungnya, dan apakah tampil di struk? | Tidak ada PPN | **Diputuskan**: PPN menjadi fitur opsional per toko yang disimpan di `store_settings` (default OFF, hanya pemilik penuh yang mengubah). Pemilik mengisi tarif (persen dua desimal, basis poin 0–10000) dan memilih penanggung `PEMBELI` atau `BENGKEL`; aplikasi tidak memakai tarif legal default. PPN dihitung dari DPP (jasa + part - diskon) pada nota penjualan, disimpan sebagai snapshot di nota bersama tarif/penanggung, dan selalu dicetak di struk. `PEMBELI` menambah tagihan; `BENGKEL` diserap sehingga total pelanggan tidak berubah tetapi tetap tampil sebagai informasi. PPN bukan pendapatan (omzet memakai DPP, kas/piutang memakai total, komisi memakai DPP). Retur/void membalik PPN proporsional. Nota lama tidak berubah saat pengaturan diubah; perangkat offline memakai konfigurasi terakhir; penerima menerima snapshot lama dan mencatat konflik bila PPN > 0 tanpa snapshot. PPN pembelian tetap terpisah (BD-16). | TASK-085 sampai TASK-087 |
| BD-29 | Apakah harga jual sudah termasuk PPN (inklusif) atau PPN ditambahkan (eksklusif)? | Eksklusif; tarif diisi pemilik, tanpa default otomatis | **BLOCKED — NEEDS BUSINESS DECISION**: implementasi sementara hanya mendukung mode eksklusif (PPN dihitung di atas DPP dan ditambahkan bila penanggung `PEMBELI`). Mode inklusif, pembulatan legal, dan tarif default menunggu keputusan pemilik sebelum diaktifkan. | TASK-085, TASK-086 |
| BD-30 | Bagaimana PPN yang ditanggung bengkel diperlakukan pada laporan, dan apakah perlu laporan rekap PPN? | Bukan pendapatan; tanpa laporan rekap | **BLOCKED — NEEDS BUSINESS DECISION**: default sementara PPN bengkel hanya dicatat sebagai informasi pada nota dan snapshot, tidak menambah omzet, serta belum menjadi biaya/laporan pajak tersendiri. Perlakuan biaya, pengurang margin, dan laporan rekap PPN menunggu keputusan. Estimasi belum menagih PPN. | TASK-086, TASK-087 |

---

## 6. Definisi selesai

- Seluruh 42 temuan memiliki tugas yang tercatat dan tidak ada yang dihapus diam-diam.
- Keputusan pemilik BD-01 sampai BD-22 serta BD-24 sampai BD-28 diterapkan; BD-23 ditunda tanpa tugas; BD-29 dan BD-30 berstatus BLOCKED dengan default konservatif yang diterapkan.
- Modul pembelian dan utang supplier (TASK-065–071), modul tambahan TASK-072–079, fitur opsional TASK-081–084, dan modul PPN TASK-085–087 selesai dan tercakup pengujian akhir; TASK-080 boleh menyusul setelah rilis.
- Fitur opsional per toko dapat dinyalakan/dimatikan tanpa menghapus data; fitur wajib terkunci.
- PPN dapat dinyalakan/dimatikan per toko, tarif dan penanggung diatur pemilik, tampil di struk, dan nota lama tidak berubah saat pengaturan berubah.
- Supplier, Follow Up Reseller, dan Pembelian & Utang menjadi satu hub dengan saklar induk/sub-fitur yang benar-benar menegakkan batas dan tidak menghilangkan data lama.
- Saldo awal, HPP, retur pembelian, aging/pengingat utang, diagnostik, operasional relay, dan dokumentasi operasional tersedia.
- APK rilis bertanda tangan, memiliki versionCode/versionName, checklist rilis, dan jalur rollback.
- Skema bersih baru dibuat tanpa migrasi data lama dan tanpa data palsu.
- SQLite dan PostgreSQL relay memakai kontrak data yang konsisten.
- Tidak ada operasi uang/stok/gaji/retur/pembayaran yang menggandakan atau menimpa tanpa konflik eksplisit.
- Seluruh referensi kode konsisten secara statis.
- `IMPLEMENTATION_PROGRESS.md` diperbarui setiap tugas/fase selesai.
- Pengujian dan build hanya pada FASE 7.
- `IMPLEMENTATION_FINAL_REPORT.md` dibuat setelah pengujian akhir.
