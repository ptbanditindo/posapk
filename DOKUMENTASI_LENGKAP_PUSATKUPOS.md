# Dokumentasi Lengkap PusatkuPOS

Dokumen gabungan dari empat dokumen proyek PusatkuPOS. Isi tiap bab dipertahankan
utuh; hanya tingkat judul yang disesuaikan agar hierarki dokumen konsisten.

- **Tanggal gabung:** 7 November 2026
- **Aplikasi:** PusatkuPOS (Flutter offline-first) + relay Dart/PostgreSQL
- **Cakupan:** peta kode dan dependensi, audit logika bisnis, laporan perbaikan,
  serta laporan test end-to-end (relay dan aplikasi).

> Catatan penomoran: tiap bab memakai penomoran bagian aslinya. Rujukan seperti
> "lihat bagian 7" mengacu pada bagian di dalam bab yang sama.

## Daftar isi

- **Bagian I — Peta Kode, Dependensi, dan Logika Bisnis**
  - 0. Cara membaca dokumen ini
  - 1. Arsitektur dalam satu gambar
  - 2. Titik masuk dan siklus hidup aplikasi
  - 3. Peta file per lapisan
  - 4. Graf ketergantungan (siapa memakai siapa)
  - 5. Alur data ujung-ke-ujung
  - 6. Logika bisnis per domain
  - 7. Rumus dan invarian kunci
  - 8. Catatan teknis hasil pembacaan kode
  - 9. Checklist cakupan file
- **Bagian II — Audit Logika Bisnis, Kelengkapan, dan Alur Operasional**
  - 1. Ringkasan Eksekutif
  - 2. Daftar Temuan P1
  - 3. Detail Temuan P1
  - 4. Temuan P2
  - 5. Temuan P3 dan Catatan Kecil
  - 6. Matriks Kelengkapan: Flutter vs Python Bengkel
  - 7. Urutan Operasional Baku (dari Menambah Pelanggan)
  - 8. Rekomendasi Urutan Perbaikan (menunggu perintah “mulai”)
  - 9. Cakupan File yang Dibaca
  - 10. Log Perbaikan
- **Bagian III — Laporan Perbaikan dan Audit Menyeluruh**
  - 1. Ringkasan
  - 2. Metode dan Batas Audit
  - 3. Peta Kode
  - 4. Temuan Audit dan Perbaikan
  - 5. Pekerjaan yang Sudah Selesai
  - 6. Skema Akhir (versi 2)
  - 7. Alur Akhir
  - 8. Fitur Struk yang Sudah Dibangun
  - 9. Keputusan Desain
  - 10. Verifikasi
  - 11. Kriteria Lulus Audit Perbaikan
  - 12. Lampiran
- **Bagian IV — Laporan Test End-to-End PusatkuPOS + Relay**
  - 1. Ringkasan
  - 2. Lingkungan pengujian
  - 3. Hasil relay E2E
  - 4. Hasil aplikasi mode offline (localhost)
  - 5. Hasil aplikasi mode online (relay lokal)
  - 6. Unggah ulang backup/snapshot (permintaan terakhir)
  - 7. Kecacatan logika
  - 8. Bug
  - 9. Kendala, gap produk, dan observasi
  - 10. Cara reproduksi
  - 11. Artefak
  - 12. Prioritas tindak lanjut
  - 13. Uji peran kustom dan pembatasan akses (06 Nov 2026)

---

# Bagian I — Peta Kode, Dependensi, dan Logika Bisnis

Dibuat: 5 November 2026
Repo: `D:\Downloads\posapk-main\posapk-main`
Cakupan: 185 file teks — 132 file Dart (`pusatkupos/lib`, `relay/lib|bin|tool`), Kotlin/Gradle/manifest Android, Windows C++/CMake, web, pubspec, env, README, dan dokumen audit. Dua belas aset biner (10 PNG, 1 ICO, 1 WASM) dan satu service worker hasil build (`web/sqflite_sw.js`) tidak dipetakan isinya.
Catatan: seluruh folder `test/` sudah dihapus; dokumen ini tidak memuat test.
Penyempurnaan tanpa fitur baru C-01–C-06 (refund retur, passphrase, duplikasi SQL,
batas relay, portabilitas skrip) tercatat pada §8 butir 2, 8, 15, dan 16.

---

### 0. Cara membaca dokumen ini

- Path selalu relatif terhadap root repo.
- Arah panah `A → B` berarti **A memakai/memanggil B**.
- "Dipakai oleh" adalah kebalikan dari import/call dan sudah diverifikasi lewat pencarian impor.
- Bagian 3 memetakan tiap file; bagian 4 merangkum graf; bagian 5 menelusuri alur data ujung-ke-ujung; bagian 6 menjelaskan aturan bisnis; bagian 7 memuat rumus/invarian; bagian 8 memuat catatan teknis; bagian 9 membuktikan cakupan file.

---

### 1. Arsitektur dalam satu gambar

```text
┌──────────────────────────── pusatkupos (Flutter) ────────────────────────────┐
│                                                                              │
│  main.dart                                                                   │
│    ├─ AppDatabase.instance.init()        → SQLite/SQLCipher + registry toko   │
│    ├─ seedDummyDataIfEnabled()           → data demo (dev saja)              │
│    ├─ AppState.instance.load()           → identitas toko, sesi, tema        │
│    ├─ BackupScheduler.start()            → backup harian saat app terbuka    │
│    └─ SyncScheduler.start()              → sync berkala 10–20 menit          │
│                                                                              │
│  app.dart → EntryGate                                                        │
│    ├─ belum ada sesi  → OnboardingFlow (gratis / Google / karyawan / viewer) │
│    └─ sudah ada sesi  → PinGate → HomeShell (owner/karyawan)                 │
│                                 └→ OwnerViewerShell (ringkasan read-only)    │
│                                                                              │
│  ui/screens/* ──► data/*Service ──► AppDatabase.instance.db (SQLite)          │
│       │                 │                                                     │
│       │                 └─► SyncService.enqueue*() ─► sync_outbox (SQLite)   │
│       │                                                                       │
│       └─► printer/PrinterService ─► adapter BT/BLE/USB/network/system/web    │
│                                                                              │
│  SyncScheduler/SyncService.syncNow()                                          │
│       ├─ push: sync_outbox → protocol.buildEnvelope → RelayClient             │
│       └─ pull: RelayClient.feed → protocol.verifyEnvelope → note_sync/apply   │
│                                    → SQLite + applied_deltas + sync_cursor    │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ HTTPS (JSON)
┌──────────────────────────────────▼───────────────────────────────────────────┐
│ relay (Dart Shelf + PostgreSQL)                                              │
│  bin/relay.dart → server.dart → db.dart → PostgreSQL                         │
│  license.dart (Ed25519 token), google.dart (ID token), sync_round.dart       │
│  auth_rules.dart (izin entity), canonical.dart (JSON kanonik)                │
└──────────────────────────────────────────────────────────────────────────────┘
```

Dua paket Dart terpisah:

| Paket | Isi | Peran |
|---|---|---|
| `pusatkupos/` | Aplikasi Flutter offline-first | Kasir, stok, payroll, laporan, cetak, backup, sinkron |
| `relay/` | Server Dart Shelf + PostgreSQL | Login akun, lisensi, log amplop terenkripsi, snapshot, rekonsiliasi |

---

### 2. Titik masuk dan siklus hidup aplikasi

1. `main.dart` memanggil `WidgetsFlutterBinding.ensureInitialized()`, memasang locale `id_ID`, lalu `AppDatabase.instance.init()`.
2. `init()` membuka `registry.db`, menentukan toko aktif, membuka database toko (SQLCipher di Android/iOS/macOS), menjalankan migrasi skema v2/v3.
3. `seedDummyDataIfEnabled()` hanya berjalan bila build dummy diaktifkan (mode uji lokal).
4. `AppState.instance.load()` membaca nama/alamat toko, tema, auto-lock, status PIN, dan sesi tersimpan.
5. `BackupScheduler.start()` dan `SyncScheduler.start()` memasang timer; sync hanya aktif bila lisensi premium, URL relay, device id, dan token tersedia.
6. `app.dart` merender `MaterialApp` dengan tema dari `AppState` dan `home: EntryGate`.
7. `EntryGate` memilih `OnboardingFlow` atau `PinGate`. `PinGate` memverifikasi PIN (`PinService.verifyDetailed`) lalu membangun `Operator` dari `SessionProfile` dan mengarahkan ke `HomeShell` atau `OwnerViewerShell`.
8. `HomeShell` menyaring menu berdasarkan izin operator, memasang timer idle auto-lock, dan memuat layar secara lazy per `storeRevision`.
9. Logout memanggil `EntryGate.signOutToOnboarding()`: menghapus sesi, PIN, token perangkat, kunci perangkat, dan identitas relay.

---

### 3. Peta file per lapisan

#### 3.1 `pusatkupos/lib/core` — primitif lintas lapisan (11 file)

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `core/app_config.dart` | 16 | URL layanan dari `--dart-define=PUSATKU_SERVICE_URL`; `serviceConfigured`, `normalizedServiceUrl` | — | `employee_auth_service`, `followup_service`, `google_auth_service`, `sync_scheduler`, `sync_service`, `owner_viewer`, `onboarding` |
| `core/dates.dart` | 26 | Format tanggal Indonesia, `nowIso`, `todayKey`, awal/akhir hari, konversi UTC | `intl` | hampir semua service data/sync dan layar UI |
| `core/ids.dart` | 37 | `newNotaPrefix`, kode perangkat 3 huruf, `newSyncId` (waktu + acak, Crockford base32) | `dart:math` | service data, sync, seed, registry |
| `core/money.dart` | 88 | Parse/format rupiah → sen; tolak negatif; `clampNonNegative` | `intl` | `price_rules`, `app_database`, `models` (tidak langsung), UI, struk |
| `core/phone.dart` | 18 | Normalisasi nomor (`+62`/`62`/`8…` → `0…`), escape `LIKE` | — | `app_database`, `supplier_service`, `followup_service` |
| `core/quantity.dart` | 50 | Format/parse kuantitas milli (1/1000), 0–3 desimal | — | `models`, `sale_return_service`, layar stok/estimasi/riwayat/POS |
| `core/relay_url.dart` | 28 | Validasi URL relay: wajib `https`, `http` hanya loopback | — | `relay_client`, `sync_service`, `pairing_service`, `employee_auth_service`, `owner_access_api` |
| `core/summary_file_io.dart` | 9 | Baca file ringkasan dari path (native) | `dart:io`, `file_picker` | `owner_viewer` (via stub/conditional) |
| `core/summary_file_stub.dart` | 5 | Fallback non-native: selalu `UnsupportedError` | `file_picker` | `owner_viewer` |
| `core/summary_file_web.dart` | 7 | Baca file ringkasan dari byte (web) | `dart:convert`, `file_picker` | `owner_viewer` |
| `core/wa_link.dart` | 23 | Mask nomor, validasi WhatsApp, buat `wa.me` + teks terenkode | `phone.dart` | `followup_service`, layar follow-up |

#### 3.2 `auth`, `state`, `dev`, dan akar `lib` (6 file)

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `lib/main.dart` | 20 | Bootstrap DB, seed, state, scheduler, `runApp` | `app`, `app_database`, `backup_scheduler`, `dummy_seed`, `app_state`, `sync_scheduler` | titik masuk (`flutter run`) |
| `lib/app.dart` | 26 | `MaterialApp`, tema, `EntryGate` | `app_state`, `entry_gate`, `theme` | `main.dart` |
| `auth/operator.dart` | 52 | Operator owner/karyawan: peran, izin, `isOwner`, `canWriteMoney`, `can()` | — | `permissions`, `app_state`, `session_service`, service data, UI |
| `auth/permissions.dart` | 30 | Konstanta izin (`void`, `diskon`, `ubah_stok`, …) + `can/require` | `operator.dart` | `app_database`, `sale_return_service`, layar riwayat/stok/POS |
| `state/app_state.dart` | 95 | `ChangeNotifier` global: identitas toko, operator, tema, auto-lock, `revision`/`storeRevision` | `operator`, `app_database`, `pin_service` | `main`, `entry_gate`, `home_shell`, `onboarding`, `pin_gate`, hampir semua layar |
| `dev/dummy_seed.dart` | 448 | Seed owner `OWNERDUMMY`, 4 akun demo, pelanggan/unit/stok/jasa/nota demo | `dates`, `ids`, `app_database`, `secure_store`, `sync/crypto` | `main.dart` (hanya build dev) |

#### 3.3 `pusatkupos/lib/data` — domain & persistensi (39 file)

