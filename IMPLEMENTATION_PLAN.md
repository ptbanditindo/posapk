# IMPLEMENTATION PLAN — PUSATKUPOS

**Sumber:** `AUDIT_REPORT/01_BUSINESS_LOGIC_DEFECTS.md` (42 temuan) dan `AUDIT_REPORT/11_REMEDIATION_ROADMAP.md`.
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
| TASK-031 | BL-01 | Kirim opname absolut (`opname_absolut_milli`) + HLC; penerima menetapkan nilai absolut, bukan menjumlahkan delta; movement mencatat selisih | `app_database.dart`, `sync_service.dart`, `schema.dart` | Opname dua perangkat mengarah ke angka fisik yang sama | TASK-007 | KRITIS |
| TASK-032 | BL-21 | Cegah stok negatif saat finalisasi atau tandai konflik yang membatalkan penjualan kedua; reservasi/aturan relay bila online | `app_database.dart`, `sync_service.dart`, `relay/lib/server.dart` | Barang terakhir tidak terjual dua kali tanpa keputusan | TASK-007, TASK-033 | SEDANG |
| TASK-033 | BL-24 | Tetapkan dan terapkan satu kebijakan stok negatif di UI, service, dan penerima | `app_database.dart`, `stock_screen.dart`, `sync_service.dart` | Perilaku stok negatif konsisten; **kebijakan perlu keputusan bisnis** | TASK-007 | SEDANG |
| TASK-034 | BL-04 | Simpan snapshot tarif komisi saat nota dibuat; rekalkulasi memakai snapshot; akun hilang mempertahankan nominal lama + konflik | `app_database.dart`, `schema.dart`, `models.dart` | Komisi tidak berubah surut | TASK-006 | TINGGI |
| TASK-035 | BL-40 | Penerima retur memanggil rekalkulasi komisi berbasis snapshot secara idempoten | `note_sync.dart`, `app_database.dart` | Komisi penerima sama dengan perangkat asal | TASK-034 | RENDAH |
| TASK-036 | BL-41 | Tangkap pelanggaran `UNIQUE(kode)` saat apply; catat konflik `kode_bentrok`; jangan menahan amplop independen; opsi gabung/renumber | `sync_service.dart`, `sync_conflict_rules.dart`, `app_database.dart` | Satu kode bentrok tidak menghentikan seluruh sinkronisasi | TASK-002, TASK-011 | SEDANG |
| TASK-037 | BL-16 | Merge pelanggan memindahkan `service_records.customer_id` (termasuk unit NULL), unit, follow-up, WA, lalu enqueue semua perubahan | `app_database.dart`, `customer` service/UI | Riwayat pelanggan tujuan lengkap | TASK-002 | SEDANG |
| TASK-038 | BL-33 | Perkuat kode perangkat (lebih panjang/acak) dan sertakan counter dokumen dalam snapshot; nomor internal berbasis ULID | `app_database.dart`, `snapshot_sync.dart`, `schema.dart` | Nomor dokumen tidak bentrok antardevice | TASK-011 | RENDAH |

**Kriteria keluar fase:** retur/void/pelunasan/gaji/opname memiliki validasi penerima dan idempotensi; stok dan kas dapat direkonsiliasi; komisi memakai snapshot; konflik tidak menahan antrean.

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

### FASE 7 — VERIFIKASI STATIS, PENGUJIAN AKHIR, DAN LAPORAN

| ID | Uraian | Berkas | Hasil | Ketergantungan |
|---|---|---|---|---|
| TASK-060 | Sapu konsistensi statis: semua pemanggil, query, kolom, dan tipe setelah perubahan skema | seluruh `pusatkupos/lib`, `relay/lib` | Tidak ada referensi mati/kolom hilang | Semua fase |
| TASK-061 | Jalankan pengujian akhir sesuai teknologi repo (setelah seluruh implementasi selesai): test suite, SQLite, PostgreSQL relay, offline/online, sinkronisasi dua arah, konflik dua perangkat, retur/void/stok/payroll/pembayaran/laporan, backup/restore | `pusatkupos`, `relay` | Seluruh pengujian lulus atau tercatat | TASK-060 |
| TASK-062 | Build APK dan verifikasi akhir | `pusatkupos` | APK terbentuk | TASK-061 |
| TASK-063 | Tulis `IMPLEMENTATION_FINAL_REPORT.md` | root | Laporan akhir lengkap | TASK-061, TASK-062 |

