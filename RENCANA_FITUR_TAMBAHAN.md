# Audit & Rencana Perubahan Fitur — PusatkuPOS

Tanggal audit: 4 November 2026
Acuan aturan bisnis: repo `ptbanditindo/aplikasiposbengkel` (commit `0bf2e1c`, clone lokal di
`C:\Users\sukron\AppData\Local\Temp\aplikasiposbengkel-review`).
Sasaran perubahan: `pusatkupos/` (aplikasi utama), `relay/` (untuk login Google dan
dukungan multi-toko). Aplikasi terpisah `pusatkupos_owner/` sudah dihapus; fungsinya
menjadi jalur login **Ringkasan laporan toko** (read-only) di aplikasi utama.
Dokumen ini **rencana + status**; tahap 1–2, 4–8, dan printer 3B–3C sudah diimplementasikan
di `pusatkupos/`. Uji perangkat printer fisik masih menjadi langkah terpisah.

## 1. Keputusan yang mengikat rencana ini

1. Fitur acuan Python yang belum ada di Flutter akan dibuat: garansi, follow-up + kuota,
   supplier, karyawan/komisi/gaji, multi-toko, pengaturan struk, printer thermal.
2. Login owner **tanpa akun** tetap menjadi jalur utama (PIN lokal, tanpa internet).
3. Login **Google hanya untuk pelanggan premium**; dipakai untuk verifikasi identitas,
   aktivasi/pemulihan lisensi, bukan syarat transaksi.
4. Nomor nota memakai **angka murni 1, 2, 3, … tanpa batas atas**, tanpa prefix perangkat,
   tanpa reset harian, dan **tidak boleh ada nomor ganda**.
5. Offline-first tidak boleh rusak: transaksi, stok, struk, dan backup tetap berjalan
   tanpa internet. Semua fitur baru disimpan lokal lebih dulu.
6. Semua perubahan skema lewat migrasi `onUpgrade` yang aditif; data lama tidak diubah.

## 2. Kondisi sekarang vs acuan

| Area | Flutter sekarang | Acuan Python | Status |
| --- | --- | --- | --- |
| Nomor nota | `INV-YYYY-MM-DD-<prefix>-0001`, counter harian (`lib/data/app_database.dart:1262-1298`) | Angka `1,2,3…` untuk owner; prefix perangkat hanya sesi perangkat | **Diubah sesuai keputusan #4 (angka murni)** |
| Garansi | Tidak ada | `warranty_service.py`, kolom garansi di nota | Belum ada |
| Follow-up | Tidak ada | `followup_service.py`, kuota 20 kredit gratis | Belum ada |
| Supplier | Tidak ada | `supplier_service.py` | Belum ada |
| Karyawan/komisi/gaji | Hanya akun login (`employee_accounts`) | `employees`, komisi, payroll, hutang | Sebagian |
| Multi-toko | Satu database | Registry + file DB per toko | Belum ada |
| Pengaturan struk | Tidak ada | 25 toggle `receipt.*` | Belum ada |
| Printer thermal | Model + store + adapter SPP/BLE/TCP/USB/system/browser (`lib/printer/`) | ESC/POS, BT/TCP/USB/system | **Kode selesai; uji perangkat belum** |
| Login owner tanpa akun | Sudah (PIN → `Operator.owner`, `pin_gate.dart:59-114`) | Sama | Pertahankan, rapikan |
| Login Google | Tidak ada | Tidak ada (hanya rencana) | Baru, perlu relay |
| Uji | 12 file tes Dart | 404 tes Python | Perlu tes paritas |

## 3. Nomor nota: angka murni 1…∞, tanpa duplikat

### 3.1 Aturan final

- Format: `"1"`, `"2"`, `"3"`, … (string desimal, tanpa padding, tanpa `INV`, tanpa prefix).
- Counter **global per database toko**, tidak reset harian, tidak reset saat ganti tahun.
- Nomor yang sudah dipakai **tidak pernah dipakai ulang**, termasuk nota VOID/retur.
- Unik dijamin dua lapis: `service_records.no_nota UNIQUE` (sudah ada,
  `app_database.dart:166`) dan alokasi di dalam transaksi tulis yang sama
  (`createTransaction`, `app_database.dart:1061`).
- Tidak memakai `device.nota_prefix` lagi. Setting lama boleh dibiarkan (tidak dibaca)
  agar backup lama tidak rusak.

### 3.2 Implementasi

1. Ubah `_nextNota` (`app_database.dart:1262-1298`) menjadi:

   ```dart
   Future<String> _nextNota(Transaction txn) async {
     await txn.rawInsert(
       "INSERT OR IGNORE INTO nota_counters(tanggal, terakhir) VALUES('NUMERIC', 0)",
     );
     final rows = await txn.query(
       'nota_counters',
       where: "tanggal = 'NUMERIC'",
       limit: 1,
     );
     var next = ((rows.first['terakhir'] as int?) ?? 0) + 1;
     if (next == 1) {
       // Inisialisasi dari nota angka yang sudah ada (termasuk VOID).
       final seed = await txn.rawQuery(
         "SELECT COALESCE(MAX(CAST(no_nota AS INTEGER)), 0) AS maks "
         "FROM service_records "
         "WHERE no_nota NOT GLOB '*[^0-9]*' AND no_nota <> ''",
       );
       next = ((seed.first['maks'] as int?) ?? 0) + 1;
     }
     await txn.update(
       'nota_counters',
       {'terakhir': next},
       where: "tanggal = 'NUMERIC'",
     );
     return '$next';
   }
   ```

2. `createTransaction` tetap memanggil `_nextNota(txn)` di `app_database.dart:1140`;
   parameter aktor tidak diperlukan lagi untuk penomoran.
3. Migrasi DB versi 6: isi `nota_counters('NUMERIC', max_nomor_lama)` dari nota yang
   seluruhnya angka, lalu naikkan `version` di `app_database.dart:72` dan tambahkan
   cabang `if (oldVersion < 6)` di `_upgrade` (`:293-306`). Migrasi **tidak menomori ulang**
   nota lama.
4. Nota lama berformat `INV-…` (data uji/legacy) dibiarkan apa adanya. Nomor baru mulai
   dari angka tertinggi yang sudah ada + 1, atau `1` bila belum ada nota angka.
5. Hapus pembuatan `device.nota_prefix` dari jalur penomoran. Jika masih ada kode lain yang
   membacanya, biarkan hanya untuk kompatibilitas baca.

