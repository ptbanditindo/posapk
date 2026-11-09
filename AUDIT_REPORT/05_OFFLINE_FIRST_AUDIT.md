# 05 — OFFLINE-FIRST AUDIT

Ruang lingkup: transaksi lokal SQLite, item, harga final, pelanggan, stok, total, struk, printing, outbox, retry, status pending/synced/failed, pemulihan setelah force close/restart/putus koneksi, dan jaminan bahwa transaksi tersimpan tidak hilang karena kegagalan internet/sync.

---

## 1. Jalur Offline yang Terbukti

| Operasi | Offline? | Bukti |
|---|---|---|
| Buat nota (jasa/part) | Ya | `createTransaction` hanya menulis SQLite; sync di-enqueue |
| Hitung pajak/diskon/total | Ya | `PajakSnapshot`, `PriceRules` lokal |
| Simpan pelanggan/unit | Ya | Tabel lokal |
| Kurangi stok | Ya | `StockLedger` lokal dalam transaksi |
| Cetak struk | Ya | `ReceiptService` membaca DB; transport Bluetooth/LAN/USB lokal |
| Lihat riwayat | Ya | `listRecords` lokal |
| Retur/void | Ya (kebijakan lokal) | `SaleReturnService`, `voidRecord` |
| Opname | Ya, tetapi penerapan tertunda | `OpnameService` hold |
| Sinkronisasi | Tidak | Butuh relay; kegagalan disimpan, tidak memblokir penjualan |

**Kesimpulan:** penjualan tidak bergantung pada jaringan. Ini memenuhi inti offline-first.

---

## 2. Siklus Outbox

1. Dokumen ditulis + `enqueue` dalam transaksi DB.
2. `SyncScheduler` berkala 10–20 menit + jitter; memicu saat resume.
3. `_syncNowBody` mengirim envelope terenkripsi yang ditandatangani.
4. Server menolak duplikat berdasarkan id/seq; klien hanya ack setelah apply.
5. Outbox terkirim dipangkas setelah 90 hari oleh `cleanupSyncHistory` ([sync_service.dart:5299](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L5299)).
6. Outbox **belum terkirim tidak pernah dipangkas oleh cleanup**.

**Kontrol positif:** retry tidak menggandakan dokumen (idempotensi), dan data belum terkirim tidak dihapus oleh pembersihan rutin.

---

## 3. Registry Temuan

### OFF-01 — Logout owner menghapus transaksi yang belum tersinkron
- **Severity:** **CRITICAL** (kanonik: SEC-02)
- **Kategori:** CONFIRMED DEFECT / DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [entry_gate.dart:97](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/entry_gate.dart#L97), [pin_gate.dart:243](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/pin_gate.dart#L243), [settings_screen.dart:1107](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/settings_screen.dart#L1107)
- **Fungsi/Kelas:** `signOutSession`; dialog logout
- **Implementasi:** Untuk mode owner, `signOutSession` memanggil `purgeDeviceIdentity`, menunggu backup idle, lalu `deleteLocalDatabases`. Tidak ada pemeriksaan `sync_outbox` pending, tidak ada flush paksa, tidak ada peringatan jumlah nota belum terkirim. Peringatan generik menyebut "database lokal dihapus".
- **Penyebab:** Logout dirancang sebagai reset perangkat, bukan sebagai operasi yang sadar data.
- **Dampak:** Seluruh nota, retur, pembelian, dan perubahan stok yang belum tersinkron hilang permanen. Tidak ada jalur pemulihan karena backup otomatis mungkin belum berjalan.
- **Skenario:** SC-02, SC-03.
- **Rekomendasi:** (1) hitung outbox pending dan tampilkan; (2) wajibkan flush/backup sebelum hapus; (3) bila offline, tawarkan "keluar tanpa hapus" atau ekspor; (4) jangan hapus DB tanpa konfirmasi eksplisit + PIN.
- **Dependensi:** SEC-01, SEC-04, OFF-03.

### OFF-02 — Restore file mengganti DB dan membuang outbox yang lebih baru
- **Severity:** HIGH (kanonik: SEC-04)
- **Kategori:** CONFIRMED DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [backup_service.dart:1015](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L1015), [backup_service.dart:1069](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L1069)
- **Fungsi/Kelas:** `_restoreBackupNow`
- **Implementasi:** Restore menutup DB aktif dan menggantinya dengan staging hasil restore. Tidak ada pemeriksaan outbox pada DB aktif, tidak ada penggabungan. `device.seq_floor` dipakai untuk mencegah seq mundur, tetapi dokumen yang hanya ada di outbox lama tetap hilang.
- **Penyebab:** Restore diperlakukan sebagai penggantian total.
- **Dampak:** Nota yang dibuat setelah backup tetapi belum tersinkron hilang tanpa peringatan.
- **Rekomendasi:** Tolak restore bila outbox pending, atau ekspor/gabungkan outbox terlebih dahulu; tampilkan ringkasan data yang akan hilang.
- **Dependensi:** SEC-01, OFF-01.

### OFF-03 — Status gagal sync tidak terlihat per dokumen
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart:2580](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2580), [sync_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_scheduler.dart)
- **Fungsi/Kelas:** `_failOutbox`; `SyncScheduler.tick`
- **Implementasi:** Kegagalan menulis `sync.last_error` dan `retry_count` pada baris outbox, tetapi scheduler menelan error. Tidak ada status "pending/terkirim/gagal" per nota yang ditampilkan di riwayat.
- **Penyebab:** Observabilitas sync terbatas pada pesan global.
- **Dampak:** Pengguna mengira nota sudah aman padahal masih lokal/gagal; tidak ada cara memilih nota untuk dikirim ulang.
- **Rekomendasi:** Tampilkan badge status sync per nota, jumlah pending, error terakhir, dan tombol retry.
- **Dependensi:** ERR-05.

