# Ringkasan Eksekutif — Audit Logika Bisnis PusatkuPOS

## 1. Ruang lingkup dan metode

Audit ini **hanya** memakai **analisis kode statis dan inspeksi source code**. Tidak ada unit test, integration test, automated test, aplikasi, server, build APK, simulasi runtime, instalasi/pembaruan dependensi, perubahan source, refactoring, atau perubahan konfigurasi yang dijalankan. Seluruh kesimpulan berasal dari pembacaan kode dan penelusuran call chain, bukan dari hasil eksekusi.

Yang diaudit: aplikasi APK/PusatkuPOS di `pusatkupos/` (Flutter/Dart, SQLite/SQLCipher), beserta relay premium di `relay/` (Dart + PostgreSQL) **sejauh memengaruhi logika aplikasi**. Versi web hanya dibaca sebagai bagian dari kode yang sama dan tidak dinilai sebagai produk terpisah. Repository lain di luar dua folder tersebut tidak diaudit.

Instruksi skill eksternal yang dirujuk (Pietz code-audit, Escoffier Skillet, Trail of Bits, Cloudflare security-audit) dibaca sebagai metode berpikir. Tidak ada scanner (CodeQL/Semgrep) yang dijalankan karena CodeQL tidak mendukung Dart dan karena larangan eksekusi alat. Laporan ini tidak mengklaim hasil scanner atau pengujian.

## 2. Teknologi aktual yang terdeteksi

| Lapisan | Teknologi |
|---|---|
| Aplikasi | Flutter/Dart 3.13.7, Android-first; Windows/macOS/Linux/web |
| Basis data lokal | SQLite via `sqflite`; SQLCipher di Android/iOS/macOS; skema v4 dengan migrasi aditif V2–V4 |
| Sinkronisasi | Amplop terenkripsi + tanda tangan perangkat, HLC (`sync_hlc_wall/counter`), outbox/inbox, cursor, snapshot, konflik |
| Relay | Dart HTTP server (`relay/`), PostgreSQL, lisensi Ed25519, Google login, kuota follow-up |
| Uang | Integer sen (cents), format Rupiah |
| Kuantitas | Milli-unit (1/1000), `wholeQuantity` untuk tampilan |
| Peran | KASIR, MEKANIK, SUPERVISOR/KEDUANYA, peran kustom; izin per toko di `store_settings.role_permissions_json` |

## 3. Jumlah temuan

| Tingkat risiko | Jumlah |
|---|---|
| KRITIS | 2 |
| TINGGI | 7 |
| SEDANG | 17 |
| RENDAH | 16 |
| **Total** | **42** |

Status validitas: **CONFIRMED** = dapat dibuktikan langsung dari kode; **SUSPECTED** = mekanisme terbukti tetapi kejadiannya bergantung pada kondisi operasional yang tidak dapat dijalankan pada audit statis; **NEEDS VALIDATION** = memerlukan konfirmasi aturan bisnis.

Rincian lengkap ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md). Berkas area (02–10) memuat analisis per modul dan rujukan ID.

## 4. Jawaban atas pertanyaan wajib

### 4.1 Berapa total cacat logika bisnis?
**42 temuan** (2 KRITIS, 7 TINGGI, 17 SEDANG, 16 RENDAH). Tidak semuanya pasti terjadi; 23 berstatus CONFIRMED, 18 SUSPECTED, 1 NEEDS VALIDATION.

### 4.2 Modul paling bermasalah
1. **Sinkronisasi multi-perangkat** (`pusatkupos/lib/sync/sync_service.dart`, `note_sync.dart`, `snapshot_sync.dart`) — sumber dua temuan KRITIS dan beberapa temuan TINGGI/SEDANG.
2. **Database inti dan transaksi** (`pusatkupos/lib/data/app_database.dart`) — total nota, pelunasan, void, stok, laporan, join pelanggan, dan benturan kode barang saat sinkronisasi (BL-41).
3. **Karyawan/payroll/komisi** (`employee_service.dart`, `employee_auth_service.dart`, `app_database.dart`) — pembayaran ganda, komisi dihitung ulang, akun tidak ikut snapshot.
4. **Autentikasi/izin** (`pin_gate.dart`, `access_control.dart`, `store_settings.dart`, `relay/server.dart`) — izin basi setelah ganti toko, akun nonaktif masih dapat menulis.
5. **Backup/restore** (`backup_service.dart`, `snapshot_platform_io.dart`, `backup_platform_io.dart`) — batas ukuran restore, passphrase otomatis, dan penggantian database yang tidak atomik (BL-42).