### 3.3 Sinkronisasi dan "tidak boleh ganda"

- Lokal: dijamin transaksi + UNIQUE; dua permintaan bersamaan tidak bisa mendapat nomor
  yang sama karena SQLite menserialkan penulisan.
- Saat menerapkan delta/snapshot dari perangkat lain (`lib/data/note_sync.dart:349-390`),
  perilaku lama menambahkan suffix pada `no_nota`. Itu melanggar aturan angka murni.
  Ganti menjadi:
  1. Jika `no_nota` bentrok dengan nota lain, alokasikan nomor **angka berikutnya** untuk
     nota masuk, lalu simpan pemetaan `no_nota_asal` di detail konflik
     (`sync_conflicts.reason = 'no_nota_bentrok'`).
  2. Jangan mengubah nomor nota yang sudah ada di perangkat ini.
  3. Catat konflik agar bisa diaudit; nomor asli tetap terlihat di detail konflik.
- **Keterbatasan yang harus disadari:** dua perangkat yang sama-sama offline bisa membuat
  nomor yang sama. Selama belum sinkron, tiap database lokal tetap unik; setelah sinkron,
  salah satunya dinomori ulang. Unik lintas perangkat *pada saat yang sama* hanya bisa
  dijamin dengan satu otoritas nomor (relay/owner hub). Jika nanti multi-perangkat
  diaktifkan dan Anda menuntut nomor tidak pernah berubah, perlu alokasi blok nomor dari
  relay — ini keputusan terpisah dan tidak termasuk rencana ini.
- Tes yang harus diperbarui/ditambah:
  - `test/note_sync_test.dart:136-137` masih mengharapkan `startsWith('INV-')` → ganti.
  - `test/business_rules_test.dart:338-399` menguji suffix bentrok → ganti menjadi uji
    renumber + `no_nota_asal`.
  - Tes baru: urut 1..N lintas restart, lanjut setelah VOID, tidak reset harian,
    migrasi v5→v6 mempertahankan nota lama, dua transaksi paralel tidak bentrok.

## 4. Login owner tanpa akun dan login Google premium

### 4.1 Owner tanpa akun (dipertahankan)

Kondisi sekarang sudah benar secara dasar: PIN lokal → `Operator.owner`
(`pin_gate.dart:59-114`, `operator.dart:30-49`), tidak ada baris akun owner, dan
`AppState.load()` hanya membaca `auth.pin_hash` (`state/app_state.dart:23-35`).
Yang dirapikan:

- Tulis `app.role = 'owner'` secara eksplisit saat login owner berhasil; saat ini hanya
  pairing karyawan yang menulis `app.role = 'employee'` (`pairing_service.dart:113`).
  Tanpa ini, perangkat yang pernah dipakai karyawan bisa tetap menampilkan form karyawan.
- `PinGate` harus memilih form dari `app.role` + keberadaan token perangkat, bukan hanya
  dari setting yang bisa tertinggal.
- Login karyawan sebaiknya memakai `loginDevice` bila token perangkat tersedia
  (`account_service.dart:392-441`), bukan selalu `loginHub` (`pin_gate.dart:129`), agar
  `deviceId` terisi dan nomor/jejak perangkat benar.
- `loginHub` perlu memeriksa status premium seperti Python (`auth_routes.py:183`):
  akun karyawan hanya untuk premium. Saat ini pembuatan akun digerbang premium
  (`account_service.dart:83-86`) tetapi login tidak.
- Owner gratis **tidak boleh** dipaksa membuat ID owner/lisensi. `ensureOwner()` hanya
  dipanggil saat aktivasi premium (lihat `license_service.dart`, `premium_screen.dart:105`).
- Tidak ada perubahan pada PIN: tetap PBKDF2 600k, lockout, dan minimum 6 digit
  (`pin_service.dart:10-14,27-70`).

### 4.2 Google untuk pelanggan premium

Tujuan: setelah membeli langganan, pemilik dapat memverifikasi identitas Google untuk
mengambil/memulihkan lisensi dan mengikat perangkat owner. **Bukan** pengganti PIN dan
**bukan** syarat membuka aplikasi atau membuat nota.

**Relay (`relay/`)**

- Tambah konfigurasi `RELAY_GOOGLE_CLIENT_ID` (wajib untuk endpoint Google) di
  `relay/lib/config.dart`; tambahkan ke `relay/.env.example` tanpa nilai rahasia.
- Tambah tabel aditif di `relay/lib/db.dart`:

  ```sql
  CREATE TABLE IF NOT EXISTS owner_identities (
    google_sub   TEXT PRIMARY KEY,
    owner_id     TEXT UNIQUE REFERENCES owners(owner_id) ON DELETE SET NULL,
    email        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ
  );
  ```

- Tambah endpoint `POST /relay/auth/google` di `relay/lib/server.dart`:
  1. Terima `{ "id_token": "..." }`; **jangan** menerima `owner_id` dari klien.
  2. Verifikasi tanda tangan RS256 terhadap JWKS Google, `iss` = `accounts.google.com`
     atau `https://accounts.google.com`, `aud` = client ID, `exp` belum lewat, `sub` ada.
  3. Cari `owner_identities.google_sub`.
     - Jika terhubung ke owner premium → kembalikan lisensi (token bertanda tangan seperti
       alur admin sekarang, lihat `server.dart:929-966`) dan daftar perangkat.
     - Jika belum terhubung → kembalikan identitas saja (`sub`, `email`, `premium: false`).
       **Jangan** membuat `owner_id` dari input klien.
  4. Simpan/ubah `last_login_at`; jangan mencatat `id_token`.
- Pengikatan `google_sub` → `owner_id` dilakukan admin setelah pembelian (CLI/admin),
  bukan otomatis dari klien, agar langganan tidak bisa diklaim sembarang orang.
- Tambah rate limit sederhana per IP/`sub` untuk endpoint ini.

**Klien Flutter**

- Tambah dependensi `google_sign_in` di `pusatkupos/pubspec.yaml`; konfigurasi
  OAuth client ID per platform (Android SHA-1, web, Windows lewat loopback flow).
- Alur: Pengaturan/Premium → "Masuk dengan Google" → dapat `idToken` → kirim ke relay →
  bila premium, simpan hasil melalui `LicenseService.installToken` (mekanisme yang sudah
  ada, `license_service.dart:94-120`); bila belum premium, tampilkan status "belum ada
  langganan" dan jangan mengunci fitur gratis.
