# 08 — Audit Alur Aplikasi

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada aplikasi yang dijalankan, layar dibuka, login dicoba, atau simulasi runtime. Alur disimpulkan dari pemanggilan widget/service dan urutan penulisan database.

**Berkas utama:** `pusatkupos/lib/ui/entry_gate.dart`, `onboarding.dart`, `pin_gate.dart`, `home_shell.dart`, `owner_viewer.dart`, `settings_screen.dart`, `stores_screen.dart`; `pusatkupos/lib/data/session_service.dart`, `employee_auth_service.dart`, `pairing_service.dart`, `pin_service.dart`, `login_guard.dart`, `store_service.dart`, `store_settings.dart`, `account_service.dart`; `relay/lib/server.dart`.

---

## 1. Titik masuk dan mode aplikasi

| Mode | Cara masuk | Identitas | Database |
|---|---|---|---|
| `free` | Onboarding "tanpa akun" | Owner lokal (`owner_identity`) | Database toko utama |
| `premium` | Google login + enroll | Owner relay | Database toko utama |
| `employee` | Login online atau pairing undangan | Akun karyawan relay + PIN lokal | Database toko utama |
| `viewer` | Google login mode ringkasan | Owner relay, `isViewer` | Database salinan terpisah (`openViewerDatabase`) |

`EntryGate` memuat `SessionProfile` dari SecureStore. Bila profil tidak ada tetapi PIN sudah dikonfigurasi, aplikasi membuat profil owner lokal (`entry_gate.dart:29-43`). Bila profil viewer, database viewer dibuka; selain itu database utama. Setelah itu `PinGate` selalu ditampilkan sebelum shell.

**Penilaian:** pemisahan database viewer dari database pembukuan baik. Namun `SessionProfile.isOwner => mode != 'employee'` (`session_service.dart:48`) membuat mode `viewer` juga menghasilkan operator owner (BL-28).

---

## 2. Onboarding

### 2.1 Mode owner

- `_startFree` memanggil `LicenseService.ensureOwner`, membuat profil `free`, lalu `_finish`.
- `_startGoogle` meminta Google login, mengambil daftar toko dari relay, membuat profil `premium`.
- `_startViewer` membuka database viewer lebih dulu, memasang lisensi, menyimpan ringkasan bertanda tangan dan enroll token, lalu membuat profil `viewer`.
- `_finish` selalu meminta PIN baru (`PinSetupPage`), menyimpan PIN lewat `PinService.setup`, menyimpan profil, mengatur `app.store_id`, memuat `AppState`, dan membuka shell (`onboarding.dart:323-360`).

**Penilaian:** PIN wajib dibuat untuk semua mode owner. Batal membuat PIN pada mode viewer membersihkan enroll token dan kembali ke database utama (`330-338`), sehingga tidak tertinggal di mode viewer tanpa sesi.

### 2.2 Mode karyawan

- Login online (`employee_auth_service.dart:58-270`) memanggil relay, memasang lisensi owner, menyimpan device lokal + kunci tanda tangan/enkripsi di SecureStore, token relay, dan profil sesi.
- Login **tidak** menyisipkan baris `employee_accounts` lokal. Hanya alur pairing undangan yang menyisipkan akun (`pairing_service.dart:87`).
- Setelah login, karyawan membuat PIN lokal (`ownerPin: false`). PIN ini membuka aplikasi saat offline.
- Bila `must_change_password`, onboarding memaksa ganti password sebelum melanjutkan (`onboarding.dart:209-300`).

**Konsekuensi:** perangkat yang login langsung tanpa pairing dapat memiliki profil dan token, tetapi tidak memiliki baris `employee_accounts`. Fitur yang membaca akun (pemilihan mekanik, komisi, payroll) tidak mengenali karyawan tersebut (BL-07).

---

## 3. Login, kunci layar, dan keluar

### 3.1 Verifikasi PIN

`PinGate._submit` (`pin_gate.dart:55-125`):

1. `PinService.verifyDetailed` memeriksa lockout (`LoginGuard`), lalu hash PBKDF2 600.000 iterasi; hash lama SHA-256 dimigrasikan saat berhasil.
2. Owner: operator dibuat dari profil.
3. Karyawan: izin dihitung ulang dari `StoreSettingsService.accessFor(role, extras)` saat unlock, sehingga perubahan izin peran berlaku setelah layar dibuka.
4. `AppState.load()` memuat nama toko, status PIN, auto-lock, dan tema.
5. `unlockOnly` kembali ke layar sebelumnya; selain itu membuka `HomeShell`/`OwnerViewerShell`.

**Kekuatan:** PIN owner/karyawan memakai PBKDF2 dan lockout bertingkat (5 kegagalan, backoff 30 detik hingga 1 jam). Perhitungan ulang izin saat unlock mengurangi masalah izin basi untuk perubahan pengaturan toko.

