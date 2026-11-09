# 08 — AUDIT ALUR APLIKASI

**Cakupan:** startup, gerbang masuk, onboarding, shell utama, alur simpan nota, pengaturan, pindah toko, dan desinkronisasi state UI ↔ database.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Peta Alur Startup

```
main()
  ├─ WidgetsFlutterBinding.ensureInitialized()
  ├─ initializeDateFormatting('id_ID')
  ├─ AppDatabase.instance.init()
  │    ├─ buka database (SQLCipher/SQLite)
  │    ├─ baca .schema_version
  │    ├─ _rejectIncompatibleVersion
  │    ├─ _prepareSchemaUpgrade / migrasi
  │    └─ createOperationalSchema
  ├─ seedDummyDataIfEnabled()
  ├─ AppState.instance.load()
  ├─ BackupScheduler.instance.start()
  ├─ SyncScheduler.instance.start()
  └─ runApp(PusatkuApp())
```

**Tidak ada** `try/catch`, `runZonedGuarded`, error boundary, atau layar pemulihan. Kegagalan pada salah satu langkah menghentikan `main` sebelum `runApp`; layar kosong atau aplikasi tertutup.

### FLW-01 — Startup tanpa penanganan kegagalan (HIGH)

**Penyebab umum:**
- file database rusak;
- `.schema_version` lebih baru dari aplikasi;
- restore terputus;
- seed dummy gagal;
- secure storage tidak tersedia.

**Dampak.** Pengguna kehilangan akses ke pembukuan tanpa instruksi. Risiko pengguna menghapus data untuk “memperbaiki”.

**Perbaikan.** Bungkus inisialisasi dengan error boundary; tampilkan layar pemulihan (restore, ekspor diagnostik, mode aman); jangan hapus database otomatis.

---

## 2. Gerbang Masuk dan Onboarding

### 2.1 EntryGate

```
EntryGate.build
  ├─ SessionService.load()
  ├─ jika profil null tetapi PIN terkonfigurasi:
  │    └─ sintesis SessionProfile(role: 'owner', nama: 'Pemilik')   ← SEC-09
  ├─ jika belum onboarding → OnboardingScreen
  └─ jika sudah → HomeShell(operator: ...)
```

### 2.2 SEC-09 — Sesi hilang disintesis menjadi owner

`EntryGate._load`:

```dart
if (profile == null && AppState.instance.pinConfigured) {
  final ownerId = await LicenseService.instance.ownerId() ?? '';
  profile = SessionProfile(
    mode: premium ? 'premium' : 'free',
    ownerId: ownerId,
    nama: 'Pemilik',
    role: 'owner',
    ...
  );
}
```

PIN karyawan disimpan di guard yang sama (`auth.pin_hash`/`session.pin_*`). Jika file sesi hilang (bukan sign-out), karyawan memasukkan PIN-nya dan masuk sebagai “Pemilik”.

**Dampak.** Eskalasi hak akses tanpa kredensial owner; aksi tercatat atas nama Pemilik.

### 2.3 SEC-01 — Sign-out lalu onboarding

`signOutToOnboarding`:

- menghapus sesi;
- menghapus PIN;
- menghapus `owner.enroll_token`;
- **tidak** menghapus database atau `owner_identity`.

Onboarding `_startFree` memanggil `LicenseService.ensureOwner()`, yang mengembalikan owner yang sudah ada, lalu meminta PIN baru dan menyimpan sesi owner.

**Skenario.** Karyawan menekan “Keluar”, memilih “Mulai gratis”, membuat PIN baru → akses owner penuh ke seluruh pembukuan.

**Dampak.** Pengambilalihan penuh oleh pemegang perangkat.

### 2.4 Onboarding normal

`_finish`:

1. `PinService.setup(pin)`;
2. `SessionService.save(profile)`;
3. buka HomeShell.

Tidak ada verifikasi bahwa PIN memenuhi panjang minimum selain validasi UI; `PinService.verify` masih menerima PIN legacy/pendek (SEC-06).

---

## 3. Shell Utama

### 3.1 HomeShell

```dart
Operator get _operator => AppState.instance.operator ?? Operator.owner;
```

**SEC-05.** Jika operator belum dimuat atau sesi rusak, UI menganggap pengguna owner dan menampilkan seluruh menu. Aktor yang diteruskan ke service juga owner.

**Skenario.** `AppState.load()` gagal atau sesi kosong sementara; HomeShell tetap dirender dengan `_operator = Operator.owner`; pengguna dapat membuka menu owner dan menjalankan aksi yang memakai aktor itu.