- Sesi Google **tidak** disimpan sebagai sesi aplikasi. Setelah lisensi terpasang,
  aplikasi tetap memakai PIN owner dan verifikasi lisensi offline
  (`license_verifier.dart`, `license_service.dart:122-168`).
- Logout Google hanya menghapus kredensial Google, bukan lisensi/data lokal.
- Jalur **Ringkasan laporan toko** memakai `signIn()` yang sama, lalu memasang lisensi
  ke database viewer terpisah (`viewer_<owner_id>.db`) dan hanya membuka layar baca.

**Keamanan & kepatuhan**

- Verifikasi token hanya di relay; klien tidak boleh mempercayai klaim tanpa tanda tangan.
- Jangan kirim `id_token`, `sub`, atau email ke log/backup.
- Kebijakan privasi perlu menyebut data Google (sub, email) dan tujuan retensi.

## 5. Rencana per fitur

Semua tabel baru harus ditambahkan ke `snapshotTables` + `snapshotDeleteOrder`
(`lib/sync/snapshot_sync.dart:12-34`) dan ke entity sync di `sync_service.dart` bila
datanya perlu ikut perangkat lain. Tabel rahasia/lokal (token, counter kuota) masuk
`snapshotLocalTables` (`snapshot_sync.dart:36-47`). Backup file SQLite otomatis mencakup
tabel baru (`backup_service.dart:46-89`).

### 5.1 Garansi

**Acuan:** `services/warranty_service.py`; kolom di `database/models.py:459-487`;
1 bulan = 30 hari; klaim sekali; status `DIBATALKAN > TANPA GARANSI > SUDAH CLAIM >
AKTIF/KEDALUWARSA`.

**Skema (DB v7, ALTER `service_records`):**
`bergaransi INTEGER DEFAULT 1`, `garansi_bulan INTEGER DEFAULT 1`,
`garansi_sampai TEXT`, `catatan_garansi TEXT`, `status_klaim TEXT DEFAULT 'Belum claim'`,
`tanggal_klaim TEXT`, `sparepart_only INTEGER DEFAULT 0`,
`garansi_barang_aktif INTEGER DEFAULT 0`, `garansi_barang_nilai INTEGER DEFAULT 0`,
`garansi_barang_satuan TEXT DEFAULT 'HARI'`, `garansi_barang_sampai TEXT`.
Tambahkan `interval_servis_bulan INTEGER DEFAULT 0` pada `service_jobs` dan
`service_parts` (snapshot saat nota dibuat, dibutuhkan follow-up).

**Perubahan:**
- `lib/data/app_database.dart`: kolom baru, hitung `garansi_sampai` saat simpan,
  method `claimWarranty(recordId, actor)` dengan update kondisional
  (`status_klaim != 'Sudah claim' AND status != 'VOID'`), tolak kedaluwarsa/VOID.
- `lib/data/models.dart`: field garansi pada `ServiceRecordSummary`/`RecordDetail`.
- `lib/ui/screens/pos_screen.dart`: toggle bergaransi, durasi bulan, syarat, mode
  sparepart-only (tanpa jasa, minimal 1 part).
- `lib/ui/screens/history_screen.dart`: badge status garansi + tombol Klaim.
- `lib/ui/screens/settings_screen.dart`: default garansi bulan + syarat standar.
- Gating: gratis (semua paket).
- Tes: 30 hari, tanpa garansi, VOID, klaim ganda/paralel, tanggal klaim tidak tertimpa.

### 5.2 Follow-up + kuota

**Acuan:** `services/followup_service.py`, `contact_gate_service.py`,
`followup_quota_service.py`, `whatsapp_service.py`; 9 status; kuota gratis 20 kredit per
toko; premium tanpa batas; WhatsApp dibuka manual lewat `wa.me`.

**Skema (DB v7):**
- `followup_items(id, sync_id, jenis, item_key, status, stage, interval_bulan,
  reference_date, jatuh_tempo, customer_id, unit_id, service_record_id,
  followup_terakhir, janji_bayar, tanggal_service, tunda_sampai, no_response_count,
  perlu_telepon, alasan_arsip, created_at, updated_at)` dengan **unique parsial**
  `(item_key) WHERE status != 'ARSIP'`.
- `followup_events(id, sync_id, item_id, jenis, status, catatan, created_at)` append-only.
- `wa_message_logs(id, sync_id, customer_id, jenis, status, nomor_masked, created_at)`.
- Counter kuota di `app_settings`: `followup.wa_used` (monoton, per toko).

**Perubahan:**
- `lib/data/followup_service.dart` (baru): sinkronisasi sumber item (prospek, garansi,
  servis berkala, piutang, kendaraan selesai), transisi status, kuota, cooldown, jam
  follow-up, DNC, prioritas pesan.
- Pemicu: setelah simpan nota, void/retur, pelunasan piutang, klaim garansi, unit diambil.
- `lib/ui/screens/followup_screen.dart` (baru): kartu ringkasan + filter
  Semua/Hari ini/Terlambat/Arsip; tombol Ingatkan/WA/Detail/Status.
- `lib/ui/home_shell.dart`: entri menu Follow up (bukan tab bawah) untuk owner/kasir
  dengan izin.
- `lib/ui/screens/settings_screen.dart`: jam follow-up, interval, batas pesan.
- `lib/core/wa_link.dart` (baru): pembuat tautan `wa.me` + masking nomor; tanpa API.
- Gating: gratis 20 kredit; premium tanpa batas (cek `LicenseService.isPremium()`).
- Tes: kuota habis, cooldown, DNC, jam, transisi status, merge pesan, auto-arsip.

### 5.3 Supplier

**Acuan:** `services/supplier_service.py`; tabel `suppliers`, `supplier_items`,
`supplier_followups`; status reseller `DIPESAN/DIKIRIM/TIDAK_TERSEDIA/ARSIP`; barang
menipis memakai `stok_minimum` atau default 3.

**Skema (DB v7):**
`suppliers(id, sync_id, nama, nomor_hp, alamat, catatan, aktif, created_at, updated_at)`;
`supplier_items(id, sync_id, supplier_id, stock_item_id, UNIQUE(supplier_id, stock_item_id))`;
`supplier_followups(id, sync_id, supplier_id, stock_item_id, status, catatan, updated_at,
UNIQUE(supplier_id, stock_item_id))`.

**Perubahan:**
- `lib/data/supplier_service.dart` (baru): CRUD, validasi nama unik ≥2 karakter, daftar
  barang menipis/habis per supplier.