**Kelemahan:** unlock tidak membaca ulang status `aktif` akun karyawan (BL-06). Profil sesi yang tersimpan tetap dipercaya; karyawan yang dinonaktifkan masih dapat membuka aplikasi dengan PIN lama.

### 3.2 Auto-lock

- `HomeShell` mengamati lifecycle. Saat `paused`/`hidden`, waktu jeda dicatat; saat `resumed`, bila jeda ≥ `security.auto_lock_minutes`, `_lock()` membuka `PinGate(unlockOnly: true)` (`home_shell.dart:66-113`).
- Timer idle direset pada setiap `onPointerDown` (`322-325`).
- Nilai 0 menonaktifkan auto-lock.
- `AppState.reloadStore()` memuat ulang nilai auto-lock dari database toko aktif, dan listener `_syncAutoLock` memperbarui timer.

**Penilaian:** mekanisme konsisten. Tidak ada pemanggilan `_lock()` saat aplikasi dihentikan paksa; perlindungan bergantung pada PIN saat aplikasi dibuka kembali.

### 3.3 Keluar

`signOutToOnboarding` (`entry_gate.dart:74-96`):

1. Hentikan scheduler sinkronisasi.
2. `purgeDeviceIdentity` mencabut token dan kunci sinkronisasi.
3. `SessionService.clear` menghapus profil, PIN sesi, dan token; `PinService.clear` menghapus PIN owner di SecureStore dan `app_settings`.
4. Hapus enroll token, kembali ke database utama, kosongkan operator, lalu buka `EntryGate`.

**Catatan:** keluar menghapus PIN perangkat, bukan hanya sesi. Ini adalah pilihan keamanan yang wajar, tetapi berarti karyawan yang menekan "Keluar" juga menghapus PIN owner di perangkat tersebut; pemilik harus membuat PIN baru melalui onboarding. Data transaksi tidak dihapus.

---

## 4. Ganti toko

`HomeShell._openStoreSwitcher` (`home_shell.dart:142-168`):

- Toko yang boleh dipilih dibatasi `operator.storeIds` untuk non-owner.
- `StoreService.switchStore` memvalidasi izin toko, membuka database toko, dan mengubah `active_store_id`.
- Setelah itu `AppState.reloadStore()` memuat nama, alamat, PIN, tema, dan auto-lock.

**Kelemahan (BL-08):** operator tidak dihitung ulang setelah ganti toko. `AppState.load()` tidak menyentuh `AppState.operator`, sehingga `permissions` tetap berasal dari toko sebelumnya. Setiap toko memiliki `role_permissions_json` sendiri (`store_settings.dart:143-205`), sehingga operator dapat memakai izin toko A di toko B sampai logout/login.

**Kekuatan:** pembatasan `storeIds` mencegah non-owner membuka toko yang tidak diizinkan pada level service, bukan hanya UI.

---

## 5. Akun karyawan dan izin

- Perubahan akun lokal (`account_service.updateAccount`) menaikkan `permission_version` dan menulis audit lokal, tetapi tidak otomatis dikirim ke relay (BL-10).
- Push akun manual hanya mengirim akun `aktif == 1`; akun nonaktif tidak dikirim dengan `aktif:false` (BL-10).
- `enqueueEmployee` mengirim nama/aktif/kompensasi, tetapi tidak mengirim role/izin/toko (BL-11).
- Relay memeriksa `aktif` saat login/pairing (`relay/lib/server.dart:1654`, `1858`, `1990`), tetapi **tidak** memeriksa `aktif` pada `_deviceAuth`/`_employeeCanSend` (BL-06).
- Izin pada amplop dari karyawan diperiksa berdasarkan `role_base`, `extra_permissions`, dan `permissions_explicit` (`server.dart:303-327`), lalu diverifikasi ulang saat apply (`sync_conflict_rules.dart:152-185`).

**Penilaian:** ada dua lapis pemeriksaan izin (relay dan penerima), tetapi keduanya tidak memeriksa status aktif akun pada jalur perangkat. Perubahan izin juga tidak merata ke semua jalur (relay, envelope, pengaturan toko).

---

## 6. Alur transaksi dari UI ke database

Contoh alur kasir:

1. `PosScreen._save` menonaktifkan tombol dengan `_saving` dan memakai `_requestId` yang stabil selama percobaan (`pos_screen.dart:479-515`, `1289-1297`).
2. `createTransaction` memvalidasi izin, pengaturan, persetujuan, stok, harga, lalu menulis nota/baris/pembayaran/stok/komisi dalam satu transaksi (`app_database.dart:1298-1746`).
3. Setelah sukses, UI membuat `_requestId` baru (`501`, `625`), sehingga percobaan berikutnya adalah nota baru.
4. `SyncService.enqueueNote` meng-enqueue amplop; outbox disimpan dalam transaksi yang sama.

**Kekuatan:** tombol simpan dinonaktifkan selama proses, dan `request_id` UNIQUE mencegah nota ganda bila permintaan yang sama diulang. Ini adalah pola retry-safe yang baik untuk nota.

