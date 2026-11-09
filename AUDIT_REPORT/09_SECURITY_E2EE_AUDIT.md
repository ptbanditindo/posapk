# 09 — SECURITY & E2EE AUDIT

Ruang lingkup: login, sesi, token, refresh, peran, izin, identitas perangkat, registrasi, otorisasi API, akses DB, enkripsi, manajemen kunci/secret, secure storage, paparan lokal, log, backup, jaringan, replay, duplikasi, dan akses tidak sah.

Klasifikasi yang dipakai: **plaintext leakage**, **crypto weakness**, **authentication**, **authorization**, **metadata leakage**, **misconfiguration**, **implementation error**.

---

## 1. Model E2EE yang Ditemukan

| Elemen | Implementasi | Penilaian |
|---|---|---|
| Tanda tangan perangkat | Ed25519 per perangkat | Baik |
| Pembungkusan store key | X25519 ECDH + HKDF-SHA256 | Baik |
| Enkripsi payload/snapshot | AES-GCM-256 | Baik |
| Key ID | SHA-256 store key, 16 hex | Baik |
| Pinning owner | TOFU | Risiko jika owner key berubah |
| Namespace rahasia | Per toko | Baik |
| Penyimpanan kunci | SecureStore | Platform-dependent |
| Rotasi kunci | Tidak ada | **SEC-12** |
| Escrow/recovery | Tidak ada | **SEC-13** |

**Yang dilihat server:** ciphertext payload, store id, device id, seq, HLC, entity, action, entity sync id, key id, ukuran, waktu. Server **tidak** memiliki jalur membaca nama pelanggan, telepon, item, harga, nominal, atau catatan.

**Kesimpulan kriptografis:** primitif dan alur enkripsi benar; masalah utama adalah **manajemen siklus hidup kunci**, bukan algoritma.

---

## 2. Registry Temuan

