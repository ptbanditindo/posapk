# PETA KODE, DEPENDENSI, DAN LOGIKA BISNIS — PUSATKUPOS

Dibuat: 5 November 2026
Repo: `D:\Downloads\posapk-main\posapk-main`
Cakupan: 185 file teks — 132 file Dart (`pusatkupos/lib`, `relay/lib|bin|tool`), Kotlin/Gradle/manifest Android, Windows C++/CMake, web, pubspec, env, README, dan dokumen audit. Dua belas aset biner (10 PNG, 1 ICO, 1 WASM) dan satu service worker hasil build (`web/sqflite_sw.js`) tidak dipetakan isinya.
Catatan: seluruh folder `test/` sudah dihapus; dokumen ini tidak memuat test.

---

## 0. Cara membaca dokumen ini

- Path selalu relatif terhadap root repo.
- Arah panah `A → B` berarti **A memakai/memanggil B**.
- "Dipakai oleh" adalah kebalikan dari import/call dan sudah diverifikasi lewat pencarian impor.
- Bagian 3 memetakan tiap file; bagian 4 merangkum graf; bagian 5 menelusuri alur data ujung-ke-ujung; bagian 6 menjelaskan aturan bisnis; bagian 7 memuat rumus/invarian; bagian 8 memuat catatan teknis; bagian 9 membuktikan cakupan file.

---

## 1. Arsitektur dalam satu gambar

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

## 2. Titik masuk dan siklus hidup aplikasi

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

## 3. Peta file per lapisan

### 3.1 `pusatkupos/lib/core` — primitif lintas lapisan (11 file)

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

### 3.2 `auth`, `state`, `dev`, dan akar `lib` (6 file)

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `lib/main.dart` | 20 | Bootstrap DB, seed, state, scheduler, `runApp` | `app`, `app_database`, `backup_scheduler`, `dummy_seed`, `app_state`, `sync_scheduler` | titik masuk (`flutter run`) |
| `lib/app.dart` | 26 | `MaterialApp`, tema, `EntryGate` | `app_state`, `entry_gate`, `theme` | `main.dart` |
| `auth/operator.dart` | 52 | Operator owner/karyawan: peran, izin, `isOwner`, `canWriteMoney`, `can()` | — | `permissions`, `app_state`, `session_service`, service data, UI |
| `auth/permissions.dart` | 30 | Konstanta izin (`void`, `diskon`, `ubah_stok`, …) + `can/require` | `operator.dart` | `app_database`, `sale_return_service`, layar riwayat/stok/POS |
| `state/app_state.dart` | 95 | `ChangeNotifier` global: identitas toko, operator, tema, auto-lock, `revision`/`storeRevision` | `operator`, `app_database`, `pin_service` | `main`, `entry_gate`, `home_shell`, `onboarding`, `pin_gate`, hampir semua layar |
| `dev/dummy_seed.dart` | 448 | Seed owner `OWNERDUMMY`, 4 akun demo, pelanggan/unit/stok/jasa/nota demo | `dates`, `ids`, `app_database`, `secure_store`, `sync/crypto` | `main.dart` (hanya build dev) |

### 3.3 `pusatkupos/lib/data` — domain & persistensi (39 file)

