# 07 — AUDIT BACKUP DAN RESTORE

**Cakupan:** pembuatan backup (terenkripsi dan polos), penjadwalan, validasi, restore, dan pemulihan kegagalan.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Format dan Jalur Backup

| Format | Platform | Enkripsi | Isi |
|---|---|---|---|
| Backup terenkripsi (`.pusatkupos`) | Android/iOS/desktop | AES + PBKDF2 210.000 iterasi | Database SQLCipher + manifest |
| Backup polos | Web/non-SQLCipher | Tidak | File SQLite |
| Snapshot sinkronisasi | Semua | Payload terenkripsi store key | Tabel tersinkron (lihat 06) |
| Auto-backup | Semua | Mengikuti format | Disimpan lokal, maksimum 30 |

### 1.1 Manifest

```dart
final manifest = jsonEncode({
  'format': _backupFormat,        // 3
  'app': 'PusatkuPOS',
  'created_at': nowIso(),
  'active_store_id': ...,
  'stores': manifestStores,
});
```

**Tidak ada:** `schema_version`, `app_version`, `schema_contract_version`, jumlah baris per tabel, checksum per tabel.

---

## 2. Alur Pembuatan Backup

### 2.1 Database terenkripsi

```
BackupService.createBackup
  ├─ tentukan path & passphrase
  ├─ checkpoint WAL
  ├─ buat salinan sementara terenkripsi (createEncryptedCopy)
  │    ├─ buka sumber
  │    ├─ buka target SQLCipher
  │    ├─ salin skema/data
  │    └─ PRAGMA user_version = schemaVersion   ← DB-02
  ├─ tulis manifest
  ├─ kompres/enkripsi payload
  └─ simpan / kirim Telegram
```

### 2.2 Database polos

`_exportPlainDatabase`:

```dart
if (!db.databaseEncrypted) {
  await db.exportPortableCopy(db.databasePath);
  return platform.readDatabase(db.databasePath);
}
```

`exportPortableCopy` hanya menjalankan `PRAGMA wal_checkpoint(FULL)` lalu membaca file database yang sedang terbuka. **Tidak ada penghentian penulis** (BAK-02). Penulisan setelah checkpoint dan selama pembacaan file dapat menghasilkan salinan tanpa WAL terbaru.

### 2.3 Penjadwalan

`BackupScheduler` berjalan otomatis. Tidak ada koordinasi dengan restore: saat restore menutup/mengganti database, scheduler dapat memulai backup berikutnya terhadap file yang sedang diganti (BAK-01).

---

## 3. Alur Restore

### 3.1 Rantai

```
SettingsScreen._restore
  ├─ pilih file & masukkan passphrase        settings_screen.dart:372-425
  ├─ BackupService.restoreBackup
  │    ├─ baca manifest
  │    ├─ validasi versi format
  │    ├─ dekripsi / buka salinan
  │    ├─ validateEncryptedCopy / validatePlainCopy
  │    │    ├─ PRAGMA integrity_check
  │    │    └─ cek keberadaan _requiredRestoreTables
  │    ├─ tutup database aktif
  │    ├─ ganti file database
  │    └─ buka kembali
  └─ (tidak ada penghentian SyncScheduler/BackupScheduler)
```

### 3.2 Validasi yang ada

- Format manifest.
- `integrity_check` (struktur b-tree).
- Keberadaan 20 tabel dalam `_requiredRestoreTables`.

### 3.3 Validasi yang **tidak** ada

- `PRAGMA foreign_key_check` (DB-06).
- Jumlah baris per tabel / checksum data (DB-05).
- Kecocokan `schema_version`/`app_version` (DB-04).
- Pemeriksaan bahwa database sumber tidak lebih baru dari aplikasi (DB-02).
- Pemeriksaan konsistensi `stock_cost_state` vs `stock_items`.
- Pemeriksaan bahwa semua tabel non-lokal ada.

---