> TASK-061 sampai TASK-063 **tidak boleh dimulai** sebelum seluruh tugas FASE 1–6 berstatus selesai.

---

## 4. Ketergantungan utama

```text
TASK-001 (skema bersih)
  ├─ TASK-002 (master) ─ TASK-007 (stock ledger) ─ TASK-031/032/033
  ├─ TASK-003 (nota) ─ TASK-004 (baris) ─ TASK-006 (komisi) ─ TASK-034/035
  │     └─ TASK-005 (pembayaran) ─ TASK-025/026/030
  ├─ TASK-008 (gaji) ─ TASK-027
  ├─ TASK-009 (retur) ─ TASK-028
  ├─ TASK-010 (akun/izin) ─ TASK-019/020/021/022/023/024
  └─ TASK-011 (sync) ─ TASK-036/047/049/050/051/052
TASK-013 (actor wajib) ─ TASK-014/017/018
TASK-039 (total efektif) ─ TASK-041/043/044/045
TASK-054 (restore atomik) ─ TASK-055/057
```

Tidak ada tugas yang menunggu fase berikutnya kecuali yang tercantum di atas. Tugas tanpa ketergantungan dapat dikerjakan lebih dulu.

---

## 5. Keputusan bisnis yang belum final

Item berikut ditandai **`BLOCKED — NEEDS BUSINESS DECISION`**. Implementasi hanya menggunakan default konservatif yang tidak merusak data; keputusan final tetap milik pemilik.

| Kode | Pertanyaan | Default konservatif yang dipakai sementara | Tugas |
|---|---|---|---|
| BD-01 | Apakah retur boleh melebihi qty terjual per baris (setelah retur sebelumnya)? | Tidak; total retur per baris ≤ qty terjual | TASK-028 |
| BD-02 | Apakah retur pada nota VOID boleh? | Tidak; VOID terminal | TASK-028 |
| BD-03 | Apakah opname absolut menang atas penjualan yang belum tersinkron? | Opname dengan HLC lebih baru menang; konflik dicatat | TASK-031 |
| BD-04 | Apakah pelunasan yang melebihi sisa menjadi saldo pelanggan atau ditolak? | Ditolak; kelebihan menjadi konflik | TASK-026 |
| BD-05 | Apakah satu siklus gaji hanya boleh dibayar sekali secara global? | Ya; pembayaran kedua menjadi konflik | TASK-027 |
| BD-06 | Komisi memakai tarif saat nota atau saat pembayaran? | Tarif saat nota (snapshot) | TASK-034 |
| BD-07 | Apakah akun karyawan ikut snapshot dan dibuat saat login? | Ya, tanpa kredensial | TASK-024 |
| BD-08 | Apakah viewer boleh menulis ke salinan lokal? | Tidak; viewer read-only | TASK-020 |
| BD-09 | Definisi "pendapatan hari ini": bruto, neto retur, atau kas? | Tampilkan ketiganya dengan label jelas | TASK-043 |
| BD-10 | Kode barang unik global per owner atau boleh renumber otomatis? | Unik per toko; konflik dicatat, tidak memblokir antrean | TASK-036 |
| BD-11 | Apakah perubahan status follow-up boleh menghapus tanggal servis/janji bayar? | Tidak; tanggal dipertahankan kecuali status baru membutuhkan dan dikonfirmasi | TASK-018 |
| BD-12 | Apakah ada modul pembelian bernilai/utang supplier? | Tidak ada; tidak ada tugas pembelian baru | — |

---

## 6. Definisi selesai

- Seluruh 42 temuan memiliki tugas yang tercatat dan tidak ada yang dihapus diam-diam.
- Skema bersih baru dibuat tanpa migrasi data lama dan tanpa data palsu.
- SQLite dan PostgreSQL relay memakai kontrak data yang konsisten.
- Tidak ada operasi uang/stok/gaji/retur/pembayaran yang menggandakan atau menimpa tanpa konflik eksplisit.
- Seluruh referensi kode konsisten secara statis.
- `IMPLEMENTATION_PROGRESS.md` diperbarui setiap tugas/fase selesai.
- Pengujian dan build hanya pada FASE 7.
- `IMPLEMENTATION_FINAL_REPORT.md` dibuat setelah pengujian akhir.
