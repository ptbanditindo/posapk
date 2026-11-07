# 07 — Audit Backup, Restore, dan Snapshot

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada backup dibuat, restore dijalankan, arsip didekripsi, atau test/build/aplikasi/server yang dijalankan. Seluruh penilaian berasal dari pembacaan kode.

**Berkas utama:** `pusatkupos/lib/data/backup_service.dart`, `pusatkupos/lib/data/backup_platform_io.dart`, `pusatkupos/lib/sync/snapshot_sync.dart`, `pusatkupos/lib/sync/snapshot_platform_io.dart`, `pusatkupos/lib/data/app_database.dart` (`checkpoint`, `exportPortableCopy`, `exportPlainDatabaseAt`, `createEncryptedCopy`), `pusatkupos/lib/ui/screens/settings_screen.dart`.

---

## 1. Format backup yang terdeteksi

| Format | Isi | Enkripsi | Catatan |
|---|---|---|---|
| 1 (lama) | `pusatkupos.db` di ZIP | Kunci perangkat | Ditolak saat restore karena tidak dapat didekripsi di perangkat lain |
| 2 (`_singleStoreFormat`) | Satu payload + `manifest.json` | AES-256-GCM + PBKDF2 210.000 | Satu toko |
| 3 (`_backupFormat`) | `stores/<n>.db.enc` per toko + manifest berisi daftar toko | AES-256-GCM + PBKDF2 210.000 per toko | Multi-toko, menyimpan `active_store_id` |

Konstanta terkait (`backup_service.dart:21-31`): batas 512 MB per database dan total, manifest maksimum 1 MB, batas Telegram 50 MB, retensi 30 backup otomatis, PBKDF2 210.000 iterasi, tag AES-GCM 16 byte.

**Penilaian format:** manifest menyimpan `store_id`, `database_id`, nama, alamat, `payload`, `sha256`, dan metadata cipher per toko. Ini cukup untuk memulihkan beberapa toko sekaligus dan memverifikasi isi sebelum mengganti database.

---

## 2. Pembuatan backup

### 2.1 Backup manual (`createBackup` `406-448`)

- Passphrase portabel minimal 8 karakter; bila kosong, arsip memakai passphrase otomatis dari SecureStore.
- `_buildArchive` (`297-356`) mengekspor setiap toko, menghitung SHA-256, mengenkripsi payload, lalu menulis manifest.
- Database aktif diekspor lewat `exportPortableCopy`/`sqlcipher_export`; database toko nonaktif diekspor lewat `exportPlainDatabaseAt` (`app_database.dart:311-334`).
- Batas ukuran diperiksa **sebelum** enkripsi: per toko 512 MB dan total semua toko 512 MB (`312-318`).

### 2.2 Backup otomatis (`449-503`)

- Menulis status percobaan, membuat arsip dengan passphrase otomatis, menyimpan ke folder backup aplikasi, memperbarui `backup.last_local_at`, lalu memangkas arsip lama menjadi 30 berkas (`637-648`).
- Bila Telegram aktif, arsip yang sama dikirim sebagai dokumen; kegagalan unggah tidak membatalkan backup lokal dan dicatat sebagai `telegram_pending`.
- Token bot disimpan di SecureStore, bukan di `app_settings` (`_telegramTokenKey`). Pesan error dibersihkan dari token sebelum disimpan (`_scrubToken`).

**Penilaian:** pemisahan backup lokal dan unggahan Telegram baik; kegagalan jaringan tidak menghilangkan backup lokal. Namun arsip otomatis dan arsip Telegram memakai passphrase yang sama dengan yang ditampilkan di layar (BL-22).

### 2.3 Passphrase otomatis (BL-22)

`_autoPassphrase` membuat 32 byte acak dan menyimpannya di SecureStore (`195-204`). `autoPassphrase()` sengaja diekspos, dan `settings_screen.dart:56-67` memuatnya ke `TextEditingController` sehingga tampil sebagai teks biasa tanpa autentikasi ulang. Siapa pun yang melihat layar dapat membaca kunci seluruh arsip backup.

**Catatan:** komentar kode menyatakan tampilan ini disengaja agar arsip Telegram dapat dipulihkan setelah aplikasi dipasang ulang. Ini alasan operasional yang sah, tetapi kontrol aksesnya tetap perlu diperkuat (PIN/owner sebelum menampilkan atau menyalin).

---

## 3. Enkripsi dan integritas

