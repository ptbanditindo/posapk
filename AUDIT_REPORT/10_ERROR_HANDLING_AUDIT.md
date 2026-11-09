# 10 — ERROR HANDLING & LIFECYCLE AUDIT

Ruang lingkup: internet/server mati, timeout, DB gagal/locked/korup, printer/Bluetooth, force close/restart, sync terputus, token kedaluwarsa, kunci hilang, dekripsi gagal, data tidak valid, storage penuh, background killed; prinsip: satu kegagalan tidak boleh merusak data lain, tidak ada error tersembunyi, retry tidak menggandakan, transaksi tersimpan bertahan, printer gagal tidak menyimpan ganda, recovery tidak menimpa data valid.

---

## 1. Registry Temuan

### ERR-01 — Kegagalan printer hanya snackbar; tidak ada antrean/status cetak
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [pos_screen.dart:543](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L543)
- **Fungsi/Kelas:** Alur simpan + cetak POS
- **Implementasi:** Nota disimpan lebih dulu; kegagalan cetak ditangkap dan ditampilkan sebagai snackbar. Tidak ada antrean cetak, status "belum tercetak", atau retry otomatis.
- **Penyebab:** Cetak dianggap aksi sekali jalan.
- **Dampak:** Pelanggan dapat pergi tanpa struk; kasir tidak punya cara mencetak ulang selain membuka detail nota (bila tersedia). Tidak ada risiko double-save — kontrol positif.
- **Rekomendasi:** Tandai status cetak per nota + tombol cetak ulang + antrean untuk Bluetooth yang putus.
- **Dependensi:** TRX-02.

### ERR-02 — Envelope dari pengirim tak dikenal dapat menahan cursor
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart:2488](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2488), [sync_service.dart:2546](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2546)
- **Fungsi/Kelas:** `_syncNowBody`
- **Implementasi:** Bila kunci pengirim tidak ditemukan, klien menyegarkan daftar perangkat sekali. Bila tetap tidak ada, envelope ditandai `blockedSeq` dan cursor hanya maju sampai `blockedSeq − 1`; envelope lain dari pengirim dikenal tetap diterapkan.
- **Penyebab:** Keamanan integritas menuntut kunci pengirim; tidak ada kebijakan dead-letter.
- **Dampak:** Envelope dari perangkat yang sudah dicabut/dihapus dapat memblokir kemajuan cursor selamanya, sehingga perubahan setelahnya tidak pernah di-ack.
- **Rekomendasi:** Kebijakan dead-letter setelah N percobaan/hari, dengan alert dan opsi melewati envelope yang tidak dapat diverifikasi (setelah audit).
- **Dependensi:** SEC-12, SYN-01.

### ERR-03 — Pemulihan DB korup berpotensi kehilangan transaksi WAL
- **Severity:** MEDIUM (kanonik: SEC-03/DB-06)
- **Kategori:** DATA INTEGRITY RISK
- **Status:** Terkonfirmasi
- **Lokasi:** [app_database.dart:108](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L108)
- **Implementasi:** Safe mode memindahkan DB utama ke `.corrupt-*` dan menghapus `-wal`/`-shm`.
- **Dampak:** Transaksi commit terakhir dapat hilang; recovery menimpa data valid.
- **Rekomendasi:** Lihat DB-06.

### ERR-04 — Tidak ada `busy_timeout`; risiko `database is locked`
- **Severity:** MEDIUM (kanonik: DB-02)
- **Kategori:** POTENTIAL DEFECT
- **Status:** NEEDS VALIDATION
- **Lokasi:** [app_database.dart:420](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L420)
- **Implementasi:** Hanya `foreign_keys` yang diset. Backup/restore/upgrade dan scheduler berjalan di proses yang sama; sqflite menyerialkan, tetapi operasi berat dapat memicu timeout.
- **Dampak:** Transaksi pengguna gagal dengan error teknis saat backup/restore berjalan.
- **Rekomendasi:** Set `busy_timeout`, tampilkan pesan "sibuk, coba lagi", dan uji beban.
- **Dependensi:** —

### ERR-05 — Scheduler menelan error; kegagalan berkepanjangan tidak terlihat
- **Severity:** MEDIUM (kanonik: ARC-05/OFF-03)
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_scheduler.dart), [backup_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_scheduler.dart)
- **Implementasi:** Error disimpan ke status, tidak pernah ditampilkan proaktif.
- **Dampak:** Sync/backup dapat mati diam-diam.
- **Rekomendasi:** Indikator kesehatan + notifikasi setelah N kegagalan.