### 4.3 Risiko transaksi terbesar
**BL-02**: retur dan void yang dibuat di perangkat berbeda dapat menghasilkan stok dan nilai nota yang berbeda antardevice, termasuk retur atas nota yang sudah di-void dan retur berlebih lintas perangkat. Ini menyentuh uang, stok, dan status nota sekaligus.

### 4.4 Risiko keuangan terbesar
1. **BL-03**: pembayaran gaji siklus yang sama dapat dilakukan dua perangkat offline (tidak ada kunci lintas perangkat).
2. **BL-04**: komisi dihitung ulang memakai tarif komisi **saat ini**, bukan snapshot saat nota dibuat; akun yang hilang membuat komisi menjadi nol.
3. **BL-14**: pelunasan piutang dari dua perangkat dapat melebihi sisa tagihan.
4. **BL-19**: dashboard dan struk memakai total asli, sedangkan laporan memakai total terkoreksi/retur — angka yang dilihat pemilik tidak konsisten.

### 4.5 Risiko integritas database terbesar
**BL-01**: opname stok absolut dikirim sebagai **delta** ke perangkat lain sehingga jumlah stok dapat menyimpang permanen. Ditambah **BL-07**: `employee_accounts` dan `document_counters` tidak ikut snapshot, sehingga perangkat bootstrap kehilangan data karyawan dan penghitung dokumen. **BL-41**: dua perangkat yang membuat kode barang sama secara offline menghasilkan pelanggaran `UNIQUE(kode)` saat penerapan; amplop gagal dan cursor tidak maju sehingga antrean sinkronisasi berikutnya ikut tertahan. **BL-42**: penggantian database saat restore menghapus berkas lama sebelum rename; proses yang berhenti di jendela tersebut meninggalkan database kosong tanpa pemulihan otomatis.

### 4.6 Kesalahan logika yang dapat menyebabkan kehilangan data
- **BL-01** — jumlah stok hilang/berlebih lintas perangkat.
- **BL-02** — retur/void ganda, stok dipulihkan berlebih, nilai refund tidak konsisten.
- **BL-07** — akun karyawan tidak ada di perangkat hasil bootstrap/snapshot; komisi dapat menjadi nol dan payroll tidak lengkap.
- **BL-03** — pembayaran gaji ganda (uang keluar dua kali).
- **BL-16** — penggabungan pelanggan tidak memindahkan nota tanpa unit dan referensi follow-up/WA.
- **BL-41** — benturan kode barang antardevice membuat amplop ditolak dan cursor tidak maju; perubahan lain dalam antrean yang sama tidak pernah diterapkan sampai konflik diselesaikan manual.
- **BL-42** — restore yang terhenti setelah database lama dihapus meninggalkan database kosong; salinan `.bak` tidak dipulihkan otomatis.
- **BL-22** — passphrase backup otomatis ditampilkan di layar; siapa pun yang melihat layar dapat membuka arsip backup.

### 4.7 Urutan remediasi yang benar
1. **Hentikan dampak uang dan stok** — BL-01, BL-02, BL-03, BL-06, BL-13, BL-14.
2. **Perbaiki identitas, akun, dan otorisasi** — BL-07 s.d. BL-12, BL-27, BL-31, BL-36, BL-37.
3. **Perbaiki model data lintas perangkat** — BL-04, BL-15, BL-16, BL-21, BL-30, BL-33, BL-34, BL-40, BL-41.
4. **Samakan perhitungan dan tampilan** — BL-05, BL-17, BL-18, BL-19, BL-23, BL-25, BL-39.
5. **Perkuat backup/restore** — BL-20, BL-22, BL-32, BL-42.
6. **Sisir temuan RENDAH dan kebijakan residual** — BL-24, BL-26, BL-28, BL-29, BL-35, BL-38.
Detail fase ada di [`11_REMEDIATION_ROADMAP.md`](11_REMEDIATION_ROADMAP.md).