- `lib/ui/screens/supplier_screen.dart` (baru): tab Supplier + Follow up Reseller.
- `lib/ui/screens/stock_screen.dart`: pilih supplier saat tambah/edit sparepart.
- `lib/ui/screens/settings_screen.dart`: toggle fitur supplier.
- Gating: premium (mengikuti `entitlement_service.py:13-31`).
- Tes: validasi, cascade, low-stock, status, gating.

### 5.4 Karyawan / komisi / gaji

**Acuan:** `services/employee_service.py`, `salary_service.py`,
`payroll_receipt_service.py`; komisi barang = margin `(harga_jual - modal) × qty`,
jasa = `biaya_jasa - retur`; pembagian mekanik rata/manual; payroll mingguan s.d. bulanan;
hutang karyawan dipotong FIFO.

**Skema (DB v8):**
- Perluas `employee_accounts` (bukan tabel karyawan kedua agar tidak ada identitas ganda):
  `jenis_imbalan TEXT DEFAULT 'KOMISI'`, `gaji_bulanan INTEGER DEFAULT 0`,
  `komisi_mode TEXT DEFAULT 'PERSEN'`, `komisi_barang_nilai INTEGER DEFAULT 0`,
  `komisi_jasa_nilai INTEGER DEFAULT 0`, `payroll_period TEXT DEFAULT 'BULANAN'`,
  `payroll_tanggal INTEGER DEFAULT 1`, `payroll_hari INTEGER DEFAULT 0`,
  `bank_nama/bank_nomor/bank_pemilik TEXT`, `tanggal_masuk TEXT`.
- `service_record_mechanics(id, sync_id, service_record_id, employee_sync_id, urutan,
  UNIQUE(service_record_id, employee_sync_id))` untuk banyak mekanik per nota.
- `service_record_commissions(id, sync_id, service_record_id, employee_sync_id,
  nominal_override, UNIQUE(...))`.
- `employee_debts(id, sync_id, employee_sync_id, nominal, terbayar, catatan, created_at)`.
- `salary_payments(id, sync_id, employee_sync_id, periode, cycle_start, tanggal, nominal,
  potongan_hutang, cicilan_hutang, bonus, metode, created_at)`; cek unik
  `(employee_sync_id, cycle_start)` di service.
- `service_records.cashier_employee_id` (nullable) untuk jejak kasir; `mechanic` lama
  dipertahankan untuk kompatibilitas.

**Perubahan:**
- `lib/data/employee_service.dart` (baru): CRUD, validasi, penugasan, hitung komisi,
  payroll summary, hutang, gaji.
- `lib/ui/screens/employees_screen.dart` (baru): daftar, performa, komisi, gaji, hutang.
- `lib/ui/screens/pos_screen.dart`: pilih kasir + banyak mekanik; tampilkan estimasi komisi.
- `lib/ui/screens/history_screen.dart`: rincian komisi per nota.
- `lib/ui/screens/reports_screen.dart`: laba setelah komisi/gaji, rekap karyawan.
- `lib/ui/screens/settings_screen.dart`: toggle karyawan aktif.
- Gating: premium.
- Tes: validasi, pembagian komisi, margin, payroll cycle, potong hutang, satu gaji/siklus.

### 5.5 Multi-toko

**Acuan:** `database/store_registry.py`, `services/store_service.py`,
`api/store_routes.py`; registry + satu file SQLite per toko; `database_id` per toko;
penambahan toko premium; karyawan hanya toko yang ditugaskan.

**Rancangan Flutter:**
- Registry disimpan di database utama (`registry.db` atau tabel `stores` di DB utama):
  `stores(store_id, database_id, nama, alamat, database_path, created_at)`,
  `app_settings.active_store_id`.
- `AppDatabase` diubah agar menerima path DB aktif: `initForStore(StoreRef)` dan
  `switchStore(storeId)`; tutup koneksi lama, buka yang baru, lalu
  `AppState.reloadAll()`. Semua layar memuat ulang lewat listener `AppState`.
- Toko pertama dari instalasi lama menjadi `utama`; file DB lama tidak dipindah.
- Toko baru dibuat dengan file `stores/<ulid>.db` + seed identitas toko.
- "Ganti toko" ditempatkan di **Menu (drawer) di atas Ringkasan**, hanya tampil bila
  ada >1 toko; karyawan hanya melihat toko yang ditugaskan.
- `lib/data/store_service.dart` (baru), `lib/ui/widgets/store_switcher.dart` (baru).
- Mode ringkasan memuat daftar toko dari ringkasan owner dan memakai salinan
  database terpisah, bukan database pembukuan lokal.
- Gating: tambah toko premium; lihat toko yang sudah ada tetap boleh.
- Risiko: semua fitur baru harus sadar toko aktif; kuota follow-up, pengaturan struk,
  printer, dan nomor nota berada di DB toko masing-masing.

### 5.6 Pengaturan struk

**Acuan:** `services/settings_service.py:99-149`, `receipt_service.py`;
25 toggle `receipt.<field>` disimpan di `app_settings`, default `"1"`.

**Perubahan:**
- `lib/data/receipt_settings.dart` (baru): daftar 25 field + baca/tulis `app_settings`.
- `lib/ui/screens/settings_screen.dart`: `SectionCard` "Struk" dengan switch per bagian
  (tagline, alamat, kontak, no_nota, tanggal, kasir, mekanik, pelanggan, hp, unit,
  keluhan, catatan, jasa, part, total_jasa, total_part, diskon, grand_total, metode,
  bayar, kembalian, status_bayar, garansi, rekening, footer).
- `lib/data/receipt_service.dart` (baru): render teks 32/48 kolom + data ESC/POS,
  menghormati toggle; jika `karyawan_aktif=false`, kasir/mekanik dipaksa off.
- `lib/ui/screens/pos_screen.dart` dan `history_screen.dart`: ganti dialog struk ringkas
  dengan pratinjau struk + Cetak/WA.
- Tes: default semua tampil, toggle berlaku pada teks cetak/WA, VOID/retur/kredit
  tampil sesuai aturan.

### 5.7 Printer thermal

**Acuan:** `services/printer_settings_service.py`, `escpos_service.py`,
Android `ClassicSppTransport.kt`, `TcpNetworkTransport.kt`, `UsbPrinterDevice.kt`,
`SystemPrintLayout.kt`; kertas hanya 58/80 mm.