### 3.2 Feature gating di UI

`_featureAllows` hanya menangani indeks menu 5, 8, 9. Fitur `estimasi`, `order_kerja`, `followup`, `unit_kendaraan`, dan `whatsapp` tidak semuanya diperiksa di service (FEAT-01).

**FEAT-02.** Sebelum `load()` atau saat toko aktif berubah, `isEnabled` mengembalikan `defaultEnabled` (true). Fitur yang seharusnya OFF dianggap ON sesaat.

### 3.3 Aksi owner tanpa guard

- Ekspor ringkasan owner tanpa cek izin (SEC-08).
- Menu pengaturan dapat dibuka oleh peran yang tidak seharusnya; service tertentu tidak memeriksa aktor (SEC-02/03/04).

---

## 4. Alur Simpan Nota

```
Kasir mengisi item
  ├─ validasi UI (qty, harga, pelanggan)
  ├─ tekan Simpan
  ├─ _createWithApproval
  │    ├─ (opsional) dialog approval owner
  │    └─ AppDatabase.createTransaction
  ├─ recordDetail(id)
  ├─ _showReceipt(detail)
  └─ catch → showSnack('Gagal menyimpan: $error')
```

### 4.1 FLW-02 — Pesan salah setelah simpan

`try` mencakup simpan **dan** muat detail/struk. Jika nota berhasil disimpan tetapi `recordDetail`/cetak gagal, kasir melihat “Gagal menyimpan” dan mengulang. Idempotensi mengembalikan nota lama, tetapi kasir dapat mengira transaksi belum tercatat.

**Perbaikan.** Pisahkan `try` simpan dan struk; pesan setelah simpan sukses harus “Nota tersimpan, struk gagal dibuka” dengan tombol cetak ulang.

### 4.2 Double tap

Tombol simpan tidak selalu dinonaktifkan setelah ditekan. `request_id` mencegah duplikasi, tetapi payload baru dengan `request_id` lama tidak diverifikasi (BIZ-01). UI dapat menampilkan sukses untuk transaksi lama.

### 4.3 Validasi UI vs service

- Harga jasa bebas hanya divalidasi UI (SAL-03).
- Kredit tidak memeriksa izin/jatuh tempo/limit (SAL-04).
- Jatuh tempo hanya dikirim jika dipilih (SAL-04).
- Viewer dapat menekan aksi yang secara service diizinkan karena `Permissions.can` tidak menolak viewer (SEC-07).

**Prinsip:** validasi UI tidak boleh menjadi satu-satunya kontrol. Setiap aturan harus ditegakkan di service.

---

## 5. Pengaturan dan Restore

### 5.1 SettingsScreen

- Backup/restore UI.
- Ekspor ringkasan owner (tanpa guard, SEC-08).
- Manajemen modul dan fitur (owner-only).
- Pindah toko.

### 5.2 Restore

`_restore` memanggil `BackupService.restoreBackup` tanpa menghentikan sync/backup scheduler (BAK-01). Database ditutup dan diganti saat proses lain berjalan.

### 5.3 Pindah toko

`StoreService.switchStore` memanggil `AppDatabase.switchStore`, yang menutup database lalu membuka path toko baru (DB-08). Tidak ada pemeriksaan `SyncService.isSyncing`.

**Skenario.** Sync toko A sedang menerapkan nota; owner pindah ke toko B → database A ditutup di tengah transaksi; sync gagal/parsial; data dapat tertulis ke toko B.

---

## 6. State UI dan Database

| Kejadian | State UI | Database | Risiko |
|---|---|---|---|
| Startup gagal | Tidak ada layar | Mungkin valid | FLW-01/FLW-03 |
| Sesi hilang | Owner sintetis | Tetap | SEC-09 |
| Operator null | Owner fallback | Tetap | SEC-05 |
| Simpan nota sukses, struk gagal | “Gagal menyimpan” | Nota tersimpan | FLW-02 |
| Restore selesai | Data lama mungkin masih tampil | Database baru | Tidak ada refresh eksplisit |
| Pindah toko saat sync | Toko B tampil | Koneksi A ditutup | DB-08 |
| Feature OFF | Menu disembunyikan | Service masih menulis | FEAT-01 |
| Flag belum dimuat | Fitur tampil ON | Bisa menulis | FEAT-02 |

**Kesimpulan.** UI dan database tidak memiliki satu state machine yang jelas. Banyak keputusan bergantung pada urutan pemuatan dan fallback, bukan pada status otoritatif.