**Kelemahan terkait:** pelunasan membuat `requestId` baru setiap kali dialog dikonfirmasi (`history_screen.dart:298-304`), sehingga percobaan ulang manual bukan duplikat yang terdeteksi; retur tidak memiliki kunci idempoten (BL-13). Pelunasan lintas perangkat tidak memeriksa sisa tagihan terbaru (BL-14).

---

## 7. Alur backup/restore dari UI

- Pengaturan memuat status backup, passphrase otomatis, jam, Telegram, dan auto-lock.
- `restoreBackup` dipanggil dari layar setelah memilih ZIP; bila `needsPassphrase`, UI meminta passphrase.
- Restore menolak mode viewer (`backup_service.dart:911-916`), lalu menjalankan validasi dan penggantian database (lihat laporan 07).
- Setelah restore, kode perangkat baru dan flag bootstrap dipasang; scheduler perlu melakukan bootstrap sebelum sinkronisasi.

**Kelemahan:** penggantian berkas tidak atomik (BL-42). UI tidak memiliki indikator/pemulihan bila proses berhenti di tengah restore; setelah dibuka kembali, database kosong dapat disalahartikan sebagai instalasi baru.

---

## 8. Temuan area alur aplikasi

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-06 | Karyawan nonaktif masih dapat menulis lewat token dan membuka sesi lokal | TINGGI | CONFIRMED |
| BL-08 | Izin operator tidak dihitung ulang saat berpindah toko | TINGGI | CONFIRMED |
| BL-07 | Akun karyawan tidak dibuat saat login dan tidak ikut snapshot | TINGGI | SUSPECTED |
| BL-10 | Perubahan/deaktivasi akun tidak otomatis dikirim ke relay | SEDANG | CONFIRMED |
| BL-11 | Role/izin/toko tidak ikut envelope sinkronisasi | SEDANG | CONFIRMED |
| BL-12 | Estimasi: batal tanpa otorisasi, revisi tanpa cek status/versi | SEDANG | CONFIRMED |
| BL-28 | Viewer dianggap owner; database viewer dapat ditulis | RENDAH | SUSPECTED |
| BL-31 | Follow-up tanpa aktor/izin dan kuota dikonsumsi sebelum commit | RENDAH | SUSPECTED |
| BL-42 | Restore tidak atomik dan tidak pulih otomatis | TINGGI | SUSPECTED |

Detail lengkap ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 9. Skenario kegagalan alur

| Skenario | Perilaku kode | Kesimpulan |
|---|---|---|
| Karyawan dinonaktifkan saat perangkat masih login | Token tetap diterima; PIN lokal tetap membuka | BL-06 |
| Perangkat karyawan pindah toko dengan izin berbeda | Operator tidak dihitung ulang | BL-08 |
| Login karyawan tanpa pairing | Profil/token tersimpan, `employee_accounts` tidak | BL-07 |
| Pemilik mengubah role lalu menekan push | Akun aktif dikirim; akun nonaktif tidak | BL-10 |
| Dua perangkat mengubah izin akun | Envelope tidak membawa role/izin | BL-11 |
| Karyawan membatalkan estimasi | `actor` diabaikan | BL-12 |
| Dua perangkat merevisi estimasi yang sama | Dua baris versi sama (index tidak unik) | BL-12 |
| Auto-lock habis | PIN gate muncul saat resume | Baik |
| Aplikasi ditutup paksa tanpa auto-lock | PIN diminta saat dibuka kembali | Baik, bergantung PIN |
| Logout karyawan | PIN perangkat (termasuk owner) dihapus | Perlu pemahaman operator; data aman |
| Restore terhenti | Database kosong tanpa pemulihan | BL-42 |
| Viewer membuka layar tulis | Tidak ada penolakan service | BL-28 |

---

## 10. Batas audit

- Tidak ada login, pairing, ganti toko, atau restore yang dijalankan.
- Widget dialog dan navigasi sebagian hanya dibaca pada titik pemanggilan; rute yang tidak terhubung tidak ditelusuri.
- Perilaku platform (SecureStore, lifecycle Android/desktop) tidak diuji.
- Relay diperiksa pada bagian auth dan izin yang memengaruhi aplikasi; endpoint lain di luar cakupan.
- Tidak ada pengujian PIN/lockout secara nyata; kesimpulan berasal dari konstanta dan urutan kode.

**Kesimpulan area:** alur utama (onboarding → PIN → shell, auto-lock, ganti toko, logout, transaksi) tersusun jelas dan memiliki kontrol dasar yang baik. Kelemahan terbesar ada pada **otorisasi yang tidak mengikuti status akun dan toko aktif (BL-06, BL-08)**, **penyebaran akun/izin yang tidak lengkap (BL-07, BL-10, BL-11)**, dan **restore yang tidak tahan penghentian proses (BL-42)**.