##### 3.3.1 Inti database, skema, dan model

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/app_database.dart` | 3055 | Gateway tunggal SQLite: lifecycle/enkripsi, setting, master data, stok, transaksi, pembayaran, void, retur/koreksi (hitung ulang), laporan, nomor dokumen, HLC, helper SQL `latestAdjustmentTotalSql`/`recordModalSql` | `operator`, `permissions`, `dates`, `ids`, `money`, `phone`, `sync/crypto`, `approval_service`, `models`, `price_rules`, `schema`, `secure_store`, `store_settings`, `store_registry` | 25+ service data, `main`, `sync/*`, `app_state`, `printer_config`, `dummy_seed`, hampir semua layar |
| `data/schema.dart` | 1017 | DDL skema bersih, tabel retur, migrasi aditif v2/v3 | `sqflite` | `app_database` |
| `data/models.dart` | 644 | DTO baris SQL: `Customer`, `VehicleUnit`, `StockItem`, `ServiceCatalog`, `ServiceRecordSummary`, `JobDraft`, `PartDraft`, `SaleReturn*`, `CommissionRow`, `RecordDetail`, `ReportSummary`, `EstimateAgingRow`, `DashboardData` | `dates`, `quantity` | `app_database`, `note_sync`, `order_service`, `receipt_service`, `sale_return_service`, `sync_service`, UI |
| `data/price_rules.dart` | 253 | Satu sumber matematika harga: `PriceLine`, alokasi diskon proporsional, batas modal, validasi koreksi | `core/money.dart` | `app_database`, `nota_adjustment_service`, `order_service`, layar riwayat |

##### 3.3.2 Siklus nota, retur, koreksi, dan sinkronisasi nota

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/sale_return_service.dart` | 373 | Retur per baris: validasi sisa qty, refund proporsional, restock, refund kas dibatasi kas diterima (`max(0, dibayar - max(0, total_efektif - retur))`), hitung ulang total/komisi, audit | `operator`, `permissions`, `dates`, `ids`, `quantity`, `app_database`, `models`, `store_settings` | layar riwayat |
| `data/nota_adjustment_service.dart` | 303 | Koreksi nilai append-only; `selisih = nilaiBaru - total saat ini`; validasi modal; approval; `applyRemote` idempoten | `operator`, `dates`, `ids`, `app_database`, `approval_service`, `price_rules`, `store_settings` | `sync_service`, layar riwayat |
| `data/note_sync.dart` | 1022 | Payload nota lengkap (pelanggan, unit, jasa, part, bayar, retur, snapshot stok) + penerapan remote idempoten | `app_database`, `models`, `dates`, `ids`, `sync/sync_conflict_rules` | `sync_service` |

##### 3.3.3 Estimasi dan work order

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/order_service.dart` | 1027 | Estimasi berversi (revisi append-only), konversi ke nota, work order + nomor antrian + log status + varians | `operator`, `dates`, `ids`, `money`, `app_database`, `approval_service`, `models`, `price_rules`, `store_settings` | layar estimasi, order, POS |

##### 3.3.4 Akun, PIN, persetujuan, sesi

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/account_service.dart` | 608 | Peran KASIR/MEKANIK/KEDUANYA, matriks izin, PBKDF2 600k, login hub/lokal/perangkat, audit izin | `operator`, `dates`, `ids`, `app_database`, `license_service`, `login_guard` | `employee_auth_service`, `pairing_service`, `sync_service`, onboarding, viewer, POS, premium, store settings |
| `data/approval_service.dart` | 143 | Persetujuan harga/diskon di bawah batas: PIN owner atau karyawan penanggung jawab | `app_database`, `login_guard`, `pin_service`, `store_settings` | `app_database`, `nota_adjustment_service`, `order_service` |
| `data/login_guard.dart` | 71 | Lockout login per scope: 5 gagal, backoff eksponensial 30–3600 detik | `app_database` | `account_service`, `approval_service`, `pin_service` |
| `data/pin_service.dart` | 175 | PIN owner PBKDF2 600k, migrasi PIN lama SHA-256, lockout | `app_database`, `login_guard`, `session_service` | `approval_service`, `app_state`, `entry_gate`, onboarding, `pin_gate`, settings |
| `data/session_service.dart` | 213 | Profil sesi (free/premium/employee/viewer), pemetaan ke `Operator`, token perangkat | `operator`, `sync_secrets`, `app_database`, `secure_store` | `employee_auth`, `pin_service`, `entry_gate`, `home_shell`, onboarding, viewer, `pin_gate` |
| `data/secure_store.dart` | 50 | Bungkus `flutter_secure_storage`; rahasia tidak pernah ke `app_settings` | `flutter_secure_storage` | `app_database`, `session_service`, `pin_service`, perangkat, lisensi, backup, pairing |

##### 3.3.5 Perangkat, lisensi, pairing, dan login

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/device_service.dart` | 143 | Registrasi perangkat (wajib premium), hash token, cabut perangkat + bersihkan kunci | `app_database`, `license_service`, `secure_store`, `dates`, `ids`, `sync/crypto`, `sync_secrets` | `owner_summary_service`, `sync_service`, viewer, premium |
| `data/license_service.dart` | 221 | Identitas owner, kode pemulihan, token lisensi server, cache claims, status premium | `app_database`, `license_verifier`, `secure_store`, `dates`, `sync/crypto` | akun, perangkat, login, follow-up, Google, owner API, ringkasan, pairing, toko, sync, UI |
| `data/license_verifier.dart` | 109 | Verifikasi Ed25519 token lisensi; `LicenseClaims.premium`; trusted signer | `sync/crypto` | `license_service`, `pairing_service`, `sync_service`, viewer |
| `data/pairing_service.dart` | 173 | Klaim kode undangan: pin kunci owner, verifikasi izin, pasang akun + perangkat + lisensi | `account_service`, `app_database`, `license_service`, `license_verifier`, `secure_store`, `dates`, `ids`, `relay_url`, `sync/crypto`, `relay_client`, `sync_secrets` | onboarding |
| `data/google_auth_service.dart` | 136 | Google Sign-In → `googleLogin` relay → pasang owner/lisensi | `app_database`, `license_service`, `app_config`, `relay_client` | onboarding, premium |
| `data/employee_auth_service.dart` | 289 | Login karyawan via relay (atau lokal dummy), pakai ulang kunci perangkat, bangun sesi | `account_service`, `app_database`, `license_service`, `secure_store`, `session_service`, `app_config`, `dummy_seed`, `sync/crypto`, `relay_client`, `sync_secrets` | onboarding |
| `data/owner_access_api.dart` | 225 | Klien HTTP owner/viewer: akun, undangan, perangkat, cabut, tanda tangan izin | `license_service`, `secure_store`, `dates`, `ids`, `relay_url`, `sync/crypto` | viewer, premium |
| `data/owner_summary_service.dart` | 88 | Ringkasan owner bertanda tangan Ed25519 untuk perangkat viewer | `app_database`, `device_service`, `license_service`, `secure_store`, `store_service`, `dates`, `sync/crypto` | layar settings |

##### 3.3.6 Multi-toko, backup, dan pengaturan toko

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/store_registry.dart` | 227 | `registry.db`: daftar toko → file DB, toko aktif; `replaceAll` saat restore | `core/dates.dart` | `app_database`, `backup_service`, `store_service`, `home_shell`, layar toko, store switcher |
| `data/store_service.dart` | 187 | Daftar/buat/ganti toko; gate premium + `store_limit` + akun Google; web memakai toko sintetis | `app_database`, `license_service`, `store_platform_*`, `store_registry`, `dates`, `ids` | `owner_summary_service`, `home_shell`, layar toko |
| `data/store_platform_io.dart` | 8 | Pastikan direktori DB toko ada; cek file | `dart:io` | `store_service` (conditional import) |
| `data/store_platform_stub.dart` | 3 | Stub web: direktori no-op, file dianggap ada | — | `store_service` (conditional import) |
| `data/store_settings.dart` | 481 | Jenis transaksi, tahap order, preset, mode persetujuan, izin per peran, transisi status; last-writer-wins | `app_database`, `operator`, `dates`, `ids` | `app_database`, approval, koreksi, order, struk, retur, sync, layar terkait |
| `data/backup_service.dart` | 1203 | Backup ZIP format 3 (per toko terenkripsi AES-256-GCM), restore atomik, retensi 30 file, Telegram | `app_database`, `backup_platform_*`, `secure_store`, `store_registry` | `backup_scheduler`, layar settings |
| `data/backup_scheduler.dart` | 65 | Timer tiap menit: backup harian sesuai jam, catch-up, retry Telegram | `backup_service` | `main.dart` |
| `data/backup_platform.dart` | 3 | Fasad conditional export `readFile`/`fileExists` | `backup_platform_io/stub` | layar pengaturan struk |
| `data/backup_platform_io.dart` | 103 | I/O backup: baca/tulis DB, `.bak`, hapus sidecar, ganti atomik, folder auto-backup | `dart:io`, `path`, `path_provider` | `backup_service` |
| `data/backup_platform_stub.dart` | 49 | Stub web: operasi file melempar `UnsupportedError` | — | `backup_service` |

##### 3.3.7 Karyawan, follow-up, supplier, struk, rekonsiliasi

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/employee_service.dart` | 524 | Kompensasi (KOMISI/GAJI, persen/nominal), siklus payroll, hutang, bayar gaji, override komisi | `app_database`, `operator`, `dates`, `ids`, `sync/crypto`, `sync_service` | layar karyawan, riwayat, order, POS |
| `data/followup_service.dart` | 1661 | Bangun dan jalankan follow-up WhatsApp: prospek, servis berkala, garansi, piutang, unit selesai; kuota gratis 20 | `app_database`, `license_service`, `app_config`, `dates`, `ids`, `money`, `phone`, `wa_link`, `relay_client` | layar follow-up, pengaturan follow-up, riwayat, POS |
| `data/supplier_service.dart` | 321 | CRUD supplier, relasi item-supplier, daftar stok minim, status follow-up pembelian | `app_database`, `dates`, `ids`, `phone` | layar stok, supplier |
| `data/receipt_service.dart` | 529 | Render `ReceiptDocument` dari nota memakai template v2 | `app_database`, `models`, `receipt_settings`, `receipt_template`, `store_settings`, `dates`, `money`, `printer/receipt_builder` | `printer_service`, dialog struk, pengaturan struk |
| `data/receipt_settings.dart` | 87 | Simpan/muat template JSON v2 + migrasi toggle lama | `app_database`, `receipt_template` | `receipt_service`, pengaturan struk |
| `data/receipt_template.dart` | 512 | Model template v2: label, visibilitas, lebar 58/80, validasi & sanitasi JSON | `printer/receipt_builder` | `receipt_service`, `receipt_settings`, pengaturan struk |
| `data/reconciliation_service.dart` | 175 | Digest harian nota (count + sha256 sync_id) untuk rekonsiliasi relay | `app_database`, `dates`, `ids` | `sync_scheduler`, premium |

#### 3.4 `pusatkupos/lib/sync` — mesin sinkronisasi (10 file)

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `sync/crypto.dart` | 193 | Ed25519, X25519 + HKDF + AES-GCM, canonical JSON, HLC | `cryptography`, `crypto` | `protocol`, `snapshot_sync`, `sync_service`, data lain |
| `sync/protocol.dart` | 234 | Bangun/verifikasi amplop delta: tanda tangan, hints, cross-check hasil dekripsi | `crypto` | `sync_service` |
| `sync/relay_client.dart` | 423 | Klien HTTP semua endpoint relay (enroll, envelope, feed, ack, round, snapshot, pairing, akun, lisensi) | `core/relay_url.dart`, `http` | `sync_service`, login, pairing, follow-up, owner API |
| `sync/snapshot_sync.dart` | 264 | Daftar tabel snapshot; buat/terapkan snapshot (checksum, enkripsi, tanda tangan, idempotensi) | `dates`, `app_database`, `crypto`, `snapshot_platform_*` | `sync_service` |
| `sync/snapshot_platform_io.dart` | 90 | Ekspor/impor snapshot SQLite native (`VACUUM INTO`, transaksi replace) | `sqflite`, `dart:io` | `snapshot_sync` |
| `sync/snapshot_platform_stub.dart` | 20 | Stub non-native: selalu `UnsupportedError` | — | `snapshot_sync` |
| `sync/sync_conflict_rules.dart` | 171 | Aturan izin pengirim, retry/backoff, alasan konflik, `ownerWins` | — | `sync_service`, `note_sync` |
| `sync/sync_scheduler.dart` | 133 | Timer sync 10–20 menit + jitter; dipicu resume aplikasi | `app_config`, `license_service`, `reconciliation_service`, `sync_service` | `main.dart` |
| `sync/sync_secrets.dart` | 58 | Token/kunci per toko di secure storage dengan suffix `@store`; migrasi nilai lama | `app_database`, `secure_store` | `sync_service`, sesi, perangkat, pairing |
| `sync/sync_service.dart` | 4185 | Mesin penuh: enroll, key-wrap, outbox, push/pull/apply, konflik, snapshot, rekonsiliasi, housekeeping | `app_config`, `dates`, `ids`, `relay_url`, akun, DB, perangkat, lisensi, verifier, model, `note_sync`, koreksi, store settings, secure store, `crypto`, `protocol`, `relay_client`, `snapshot_sync`, `sync_conflict_rules`, `sync_secrets` | `sync_scheduler`, service data (enqueue), UI premium/konflik |

#### 3.5 `pusatkupos/lib/printer` — cetak struk (26 file)

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `printer/printer_adapter.dart` | 47 | Kontrak adapter + `PrintPayload`/`PrinterException` | `printer_config`, `printer_device` | manager, semua adapter, `printer_service` |
| `printer/printer_channel.dart` | 118 | MethodChannel `pusatkupos/printer` ke Android | adapter, device | adapter BT/BLE/USB/network/system |
| `printer/ble_printer_adapter.dart` | 213 | BLE GATT: scan 8 s, MTU 247, tulis per chunk | adapter, channel, config, device | manager |
| `printer/bluetooth_classic_adapter.dart` | 40 | SPP klasik via channel native | adapter, channel, config, device | manager |
| `printer/usb_printer_adapter.dart` | 35 | USB OTG via channel native | adapter, channel, config, device | manager |
| `printer/network_printer_adapter.dart` | 30 | TCP JetDirect (default port 9100) + discovery NSD | adapter, channel, config, device, transport | manager |
| `printer/system_print_adapter.dart` | 22 | Dialog cetak sistem Android | adapter, channel, config | manager |
| `printer/web_printer_adapter.dart` | 12 | Cetak lewat dialog browser | browser_print, adapter, config | manager |
| `printer/printer_manager.dart` | 124 | Pilih adapter per tipe/transport; status koneksi runtime | adapter, config, device, semua adapter | `printer_service` |
| `printer/printer_service.dart` | 280 | Entry point cetak: render ulang jika lebar beda, auto-connect, logo raster, pilih payload | receipt_service, escpos, logo, adapter, config, manager, receipt_builder | UI (dialog struk, POS, riwayat, estimasi) |
| `printer/printer_config.dart` | 509 | Model konfigurasi printer + validasi + `PrinterStore` (maks 8) | ids, app_database, storage | semua adapter, manager, service, UI |
| `printer/printer_device.dart` | 41 | Objek hasil discovery | — | adapter, channel, manager |
| `printer/printer_storage.dart` | 25 | Abstraksi storage + implementasi memori | — | `printer_config`, storage io |
| `printer/printer_storage_io.dart` | 49 | File JSON atomik + `.bak` | storage | `printer_config` (conditional) |
| `printer/printer_storage_stub.dart` | 7 | Stub non-IO | storage | `printer_config` |
| `printer/printer_storage_web.dart` | 18 | `localStorage` | storage | `printer_config` |
| `printer/printer_transport_io.dart` | 16 | Kirim TCP dengan timeout | `dart:io` | network adapter |
| `printer/printer_transport_stub.dart` | 5 | Stub TCP | — | network adapter |
| `printer/receipt_builder.dart` | 164 | Komposer baris struk lebar tetap (item, amount, divider) | `core/money.dart` | escpos, `printer_service` |
| `printer/escpos_builder.dart` | 294 | Byte ESC/POS: codepage, align, bold, double, raster, cut, word-wrap | `receipt_builder` | `printer_service` |
| `printer/browser_print.dart` | 4 | Fasad conditional browser print | stub/web | web adapter |
| `printer/browser_print_stub.dart` | 5 | Stub: `UnsupportedError` | — | `browser_print` |
| `printer/browser_print_web.dart` | 21 | Buka popup `<pre>` lalu `window.print()` | `dart:html` | `browser_print` |
| `printer/logo_platform.dart` | 2 | Fasad conditional pembaca logo | stub/io | `printer_service` |
| `printer/logo_platform_io.dart` | 13 | Baca byte file logo | `dart:io` | `logo_platform` |
| `printer/logo_platform_stub.dart` | 1 | Stub: `null` | — | `logo_platform` |

#### 3.6 `pusatkupos/lib/ui` — layar dan komponen (30 file)

| File | LOC | Tanggung jawab | Bergantung pada |
|---|---:|---|---|
| `ui/entry_gate.dart` | 96 | Pilih onboarding/PIN; logout total | DB, lisensi, PIN, secure store, sesi, sync, onboarding, `pin_gate` |
| `ui/home_shell.dart` | 458 | Shell utama, menu difilter izin, auto-lock, rail/bottom nav | operator, DB, sesi, registry, store service, state, `pin_gate`, widgets, store switcher, 13 layar |
| `ui/onboarding.dart` | 1070 | Alur awal: gratis, Google, karyawan (password/pairing), PIN ≥6 digit | app_config, akun, DB, employee auth, Google, lisensi, pairing, PIN, secure store, sesi, state, `home_shell`, viewer |
| `ui/owner_viewer.dart` | 1394 | Shell ringkasan read-only: verifikasi ringkasan bertanda tangan, perangkat, akun, undangan | app_config, money, summary file, akun, DB, perangkat, lisensi, verifier, model, owner API, secure store, sesi, crypto, sync, `entry_gate`, `pin_gate`, konflik |
| `ui/pin_gate.dart` | 277 | Buka kunci PIN; bedakan terkunci/salah/PIN lama lemah; routing per profil | operator, PIN, sesi, state, `entry_gate`, `home_shell`, viewer |
| `ui/receipt_dialog.dart` | 257 | Pratinjau/cetak struk 58/80 + WhatsApp | receipt service, logo, printer config/service, receipt builder, widgets |
| `ui/theme.dart` | 43 | Tema Material 3 terang/gelap (seed `0xFF155E75`) | — |
| `ui/upload_backup_dialog.dart` | 278 | Cek kelengkapan snapshot sebelum unggah backup | sync service |
| `ui/widgets.dart` | 231 | `SectionCard`, `StatCard`, `MoneyText`, `EmptyState`, snackbar, konfirmasi, label satuan | core/money |
| `ui/widgets/store_switcher.dart` | 52 | Dialog pilih toko aktif | store registry |
| `ui/screens/pos_screen.dart` | 1737 | Kasir semua jenis transaksi: keranjang, diskon, pembayaran, approval, cetak | operator, dates, ids, money, quantity, akun, DB, employee, followup, model, order, store settings, printer, state, sync, dialog struk, widgets |
| `ui/screens/history_screen.dart` | 1447 | Riwayat transaksi + filter piutang; void/retur/koreksi/pelunasan/komisi | dates, money, quantity, DB, employee, followup, model, koreksi, price rules, retur, store settings, state, sync, dialog struk, widgets |
| `ui/screens/premium_screen.dart` | 1411 | Aktivasi lisensi, akun/perangkat, undangan, sync admin, rekonsiliasi | akun, DB, perangkat, Google, lisensi, owner API, rekonsiliasi, state, sync, upload dialog, konflik, widgets |
| `ui/screens/receipt_settings_screen.dart` | 1221 | Editor struk 6 tab, pratinjau debounce 300 ms, impor/ekspor JSON v2 | DB, backup platform, receipt service/settings/template, logo, printer config/service, receipt builder, widgets |
| `ui/screens/estimates_screen.dart` | 1168 | Daftar/detail estimasi, revisi, konversi ke nota, batal | dates, money, quantity, DB, model, order, store settings, state, sync, dialog struk, widgets |
| `ui/screens/settings_screen.dart` | 950 | Identitas toko, fitur, keamanan, backup, ringkasan owner, logout | DB, backup, owner summary, PIN, state, `entry_gate`, `pin_gate`, widgets, followup/printer/receipt/store settings/toko |
| `ui/screens/stock_screen.dart` | 901 | Stok: tambah/edit, masuk/keluar, opname, supplier | money, quantity, DB, model, supplier, state, sync, widgets |
| `ui/screens/orders_screen.dart` | 876 | Work order + transisi status + log | dates, DB, employee, model, order, store settings, state, sync, widgets, estimates |
| `ui/screens/customers_screen.dart` | 829 | Pelanggan + unit kendaraan, deteksi duplikat, merge | DB, model, state, sync, widgets |
| `ui/screens/followup_screen.dart` | 780 | Daftar follow-up, filter, kuota, kirim WA, ubah status | dates, money, followup, widgets |
| `ui/screens/employees_screen.dart` | 712 | Kompensasi, bayar gaji, hutang, komisi | dates, money, employee, lisensi, sync, widgets |
| `ui/screens/printer_settings_screen.dart` | 629 | Kelola/printer test/discovery, maks 8 | printer adapter/config/device/manager/service, widgets |
| `ui/screens/reports_screen.dart` | 507 | Laporan presets (hari/7 hari/bulan/semua), laba, kas, retur, koreksi, estimasi | dates, money, DB, model, state, widgets |
| `ui/screens/store_settings_screen.dart` | 429 | Preset transaksi/tahap, izin per peran, approver | akun, store settings, state, sync, widgets |
| `ui/screens/supplier_screen.dart` | 420 | Supplier + status stok minim (premium) | quantity, DB, lisensi, supplier, sync, widgets |
| `ui/screens/followup_settings_screen.dart` | 373 | Interval/kuota follow-up dengan validasi | followup, widgets |
| `ui/screens/jasa_screen.dart` | 313 | Katalog jasa: harga & modal (modal owner-only) | money, DB, model, state, sync, widgets |
| `ui/screens/sync_conflicts_screen.dart` | 263 | Daftar konflik sync, retry/ignore | sync, widgets |
| `ui/screens/dashboard_screen.dart` | 237 | Ringkasan harian + aksi cepat | dates, money, DB, model, state, widgets |
| `ui/screens/stores_screen.dart` | 234 | Daftar/ganti/tambah toko (premium, store limit) | DB, lisensi, registry, store service, state, widgets |

#### 3.7 `relay/` — server sinkronisasi & lisensi (10 file Dart + config)

| File | LOC | Tanggung jawab | Bergantung pada |
|---|---:|---|---|
| `relay/lib/server.dart` | 2559 | HTTP Shelf: enroll/pairing, envelope log, feed/ack, bootstrap, sync round, snapshot, akun/undangan, login Google/karyawan, admin; body dibatasi 16 MB (snapshot: batas penyimpanan + 8 MB), penyimpanan toko penuh ditolak `413 storage_full` | `auth_rules`, `canonical`, `config`, `db`, `google`, `license`, `sync_round`, shelf |
| `relay/lib/db.dart` | 347 | Lapisan PostgreSQL + migrasi idempoten + decoder JSONB | `postgres`, `config` |
| `relay/lib/license.dart` | 97 | Kunci Ed25519 server, terbitkan token lisensi, verifikasi payload/tanda tangan | `canonical`, `db`, `cryptography` |
| `relay/lib/google.dart` | 360 | Verifikasi ID token Google (JWKS/RS256) + rate limiter | `dart:io`, `crypto` |
| `relay/lib/auth_rules.dart` | 78 | Aturan entity/aksi per peran + field hints amplop; `stock`/`stock_movement` wajib `ubah_stok`, `harga_jasa` hanya pemilik | — |
| `relay/lib/canonical.dart` | 13 | JSON kanonik (urut kunci rekursif) untuk semua tanda tangan | `dart:convert` |
| `relay/lib/config.dart` | 109 | Baca env/.env, parse URL PostgreSQL | `dart:io` |
| `relay/lib/sync_round.dart` | 57 | Evaluasi kelengkapan sync round (ack semua perangkat, tidak stale) | — |
| `relay/bin/relay.dart` | 377 | CLI: `serve`, `migrate`, `key`, `owner`, `token`, `identity`, `license`, `seed-demo` | paket relay, `args`, `shelf_io` |
| `relay/tool/gen_demo_summary.dart` | 48 | Tool pembuat ringkasan owner demo | paket relay |
| `relay/pubspec.yaml` | 18 | Manifest paket relay | pub.dev |
| `relay/.env.example` | 9 | Template `RELAY_HOST/PORT/DATABASE_URL/ADMIN_TOKEN/GOOGLE_CLIENT_ID` | — |
| `relay/start-relay.ps1` | 28 | Launcher Windows: resolusi Dart (`DART` → `FLUTTER_ROOT` → `PATH`), cek `.env`, `dart pub get`, `serve` | — |
| `relay/README.md` | 262 | Dokumentasi setup, endpoint, model auth, batas body/penyimpanan | — |

Endpoint utama `server.dart`:

| Grup | Endpoint | Fungsi |
|---|---|---|
| Health | `GET /relay/health`, `GET /relay/admin/license-public-key` | Status + kunci publik lisensi |
| Perangkat | `POST /relay/devices`, `GET /relay/devices`, `GET /relay/bootstrap` | Enroll owner/viewer, daftar perangkat, key-wrap + snapshot awal |
| Pairing | `POST /relay/pairing`, `POST /relay/invites/claim` | Kode undangan karyawan |
| Envelope | `POST /relay/envelopes`, `POST /relay/envelopes/batch`, `GET /relay/feed`, `POST /relay/feed/ack` | Log delta terenkripsi + kursor |
| Kunci toko | `POST /relay/keys` | Key-wrap kunci toko per perangkat |
| Sync round | `POST /relay/sync/rounds`, `GET /relay/sync/rounds/open`, `GET /relay/sync/rounds/<id>`, `POST /relay/sync/rounds/<id>/ack` | Gerbang snapshot |
| Snapshot | `POST /relay/snapshots` | Unggah snapshot terenkripsi |
| Akun karyawan | `POST /relay/auth/employee`, `POST /relay/auth/employee/password`, `GET /relay/permissions/me` | Login/ganti password/izin |
| Owner manage | `GET|POST /relay/manage/accounts`, `GET|POST /relay/manage/invites`, `GET /relay/manage/devices`, `POST /relay/manage/devices/<id>/revoke` | Kelola akun/undangan/perangkat |
| Google | `POST /relay/auth/google` | Login Google → lisensi |
| Kuota | `POST /relay/followup/quota` | Kuota WA gratis |
| Admin | `POST /relay/admin/owners`, `GET|POST /relay/admin/identities` | Provisioning owner |

#### 3.8 Platform, web, dan konfigurasi

| File | LOC | Tanggung jawab | Terhubung ke |
|---|---:|---|---|
| `android/.../MainActivity.kt` | 30 | Activity Flutter + pasang `PrinterBridge` | `PrinterBridge`, manifest |
| `android/.../printer/PrinterBridge.kt` | 294 | MethodChannel `pusatkupos/printer`: izin, BT klasik, USB, NSD, system print | `BluetoothPrinter`, `UsbPrinter`, `SystemPrinter`, `printer_channel.dart` |
| `android/.../printer/BluetoothPrinter.kt` | 362 | Koneksi SPP, chunk 128 byte, timeout 15/20/120 s | `PrinterBridge` |
| `android/.../printer/UsbPrinter.kt` | 340 | USB Host bulk-out, izin runtime, chunk 8 KiB | `PrinterBridge` |
| `android/.../printer/SystemPrinter.kt` | 247 | PDF thermal 58/80 mm lewat Print Framework | `PrinterBridge` |
| `android/app/build.gradle.kts` | 86 | namespace/applicationId, signing release wajib, Flutter | Gradle |
| `android/build.gradle.kts`, `settings.gradle.kts`, `gradle.properties` | 24/26/6 | Repositori, plugin, Flutter SDK path, JVM | Gradle |
| `android/app/src/main/AndroidManifest.xml` | 61 | Izin internet/BT/USB/lokasi, activity, `allowBackup=false`, no cleartext | `MainActivity`, build |
| `android/app/src/debug/AndroidManifest.xml` | 12 | Izinkan cleartext hanya untuk relay localhost debug | build debug |
| `android/app/src/profile/AndroidManifest.xml` | 7 | Izin internet untuk profil | build profile |
| `windows/CMakeLists.txt`, `windows/flutter/*`, `windows/runner/*` | 108/109/17/26/40/43/71/288/69/121/14 | Build runner Windows, plugin secure storage/url_launcher, DPI/dark mode | Flutter Windows |
| `web/index.html`, `web/manifest.json` | 46/35 | Bootstrap Flutter web + manifest PWA | build web |
| `web/sqflite_sw.js` + `web/sqlite3.wasm` | generated/binary | Backend SQLite browser | `sqflite_common_ffi_web` |
| `pusatkupos/pubspec.yaml` | 102 | Dependensi Flutter (sqflite/SQLCipher/FFI/web, secure storage, Google, BLE, archive, file picker) | build semua platform |
| `pusatkupos/.env.example` | 6 | `PUSATKU_LICENSE_PUBLIC_KEY`, `PUSATKU_GOOGLE_CLIENT_ID` | `--dart-define-from-file=.env` |
| `pusatkupos/analysis_options.yaml` | 35 | Lint Flutter; abaikan folder platform | analyzer |
| `pusatkupos/README.md`, `README.md` | 151/86 | Dokumentasi login, fitur, keamanan, build, kontrak sync | developer |
| `DOKUMENTASI_LENGKAP_PUSATKUPOS.md`, `LICENSE` | — | Riwayat audit, laporan perbaikan, lisensi repo | dokumentasi |

---

### 4. Graf ketergantungan (siapa memakai siapa)

#### 4.1 Arah lapisan

```text
main.dart
  ├── app.dart ──────────────► ui/entry_gate.dart
  │                                ├── ui/onboarding.dart ─► data/{employee_auth,google_auth,pairing,pin,session}
  │                                └── ui/pin_gate.dart ───► data/{pin,session} + state/app_state
  │                                       ├── ui/home_shell.dart ─► ui/screens/*
  │                                       └── ui/owner_viewer.dart ─► data/{owner_access_api,owner_summary,sync}
  │
  ├── data/app_database.dart ◄── hampir semua data/*Service
  │        ├── data/schema.dart
  │        ├── data/models.dart
  │        ├── data/price_rules.dart
  │        ├── data/approval_service.dart ─► data/{pin,login_guard,store_settings}
  │        ├── auth/{operator,permissions}.dart
  │        └── sync/crypto.dart (HLC)
  │
  ├── data/backup_scheduler.dart ─► data/backup_service.dart ─► data/store_registry.dart
  ├── sync/sync_scheduler.dart ───► sync/sync_service.dart
  │                                     ├── sync/{protocol,relay_client,snapshot_sync,conflict_rules,secrets}
  │                                     ├── data/note_sync.dart
  │                                     ├── data/nota_adjustment_service.dart
  │                                     └── data/{account,device,license,store_settings}
  └── sync/sync_service.dart ─────► sync/relay_client.dart ─► relay/lib/server.dart ─► relay/lib/db.dart
```

Aturan praktis:

- **UI tidak menulis SQL.** Semua akses data lewat service atau `AppDatabase.instance`.
- **Service tidak mengimpor UI.** Ketergantungan hanya satu arah: UI → service → database/relay.
- **`AppDatabase` adalah pusat.** Perubahan harga, stok, total, nomor dokumen, dan HLC harus lewat situ agar invarian terjaga.
- **Sync hanya membaca outbox dan menulis inbox/kursor.** Service domain menitipkan perubahan lewat `SyncService.enqueue*()` di dalam transaksi database.
- **Relay tidak tahu SQLite.** Relay hanya menyimpan amplop terenkripsi, kunci ter-wrap, akun, lisensi, dan status round.

#### 4.2 Ketergantungan silang yang perlu diwaspadai

| Relasi | Penjelasan |
|---|---|
| `app_database` ⇄ `approval_service` | `app_database` memanggil approval; approval membaca `app_settings`/akun lewat `app_database`. Tidak ada import melingkar karena approval memakai singleton saat runtime. |
| `sync_service` → `note_sync` → `sync_conflict_rules` | Penerapan nota memakai tipe `RetryableSyncException` dan aturan konflik. |
| `printer_service` → `receipt_service` → `app_database` | Cetak selalu merender ulang dari data nota, bukan dari draft UI. |
| `backup_service` → `store_registry` | Restore multi-toko menulis ulang registry, lalu `AppDatabase` wajib bootstrap ulang. |
| `license_service` ⇄ `store_service` | Store service membaca claims lisensi; lisensi menyimpan owner/token. Cache lisensi dibersihkan saat ganti toko. |

#### 4.3 Conditional import per platform

| Fasad | Native (IO) | Web/stub | Dipakai untuk |
|---|---|---|---|
| `data/backup_platform.dart` | `backup_platform_io.dart` | `backup_platform_stub.dart` | Baca file backup |
| `data/store_platform.dart` (via `store_service`) | `store_platform_io.dart` | `store_platform_stub.dart` | Folder DB tiap toko |
| `sync/snapshot_platform.dart` (via `snapshot_sync`) | `snapshot_platform_io.dart` | `snapshot_platform_stub.dart` | Ekspor/impor snapshot |
| `printer/printer_storage.dart` (via `printer_config`) | `printer_storage_io.dart` | `printer_storage_stub.dart` / `printer_storage_web.dart` | Simpan konfigurasi printer |
| `printer/printer_transport.dart` (via network adapter) | `printer_transport_io.dart` | `printer_transport_stub.dart` | Kirim TCP |
| `printer/browser_print.dart` | — | `browser_print_stub.dart` / `browser_print_web.dart` | Cetak browser |
| `printer/logo_platform.dart` | `logo_platform_io.dart` | `logo_platform_stub.dart` | Baca logo |
| `core/summary_file_*` | `summary_file_io.dart` | `summary_file_stub.dart` / `summary_file_web.dart` | Impor ringkasan owner |

---

### 5. Alur data ujung-ke-ujung

#### 5.1 Buka aplikasi dan buka kunci

1. `main` → `AppDatabase.init`.
2. `EntryGate` membaca sesi (`SessionService.load`).
3. Tanpa sesi → `OnboardingFlow`; ada sesi → `PinGate`.
4. `PinService.verifyDetailed` memeriksa lockout, PIN PBKDF2, dan PIN lama.
5. `SessionProfile.toOperator()` → `AppState.setOperator`.
6. `HomeShell` atau `OwnerViewerShell` dirender; menu difilter `operator.permissions`.

#### 5.2 Membuat nota (POS)

1. `PosScreen` memuat pelanggan, unit, stok, katalog jasa, dan pengaturan toko.
2. Kasir mengisi `JobDraft`/`PartDraft`; kuantitas disimpan sebagai `qtyMilli`.
3. Simpan → `AppDatabase.createTransaction(requestId, …)`.
4. Validasi: jenis transaksi aktif (`StoreSettings.typeEnabled`), peran boleh (`roleAllows('buat_nota')`), pelanggan/unit wajib sesuai aturan bengkel.
5. Harga dan stok dibaca ulang dari DB (anti-keranjang basi). Stok kurang → ditolak.
6. Diskon dialokasikan `PriceRules.allocate`: proporsional per baris, tidak boleh melewati modal. Non-owner butuh `ApprovalService` bila diskon di bawah batas.
7. Tulis `service_records` (harga terdaftar, batas, final, diskon alokasi, approver dibekukan), `service_jobs`, `service_parts`, mekanik, komisi, pembayaran, dan `stock_movements` keluar.
8. Total, `sisa_bayar`, status (`LUNAS`/`KREDIT`/`DP`), nomor nota, dan audit ditulis dalam satu transaksi.
9. `SyncService.enqueueNote()` menulis payload lengkap ke `sync_outbox`.
10. Dialog struk → `ReceiptService.build` → `PrinterService.printReceipt`.

#### 5.3 Pembayaran piutang

1. `HistoryScreen` → `AppDatabase.settleReceivable`.
2. Tolak nota VOID; nominal ≤ `sisa_bayar`.
3. `request_id` mencegah pembayaran ganda.
4. Insert baris `service_payments` (`PELUNASAN`), hitung ulang total, ubah status ke `LUNAS` bila sisa 0.
5. Enqueue `note_payment` ke outbox.

#### 5.4 Retur penjualan

1. `HistoryScreen` → `SaleReturnService.createReturn`.
2. Wajib alasan, minimal satu baris, izin `void`, peran `void`; nota VOID ditolak.
3. Hitung sisa per baris: `original - sudah diretur`; qty retur tidak boleh melebihi.
4. Refund proporsional dari neto baris (`subtotal - diskon_alokasi`).
5. Simpan `sale_returns` + `sale_return_items` (termasuk `modal_satuan`).
6. Kembalikan stok part + catat `stock_movements` masuk.
7. Bila refund melebihi sisa bayar, tulis pembayaran `REFUND` negatif (idempoten).
8. `recalculateRecordTotals` + `recalculateRecordCommissions`, audit, enqueue.

#### 5.5 Void nota

1. `HistoryScreen` → `AppDatabase.voidRecord`.
2. Ditolak bila masih ada retur aktif.
3. Stok part dikembalikan sebesar qty nota dikurangi qty yang sudah diretur; `stock_movements` masuk dicatat dengan kunci `void-<part_sync_id>`.
4. Pembayaran dikembalikan sebagai baris `REFUND` negatif (idempoten per `request_id`).
5. Status nota → `VOID`, `voided_at`, `sisa_bayar = 0`, audit, enqueue `note_void` dan amplop `note_payment` agar REFUND ikut ke perangkat lain.
6. Perangkat penerima void hanya menyamakan status + stok (tidak membuat refund ganda); `sisa_bayar` juga dinolkan.

#### 5.6 Koreksi nilai nota

1. `HistoryScreen` → `NotaAdjustmentService.create`.
2. Wajib aktor + alasan; non-owner butuh peran `koreksi`.
3. Total saat ini = `nilai_baru` koreksi terakhir menurut `(sync_hlc_wall, sync_hlc_counter, id)`, atau `total_servis` bila belum ada koreksi.
4. `nilaiBaru` boleh dikirim langsung atau lewat `selisih`; target dihitung ulang di dalam transaksi, baris baru ditambahkan, nota asli tidak diubah.
5. Koreksi di bawah modal divalidasi `PriceRules.validateCorrection`; PIN/approval diverifikasi **di luar** transaksi agar hitungan gagal terkunci tetap tersimpan.
6. Modal part dihitung dari `COALESCE(jumlah_milli, jumlah * 1000)`; modal jasa tetap `jumlah` bulat.
7. `recalculateRecordTotals`, audit, enqueue `nota_adjustment`.

#### 5.7 Estimasi → nota → work order

1. `OrderService.createEstimate`: jenis transaksi aktif, peran boleh, diskon lewat `PriceRules`, nomor estimasi, masa berlaku.
2. Revisi membuat baris baru `versi + 1` dengan `revisi_dari_sync_id`; estimasi lama ditandai `direvisi`.
3. `convertEstimateToNote`: cek status/kedaluwarsa, susun draft dari harga estimasi, `diskon = (jasa + part) - total estimasi`, panggil `createTransaction` dengan `estimate_sync_id`.
4. Estimasi menjadi `dikonversi`.
5. `createWorkOrder`: nomor order + nomor antrian harian per perangkat, status awal sesuai tahap yang aktif.
6. `changeStatus`: transisi divalidasi `allowedWorkOrderTransitions`; override owner dicatat sebagai konflik; setiap perubahan masuk `work_order_status_log`.
7. Semua langkah enqueue ke outbox (`estimate`, `work_order`, `work_order_status`).

#### 5.8 Stok dan opname

1. `StockScreen` → `AppDatabase.saveStockItem` / `stockIn` / `stockOut` / `opname`.
2. Kuantitas selalu milli; kolom lama `jumlah` diisi `wholeQuantity(milli)` yang membulatkan ke bawah untuk nilai negatif (bukan ke arah nol).
3. Setiap perubahan menulis `stock_movements` (`MASUK`/`KELUAR`/`OPNAME`) dan menstempel HLC.
4. Izin berbeda: `ubah_stok`, `stok_masuk`, `stok_keluar`, `opname`.
5. Enqueue `stock`/`stock_movement` agar perangkat lain menerima saldo yang sama.

#### 5.9 Payroll dan komisi

1. `EmployeesScreen` → `EmployeeService.updateCompensation`.
2. Siklus: mingguan mengikuti `payroll_hari`, bulanan mengikuti `payroll_tanggal` (diklem 1–31).
3. `payrollSummary` menjumlahkan komisi nota non-VOID; gaji mingguan diprorata `gaji * hari / 30`.
4. Potongan = `min(totalHutang, bruto)`; hutang dibayar FIFO.
5. `paySalary` menolak siklus yang sudah dibayar, menulis `salary_payments`, dan mengenqueue `salary`.
6. Override komisi hanya owner; nota VOID tidak bisa diubah.

#### 5.10 Laporan

1. `ReportsScreen` memilih preset: hari ini, 7 hari, bulan ini, semua (`DateTime(2000)..sekarang`).
2. `AppDatabase.reportSummary` menjumlahkan omzet neto (setelah diskon), modal part/jasa, komisi, gaji, retur, koreksi, kas per metode.
3. Owner melihat tambahan: penjualan di bawah harga, koreksi, umur estimasi.
4. `DashboardData` meringkas hari ini untuk layar dashboard.

#### 5.11 Backup dan restore

1. `SettingsScreen`/`BackupScheduler` → `BackupService.createBackup`.
2. Arsip ZIP format 3: `manifest.json` + `stores/<n>.db.enc`.
3. Tiap DB diekspor konsisten, dienkripsi AES-256-GCM (PBKDF2 210k), checksum SHA-256.
4. Mode portable memakai passphrase pengguna; mode otomatis memakai passphrase acak di SecureStore (hanya perangkat yang sama).
5. Retensi 30 file; opsi kirim Telegram ≤50 MB.
6. Restore: validasi manifest/checksum/header SQLite → decrypt → tulis DB sementara → ganti atomik dengan `.bak` → registry `replaceAll` → kode perangkat baru + `seq_floor` → `sync.restore_requires_bootstrap=1`.

#### 5.12 Login, lisensi, dan pairing

**Gratis:** tanpa akun, data lokal, tanpa sync.

**Google (owner premium):**
1. `GoogleAuthService.signIn` → ID token.
2. `RelayClient.googleLogin` → `owner_id` + `license_token`.
3. `install` menulis owner identity, token lisensi, email/provider, URL relay.
4. `LicenseService.verifiedClaims` memastikan plan premium dan masa aktif.

**Karyawan (password):**
1. `EmployeeAuthService.login` membuat/memakai ulang kunci Ed25519 + X25519.
2. Relay `employeeLogin` memverifikasi owner/username/password, mengembalikan akun, perangkat, token lisensi.
3. Klien menyimpan perangkat, token, kunci, sesi, dan izin peran.

**Karyawan (kode pairing):**
1. `PairingService.claim` memanggil relay, memeriksa `owner_public_key` dan tanda tangan izin.
2. Kunci owner dipin (TOFU); kunci berbeda → pairing dibatalkan.
3. Akun + perangkat + lisensi dipasang; `must_change_password` dimatikan.

**Viewer (ringkasan):**
1. Owner mengekspor ringkasan bertanda tangan (`OwnerSummaryService`).
2. Viewer memverifikasi tanda tangan dengan kunci server/owner sebelum mengimpor.
3. Viewer memakai DB terpisah `viewer_<owner_id>.db`, read-only.

#### 5.13 Sinkronisasi

**Push:**
1. Service domain menulis outbox (`seq`, `hlc`, payload, `idempotency_key`).
2. `SyncService.syncNow` mengambil baris yang jatuh tempo.
3. `protocol.buildEnvelope` mengenkripsi payload dengan kunci toko dan menandatangani amplop + hints.
4. `RelayClient.submitEnvelopes` mengirim batch adaptif; 429/503 menurunkan ukuran batch dan menunda sisa baris.
5. Batch 4xx dikirim ulang satu per satu; kegagalan masuk backoff.

**Pull:**
1. Ambil daftar perangkat (`/relay/devices`) untuk kunci publik pengirim.
2. Replay inbox yang tertunda.
3. Baca feed dari `sync_cursor`.
4. `protocol.verifyEnvelope` memeriksa tanda tangan, `key_id`, dan cross-check hints.
5. `_applyOnce` menerapkan delta dalam satu transaksi; `applied_deltas` + `noteRemoteHlc`.
6. Ack hanya sampai `blockedSeq - 1`; kursor tidak boleh melewati amplop yang gagal.

**Snapshot (bootstrap/unggah):**
1. `startUploadCheck` memastikan outbox kosong dan `latest_seq == cursor`.
2. Relay membuat sync round; semua perangkat penulis harus ack.
3. `uploadSnapshot` memeriksa kelengkapan, mengenkripsi, menandatangani, lalu mengunggah.
4. Penerima memverifikasi tanda tangan, checksum, dan `store_seq` sebelum impor.

**Konflik:**
- HLC lebih besar menang; seri → counter lebih besar; seri penuh → lokal dipertahankan kecuali keduanya 0.
- Alasan non-blocking (`versi_lokal_lebih_baru`, harga di bawah batas, stok negatif, rekonsiliasi beda, nomor nota bentrok) dicatat tanpa menggagalkan transaksi.
- Alasan lain → `_ApplyRejected`, seluruh transaksi rollback, amplop masuk `sync_inbox` + `sync_conflicts` dengan backoff 1/2/4…240 menit (maks 8 percobaan).

#### 5.14 Cetak struk

1. `ReceiptService.build` membaca nota + template + pengaturan toko.
2. `ReceiptBuilder` menyusun baris lebar 32 (58 mm) atau 48 (80 mm).
3. `PrinterService` memilih mode: `ESCPOS`, `TEXT`, atau `SYSTEM`.
4. Untuk ESC/POS: `EscPosBuilder` menambahkan init, codepage, alignment, bold, double size, raster logo, feed, cut.
5. Transport: BLE (MTU 247, chunk), SPP (128 byte), USB (8 KiB), TCP 9100, atau dialog sistem/browser.
6. Jika lebar dokumen tidak cocok dengan printer, struk dirender ulang dari `recordId`; jika tidak ada `recordId`, cetak gagal.

---

### 6. Logika bisnis per domain

#### 6.1 Uang dan kuantitas

- **Uang selalu integer sen.** Tipe/kolom memakai akhiran `Cents` (`harga`, `subtotal`, `diskon`, `total`, `sisa_bayar`). Input pengguna diubah lewat `parseRupiahToCents` (format `1.500,50`), output lewat `formatRupiah`.
- **Kuantitas selalu milli (1/1000).** `jumlah` (bulat) dipertahankan untuk kompatibilitas; `jumlah_milli` adalah nilai otoritatif. Rumus nominal baris: `harga * qtyMilli ~/ 1000` (dengan pembulatan pada perhitungan tertentu).
- `formatQuantity(milli, desimal, satuan)` menampilkan 0–3 desimal dan memangkas nol; `parseQuantityToMilli` menerima koma desimal dan titik ribuan.
- Nilai negatif ditolak pada input uang; koreksi/retur memakai jalur khusus (bukan input negatif biasa).

#### 6.2 Peran dan izin

| Peran | Izin default | Catatan |
|---|---|---|
| `owner` | semua | Satu-satunya yang boleh mengubah modal/harga katalog, menambah barang, override status order, dan menyetujui dengan PIN |
| `KASIR` | `void`, `retur`, `diskon`, `stok_masuk`, `stok_keluar`, `opname`, `lihat_laporan`, `followup` | Tidak boleh mengubah katalog/modal |
| `KEDUANYA` | sama dengan KASIR | Bisa kasir + mekanik |
| `MEKANIK` | kosong | Izin tambahan dapat diberikan per akun: `buat_estimasi`, `buat_order`, `ubah_status`, `koreksi`, `ubah_stok`, `setujui` |
| `viewer` | baca laporan | Tidak boleh mengirim amplop/tulis data |

- `Permissions.require(operator, izin)` melempar `StateError` bila izin tidak ada; owner selalu lolos.
- `canWriteMoney` membedakan owner dari karyawan; dipakai untuk pelunasan dan aksi keuangan.
- Izin per peran untuk jenis transaksi diatur `StoreSettings.roleAllows/roleCanSelect`; perubahan pengaturan toko hanya owner.
- Persetujuan harga/diskon: mode `owner` (PIN pemilik) atau `penanggung_jawab` (akun aktif dengan izin `setujui`), dengan lockout terpisah `approver:<syncId>`.

#### 6.3 Harga, diskon, dan batas modal

- `PriceLine` menghitung `subtotal`, `batasTotal` (modal), dan `hargaFinal` per baris.
- **Batas bawah = modal tersimpan** (`harga_modal`/`harga_batas_saat_transaksi`). Tidak ada kolom batas terpisah; menurunkan batas berarti menurunkan modal.
- Non-owner:
  - tidak boleh menjual di bawah modal;
  - total diskon tidak boleh melebihi total margin (`bruto - modal`);
  - alokasi diskon proporsional per baris; sisa pembulatan digeser ke baris berikutnya; bila kapasitas habis → transaksi ditolak.
- Owner boleh menjual di bawah modal; baris tersebut diberi `disetujui_oleh` dan ditandai `belowMinimum` untuk laporan.
- Harga dibekukan saat transaksi: `harga_jual_terdaftar`, `harga_batas_saat_transaksi`, `harga_final`, `diskon_alokasi`.

#### 6.4 Transaksi dan status

Lima jenis transaksi (`store_settings.dart`):

| Konstanta | Arti |
|---|---|
| `jual_sparepart` | Penjualan part saja |
| `servis_langsung` | Servis tanpa order panjang |
| `order_kerja` | Order pengerjaan |
| `estimasi_saja` | Estimasi tanpa nota finansial (bila diizinkan) |
| `pelunasan_order` | Pelunasan order |

Lima tahap order: `nomor_order`, `nomor_antrian`, `status_pengerjaan`, `estimasi`, `persetujuan_pelanggan`.
Tiga preset: `layanan_langsung`, `order_lengkap`, `manual`.

- Status pembayaran: `LUNAS` (sisa 0), `KREDIT`/`DP` (sisa > 0), `VOID`.
- Nomor nota: `{cabang}{perangkat}-{prefix}{yyyymmdd}-{urut}`; nomor antrian `{cabang}{perangkat}-{urut}`; counter per perangkat + tanggal agar perangkat offline tidak bentrok.
- `request_id` membuat pembuatan nota/pembayaran idempoten (retry tidak menggandakan).
- Harga/stok dibaca ulang dari DB saat menyimpan untuk mencegah keranjang basi.

#### 6.5 Pembayaran dan piutang

- `CASH`: `dibayar = bayar.clamp(0, total)`, `kembalian = bayar - total`.
- `TRANSFER`: tidak boleh melebihi total (tidak ada kembalian).
- `sisa = total - dibayar`; sisa > 0 → status kredit dan opsi `jatuh_tempo`.
- Setiap pembayaran menulis baris ledger `service_payments` (`DP`, `PELUNASAN`, `REFUND`).
- `settleReceivable`: tolak VOID, nominal ≤ sisa, idempoten, status → `LUNAS` saat sisa 0.

#### 6.6 Retur, void, dan koreksi (append-only)

**Retur**
- Satu baris retur hanya boleh sampai sisa qty (`original - sudah diretur`).
- Refund proporsional dari neto baris (setelah diskon alokasi).
- Stok part kembali + movement `MASUK`.
- Kelebihan refund atas sisa bayar dibukukan sebagai `REFUND` negatif.
- Total dan komisi dihitung ulang; nota asli tidak diubah.

**Void**
- Ditolak bila ada retur aktif.
- Stok dikembalikan hanya untuk qty yang belum diretur, pembayaran di-refund, status `VOID`, `sisa_bayar = 0`, audit, enqueue `void` + amplop pembayaran REFUND.
- Nota VOID tidak bisa diretur/dikoreksi/diubah komisinya.

**Koreksi**
- Baris `nota_adjustments` baru; `nilai_baru` dan `selisih` disimpan sebagai riwayat.
- Total efektif = `nilai_baru` terakhir menurut HLC, bukan penjumlahan `nilai_selisih` (menghindari hitung ganda koreksi bersamaan).
- Divalidasi terhadap modal baris asli; di bawah modal butuh approval di luar transaksi.
- Total, piutang, dan komisi dihitung ulang; `applyRemote` idempoten dan melewati nota VOID.

#### 6.7 Estimasi dan work order

- Estimasi bukan dokumen finansial; hanya disimpan bila `simpan_estimasi_lepas` aktif, selain itu hanya dicetak.
- Revisi append-only: `versi + 1`, `revisi_dari_sync_id`, estimasi lama `direvisi`.
- Masa berlaku `masa_berlaku_hari` (minimal 1); kedaluwarsa tidak bisa dikonversi.
- Konversi: harga diambil dari estimasi, `diskon = (jasa + part) - total_estimasi`; diskon negatif ditolak; nota ditautkan `estimate_sync_id`; estimasi → `dikonversi`.
- Work order: nomor + antrian hanya dialokasikan bila tahapnya aktif; tanpa tahap pengerjaan status awal `dibuka`.
- Transisi status mengikuti `allowedWorkOrderTransitions`; transisi di luar peta hanya owner dan dicatat `sync_conflicts`; setiap transisi masuk `work_order_status_log`.

#### 6.8 Stok

- Tiga jalur: `stockIn`, `stockOut`, `opname`, semuanya menulis `stock_movements`.
- Stok minimum default 3 (bila `stok_minimum` kosong) dipakai untuk daftar stok minim.
- Stok negatif dapat terjadi dari penerapan delta dan dicatat sebagai konflik `stok_negatif` (non-blocking).
- Penambahan barang/katalog dan perubahan harga dibatasi owner; transaksi stok mengikuti izin masing-masing.

#### 6.9 Komisi, gaji, dan hutang

- Jenis imbalan: `KOMISI` atau `GAJI`; mode komisi `PERSEN` atau `NOMINAL`.
- Komisi dihitung dari jasa dan margin part, dibagi rata antar mekanik dengan sisa pembagian yang deterministik.
- Periode payroll: `MINGGUAN` (mengikuti `payroll_hari` 1–7) atau `BULANAN` (mengikuti `payroll_tanggal` 1–31, diklem ke akhir bulan).
- Gaji mingguan diprorata `gaji_bulanan * hari / 30`.
- Potongan hutang = `min(totalHutang, bruto)`; hutang dibayar FIFO (yang paling lama dulu).
- Satu siklus hanya boleh dibayar sekali; pembayaran menulis `salary_payments`.
- Override komisi hanya owner dan tidak berlaku untuk nota VOID.

#### 6.10 Follow-up dan supplier

- Jenis follow-up: prospek, servis berkala, garansi, piutang, unit selesai.
- Sumber dibangun ulang dari nota non-VOID: garansi H-7/kedaluwarsa, prospek 30/60/90 hari, servis berkala dari interval bulan, piutang setelah tenggang, unit selesai saat unit diambil.
- Pengiriman WA dibatasi jam aktif, cooldown, kuota harian/bulanan, consent/DNC, dan prioritas (piutang > garansi > servis; unit masih dikerjakan memblokir).
- Kuota gratis 20 pesan; premium tanpa batas. Kuota disinkronkan lewat relay.
- Status follow-up punya transisi sah per jenis; piutang lunas menutup follow-up.
- Supplier: nama unik (case-insensitive), telepon dinormalisasi, relasi item-supplier, status follow-up pembelian.

#### 6.11 Laporan

- Preset: hari ini, 7 hari, bulan ini, **semua** (`DateTime(2000)`–sekarang).
- Omzet neto = total nota − retur; laba kotor neto = laba kotor − (retur jual − retur modal).
- Komponen: modal part, modal jasa, komisi, gaji, retur, koreksi, kas per metode, jenis transaksi.
- Owner-only: penjualan di bawah harga, daftar koreksi, umur estimasi.
- `belowPriceSales` menelusuri baris dengan `harga_final < harga_batas_saat_transaksi`.
- `estimateAging` mengelompokkan estimasi belum dikonversi menurut umur.

#### 6.12 Multi-toko dan backup

- `registry.db` menyimpan daftar toko → file DB dan toko aktif. Web memakai satu toko sintetis.
- Menambah toko: wajib premium, akun Google, nama unik ≥2 karakter, dan tidak melewati `store_limit` lisensi.
- Ganti toko: cek penugasan akun (`allowedStoreIds`) + file ada; `AppDatabase` dibuka ulang; cache lisensi dibersihkan.
- Backup format 3: satu ZIP berisi manifest + satu DB terenkripsi per toko; kunci payload per toko.
- Restore atomik memakai `.bak`, menulis ulang registry, membuat kode perangkat baru, menaikkan `seq_floor`, dan mewajibkan bootstrap sync.
- Backup otomatis: retensi 30 file, jadwal harian, opsi Telegram ≤50 MB.
- Passphrase backup otomatis disimpan di SecureStore, minimal 8 karakter, dan dapat dilihat/disalin dari layar Pengaturan. Caption Telegram menandai arsip terkunci passphrase.

#### 6.13 Lisensi, pairing, dan sesi

- Lisensi **hanya** diterbitkan relay dan diverifikasi dengan kunci publik server yang ditanam saat build.
- `premium = plan == "premium" && period_end > sekarang`; lisensi kedaluwarsa tidak mengunci kasir offline, hanya mematikan sync/multi-toko.
- Owner lokal: ID 8 karakter, kunci Ed25519 di SecureStore, kode pemulihan 12 karakter (PBKDF2 600k).
- Pairing memverifikasi `owner_public_key` dan tanda tangan izin; kunci owner dipin (TOFU).
- Login karyawan: password + PIN (PIN didaftarkan saat login pertama), atau kode pairing.
- Sesi disimpan di SecureStore; mode `free`, `premium`, `employee`, `viewer`.
- Lockout: 5 percobaan gagal, backoff eksponensial 30–3600 detik per scope.

#### 6.14 Sinkronisasi, HLC, dan konflik

- Outbox menyimpan `seq`, `hlc`, payload, `idempotency_key`; urutan per perangkat.
- Amplop: payload terenkripsi AES-GCM dengan kunci toko; tanda tangan Ed25519; hints terpisah ikut ditandatangani.
- `key_id` = 16 hex pertama SHA-256 kunci toko; ketidakcocokan → amplop tidak di-ack.
- HLC lokal: `wall = now` bila lebih besar dari sebelumnya, selain itu `counter + 1`. HLC remote menaikkan lantai (`sync.hlc_floor`) agar penulisan lokal berikutnya menang.
- Konflik data: HLC lebih besar menang → counter lebih besar → lokal dipertahankan bila seri penuh (kecuali keduanya 0).
- Ack hanya sampai amplop pertama yang gagal dikurangi satu; kursor tidak pernah melewati data yang belum diterapkan.
- Retry maksimal 8 kali dengan backoff `2^retry` menit, dibatasi 240 menit.
- Snapshot hanya boleh diunggah setelah outbox bersih, `latest_seq == cursor`, dan semua perangkat penulis ack pada sync round yang sama. Konflik `review` dan konflik final tidak menghalangi cadangan.
- Relay mengunci `(owner_id, store_id)` dengan advisory lock saat menerima amplop tunggal/batch sehingga urutan `relay_seq` sama dengan urutan commit; celah nomor akibat rollback tidak berbahaya karena feed memakai `> since`.
- Izin perangkat karyawan: `stok` butuh `ubah_stok`, `nota` dipilah per aksi (`void`→`void`, `warranty`/`taken`→`ubah_status`, lainnya `buat_nota`). Harga stok tetap hanya owner; perubahan harga dari karyawan dicatat sebagai konflik final `harga_dikunci_owner` tanpa memblokir kursor.
- Konflik final (`peran_tidak_berhak*`, `peran_viewer_hanya_baca`, `hanya_owner`, `harga_dikunci_owner`, `hapus_order_hanya_owner`) disimpan status `rejected` dan tidak diputar ulang; pemilik tetap melihatnya di daftar konflik.
- Kuota follow-up `/relay/followup/quota` memerlukan token perangkat; instalasi tanpa pairing memakai kuota lokal.
- Digest harian (`day_digests`) dibandingkan relay; ketidakcocokan memicu `reconciliation_requests` + `data_request`.
- Amplop lama dipangkas setelah semua perangkat relevan maju; perangkat dicabut tidak menahan pemangkasan.

#### 6.15 Printer dan struk

- Template v2: blok header, meta, item, total, pembayaran, garansi, bank, footer; label dan visibilitas dapat diubah.
- Lebar: 58 mm = 32 kolom; 80 mm = 48 kolom. Lebar dokumen harus sama dengan printer; jika beda, struk dirender ulang dari `recordId`.
- Codepage: CP437, CP850, CP1252; karakter tak didukung ditransliterasi atau menjadi `?`.
- Logo raster 1-bit, lebar 10–40 mm; alignment direset setelah logo.
- Salinan 1–3, baris kosong 0–5, maksimal 5 baris tambahan (≤80 karakter).
- WhatsApp: teks dinormalisasi ke prefix `62`, dipotong 3500 karakter.
- Maksimal 8 printer; konfigurasi disimpan terpisah (`printer_config.json`) dan tidak ikut backup.
- Status `CONNECTED`/`CONNECTING` hanya runtime; status tersimpan diturunkan menjadi `SAVED`.

---

### 7. Rumus dan invarian kunci

| Invarian | Rumus / aturan |
|---|---|
| Nilai baris | `subtotal = (harga * qtyMilli / 1000).round()` |
| Diskon per baris | proporsional terhadap subtotal; total alokasi ≤ `subtotal - modal` untuk non-owner |
| Sisa bayar | `sisa = totalEfektif - Σretur - Σpembayaran`, minimum 0; `totalEfektif` = `nilai_baru` koreksi terakhir menurut HLC atau `total_servis` |
| Laba kotor | `Σ(harga_final - modal)`, dinetokan dengan retur |
| Laba kotor neto | `labaKotor - (returJual - returModal)` |
| Omzet neto | `total - retur` |
| Komisi persen | `shareJasa * persenJasa / 100 + shareMargin * persenBarang / 100`, sisa pembagian dibagikan deterministik |
| Gaji mingguan | `gajiBulanan * jumlahHari / 30` |
| Potongan hutang | `min(totalHutang, bruto)`; pelunasan FIFO |
| Payroll | satu `salary_payments` per `(employee, cycle_start)` |
| HLC lokal | `wall = max(now, prevWall)`, `counter = (now > prevWall) ? 0 : prevCounter + 1` |
| Konflik remote | bandingkan `(hlc_wall, hlc_counter)`; seri penuh → lokal |
| Lisensi | `premium = plan == "premium" && period_end > now` |
| Kunci toko | `key_id = sha256(storeKey)[0..16]` (hex) |
| Enkripsi payload | AES-GCM-256; ciphertext + 16 byte MAC |
| Enkripsi backup | AES-256-GCM, PBKDF2-HMAC-SHA256 210.000 iterasi |
| PIN/password | PBKDF2-HMAC-SHA256 600.000 iterasi, salt 16 byte |
| Retensi outbox | 90 hari untuk baris terkirim; `applied_deltas` dibatasi ±20.000 |
| Sync interval | 10–20 menit + jitter 60–120 detik |
| Retry sync | `2^attempt` menit, maksimal 240 menit, 8 percobaan |
| Printer | maksimal 8; 58 mm = 32 kolom, 80 mm = 48 kolom |
| Kuantitas | 1 unit = 1000 milli; desimal 0–3 |

---

### 8. Catatan teknis hasil pembacaan kode

1. **Restock void dan validasi stok.** `AppDatabase.voidRecord` mengembalikan stok memakai `jumlah_milli` (fallback `jumlah × 1000`) dikurangi qty yang sudah diretur, dan `createTransaction` memvalidasi total qty per `stock_item_id` sehingga dua baris barang yang sama tidak dapat membuat stok negatif. Void juga membuka kembali estimasi (`status = aktif`, `converted_nota_sync_id = NULL`) dan melepas `work_orders.nota_sync_id` bila nota berasal dari keduanya, lalu meng-enqueue amplop `note_payment` untuk REFUND.
2. **Total koreksi bersifat absolut.** `NotaAdjustmentService._currentTotal`, `AppDatabase.recalculateRecordTotals`, `reportSummary`, dan perhitungan refund retur memakai `nilai_baru` terakhir menurut HLC, bukan `SUM(nilai_selisih)`, agar dua koreksi bersamaan tidak terhitung ganda. Rumusnya kini satu sumber, `AppDatabase.latestAdjustmentTotalSql`; modal nota memakai `AppDatabase.recordModalSql`. Verifikasi approval berjalan di luar transaksi supaya hitungan PIN gagal tidak ikut rollback.
3. **Pembulatan kolom `jumlah` lama.** `wholeQuantity(milli)` membulatkan ke bawah untuk nilai negatif dan dipakai di semua penulisan stok (tambah, edit, opname), retur, void, dan jalur sinkronisasi.
4. **`sqflite_sw.js` adalah artefak build**, bukan kode aplikasi; isinya minified dan hanya dipakai backend SQLite web.
5. **Folder test sudah dihapus total** (25 file Flutter + 3 relay + 2 skrip uji) beserta hook test di `AppDatabase`, `SecureStore`, dan `SyncService`. `pubspec.lock` masih menyebut paket test sampai `pub get` berikutnya.
6. **`summary_file_stub.dart` diimpor langsung oleh `owner_viewer`** ketika platform tidak mendukung file picker; di web/native implementasi yang dipakai ditentukan conditional import.
7. **`analysis_options.yaml` mengecualikan folder platform** (`android/`, `web/`, `windows/`), sehingga lint Flutter tidak memeriksa kode native.
8. **`start-relay.ps1` portabel.** Skrip mencari `DART`, lalu `FLUTTER_ROOT\bin\dart.bat`, lalu `PATH`, dan berhenti dengan pesan jelas bila Dart tidak ditemukan.
9. **Mode viewer memakai database terpisah** `viewer_<owner_id>.db`; `openViewerDatabase` tidak menulis ke DB utama.
10. **`app_settings` menyimpan penanda lokal** (mis. `sync.last_*`, `device.*`) yang dikecualikan saat snapshot/impor agar tidak menimpa identitas perangkat tujuan.
11. **Persetujuan diskon diverifikasi sebelum `db.transaction`** di `createTransaction` (sama seperti `createEstimate`), supaya penghitung gagal PIN di `login_guards` tidak ikut ter-rollback saat PIN salah.
12. **Konversi estimasi idempoten.** `convertEstimateToNote` mengirim `requestId = estimasi:<sync_id>` dan `createTransaction` hanya mengubah estimasi dengan syarat `status = 'aktif'`; klik ganda atau konversi ulang ditolak tanpa mengurangi stok dua kali.
13. **Konflik final tidak memblokir.** `SyncConflictRules.isFinal` menandai penolakan izin/harga sebagai `rejected`; `_applyOnce` menganggapnya selesai sehingga kursor maju, sedangkan `blockingConflictCount` mengabaikan `review` dan final sehingga snapshot/backup tetap bisa dibuat.
14. **Kuota follow-up diautentikasi.** `FollowupService` mengirim token perangkat hasil pairing ke `/relay/followup/quota`; tanpa token, kuota hanya dihitung lokal.
15. **Refund retur dibatasi kas diterima.** `SaleReturnService` menghitung `max(0, dibayar - max(0, total_efektif - retur))` lalu membatasinya dengan nilai retur, sehingga retur pada nota yang dikoreksi menjadi 0 dan belum dibayar tidak mengeluarkan uang.
16. **Batas relay ditegakkan.** `_body` membaca body secara bertahap dengan batas 16 MB (snapshot: `RELAY_STORAGE_LIMIT_BYTES` + 8 MB); amplop yang membuat pemakaian toko melewati batas ditolak `413 storage_full` setelah amplop yang sudah diakui dipangkas lebih dulu.

---

### 9. Checklist cakupan file

Semua file di bawah sudah dibaca sampai baris terakhir. Angka di judul adalah jumlah file per folder.

**Dart — `pusatkupos/lib` (122 file)**

- `lib/` (2): `main.dart`, `app.dart`
- `core/` (11): `app_config`, `dates`, `ids`, `money`, `phone`, `quantity`, `relay_url`, `summary_file_io`, `summary_file_stub`, `summary_file_web`, `wa_link`
- `auth/` (2): `operator`, `permissions`
- `state/` (1): `app_state`
- `dev/` (1): `dummy_seed`
- `data/` (39): `account_service`, `app_database`, `approval_service`, `backup_platform`, `backup_platform_io`, `backup_platform_stub`, `backup_scheduler`, `backup_service`, `device_service`, `employee_auth_service`, `employee_service`, `followup_service`, `google_auth_service`, `license_service`, `license_verifier`, `login_guard`, `models`, `nota_adjustment_service`, `note_sync`, `order_service`, `owner_access_api`, `owner_summary_service`, `pairing_service`, `pin_service`, `price_rules`, `receipt_service`, `receipt_settings`, `receipt_template`, `reconciliation_service`, `sale_return_service`, `schema`, `secure_store`, `session_service`, `store_platform_io`, `store_platform_stub`, `store_registry`, `store_service`, `store_settings`, `supplier_service`
- `sync/` (10): `crypto`, `protocol`, `relay_client`, `snapshot_platform_io`, `snapshot_platform_stub`, `snapshot_sync`, `sync_conflict_rules`, `sync_scheduler`, `sync_secrets`, `sync_service`
- `printer/` (26): `ble_printer_adapter`, `bluetooth_classic_adapter`, `browser_print`, `browser_print_stub`, `browser_print_web`, `escpos_builder`, `logo_platform`, `logo_platform_io`, `logo_platform_stub`, `network_printer_adapter`, `printer_adapter`, `printer_channel`, `printer_config`, `printer_device`, `printer_manager`, `printer_service`, `printer_storage`, `printer_storage_io`, `printer_storage_stub`, `printer_storage_web`, `printer_transport_io`, `printer_transport_stub`, `receipt_builder`, `system_print_adapter`, `usb_printer_adapter`, `web_printer_adapter`
- `ui/` (10): `entry_gate`, `home_shell`, `onboarding`, `owner_viewer`, `pin_gate`, `receipt_dialog`, `theme`, `upload_backup_dialog`, `widgets`, `widgets/store_switcher`
- `ui/screens/` (20): `customers`, `dashboard`, `employees`, `estimates`, `followup`, `followup_settings`, `history`, `jasa`, `orders`, `pos`, `premium`, `printer_settings`, `receipt_settings`, `reports`, `settings`, `stock`, `store_settings`, `stores`, `supplier`, `sync_conflicts`

**Dart — `relay` (10 file)**

- `relay/lib/` (8): `auth_rules`, `canonical`, `config`, `db`, `google`, `license`, `server`, `sync_round`
- `relay/bin/` (1): `relay`
- `relay/tool/` (1): `gen_demo_summary`

**Android (18 file teks + 5 PNG)**

- Kotlin (5): `MainActivity.kt`, `printer/PrinterBridge.kt`, `printer/BluetoothPrinter.kt`, `printer/UsbPrinter.kt`, `printer/SystemPrinter.kt`
- Gradle (5): `app/build.gradle.kts`, `build.gradle.kts`, `settings.gradle.kts`, `gradle.properties`, `gradle/wrapper/gradle-wrapper.properties`
- Manifest (3): `main`, `debug`, `profile`
- Resource XML (4): `values/styles.xml`, `values-night/styles.xml`, `drawable/launch_background.xml`, `drawable-v21/launch_background.xml`
- Gitignore (1): `android/.gitignore`
- Aset biner (5): ikon launcher mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi

**Windows (17 file teks + 1 ICO)**

`windows/.gitignore`, `CMakeLists.txt`, `flutter/CMakeLists.txt`, `flutter/generated_plugin_registrant.{cc,h}`, `flutter/generated_plugins.cmake`, `runner/CMakeLists.txt`, `runner/main.cpp`, `runner/flutter_window.{cpp,h}`, `runner/win32_window.{cpp,h}`, `runner/utils.{cpp,h}`, `runner/resource.h`, `runner/Runner.rc`, `runner/runner.exe.manifest`, `runner/resources/app_icon.ico`.

**Web (3 file teks + 5 PNG + 1 WASM)**

`index.html`, `manifest.json`, `sqflite_sw.js` (generated), `sqlite3.wasm`, `favicon.png`, `icons/Icon-{192,512}.png`, `icons/Icon-maskable-{192,512}.png`.

**Konfigurasi dan dokumentasi**

`pusatkupos/pubspec.yaml`, `pusatkupos/.env.example`, `pusatkupos/analysis_options.yaml`, `pusatkupos/.metadata`, `pusatkupos/README.md`, `pusatkupos/.gitignore`, `README.md`, `.gitignore`, `relay/pubspec.yaml`, `relay/.env.example`, `relay/start-relay.ps1`, `relay/README.md`, `DOKUMENTASI_LENGKAP_PUSATKUPOS.md`, `LICENSE`.

**Tidak dipetakan isinya (non-kode):** 12 aset biner — ikon launcher Android ×5, ikon web ×5 (`Icon-192`, `Icon-512`, `Icon-maskable-192`, `Icon-maskable-512`, `favicon.png`), `app_icon.ico`, `sqlite3.wasm` — dan `web/sqflite_sw.js` (hasil kompilasi). Tidak ada file teks/kode yang terlewat.

---

# Bagian II — Audit Logika Bisnis, Kelengkapan, dan Alur Operasional

**Aplikasi:** PusatkuPOS (Flutter offline-first + relay Dart/PostgreSQL)
**Pembanding:** POS bengkel Python di `D:/Downloads/aplikasiposbengkel`
**Tanggal audit:** 5 November 2026
**Sifat audit:** Baca kode menyeluruh. Tidak ada dependency yang dipasang. Tidak ada test otomatis yang dijalankan (pengujian dilakukan manual oleh pemilik).
**Status implementasi:** seluruh temuan P1–P3 pada dokumen ini sudah diperbaiki; Kelompok 6 (B-01–B-10) dan Kelompok 7 (C-01–C-06) mencatat audit lanjutan yang juga sudah selesai.

---

### 1. Ringkasan Eksekutif

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

### 2. Daftar Temuan P1

| ID | Temuan | Dampak utama | Bukti |
|---|---|---|---|
| P1-01 | Void setelah retur tetap diizinkan | Stok dobel, kas lebih-refund, piutang retur tidak beres | `pusatkupos/lib/data/app_database.dart:2321` |
| P1-02 | Retur tidak menyentuh pembayaran/piutang | Piutang dan kas tidak mencerminkan barang yang dikembalikan | `pusatkupos/lib/data/sale_return_service.dart:56` |
| P1-03 | Ambil unit tanpa cek sisa tagihan | Unit keluar bengkel walau piutang masih ada | `pusatkupos/lib/data/app_database.dart:2086` |
| P1-04 | Pelanggan/unit quick-add di POS tidak di-enqueue | Master data tidak ikut sinkronisasi inkremental | `pusatkupos/lib/ui/screens/pos_screen.dart:212`, `:245` |
| P1-05 | Konversi estimasi ke nota kehilangan relasi | Nota tanpa pelanggan/unit, work order tidak tertutup | `pusatkupos/lib/data/order_service.dart:538` |
| P1-06 | Perangkat karyawan boleh mengunggah snapshot toko | Karyawan dapat menimpa cadangan seluruh toko | `relay/lib/server.dart:1297` |

---

### 3. Detail Temuan P1

#### P1-01 Void setelah retur: stok kembali dua kali, kas direfund penuh

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

#### P1-02 Retur tidak mengurangi piutang, kas, dan status bayar

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

#### P1-03 Unit bisa diambil walau masih ada sisa tagihan

**Perilaku saat ini**

`markUnitTaken` hanya mengubah `diambil_at` selama `unit_ditinggal = 1` (`app_database.dart:2086-2104`). Tidak ada pemeriksaan `sisa_bayar`. Tombol di riwayat juga hanya mensyaratkan unit masih di bengkel (`history_screen.dart:341-368`).

**Pembanding Python**

`services/pengerjaan_service.py:234-236` menolak status `SUDAH_DIAMBIL` selama `record_sisa(marker.service_record) > 0`, dengan pesan “Unit belum bisa ditandai diambil selama masih ada sisa tagihan.”

**Dampak**

Praktik bengkel normal: unit tidak diserahkan sebelum tagihan lunas (kecuali kebijakan khusus). Aplikasi saat ini membolehkan unit keluar dengan piutang berjalan, sehingga penagihan menjadi jauh lebih sulit dan tidak ada jejak jaminan.

**Rekomendasi**

Tolak pengambilan bila `sisa_bayar > 0`; sediakan jalur override khusus pemilik dengan alasan dan audit log bila kebijakan toko mengizinkan.

---

#### P1-04 Pelanggan/unit dari jalan pintas POS tidak ikut sinkronisasi

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

#### P1-05 Konversi estimasi ke nota kehilangan pelanggan, unit, dan work order

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

#### P1-06 Perangkat karyawan dapat mengunggah snapshot toko

**Perilaku saat ini**

`_createSnapshot` hanya memblokir `kind == 'viewer'` (`relay/lib/server.dart:1297-1312`). Perangkat `employee` lolos selama putaran sinkron selesai dan `store_seq` cocok. Snapshot kemudian di-upsert sebagai cadangan resmi toko.

**Dampak**

Snapshot adalah salinan penuh data toko (termasuk harga, pelanggan, transaksi). Karyawan yang perangkatnya disusupi dapat mengganti cadangan resmi dengan data buatan. Saat pemulihan, data palsu itu yang dipakai. Ini pelanggaran pemisahan wewenang: karyawan hanya boleh mengirim entitas operasional, bukan mengganti seluruh keadaan toko.

**Rekomendasi**

Batasi unggah snapshot ke perangkat `owner` (atau pemilik dengan izin eksplisit), dan verifikasi ulang tanda tangan terhadap kunci owner, bukan hanya kunci perangkat.

---

### 4. Temuan P2

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

### 5. Temuan P3 dan Catatan Kecil

- Pembayaran sebagian selalu diberi label `PELUNASAN` (`app_database.dart:1652-1665`). Tidak ada label DP/uang muka.
- `salary_payments.cicilan_hutang` diisi **sisa utang setelah potong gaji**, bukan jumlah cicilan yang dibayar (`employee_service.dart:307-324`, `:457-495`). Kolom tidak dipakai di tempat lain, tetapi namanya menyesatkan.
- Follow-up yang sudah `SUDAH_BAYAR` tetap tampil di daftar “semua” karena filter hanya mengecualikan `ARSIP` (`followup_service.dart:549-573`).
- Tombol void/retur/pelunasan memakai izin `void`; tidak ada pemisahan izin retur vs void di UI.
- Batas toko sudah ditegakkan (`store_service.dart:70-110`), jadi tidak lagi menjadi temuan.
- Viewer sudah mengirim ack (`owner_viewer.dart:278-300`), sehingga macetnya pemangkasan berasal dari perangkat karyawan yatim, bukan viewer.
- `data_response` dan `day_digest` memang diizinkan untuk karyawan; bukan bug.

---

### 6. Matriks Kelengkapan: Flutter vs Python Bengkel

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

### 7. Urutan Operasional Baku (dari Menambah Pelanggan)

Urutan ini mengikuti alur yang benar untuk bengkel, sekaligus menandai titik yang perlu diperbaiki.

#### Tahap 0 — Persiapan toko dan perangkat

1. Isi identitas toko: nama, alamat, telepon, tagline (`bengkel.*`).
2. Aktifkan premium dan identitas owner (kunci owner, lisensi).
3. Daftarkan perangkat owner ke relay (token pendaftaran, kunci perangkat, kunci toko).
4. Buat akun karyawan beserta peran dan izin (`void`, `diskon`, `koreksi`, `lihat_laporan`, `setujui`).
5. Pasangkan perangkat karyawan melalui kode undangan.
6. Pasang perangkat viewer bila diperlukan (hanya baca ringkasan).
7. Atur pajak/biaya lain, template struk, printer, dan pengaturan follow-up.

#### Tahap 1 — Master data

8. **Tambah pelanggan**: nama, nomor HP (wajib, unik setelah normalisasi), alamat, consent WhatsApp, do-not-contact.
9. **Tambah unit pelanggan**: jenis unit, nopol, merek/tipe, jenis mobil, tahun, nomor rangka/mesin, tipe radiator.
10. **Tambah jasa**: deskripsi, harga jual, batas modal, interval servis.
11. **Tambah supplier**, lalu **tambah sparepart**: nama, satuan, harga modal, harga jual, stok awal, stok minimum, flag desimal.
12. **Petakan supplier ke sparepart** (mapping multi-supplier).

> Catatan audit: pelanggan/unit yang dibuat dari tombol cepat di layar POS tidak ikut sinkron (P1-04). Gunakan menu Pelanggan sampai diperbaiki.

#### Tahap 2 — Estimasi dan work order (opsional)

13. Buat **estimasi**: pilih pelanggan + unit, tambah jasa/part, tetapkan masa berlaku.
14. Bila berubah, buat **revisi estimasi** (versi baru; versi lama tetap tersimpan).
15. Buat **work order**: keluhan, mekanik, prioritas, nomor antrian harian.
16. Ubah status pengerjaan (antri → dikerjakan → selesai) dengan catatan.
17. Estimasi aktif dapat **dijadikan nota**.

> Catatan audit: konversi sudah membawa pelanggan/unit/work order (P1-05) dan detail estimasi kini punya aksi Revisi/Batalkan (P2-16).

#### Tahap 3 — Transaksi POS

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

#### Tahap 4 — Struk dan pengiriman

25. Pilih ukuran struk 58/80 mm dan template.
26. Cetak ke printer Bluetooth/network/USB, atau simpan/lihat pratinjau.
27. Kirim struk ke WhatsApp pelanggan (bila consent dan nomor tersedia).

> Catatan audit: nota tanpa unit kehilangan nomor HP karena inner join (P2-12).

#### Tahap 5 — Piutang dan follow-up

28. Buka daftar piutang; lihat sisa, jatuh tempo, dan status lewat tempo.
29. Catat **pelunasan bertahap** (CASH/TRANSFER). Sisa dan status bayar diperbarui.
30. Buka **follow-up WhatsApp**: pilih pelanggan/unit, lihat pesan yang digabung, kirim.
31. Catat hasil: akan datang, masih kendala, janji bayar, sudah bayar, atau arsip.
32. Piutang hanya keluar dari daftar lewat pelunasan penuh, void, atau mekanisme arsip yang diizinkan.

> Catatan audit: pelunasan belum idempoten (P2-03); kuota follow-up terpakai saat tautan dibuka (P2-04).

#### Tahap 6 — Pengambilan unit dan garansi

33. Setelah pekerjaan selesai dan pembayaran lunas, tandai **unit diambil**.
34. Catat **klaim garansi**: tanggal klaim, status, catatan syarat.
35. Bila unit dititipkan, pantau status “masih di bengkel” vs “sudah diambil”.

> Catatan audit: pengambilan tidak dicek terhadap sisa tagihan (P1-03).

#### Tahap 7 — Retur, void, koreksi

36. **Retur**: pilih item jasa/part, qty, dan alasan. Sistem mengembalikan stok part dan mencatat retur append-only.
37. **Void**: hanya untuk nota yang salah total; wajib alasan dan izin.
38. **Koreksi nota**: mengubah nilai nota tanpa mengubah nota asli (append-only).

> Catatan audit: retur belum mengurangi piutang/kas (P1-02); void setelah retur masih diizinkan (P1-01); koreksi belum ada UI (P2-02).

#### Tahap 8 — Tutup buku

39. Buka **Laporan** harian/periode: omzet jasa/part, diskon, total, retur, penjualan neto, modal, laba kotor, komisi, gaji, laba setelah komisi & gaji.
40. Periksa **kas per metode** dan **piutang**.
41. Periksa **estimasi aging** dan daftar koreksi.
42. Proses **payroll**: komisi periode, gaji pokok, bonus, potongan utang karyawan, lalu bayar.
43. Ekspor/cetak laporan bila diperlukan.

> Catatan audit: laba belum mengurangi diskon dan komisi belum neto retur (P2-01). Belum ada ekspor XLSX/CSV dan laporan semua waktu (bagian 6).

#### Tahap 9 — Backup dan sinkronisasi

44. Jalankan sinkronisasi rutin (outbox → relay, feed → terapkan, ack).
45. Lengkapi **putaran sinkron** seluruh perangkat.
46. Unggah **snapshot** toko setelah putaran selesai dan cursor perangkat ini mutakhir.
47. Simpan backup lokal terenkripsi (ZIP per toko, AES-GCM, SHA-256) ke media terpisah.
48. Uji restore di perangkat lain secara berkala.

> Catatan audit: snapshot sebaiknya hanya dari perangkat owner (P1-06); pemangkasan bisa macet karena perangkat karyawan yatim (P2-08/P2-09).

---

### 8. Rekomendasi Urutan Perbaikan (menunggu perintah “mulai”)

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

### 9. Cakupan File yang Dibaca

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

### 10. Log Perbaikan

#### Kelompok 1 — temuan mudah (selesai 5 November 2026)

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

#### Kelompok 2 — retur, void, koreksi, dan uang (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P1-01 | Sudah diperbaiki | Void ditolak bila nota sudah memiliki retur aktif. Refund void kini dicek per `request_id` sehingga tidak bentrok dengan refund retur. | `pusatkupos/lib/data/app_database.dart` (`voidRecord`) |
| P1-02 | Sudah diperbaiki | Retur kini: (1) menghapus piutang lebih dulu, (2) membuat baris pembayaran `REFUND` negatif hanya untuk kelebihan yang harus dikembalikan tunai, (3) menghitung ulang `total_dibayar`, `sisa_bayar`, dan `status_bayar`, (4) ikut diterapkan saat retur masuk dari perangkat lain. | `pusatkupos/lib/data/sale_return_service.dart`, `data/app_database.dart` (`recalculateRecordTotals`), `data/note_sync.dart` |
| P2-02 | Sudah diperbaiki | Koreksi nota bisa dibuat dari riwayat (tombol “Koreksi total nota”, dengan PIN pemilik/penanggung jawab bila di bawah batas modal). Koreksi langsung mengubah piutang/status bayar, ikut disinkronkan, dan total laporan memakai nilai setelah koreksi. | `pusatkupos/lib/ui/screens/history_screen.dart`, `data/nota_adjustment_service.dart`, `data/app_database.dart` |
| P2-01 | Sudah diperbaiki | Omzet part/jasa di laporan memakai `subtotal - diskon_alokasi`, sehingga laba kotor sudah setelah diskon. Label laporan diperjelas “(setelah diskon)”. | `data/app_database.dart` (`reportSummary`), `ui/screens/reports_screen.dart` |

#### Kelompok 3 — relay, perangkat, dan undangan (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P1-06 | Sudah diperbaiki | Snapshot toko hanya boleh diunggah perangkat owner (`owner_device_required`). | `relay/lib/server.dart` |
| P2-06 | Sudah diperbaiki | Klaim undangan: rate limit per IP, akun harus aktif, kunci perangkat wajib, toko harus terdaftar pada owner dan termasuk toko akun. | `relay/lib/server.dart` (`_claimInvite`, `_ownerStoreAllowed`) |
| P2-07 | Sudah diperbaiki | Pembuatan undangan menolak TTL di luar 1–1440 menit, akun nonaktif, dan toko yang tidak terdaftar/tidak menjadi hak akun. | `relay/lib/server.dart` (`_createInvite`) |
| P2-08 | Sudah diperbaiki | Relay memakai ulang baris perangkat karyawan yang sama (owner+akun+kunci publik) saat login; aplikasi memakai ulang pasangan kunci lokal sehingga login berulang tidak menambah perangkat. | `relay/lib/server.dart` (`_employeeLogin`), `pusatkupos/lib/data/employee_auth_service.dart` |
| P2-09 | Sudah diperbaiki | Pemangkasan amplop hanya menghitung perangkat relevan: semua perangkat owner + satu perangkat karyawan terbaru per akun, sehingga perangkat lama yang tidak pernah ack tidak menahan pemangkasan. | `relay/lib/server.dart` (`_pruneAcknowledged`) |
| P2-10 | Sudah diperbaiki | Bentrok `seq` menghasilkan `409 seq_conflict`, bukan id karangan; klien memberi nomor seq baru agar amplop dikirim ulang, bukan ditandai terkirim. | `relay/lib/server.dart` (`_ingestEnvelope`), `pusatkupos/lib/sync/sync_service.dart` (`_failOutbox`) |

#### Kelompok 4 — estimasi, kompensasi, laporan, dan qty desimal (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| P2-01 | Sudah diperbaiki | Laba kotor part dan jasa dihitung dari `subtotal - diskon_alokasi`; label laporan menyebut “setelah diskon”. | `pusatkupos/lib/data/app_database.dart` (`reportSummary`), `ui/screens/reports_screen.dart` |
| P2-13 | Sudah diperbaiki | Perubahan kompensasi karyawan (gaji, komisi, payroll, bank, status aktif) menaikkan HLC lalu meng-enqueue entitas `employee`; perangkat pasangan menerapkannya. | `data/employee_service.dart`, `sync/sync_service.dart` |
| P2-16 | Sudah diperbaiki | Detail estimasi memiliki aksi **Revisi** (qty, diskon, alasan) dan **Batalkan**; keduanya menulis status/HLC dan meng-enqueue sinkronisasi. | `data/order_service.dart` (`cancelEstimate`), `ui/screens/estimates_screen.dart` |
| P2-14 | Sudah diperbaiki | Qty part menerima desimal hingga 3 digit (mis. 0,5 L) di POS, revisi estimasi, retur, struk, detail nota, dan laporan. Kolom `jumlah_milli` ditambahkan ke `service_parts`, `sale_return_items`, dan `estimate_items` lewat skema v3 + backfill; sisa stok, pergerakan stok, komisi, dan sinkronisasi memakai milli. | `data/schema.dart`, `data/app_database.dart`, `data/models.dart`, `data/price_rules.dart`, `data/order_service.dart`, `data/sale_return_service.dart`, `data/note_sync.dart`, `data/receipt_service.dart`, `printer/receipt_builder.dart`, `ui/screens/pos_screen.dart`, `ui/screens/estimates_screen.dart`, `ui/screens/history_screen.dart` |
| P3 | Sudah diperbaiki | Pembayaran sebagian diberi label `DP` dan pelunasan penuh `PELUNASAN`; izin retur dipisahkan dari `void` (peran kasir/keduanya mendapat `retur`). | `data/app_database.dart`, `data/account_service.dart`, `ui/screens/history_screen.dart` |

#### Kelompok 5 — kasus tepi transaksi, stok, dan estimasi (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| U-01 | Sudah diperbaiki | Void mengembalikan stok memakai `jumlah_milli`, bukan `jumlah` yang sudah dibulatkan ke bawah. Barang 1,5 L kembali 1,5 L dan `stock_movements` mencatat angka yang sama. | `pusatkupos/lib/data/app_database.dart` (`voidRecord`) |
| U-02 | Sudah diperbaiki | Verifikasi PIN/persetujuan diskon dipindah ke luar `db.transaction`, sehingga penghitung gagal di `login_guards` tetap tersimpan saat PIN salah dan lockout benar-benar aktif. | `pusatkupos/lib/data/app_database.dart` (`createTransaction`) |
| U-03 | Sudah diperbaiki | Stok divalidasi terhadap total qty per `stock_item_id`; keranjang POS menggabungkan baris barang yang sama. Dua baris @3 dengan stok 5 kini ditolak, bukan menghasilkan stok −1. | `data/app_database.dart`, `ui/screens/pos_screen.dart` |
| U-04 | Sudah diperbaiki | Konversi estimasi memakai `requestId = estimasi:<sync_id>` (unik di database) dan update status hanya berlaku bila `status = 'aktif'` serta mengenai tepat satu baris. Klik ganda tidak lagi membuat dua nota. | `data/order_service.dart` (`convertEstimateToNote`), `data/app_database.dart` |
| U-05 | Sudah diperbaiki | `varianceReport` memakai `isoStartOfDay`/`isoEndOfDay` seperti laporan lain, sehingga batas tanggal tidak bergeser 7 jam di WIB. | `data/order_service.dart` |
| U-06 | Sudah diperbaiki | `waktu_selesai` hanya ditulis saat status menjadi `selesai`; transisi ke `diambil` tidak lagi mengosongkannya. | `data/order_service.dart` (`changeStatus`) |
| U-07 | Sudah diperbaiki | Perhitungan ulang komisi tidak lagi melewati margin negatif, sehingga hasilnya sama dengan saat nota dibuat. `_splitShare` membagi sisa (termasuk total negatif) dengan jumlah yang tetap sama dengan total. | `data/app_database.dart` (`recalculateRecordCommissions`, `_splitShare`) |
| U-08 | Sudah diperbaiki | Void membuka kembali estimasi asal (`aktif`, `converted_nota_sync_id = NULL`) dan melepas `work_orders.nota_sync_id`, lalu meng-enqueue keduanya. | `data/app_database.dart` (`voidRecord`), `ui/screens/history_screen.dart` |
| U-09 | Sudah diperbaiki | Subtotal baris estimasi memakai `subtotal - diskon_alokasi` sehingga jumlah baris sama dengan total dokumen; pemilihan baris di bawah modal tidak lagi berpotensi melempar `StateError`. | `data/order_service.dart` (`createEstimate`), `data/price_rules.dart` |
| U-10 | Sudah diperbaiki | Edit stok menerapkan selisih terhadap stok terkini (`stokAwalMilli`), bukan menimpa absolut, sehingga penjualan yang terjadi saat dialog terbuka tidak hilang. | `data/app_database.dart` (`saveStockItem`), `ui/screens/stock_screen.dart` |

Catatan yang sengaja belum diubah (butuh keputusan pemilik): basis komisi tetap memakai jasa dan margin **sebelum** diskon; label cicilan tetap `DP` sampai cicilan terakhir; `parseQuantityToMilli("1.500")` pada satuan berdesimal dibaca 1,5 (semua pemanggil sudah menolak nol/negatif); lockout login masih berbasis jam perangkat.



#### Kelompok 6 — temuan audit lanjutan: seq relay, izin stok, koreksi, backup, void (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| B-01 | Sudah diperbaiki | Urutan `relay_seq` dijamin per toko dengan `pg_advisory_xact_lock(hashtext(owner), hashtext(store))` pada amplop tunggal dan batch. Celah nomor akibat rollback tidak berbahaya karena feed memakai `relay_seq > since`. | `relay/lib/server.dart` (`_lockStore`, `_ingestEnvelope`) |
| B-02 | Sudah diperbaiki | Perangkat karyawan boleh mengirim perubahan **jumlah** stok bila punya `ubah_stok`; perubahan harga dari karyawan ditolak sebagai konflik final `harga_dikunci_owner` sehingga delta tidak lagi tertahan permanen dan kursor tetap maju. | `relay/lib/auth_rules.dart`, `pusatkupos/lib/sync/sync_conflict_rules.dart`, `sync/sync_service.dart` |
| B-03 | Sudah diperbaiki | Backup otomatis memakai passphrase yang disimpan di SecureStore, minimal 8 karakter, dapat dilihat/disalin dari Pengaturan; caption Telegram menandai arsip terkunci. Arsip Telegram kini dapat dipulihkan di perangkat lain. | `data/backup_service.dart`, `ui/screens/settings_screen.dart` |
| B-04 | Sudah diperbaiki | Koreksi nota: (1) PIN/approval diverifikasi di luar transaksi agar hitungan gagal tidak ikut rollback; (2) target dihitung di dalam transaksi, termasuk mode `selisih`, sehingga koreksi bersamaan tidak saling menimpa; (3) total efektif memakai `nilai_baru` terakhir menurut HLC, bukan `SUM(nilai_selisih)`; (4) modal part memakai `COALESCE(jumlah_milli, jumlah * 1000)`. Berlaku di layar koreksi, laporan, refund retur, dan penerimaan remote. | `data/nota_adjustment_service.dart`, `data/app_database.dart` (`recalculateRecordTotals`, `reportSummary`), `data/sale_return_service.dart`, `sync/sync_service.dart` |
| B-05 | Sudah diperbaiki | Void dari perangkat lain tidak lagi mengembalikan qty yang sudah diretur, menolkan `sisa_bayar`, dan REFUND ikut disinkronkan lewat amplop `note_payment` agar kas perangkat lain sama. | `data/app_database.dart` (`voidRecord`), `data/note_sync.dart`, `ui/screens/history_screen.dart` |
| B-06 | Sudah diperbaiki | Izin `nota` di relay dipilah per aksi: `void` butuh `void`, `warranty`/`taken` butuh `ubah_status`, lainnya `buat_nota`; konflik izin dicatat final dan tidak memblokir kursor. | `relay/lib/auth_rules.dart`, `sync/sync_conflict_rules.dart`, `sync/sync_service.dart` |
| B-07 | Sudah diperbaiki | `/relay/followup/quota` memerlukan token perangkat; aplikasi mengirim token hasil pairing dan jatuh ke kuota lokal bila belum dipasangkan. | `relay/lib/server.dart` (`_followupQuota`), `data/followup_service.dart` |
| B-08 | Sudah diperbaiki | Perbandingan token admin relay memakai waktu konstan. | `relay/lib/server.dart` (`_admin`, `_constantTimeEquals`) |
| B-09 | Sudah diperbaiki | Konflik `review` dan konflik final tidak lagi menghalangi snapshot/backup; `blockingConflictCount` hanya menghitung delta yang belum diterapkan. | `sync/sync_service.dart` (`blockingConflictCount`, `_requireCleanBeforeUpload`) |
| B-10 | Sudah diperbaiki | Kolom lama `jumlah` memakai `wholeQuantity(milli)` yang membulatkan ke bawah untuk nilai negatif, dipakai di stok, retur, void, dan jalur sinkronisasi. | `core/quantity.dart`, `data/app_database.dart`, `data/note_sync.dart`, `data/sale_return_service.dart`, `sync/sync_service.dart` |

Catatan: payload stok memang sudah membawa `jumlah_milli`; kecurigaan soal kuantitas stok yang hilang tidak terbukti. Masalah sebenarnya adalah entitas `stock` diperlakukan sebagai entitas harga sehingga seluruh delta ditolak (B-02).

#### Kelompok 7 — penyempurnaan tanpa fitur baru: refund retur, passphrase, duplikasi SQL, batas relay (selesai 5 November 2026)

| ID | Status | Perubahan | File |
|---|---|---|---|
| C-01 | Sudah diperbaiki | Refund tunai retur dibatasi kas yang benar-benar diterima: `max(0, dibayar - max(0, total_efektif - retur))`, lalu dibatasi nilai retur. Setelah koreksi nota menjadi 0, retur barang yang belum dibayar tidak lagi menghasilkan REFUND tunai. | `data/sale_return_service.dart` (`createReturn`) |
| C-02 | Sudah diperbaiki | Passphrase backup memakai batas yang sama di semua jalur: manual, simpan pengaturan, dan `createBackup` menolak kurang dari 8 karakter dengan pesan `BackupResult`/snackbar, bukan `ArgumentError` mentah. Teks bantuan dialog ikut disamakan. | `data/backup_service.dart` (`createBackup`, `setAutoPassphrase`), `ui/screens/settings_screen.dart` (`_saveBackup`, `_promptPassphrase`) |
| C-03 | Sudah diperbaiki | `_backupPassphrase` di-dispose bersama controller lain di `SettingsScreen`. | `ui/screens/settings_screen.dart` (`dispose`) |
| C-04 | Sudah diperbaiki | Rumus total koreksi terakhir dan modal nota disatukan sebagai `AppDatabase.latestAdjustmentTotalSql` dan `recordModalSql`, lalu dipakai oleh hitung ulang total, laporan, koreksi nota, refund retur, dan penerimaan koreksi remote. Fallback mati di `_currentTotal` dan `actor?.label ?? 'Pemilik'` yang tidak terjangkau dihapus. | `data/app_database.dart`, `data/nota_adjustment_service.dart`, `data/sale_return_service.dart`, `sync/sync_service.dart` |
| C-05 | Sudah diperbaiki | Relay membatasi body: 16 MB untuk permintaan biasa dan `RELAY_STORAGE_LIMIT_BYTES` + 8 MB untuk snapshot; kelebihan ditolak `413 body_too_large`, JSON tidak valid `400 invalid_body`. Batas penyimpanan toko kini menolak (`413 storage_full`), bukan hanya memberi peringatan, setelah amplop yang sudah diakui dipangkas lebih dulu. Entity `stock_movement` mewajibkan izin `ubah_stok`, sama dengan klien. | `relay/lib/server.dart` (`_body`, `_BodyTooLarge`, `_storeBytes`, `_ingestEnvelope`, pemangkasan pra-transaksi), `relay/lib/auth_rules.dart` |
| C-06 | Sudah diperbaiki | Skrip relay tidak lagi menunjuk path Dart pengembang. `start-relay.ps1` mencari `DART` lalu `FLUTTER_ROOT\bin\dart.bat` lalu `PATH`, dan memberi pesan jelas bila tidak ditemukan. README memuat batas body/penyimpanan serta izin entity karyawan yang baru. | `relay/start-relay.ps1`, `relay/README.md` |

---

# Bagian III — Laporan Perbaikan dan Audit Menyeluruh

Tanggal: 5 November 2026
Cakupan: `pusatkupos/` (Flutter + SQLite/SQLCipher) dan `relay/` (Dart Shelf + PostgreSQL)
Referensi fitur struk: `github.com/ptbanditindo/aplikasiposbengkel` (Python/FastAPI)

Status: seluruh temuan P0, P1, P2, kelompok audit lanjutan B-01–B-10, dan
penyempurnaan C-01–C-06 sudah diperbaiki, editor struk v2 sudah dibangun, dan
sembilan fitur lanjutan sudah ditulis ke kode. Tidak ada dependency baru yang
dipasang. Dokumen ini hanya memuat keadaan kode saat ini.

---

### 1. Ringkasan

- **Tahap 2 selesai:** skema bersih, SQLCipher, aturan harga dan batas modal,
  koreksi append-only, jenis transaksi/tahap/preset/izin, estimasi dan
  konversinya, work order dan log status, sinkron terjadwal/batch/retensi/
  rekonsiliasi, serta peran dan kode pairing.
- **Tahap lanjutan selesai:** backup multi-toko format 3, retur penjualan
  tingkat baris beserta sinkronisasinya, editor struk v2, dan tujuh fitur struk
  (logo raster, WhatsApp, ekspor/impor JSON, pratinjau debounce + validasi
  inline, jatuh tempo + banner pelunasan, diskon per baris, pratinjau 58/80 mm).
- **Audit lanjutan selesai (B-01–B-10):** urutan `relay_seq` dikunci per toko,
  konflik izin/harga bersifat final tanpa memblokir kursor, koreksi nota
  memakai nilai absolut terakhir, void menyinkronkan REFUND, passphrase backup
  dapat dipulihkan, dan pembulatan kuantitas negatif konsisten.
- **Penyempurnaan selesai (C-01–C-06):** refund retur dibatasi kas diterima,
  passphrase backup seragam 8 karakter, duplikasi rumus koreksi/modal
  disatukan, relay membatasi body dan menolak penyimpanan penuh, dan skrip
  relay tidak lagi memakai path Dart pengembang.
- **Skema naik ke versi 2 secara aditif.** Migrasi menambah kolom dan tabel
  retur tanpa menghapus data; database versi 1 tetap dapat dibuka.
- **Relay tetap buta isi.** Relay hanya menyimpan amplop terenkripsi dan tidak
  membaca transaksi, harga, atau tanggal transaksi.
- **Tidak ada dependency baru.** Seluruh fitur memakai paket yang sudah ada.

Audit menemukan tujuh kelas masalah utama. Semuanya sudah ditutup:

| Area | Temuan audit | Keadaan sekarang |
|---|---|---|
| Backup/restore | Backup Android tidak dapat dipulihkan, restore tidak atomik, hanya satu toko | Format 3 multi-toko, validasi semua payload, safety `.bak`, replace atomik, registry dibangun ulang |
| Relay/auth | Viewer dapat naik menjadi owner; entity dapat dipalsukan; bootstrap lintas toko | Scope token per peran, pengelolaan akun hanya owner, hash server-side, `hints_signature` wajib, cek keanggotaan toko |
| Sinkronisasi | Delta ditolak tetap di-ack; snapshot lama menimpa data baru; logout tidak mencabut token | Tri-state apply, snapshot non-regresi, seq floor, rahasia per toko, pencabutan token/kunci |
| Transaksi/harga | Modal jasa tidak dihitung; konversi estimasi memakai harga saat ini; diskon terpotong | Modal jasa masuk laporan, konversi memakai harga estimasi, alokasi diskon tanpa truncation |
| UI | Aksi gagal tanpa pesan, state basi, race | `try/catch/finally`, epoch load, `AppState.touch()`, validasi inline |
| Printer | Lebar dokumen salah, status cetak tidak jujur, codepage tidak dipilih | Dokumen dibangun ulang sesuai printer, status dibedakan, codepage + transliterasi |
| Struk | Hanya toggle dan empat teks | Template v2 lengkap, 58/80, logo, WhatsApp, JSON, diskon baris, jatuh tempo, banner pelunasan |
| Audit lanjutan | `relay_seq` dapat terlewat, delta stok tertahan, koreksi ganda, passphrase backup tidak dapat dipulihkan | Advisory lock per toko, konflik final tanpa blokir kursor, total koreksi absolut, passphrase dapat dilihat/disalin |

---

### 2. Metode dan Batas Audit

- Audit dilakukan dengan membaca kode sumber langsung dan menyusuri pemanggil.
- Tidak ada dependency baru yang dipasang selama audit maupun perbaikan.
- Sesi terakhir tidak memiliki SDK Flutter/Dart, sehingga verifikasi bersifat
  statis: keseimbangan delimiter, pencocokan simbol antar-lapis, dan
  penelusuran jalur data. Pemeriksaan perilaku dilakukan pemilik lewat APK atau
  localhost.

Definisi severity:

| Kode | Arti |
|---|---|
| P0 | Kehilangan data, bypass keamanan, atau fitur inti tidak berfungsi |
| P1 | Salah hitung/salah perilaku yang terlihat pengguna, atau kegagalan yang sulit dipulihkan |
| P2 | Bug logika terbatas, edge case, atau risiko operasional |
| P3 | Kebersihan kode, konsistensi, atau perbaikan kecil |

---

### 3. Peta Kode

#### 3.1 Struktur proyek

```text
posapk-main/
├── pusatkupos/                 aplikasi Flutter
│   ├── lib/
│   │   ├── app.dart, main.dart
│   │   ├── auth/               Operator, izin
│   │   ├── core/               uang, tanggal, kuantitas, ID, WA, file
│   │   ├── data/               database, layanan domain, backup, retur, struk
│   │   ├── sync/               protokol, kripto, klien relay, snapshot
│   │   ├── printer/            ESC/POS, raster logo, adapter BT/USB/network
│   │   ├── state/              AppState
│   │   └── ui/                 layar dan dialog
│   ├── android/                bridge printer Kotlin
│   └── web/                    wasm SQLite + service worker
└── relay/                      server sinkronisasi + lisensi
    ├── lib/server.dart         seluruh endpoint
    ├── lib/db.dart             PostgreSQL
    ├── lib/auth_rules.dart     aturan entity per peran
    ├── lib/license.dart        tanda tangan lisensi
    └── lib/google.dart         login Google
```

#### 3.2 Modul dan tanggung jawab

| Modul | Tanggung jawab | Risiko utama |
|---|---|---|
| `lib/data/app_database.dart` | Skema v2, transaksi, stok, laporan, void, piutang, nomor dokumen | Titik pusat logika bisnis |
| `lib/data/schema.dart` | DDL, indeks, tabel sinkron, tabel retur | Perubahan skema harus aditif |
| `lib/data/order_service.dart` | Estimasi, konversi, work order | Harga konversi |
| `lib/data/sale_return_service.dart` | Retur tingkat baris, refund, stok kembali | Sisa jumlah dan pembulatan |
| `lib/sync/sync_service.dart` | Outbox/inbox, enroll, feed, snapshot | Ack semantik, cursor |
| `lib/data/note_sync.dart` | Terapkan nota + retur dari perangkat lain | Renumber nota, pemetaan stok |
| `lib/data/followup_service.dart` | Follow-up, status, WA | Status arsip |
| `lib/data/backup_service.dart` | ZIP backup multi-toko, restore, Telegram | SQLCipher, atomisitas |
| `lib/data/store_registry.dart` | Daftar toko dan toko aktif | Konsistensi setelah restore |
| `lib/data/account_service.dart` | Akun karyawan, izin | Lisensi, actor null |
| `lib/data/employee_service.dart` | Payroll, komisi, utang | Siklus gaji |
| `lib/data/store_settings.dart` | Jenis transaksi, peran, preset | Filter store |
| `lib/data/receipt_template.dart` | Template struk v2, JSON, validasi, migrasi | Kompatibilitas data lama |
| `lib/data/receipt_service.dart` | Susun blok struk, label, pembayaran, VOID | Konten dan perataan |
| `lib/printer/receipt_builder.dart` | Baris bergaya, pembungkusan, nominal | Lebar kolom |
| `lib/printer/printer_service.dart` | Payload struk, logo raster, cetak | Lebar printer, status |
| `lib/printer/escpos_builder.dart` | Byte ESC/POS, codepage, transliterasi | Encoding |
| `lib/ui/screens/receipt_settings_screen.dart` | Editor 6 tab, pratinjau, JSON | Validasi input |
| `lib/ui/receipt_dialog.dart` | Pratinjau 58/80, WhatsApp, cetak | State dokumen |
| `relay/lib/server.dart` | Semua endpoint | Otorisasi |
| `relay/lib/auth_rules.dart` | Entity per peran | Hanya hint tanda tangan |

#### 3.3 Alur inti

**Transaksi kasir**

```text
POS screen
  → AppDatabase.createTransaction()
    → validasi jenis/peran/diskon
    → verifikasi harga master (jasa & stok)
    → PriceRules.allocate()
    → INSERT service_records, jobs, parts, payments, stock_movements
    → UPDATE stok, work_order, estimate
    → enqueue() ke sync_outbox
```

**Sinkronisasi**

```text
enqueue → sync_outbox (seq per device)
  → POST /relay/envelopes/batch
  → relay simpan amplop terenkripsi + relay_seq
  → device lain GET /relay/feed?since=cursor
  → sync_service.applyEnvelope()
  → INSERT applied_deltas + update cursor
  → POST /relay/feed/ack
```

**Retur**

```text
Riwayat → dialog retur (sisa per baris)
  → SaleReturnService.createReturn()
    → INSERT sale_returns + sale_return_items
    → UPDATE stok part + INSERT stock_movements (MASUK)
    → permission_audits
    → enqueue nota (payload membawa returns)
  → laporan: omzet neto = bruto - retur
```

**Backup**

```text
checkpoint → ekspor tiap toko ke plaintext sementara
  → SHA-256 + AES-256-GCM per toko
  → ZIP (manifest.json + stores/<n>.db.enc)
  → simpan ke file / upload Telegram
restore → validasi semua checksum + header SQLite
  → safety .bak → replace atomik → registry → reopen
```

**Struk**

```text
ReceiptService.build(recordId, width)
  → baca template v2 dari app_settings
  → susun blok (header, meta, items, totals, payment, warranty, bank, footer)
  → ReceiptDocument(lines, width, logo, copies, codepage)
  → PrinterService.printReceipt()
    → ESC/POS: teks bergaya + logo GS v 0
    → TEXT/SYSTEM/BROWSER: teks polos
```

---

### 4. Temuan Audit dan Perbaikan

#### 4.1 P0 (Kritis) — sudah diperbaiki

| ID | Masalah | Perbaikan |
|---|---|---|
| P0-01 | Backup Android berisi database SQLCipher, sedangkan restore memvalidasi header plaintext lalu membukanya dengan SQLite biasa | Ekspor plaintext terkontrol (`sqlcipher_export`) sebelum validasi; restore memahami format terenkripsi |
| P0-02 | Restore menyalin berkas sebelum semua validasi selesai; kegagalan di tengah menghasilkan database kosong | Validasi semua payload lebih dulu, safety `.bak`, replace atomik, rollback saat gagal |
| P0-03 | Backup hanya berisi satu database toko | Format 3: manifest `stores[]` + payload per toko; format lama tetap dapat dipulihkan |
| P0-04 | Viewer dapat membuat kode pairing owner dan menulis akun | Scope token per peran; pengelolaan akun hanya owner; hash password di server; hash tidak dikirim balik |
| P0-05 | Karyawan dapat memalsukan entity pada amplop | `hints_signature` wajib dan diverifikasi relay; client memeriksa ulang entity hasil dekripsi |
| P0-06 | Bootstrap tidak memeriksa keanggotaan toko | Relay menolak bootstrap lintas toko (403) |
| P0-07 | Snapshot lama dapat menimpa data yang lebih baru | Snapshot non-regresi: cursor/seq lebih tinggi tidak ditimpa |
| P0-08 | Delta yang ditolak tetap ditandai `applied_deltas` dan di-ack | Tri-state apply; hanya delta yang benar-benar diterapkan yang di-ack |
| P0-09 | Logout tidak mencabut token dan kunci sinkronisasi | Logout/pencabutan menghapus token, kunci per toko, dan menghentikan sync |
| P0-10 | Pairing memasang akun dari objek yang tidak ditandatangani | Akun dipasang dari payload bertanda tangan; klaim kedua ditolak |

#### 4.2 P1 (Tinggi) — sudah diperbaiki

| Area | ID | Perbaikan |
|---|---|---|
| Transaksi & laporan | P1-01 | Modal jasa dihitung (`totalModalJasaCents`) dan masuk laba |
| | P1-02 | Konversi estimasi memakai harga estimasi per baris; perubahan harga master dikonfirmasi |
| | P1-03, P1-04 | Alokasi diskon dengan batas per baris; sisa pembulatan didistribusikan; total tanpa truncation |
| | P1-05 | Baris menyimpan harga final dan alokasi diskon; struk menampilkan diskon per baris |
| | P1-06, P1-07 | Kuantitas desimal didukung; parser format Indonesia membedakan ribuan dan desimal |
| | P1-08 | `actor == null` tidak lagi otomatis dianggap owner |
| Sinkronisasi | P1-09 | `device.seq_floor` dipertahankan sebelum pemangkasan outbox |
| | P1-10, P1-11 | Timeout HTTP/watchdog; envelope penyebab dicari dari detail relay |
| | P1-12 | Token, store key, dan kunci signing disimpan per `store_id` |
| | P1-13 | Epoch `key_id`; kegagalan dekripsi menjadi hard stop |
| | P1-14 | Snapshot/bootstrap wajib sebelum feed pertama |
| | P1-15 | Retry konflik menyimpan dan mengirim ulang envelope asli |
| | P1-16 | Estimasi versi lebih tinggi mengganti item |
| | P1-17, P1-18 | Digest di-upsert per `(store_id, source_device_id, tanggal, data_type)`; tanggal lokal eksplisit |
| | P1-19 | Nomor nota hasil resolusi konflik dikirim ulang sebagai koreksi |
| | P1-20 | Scheduler memakai `try/finally` dan interval awal yang benar |
| UI | P1-21 | Kartu pairing membaca `store_ids_json` dan meminta pilih toko |
| | P1-22 | Backup memakai `try/catch/finally` dan menampilkan pesan |
| | P1-23 | Hasil load karyawan dibuang bila pilihan berubah |
| | P1-24, P1-25 | Gate diskon UI sama dengan service; diskon > bruto ditolak sebelum simpan |
| | P1-26 | Garansi 1 bulan tidak lagi ditimpa default |
| | P1-27, P1-31 | `AppState.touch()` setelah simpan pengaturan/order |
| | P1-28 | Load laporan memakai token epoch + `finally` |
| | P1-29 | Alasan void < 3 karakter ditolak inline, dialog tidak tertutup |
| | P1-30 | Edit stok absolut hanya untuk owner; non-owner diarahkan ke opname |
| | P1-32 | Tombol cetak menangani error dokumen |
| Printer | P1-33 | Dokumen dibangun ulang sesuai lebar printer target |
| | P1-34 | Status cetak membedakan dialog dibuka dan selesai |
| | P1-35, P1-36 | Alamat printer aktif diperiksa; BLE reconnect setelah GATT drop |
| | P1-37 | Codepage CP437/CP850/CP1252 + transliterasi |
| | P1-38, P1-39 | MTU dinegosiasikan; write/flush/close memiliki timeout |
| | P1-40, P1-41 | Perbandingan halaman 1-based; ukuran font dihitung dari lebar halaman |
| Backup & akun | P1-42 | Retry Telegram dibatasi ke folder backup dan pola nama file |
| | P1-43 | Arsip dienkripsi; rahasia tidak ikut diekspor |
| | P1-44 | Restore meregenerasi `kode_lokal` dan mereset counter |
| | P1-45 | Semua operasi akun memeriksa lisensi |
| | P1-46 | Profil/izin disegarkan; akun nonaktif dipaksa logout |
| | P1-47, P1-48 | Rentang gaji mingguan benar; payroll dihitung di dalam transaksi pembayaran |

#### 4.3 P2/P3 — sudah diperbaiki

| Kelompok | ID | Perbaikan |
|---|---|---|
| Sync | P2-01–P2-05 | Clamp skew HLC; verifikasi seluruh field inner; transaksi + indeks unik seq; inbox gagal tidak memblokir feed; pemangkasan `applied_deltas` mengikuti cursor peer |
| Data | P2-06–P2-18 | Filter `store_id`; baca-lalu-tulis dalam transaksi; arsip manual dipertahankan; `LoginGuard` atomik; persetujuan fail-closed; jadwal backup tahan jam mundur; normalisasi nomor 62; pembulatan kuantitas; simpan pengaturan transaksional; konsistensi pembayaran; audit pengambilan unit |
| UI | P2-19–P2-30 | `hasError` + retry; `try/catch` pada aksi; validasi harga/bonus/field; `PopScope` saat sibuk; chip navigasi valid; dispose controller; cek `mounted`; `formatQuantity`; pesan stok kurang |
| Printer | P2-31–P2-39 | Bungkus baris; timeout proporsional; BLE tanpa nama; GATT ditutup; listener scan dibatalkan; JSON printer `.bak` + tulis atomik; encoding dipertahankan; identitas USB memakai `deviceId`/serial |

#### 4.4 Akar masalah lintas modul

1. **Sumber kebenaran ganda.** Pengaturan toko, identitas, dan konfigurasi
   printer dibaca dari tempat berbeda; kini dinormalisasi di layanan domain.
2. **`actor == null` dianggap owner.** Pola ini sudah dihapus; actor wajib atau
   flag owner eksplisit.
3. **Sinkronisasi mempercayai petunjuk luar.** Relay memverifikasi tanda tangan
   dan klien memeriksa ulang entity hasil dekripsi.
4. **Ack lebih cepat dari penerapan.** `applied_deltas` hanya ditulis untuk delta
   yang benar-benar diterapkan.
5. **Asumsi plaintext pada backup.** Jalur ekspor/impor kini SQLCipher-aware.
6. **Zona waktu campur.** Tanggal lokal eksplisit dipakai untuk digest dan
   laporan; timestamp tetap ISO UTC.
7. **Pembulatan rupiah tidak eksplisit.** Alokasi diskon dan sisa unit memiliki
   aturan yang konsisten.
8. **UI menduplikasi aturan bisnis.** Gate diskon dan izin disamakan dengan
   service.
9. **`catch` menelan error.** Aksi kritis menampilkan pesan dan tidak mengunci
   tombol.

#### 4.5 Kelompok audit lanjutan B-01–B-10 (sudah diperbaiki)

| ID | Severity | Masalah | Perbaikan |
|---|---|---|---|
| B-01 | P1 | `relay_seq BIGSERIAL` dapat ter-commit tidak berurutan antar transaksi sehingga perangkat melewati amplop yang commit belakangan | `pg_advisory_xact_lock(hashtext(owner), hashtext(store))` pada submit tunggal dan batch; celah nomor akibat rollback aman karena feed memakai `relay_seq > since` |
| B-02 | P1 | Perangkat karyawan mengubah stok ditolak oleh aturan harga sehingga delta tertahan permanen dan kursor tidak maju | `priceEntities` hanya `harga_jasa`; jumlah stok diterapkan bila punya `ubah_stok`, perubahan harga dicatat final `harga_dikunci_owner` tanpa memblokir kursor |
| B-03 | P1 | Passphrase backup otomatis tidak dapat dilihat sehingga arsip Telegram tidak dapat dipulihkan | Passphrase disimpan di SecureStore, minimal 8 karakter, dapat dilihat/disalin dari Pengaturan; caption Telegram menandai arsip terkunci |
| B-04 | P1 | Koreksi nota: PIN di dalam transaksi, `SUM(nilai_selisih)` ganda, dan modal part memakai `jumlah` bulat | Approval di luar transaksi; total efektif = `nilai_baru` terakhir menurut HLC di semua jalur (layar, laporan, refund retur, terima remote); modal memakai `jumlah_milli` |
| B-05 | P2 | Void lewat sinkronisasi mengabaikan retur dan tidak mengirim REFUND | Restock qty sisa, `sisa_bayar = 0`, REFUND dikirim sebagai amplop `note_payment` dari dalam transaksi void |
| B-06 | P2 | Izin `nota` dan `void` dari perangkat karyawan tidak dipilah per aksi | Relay memeriksa `void`/`ubah_status`/`buat_nota` sesuai aksi; pelanggaran dicatat final |
| B-07 | P2 | `/relay/followup/quota` dapat dipanggil tanpa autentikasi | Wajib token perangkat; tanpa pairing aplikasi memakai kuota lokal |
| B-08 | P2 | Token admin relay dibandingkan dengan `==` | Perbandingan waktu konstan `_constantTimeEquals` |
| B-09 | P3 | Konflik `review` menghalangi snapshot dan backup | `blockingConflictCount` hanya menghitung delta yang belum diterapkan; konflik final berstatus `rejected` |
| B-10 | P3 | Pembulatan `~/ 1000` ke arah nol membuat stok negatif pecahan tampil salah | `wholeQuantity(milli)` membulatkan ke bawah untuk nilai negatif, dipakai di stok, opname, retur, void, dan jalur sinkronisasi |

Catatan: payload stok memang sudah membawa `jumlah_milli`; kecurigaan kuantitas
stok hilang tidak terbukti. Akar masalahnya adalah `stock` diperlakukan sebagai
entitas harga pada aturan konflik (B-02).

#### 4.6 Penyempurnaan C-01–C-06 (sudah diperbaiki)

Kelompok ini tidak menambah fitur; isinya memperbaiki perilaku yang sudah ada
dan membersihkan duplikasi.

| ID | Severity | Masalah | Perbaikan |
|---|---|---|---|
| C-01 | P1 | Retur setelah nota dikoreksi menjadi 0 memberikan REFUND tunai sebesar nilai barang walaupun pelanggan belum membayar | Refund dibatasi kas yang diterima: `max(0, dibayar - max(0, total_efektif - retur))`, lalu dibatasi nilai retur. Koreksi ke 0 pada nota yang belum dibayar menghasilkan refund 0 |
| C-02 | P2 | Backup manual menerima passphrase 6 karakter, backup otomatis mewajibkan 8, dan simpan passphrase pendek memunculkan `ArgumentError` mentah | Semua jalur memakai minimal 8 karakter dengan pesan `BackupResult`/snackbar; teks bantuan dialog disamakan |
| C-03 | P3 | `_backupPassphrase` tidak di-dispose | Dispose ditambahkan bersama controller lain |
| C-04 | P2 | Rumus total koreksi terakhir dan modal nota ditulis ulang di empat berkas; `_currentTotal` punya fallback mati dan ada `actor?.label ?? 'Pemilik'` yang tidak terjangkau | `AppDatabase.latestAdjustmentTotalSql` dan `recordModalSql` dipakai bersama; fallback mati dan null-coalescing berlebih dihapus |
| C-05 | P1 | Relay membaca body tanpa batas; batas penyimpanan hanya memberi peringatan; `stock_movement` diterima dari karyawan tanpa `ubah_stok` | Body dibatasi 16 MB (snapshot: batas penyimpanan + 8 MB) dengan `413 body_too_large`/`400 invalid_body`; penyimpanan penuh ditolak `413 storage_full` setelah pemangkasan amplop yang sudah diakui; `stock_movement` wajib `ubah_stok` |
| C-06 | P2 | `relay/start-relay.ps1` menunjuk path Dart milik satu pengembang | Skrip mencari `DART`, lalu `FLUTTER_ROOT\bin\dart.bat`, lalu `PATH`, dengan pesan jelas bila tidak ditemukan; README diperbarui |

---

### 5. Pekerjaan yang Sudah Selesai

#### 5.1 Sinkronisasi dan keamanan

| Area | Hasil |
|---|---|
| Skema | Skema bersih dengan `sync_id`, `store_id`, `device_id`, pasangan HLC, timestamp, dan tombstone pada semua tabel data. Database viewer terpisah per owner. |
| Enkripsi lokal | SQLCipher dengan kunci acak di SecureStore pada Android/iOS/macOS. Windows/Linux/web memakai SQLite biasa dan menampilkan keterangan di Pengaturan → Keamanan. |
| Harga | Modal menjadi batas bawah mutlak bagi selain pemilik; diskon maksimal sebesar selisih harga jual dan modal; persetujuan tidak dapat membuka batas itu. |
| Persetujuan | Mode penyetuju `owner` (PIN pemilik) atau `penanggung_jawab` (akun aktif dengan izin `setujui`), dengan `LoginGuard` terpisah. Saklar persetujuan diskon default mati. |
| Koreksi nota | Baris `nota_adjustments` baru; nota asli tidak diubah. Total efektif memakai `nilai_baru` terakhir menurut HLC (bukan `SUM`), target dihitung ulang di dalam transaksi, dan approval diverifikasi di luar transaksi. |
| Transaksi | Lima jenis transaksi, lima tahap order, tiga preset, izin per peran, dan snapshot mode saat transaksi dibuat. |
| Estimasi | Revisi append-only dengan `versi + 1` dan `revisi_dari_sync_id`; konversi ke nota menautkan `estimate_sync_id` dan `total_estimasi_terakhir`. |
| Work order | Nomor order dan nomor antrian harian per perangkat; log status append-only; status minimal saat tahap pengerjaan dimatikan. |
| Sinkron | Scheduler 15 menit (10–20 menit) dengan jitter, batch adaptif, retensi berbasis ack semua perangkat, peringatan penyimpanan relay, dan rekonsiliasi ringkasan harian. |
| Relay | Scope token per peran, pengelolaan akun hanya owner, hash password di server, `hints_signature` wajib, cek keanggotaan toko saat bootstrap, penolakan entity di luar izin, advisory lock urutan `relay_seq` per toko, perbandingan token admin waktu konstan, dan kuota follow-up yang memerlukan token perangkat. |
| Penerapan delta | Tri-state apply: delta yang ditolak tidak di-ack; konflik izin/harga bersifat final (`rejected`) sehingga kursor tetap maju; snapshot lama tidak menimpa data yang lebih baru; `applied_deltas` dibersihkan bersama cursor. |
| Void dan retur | Void mengembalikan qty yang belum diretur, menolkan `sisa_bayar`, dan meng-enqueue REFUND sebagai amplop `note_payment`; perangkat penerima menyamakan status tanpa membuat refund ganda. |
| Sesi | Logout dan pencabutan perangkat menghapus token serta kunci sync; rahasia disimpan per `store_id`. |
| Pairing | Kode karyawan enam karakter, berlaku 10 menit, sekali pakai; akun dipasang dari payload yang ditandatangani. |

#### 5.2 Fitur lanjutan (5 November 2026)

| Pekerjaan | Hasil | Berkas utama |
|---|---|---|
| Backup multi-toko | Format arsip 3: `manifest.json` berisi `stores[]`; setiap toko punya payload terenkripsi AES-256-GCM, checksum SHA-256, dan metadata cipher. Restore memvalidasi seluruh payload, membuat safety `.bak`, mengganti berkas secara atomik, membangun ulang registry, lalu membuka toko aktif. Format 1 dan 2 tetap didukung. Passphrase backup otomatis disimpan di SecureStore (minimal 8 karakter), dapat dilihat/disalin dari Pengaturan, dan arsip Telegram diberi caption terkunci agar dapat dipulihkan di perangkat lain. | `lib/data/backup_service.dart`, `lib/data/store_registry.dart`, `lib/data/app_database.dart`, `lib/data/backup_platform_io.dart`, `lib/ui/screens/settings_screen.dart` |
| Retur / penjualan neto | Tabel append-only `sale_returns` dan `sale_return_items`; retur per baris dengan sisa jumlah, refund proporsional dari harga neto, pengembalian stok part + `stock_movements`, audit `retur_nota`. Laporan memakai omzet neto, retur jasa/part, dan laba neto. | `lib/data/sale_return_service.dart`, `lib/data/schema.dart`, `lib/data/app_database.dart`, `lib/ui/screens/history_screen.dart`, `lib/ui/screens/reports_screen.dart` |
| Sinkron retur | Payload nota membawa `returns`; penerima membuat `sale_returns`/`sale_return_items`, memetakan stok lewat `stock_sync_id`, dan memakai `sync_id` pergerakan stok deterministik agar kedua sisi konvergen. Tabel retur ikut snapshot dan urutan hapus. | `lib/data/note_sync.dart`, `lib/sync/snapshot_sync.dart` |
| Editor struk v2 | Template JSON dengan blok, label, placeholder, validasi, migrasi dari 25 toggle + 4 teks lama, pratinjau, dan cetak percobaan. | `lib/data/receipt_template.dart`, `lib/data/receipt_settings.dart`, `lib/data/receipt_service.dart`, `lib/ui/screens/receipt_settings_screen.dart` |
| Logo raster struk | Logo file diubah menjadi bitmap 1-bit melalui `dart:ui`, lalu dicetak dengan `GS v 0` sebelum teks. Lebar logo 10–40 mm. Hanya berlaku untuk mode ESC/POS. | `lib/printer/printer_service.dart`, `lib/printer/escpos_builder.dart`, `lib/printer/logo_platform*.dart` |
| WhatsApp | Tombol membuka `https://wa.me/<nomor>?text=...`; nomor dinormalisasi 0/8 → 62 dan teks dipotong 3500 karakter. | `lib/ui/receipt_dialog.dart`, `lib/core/wa_link.dart` |
| Ekspor/impor template | Template v2 diekspor sebagai JSON dan diimpor kembali dengan validasi versi serta `validate()`. | `lib/ui/screens/receipt_settings_screen.dart`, `lib/data/receipt_template.dart` |
| Pratinjau debounce | Input dijadwalkan 300 ms; kesalahan validasi tampil sebagai strip peringatan, `errorText` per label, dan tombol simpan dinonaktifkan. | `lib/ui/screens/receipt_settings_screen.dart` |
| Jatuh tempo + pelunasan | POS meminta jatuh tempo selama masih ada sisa; tanggal disimpan, disinkronkan, dan dicetak. Banner `STRUK PELUNASAN` muncul untuk nota lunas hasil pelunasan order atau dengan lebih dari satu pembayaran. | `lib/ui/screens/pos_screen.dart`, `lib/data/app_database.dart`, `lib/data/note_sync.dart`, `lib/data/receipt_service.dart` |
| Diskon per baris | Setiap baris menyimpan harga terdaftar, harga final, dan alokasi diskon; struk mencetak harga terdaftar × jumlah lalu baris diskon. Harga neto dipakai untuk refund retur dan laporan. | `lib/data/models.dart`, `lib/data/app_database.dart`, `lib/data/receipt_service.dart` |
| Pratinjau 58/80 mm | Dialog struk memakai `SegmentedButton` 58/80 mm dan membangun ulang dokumen sesuai lebar kolom 32/48. | `lib/ui/receipt_dialog.dart` |

---

### 6. Skema Akhir (versi 2)

#### 6.1 Kelompok tabel

- **Identitas dan akses:** `app_settings`, `owner_identity`, `license`,
  `employee_accounts`, `permission_audits`, `devices`, `login_guards`.
- **Master:** `customers`, `vehicle_or_units`, `stock_items`, `harga_jasa`,
  `suppliers`, `supplier_items`, `supplier_followups`, `followup_items`,
  `followup_events`, `wa_message_logs`.
- **Transaksi:** `service_records`, `service_jobs`, `service_parts`,
  `service_payments`, `stock_movements`, `nota_adjustments`,
  `service_record_mechanics`, `service_record_commissions`, `employee_debts`,
  `salary_payments`, `sale_returns`, `sale_return_items`.
- **Aturan dan dokumen:** `store_settings`, `estimates`, `estimate_items`,
  `work_orders`, `work_order_status_log`, `document_counters`.
- **Sinkron dan rekonsiliasi:** `sync_outbox`, `sync_inbox`, `sync_cursor`,
  `applied_deltas`, `sync_conflicts`, `device_sync_status`, `day_digests`,
  `reconciliation_requests`, `sync_peer_digests`.

#### 6.2 Tambahan versi 2

- `sale_returns`: `sync_id`, `service_record_id`, `nota_sync_id`, `no_nota`,
  `no_retur`, `total`, `alasan`, `dibuat_oleh`, pasangan HLC, timestamp.
- `sale_return_items`: `sync_id`, `return_id`, `line_type`, `line_sync_id`,
  `deskripsi`, `jumlah`, `harga_satuan`, `subtotal`, `modal_satuan`,
  `stock_item_id`, pasangan HLC, timestamp.
- `service_records.jatuh_tempo` untuk nota dengan sisa pembayaran.
- Migrasi memakai `migrateSchemaV2` + `_addColumnIfMissing` + `createReturnTables`
  dan menaikkan `schemaVersion` menjadi 2.

#### 6.3 Kolom penting

- `service_records`: jenis transaksi, snapshot mode, referensi order/estimasi,
  `request_id` unik, status void, status pembayaran, dan jatuh tempo.
- `service_jobs` / `service_parts` / `estimate_items`: harga terdaftar, batas
  modal saat transaksi, harga final, alokasi diskon, alasan diskon, penyetuju.
- `nota_adjustments`: `nota_sync_id`, `nilai_selisih`, `nilai_baru`, `alasan`,
  `dibuat_oleh`, `disetujui_oleh`.
- `estimates`: nomor, versi, `revisi_dari_sync_id`, masa berlaku,
  `converted_nota_sync_id`, total estimasi terakhir.
- `work_orders`: nomor order, nomor antrian, status, mekanik, waktu masuk,
  snapshot mode, dan referensi nota.

---

### 7. Alur Akhir

#### 7.1 Nota, harga, dan persetujuan

1. Kasir memilih jenis transaksi dan barang/jasa. Harga modal tidak ditampilkan
   kepada kasir; untuk jasa dari daftar tarif, harga diverifikasi ulang.
2. `PriceRules.allocate` menyimpan harga final dan alokasi diskon per baris.
   Selain pemilik: harga akhir tidak boleh di bawah modal dan total diskon
   tidak boleh melebihi total margin.
3. Pemilik tetap dapat menjual di bawah modal; baris ditandai dan dicatat untuk
   audit.
4. Nota, baris, pembayaran, stok, audit, dan outbox ditulis dalam satu
   transaksi SQLite.
5. Batas modal dan margin tidak dapat dibuka oleh persetujuan siapa pun kecuali
   transaksi yang dibuat pemilik sendiri.
6. `approvalDiscount = true`: setiap diskon kasir meminta persetujuan sesuai
   mode penyetuju. `false` (default): diskon sampai margin langsung tersimpan
   dan tetap dicatat di `permission_audits`.

#### 7.2 Retur

1. Pengguna membuka nota di Riwayat dan memilih **Retur penjualan**.
2. Dialog menampilkan sisa jumlah per baris (dikurangi retur sebelumnya).
   Jumlah dan alasan divalidasi; minimal satu baris harus dipilih.
3. `SaleReturnService.createReturn` menulis header + item, mengembalikan stok
   part, menambah `stock_movements` bertipe MASUK, dan menulis audit.
4. REFUND tunai hanya sebesar kas yang benar-benar diterima
   (`max(0, dibayar - max(0, total_efektif - retur))`, dibatasi nilai retur),
   sehingga retur pada nota yang dikoreksi menjadi 0 dan belum dibayar tidak
   menghasilkan uang keluar.
5. Nota asli tidak berubah. Laporan mengurangi omzet dan laba dengan nilai
   retur neto.
6. Retur ikut payload sinkronisasi nota sehingga perangkat lain menerima
   header, item, penyesuaian stok, dan pergerakan stok yang sama.

#### 7.3 Estimasi dan work order

- Estimasi revisi membuat baris baru; konversi menautkan versi yang disetujui
  dan menampilkan selisih terhadap total estimasi terakhir.
- Perubahan status order selalu menambah baris log; status tidak ditimpa.
- Order baru mendapat nomor order dan nomor antrian harian per perangkat.
- Bila tahap status pengerjaan dimatikan pada snapshot order, daftar status
  menyusut menjadi `dibuka`, `selesai`, `diambil`, `batal`.

#### 7.4 Sinkronisasi

1. Scheduler berjalan tiap 15 menit dengan jitter dan saat aplikasi
   resume/tutup.
2. Outbox dikirim per batch adaptif; relay mengembalikan pemakaian penyimpanan.
3. Perangkat menarik delta secara berpaginasi. Penerapan delta dan
   `applied_deltas` berada dalam transaksi yang sama.
4. Relay menghapus amplop yang sudah diakui semua perangkat aktif.
5. Ringkasan harian dibandingkan antarperangkat; selisih membuat permintaan
   rekonsiliasi dan konflik yang dapat ditinjau pemilik.
6. Relay mengunci `(owner_id, store_id)` saat menerima amplop tunggal/batch,
   sehingga urutan `relay_seq` sama dengan urutan commit dan tidak ada amplop
   terlewat.
7. Konflik izin/harga dicatat final (`rejected`) dan tidak diputar ulang;
   kursor tetap maju dan hanya delta yang belum diterapkan yang menahan
   snapshot/backup.
8. Relay menolak body di atas 16 MB (snapshot: batas penyimpanan + 8 MB) dan
   menolak unggahan yang membuat toko melewati `RELAY_STORAGE_LIMIT_BYTES`
   dengan `413 storage_full` setelah amplop yang sudah diakui dipangkas.
9. Karyawan hanya boleh mengirim `stock`/`stock_movement` bila akun punya
   `ubah_stok`; `harga_jasa` tetap hanya dari pemilik.

#### 7.5 Backup multi-toko

```text
createBackup
  → daftar toko dari registry
  → ekspor setiap database menjadi plaintext sementara
  → SHA-256 + enkripsi AES-256-GCM per toko
  → ZIP: manifest.json + stores/<n>.db.enc

restoreBackup
  → baca manifest, validasi semua checksum dan header SQLite
  → siapkan salinan aman .bak
  → tulis berkas tujuan (plain atau SQLCipher) secara atomik
  → ganti registry, aktifkan toko dari manifest
  → reset seq/kode perangkat dan wajibkan bootstrap sync
```

Passphrase backup otomatis disimpan di SecureStore dan dapat dilihat/disalin
dari Pengaturan, sehingga arsip yang diunggah ke Telegram tetap dapat dipulihkan
di perangkat lain.

Format 1 (database tunggal) dan format 2 (single-store dengan manifest) tetap
memiliki jalur restore.

#### 7.6 Peran dan pairing

- Peran dasar `KASIR`, `MEKANIK`, `KEDUANYA` ditambah `extra_permissions`.
- Relay memverifikasi `hints_signature` dan menolak entity di luar izin.
- Kode pairing karyawan sekali pakai; kode owner berlaku 5–20 menit.
- Perangkat karyawan yang dicabut tidak dapat mengirim amplop lagi.

---

### 8. Fitur Struk yang Sudah Dibangun

| Fitur | Keadaan |
|---|---|
| Template tersimpan | `app_settings['receipt.template.v2']`, JSON tervalidasi |
| Blok | header, meta, items, totals, payment, warranty, bank, footer |
| Urutan & visibilitas | Blok dapat digeser dan disembunyikan |
| Label | Semua label dapat diedit; label kosong ditolak |
| Placeholder | `{{nama_toko}}`, `{{tagline}}`, `{{alamat}}`, `{{kontak}}`, dan lainnya |
| Pelanggan/unit/mekanik | Blok meta dengan label yang dapat diubah |
| Riwayat pembayaran | Tampil bila lebih dari satu pembayaran atau DP |
| Sisa / DP / jatuh tempo | Tampil untuk nota yang belum lunas |
| Banner pelunasan | `STRUK PELUNASAN` untuk nota lunas hasil pelunasan/multi-pembayaran |
| Banner VOID | Tampil beserta alasan pembatalan |
| Garansi | Status, tanggal, dan catatan garansi |
| Rekening | Nama bank, nomor, atas nama, catatan |
| Footer | Beberapa baris + alignment + tebal |
| Tanda tangan | Baris tanda tangan dan garis |
| Logo | Raster ESC/POS, lebar mm, preview |
| Diskon per baris | Harga terdaftar × jumlah, lalu baris diskon |
| 58/80 mm | Pratinjau dan cetak sesuai lebar printer |
| Codepage | CP437/CP850/CP1252 + transliterasi karakter Indonesia |
| Salinan | 1–3 rangkap |
| WhatsApp | Kirim teks struk ke nomor pelanggan |
| Ekspor/impor | JSON template untuk backup antarperangkat |
| Pratinjau langsung | Debounce 300 ms + validasi inline |

---

### 9. Keputusan Desain

- **Batas modal dipisahkan dari persetujuan.** Persetujuan tidak boleh menjadi
  jalan pintas untuk menjual di bawah modal.
- **Harga disalin ke baris transaksi.** Perubahan harga master tidak mengubah
  nota lama.
- **Koreksi dan retur append-only.** Nota final tidak berubah sehingga
  sinkronisasi tidak menghasilkan konflik tulis dan audit tetap utuh.
- **Revisi estimasi membuat baris baru.** Riwayat penawaran tetap terlihat.
- **Nomor dokumen per perangkat.** Dua perangkat offline tidak menghasilkan
  nomor yang sama.
- **Rekonsiliasi dihitung lokal.** Relay tidak perlu mengetahui tanggal
  transaksi.
- **Backup multi-toko memakai satu arsip.** Pemilik dapat memindahkan seluruh
  usaha dalam satu berkas; setiap toko tetap memiliki kunci payload sendiri.
- **Retur disinkronkan sebagai bagian nota.** Retur selalu merujuk nota asli dan
  tidak menciptakan dokumen penjualan baru.
- **Struk terstruktur, bukan template bebas.** Pengguna mengedit blok dan label
  agar perataan tidak rusak.
- **SQLCipher hanya di platform yang didukung paket.** Memaksa enkripsi di
  Windows/Linux/web akan menggagalkan pembukaan database; keterbatasan
  ditampilkan di Pengaturan → Keamanan.

---

### 10. Verifikasi

#### 10.1 Hasil sesi lanjutan (5 November 2026)

Mesin sesi ini tidak memiliki SDK Flutter/Dart dan pemilik melarang pemasangan
dependency, sehingga `dart format` dan `flutter analyze` tidak dijalankan.
Verifikasi yang dilakukan bersifat statis:

- Keseimbangan delimiter seluruh `lib/**/*.dart` (143 berkas).
- Penelusuran simbol baru antar-lapis: template struk → service → builder →
  printer → UI; retur → laporan → payload sync → snapshot; backup → registry →
  database.
- Pemeriksaan bahwa format backup 1/2/3 tetap memiliki jalur restore.
- Pemeriksaan bahwa tidak ada dependency baru pada `pubspec.yaml`.

Untuk kelompok B-01–B-10, verifikasi statis tambahan yang dilakukan:

- Pembacaan ulang seluruh berkas yang berubah: relay (`server.dart`,
  `auth_rules.dart`), sinkronisasi (`sync_service.dart`,
  `sync_conflict_rules.dart`, `note_sync.dart`), domain (`app_database.dart`,
  `nota_adjustment_service.dart`, `sale_return_service.dart`,
  `backup_service.dart`, `quantity.dart`), dan UI (`history_screen.dart`,
  `settings_screen.dart`).
- Penelusuran pemanggil: `enqueuePayment` terhubung dari riwayat ke
  `enqueueNotePayment`; `autoPassphrase` dipakai layar Pengaturan dan
  `saveSettings`; `_lockStore` dipanggil pada jalur submit tunggal dan batch.
- Pemeriksaan konsistensi semantik total koreksi di lima jalur (layar koreksi,
  `recalculateRecordTotals`, laporan, refund retur, penerimaan remote).
- Tidak ada test yang dibuat atau dijalankan.

Untuk kelompok C-01–C-06, verifikasi statis tambahan:

- Refund retur diuji dengan tabel kasus manual: nota lunas, DP sebagian, koreksi
  ke 0 tanpa pembayaran, koreksi ke 0 dengan pembayaran, dan dua retur
  berurutan. Hasilnya refund tidak pernah melebihi kas diterima maupun nilai
  retur.
- Semua pemakaian minimal passphrase diperiksa: `setAutoPassphrase`,
  `createBackup`, `_saveBackup`, dan dialog passphrase memakai angka 8.
- Pencarian ulang seluruh `lib/` memastikan `nilai_baru` terakhir dan rumus
  modal hanya didefinisikan di `app_database.dart`; fallback `_currentTotal`
  dan `actor?.label ?? 'Pemilik'` tidak tersisa.
- Relay: alur `_body` (batas deklarasi + hitung per chunk), pemangkasan sebelum
  transaksi, `_storeBytes` yang dipakai bersama status penyimpanan, dan
  kesesuaian entity `stock_movement` antara `server.dart` dan `auth_rules.dart`.
- `start-relay.ps1` dibaca ulang: tidak ada path pengguna yang tersisa;
  resolusi mengikuti `DART` → `FLUTTER_ROOT` → `PATH`.

Pemeriksaan perilaku tetap dilakukan pemilik melalui APK atau localhost.

#### 10.2 Build yang disarankan setelah SDK tersedia

```bash
cd pusatkupos
flutter pub get
flutter analyze