---

## 7. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| FLW-01 | Startup tanpa penanganan kegagalan | HIGH | CONFIRMED | `main.dart:1-25` |
| FLW-02 | Kegagalan struk dilaporkan sebagai gagal simpan | LOW | CONFIRMED | `pos_screen.dart:487-530` |
| FLW-03 | Tidak ada pemulihan database rusak | MEDIUM | CONFIRMED | `app_database.dart:301-343,345-378`; `entry_gate.dart` |
| SEC-01 | Sign-out lalu onboarding takeover | CRITICAL | CONFIRMED | `entry_gate.dart:74-96`; `onboarding.dart:96-107,323-358` |
| SEC-05 | Fallback `Operator.owner` | HIGH | CONFIRMED | `home_shell.dart:273-289` |
| SEC-09 | Sesi hilang disintesis owner | HIGH | CONFIRMED | `entry_gate.dart:31-44` |
| FEAT-01 | Hanya pembelian menegakkan flag di service | HIGH | CONFIRMED | `feature_flags.dart:137-152`; `purchase_service.dart:97` |
| FEAT-02 | Cache flag fallback true | MEDIUM | CONFIRMED | `feature_flags.dart:100-110` |
| BAK-01 | Restore saat scheduler aktif | HIGH | CONFIRMED | `settings_screen.dart:372-425` |
| DB-08 | Pindah toko saat sync | HIGH | CONFIRMED | `store_service.dart:137-163` |

---

## 8. Skenario Ujung-ke-Ujung

### 8.1 Pengguna baru (happy path)

1. Onboarding → `ensureOwner` → PIN → sesi.
2. HomeShell dengan owner.
3. Buat nota → simpan → struk.
4. Backup otomatis.
5. Sync.

**Gangguan yang mungkin:** startup gagal (FLW-01), PIN lemah (SEC-06), struk gagal (FLW-02), backup tidak konsisten (BAK-02).

### 8.2 Karyawan keluar perangkat

1. Karyawan menekan “Keluar”.
2. Onboarding menawarkan “Mulai gratis”.
3. Karyawan membuat PIN baru → owner.
4. Akses penuh ke payroll, backup, ekspor.

**Perbaikan.** Sign-out harus meminta PIN owner atau mengunci/menghapus database; onboarding harus mendeteksi `owner_identity` dan meminta kredensial owner.

### 8.3 Restore setelah perangkat hilang

1. Pengguna memasang aplikasi di perangkat baru.
2. Restore backup.
3. Snapshot/backup tidak memuat `cash_ledger`/`opname_holds` (DB-01) dan versi tidak diketahui (DB-02/04).
4. Laporan kas kosong; opname hilang; kemungkinan error skema.

### 8.4 Owner mematikan fitur

1. Owner mematikan “Estimasi”.
2. Menu hilang.
3. Layar lain masih memanggil `createEstimate` karena service tidak memeriksa flag (FEAT-01).
4. Data estimasi baru tetap masuk; laporan tidak dapat memisahkan periode.

### 8.5 Pindah toko saat sync

1. Sync A berjalan.
2. Pindah ke B → database A ditutup (DB-08).
3. Sync gagal/parsial; outbox tidak konsisten.

---

## 9. Rekomendasi Alur

1. **State machine aplikasi:** `starting`, `unauthenticated`, `ready`, `recovering`, `restoring`, `switching_store`. UI hanya dirender sesuai state.
2. **Error boundary startup** dan layar pemulihan.
3. **Hapus fallback owner**; operator null = tidak terautentikasi.
4. **Sign-out aman:** minta PIN owner atau kunci database.
5. **Sinkronisasi state setelah restore/pindah toko:** muat ulang operator, fitur, pengaturan, dan daftar.
6. **Blokir aksi saat restore/switch.**
7. **Tegakkan fitur di service**, bukan hanya menu.
8. **Pisahkan pesan simpan dan struk.**

---

## 10. Ringkasan

- Alur utama (onboarding → nota → backup → sync) dapat berjalan, tetapi **tidak memiliki penanganan kegagalan terpusat**.
- Tiga jalur eskalasi (SEC-01/05/09) membuat kontrol akses bergantung pada state yang dapat hilang.
- Restore dan pindah toko adalah operasi global yang tidak diblokir terhadap proses lain.
- Perbaikan alur harus dimulai dari state machine dan error boundary, bukan menambal pesan per layar.