| Aspek | Implementasi | Penilaian |
|---|---|---|
| Kunci | PBKDF2-HMAC-SHA256, 210.000 iterasi, salt 16 byte acak per payload | Baik |
| Cipher | AES-256-GCM, nonce 12 byte acak per payload | Baik |
| Integritas ciphertext | Tag GCM 16 byte | Baik |
| Integritas payload | SHA-256 dibandingkan setelah dekripsi | Baik |
| Manifest | `format`, `app`, `created_at`, daftar toko | Tidak ditandatangani; arsip tidak memiliki tanda tangan pemilik |
| Validasi tipe database | 16 byte pertama `SQLite format 3\0` (`1194-1197`) | Baik |
| Validasi skema restore | `_requiredRestoreTables` + `PRAGMA integrity_check` | Baik |

**Penilaian:** perlindungan kerahasiaan dan integritas payload kuat. Manifest tidak ditandatangani, tetapi payload tidak dapat dipalsukan tanpa passphrase karena checksum dan tag GCM. Risiko utama bukan kriptografi, melainkan alur penggantian berkas dan paparan passphrase.

---

## 4. Restore

### 4.1 Restore satu toko (`704-901`)

Alur:

1. Baca ZIP, validasi manifest dan versi format.
2. Batasi ukuran payload terkompresi dan hasil dekompresi 512 MB.
3. Dekripsi dengan passphrase pengguna atau passphrase otomatis untuk `scope=auto`.
4. Verifikasi SHA-256 dan header SQLite.
5. Validasi tabel wajib pada salinan sementara; bila SQLCipher, buat salinan terenkripsi dan validasi.
6. `checkpoint`, buat salinan pengaman `.bak-*`, tutup database, ganti berkas, buka kembali, jalankan `PRAGMA integrity_check`.
7. Bila integritas gagal, kembalikan salinan pengaman dan buka kembali.
8. Set `device.seq_floor`, buat kode perangkat baru, set `sync.restore_requires_bootstrap=1`.

**Kekuatan:** verifikasi berlapis, rollback dalam proses, dan pemutaran ulang identitas perangkat setelah restore. `device.kode_lokal` baru mencegah nomor nota bentrok dengan perangkat lain. Flag bootstrap memaksa sinkronisasi awal yang terkontrol.

**Kelemahan:** penggantian berkas tidak atomik (BL-42). `replaceDatabase` menghapus database lama sebelum rename; bila proses berhenti tepat di antara keduanya, tidak ada database aktif. Salinan `.bak-*` tidak dipindai saat startup.

### 4.2 Restore multi-toko (`904-1184`)

- Menolak restore bila sedang memakai database viewer.
- Memvalidasi setiap toko, mendekripsi, memeriksa checksum, dan menyiapkan berkas sementara.
- Menentukan `store_id`/`database_id` baru bila kosong atau duplikat, sehingga dua entri arsip tidak saling menimpa.
- Membuat salinan pengaman untuk setiap target, menutup database, lalu mengganti berkas satu per satu.
- Bila satu penggantian gagal, berkas yang sudah diganti dikembalikan dari salinan pengaman; semua temp dihapus.
- Registry diperbarui setelah semua berkas diganti; bila registry gagal, restore dilaporkan gagal meskipun berkas toko sudah berganti.
- Setiap toko mendapat `seq_floor`, kode perangkat baru, dan flag bootstrap.

**Kelemahan tambahan:** penggantian dilakukan per berkas dan registry diperbarui setelahnya. Penghentian proses di tengah loop meninggalkan campuran database baru dan lama, sementara registry masih menunjuk susunan lama sampai langkah terakhir. Ini memperluas dampak BL-42 ke konsistensi antartoko.

### 4.3 Batas ukuran multi-toko (BL-20)

Saat membuat arsip, total semua toko dibatasi 512 MB (`312-318`). Saat restore multi-toko, hanya ukuran per payload yang dibatasi 512 MB (`949-977`); tidak ada akumulasi total. Arsip dari versi lama/aplikasi lain dapat berisi banyak toko yang masing-masing di bawah batas tetapi totalnya jauh lebih besar, sehingga restore dapat menghabiskan disk atau gagal setelah sebagian toko diganti.

---

## 5. Snapshot sinkronisasi

- `createSnapshotPayload` mengekspor database dengan `VACUUM INTO`, menghapus tabel lokal, menghapus pengaturan lokal, lalu mengenkripsi dan menandatangani payload (`snapshot_sync.dart:104-143`).
- `applySnapshotPayload` memeriksa idempotensi, urutan `store_seq`, tidak ada outbox/inbox tertunda, tanda tangan Ed25519, checksum, lalu mengimpor seluruh tabel bisnis dalam satu transaksi (`145-260`).
- Tabel lokal yang tidak ikut snapshot: `owner_identity`, `license`, `employee_accounts`, `permission_audits`, `devices`, `login_guards`, `sync_outbox`, `sync_inbox`, `sync_cursor`, `applied_deltas`, `sync_conflicts`, `device_sync_status`, `document_counters` (`snapshot_sync.dart:12-90`).
- Setelah impor, `applied_deltas` dihapus dan cursor diatur ke `store_seq` snapshot.