**Rancangan Flutter:**
- `lib/printer/printer_config.dart`: model `PrinterConfig` (id, nama, tipe
  BLUETOOTH/NETWORK/USB/SYSTEM/WEB, paper 58/80, mode ESCPOS/TEXT/SYSTEM/BROWSER,
  encoding, address/ip/port). Simpan di file `printer_config.json` lewat
  `path_provider`, **di luar database** agar tidak ikut backup/sync (paritas Python).
- `lib/printer/escpos_builder.dart`: encoder ESC/POS murni Dart (init, align, bold,
  double-width, feed, cut), sanitasi ASCII, wrap 32/48 kolom.
- Adapter:
  - NETWORK: `Socket.connect` (Android/desktop) port 9100 default; pencarian via NSD
    `_pdl-datastream._tcp` di bridge Android.
  - BLUETOOTH: dua jalur — Classic SPP lewat MethodChannel native (UUID
    `00001101-0000-1000-8000-00805F9B34FB`) dan BLE GATT lewat
    `flutter_blue_plus` (layanan FFE0/FF00/FF10/FF20/18F0).
  - USB: bridge native Android, hanya perangkat dengan endpoint BULK OUT,
    identitas `usb:VID:PID`.
  - SYSTEM: Android Print Framework lewat bridge native (PDF 58/80 mm).
  - WEB: dialog cetak browser.
  - Windows desktop: jaringan tetap jalan; Bluetooth/USB Android belum tersedia.
- `lib/printer/printer_service.dart`: daftar printer, printer utama, tes cetak,
  connect-on-demand, status SAVED/CONNECTED/ERROR, tanpa status "terhubung" palsu.
- UI: `SectionCard` "Printer" di `settings_screen.dart` (tambah/edit/hapus/tes/utama),
  tombol Cetak di POS dan Riwayat.
- Gating: gratis (semua paket).
- Tes: encoder (kolom, potong, encoding), validasi alamat/IP/port, fallback error,
  layout 58/80.

## 6. Migrasi database

Naikkan `version` di `app_database.dart:72` secara bertahap; setiap langkah aditif dan
idempoten:

| Versi | Isi |
| --- | --- |
| 6 | Counter nota `'NUMERIC'`, inisialisasi dari nomor tertinggi; tanpa ubah nota lama |
| 7 | Kolom garansi + `interval_servis_bulan`; tabel follow-up, WA log, supplier |
| 8 | Kolom kompensasi karyawan; mekanik/komisi/hutang/gaji |
| 9 | Registry toko + `active_store_id` (bila multi-toko dikerjakan setelah v8) |

Aturan:
- Selalu `if (oldVersion < N)` berurutan di `_upgrade` (`:293-306`).
- Jangan menghapus/rename kolom lama; `service_records.no_nota` tetap UNIQUE.
- Tabel baru wajib ditambahkan ke `snapshotTables`/`snapshotDeleteOrder`
  (`snapshot_sync.dart:12-34`) dan entity sync di `sync_service.dart:500-1136`
  bila harus tersinkron; tabel lokal/rahasia ke `snapshotLocalTables`.
- `backup_service.dart` menyalin seluruh file DB; tidak perlu daftar tabel baru, tetapi
  restore harus tetap melewati `_requiredRestoreTables` (`backup_service.dart:17-23`).

## 7. Daftar file yang akan diubah/ditambah

### 7.1 Aplikasi utama (`pusatkupos/`)

| File | Perubahan |
| --- | --- |
| `lib/data/app_database.dart` | Migrasi v6–v9; `_nextNota` numerik; kolom garansi; tabel fitur baru; method CRUD/transaksi |
| `lib/data/models.dart` | Field garansi, komisi, supplier, follow-up, struk |
| `lib/data/followup_service.dart` *(baru)* | Sumber item, status, kuota, cooldown, pesan |
| `lib/data/supplier_service.dart` *(baru)* | CRUD supplier + follow-up reseller |
| `lib/data/employee_service.dart` *(baru)* | Karyawan, komisi, payroll, hutang, gaji |
| `lib/data/store_service.dart` *(baru)* | Registry toko, ganti toko, isolasi |
| `lib/data/receipt_settings.dart` *(baru)* | 25 toggle struk |
| `lib/data/receipt_service.dart` *(baru)* | Render struk 58/80 + teks WA |
| `lib/printer/printer_config.dart` *(baru)* | Model + file konfigurasi printer |
| `lib/printer/escpos_builder.dart` *(baru)* | Encoder ESC/POS |
| `lib/printer/printer_service.dart` *(baru)* | Koneksi/status/tes cetak |
| `lib/core/wa_link.dart` *(baru)* | Tautan `wa.me`, masking nomor |
| `lib/ui/home_shell.dart` | Menu Follow up/Supplier/Karyawan; Ganti toko di atas Ringkasan; visibilitas per peran |
| `lib/ui/screens/pos_screen.dart` | Garansi, kasir/mekanik, struk, cetak |
| `lib/ui/screens/history_screen.dart` | Klaim garansi, komisi, struk/cetak |
| `lib/ui/screens/stock_screen.dart` | Supplier item, minimum stok |
| `lib/ui/screens/settings_screen.dart` | Struk, printer, garansi, follow-up, supplier, karyawan |
| `lib/ui/screens/reports_screen.dart` | Laba setelah komisi/gaji, rekap |
| `lib/ui/screens/followup_screen.dart` *(baru)* | Kartu & aksi follow-up |
| `lib/ui/screens/supplier_screen.dart` *(baru)* | Supplier + reseller |
| `lib/ui/screens/employees_screen.dart` *(baru)* | Karyawan, komisi, gaji, hutang |
| `lib/ui/widgets/store_switcher.dart` *(baru)* | Dialog/daftar ganti toko |
| `lib/ui/pin_gate.dart` | Pilihan owner/karyawan dari `app.role`; `loginDevice`; teks |
| `lib/data/account_service.dart` | Gating premium login; kolom kompensasi |
| `lib/auth/operator.dart` | (Opsional) identitas/plan; tidak wajib untuk Google |
| `lib/data/license_service.dart` | Aktivasi via Google; `ensureOwner` saat premium |
| `lib/sync/note_sync.dart` | Renumber saat bentrok (bukan suffix), catat `no_nota_asal` |
| `lib/sync/sync_service.dart` | Entity sync baru (supplier, garansi, komisi, dll.) |
| `lib/sync/snapshot_sync.dart` | Daftar tabel snapshot baru |
| `pubspec.yaml` | `google_sign_in`, plugin printer (BT/USB), paket pendukung |
| `test/*` | Tes baru + perbarui tes `INV-` dan bentrok nota |