### ERR-06 — Storage relay penuh menghentikan seluruh pengiriman (413)
- **Severity:** MEDIUM (kanonik: SYN-01)
- **Kategori:** PERFORMANCE ISSUE
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/config.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/config.dart), [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart)
- **Implementasi:** Batas default 256 MB; saat penuh server menolak dengan 413 dan klien berhenti mengirim.
- **Dampak:** Nota tetap lokal, tetapi tidak pernah sampai server/tablet; pengguna hanya melihat `last_error`.
- **Rekomendasi:** Alert kapasitas, pruning berbasis kebijakan, dan pesan UI yang dapat ditindaklanjuti.
- **Dependensi:** SYN-01.

### ERR-07 — Penanganan token kedaluwarsa dan dekripsi gagal belum dapat dibuktikan menyeluruh
- **Severity:** LOW
- **Kategori:** NEEDS VALIDATION
- **Status:** Sebagian kode ada; perilaku ujung belum teruji
- **Lokasi:** [sync_service.dart:2209](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2209), [sync_service.dart:180](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L180)
- **Implementasi:** `refreshEmployeePermission` dan `refreshStoreKey` ada; kegagalan dekripsi masuk `_rememberFailure`/konflik dan dicoba ulang. Tidak ada pesan khusus "kunci tidak tersedia" atau jalur pemulihan di UI.
- **Dampak:** Bila kunci hilang, pengguna melihat error sync berulang tanpa instruksi.
- **Rekomendasi:** Petakan error kripto ke pesan yang dapat ditindaklanjuti + jalur enrollment owner.
- **Dependensi:** SEC-13.

### ERR-08 — Envelope tidak valid dapat dicoba ulang tanpa dead-letter
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart:2516](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2516)
- **Fungsi/Kelas:** `_applyOnce` catch → `_rememberFailure`
- **Implementasi:** Kegagalan apply dihitung sebagai konflik dan disimpan untuk retry; tidak ada batas akhir yang menampilkan envelope sebagai "gagal permanen".
- **Dampak:** Beban retry terus-menerus; konflik tidak terlihat pengguna.
- **Rekomendasi:** Dead-letter + laporan konflik yang dapat ditinjau.
- **Dependensi:** ERR-02.

---

## 2. Matriks Kegagalan

| Skenario | Perilaku kode | Menyebabkan korupsi? | Status |
|---|---|---|---|
| Internet mati saat simpan | Tidak ada I/O jaringan di transaksi | Tidak | PASS |
| Server 500/timeout saat sync | Outbox tetap; retry | Tidak | PASS |
| Retry sync | Idempotensi | Tidak | PASS |
| Aplikasi ditutup saat simpan | SQLite atomik | Tidak | PASS |
| Aplikasi ditutup saat sync | Cursor/ack setelah apply | Tidak | PASS |
| DB korup | Safe mode | **Ya (WAL hilang)** | FAIL |
| DB locked | Tidak ada busy_timeout | Tidak, tetapi gagal | NEEDS VALIDATION |
| Printer/Bluetooth gagal | Snackbar; nota tersimpan | Tidak | PARTIAL |
| Force close saat restore | `recoverInterruptedRestore` + staging | Tidak | PASS |
| Token kedaluwarsa | Refresh permission/store key | Tidak | NEEDS VALIDATION |
| Kunci hilang | Sync gagal berulang | Tidak, tetapi data tak terbaca | FAIL (UX/log) |
| Storage perangkat penuh | SQLite error; tidak ada pre-check | Berisiko partial UX | NEEDS VALIDATION |
| Background killed | Timer berhenti; resume memicu tick | Tidak | PASS |

---

## 3. Kesimpulan

Jalur transaksi tahan terhadap kegagalan jaringan dan force close. Kelemahan error handling terkonsentrasi pada:
1. pemulihan korupsi yang dapat membuang WAL;
2. kegagalan sinkronisasi/kripto yang tidak dapat ditindaklanjuti pengguna;
3. tidak ada dead-letter untuk envelope bermasalah;
4. printer tanpa antrean/status;
5. konkurensi DB yang tidak dikonfigurasi.
