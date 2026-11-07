# 09 — Audit Keamanan (Fokus Dampak Logika Bisnis)

**Metode:** analisis kode statis dan inspeksi source code. **Tidak ada scanner keamanan yang dijalankan** (CodeQL tidak mendukung Dart; Semgrep/alat lain tidak dieksekusi karena larangan audit). Tidak ada aplikasi, server, test, atau serangan yang dijalankan. Laporan ini tidak mengklaim hasil scanner atau pengujian penetrasi.

**Berkas utama:** `pusatkupos/lib/data/pin_service.dart`, `login_guard.dart`, `session_service.dart`, `secure_store.dart`, `license_service.dart`, `license_verifier.dart`, `app_database.dart`; `pusatkupos/lib/sync/crypto.dart`, `sync_service.dart`, `sync_conflict_rules.dart`, `snapshot_sync.dart`, `relay_client.dart`; `relay/lib/server.dart`, `auth_rules.dart`; `pusatkupos/lib/ui/pin_gate.dart`.

---

## 1. Model keamanan yang terdeteksi

| Lapisan | Mekanisme | Penilaian |
|---|---|---|
| Database lokal | SQLCipher di Android/iOS/macOS; kunci acak 256-bit di SecureStore | Baik untuk platform seluler; Windows/Linux/web memakai SQLite polos dan aplikasi memberi peringatan |
| PIN pemilik/karyawan | PBKDF2-HMAC-SHA256 600.000 iterasi; hash SHA-256 lama dimigrasikan saat verifikasi | Baik, dengan catatan hash juga disalin ke `app_settings` |
| Lockout | `LoginGuard` per scope, 5 kegagalan, backoff 30 detik–1 jam | Baik |
| Sesi | Profil di SecureStore; PIN dan hash sesi terpisah | Baik, tetapi profil tidak divalidasi ulang ke akun |
| Sinkronisasi | Amplop AES-GCM dengan kunci toko; tanda tangan Ed25519 perangkat; X25519 untuk membungkus kunci toko; HKDF | Baik |
| Relay | Token perangkat di-hash; token enrollment sekali pakai; signature envelope dan hint diverifikasi; advisory lock per toko | Baik |
| Lisensi | Token Ed25519 yang ditandatangani relay | Baik secara kriptografi; kelemahan pada acuan waktu |
| Backup | AES-256-GCM + PBKDF2 210.000; checksum; snapshot bertanda tangan | Baik |
| Transport | URL relay wajib HTTPS; HTTP hanya untuk loopback | Baik |

---

## 2. Autentikasi dan sesi

### 2.1 PIN

- `PinService.verifyDetailed` memeriksa `LoginGuard`, lalu membandingkan hash PBKDF2 dengan salt 16 byte. PIN lama (SHA-256) dimigrasikan otomatis setelah berhasil (`pin_service.dart:38-89`).
- PIN baru minimal 6 digit dan hanya angka (`103-113`).
- PIN disimpan di dua tempat: SecureStore (`session.*`) dan `app_settings` (`auth.pin_hash`, `auth.pin_salt`, `auth.pin_iterations`). Salinan database menyertakan `auth.%` sebagai pengaturan lokal, tetapi snapshot bisnis mengecualikannya.
- `LoginGuard` menyimpan kegagalan di database; lockout bertingkat.

**Kekuatan:** biaya brute force PBKDF2 600.000 cukup tinggi; lockout membatasi percobaan interaktif.

**Kelemahan:** `auth.pin_hash` ada di database. Siapa pun yang memperoleh salinan database (mis. perangkat non-SQLCipher atau backup yang didekripsi) dapat melakukan brute force offline tanpa lockout. Ini risiko yang melekat pada penyimpanan hash PIN di database; tidak dicatat sebagai temuan terpisah karena PBKDF2 dan batas PIN 6 digit masih memberi perlindungan, tetapi perlu dipertimbangkan bila PIN dipakai untuk otorisasi keuangan.

### 2.2 Sesi dan status akun (BL-06)

