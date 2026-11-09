# 08 — APPLICATION FLOW AUDIT

Ruang lingkup: entry point, routing, onboarding, login, pemilihan toko, startup recovery, lifecycle aplikasi, navigasi fitur, dan alur yang berdampak pada integritas data.

---

## 1. Entry Point dan Startup

1. [main.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/main.dart) menjalankan `runZonedGuarded`; error tak tertangkap mengarah ke `StartupRecoveryApp`.
2. [app.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/app.dart) membangun `MaterialApp` dengan `home: EntryGate` dan overlay sibuk saat restore/switch store.
3. [startup.dart:21](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/core/startup.dart#L21) `StartupService.boot`:
   - set locale;
   - `init()` DB atau `openSafeMode()` bila gagal;
   - seed dummy bila flag aktif;
   - `AppState.load`;
   - start `BackupScheduler` dan `SyncScheduler`;
   - error ditangkap dan dicatat.

**Catatan:** scheduler dimulai bahkan bila DB dibuka dalam safe mode (DB kosong). Sync/backup kemudian berjalan di atas DB baru; lihat SEC-11.

---

## 2. Jalur Masuk

| Jalur | Kondisi | Konsekuensi data |
|---|---|---|
| Tanpa akun (free cashier) | Mode lokal | DB lokal, tanpa sync premium |
| Google premium | Lisensi premium | Sync + backup |
| Login karyawan | Akun karyawan pada toko | Peran/permission dari akun |
| Viewer | Perangkat pendamping | `openViewerDatabase` + `PRAGMA query_only=ON` |

`signOutSession` ([entry_gate.dart:97](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/entry_gate.dart#L97)):
- `allowOwnerRebind`, stop SyncScheduler, `useMainDatabase`;
- `purgeDeviceIdentity` (catch-all);
- tunggu backup idle;
- hapus sesi/PIN/enroll token;
- bila owner: hapus DB lokal, kunci signing, recovery code, cache lisensi.

**Defect:** tidak ada pemeriksaan outbox sebelum hapus (SEC-02).

---

## 3. Navigasi Fitur

`HomeShell` menampilkan modul berdasarkan feature flag dan permission:
- POS, Riwayat, Stok, Pelanggan, Work Order, Laporan, Pajak, Penggajian, Pengaturan.
- `AppState.can(key)` dipakai untuk menyembunyikan aksi (mis. backup, retur).

**Catatan:** penyembunyian UI bukan otorisasi. Service tetap harus memeriksa aktor; sebagian service sudah melakukannya (lihat SEC-07 untuk celah).

---

## 4. Lifecycle

- `SyncScheduler` tick pada resume, pause, dan detached (`force: true`), selain timer 10–20 menit.
- `BackupScheduler` timer 1 menit, jadwal harian, retry Telegram 10 menit.
- Restore dan switch store memakai `RestoreLock` + overlay; restore menunggu scheduler idle.
- Force close saat transaksi: SQLite rollback/commit atomik (PASS).
- Force close saat sync: cursor/ack hanya maju setelah apply; envelope diulang (PASS).

---

## 5. Registry Temuan Alur

### FLW-01 — Restore dapat dilakukan sebelum login tanpa autentikasi owner
- **Severity:** **CRITICAL** (kanonik: SEC-01)
- **Kategori:** SECURITY WEAKNESS / DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [startup_recovery.dart:82](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/startup_recovery.dart#L82), [backup_service.dart:808](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L808)
- **Fungsi/Kelas:** `_restoreBackup`; `BackupService.restoreBackup`
- **Implementasi:** Layar recovery startup menyediakan tombol restore, meminta file + passphrase, lalu memanggil restore. Tidak ada PIN owner, tidak ada verifikasi identitas, tidak ada sesi.
- **Dampak:** Siapa pun memegang perangkat dapat menimpa database dengan arsip lain (termasuk arsip toko lain bila passphrase diketahui), atau menanam data palsu. Bila arsip tidak terenkripsi/berhasil didekripsi, integritas toko hilang.
- **Skenario:** SC-02, SC-03.
- **Rekomendasi:** Wajibkan autentikasi owner (PIN + faktor perangkat) sebelum restore; batasi restore dari dalam sesi owner; audit setiap restore.
- **Dependensi:** SEC-04, SEC-11.

### FLW-02 — Riwayat dibatasi 200 baris tanpa paginasi/filter tanggal
- **Severity:** HIGH
- **Kategori:** MISSING FEATURE / PERFORMANCE ISSUE
- **Status:** Terkonfirmasi
- **Lokasi:** [history_screen.dart:53](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart#L53), [app_database.dart:3397](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3397)
- **Fungsi/Kelas:** `_load`; `listRecords`
- **Implementasi:** UI memanggil `listRecords(query: ..., limit: 200)` tanpa offset, tanpa rentang tanggal. Pencarian hanya `no_nota`/nama pelanggan.
- **Dampak:** Nota lama tidak dapat ditemukan meskipun masih ada di DB; bertentangan dengan kebutuhan riwayat 1 tahun dan pencarian 2 tahun (SC-03/SC-04).
- **Rekomendasi:** Paginasi/scroll infinite, filter tanggal, pencarian telepon/plat/nominal, indeks yang sesuai.
- **Dependensi:** SC-03, SC-04.

### FLW-03 — Startup recovery membuka safe mode sebelum mengetahui penyebab error
- **Severity:** MEDIUM (kanonik: SEC-11)
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [startup_recovery.dart:91](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/startup_recovery.dart#L91), [startup.dart:21](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/core/startup.dart#L21)
- **Implementasi:** `StartupService.boot(quarantine: true)` dipanggil dari layar restore sebelum error dianalisis; safe mode memindahkan DB dan menghapus WAL/SHM.
- **Dampak:** Error non-DB (mis. lisensi, locale) dapat memicu karantina yang tidak perlu dan kehilangan transaksi WAL.
- **Rekomendasi:** Diagnosis error dulu; hanya karantina bila error benar-benar `DatabaseException` korupsi; pertahankan WAL.
- **Dependensi:** DB-06.

### FLW-04 — Cakupan piutang/kas berbeda antar layar
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:4009](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4009), layar laporan/riwayat
- **Fungsi/Kelas:** `reportSummary`; `listRecords(onlyReceivable)`
- **Implementasi:** Sebagian laporan memasukkan piutang awal/opening dan kas dari `cash_ledger`; daftar piutang memakai `sisa_bayar` nota. Definisi tidak identik.
- **Dampak:** Total piutang/kas di dua layar berbeda; pemilik tidak tahu angka mana yang benar.
- **Rekomendasi:** Tetapkan satu definisi dan satu query bersama.
- **Dependensi:** REP-06.

### FLW-05 — Logout tanpa konfirmasi di HomeShell
- **Severity:** MEDIUM
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [home_shell.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/home_shell.dart) (aksi "Keluar")
- **Implementasi:** Aksi keluar memanggil `signOutSession` tanpa dialog konfirmasi khusus; dialog PIN/logout hanya memberi peringatan generik.
- **Dampak:** Salah tap dapat menghapus DB lokal (SEC-02).
- **Rekomendasi:** Konfirmasi eksplisit + ringkasan data pending.
- **Dependensi:** SEC-02.

### FLW-06 — Viewer read-only dapat dimatikan oleh pemanggil publik
- **Severity:** MEDIUM (kanonik: SEC-05)
- **Kategori:** SECURITY WEAKNESS
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:148](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L148), [app_database.dart:170](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L170)
- **Implementasi:** `runViewerWrite` membuka `PRAGMA query_only=OFF` pada koneksi viewer. Siapa pun yang memanggil fungsi ini dapat menulis.
- **Dampak:** Jaminan "viewer hanya baca" bersifat konvensi, bukan penegakan.
- **Rekomendasi:** Hapus API tulis dari build viewer; gunakan koneksi read-only terpisah tanpa jalur tulis.
- **Dependensi:** —

---

## 6. Uji Alur

| Uji | Hasil |
|---|---|
| Start dengan DB normal | PASS |
| Start dengan DB korup | PARTIAL (safe mode, WAL hilang) |
| Buka tanpa akun | PASS |
| Login karyawan | PASS (dengan catatan role, SEC-06) |
| Logout owner tanpa kehilangan pending | **FAIL** |
| Restore sebelum login | **FAIL** |
| Riwayat 1 tahun | **FAIL** (limit 200) |
| Force close saat simpan | PASS |
| Force close saat sync | PASS |
| Switch store gagal | PASS (rollback ke store sebelumnya) |