cd ../relay
dart pub get
dart analyze
```

#### 10.3 Pemeriksaan manual yang disarankan

1. Buat nota, lakukan retur sebagian, cek stok dan omzet neto.
2. Backup dua toko, ubah data, restore, pastikan kedua toko dan toko aktif
   pulih.
3. Ubah template struk, pasang logo, geser 58/80, ekspor JSON, impor lagi,
   lalu kirim ke WhatsApp.
4. Cetak ke printer Bluetooth 58 mm dan 80 mm; cetak ulang nota VOID.
5. Logout karyawan dan cabut perangkat di menu Akses; pastikan sync berhenti.

---

### 11. Kriteria Lulus Audit Perbaikan

| Area | Kriteria |
|---|---|
| Backup | Backup Android dapat direstore di perangkat lain; gagal restore tidak mengosongkan DB |
| Multi-toko | Seluruh toko dan toko aktif pulih dari satu arsip |
| Relay | Viewer tidak bisa enroll owner/menulis akun; entity spoof ditolak |
| Sync | Delta ditolak tidak di-ack; snapshot lama ditolak; seq tidak pernah mundur |
| Urutan relay | Feed `relay_seq > since` tidak melewatkan amplop yang commit belakangan |
| Konflik kursor | Konflik izin/harga berstatus final tidak menghalangi feed, snapshot, atau backup |
| Koreksi nota | Dua koreksi bersamaan tidak terhitung ganda; total sama di layar, laporan, dan refund |
| Passphrase backup | Pemilik dapat melihat passphrase arsip otomatis dan memulihkannya di perangkat lain |
| Retur | Sisa jumlah benar, stok kembali, laporan neto, retur diterima perangkat lain |
| Logout | Token dan kunci perangkat terhapus; sync berhenti |
| Laporan | Laba = total - modal part - modal jasa - komisi - gaji - retur |
| Estimasi | Total konversi = total estimasi, atau konfirmasi eksplisit |
| Struk | Template dapat diedit, dipratinjau, disimpan, dicetak 58/80, dan tahan karakter Indonesia |
| Printer | Lebar dokumen sama dengan lebar printer; status cetak jujur |

---

### 12. Lampiran

#### 12.1 File yang diaudit

**Flutter inti**
`lib/main.dart`, `lib/app.dart`, `lib/state/app_state.dart`, `lib/auth/*`,
`lib/core/*`, `lib/data/app_database.dart`, `schema.dart`, `models.dart`,
`order_service.dart`, `price_rules.dart`, `approval_service.dart`,
`nota_adjustment_service.dart`, `sale_return_service.dart`, `receipt_service.dart`,
`receipt_template.dart`, `receipt_settings.dart`, `backup_service.dart`,
`backup_scheduler.dart`, `store_registry.dart`, `account_service.dart`,
`employee_service.dart`, `employee_auth_service.dart`, `session_service.dart`,
`pin_service.dart`, `login_guard.dart`, `device_service.dart`,
`pairing_service.dart`, `license_service.dart`, `license_verifier.dart`,
`google_auth_service.dart`, `owner_access_api.dart`, `store_service.dart`,
`store_settings.dart`, `supplier_service.dart`, `followup_service.dart`,
`reconciliation_service.dart`, `note_sync.dart`, `secure_store.dart`.

**Sinkronisasi**
`lib/sync/sync_service.dart`, `protocol.dart`, `crypto.dart`, `relay_client.dart`,
`snapshot_sync.dart`, `snapshot_platform_io.dart`, `sync_conflict_rules.dart`,
`sync_scheduler.dart`, `sync_secrets.dart`.

**UI**
`lib/ui/*.dart`, `lib/ui/screens/*.dart`, `lib/ui/widgets/*.dart`.

**Printer**
`lib/printer/*.dart`,
`android/app/src/main/kotlin/com/pusatkupos/pusatkupos/printer/*.kt`.

**Relay**
`relay/lib/server.dart`, `auth_rules.dart`, `canonical.dart`, `config.dart`,
`db.dart`, `google.dart`, `license.dart`, `sync_round.dart`, `bin/relay.dart`.

#### 12.2 Referensi Python

- `services/receipt_service.py` — penyusun struk, 25 field, pembayaran, VOID,
  garansi, label, teks WA, payload 58/80.
- `services/escpos_service.py` — `ReceiptBuilder`, alignment, bold, double,
  `to_escpos`, feed+cut.
- `services/settings_service.py` — `RECEIPT_FIELDS`, `bengkel.*`, `ops.*`.
- `services/printer_settings_service.py` — validasi printer, 58/80, mode,
  encoding, satu primary, penulisan atomik.
- `api/printer_routes.py` — endpoint baca/tulis konfigurasi printer.

#### 12.3 Catatan status

- Dokumen ini menggabungkan laporan perbaikan sinkronisasi dan audit kode;
  isinya mencerminkan kode setelah perbaikan, bukan rencana.
- Rencana dan butir yang sudah selesai dihapus dari dokumen.
- Sesi terakhir hanya melakukan verifikasi statis karena SDK tidak tersedia dan
  dependency tidak boleh dipasang.
- Kelompok audit lanjutan B-01–B-10 (Bagian 4.5) sudah diterapkan pada kode dan
  tercatat juga di `DOKUMENTASI_LENGKAP_PUSATKUPOS.md` (Bagian II, Kelompok 6).
- Penyempurnaan C-01–C-06 (Bagian 4.6) sudah diterapkan dan tercatat di
  `DOKUMENTASI_LENGKAP_PUSATKUPOS.md` (Bagian II, Kelompok 7). Tidak ada fitur
  baru pada kelompok ini.

---

# Bagian IV — Laporan Test End-to-End PusatkuPOS + Relay

Tanggal eksekusi: 6 November 2026
Lingkup: aplikasi Flutter (mode offline/localhost dan online ke relay lokal), relay Dart + PostgreSQL, serta jalur unggah ulang backup/snapshot.

---

### 1. Ringkasan

| Area | Hasil | Catatan |
|---|---|---|
| Relay E2E otomatis | **74 / 77 lulus** | 3 gagal: 1 bug koneksi 413, 2 akibat bug endpoint admin |
| Aplikasi offline (Flutter web) | Lulus untuk alur utama | Onboarding, PIN, transaksi, nota, supplier, follow up, karyawan |
| Aplikasi online (relay lokal) | Sebagian lulus | Aktivasi lisensi, pendaftaran perangkat, sinkronisasi berhasil; unggah snapshot dari UI web tidak bisa |
| Unggah ulang backup/snapshot | **Lulus di sisi relay** | Snapshot terbaru menimpa snapshot lama (`ON CONFLICT ... DO UPDATE`) |
| Bug/logic defect ditemukan | **1 defect logika berat, 3 bug, 1 gap produk, 2 keterbatasan platform** | Rincian di bagian 7–9 |

Kesimpulan singkat: relay berfungsi dan sebagian besar kontrak API terpenuhi. Namun ada **satu cacat logika penting** pada penomoran `relay_seq` yang membuat sinkronisasi pertama pemilik baru gagal pada relay yang sudah berisi data pemilik lain. Unggah ulang snapshot di relay sudah benar memperbarui data, tetapi belum dapat diuji dari UI karena Flutter web tidak mendukung pembuatan payload snapshot.

---

### 2. Lingkungan pengujian

| Komponen | Nilai |
|---|---|
| OS | Windows 10.0.26200 (x64) |
| Flutter | 3.47.9 stable |
| Dart | 3.13.7 |
| Aplikasi | `pusatkupos` (Flutter web build) |
| Web server aplikasi | `http://127.0.0.1:8091` (Python `http.server`) |
| Relay | `http://127.0.0.1:8787` (Dart shelf + shelf_router) |
| Database relay | PostgreSQL 17.11 |
| Seed data | `PUSATKU_DUMMY_SEED=true` |
| Konfigurasi layanan | `PUSATKU_SERVICE_URL=http://127.0.0.1:8787` |
| Lisensi | Ditandatangani relay, public key cocok dengan `.env` aplikasi |
| Database aplikasi | SQLite WASM di IndexedDB (`sqflite_databases`) |
| PIN owner saat uji | `123456` (dibuat ulang saat onboarding) |

Catatan: pengujian web memakai satu origin (`127.0.0.1:8091`). Port lain akan menjadi origin/IndexedDB terpisah, jadi tidak bisa dipakai sebagai “dua perangkat” yang berbagi data lokal.

---

### 3. Hasil relay E2E

Harness: `relay/tool/e2e_test.dart`
Artefak hasil: `relay/relay_e2e_result.json`
Run: `mw4z5iau`, owner uji `e2e_owner_mw4z5iau`, selesai `2026-11-06T12:52:37Z`.

Cakupan yang lulus (74 check):

- Health, public key lisensi, status Google login nonaktif.
- Autentikasi admin (401 tanpa token, 200 dengan Bearer).
- Pembuatan owner, enroll token sekali pakai, penolakan token salah, penegakan `store_limit`.
- Enroll perangkat owner, pengembalian token + license token.
- Pairing perangkat kedua, kode sekali pakai.
- Key-wrap bertanda tangan owner: diterima; tanda tangan salah ditolak.
- Amplop: tanda tangan wajib, idempotensi kirim ulang, penolakan tanda tangan salah, penolakan device lain, penolakan `seq 0`, isolasi toko.
- Feed: perangkat lain melihat amplop, toko tidak terdaftar ditolak, ack cursor.
- Sync round: dibuat, dua perangkat ack, status menjadi `complete`.
- Snapshot: wajib putaran lengkap, tanda tangan diverifikasi, unggah ulang berhasil.
- Manajemen akun karyawan bertanda tangan owner, penolakan signer bukan owner.
- Undangan karyawan, klaim sekali pakai, login karyawan, `permissions/me`.
- Otorisasi karyawan: boleh buat nota, tidak boleh ubah harga jasa, boleh pindah stok.
- Cabut perangkat dan penolakan token yang dicabut.
- Kuota follow-up berhenti tepat di 20.
- CORS preflight, 404 rute tidak dikenal, 400 JSON rusak.

#### 3.1 Tiga check yang gagal

1. **Body terlalu besar tidak sampai ke client sebagai 413**
   - Nama check: `body terlalu besar 413 terkirim ke client`
   - Detail: `relay mencatat 413 tetapi koneksi ditutup saat unggah: Write failed`
   - Dampak: server menolak dengan benar, tetapi client melihat koneksi terputus, bukan respons 413 yang bisa dibaca.

2. **`GET /relay/admin/identities` tanpa `owner_id` mengembalikan 500**
   - Detail: `Contains superfluous variables: owner: _Map len:1`
   - Penyebab: query tanpa placeholder tetap dikirimi parameter `@owner` (`relay/lib/server.dart:2477-2482`).

3. **Daftar identitas tidak berisi email baru**
   - Kegagalan lanjutan dari nomor 2; endpoint tidak pernah mengembalikan daftar.

---

### 4. Hasil aplikasi mode offline (localhost)

| Alur | Hasil | Bukti/catatan |
|---|---|---|
| Onboarding lokal + pembuatan owner | Lulus | Owner lokal `OWNERDUMMY`, data dummy tampil |
| PIN owner & auto-lock 5 menit | Lulus | Setelah idle, aplikasi terkunci; PIN `123456` membuka kembali |
| Transaksi POS | Lulus | Nota tersimpan, stok dan laporan mengikuti |
| Pembayaran lebih dari total | Lulus sesuai desain | `dibayar` dibatasi sebesar total, `kembalian` disimpan terpisah dan tampil di struk |
| Dialog “Nota tersimpan” | Lulus dengan catatan | Menampilkan Total, Dibayar, Sisa, Status, Garansi; **tidak** menampilkan Kembalian (struk menampilkan) |
| Supplier | Lulus | “Supplier Uji E2E” (081234567890, Jl. Uji No. 1, Bandung) tersimpan dan muncul di daftar |
| Follow up Reseller | Lulus | Tab terbuka; stok menipis menampilkan empty state yang benar |
| Karyawan | Lulus | Tab Karyawan, Komisi & Gaji, Hutang terbuka; 4 karyawan; siklus 01–30 Nov 2026 semua Rp 0; hutang Rp 0 |
| Logout lalu onboarding ulang | Lulus | Data transaksi tetap ada setelah keluar dan masuk lagi |
| Pengaturan backup (web) | Sesuai batasan platform | Backup file/otomatis/Telegram mengembalikan pesan “tersedia di Android/desktop” |

Catatan: login karyawan di build web lokal sempat gagal 401 karena `serviceConfigured=true` tetapi relay tidak memiliki akun `OWNERDUMMY`. Ini artefak konfigurasi uji (akun lokal vs akun relay), bukan kegagalan transaksi offline.

---

### 5. Hasil aplikasi mode online (relay lokal)

Langkah yang dijalankan:

1. Relay dinyalakan dan `/relay/health` merespons 200 dengan public key lisensi.
2. Owner relay dibuat dengan public key perangkat aplikasi, lalu license token ditandatangani relay.
3. Lisensi dipasang dari layar Premium → “Aktifkan” → token lisensi.
4. Tombol sinkronisasi menjadi aktif (sebelumnya nonaktif karena aplikasi berstatus gratis/lokal).
5. Enroll token relay dimasukkan ke SecureStore perangkat, lalu “Sambungkan perangkat ini” dijalankan.
6. “Sinkron sekarang” dijalankan.

Hasil:

- Pendaftaran perangkat owner berhasil; perangkat tersimpan di relay.
- Sinkronisasi berhasil setelah masalah `relay_seq` diatasi (lihat bagian 7): pesan akhir **“Sinkron: 0 terkirim, 0 diterapkan.”**, 0 pending, dan 6 amplop diterima dari feed (tidak ada yang perlu diterapkan ulang).
- “Unggah snapshot” dari UI web **tidak dapat dijalankan**: dialog berhenti dengan `Unsupported operation: Snapshot hanya tersedia di aplikasi native.`
- “Ambil snapshot” juga termasuk jalur native-only.
- Konflik sinkronisasi: layar dapat dibuka; tidak ada konflik baru pada data uji.

Kesimpulan: jalur online aplikasi terbukti tersambung dan bertukar amplop dengan relay. Pembuatan snapshot dari aplikasi harus diuji pada build Android/desktop.

---

### 6. Unggah ulang backup/snapshot (permintaan terakhir)

#### 6.1 Dari UI aplikasi

Pada Flutter web, dua jalur backup memang dinonaktifkan secara eksplisit:

- Backup file/lokal: `Backup file tersedia di Android/desktop.` (`pusatkupos/lib/data/backup_service.dart:408-411`)
- Backup otomatis: `Backup otomatis tersedia di Android/desktop.` (`backup_service.dart:451-454`)
- Snapshot: `Snapshot hanya tersedia di aplikasi native.` (`pusatkupos/lib/sync/snapshot_platform_stub.dart:10,19`)

Jadi **unggah ulang backup dari UI web tidak mungkin dilakukan**; ini batasan platform yang disengaja, bukan crash.

#### 6.2 Dari sisi relay (diverifikasi)

Harness E2E ditambah skenario 9b: setelah snapshot pertama diunggah, snapshot kedua diunggah pada putaran yang sama dengan `checksum` dan `ciphertext` berbeda.

Hasil:

- `unggah ulang snapshot 200`
- `snapshot diperbarui ke unggahan terbaru`
- `GET /relay/bootstrap` mengembalikan `checksum: sha256-checksum-demo-2` dan `ciphertext: snapshot-cipher-2` (bukan data lama).

Implementasi relay memakai upsert `ON CONFLICT (owner_id, store_id) DO UPDATE` (`relay/lib/server.dart:1535`), sehingga unggahan terbaru menggantikan snapshot lama untuk toko yang sama. Dengan demikian, **jalur “upload lagi agar data diperbarui” sudah benar di server**; yang belum bisa dibuktikan hanyalah pemicunya dari UI web.

---

### 7. Kecacatan logika

#### 7.1 Berat — `relay_seq` global menyebabkan “riwayat dipangkas” palsu

**Gejala saat uji:**

```
Sinkron gagal: Bad State: Riwayat relay sudah dimulai pada urutan 12,
sedangkan perangkat ini baru berada di urutan 0. Minta pemilik mengunggah
snapshot dari perangkat yang datanya lengkap.
```

**Kondisi:** owner baru (OWNERDUMMY) pada relay yang sudah berisi amplop owner lain. Amplop pertama OWNERDUMMY mendapat `relay_seq` 12 karena kolom tersebut memakai sequence global lintas owner.

**Akar masalah:**

- `relay_seq` adalah nomor global, bukan nomor per owner/toko (`relay/lib/server.dart:1008-1025`).
- `_feed` mengirim `log_start_seq = MIN(relay_seq)` untuk owner/toko tersebut. Untuk owner baru, nilai ini bisa 12 meski tidak ada satu pun amplop miliknya yang dipangkas.
- Client menganggap `logStart > pageCursor + 1` sebagai bukti riwayat terpotong (`pusatkupos/lib/sync/sync_service.dart:1883-1889`). Asumsi ini hanya valid bila penomoran dimulai dari 1 dan kontinu per owner/toko.

**Dampak:** pemilik baru tidak bisa menyelesaikan sinkronisasi pertama pada relay multi-owner sampai database dimanipulasi atau snapshot diunggah. Ini juga membuat pesan kesalahan menyesatkan (menyuruh mengunggah snapshot padahal data lengkap).

**Workaround yang dipakai saat uji (hanya untuk pengujian):** `relay_seq` owner lain digeser +1000 dan milik OWNERDUMMY digeser −11 sehingga menjadi 1–6, lalu sequence di-`setval`. Setelah itu sinkronisasi berhasil. **Jangan lakukan ini di produksi.**

**Rekomendasi perbaikan (salah satu):**

1. Beri nomor urut per `(owner_id, store_id)` yang selalu mulai dari 1, sehingga `log_start_seq > cursor + 1` benar-benar menandakan celah; atau
2. Simpan `trimmed_through_seq` per owner/toko dan kirim sebagai field eksplisit; client hanya meminta snapshot bila `cursor < trimmed_through_seq`; atau
3. Kirim flag `history_truncated` yang dihitung server berdasarkan data yang benar-benar dipangkas.

Opsi 1 paling kecil risikonya bagi client karena menjaga semantik urutan yang sudah diasumsikan.

#### 7.2 Ringan — deteksi celah client bergantung pada asumsi urutan global

Bahkan tanpa kasus owner baru, pengecekan di `sync_service.dart:1883-1889` membandingkan cursor dengan `log_start_seq` milik owner, sementara cursor berasal dari `relay_seq` global. Selama penomoran per owner belum diubah, logika ini rawan salah positif/salah negatif. Perbaikan 7.1 sekaligus menutup ini.

#### 7.3 Catatan — pembulatan pembayaran bukan defect

`dibayar = bayarCents.clamp(0, total)` dan `kembalian` disimpan terpisah adalah perilaku yang disengaja dan konsisten dengan struk. Dialog “Nota tersimpan” yang tidak menampilkan Kembalian hanya inkonsistensi tampilan (lihat 9.3).

---

### 8. Bug

| # | Bug | Bukti | Dampak | Rekomendasi |
|---|---|---|---|---|
| 8.1 | `GET /relay/admin/identities` tanpa `owner_id` → 500 | `Contains superfluous variables: owner: _Map len:1` | Admin tidak bisa melihat semua identitas | Kirim `{}` saat `ownerId` kosong (`server.dart:2477-2482`) |
| 8.2 | Body terlalu besar: client melihat koneksi reset, bukan 413 | `Write failed` | Client tidak bisa menampilkan pesan ukuran berlebih dengan rapi | Drain body atau tangani kegagalan tulis di client; pastikan respons 413 terbaca |
| 8.3 | `relay list-owners` gagal `jsonEncode` karena kolom `DateTime` | `Convert to encodable object failed` (dari operasional CLI) | CLI tidak bisa mendaftar owner | Konversi `license_period_end`/timestamp ke ISO string sebelum encode (`relay/bin/relay.dart:69-73`) |

---

### 9. Kendala, gap produk, dan observasi

#### 9.1 Enroll token tidak tersedia untuk alur lokal/on-prem

Hanya login Google yang menulis `owner.enroll_token` (`pusatkupos/lib/ui/onboarding.dart:175-177`). Alur gratis/lokal tidak pernah mengisinya dan tidak ada UI untuk memasukkan token pendaftaran manual. Akibatnya, pada relay lokal, perangkat tidak bisa “Sambungkan perangkat ini” tanpa injeksi token ke SecureStore (yang dilakukan manual saat uji). Untuk deployment on-prem/self-hosted, perlu UI “Token pendaftaran” atau mekanisme pairing yang tidak bergantung pada Google.

#### 9.2 Snapshot dan backup file tidak tersedia di web

`backup_service.dart` dan `snapshot_platform_stub.dart` menonaktifkan backup lokal, backup otomatis, Telegram, dan snapshot di web. Ini konsisten dengan desain, tetapi berarti verifikasi end-to-end fitur backup harus memakai build native. Pesan aplikasi sudah jelas, jadi bukan crash.

#### 9.3 Dialog “Nota tersimpan” tidak menampilkan Kembalian

Struk menampilkan Kembalian; dialog ringkasan tidak. Tidak memengaruhi data, hanya inkonsistensi informasi.

#### 9.4 Login karyawan 401 pada build web lokal

Terjadi karena layanan relay dikonfigurasi tetapi relay tidak memiliki akun `OWNERDUMMY`/kasir lokal. Bukan bug alur offline; perlu dicatat agar penguji tidak mengira data lokal rusak.

#### 9.5 Keterbatasan alat uji

- Interaksi browser untuk Flutter web memerlukan klik-fokus sebelum mengisi field; event wheel sintetis tidak menggulir area Premium, sehingga digunakan `scrollTop` pada node semantics.
- Panggilan tool browser kadang gagal “not found”; diulang melalui pemanggilan MCP.
- Health check yang benar adalah `/relay/health`, bukan `/health`.

---

### 10. Cara reproduksi

#### 10.1 Relay

```bash
cd relay
dart pub get
dart run bin/relay.dart migrate
dart run bin/relay.dart serve
curl http://127.0.0.1:8787/relay/health
```

#### 10.2 E2E relay

```bash
cd relay
dart run tool/e2e_test.dart
```

Default menuju `http://127.0.0.1:8787` dan memakai admin token default harness. Hasil ditulis ke `relay/relay_e2e_result.json`.

#### 10.3 Aplikasi web

```bash
cd pusatkupos
"C:\Users\sukron\flutter\bin\flutter.bat" build web --dart-define-from-file=.env --dart-define=PUSATKU_DUMMY_SEED=true
# Sajikan build/web pada http://127.0.0.1:8091
```

(Gunakan path absolut `C:\Users\sukron\flutter\bin\flutter.bat` di lingkungan ini.)

#### 10.4 Skenario unggah ulang snapshot

Di harness E2E, setelah putaran sinkron `complete`:

1. Unggah snapshot A (checksum A, ciphertext A) → 200.
2. Unggah snapshot B pada `round_id` dan `store_seq` yang sama dengan checksum/ciphertext berbeda → 200.
3. `GET /relay/bootstrap?store_id=utama` → snapshot B.

Snapshot hanya diterima bila: perangkat berjenis owner, putaran lengkap dan tidak stale, `store_seq` sama dengan `latest_seq` putaran, serta tanda tangan valid.

---

### 11. Artefak

| Artefak | Lokasi |
|---|---|
| Hasil E2E relay (JSON) | `relay/relay_e2e_result.json` |
| Harness E2E (termasuk skenario 9b unggah ulang) | `relay/tool/e2e_test.dart` |
| Laporan ini | `DOKUMENTASI_LENGKAP_PUSATKUPOS.md` |

---

### 12. Prioritas tindak lanjut

1. **Perbaiki penomoran `relay_seq` per owner/toko** atau tambahkan sinyal pemangkasan eksplisit; ini memblokir sinkronisasi pertama pemilik baru.
2. Perbaiki `_adminIdentities` agar tidak mengirim parameter tak terpakai.
3. Perbaiki `list-owners` (serialisasi `DateTime`).
4. Tangani respons 413 agar terbaca client.
5. Tambahkan jalur UI untuk enroll token/pairing pada deployment lokal/on-prem.
6. Uji unggah snapshot dan backup file pada build Android/desktop (tidak bisa di web).
7. Samakan informasi Kembalian antara struk dan dialog nota (opsional).
---

### 13. Uji peran kustom dan pembatasan akses (06 Nov 2026)

#### 13.1 Lingkup

- Owner menambah peran baru di **Pengaturan → Aturan transaksi → Peran dan akses**.
- Peran hanya sebagai label; akses diatur terpisah per peran (menu, tindakan, jenis transaksi).
- UI menyembunyikan menu dan tombol yang tidak diizinkan untuk peran tersebut.
- Data lama dan mode offline tetap berjalan.

#### 13.2 Langkah dan hasil

| Langkah | Hasil |
|---|---|
| Buka Pengaturan → Atur transaksi dan izin → Tambah peran | Lulus; dialog menampilkan nama peran dan "Salin akses dari" |
| Tambah peran "Penanggung Jawab" (salin akses Kasir) | Lulus; kartu "Penanggung Jawab · Peran kustom" muncul |
| Ubah akses Kasir: matikan Ringkasan, Pelanggan, Stok, Order, Laporan, Follow up; matikan tindakan stok dan pelanggan | Lulus; chip berubah dan tersimpan ("Aturan transaksi disimpan.") |
| Login karyawan `kasir` (PIN 111111) | Lulus; aplikasi hanya menampilkan tab Kasir, Riwayat, Menu |
| Buka drawer Menu | Lulus; hanya Kasir dan Riwayat; Ringkasan/Pelanggan/Stok/Order/Jasa/Laporan/Supplier/Follow up/Karyawan/Pengaturan/Premium tidak tampil |
| Layar Kasir | Lulus; jenis transaksi mengikuti saklar toko; notifikasi "Simpan nota" tetap aktif |
| Buka Riwayat | Lulus; daftar nota tampil, aksi void/retur/koreksi mengikuti izin peran |
| Data lama | Lulus; nota, pelanggan, dan pengaturan lama tetap ada |
| `dart analyze lib` | 17 info/warning lama, tanpa error |
| `flutter test` | 6/6 lulus (peran bawaan, alias, peran kustom, override, izin tambahan, jenis transaksi) |

#### 13.3 Temuan dan perbaikan

1. **Celah gating (diperbaiki):** tombol "+" pelanggan dan "+" unit di layar Kasir tetap tampil walau peran tidak punya `ubah_pelanggan`. Perbaikan: tombol disembunyikan dan fungsi `_addCustomer`/`_addUnit` dijaga `_canEditCustomers` di `pusatkupos/lib/ui/screens/pos_screen.dart`.
2. **Izin tambahan menimpa pembatasan peran (sesuai desain, perlu dipahami owner):** akun `kasir` memiliki izin tambahan `lihat_laporan` sehingga menu Laporan tetap terbuka walau peran Kasir tidak diberi akses. Label dialog "Izin tambahan (di atas akses peran)" sudah menjelaskan hal ini; saat pengujian, izin tambahan dikosongkan agar pembatasan peran murni terlihat.
3. **Login karyawan online tidak bisa diuji pada owner lokal `OWNERDUMMY`:** relay tidak memiliki akun tersebut (temuan lama pada laporan ini). Pengujian UI dilakukan pada build lokal (tanpa URL relay) dengan akun lokal, sehingga gating tetap terverifikasi.

#### 13.4 Catatan teknis

- Definisi peran disimpan pada `store_settings.role_permissions_json` sehingga ikut tersinkron dan tidak menambah entitas baru.
- Peran kustom dimulai tanpa akses sampai owner mengaturnya; peran bawaan memakai peta default dengan fallback.
- Peran yang masih dipakai akun (aktif maupun nonaktif) tidak bisa dihapus.