- `SessionProfile` disimpan di SecureStore dan dimuat sebagai `_cached`.
- `PinGate` memverifikasi PIN lalu membangun operator dari profil; untuk karyawan, izin peran dihitung ulang dari `StoreSettings`, tetapi **status `aktif` akun tidak dibaca** (`pin_gate.dart:55-125`).
- Relay memeriksa `aktif` saat login/pairing (`server.dart:1654`, `1858`, `1990`), tetapi `_deviceAuth` hanya memeriksa `token_hash` dan `revoked_at` (`server.dart:208-226`), dan `_employeeCanSend` tidak memeriksa `aktif` (`303-327`).

**Dampak:** karyawan yang dinonaktifkan tetap dapat membuka aplikasi dengan PIN lama dan mengirim amplop dengan token yang masih valid. Ini adalah temuan **BL-06 (TINGGI, CONFIRMED)**.

### 2.3 Perubahan akun (BL-10, BL-11)

- Push akun manual hanya mengirim akun aktif; akun yang dinonaktifkan tidak dikirim dengan `aktif:false` (`premium_screen.dart:133-182`, `468-496`).
- Envelope karyawan tidak membawa role/izin/toko (`sync_service.dart:1305-1341`), sehingga perubahan izin tidak merata antardevice.
- `permission_version` dinaikkan lokal, tetapi tidak menjadi bagian dari payload envelope.

**Dampak:** status dan izin akun dapat berbeda antara database pemilik, relay, dan perangkat lain. Ini adalah **BL-10 dan BL-11 (SEDANG, CONFIRMED)**.

---

## 3. Otorisasi fitur

| Area | Pemeriksaan | Kelemahan |
|---|---|---|
| Nota baru | `Permissions.require` + `roleAllows` + `typeEnabled` + persetujuan harga | Baik |
| Retur | Service memakai izin `void`, bukan `retur` | BL-09 |
| Void | Izin `void`, owner-only untuk beberapa kasus | Baik, tetapi lihat BL-34 |
| Koreksi nota | Izin `koreksi`, validasi batas harga | Baik |
| Pelunasan | `canWriteMoney` | Baik |
| Stok | `stock_in`, `stock_out`, `opname`, `ubah_stok` | Baik |
| Estimasi | Batal tidak memakai actor; revisi tanpa cek status | BL-12 |
| Order kerja | Memakai `buat_nota`, bukan izin jenis order | BL-36 |
| Follow-up | Tidak memakai actor/izin | BL-31 |
| `actor == null` | Dianggap owner di beberapa service | BL-27, BL-37 |
| Viewer | `isOwner => mode != 'employee'` | BL-28 |

**Penilaian:** sebagian besar service memeriksa izin di lapisan data, bukan hanya UI. Namun ada beberapa jalur yang mengabaikan actor atau memakai izin yang salah, sehingga kontrol peran tidak konsisten. Temuan ini berdampak langsung pada siapa yang boleh mengubah uang, stok, dan nota.

---

## 4. Keamanan sinkronisasi dan relay

### 4.1 Yang sudah kuat

- Setiap amplop membawa signature perangkat; relay memverifikasi dengan public key perangkat (`server.dart:707-745`). Hint juga ditandatangani agar tidak dapat dipalsukan tanpa kunci perangkat.
- Relay memeriksa izin pengirim karyawan berdasarkan `role_base`, `extra_permissions`, dan `permissions_explicit` (`303-327`), lalu penerima memverifikasi ulang (`sync_conflict_rules.dart:152-185`).
- Kunci toko dibungkus untuk perangkat penerima dengan X25519 + HKDF + AES-GCM (`crypto.dart:76-135`).
- `relay_seq` diserialisasi per toko dengan advisory lock, mencegah perangkat melewati amplop yang commit belakangan (`server.dart:263-273`).
- Idempotensi amplop memakai `(store, sender_device, seq)` dan `envelope_id`; duplikat tidak diterapkan ulang.
- Perangkat viewer dibatasi di endpoint manajemen (`_manageAuth`, `allowViewer`) dan penerima menolak entity dari `sender.kind == 'viewer'` (`sync_conflict_rules.dart:157`).

### 4.2 Kelemahan