### 7.2 Mode ringkasan (di dalam `pusatkupos/`)

| File | Perubahan |
| --- | --- |
| `lib/ui/owner_viewer.dart` | Enam tab read-only: ringkasan, riwayat, laporan, cadangan, akses, pengaturan |
| `lib/data/owner_access_api.dart` | Kelola akun, undangan, perangkat lewat layanan pusat |
| `lib/core/summary_file_*.dart` | Baca berkas ringkasan owner |
| `lib/data/app_database.dart` | Database viewer terpisah dari pembukuan lokal |
| `lib/data/google_auth_service.dart` | `signIn()`/`install()` agar tujuan database dapat dipilih |
| `lib/ui/onboarding.dart` | Empat pilihan masuk, termasuk ringkasan laporan toko |

#### 7.2.1 Gate kelengkapan unggah cadangan

Unggah cadangan tidak boleh menghasilkan snapshot yang kehilangan data satu
perangkat. Alurnya memakai putaran sinkron:

1. Perangkat owner membuka putaran; relay menyimpan `latest_seq` dan daftar
   perangkat tulis (semua perangkat owner + satu perangkat terbaru per akun
   karyawan; `viewer` dan perangkat dicabut dikecualikan).
2. Setiap perangkat mengakui putaran setelah mengirim antrean lokal dan
   menerima data sampai `latest_seq`, membawa `pending_count`.
3. Relay menandai lengkap hanya bila semua perangkat sudah ack, tidak ada
   antrean lokal, dan tidak ada data baru setelah putaran dibuka.
4. Snapshot ditolak bila putaran belum lengkap atau basi. Metadata snapshot
   diverifikasi dengan tanda tangan perangkat.
5. Status per perangkat di-cache di tabel lokal `device_sync_status` dan
   ditampilkan sebagai checklist "sudah/belum sinkron" sebelum unggah.

| File | Perubahan |
| --- | --- |
| `lib/ui/upload_backup_dialog.dart` *(baru)* | Checklist perangkat, periksa ulang, tombol unggah terkunci |
| `lib/sync/sync_service.dart` | `startUploadCheck`, `refreshUploadCheck`, `uploadSnapshot(roundId)`, ack putaran saat sync |
| `lib/sync/relay_client.dart` | Endpoint putaran sinkron |
| `lib/data/app_database.dart` | Tabel `device_sync_status` (schema v10) |
| `lib/ui/screens/premium_screen.dart` | Unggah lewat dialog kelengkapan |
| `test/upload_gate_test.dart` *(baru)* | Cache status + upload ditolak tanpa perangkat |
| `relay/lib/sync_round.dart` *(baru)* | Evaluasi kelengkapan murni |
| `relay/lib/server.dart` | Endpoint putaran + validasi snapshot + tanda tangan |
| `relay/lib/db.dart` | `sync_rounds`, `sync_round_acks`, kolom baru `snapshots` |
| `relay/test/sync_round_test.dart` *(baru)* | Kasus offline, antrean, stale, revoked |

### 7.3 Relay (`relay/`)

| File | Perubahan |
| --- | --- |
| `lib/config.dart` | `RELAY_GOOGLE_CLIENT_ID` |
| `lib/db.dart` | Tabel `owner_identities` (aditif) |
| `lib/server.dart` | `POST /relay/auth/google`, verifikasi JWKS, rate limit |
| `.env.example` | Contoh variabel Google tanpa nilai rahasia |
| `README.md` | Dokumentasi endpoint + batasan |

## 8. Alur pekerjaan

### 8.0 Prinsip eksekusi

- Satu tahap = satu branch/PR. Jangan mencampur dua migrasi database dalam satu tahap.
- Urutkan **data dulu, UI kemudian**: skema + service + tes, baru layar.
- Setiap tahap harus meninggalkan aplikasi yang tetap bisa dipakai (tidak ada fitur
  setengah jadi yang terbuka untuk pengguna).
- Gerbang mutu setiap tahap:
  1. `dart analyze` bersih (bukan `flutter analyze` selama Developer Mode mati).
  2. `flutter test` hijau, termasuk tes migrasi dari DB v5.
  3. `flutter build web --release --dart-define-from-file=.env` berhasil.
  4. Smoke manual 3 peran (owner PIN, kasir, mekanik) pada build web.
  5. Tidak ada panggilan jaringan baru di jalur simpan nota/stok/struk.
- Data uji: gunakan DB dummy baru per tahap, bukan data kasir nyata.

### 8.1 Tahap 0 — Baseline & keputusan (0,5 hari)

Pekerjaan:
- Buat branch `fitur/tahap-…`; catat hasil `dart analyze` dan `flutter test` sebagai
  baseline.
- Simpan salinan DB v5 + backup ZIP untuk uji migrasi.
- Putuskan tiga hal yang memblokir tahap lain:
  1. Client ID Google (Android + web) dan siapa yang membuat proyek OAuth.
  2. Platform printer yang diuji lebih dulu (Android jaringan, lalu Bluetooth/USB).
  3. Kebijakan nomor nota lintas perangkat (renumber saat bentrok — default dokumen ini).

Kriteria selesai: keputusan tercatat di PR/issue; baseline tes terdokumentasi.

### 8.2 Tahap 1 — Fondasi: nomor nota numerik + identitas sesi (2–3 hari)

Pekerjaan:
- Migrasi DB v6: counter `nota_counters('NUMERIC')`, inisialisasi dari nomor tertinggi,
  tanpa mengubah nota lama (`app_database.dart:72,293-306,1262-1298`).
- Hapus pemakaian `device.nota_prefix` dari alokasi; pertahankan setting lama hanya untuk
  kompatibilitas.
- `note_sync.dart:349-390`: ganti suffix bentrok menjadi renumber angka berikutnya +
  catat `no_nota_asal` di `sync_conflicts`.
- Tulis `app.role='owner'` saat login owner; pilih `loginDevice` saat token perangkat ada;
  tambah cek premium di `loginHub` (`pin_gate.dart:31-155`, `account_service.dart:335-441`).
- Perbarui `test/note_sync_test.dart:136-137`, `test/business_rules_test.dart:338-399`;
  tambah tes serialisasi/paralel, VOID tidak dipakai ulang, migrasi v5→v6.