## 4. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| BAK-01 | Restore saat sync/backup scheduler aktif | HIGH | CONFIRMED | `settings_screen.dart:372-425`; `backup_service.dart:930-960` |
| BAK-02 | Ekspor database polos tanpa menghentikan penulis | MEDIUM | CONFIRMED | `backup_service.dart:299-318`; `app_database.dart:396-403` |
| DB-02 | Restore memaksa `user_version` | CRITICAL | CONFIRMED | `app_database.dart:462-481` |
| DB-04 | Tanpa versi skema/aplikasi | HIGH | CONFIRMED | `backup_service.dart:352-378` |
| DB-05 | Validasi tabel inti tidak lengkap | HIGH | CONFIRMED | `backup_service.dart:35-56,910-922` |
| DB-06 | Tanpa `foreign_key_check` | MEDIUM | CONFIRMED | `app_database.dart:520-538`; `backup_service.dart:940-955` |
| FLW-03 | Tidak ada pemulihan database rusak/tidak kompatibel | MEDIUM | CONFIRMED | `app_database.dart:301-343,345-378`; `entry_gate.dart` |

### BAK-01 — Restore bersamaan scheduler

`_restore` tidak memanggil `SyncScheduler.instance.stop()` atau memeriksa `SyncService.isSyncing`. Restore menutup dan mengganti database; scheduler tetap berjalan.

**Skenario.** Restore dimulai saat sync mengirim outbox. Database ditutup; sync gagal di tengah; outbox tetap pending. Setelah reopen, status “terkirim” mungkin sudah dicatat untuk data yang belum masuk, atau data dikirim ganda.

**Dampak.** Restore tampak berhasil tetapi antrean sync/backup rusak; data hilang/terkirim ganda.

### BAK-02 — Ekspor polos tidak atomik

`wal_checkpoint(FULL)` tidak menghentikan penulis. Salinan file dapat kehilangan transaksi terakhir atau berisi halaman yang tidak konsisten.

**Perbaikan.** Gunakan `VACUUM INTO` atau backup API SQLite, atau hentikan penulisan selama ekspor. Pada Android SQLCipher, pertahankan jalur sementara yang sudah ada.

### DB-02 — Versi dipaksa

Detail di 06. Dampak restore: skema lama diklaim baru; migrasi dilewati; aplikasi error.

### DB-04 — Tanpa metadata

Backup dari versi lebih baru dipulihkan di versi lama; tidak ada cara menolak sebelum menimpa database. Dukungan pelanggan tidak dapat menentukan kompatibilitas.

### DB-05 — Validasi tidak lengkap

Backup yang kehilangan `service_parts`, `sale_returns`, `cash_ledger`, dll. tetap lolos. Restore “berhasil” tetapi data inti hilang.

### DB-06 — Tanpa FK check

Baris yatim tidak terdeteksi; laporan dan detail nota tidak konsisten.

### FLW-03 — Tidak ada pemulihan

Database rusak/versi lebih baru melempar `StateError` sebelum UI dirender. Tidak ada layar restore/ekspor diagnostik. Pengguna mungkin menghapus data untuk “memperbaiki”.

---

## 5. Skenario Kegagalan

### 5.1 Restore terputus di tengah

1. Database aktif ditutup.
2. File lama diganti sebagian / proses crash.
3. Aplikasi dibuka kembali; file tidak lengkap.
4. `_open` gagal; startup berhenti tanpa UI (FLW-01/FLW-03).
5. Satu-satunya pemulihan adalah restore manual dari backup lain.

**Tidak ada mekanisme rollback ke file lama** atau penanda “restore belum selesai”.

### 5.2 Backup saat kasir menyimpan nota

- Backup terjadwal berjalan bersamaan dengan `createTransaction`.
- Checkpoint menunggu penulisan selesai, tetapi setelah checkpoint penulisan baru dapat masuk.
- Salinan file polos dapat kehilangan transaksi terakhir.
- Pada SQLCipher, `createEncryptedCopy` menyalin database melalui query, sehingga lebih aman, tetapi masih tidak menjamin snapshot konsisten jika ada penulisan bersamaan.

### 5.3 Restore backup versi lama

- Manifest tidak memiliki versi.
- `user_version` dipaksa ke versi terbaru.
- Migrasi tidak berjalan.
- Kolom baru hilang; aplikasi error saat query.