### SEC-01 — Restore backup tanpa autentikasi owner dari layar pra-login
- **Severity:** **CRITICAL**
- **Kategori:** SECURITY WEAKNESS / AUTHORIZATION
- **Status:** Terkonfirmasi
- **Lokasi:** [startup_recovery.dart:82](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/startup_recovery.dart#L82), [backup_service.dart:808](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L808)
- **Fungsi/Kelas:** `_restoreBackup`; `BackupService.restoreBackup`
- **Implementasi:** Layar recovery startup dapat memilih arsip, memasukkan passphrase, lalu mengganti database. Tidak ada sesi, PIN, atau verifikasi identitas. Restore juga memicu `StartupService.boot(quarantine: true)`.
- **Penyebab:** Restore ditempatkan sebagai alat pemulihan darurat tanpa gerbang otorisasi.
- **Dampak:** Penimpaan data/pemasangan data palsu oleh pemegang perangkat; potensi membaca arsip toko lain bila passphrase bocor; kehilangan WAL (DB-06).
- **Skenario:** SC-02, SC-03.
- **Rekomendasi:** Wajibkan PIN owner + konfirmasi perangkat; batasi restore pra-login hanya untuk arsip yang ditandatangani owner dan toko yang sama; audit.
- **Dependensi:** FLW-01, SEC-04.

### SEC-02 — Logout owner menghapus database tanpa memeriksa outbox
- **Severity:** **CRITICAL**
- **Kategori:** DATA INTEGRITY RISK / IMPLEMENTATION ERROR
- **Status:** Terkonfirmasi
- **Lokasi:** [entry_gate.dart:97](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/entry_gate.dart#L97), [app_database.dart:214](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L214)
- **Fungsi/Kelas:** `signOutSession`; `deleteLocalDatabases`
- **Implementasi:** Logout owner memanggil `purgeDeviceIdentity` lalu `deleteLocalDatabases`. `deleteLocalDatabases` menghapus DB semua store, sidecar, `.bak`, `.corrupt`, dan viewer DB, lalu membuka DB kosong. Tidak ada pemeriksaan `sync_outbox`, tidak ada flush paksa, tidak ada ringkasan pending.
- **Penyebab:** Logout diperlakukan sebagai reset perangkat.
- **Dampak:** Nota/retur/pembelian/perubahan stok yang belum tersinkron hilang permanen. Backup otomatis mungkin belum berisi data terbaru.
- **Skenario:** SC-02, SC-03.
- **Rekomendasi:** Blokir logout bila outbox pending kecuali pengguna memilih ekspor/hapus dengan konfirmasi berlapis; flush dulu; tampilkan jumlah dokumen.
- **Dependensi:** OFF-01, FLW-05.

### SEC-03 — Safe mode memindahkan DB tetapi menghapus WAL/SHM
- **Severity:** MEDIUM
- **Kategori:** DATA INTEGRITY RISK / IMPLEMENTATION ERROR
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:108](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L108), [backup_platform_io.dart:78](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_platform_io.dart#L78)
- **Implementasi:** File DB dipindahkan ke `.corrupt-*`; `-wal` dan `-shm` dihapus.
- **Dampak:** Transaksi yang sudah commit di WAL hilang dari karantina; recovery dapat menimpa data valid.
- **Rekomendasi:** Pindahkan seluruh set file; coba checkpoint salinan sebelum membuka DB baru.
- **Dependensi:** DB-06, FLW-03.

### SEC-04 — Restore mengganti DB dan membuang outbox yang lebih baru
- **Severity:** HIGH
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [backup_service.dart:1015](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L1015), [backup_service.dart:1069](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L1069)
- **Fungsi/Kelas:** `_restoreBackupNow`
- **Implementasi:** DB aktif ditutup, staging dipromosikan, `restore_requires_bootstrap=1` diset. Tidak ada pemeriksaan/merge outbox DB lama.
- **Dampak:** Dokumen lokal yang lebih baru dari backup hilang; pengguna tidak diperingatkan.
- **Rekomendasi:** Tolak/ekspor outbox pending; tampilkan diff sebelum restore.
- **Dependensi:** SEC-01, OFF-02.

### SEC-05 — `runViewerWrite` membuka kunci read-only viewer
- **Severity:** MEDIUM
- **Kategori:** AUTHORIZATION / IMPLEMENTATION ERROR
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:148](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L148), [app_database.dart:170](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L170)
- **Implementasi:** Koneksi viewer dibuka `query_only=ON`, tetapi `runViewerWrite` mematikan pragma tersebut untuk blok kode.
- **Dampak:** Jaminan read-only bergantung pada disiplin pemanggil; bukan kontrol keamanan.
- **Rekomendasi:** Hapus jalur tulis pada build viewer; gunakan koneksi read-only tanpa API tulis.
- **Dependensi:** FLW-06.

### SEC-06 — `role_base='owner'` pada akun karyawan menghasilkan seluruh izin
- **Severity:** MEDIUM
- **Kategori:** AUTHORIZATION / POTENTIAL DEFECT
- **Status:** Terkonfirmasi dengan mitigasi sebagian
- **Lokasi:** [store_settings.dart:196](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/store_settings.dart#L196), [account_service.dart:80](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/account_service.dart#L80)
- **Implementasi:** `accessFor` mengembalikan semua akses bila `canonicalRole(role) == 'owner'`. `effectivePermissions` memakai `role_base` mentah dari akun + extras. Validasi peran ada di `_requireKnownRole` (roleNames), tetapi payload remote/restore tidak divalidasi ulang.
- **Dampak:** Akun karyawan dengan `role_base` owner (mis. data restore/sync yang dimanipulasi) mendapat akses penuh.
- **Rekomendasi:** Larang `owner` sebagai role_base akun karyawan; gunakan flag owner terpisah; validasi ulang saat apply remote.
- **Dependensi:** SEC-07, SEC-10.

### SEC-07 — Otorisasi `saveCatalog`/`deleteCatalog` tidak konsisten
- **Severity:** MEDIUM
- **Kategori:** AUTHORIZATION
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:1712](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1712), [app_database.dart:1769](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1769)
- **Implementasi:** `saveCatalog` memeriksa permission/owner hanya bila `actor != null`; `deleteCatalog` memeriksa permission tetapi tidak owner-only.
- **Dampak:** Pemanggil internal tanpa aktor dapat menulis; penghapusan katalog mungkin dilakukan peran yang tidak seharusnya.
- **Rekomendasi:** Wajibkan aktor untuk semua mutasi master; pisahkan izin edit vs hapus; audit.
- **Dependensi:** ARC-04.

### SEC-08 — `approvedByOverride` dipercaya tanpa verifikasi
- **Severity:** MEDIUM
- **Kategori:** AUTHORIZATION / POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:1885](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1885), [order_service.dart:774](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/order_service.dart#L774)
- **Implementasi:** String `approvedByOverride` (dari `estimate.disetujuiOleh`) langsung mengaktifkan `allowBelowMinimum` dan menjadi `approver`.
- **Dampak:** Bila estimasi dapat disetujui tanpa PIN yang valid atau data estimasi dimanipulasi, harga bawah minimum lolos tanpa bukti persetujuan.
- **Rekomendasi:** Terbitkan grant persetujuan bertanda tangan; verifikasi sebelum dipakai.
- **Dependensi:** ARC-01, TRX-08.

### SEC-09 — Hash PIN dicerminkan ke `app_meta`; DB desktop plaintext
- **Severity:** LOW
- **Kategori:** PLAINTEXT LEAKAGE / CRYPTO WEAKNESS
- **Status:** Terkonfirmasi
- **Lokasi:** [pin_service.dart:146](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/pin_service.dart#L146), [app_database.dart:407](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L407)
- **Implementasi:** Hash/salt/iterasi PIN disimpan di SecureStore **dan** `app_meta`. Di Windows/Linux DB tidak dienkripsi.
- **Dampak:** Hash PIN (PBKDF2) dapat diambil dari file DB dan diserang offline; tidak ada plaintext PIN.
- **Rekomendasi:** Jangan mencerminkan hash ke DB; atau enkripsi DB desktop; naikkan biaya KDF sesuai perangkat.
- **Dependensi:** DB-03.

### SEC-10 — `isOwner` default true untuk mode tak dikenal; kunci DB dipertahankan setelah logout
- **Severity:** LOW
- **Kategori:** AUTHORIZATION
- **Status:** Terkonfirmasi
- **Lokasi:** [session_service.dart:52](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/session_service.dart#L52), [app_database.dart:407](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L407)
- **Implementasi:** `isOwner => mode != 'employee' && mode != 'viewer'`; mode kosong/tak dikenal dianggap owner. Kunci enkripsi DB tetap tersimpan setelah logout.
- **Dampak:** Fail-open untuk peran; kunci tetap dapat dipakai bila ada akses penyimpanan.
- **Rekomendasi:** Default ke peran paling rendah; hapus kunci saat logout penuh bila kebijakan mengizinkan.
- **Dependensi:** SEC-02.

### SEC-11 — Safe mode dipicu sebelum diagnosis error
- **Severity:** LOW
- **Kategori:** IMPLEMENTATION ERROR
- **Status:** Terkonfirmasi
- **Lokasi:** [startup_recovery.dart:91](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/startup_recovery.dart#L91)
- **Implementasi:** Layar recovery memanggil boot dengan `quarantine: true` sebelum error dianalisis.
- **Dampak:** Karantina tidak perlu dan kehilangan WAL.
- **Rekomendasi:** Lihat FLW-03.
- **Dependensi:** SEC-03.

### SEC-12 — Pencabutan perangkat tidak merotasi store key
- **Severity:** HIGH
- **Kategori:** CRYPTO WEAKNESS / E2EE VIOLATION RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/server.dart:2429](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart#L2429)
- **Fungsi/Kelas:** `_revokeDevice`
- **Implementasi:** Server hanya mengeset `revoked_at` dan menghapus baris `store_keys` milik perangkat. Store key tidak berubah; tidak ada kode rotasi (pencarian `rotate`/`store_key_version` tidak menemukan implementasi).
- **Penyebab:** Kunci dianggap tidak perlu diganti saat perangkat hilang.
- **Dampak:** Perangkat yang dicabut tetapi sudah memiliki store key dapat membuka ciphertext yang dienkripsi dengan kunci sama di masa depan (bila masih menerima feed/envelope), dan seluruh riwayat yang tersimpan dengan kunci itu tetap dapat didekripsi oleh penyerang yang mengekstrak kunci sebelum pencabutan.
- **Skenario:** SC-05.
- **Rekomendasi:** Rotasi store key saat pencabutan/kehilangan; enkripsi ulang snapshot; tandai versi kunci; distribusikan kunci baru ke perangkat sah.
- **Dependensi:** SEC-13, SYN-05.

### SEC-13 — Tidak ada escrow/recovery store key
- **Severity:** HIGH
- **Kategori:** MISSING FEATURE / AVAILABILITY
- **Status:** Terkonfirmasi
- **Lokasi:** [session_recovery.dart:32](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/session_recovery.dart#L32), [backup_service.dart:224](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L224)
- **Fungsi/Kelas:** `SessionRecoveryScreen._recover`; auto passphrase backup
- **Implementasi:** Kode pemulihan hanya memverifikasi lisensi lalu membuat PIN baru. Store key tidak dipulihkan. Backup otomatis memakai passphrase acak di SecureStore yang tidak diekspor ke mana pun.
- **Penyebab:** Tidak ada mekanisme escrow/recovery kunci.
- **Dampak:** Kehilangan perangkat/kerusakan storage = riwayat terenkripsi tidak dapat dibuka; backup otomatis tidak dapat direstore di perangkat lain tanpa passphrase.
- **Keputusan pemilik (9 Nov 2026):** recovery menggunakan **akun Gmail**. Gmail menjadi identitas/faktor pemulihan; wrapped key dapat disimpan di Google Drive app data dan dibuka dengan PIN owner + sesi Google yang sah. Wajib 2FA, audit akses, dan prosedur bila akun Google hilang. Implementasi belum ada.
- **Skenario:** SC-05.
- **Rekomendasi:** Rancang escrow wrapped key berbasis akun Gmail + PIN owner; uji skenario perangkat hilang, akun Google hilang, dan akun Google diambil alih. Jangan menyimpan plaintext store key di Google.
- **Dependensi:** SYN-05, SEC-12.

### SEC-14 — TLS PostgreSQL mati secara default; relay HTTP/CORS permisif
- **Severity:** MEDIUM
- **Kategori:** MISCONFIGURATION
- **Status:** Terkonfirmasi (deployment-dependent)
- **Lokasi:** [relay/lib/config.dart:106](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/config.dart#L106), [relay/lib/db.dart:18](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/db.dart#L18)
- **Implementasi:** `sslMode: uri.queryParameters['sslmode'] ?? 'disable'`. Relay HTTP sendiri tidak menetapkan TLS; CORS `*`.
- **Dampak:** Kredensial DB dan metadata relay dapat terekspos bila tidak di belakang proxy TLS. Payload tetap terenkripsi E2EE, tetapi metadata dan token perangkat berisiko.
- **Rekomendasi:** Default `require`/`verify-full`; dokumentasikan TLS termination; batasi CORS.
- **Dependensi:** SYN-01, SEC-16.

### SEC-15 — Relay menyimpan hash password karyawan dan mengembalikan detail error
- **Severity:** MEDIUM
- **Kategori:** PLAINTEXT LEAKAGE / IMPLEMENTATION ERROR
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/auth_rules.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/auth_rules.dart), [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart)
- **Implementasi:** Hash/salt password karyawan disimpan di server; error dapat memuat detail/stack trace.
- **Dampak:** Kompromi relay/DB memungkinkan serangan offline pada kredensial karyawan; detail error membantu penyerang memetakan sistem.
- **Rekomendasi:** Gunakan KDF kuat + rate limit; jangan kirim detail internal ke klien; audit akses admin.
- **Dependensi:** SEC-14.

### SEC-16 — Metadata plaintext dan tidak ada blind index; pencarian arsip terenkripsi tidak mungkin
- **Severity:** MEDIUM
- **Kategori:** METADATA LEAKAGE / MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart), [sync_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart)
- **Implementasi:** Envelope membawa store/device/seq/HLC/entity/action/entity id/key id dalam plaintext. Tidak ada indeks pencarian terenkripsi (blind index/token) dan tidak ada API pencarian.
- **Dampak:** Server dapat memetakan pola transaksi (waktu, volume, jenis) meski tidak membaca isi; SC-04 tidak dapat dipenuhi tanpa indeks khusus atau dekripsi lokal bertahap.
- **Rekomendasi:** Minimalkan metadata; bangun indeks pencarian dengan HMAC/token (mis. HMAC(no_nota), prefix nama) dan API arsip; atau sepakati batas bahwa pencarian hanya lokal.
- **Dependensi:** SYN-02, SYN-07, SC-04.

---

## 3. Analisis Skenario SC-05

| Pertanyaan | Jawaban dari kode |
|---|---|
| Server dapat membaca nama pelanggan? | Tidak — ada di ciphertext |
| Nomor telepon? | Tidak |
| Item/harga jual? | Tidak |
| Nominal pembayaran? | Tidak |
| Catatan? | Tidak |
| Enkripsi sebelum dikirim? | Ya — payload dienkripsi lalu ditandatangani |
| Integritas/replay? | Ya — AES-GCM + signature + id/seq |
| Metadata bocor? | Ya — store/device/seq/HLC/entity/action/id/key id |
| Rotasi kunci? | Tidak ada |
| Recovery kunci? | Tidak ada |
| Device enrollment? | Ada, tetapi berbagi kunci manual |
| Server menjadi kalkulator transaksi? | Tidak ditemukan jalur plaintext/kalkulasi bisnis di relay |
| Backup terenkripsi? | Ya — AES-256-GCM + PBKDF2 |
| Pencarian arsip di server? | Tidak dapat dilakukan tanpa blind index |

**Status SC-05: PARTIAL + NEEDS CLARIFICATION.**

Kriptografi memenuhi kerahasiaan isi terhadap server. Namun E2EE belum lengkap secara operasional: kehilangan kunci = kehilangan riwayat, pencabutan perangkat tidak mencabut akses kriptografis, dan metadata tetap terbuka. Keputusan recovery kunci wajib diambil sebelum produksi.

---

## 4. Klasifikasi Kelemahan

| Klasifikasi | Temuan |
|---|---|
| Plaintext leakage | SEC-09 (hash PIN di DB), SEC-15 (detail error), SEC-16 (metadata) |
| Crypto weakness | SEC-12 (tanpa rotasi), SEC-13 (tanpa recovery) |
| Authentication | FLW-01/SEC-01 (restore pra-login), SEC-15 |
| Authorization | SEC-05, SEC-06, SEC-07, SEC-08, SEC-10 |
| Metadata leakage | SEC-16, SEC-14 |
| Misconfiguration | SEC-14 |
| Implementation error | SEC-02, SEC-03, SEC-04, SEC-11 |