Kriteria selesai:
- Nota baru selalu `1,2,3,…`; tidak ada duplikat setelah 50 transaksi berurutan + restart.
- Nota `INV-…` lama tetap utuh; nomor baru melanjutkan dari angka tertinggi.
- Login owner/kasir/mekanik tidak berubah perilaku selain perbaikan di atas.

### 8.3 Tahap 2 — Garansi (2–3 hari)

Pekerjaan:
- Migrasi v7 bagian A: kolom garansi di `service_records` + `interval_servis_bulan` di
  `service_jobs`/`service_parts`.
- Logika: 1 bulan = 30 hari, `garansi_sampai`, status turunan, klaim sekali dengan update
  kondisional, tolak VOID/kedaluwarsa.
- UI: form POS (toggle, bulan, syarat, sparepart-only), badge + tombol Klaim di Riwayat,
  default garansi di Pengaturan.
- Tes: 30 hari, tanpa garansi, VOID, klaim ganda/paralel, tanggal klaim pertama menang.

Kriteria selesai: nota bergaransi menampilkan status benar; klaim kedua ditolak tanpa
mengubah data; nota lama tanpa kolom baru tetap terbaca (default aman).

### 8.4 Tahap 3 — Pengaturan struk + printer thermal (3–4 hari)

Dibagi tiga sub-tahap agar bisa diuji bertahap:

**3A — Renderer struk (tanpa hardware)**
- `receipt_settings.dart`: 25 toggle `receipt.*` di `app_settings`, default `"1"`.
- `receipt_service.dart`: teks 32/48 kolom, hormati toggle, VOID/retur/kredit, garansi.
- UI: `SectionCard` "Struk" di Pengaturan; pratinjau struk dari POS/Riwayat.
- Tes: default, toggle, teks WA, status bayar.

**3B — Konfigurasi printer + ESC/POS + jaringan**
- Model `PrinterConfig`, file `printer_config.json` di luar DB (tidak ikut backup/sync).
- `escpos_builder.dart`: init/align/bold/double/feed/cut, sanitasi ASCII, wrap 58/80.
- Adapter NETWORK (`Socket` port 9100), validasi IP/port, status SAVED/CONNECTED/ERROR.
- UI daftar printer + tes cetak.

**3C — Bluetooth/USB/system + uji perangkat** *(kode selesai, uji fisik belum)*
- Adapter Bluetooth SPP + BLE, USB OTG, dan cetak sistem/browser.
- Bridge native: `android/app/src/main/kotlin/com/pusatkupos/pusatkupos/printer/`
  (izin API 31+, SPP, USB BULK OUT, NSD, PDF Android Print).
- Uji cetak di perangkat nyata; catat merek/printer yang terbukti.
- Tes: encoder, validasi alamat, fallback error, layout 58/80.

Kriteria selesai: struk tercetak dari POS dan Riwayat di minimal satu printer jaringan;
toggle struk berlaku pada cetak dan teks WA; tidak ada dependensi printer di jalur nota.

### 8.5 Tahap 4 — Karyawan / komisi / gaji (4–6 hari)

Pekerjaan:
- Migrasi v8: kolom kompensasi di `employee_accounts`; tabel
  `service_record_mechanics`, `service_record_commissions`, `employee_debts`,
  `salary_payments`; `cashier_employee_id` di nota.
- Service: validasi, penugasan kasir/mekanik, hitung komisi (margin barang, jasa, rata/
  manual/override), payroll per siklus, hutang FIFO, satu gaji per siklus.
- UI: layar Karyawan (daftar, performa, komisi, gaji, hutang), penugasan di POS,
  rincian komisi di Riwayat, laporan laba setelah komisi/gaji.
- Tes: pembagian komisi, margin, siklus payroll, potong hutang, validasi gaji.

Kriteria selesai: nota dengan 2 mekanik menghasilkan pembagian benar; gaji kedua pada
siklus yang sama ditolak; laporan periode memakai tanggal bayar.

### 8.6 Tahap 5 — Supplier (2–3 hari)

Pekerjaan:
- Migrasi v7 bagian B (bisa digabung v7): `suppliers`, `supplier_items`,
  `supplier_followups`.
- Service: CRUD, nama unik, barang menipis/habis per supplier, status reseller.
- UI: layar Supplier + Follow up Reseller; pilih supplier di form stok; toggle fitur.
- Gating premium di service dan UI.

Kriteria selesai: barang menipis muncul di kartu supplier yang benar; supplier nonaktif
tidak dihitung; data supplier ikut backup dan (bila disiapkan) sync.

### 8.7 Tahap 6 — Follow-up + kuota (4–6 hari)

Pekerjaan:
- Migrasi v7 bagian C: `followup_items`, `followup_events`, `wa_message_logs`; counter
  `followup.wa_used` per toko.
- Generator item dari garansi, prospek, servis berkala, piutang, unit di bengkel; aturan
  dedupe/tunda/arsip; transisi 9 status; cooldown, jam, DNC, prioritas.
- Kuota: gratis 20 kredit, premium tanpa batas; potong hanya saat tautan dibuat.
- UI: layar Follow up (kartu + filter), aksi Ingatkan/WA/Detail/Status; pengaturan jam dan
  interval; tautan `wa.me` manual dengan masking nomor.
- Tes: kuota habis, cooldown, DNC, jam, merge pesan, auto-arsip, hasil follow-up.

Kriteria selesai: kuota ke-21 ditolak untuk gratis dan tidak bertambah setelah restart;
nota void/retur tidak menghasilkan item; unit yang belum diambil tidak masuk prospek.

### 8.8 Tahap 7 — Multi-toko (4–6 hari)

Pekerjaan:
- Migrasi v9: tabel `stores` + `active_store_id`; registry DB utama; file DB per toko.
- Refactor `AppDatabase` agar bisa `initForStore`/`switchStore`; tutup-buka koneksi;
  reload `AppState` dan semua layar.
- UI: Ganti toko di Menu **di atas Ringkasan**; hanya tampil bila >1 toko; blokir toko
  yang tidak ditugaskan untuk karyawan.
- Tambah toko hanya premium; seed identitas + `database_id` per toko.
- Mode ringkasan memuat daftar toko dari ringkasan owner (bukan hardcode `utama`).
- Tes: isolasi data antar toko, ganti toko berulang, backup/restore per toko, kios
  karyawan tidak bisa pindah toko.

Kriteria selesai: dua toko tidak berbagi pelanggan/nota/stok; ganti toko tidak kehilangan
data dan tidak meninggalkan koneksi DB lama terbuka.