**Kekuatan:** snapshot tidak menimpa identitas perangkat/kredensial lokal; impor atomik; signature dan checksum mencegah payload palsu.

**Kelemahan:** `employee_accounts` dan `document_counters` tidak ada di snapshot (BL-07). Perangkat baru hasil snapshot tidak memiliki akun karyawan; rekalkulasi komisi dapat menghasilkan nol (BL-04), dan payroll tidak lengkap. Penghitung dokumen mulai dari nol tetapi dilindungi oleh kode perangkat baru dan renumber nota.

---

## 6. Temuan area backup/restore

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-42 | Restore mengganti database secara non-atomik; tidak ada pemulihan otomatis | TINGGI | SUSPECTED |
| BL-20 | Restore multi-toko tidak membatasi total ukuran hasil dekompresi | SEDANG | CONFIRMED |
| BL-22 | Passphrase backup otomatis ditampilkan dalam teks jelas | SEDANG | CONFIRMED |
| BL-07 | `employee_accounts`/`document_counters` tidak ikut snapshot | TINGGI | SUSPECTED |
| BL-32 | Backup toko nonaktif dibaca tanpa checkpoint pada jalur non-SQLCipher | RENDAH | SUSPECTED |
| BL-33 | Kode perangkat/counter dokumen berpotensi bentrok | RENDAH | SUSPECTED |

Detail lengkap ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 7. Skenario kegagalan

| Skenario | Perilaku kode | Kesimpulan |
|---|---|---|
| Passphrase salah | Dekripsi GCM gagal; pesan "passphrase salah atau rusak" | Aman |
| Payload diubah | Tag GCM/checksum gagal | Aman |
| Arsip bukan backup PusatkuPOS | Manifest/tabel wajib gagal | Aman |
| Backup saat toko nonaktif belum checkpoint (non-SQLCipher) | Berkas utama dibaca langsung | Transaksi terakhir di WAL tidak ikut (BL-32) |
| Restore database rusak | Validasi salinan sementara + `integrity_check` + rollback | Baik dalam proses yang sama |
| Proses berhenti saat replace | Database lama sudah dihapus, rename belum selesai | Database kosong; `.bak` tidak dipulihkan otomatis (BL-42) |
| Restore multi-toko berhenti di tengah | Sebagian toko baru, sebagian lama; registry belum diperbarui | Campuran data antartoko (BL-42) |
| Restore multi-toko berukuran besar | Tidak ada batas total | Disk penuh/kegagalan sebagian (BL-20) |
| Snapshot diterapkan saat outbox/inbox tertunda | Ditolak dengan pesan jelas | Baik |
| Snapshot dari perangkat lain | Signature/checksum dan `store_id` diverifikasi | Baik |
| Backup otomatis gagal diunggah | Backup lokal tetap ada; status pending | Baik |
| Layar backup dibuka orang lain | Passphrase otomatis tampil | Arsip dapat dibuka (BL-22) |

---

## 8. Batas audit

- Tidak ada arsip backup nyata yang dibuka, didekripsi, atau dipulihkan.
- Tidak ada pengujian proses terhenti; BL-42 disimpulkan dari urutan operasi berkas, bukan dari reproduksi.
- Perilaku `rename`/`delete` berbeda antarsistem operasi; temuan berlaku terutama untuk penghentian proses, bukan kegagalan API biasa (yang ditangani `catch`).
- Format backup lama (1) hanya dinilai dari jalur penolakannya; tidak ada arsip format 1 untuk diperiksa.
- Integrasi Telegram tidak diuji; hanya alur kode dan penanganan error yang dibaca.

**Kesimpulan area:** kriptografi backup (AES-256-GCM, PBKDF2 210.000, checksum, signature snapshot) dan validasi restore berlapis merupakan bagian yang kuat. Kelemahan utama ada pada **penggantian berkas yang tidak atomik dan tidak memiliki pemulihan startup (BL-42)**, **paparan passphrase (BL-22)**, **batas ukuran restore multi-toko (BL-20)**, dan **data akun yang tidak ikut snapshot (BL-07)**. Backup tidak dapat dianggap sebagai jaminan pemulihan penuh sampai BL-42 dan BL-07 ditangani.