- **BL-06:** status akun tidak diperiksa pada setiap penggunaan token.
- **BL-35:** `_deviceAuth` tidak memeriksa masa lisensi owner; perangkat terdaftar tetap dapat menyinkronkan setelah lisensi berakhir.
- **BL-21:** validasi stok hanya lokal; dua perangkat dapat menjual stok yang sama dan penerima menerima stok negatif. Ini bukan eskalasi hak akses, tetapi merupakan kegagalan kontrol bisnis yang berdampak finansial.
- **BL-41:** kode barang duplikat menyebabkan amplop gagal dan cursor tertahan. Selain bug integritas, ini dapat dipakai untuk menahan sinkronisasi perangkat lain secara tidak sengaja (denial of sync).
- **BL-30:** koreksi yang tiba sebelum nota dibuang dan envelope dianggap selesai; data hilang tanpa peringatan.
- **BL-42:** restore yang terhenti dapat menghilangkan database aktif; tidak ada pemulihan otomatis. Ini masalah ketersediaan/integritas, bukan kebocoran.

---

## 5. Perlindungan data dan kebocoran

### 5.1 Backup (BL-22)

Passphrase backup otomatis ditampilkan dalam teks jelas di layar Pengaturan (`settings_screen.dart:56-67`). Siapa pun yang melihat layar dapat membuka arsip backup yang berisi seluruh database bisnis. Enkripsi AES-GCM menjadi tidak efektif terhadap orang yang memiliki akses fisik sementara ke perangkat yang tidak terkunci.

**Rekomendasi:** tampilkan hanya setelah verifikasi PIN/owner, sediakan tombol salin dengan konfirmasi, atau gunakan kunci yang terikat ke perangkat dan mekanisme ekspor eksplisit.

### 5.2 Database non-SQLCipher

`_usesSqlCipher` hanya true untuk Android/iOS/macOS; Windows/Linux/web memakai SQLite polos (`app_database.dart:197-208`). Aplikasi menampilkan peringatan, tetapi data bisnis dan hash PIN tetap tersimpan tanpa enkripsi di platform tersebut. Ini adalah keputusan platform yang terdokumentasi, bukan temuan baru, namun relevan untuk deployment desktop.

### 5.3 Token dan kredensial

- Token relay disimpan di SecureStore dan disalin ke `SyncSecrets`; salinan lama di `app_settings` dihapus (`session_service.dart:213-222`).
- Token bot Telegram disimpan di SecureStore, dan pesan error dibersihkan dari token sebelum disimpan (`backup_service.dart:599-635`).
- Kunci privat perangkat disimpan di SecureStore (`employee_auth_service.dart:225-237`).

**Penilaian:** kredensial tidak ditempatkan di database biasa. Namun backup database tetap memuat hash PIN dan data bisnis; perlindungan backup bergantung pada passphrase (BL-22).

### 5.4 Viewer (BL-28)

`SessionProfile.isOwner` menganggap semua mode selain `employee` sebagai owner, termasuk `viewer`. Operator viewer mendapat `can()` yang selalu true. Database viewer adalah salinan lokal yang dapat ditulis; pembatasan hanya dari shell UI. Bila ada jalur yang membuka layar tulis, tidak ada penolakan di lapisan service.

**Dampak:** kontrol "hanya baca" tidak memiliki pertahanan berlapis. Rekomendasi: tambahkan `kind: 'viewer'`, tolak semua izin tulis di `can()`, dan buka database viewer read-only bila platform mendukung.

---

## 6. Lisensi dan waktu

- Token lisensi ditandatangani Ed25519 dan diverifikasi dengan public key yang dipin (`license_verifier.dart:59-100`). Ini mencegah token palsu.
- Status aktif dihitung dengan `periodEnd.isAfter(DateTime.now().toUtc())` (`license_verifier.dart:39-41`), tanpa waktu server yang ditandatangani.
- Relay tidak memeriksa lisensi pada setiap sinkronisasi (BL-35); lisensi diperiksa saat login/enroll.

**Dampak:** pengguna dapat memundurkan jam perangkat untuk memperpanjang tampilan premium (BL-29), dan perangkat yang sudah terdaftar tetap dapat menyinkronkan setelah lisensi berakhir (BL-35). Keduanya berisiko pendapatan, bukan integritas data.