### 8.9 Tahap 8 — Login Google premium (3–5 hari)

Pekerjaan relay lebih dulu:
- `RELAY_GOOGLE_CLIENT_ID`; tabel `owner_identities`; endpoint `POST /relay/auth/google`
  dengan verifikasi JWKS, `aud`, `iss`, `exp`, `sub`; rate limit; pengikatan `owner_id`
  hanya oleh admin setelah pembelian.

Lalu klien:
- `google_sign_in` di aplikasi utama + owner; alur aktivasi/pemulihan lisensi.
- Simpan hasil lewat `LicenseService.installToken`; sesi aplikasi tetap PIN.
- UI Premium: tombol Masuk dengan Google, status langganan, pesan bila belum premium.
- Tes: token invalid/kedaluwarsa/aud salah ditolak; pengguna gratis tidak mendapat
  lisensi; offline setelah aktivasi tetap membuka semua fitur yang sudah aktif.

Kriteria selesai: akun premium dapat memulihkan lisensi di perangkat baru; login Google
tidak pernah menjadi syarat membuat nota; relay lama tetap kompatibel.

### 8.10 Tahap 9 — Stabilisasi & rilis (3–4 hari)

Pekerjaan:
- Jalankan seluruh tes + matriks manual: offline, backup/restore, migrasi v5→v9 berurutan,
  ganti toko, 3 peran, printer, struk, kuota.
- Uji paritas dengan Python untuk uang, stok, nomor nota, void/retur, laporan, komisi.
- Audit keamanan singkat: token Google tidak di log, backup tidak memuat rahasia,
  `allowBackup=false`, relay hanya HTTPS di produksi.
- Perbarui README + dokumen ini; catat batasan yang tersisa.

Kriteria selesai: `flutter test` dan `dart analyze` hijau; build web dan APK debug berhasil;
checklist manual lolos; tidak ada regresi pada alur kasir offline.

### 8.11 Ketergantungan antar tahap

| Tahap | Bergantung pada | Alasan |
| --- | --- | --- |
| 1 Nota + sesi | — | Fondasi penomoran dan identitas |
| 2 Garansi | 1 | Menambah kolom di nota; butuh migrasi stabil |
| 3A Struk | 1, 2 | Struk menampilkan garansi/karyawan |
| 3B–3C Printer | 3A | Printer mengonsumsi renderer struk |
| 4 Karyawan/komisi | 1 | Nota butuh jejak kasir/mekanik |
| 5 Supplier | 1 | Relasi ke stok |
| 6 Follow-up | 2, 4, 5 | Sumber item: garansi, piutang, unit, servis berkala |
| 7 Multi-toko | 1–6 | Membungkus semua data per toko |
| 8 Google | 7 (opsional) | Lisensi/owner; bisa paralel setelah relay siap |
| 9 Stabilisasi | semua | Uji akhir |

### 8.12 Paralelisasi yang aman

- Satu orang: kerjakan berurutan 1 → 2 → 3A → 3B → 3C → 4 → 5 → 6 → 7 → 8 → 9.
- Dua orang: pemisahan hanya setelah migrasi tahap selesai — mis. orang A mengerjakan
  3A/3B (renderer/printer) sementara orang B mengerjakan 4 (karyawan) **di branch
  berbeda**, lalu migrasi digabung berurutan (v7, v8) untuk menghindari konflik nomor versi.
- Jangan memparalelkan dua tahap yang sama-sama menaikkan `version` database.

### 8.13 Definisi selesai (per tahap)

- Kode + migrasi + tes lulus; tidak ada TODO menggantung di jalur utama.
- UI berbahasa Indonesia dan mengikuti pola `SectionCard`/filter yang ada.
- Fitur premium digerbang di service **dan** UI.
- Data baru ikut backup; tabel bisnis baru terdaftar di snapshot/sync.
- Catatan perubahan singkat ditambahkan ke README fitur terkait.

### 8.14 Titik henti (stop/go)

- **Setelah Tahap 1:** review penomoran dan migrasi sebelum fitur lain menumpuk.
- **Setelah Tahap 3A:** setujui tampilan struk sebelum membeli/menguji printer.
- **Setelah Tahap 6:** uji follow-up dengan data dummy nyata sebelum multi-toko.
- **Sebelum Tahap 7:** putuskan apakah multi-toko jadi di rilis ini; refactor DB paling
  berisiko.
- **Sebelum Tahap 8:** client ID Google dan alur pembelian langganan harus sudah jelas.

Perkiraan total untuk satu pengembang: **±4–6 minggu** (multi-toko dan Google adalah
penentu utama); dua pengembang dengan pembagian di 8.12: **±3–4 minggu**.

## 9. Risiko dan keputusan terbuka

- **Nomor nota lintas perangkat:** angka murni + offline tidak bisa menjamin unik lintas
  perangkat sebelum sinkron; solusi saat ini adalah renumber saat bentrok. Bila Anda
  menuntut nomor tidak pernah berubah antar perangkat, perlu alokasi blok dari relay
  (keputusan terpisah).
- **Google login di Windows/macOS:** `google_sign_in` resmi berfokus Android/iOS/web;
  Windows butuh loopback OAuth manual. Perlu keputusan platform mana yang didukung lebih
  dulu.
- **Sumber langganan:** rencana ini mengasumsikan pembelian/aktivasi dilakukan di luar
  aplikasi (admin/relay). Play Billing tidak termasuk.
- **Printer fisik:** adapter SPP/BLE/USB/system sudah ada, tetapi merek/koneksi harus
  diuji di perangkat Android nyata. BLE hanya untuk printer GATT yang menyediakan
  karakteristik tulis; printer vendor dengan protokol khusus tetap di luar cakupan.
- **Multi-toko:** mengubah siklus hidup `AppDatabase`; semua layar harus diuji ulang
  setelah ganti toko, termasuk backup, sync, dan lisensi.
- **Migrasi data uji:** nota `DEMO-0001/0002` dan nota `INV-…` lama tetap ada; nomor
  numerik baru mulai setelah nomor angka tertinggi. Bila Anda ingin semua nota lama
  dinomori ulang, itu migrasi terpisah yang mengubah nomor tercetak.
- **Kuota follow-up:** dihitung per toko; memindahkan/menyalin DB dapat menyalin counter.
  Ini disengaja agar gratis tidak bisa diakali dengan ganti perangkat.