### 5.4 Restore saat sync berjalan

- Outbox/inbox dapat ditulis ke database yang sedang ditutup.
- Status pengiriman tidak konsisten.
- Data dapat terkirim ganda setelah reopen.

### 5.5 Backup Telegram

- Token dan chat ID disimpan di `app_settings` (tidak dienkripsi di database? Android database terenkripsi, jadi relatif aman).
- Batas 50 MB; backup besar gagal tanpa strategi pemisahan.
- Retry 10 menit; tidak ada antrean persisten untuk upload yang gagal.

---

## 6. Dampak ke Modul Lain

| Temuan | Dampak |
|---|---|
| BAK-01 | Sync, kas, stok, laporan setelah restore |
| BAK-02 | Kelengkapan backup, kepercayaan pada auto-backup |
| DB-02 | Semua modul yang membaca kolom baru |
| DB-04 | Dukungan lintas versi |
| DB-05 | Kehilangan data inti tanpa peringatan |
| DB-06 | Relasi nota/baris |
| FLW-03 | Akses pengguna ke data |

---

## 7. Rekomendasi

### 7.1 Backup

1. Tambahkan `schema_version`, `app_version`, dan `schema_contract_version` ke manifest.
2. Simpan daftar tabel + jumlah baris + checksum per tabel.
3. Gunakan backup API SQLite/`VACUUM INTO` untuk salinan konsisten.
4. Hentikan penulisan selama ekspor polos; gunakan kunci global.
5. Catat status backup terakhir dan verifikasi hasil (buka salinan dan jalankan `integrity_check`).

### 7.2 Restore

1. Hentikan `SyncScheduler` dan `BackupScheduler`; tunggu operasi selesai.
2. Validasi versi sumber terhadap versi aplikasi sebelum menimpa.
3. Pertahankan `user_version` asli; jalankan migrasi setelah restore.
4. Validasi semua tabel non-lokal, jumlah baris, `foreign_key_check`.
5. Gunakan file sementara + rename atomik; simpan file lama sampai restore dinyatakan sukses.
6. Sediakan rollback ke file lama bila reopen gagal.
7. Tampilkan status “restore dalam proses” yang memblokir aksi lain.

### 7.3 Pemulihan

1. Error boundary saat startup.
2. Layar pemulihan: versi database, restore backup, ekspor file mentah, buka mode aman.
3. Jangan pernah menghapus database otomatis.
4. Log diagnostik yang dapat diekspor tanpa data sensitif.

---

## 8. Definisi “Restore Berhasil”

Restore hanya boleh dinyatakan berhasil jika:

- versi sumber kompatibel dan migrasi selesai;
- semua tabel non-lokal ada;
- `integrity_check` dan `foreign_key_check` bersih;
- jumlah baris tabel inti sesuai manifest;
- `stock_items.jumlah_milli` konsisten dengan `stock_cost_state` (atau cost state berhasil direbuild);
- `cash_ledger` dan pembayaran konsisten;
- aplikasi dapat membuka database dan menjalankan query laporan utama;
- scheduler sync/backup dimulai ulang dan outbox tidak berisi data lama yang sudah tidak relevan.

Saat ini tidak satu pun dari kriteria di atas diperiksa secara lengkap.

---

## 9. Pertanyaan Aturan Bisnis

1. Apakah backup harus menyertakan `cash_ledger` dan audit?
2. Apakah restore boleh menimpa database yang memiliki transaksi lebih baru?
3. Apakah backup lintas versi harus didukung, atau hanya versi yang sama?
4. Apakah file backup harus selalu terenkripsi, termasuk di web?
5. Berapa lama backup lama disimpan (saat ini 30)?

---

## 10. Ringkasan

- Backup terenkripsi memiliki fondasi yang baik, tetapi **tidak membawa versi** dan **validasinya tidak lengkap**.
- Restore dapat berjalan bersamaan dengan sync/backup dan tidak memiliki rollback.
- Backup polos tidak atomik terhadap penulisan.
- Restore adalah jalur paling berbahaya untuk kehilangan data karena menggabungkan DB-02, DB-04, DB-05, BAK-01, dan FLW-03.