---

## 7. Temuan keamanan yang relevan

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-06 | Karyawan nonaktif masih dapat menulis/membuka sesi | TINGGI | CONFIRMED |
| BL-09 | Retur memakai izin `void` | SEDANG | CONFIRMED |
| BL-10 | Deaktivasi akun tidak dikirim ke relay | SEDANG | CONFIRMED |
| BL-11 | Role/izin/toko tidak ikut envelope | SEDANG | CONFIRMED |
| BL-22 | Passphrase backup ditampilkan | SEDANG | CONFIRMED |
| BL-28 | Viewer dianggap owner | RENDAH | SUSPECTED |
| BL-29 | Lisensi memakai jam perangkat | RENDAH | SUSPECTED |
| BL-27 | `actor == null` dianggap owner | RENDAH | CONFIRMED |
| BL-31 | Follow-up tanpa aktor/izin | RENDAH | SUSPECTED |
| BL-35 | Token perangkat tidak memeriksa lisensi | RENDAH | SUSPECTED |
| BL-37 | `createEstimate` actor null = owner | RENDAH | CONFIRMED |
| BL-41 | Duplikat kode barang menahan sinkronisasi | SEDANG | SUSPECTED |
| BL-42 | Restore tidak atomik | TINGGI | SUSPECTED |

Detail lengkap ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 8. Skenario penyalahgunaan yang dianalisis

| Skenario | Kemungkinan dari kode | Dampak |
|---|---|---|
| Mantan karyawan memakai perangkat lama | Token masih valid; PIN lokal masih membuka | Menulis nota/stok (BL-06) |
| Karyawan dengan izin retur dimatikan tetap meretur | Service memakai izin `void` | Retur tidak sah (BL-09) |
| Pemilik menonaktifkan akun, relay tetap menerima login | Akun nonaktif tidak dipush | Akses berlanjut (BL-10) |
| Dua perangkat memakai izin berbeda | Envelope tidak membawa role/izin | Aksi melebihi izin (BL-11) |
| Orang melihat layar backup | Passphrase tampil | Seluruh database dapat dibuka (BL-22) |
| Perangkat viewer membuka layar tulis | Tidak ada penolakan service | Salinan viewer berubah (BL-28) |
| Jam perangkat dimundurkan | Lisensi lokal | Premium tetap aktif (BL-29) |
| Lisensi berakhir | Token perangkat tidak diperiksa | Sinkronisasi tetap berjalan (BL-35) |
| Kode barang dibuat sama di dua perangkat | UNIQUE gagal; cursor tertahan | Sinkronisasi berhenti (BL-41) |
| Proses mati saat restore | Database lama sudah dihapus | Data tampak hilang (BL-42) |

---

## 9. Batas audit

- Tidak ada scanner SAST/DAST, uji penetrasi, atau analisis dependensi yang dijalankan.
- Tidak ada verifikasi runtime terhadap SecureStore/keystore, TLS, atau perilaku relay.
- Kode relay diperiksa pada bagian auth, izin, envelope, lisensi, dan manajemen perangkat; endpoint lain tidak diaudit mendalam.
- Tidak ada analisis kerentanan library (versi paket, CVE) karena instalasi/pembaruan dependensi dilarang.
- Tidak ada klaim bahwa skenario penyalahgunaan pasti berhasil; status validitas mengikuti bukti kode.

**Kesimpulan area:** fondasi kriptografi (SQLCipher, PBKDF2, AES-GCM, Ed25519, X25519, HKDF, HTTPS) dan verifikasi tanda tangan relay tergolong kuat. Kelemahan keamanan yang berdampak bisnis terkonsentrasi pada **otorisasi yang tidak mengikuti status akun/toko (BL-06, BL-08, BL-10, BL-11)**, **paparan passphrase backup (BL-22)**, **pemisahan viewer yang hanya di UI (BL-28)**, dan **lisensi yang bergantung pada waktu/endpoint (BL-29, BL-35)**. Tidak ditemukan bukti kebocoran kunci privat ke database biasa.