### OFF-04 — Force close/restart aman untuk nota yang sudah commit
- **Severity:** INFO (kontrol positif)
- **Kategori:** —
- **Status:** PASS
- **Lokasi:** [app_database.dart:1958](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1958)
- **Implementasi:** Nota di-commit sebelum UI menampilkan sukses. Bila proses mati setelah commit, data ada; bila mati sebelum commit, SQLite rollback. Outbox berada dalam transaksi yang sama.
- **Catatan:** Bila mati setelah commit tetapi sebelum `enqueue`? Tidak mungkin: `enqueue` berada di dalam transaksi.
- **Rekomendasi:** Tidak ada.

### OFF-05 — Database lokal dapat dibaca plaintext di desktop
- **Severity:** MEDIUM (kanonik: DB-03/SEC-09)
- **Kategori:** SECURITY WEAKNESS
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:407](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L407)
- **Dampak:** Pada Windows/Linux, seluruh riwayat offline terbaca tanpa kunci.
- **Rekomendasi:** Lihat DB-03.

### OFF-06 — Pemulihan setelah korupsi berpotensi kehilangan transaksi terakhir
- **Severity:** MEDIUM (kanonik: SEC-03/DB-06)
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:108](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L108)
- **Implementasi:** Safe mode mengarantina DB utama dan menghapus WAL/SHM.
- **Dampak:** Transaksi yang sudah commit di WAL hilang dari karantina.
- **Rekomendasi:** Lihat DB-06.

---

## 4. Uji Offline Wajib

| Uji | Hasil | Catatan |
|---|---|---|
| Buat nota tanpa internet | PASS | Tidak ada panggilan jaringan di jalur simpan |
| Harga final nego tersimpan lokal | PASS | Kolom snapshot |
| Struk dapat dicetak offline | PASS | Transport lokal |
| Print gagal tidak menggandakan nota | PASS | Print read-only |
| Tutup paksa setelah simpan | PASS | Commit atomik |
| Restart lalu lihat nota | PASS | `listRecords` lokal |
| Retry sync tidak menggandakan | PASS | `request_id`/sync id |
| Nota pending tidak terhapus cleanup | PASS | Cleanup hanya outbox terkirim >90 hari |
| Logout owner menyelamatkan pending | **FAIL** | OFF-01 |
| Restore menyelamatkan pending | **FAIL** | OFF-02 |
| Status sync per nota terlihat | **FAIL** | OFF-03 |
| Pemulihan korupsi mempertahankan WAL | **FAIL** | DB-06 |

---

## 5. Kesimpulan

Offline-first untuk **penulisan transaksi** berjalan baik dan tahan crash. Kegagalan utamanya bersifat **operasional-destruktif**: aksi logout/restore dapat menghapus data yang justru belum sempat tersinkron, dan pengguna tidak diberi informasi untuk mencegahnya. Selama celah ini ada, klaim "transaksi tersimpan tidak hilang karena kegagalan internet/sync" hanya benar bila pengguna tidak logout atau restore.