### 4.8 Area yang memerlukan validasi aturan bisnis
- Apakah retur seharusnya memakai izin `retur` atau `void` (BL-09).
- Apakah stok boleh negatif (BL-24).
- Apakah koreksi nota di atas modal selalu perlu persetujuan, atau hanya di bawah modal.
- Apakah akun karyawan seharusnya ikut snapshot dan dibuat otomatis saat login karyawan (BL-07).
- Apakah `viewer` boleh menulis apa pun ke database lokal (BL-28).
- Definisi "Pendapatan hari ini": bruto, neto retur, atau kas diterima (BL-19).
- Apakah perubahan periode payroll boleh membuat siklus yang sudah dibayar tampak belum dibayar.
- Apakah status follow-up boleh menghapus tanggal servis/janji bayar secara otomatis (BL-31).
- Apakah kode barang harus unik global per toko atau boleh berbeda antardevice dengan penomoran ulang otomatis (BL-41).
- Apakah modul pembelian memang tidak ada (hanya stok masuk + supplier), sehingga nilai pembelian tidak pernah dicatat.

## 5. Modul yang diperiksa vs belum

**Diperiksa mendalam (kode dibaca dan ditelusuri):** skema/migrasi, `app_database` (transaksi, stok, void, pelunasan, laporan, dashboard, merge pelanggan, nomor dokumen), `note_sync`, `sync_service`, `snapshot_sync` + platform IO, `reconciliation`, `sale_return_service`, `nota_adjustment_service`, `order_service`, `employee_service`, `employee_auth_service`, `account_service`, `approval_service`, `pin_service`, `login_guard`, `session_service`, `device_service`, `store_service`, `store_registry`, `store_settings`, `price_rules`, `backup_service`, `receipt_service`, `supplier_service`, `followup_service` (bagian inti), serta layar `pos`, `history`, `reports`, `dashboard`, `employees`, `estimates`, `settings`, `premium`, `owner_viewer`, `onboarding`, `pin_gate`, `home_shell` (bagian alur), dan relay `server`, `auth_rules`, `sync_round`, `license`, `config`.

**Diperiksa sebagian / belum mendalam:** seluruh adapter printer (`printer/*`), `receipt_template.dart`, `receipt_settings.dart`, `jasa_screen`, `stock_screen` (bagian dialog), `orders_screen`, `supplier_screen`, `followup_screen`/`followup_settings_screen`, `customers_screen` (di luar alur merge), `premium_screen` (bagian tengah), `relay/lib/db.dart`, `google.dart`, `canonical.dart`, `relay_client.dart`, `protocol.dart`, `crypto.dart`, `sync_scheduler.dart`, `backup_scheduler.dart`, `license_service/verifier` (sebagian), `pairing_service`, `owner_summary_service`, `owner_access_api`, `jasa_screen`. Modul-modul ini tidak diberi temuan yang tidak memiliki bukti; area tersebut dicatat sebagai batas audit, bukan sebagai "bersih".

## 6. Catatan penting

- Tidak ada modul pembelian (purchase order/penerimaan barang dengan nilai pembelian) di aplikasi. Yang ada hanya **stok masuk** dan **follow-up supplier**. Karena itu tidak ada perhitungan total pembayaran pembelian, utang supplier, atau harga beli per transaksi untuk diaudit; ini dicatat di laporan 02 dan 04.
- Tidak ada temuan yang dibuat berdasarkan hasil test, build, atau runtime. Skenario yang bergantung pada waktu/konkurensi diberi status SUSPECTED bila tidak dapat dibuktikan statis.
- Laporan ini tidak mengubah source code dan tidak menjalankan apa pun selain pembacaan file.