#### 3.3.1 Inti database, skema, dan model

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/app_database.dart` | 3055 | Gateway tunggal SQLite: lifecycle/enkripsi, setting, master data, stok, transaksi, pembayaran, void, retur/koreksi (hitung ulang), laporan, nomor dokumen, HLC | `operator`, `permissions`, `dates`, `ids`, `money`, `phone`, `sync/crypto`, `approval_service`, `models`, `price_rules`, `schema`, `secure_store`, `store_settings`, `store_registry` | 25+ service data, `main`, `sync/*`, `app_state`, `printer_config`, `dummy_seed`, hampir semua layar |
| `data/schema.dart` | 1017 | DDL skema bersih, tabel retur, migrasi aditif v2/v3 | `sqflite` | `app_database` |
| `data/models.dart` | 644 | DTO baris SQL: `Customer`, `VehicleUnit`, `StockItem`, `ServiceCatalog`, `ServiceRecordSummary`, `JobDraft`, `PartDraft`, `SaleReturn*`, `CommissionRow`, `RecordDetail`, `ReportSummary`, `EstimateAgingRow`, `DashboardData` | `dates`, `quantity` | `app_database`, `note_sync`, `order_service`, `receipt_service`, `sale_return_service`, `sync_service`, UI |
| `data/price_rules.dart` | 253 | Satu sumber matematika harga: `PriceLine`, alokasi diskon proporsional, batas modal, validasi koreksi | `core/money.dart` | `app_database`, `nota_adjustment_service`, `order_service`, layar riwayat |

#### 3.3.2 Siklus nota, retur, koreksi, dan sinkronisasi nota

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/sale_return_service.dart` | 373 | Retur per baris: validasi sisa qty, refund proporsional, restock, refund kas, hitung ulang total/komisi, audit | `operator`, `permissions`, `dates`, `ids`, `quantity`, `app_database`, `models`, `store_settings` | layar riwayat |
| `data/nota_adjustment_service.dart` | 303 | Koreksi nilai append-only; `selisih = nilaiBaru - total saat ini`; validasi modal; approval; `applyRemote` idempoten | `operator`, `dates`, `ids`, `app_database`, `approval_service`, `price_rules`, `store_settings` | `sync_service`, layar riwayat |
| `data/note_sync.dart` | 1022 | Payload nota lengkap (pelanggan, unit, jasa, part, bayar, retur, snapshot stok) + penerapan remote idempoten | `app_database`, `models`, `dates`, `ids`, `sync/sync_conflict_rules` | `sync_service` |

#### 3.3.3 Estimasi dan work order

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/order_service.dart` | 1027 | Estimasi berversi (revisi append-only), konversi ke nota, work order + nomor antrian + log status + varians | `operator`, `dates`, `ids`, `money`, `app_database`, `approval_service`, `models`, `price_rules`, `store_settings` | layar estimasi, order, POS |

#### 3.3.4 Akun, PIN, persetujuan, sesi

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/account_service.dart` | 608 | Peran KASIR/MEKANIK/KEDUANYA, matriks izin, PBKDF2 600k, login hub/lokal/perangkat, audit izin | `operator`, `dates`, `ids`, `app_database`, `license_service`, `login_guard` | `employee_auth_service`, `pairing_service`, `sync_service`, onboarding, viewer, POS, premium, store settings |
| `data/approval_service.dart` | 143 | Persetujuan harga/diskon di bawah batas: PIN owner atau karyawan penanggung jawab | `app_database`, `login_guard`, `pin_service`, `store_settings` | `app_database`, `nota_adjustment_service`, `order_service` |
| `data/login_guard.dart` | 71 | Lockout login per scope: 5 gagal, backoff eksponensial 30–3600 detik | `app_database` | `account_service`, `approval_service`, `pin_service` |
| `data/pin_service.dart` | 175 | PIN owner PBKDF2 600k, migrasi PIN lama SHA-256, lockout | `app_database`, `login_guard`, `session_service` | `approval_service`, `app_state`, `entry_gate`, onboarding, `pin_gate`, settings |
| `data/session_service.dart` | 213 | Profil sesi (free/premium/employee/viewer), pemetaan ke `Operator`, token perangkat | `operator`, `sync_secrets`, `app_database`, `secure_store` | `employee_auth`, `pin_service`, `entry_gate`, `home_shell`, onboarding, viewer, `pin_gate` |
| `data/secure_store.dart` | 50 | Bungkus `flutter_secure_storage`; rahasia tidak pernah ke `app_settings` | `flutter_secure_storage` | `app_database`, `session_service`, `pin_service`, perangkat, lisensi, backup, pairing |

#### 3.3.5 Perangkat, lisensi, pairing, dan login

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

#### 3.3.6 Multi-toko, backup, dan pengaturan toko

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

#### 3.3.7 Karyawan, follow-up, supplier, struk, rekonsiliasi

| File | LOC | Tanggung jawab | Bergantung pada | Dipakai oleh |
|---|---:|---|---|---|
| `data/employee_service.dart` | 524 | Kompensasi (KOMISI/GAJI, persen/nominal), siklus payroll, hutang, bayar gaji, override komisi | `app_database`, `operator`, `dates`, `ids`, `sync/crypto`, `sync_service` | layar karyawan, riwayat, order, POS |
| `data/followup_service.dart` | 1661 | Bangun dan jalankan follow-up WhatsApp: prospek, servis berkala, garansi, piutang, unit selesai; kuota gratis 20 | `app_database`, `license_service`, `app_config`, `dates`, `ids`, `money`, `phone`, `wa_link`, `relay_client` | layar follow-up, pengaturan follow-up, riwayat, POS |
| `data/supplier_service.dart` | 321 | CRUD supplier, relasi item-supplier, daftar stok minim, status follow-up pembelian | `app_database`, `dates`, `ids`, `phone` | layar stok, supplier |
| `data/receipt_service.dart` | 529 | Render `ReceiptDocument` dari nota memakai template v2 | `app_database`, `models`, `receipt_settings`, `receipt_template`, `store_settings`, `dates`, `money`, `printer/receipt_builder` | `printer_service`, dialog struk, pengaturan struk |
| `data/receipt_settings.dart` | 87 | Simpan/muat template JSON v2 + migrasi toggle lama | `app_database`, `receipt_template` | `receipt_service`, pengaturan struk |
| `data/receipt_template.dart` | 512 | Model template v2: label, visibilitas, lebar 58/80, validasi & sanitasi JSON | `printer/receipt_builder` | `receipt_service`, `receipt_settings`, pengaturan struk |
| `data/reconciliation_service.dart` | 175 | Digest harian nota (count + sha256 sync_id) untuk rekonsiliasi relay | `app_database`, `dates`, `ids` | `sync_scheduler`, premium |

### 3.4 `pusatkupos/lib/sync` — mesin sinkronisasi (10 file)

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

### 3.5 `pusatkupos/lib/printer` — cetak struk (26 file)

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

### 3.6 `pusatkupos/lib/ui` — layar dan komponen (30 file)

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

### 3.7 `relay/` — server sinkronisasi & lisensi (10 file Dart + config)

| File | LOC | Tanggung jawab | Bergantung pada |
|---|---:|---|---|
| `relay/lib/server.dart` | 2453 | HTTP Shelf: enroll/pairing, envelope log, feed/ack, bootstrap, sync round, snapshot, akun/undangan, login Google/karyawan, admin | `auth_rules`, `canonical`, `config`, `db`, `google`, `license`, `sync_round`, shelf |
| `relay/lib/db.dart` | 347 | Lapisan PostgreSQL + migrasi idempoten + decoder JSONB | `postgres`, `config` |
| `relay/lib/license.dart` | 97 | Kunci Ed25519 server, terbitkan token lisensi, verifikasi payload/tanda tangan | `canonical`, `db`, `cryptography` |
| `relay/lib/google.dart` | 360 | Verifikasi ID token Google (JWKS/RS256) + rate limiter | `dart:io`, `crypto` |
| `relay/lib/auth_rules.dart` | 78 | Aturan entity/aksi per peran + field hints amplop | — |
| `relay/lib/canonical.dart` | 13 | JSON kanonik (urut kunci rekursif) untuk semua tanda tangan | `dart:convert` |
| `relay/lib/config.dart` | 109 | Baca env/.env, parse URL PostgreSQL | `dart:io` |
| `relay/lib/sync_round.dart` | 57 | Evaluasi kelengkapan sync round (ack semua perangkat, tidak stale) | — |
| `relay/bin/relay.dart` | 377 | CLI: `serve`, `migrate`, `key`, `owner`, `token`, `identity`, `license`, `seed-demo` | paket relay, `args`, `shelf_io` |
| `relay/tool/gen_demo_summary.dart` | 48 | Tool pembuat ringkasan owner demo | paket relay |
| `relay/pubspec.yaml` | 18 | Manifest paket relay | pub.dev |
| `relay/.env.example` | 9 | Template `RELAY_HOST/PORT/DATABASE_URL/ADMIN_TOKEN/GOOGLE_CLIENT_ID` | — |
| `relay/start-relay.ps1` | 14 | Launcher Windows: cek `.env`, `dart pub get`, `serve` | — |
| `relay/README.md` | 247 | Dokumentasi setup, endpoint, model auth, batas relay | — |

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

### 3.8 Platform, web, dan konfigurasi

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
| `AUDIT_LOGIKA_BISNIS_DAN_ALUR_OPERASIONAL.md`, `LAPORAN_PERBAIKAN_DAN_AUDIT.md`, `LICENSE` | — | Riwayat audit, laporan perbaikan, lisensi repo | dokumentasi |

---

## 4. Graf ketergantungan (siapa memakai siapa)

### 4.1 Arah lapisan

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

### 4.2 Ketergantungan silang yang perlu diwaspadai

| Relasi | Penjelasan |
|---|---|
| `app_database` ⇄ `approval_service` | `app_database` memanggil approval; approval membaca `app_settings`/akun lewat `app_database`. Tidak ada import melingkar karena approval memakai singleton saat runtime. |
| `sync_service` → `note_sync` → `sync_conflict_rules` | Penerapan nota memakai tipe `RetryableSyncException` dan aturan konflik. |
| `printer_service` → `receipt_service` → `app_database` | Cetak selalu merender ulang dari data nota, bukan dari draft UI. |
| `backup_service` → `store_registry` | Restore multi-toko menulis ulang registry, lalu `AppDatabase` wajib bootstrap ulang. |
| `license_service` ⇄ `store_service` | Store service membaca claims lisensi; lisensi menyimpan owner/token. Cache lisensi dibersihkan saat ganti toko. |

### 4.3 Conditional import per platform

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

## 5. Alur data ujung-ke-ujung

### 5.1 Buka aplikasi dan buka kunci

1. `main` → `AppDatabase.init`.
2. `EntryGate` membaca sesi (`SessionService.load`).
3. Tanpa sesi → `OnboardingFlow`; ada sesi → `PinGate`.
4. `PinService.verifyDetailed` memeriksa lockout, PIN PBKDF2, dan PIN lama.
5. `SessionProfile.toOperator()` → `AppState.setOperator`.
6. `HomeShell` atau `OwnerViewerShell` dirender; menu difilter `operator.permissions`.

### 5.2 Membuat nota (POS)

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

### 5.3 Pembayaran piutang

1. `HistoryScreen` → `AppDatabase.settleReceivable`.
2. Tolak nota VOID; nominal ≤ `sisa_bayar`.
3. `request_id` mencegah pembayaran ganda.
4. Insert baris `service_payments` (`PELUNASAN`), hitung ulang total, ubah status ke `LUNAS` bila sisa 0.
5. Enqueue `note_payment` ke outbox.

### 5.4 Retur penjualan

1. `HistoryScreen` → `SaleReturnService.createReturn`.
2. Wajib alasan, minimal satu baris, izin `void`, peran `void`; nota VOID ditolak.
3. Hitung sisa per baris: `original - sudah diretur`; qty retur tidak boleh melebihi.
4. Refund proporsional dari neto baris (`subtotal - diskon_alokasi`).
5. Simpan `sale_returns` + `sale_return_items` (termasuk `modal_satuan`).
6. Kembalikan stok part + catat `stock_movements` masuk.
7. Bila refund melebihi sisa bayar, tulis pembayaran `REFUND` negatif (idempoten).
8. `recalculateRecordTotals` + `recalculateRecordCommissions`, audit, enqueue.

### 5.5 Void nota

1. `HistoryScreen` → `AppDatabase.voidRecord`.
2. Ditolak bila masih ada retur aktif.
3. Stok part dikembalikan sebesar qty nota dikurangi qty yang sudah diretur; `stock_movements` masuk dicatat dengan kunci `void-<part_sync_id>`.
4. Pembayaran dikembalikan sebagai baris `REFUND` negatif (idempoten per `request_id`).
5. Status nota → `VOID`, `voided_at`, `sisa_bayar = 0`, audit, enqueue `note_void` dan amplop `note_payment` agar REFUND ikut ke perangkat lain.
6. Perangkat penerima void hanya menyamakan status + stok (tidak membuat refund ganda); `sisa_bayar` juga dinolkan.

### 5.6 Koreksi nilai nota

1. `HistoryScreen` → `NotaAdjustmentService.create`.
2. Wajib aktor + alasan; non-owner butuh peran `koreksi`.
3. Total saat ini = `nilai_baru` koreksi terakhir menurut `(sync_hlc_wall, sync_hlc_counter, id)`, atau `total_servis` bila belum ada koreksi.
4. `nilaiBaru` boleh dikirim langsung atau lewat `selisih`; target dihitung ulang di dalam transaksi, baris baru ditambahkan, nota asli tidak diubah.
5. Koreksi di bawah modal divalidasi `PriceRules.validateCorrection`; PIN/approval diverifikasi **di luar** transaksi agar hitungan gagal terkunci tetap tersimpan.
6. Modal part dihitung dari `COALESCE(jumlah_milli, jumlah * 1000)`; modal jasa tetap `jumlah` bulat.
7. `recalculateRecordTotals`, audit, enqueue `nota_adjustment`.

### 5.7 Estimasi → nota → work order

1. `OrderService.createEstimate`: jenis transaksi aktif, peran boleh, diskon lewat `PriceRules`, nomor estimasi, masa berlaku.
2. Revisi membuat baris baru `versi + 1` dengan `revisi_dari_sync_id`; estimasi lama ditandai `direvisi`.
3. `convertEstimateToNote`: cek status/kedaluwarsa, susun draft dari harga estimasi, `diskon = (jasa + part) - total estimasi`, panggil `createTransaction` dengan `estimate_sync_id`.
4. Estimasi menjadi `dikonversi`.
5. `createWorkOrder`: nomor order + nomor antrian harian per perangkat, status awal sesuai tahap yang aktif.
6. `changeStatus`: transisi divalidasi `allowedWorkOrderTransitions`; override owner dicatat sebagai konflik; setiap perubahan masuk `work_order_status_log`.
7. Semua langkah enqueue ke outbox (`estimate`, `work_order`, `work_order_status`).

### 5.8 Stok dan opname

1. `StockScreen` → `AppDatabase.saveStockItem` / `stockIn` / `stockOut` / `opname`.
2. Kuantitas selalu milli; kolom lama `jumlah` diisi `wholeQuantity(milli)` yang membulatkan ke bawah untuk nilai negatif (bukan ke arah nol).
3. Setiap perubahan menulis `stock_movements` (`MASUK`/`KELUAR`/`OPNAME`) dan menstempel HLC.
4. Izin berbeda: `ubah_stok`, `stok_masuk`, `stok_keluar`, `opname`.
5. Enqueue `stock`/`stock_movement` agar perangkat lain menerima saldo yang sama.

### 5.9 Payroll dan komisi

1. `EmployeesScreen` → `EmployeeService.updateCompensation`.
2. Siklus: mingguan mengikuti `payroll_hari`, bulanan mengikuti `payroll_tanggal` (diklem 1–31).
3. `payrollSummary` menjumlahkan komisi nota non-VOID; gaji mingguan diprorata `gaji * hari / 30`.
4. Potongan = `min(totalHutang, bruto)`; hutang dibayar FIFO.
5. `paySalary` menolak siklus yang sudah dibayar, menulis `salary_payments`, dan mengenqueue `salary`.
6. Override komisi hanya owner; nota VOID tidak bisa diubah.

### 5.10 Laporan

1. `ReportsScreen` memilih preset: hari ini, 7 hari, bulan ini, semua (`DateTime(2000)..sekarang`).
2. `AppDatabase.reportSummary` menjumlahkan omzet neto (setelah diskon), modal part/jasa, komisi, gaji, retur, koreksi, kas per metode.
3. Owner melihat tambahan: penjualan di bawah harga, koreksi, umur estimasi.
4. `DashboardData` meringkas hari ini untuk layar dashboard.

### 5.11 Backup dan restore

1. `SettingsScreen`/`BackupScheduler` → `BackupService.createBackup`.
2. Arsip ZIP format 3: `manifest.json` + `stores/<n>.db.enc`.
3. Tiap DB diekspor konsisten, dienkripsi AES-256-GCM (PBKDF2 210k), checksum SHA-256.
4. Mode portable memakai passphrase pengguna; mode otomatis memakai passphrase acak di SecureStore (hanya perangkat yang sama).
5. Retensi 30 file; opsi kirim Telegram ≤50 MB.
6. Restore: validasi manifest/checksum/header SQLite → decrypt → tulis DB sementara → ganti atomik dengan `.bak` → registry `replaceAll` → kode perangkat baru + `seq_floor` → `sync.restore_requires_bootstrap=1`.

### 5.12 Login, lisensi, dan pairing

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

### 5.13 Sinkronisasi

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

### 5.14 Cetak struk

1. `ReceiptService.build` membaca nota + template + pengaturan toko.
2. `ReceiptBuilder` menyusun baris lebar 32 (58 mm) atau 48 (80 mm).
3. `PrinterService` memilih mode: `ESCPOS`, `TEXT`, atau `SYSTEM`.
4. Untuk ESC/POS: `EscPosBuilder` menambahkan init, codepage, alignment, bold, double size, raster logo, feed, cut.
5. Transport: BLE (MTU 247, chunk), SPP (128 byte), USB (8 KiB), TCP 9100, atau dialog sistem/browser.
6. Jika lebar dokumen tidak cocok dengan printer, struk dirender ulang dari `recordId`; jika tidak ada `recordId`, cetak gagal.

---

## 6. Logika bisnis per domain

### 6.1 Uang dan kuantitas

- **Uang selalu integer sen.** Tipe/kolom memakai akhiran `Cents` (`harga`, `subtotal`, `diskon`, `total`, `sisa_bayar`). Input pengguna diubah lewat `parseRupiahToCents` (format `1.500,50`), output lewat `formatRupiah`.
- **Kuantitas selalu milli (1/1000).** `jumlah` (bulat) dipertahankan untuk kompatibilitas; `jumlah_milli` adalah nilai otoritatif. Rumus nominal baris: `harga * qtyMilli ~/ 1000` (dengan pembulatan pada perhitungan tertentu).
- `formatQuantity(milli, desimal, satuan)` menampilkan 0–3 desimal dan memangkas nol; `parseQuantityToMilli` menerima koma desimal dan titik ribuan.
- Nilai negatif ditolak pada input uang; koreksi/retur memakai jalur khusus (bukan input negatif biasa).

### 6.2 Peran dan izin

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

### 6.3 Harga, diskon, dan batas modal

- `PriceLine` menghitung `subtotal`, `batasTotal` (modal), dan `hargaFinal` per baris.
- **Batas bawah = modal tersimpan** (`harga_modal`/`harga_batas_saat_transaksi`). Tidak ada kolom batas terpisah; menurunkan batas berarti menurunkan modal.
- Non-owner:
  - tidak boleh menjual di bawah modal;
  - total diskon tidak boleh melebihi total margin (`bruto - modal`);
  - alokasi diskon proporsional per baris; sisa pembulatan digeser ke baris berikutnya; bila kapasitas habis → transaksi ditolak.
- Owner boleh menjual di bawah modal; baris tersebut diberi `disetujui_oleh` dan ditandai `belowMinimum` untuk laporan.
- Harga dibekukan saat transaksi: `harga_jual_terdaftar`, `harga_batas_saat_transaksi`, `harga_final`, `diskon_alokasi`.

### 6.4 Transaksi dan status

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

### 6.5 Pembayaran dan piutang

- `CASH`: `dibayar = bayar.clamp(0, total)`, `kembalian = bayar - total`.
- `TRANSFER`: tidak boleh melebihi total (tidak ada kembalian).
- `sisa = total - dibayar`; sisa > 0 → status kredit dan opsi `jatuh_tempo`.
- Setiap pembayaran menulis baris ledger `service_payments` (`DP`, `PELUNASAN`, `REFUND`).
- `settleReceivable`: tolak VOID, nominal ≤ sisa, idempoten, status → `LUNAS` saat sisa 0.

### 6.6 Retur, void, dan koreksi (append-only)

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

### 6.7 Estimasi dan work order

- Estimasi bukan dokumen finansial; hanya disimpan bila `simpan_estimasi_lepas` aktif, selain itu hanya dicetak.
- Revisi append-only: `versi + 1`, `revisi_dari_sync_id`, estimasi lama `direvisi`.
- Masa berlaku `masa_berlaku_hari` (minimal 1); kedaluwarsa tidak bisa dikonversi.
- Konversi: harga diambil dari estimasi, `diskon = (jasa + part) - total_estimasi`; diskon negatif ditolak; nota ditautkan `estimate_sync_id`; estimasi → `dikonversi`.
- Work order: nomor + antrian hanya dialokasikan bila tahapnya aktif; tanpa tahap pengerjaan status awal `dibuka`.
- Transisi status mengikuti `allowedWorkOrderTransitions`; transisi di luar peta hanya owner dan dicatat `sync_conflicts`; setiap transisi masuk `work_order_status_log`.

### 6.8 Stok

- Tiga jalur: `stockIn`, `stockOut`, `opname`, semuanya menulis `stock_movements`.
- Stok minimum default 3 (bila `stok_minimum` kosong) dipakai untuk daftar stok minim.
- Stok negatif dapat terjadi dari penerapan delta dan dicatat sebagai konflik `stok_negatif` (non-blocking).
- Penambahan barang/katalog dan perubahan harga dibatasi owner; transaksi stok mengikuti izin masing-masing.

### 6.9 Komisi, gaji, dan hutang

- Jenis imbalan: `KOMISI` atau `GAJI`; mode komisi `PERSEN` atau `NOMINAL`.
- Komisi dihitung dari jasa dan margin part, dibagi rata antar mekanik dengan sisa pembagian yang deterministik.
- Periode payroll: `MINGGUAN` (mengikuti `payroll_hari` 1–7) atau `BULANAN` (mengikuti `payroll_tanggal` 1–31, diklem ke akhir bulan).
- Gaji mingguan diprorata `gaji_bulanan * hari / 30`.
- Potongan hutang = `min(totalHutang, bruto)`; hutang dibayar FIFO (yang paling lama dulu).
- Satu siklus hanya boleh dibayar sekali; pembayaran menulis `salary_payments`.
- Override komisi hanya owner dan tidak berlaku untuk nota VOID.

### 6.10 Follow-up dan supplier

- Jenis follow-up: prospek, servis berkala, garansi, piutang, unit selesai.
- Sumber dibangun ulang dari nota non-VOID: garansi H-7/kedaluwarsa, prospek 30/60/90 hari, servis berkala dari interval bulan, piutang setelah tenggang, unit selesai saat unit diambil.
- Pengiriman WA dibatasi jam aktif, cooldown, kuota harian/bulanan, consent/DNC, dan prioritas (piutang > garansi > servis; unit masih dikerjakan memblokir).
- Kuota gratis 20 pesan; premium tanpa batas. Kuota disinkronkan lewat relay.
- Status follow-up punya transisi sah per jenis; piutang lunas menutup follow-up.
- Supplier: nama unik (case-insensitive), telepon dinormalisasi, relasi item-supplier, status follow-up pembelian.

### 6.11 Laporan

- Preset: hari ini, 7 hari, bulan ini, **semua** (`DateTime(2000)`–sekarang).
- Omzet neto = total nota − retur; laba kotor neto = laba kotor − (retur jual − retur modal).
- Komponen: modal part, modal jasa, komisi, gaji, retur, koreksi, kas per metode, jenis transaksi.
- Owner-only: penjualan di bawah harga, daftar koreksi, umur estimasi.
- `belowPriceSales` menelusuri baris dengan `harga_final < harga_batas_saat_transaksi`.
- `estimateAging` mengelompokkan estimasi belum dikonversi menurut umur.

### 6.12 Multi-toko dan backup

- `registry.db` menyimpan daftar toko → file DB dan toko aktif. Web memakai satu toko sintetis.
- Menambah toko: wajib premium, akun Google, nama unik ≥2 karakter, dan tidak melewati `store_limit` lisensi.
- Ganti toko: cek penugasan akun (`allowedStoreIds`) + file ada; `AppDatabase` dibuka ulang; cache lisensi dibersihkan.
- Backup format 3: satu ZIP berisi manifest + satu DB terenkripsi per toko; kunci payload per toko.
- Restore atomik memakai `.bak`, menulis ulang registry, membuat kode perangkat baru, menaikkan `seq_floor`, dan mewajibkan bootstrap sync.
- Backup otomatis: retensi 30 file, jadwal harian, opsi Telegram ≤50 MB.
- Passphrase backup otomatis disimpan di SecureStore, minimal 8 karakter, dan dapat dilihat/disalin dari layar Pengaturan. Caption Telegram menandai arsip terkunci passphrase.

### 6.13 Lisensi, pairing, dan sesi

- Lisensi **hanya** diterbitkan relay dan diverifikasi dengan kunci publik server yang ditanam saat build.
- `premium = plan == "premium" && period_end > sekarang`; lisensi kedaluwarsa tidak mengunci kasir offline, hanya mematikan sync/multi-toko.
- Owner lokal: ID 8 karakter, kunci Ed25519 di SecureStore, kode pemulihan 12 karakter (PBKDF2 600k).
- Pairing memverifikasi `owner_public_key` dan tanda tangan izin; kunci owner dipin (TOFU).
- Login karyawan: password + PIN (PIN didaftarkan saat login pertama), atau kode pairing.
- Sesi disimpan di SecureStore; mode `free`, `premium`, `employee`, `viewer`.
- Lockout: 5 percobaan gagal, backoff eksponensial 30–3600 detik per scope.

### 6.14 Sinkronisasi, HLC, dan konflik

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

### 6.15 Printer dan struk

- Template v2: blok header, meta, item, total, pembayaran, garansi, bank, footer; label dan visibilitas dapat diubah.
- Lebar: 58 mm = 32 kolom; 80 mm = 48 kolom. Lebar dokumen harus sama dengan printer; jika beda, struk dirender ulang dari `recordId`.
- Codepage: CP437, CP850, CP1252; karakter tak didukung ditransliterasi atau menjadi `?`.
- Logo raster 1-bit, lebar 10–40 mm; alignment direset setelah logo.
- Salinan 1–3, baris kosong 0–5, maksimal 5 baris tambahan (≤80 karakter).
- WhatsApp: teks dinormalisasi ke prefix `62`, dipotong 3500 karakter.
- Maksimal 8 printer; konfigurasi disimpan terpisah (`printer_config.json`) dan tidak ikut backup.
- Status `CONNECTED`/`CONNECTING` hanya runtime; status tersimpan diturunkan menjadi `SAVED`.

---

## 7. Rumus dan invarian kunci

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

## 8. Catatan teknis hasil pembacaan kode

1. **Restock void dan validasi stok.** `AppDatabase.voidRecord` mengembalikan stok memakai `jumlah_milli` (fallback `jumlah × 1000`) dikurangi qty yang sudah diretur, dan `createTransaction` memvalidasi total qty per `stock_item_id` sehingga dua baris barang yang sama tidak dapat membuat stok negatif. Void juga membuka kembali estimasi (`status = aktif`, `converted_nota_sync_id = NULL`) dan melepas `work_orders.nota_sync_id` bila nota berasal dari keduanya, lalu meng-enqueue amplop `note_payment` untuk REFUND.
2. **Total koreksi bersifat absolut.** `NotaAdjustmentService._currentTotal`, `AppDatabase.recalculateRecordTotals`, `reportSummary`, dan perhitungan refund retur memakai `nilai_baru` terakhir menurut HLC, bukan `SUM(nilai_selisih)`, agar dua koreksi bersamaan tidak terhitung ganda. Verifikasi approval berjalan di luar transaksi supaya hitungan PIN gagal tidak ikut rollback.
3. **Pembulatan kolom `jumlah` lama.** `wholeQuantity(milli)` membulatkan ke bawah untuk nilai negatif dan dipakai di semua penulisan stok/retur/void, termasuk jalur sinkronisasi.
4. **`sqflite_sw.js` adalah artefak build**, bukan kode aplikasi; isinya minified dan hanya dipakai backend SQLite web.
5. **Folder test sudah dihapus total** (25 file Flutter + 3 relay + 2 skrip uji) beserta hook test di `AppDatabase`, `SecureStore`, dan `SyncService`. `pubspec.lock` masih menyebut paket test sampai `pub get` berikutnya.
6. **`summary_file_stub.dart` diimpor langsung oleh `owner_viewer`** ketika platform tidak mendukung file picker; di web/native implementasi yang dipakai ditentukan conditional import.
7. **`analysis_options.yaml` mengecualikan folder platform** (`android/`, `web/`, `windows/`), sehingga lint Flutter tidak memeriksa kode native.
8. **`start-relay.ps1` memuat path Dart hardcoded** (`C:\Users\sukron\flutter\bin\dart.bat`); di mesin lain perlu disesuaikan.
9. **Mode viewer memakai database terpisah** `viewer_<owner_id>.db`; `openViewerDatabase` tidak menulis ke DB utama.
10. **`app_settings` menyimpan penanda lokal** (mis. `sync.last_*`, `device.*`) yang dikecualikan saat snapshot/impor agar tidak menimpa identitas perangkat tujuan.
11. **Persetujuan diskon diverifikasi sebelum `db.transaction`** di `createTransaction` (sama seperti `createEstimate`), supaya penghitung gagal PIN di `login_guards` tidak ikut ter-rollback saat PIN salah.
12. **Konversi estimasi idempoten.** `convertEstimateToNote` mengirim `requestId = estimasi:<sync_id>` dan `createTransaction` hanya mengubah estimasi dengan syarat `status = 'aktif'`; klik ganda atau konversi ulang ditolak tanpa mengurangi stok dua kali.
13. **Konflik final tidak memblokir.** `SyncConflictRules.isFinal` menandai penolakan izin/harga sebagai `rejected`; `_applyOnce` menganggapnya selesai sehingga kursor maju, sedangkan `blockingConflictCount` mengabaikan `review` dan final sehingga snapshot/backup tetap bisa dibuat.
14. **Kuota follow-up diautentikasi.** `FollowupService` mengirim token perangkat hasil pairing ke `/relay/followup/quota`; tanpa token, kuota hanya dihitung lokal.

---

## 9. Checklist cakupan file

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

`pusatkupos/pubspec.yaml`, `pusatkupos/.env.example`, `pusatkupos/analysis_options.yaml`, `pusatkupos/.metadata`, `pusatkupos/README.md`, `pusatkupos/.gitignore`, `README.md`, `.gitignore`, `relay/pubspec.yaml`, `relay/.env.example`, `relay/start-relay.ps1`, `relay/README.md`, `AUDIT_LOGIKA_BISNIS_DAN_ALUR_OPERASIONAL.md`, `LAPORAN_PERBAIKAN_DAN_AUDIT.md`, `LICENSE`.

**Tidak dipetakan isinya (non-kode):** 12 aset biner — ikon launcher Android ×5, ikon web ×5 (`Icon-192`, `Icon-512`, `Icon-maskable-192`, `Icon-maskable-512`, `favicon.png`), `app_icon.ico`, `sqlite3.wasm` — dan `web/sqflite_sw.js` (hasil kompilasi). Tidak ada file teks/kode yang terlewat.

