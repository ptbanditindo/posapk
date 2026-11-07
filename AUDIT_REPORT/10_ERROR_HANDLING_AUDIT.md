# 10 — Audit Penanganan Error, Retry Safety, dan Kegagalan Parsial

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada skenario kegagalan yang direproduksi, aplikasi dibunuh, database dikorupsi, atau retry dijalankan. Seluruh kesimpulan berasal dari urutan transaksi, penanganan `catch`, dan struktur data retry.

**Berkas utama:** `pusatkupos/lib/data/app_database.dart`, `sale_return_service.dart`, `employee_service.dart`, `backup_service.dart`, `backup_platform_io.dart`; `pusatkupos/lib/sync/sync_service.dart`, `sync_conflict_rules.dart`, `note_sync.dart`, `snapshot_sync.dart`, `sync_scheduler.dart`; `pusatkupos/lib/ui/screens/pos_screen.dart`, `history_screen.dart`.

---

## 1. Pola yang sudah baik

| Pola | Implementasi | Dampak |
|---|---|---|
| Transaksi multi-tabel | Nota, retur, void, pelunasan, gaji, stok ditulis dalam `db.transaction` | Error membatalkan seluruh langkah; tidak ada data separuh |
| Outbox dalam transaksi bisnis | `enqueue` dipanggil di dalam transaksi yang sama | Perubahan dan amplop sinkronisasi tidak terpisah |
| Idempotensi nota | `service_records.request_id` UNIQUE; duplikat mengembalikan ID lama | Tap ulang/retry tidak membuat nota ganda |
| Guard tombol simpan | `_saving` menonaktifkan tombol; `_requestId` stabil sampai sukses | Mengurangi submit ganda lokal |
| Idempotensi amplop | `applied_deltas`, `(store, sender, seq)`, envelope ID | Amplop duplikat tidak diterapkan ulang |
| Retry dengan backoff | Outbox/inbox: 1, 2, 4, ... 240 menit; maksimum 8 percobaan untuk inbox | Tidak ada loop tanpa jeda |
| Konflik terlihat | `sync_conflicts` menyimpan entity, error, envelope, status | Pengguna dapat meninjau dan memilih retry/abaikan |
| Snapshot atomik | Impor seluruh tabel bisnis dalam satu transaksi | Snapshot gagal tidak meninggalkan data separuh |
| Validasi restore | Checksum, header SQLite, tabel wajib, `PRAGMA integrity_check`, salinan pengaman | Restore rusak ditolak/dikembalikan dalam proses yang sama |
| Error yang dapat dibaca | Pesan Indonesia untuk PIN, stok, harga, passphrase, sinkronisasi | Operator memahami tindakan berikutnya |

**Penilaian:** ini bukan basis kode yang mengabaikan kegagalan. Jalur lokal utama (nota, retur, void, stok) sudah transaction-safe, dan sinkronisasi memiliki model retry/konflik yang eksplisit.

---

## 2. Matriks skenario kegagalan

| Skenario | Perilaku kode | Penilaian |
|---|---|---|
| Aplikasi ditutup saat nota disimpan | Transaksi SQLite belum commit → rollback | Aman |
| Simpan nota gagal di tengah (stok/pembayaran) | Seluruh transaksi dibatalkan; UI menampilkan error; `_requestId` dipertahankan | Aman; retry memakai request ID sama |
| Tap "Simpan" berulang | `_saving` menonaktifkan tombol; request ID sama | Aman untuk nota |
| Nota berhasil tetapi UI gagal memuat detail | Data sudah commit; UI menampilkan "Gagal menyimpan"; retry mengembalikan ID lama | Tidak menggandakan data, tetapi pesan menyesatkan |
| Pelunasan dikonfirmasi dua kali | Setiap percobaan memakai `requestId` baru berbasis waktu | Dapat menjadi dua pembayaran (BL-13) |
| Dua perangkat melunasi nota yang sama | Pemeriksaan sisa hanya lokal; penerima menerapkan pembayaran apa adanya | Sisa dapat negatif/melebihi tagihan (BL-14) |
| Retur dikirim dua kali | Tidak ada kunci idempoten retur | Retur/stok/refund ganda (BL-13) |
| Dua perangkat meretur nota yang sama | Penerima tidak memeriksa total retur sebelum menambah stok | Retur berlebih dan stok berlebih (BL-02) |
| Gaji siklus sama dibayar di dua perangkat | UNIQUE lokal; penerima mencocokkan employee+cycle dan **update** baris | Dua kas keluar, satu catatan (BL-03) |
| Kode barang sama dibuat di dua perangkat | UNIQUE gagal; envelope gagal; cursor tidak maju | Seluruh antrean setelahnya tertahan (BL-41) |
| Opname di dua perangkat | Delta dikirim, bukan nilai absolut | Stok menyimpang (BL-01) |
| Database tidak dapat dibuka | `openDatabase` melempar; UI menampilkan error | Tidak ada penulisan setengah jadi |
| Downgrade skema | `onDowngrade` menolak | Aman dari skema tidak lengkap |
| Migrasi gagal | Migrasi aditif; error membatalkan open | Tidak ada DROP; tidak ada backup otomatis pra-migrasi |
| Backup otomatis gagal diunggah | Backup lokal tetap tersimpan; status pending dan error disimpan | Baik |
| Backup toko nonaktif non-SQLCipher | Berkas utama dibaca tanpa checkpoint | Transaksi terakhir di WAL hilang (BL-32) |
| Restore database rusak | Validasi + rollback dalam proses | Baik |
| Proses berhenti saat restore | Database lama sudah dihapus sebelum rename | Database kosong; `.bak` tidak dipulihkan otomatis (BL-42) |
| Restore multi-toko berhenti di tengah | Sebagian berkas baru, sebagian lama; registry belum diperbarui | Campuran data (BL-42) |
| Kuota follow-up dipakai lalu simpan gagal | Kuota dikonsumsi sebelum transaksi lokal | Kuota hilang (BL-31) |
| Snapshot diterapkan saat ada outbox/inbox | Ditolak dengan pesan jelas | Baik |
| Koreksi tiba sebelum nota | `applyRemote` mengembalikan void; envelope dianggap selesai | Koreksi hilang (BL-30) |

---

## 3. Analisis per jalur

### 3.1 Nota penjualan

- `createTransaction` membungkus validasi harga, stok, nomor dokumen, pelanggan/unit, mekanik, baris, pembayaran, movement, audit, dan komisi dalam satu transaksi (`app_database.dart:1298-1746`).
- Pemeriksaan `request_id` dilakukan di awal transaksi; duplikat mengembalikan ID lama dan tetap memanggil `enqueue` (`1305-1313`).
- `enqueueNote`/`enqueueStockMovement` dipanggil di dalam transaksi, sehingga kegagalan menyimpan outbox membatalkan nota.
- UI `_saving` dan `_requestId` memberi perlindungan ganda terhadap tap cepat (`pos_screen.dart:479-515`).

**Kesimpulan:** jalur nota adalah bagian paling retry-safe. Satu-satunya kelemahan adalah pesan error setelah commit bila pemuatan detail gagal; data tidak hilang.

### 3.2 Retur

- `createReturn` memvalidasi nota, sisa retur, qty, refund, dan menulis retur/item/stok/movement/refund/rekalkulasi/audit dalam satu transaksi (`sale_return_service.dart:62-257`).
- Tidak ada `request_id`/idempotency key retur. UI tidak memiliki penjaga submit berbasis request ID.
- Penerima `_upsertReturn` menambah stok **sebelum** dedupe movement dan tidak memeriksa apakah nota sudah void atau total retur melebihi qty (`note_sync.dart:922-1039`).

**Kesimpulan:** aman terhadap kegagalan lokal di tengah transaksi, tetapi tidak aman terhadap pengiriman ganda/retry jaringan dan retur lintas perangkat. Ini adalah **BL-13** dan **BL-02**.

### 3.3 Pelunasan

- `settleReceivable` memakai transaksi dan memeriksa `request_id` bila diberikan (`app_database.dart:2767-2856`).
- UI membuat `requestId` baru setiap dialog dikonfirmasi (`history_screen.dart:298-304`), sehingga retry pengguna bukan duplikat yang terdeteksi.
- Sisa tagihan diperiksa dari baris lokal; tidak ada rekonsiliasi dengan pembayaran yang belum diterapkan dari perangkat lain.

**Kesimpulan:** **BL-13** (submit ganda) dan **BL-14** (pelunasan lintas perangkat melebihi sisa).

### 3.4 Gaji dan komisi

- `paySalary` memakai transaksi, memeriksa pembayaran siklus yang sama secara lokal, membayar hutang, lalu menyisipkan `salary_payments` (`employee_service.dart:299-341`).
- Penerima sync mencocokkan `employee_sync_id + cycle_start`; bila ada, ia **memperbarui** baris yang sudah ada (`sync_service.dart:3337-3386`). Tidak ada konflik atau penolakan pembayaran kedua.
- `recalculateRecordCommissions` menghitung ulang memakai tarif **saat ini** dan menimpa nominal (`app_database.dart:1828-1952`).

**Kesimpulan:** **BL-03** (dua kas keluar, satu catatan) dan **BL-04** (komisi berubah setelah tarif berubah).

### 3.5 Sinkronisasi

- Outbox yang gagal mendapat `retry_count`, `error`, dan `next_retry_at` dengan backoff eksponensial (`sync_service.dart:2041-2087`); scheduler mencoba lagi setiap 10–20 menit dan saat aplikasi resume/tutup (`sync_scheduler.dart:53-118`).
- Inbox yang gagal disimpan lengkap (`envelope_json`), diberi status `pending`/`failed`, dan dicatat di `sync_conflicts` (`sync_service.dart:2390-2520`).
- Cursor **selalu** berhenti di amplop pertama yang gagal, bahkan setelah 8 percobaan (`1990-2015`). Ini melindungi urutan, tetapi membuat satu amplop bermasalah menahan seluruh antrean.
- Kegagalan permanen pada entity yang tidak berhak (mis. `peran_tidak_berhak`) tidak menahan cursor karena termasuk `finalReasons`; kegagalan teknis (mis. UNIQUE kode barang) menahan.

**Kesimpulan:** model retry/konflik kuat, tetapi **blocking cursor** memperbesar dampak kegagalan kecil menjadi penghentian sinkronisasi menyeluruh (BL-41). Tidak ada batas waktu atau jalur "lewati amplop" otomatis; pengguna harus menindaklanjuti konflik.

### 3.6 Backup dan restore

- Backup otomatis menangani kegagalan unggah tanpa menghapus backup lokal; status dan error dicatat.
- Restore memvalidasi payload, membuat salinan pengaman, dan mengembalikannya bila `integrity_check` gagal (`backup_service.dart:704-901`).
- Penggantian berkas **tidak atomik** dan tidak ada pemulihan startup (BL-42).
- Restore multi-toko membatasi ukuran per toko, bukan total (BL-20).

**Kesimpulan:** penanganan error di dalam proses baik; yang tidak tertangani adalah penghentian proses di jendela kritis dan kegagalan disk.

---

## 4. Error yang tidak terlihat pengguna

| Kondisi | Perilaku | Dampak |
|---|---|---|
| Koreksi tiba sebelum nota | `applyRemote` mengembalikan void; envelope selesai | Koreksi hilang tanpa pesan (BL-30) |
| Amplop dari perangkat nonaktif | Tetap diproses; status aktif tidak diperiksa | Perubahan tidak sah diterima (BL-06) |
| Retur pada nota void diterima | `_upsertReturn` tidak memeriksa void | Stok/refund bertambah (BL-02) |
| Gaji kedua lintas perangkat | Baris lama ditimpa, bukan ditolak | Kas keluar ganda (BL-03) |
| Kuota follow-up gagal simpan | Kuota sudah terpotong | Kerugian kuota (BL-31) |
| Barang soft-deleted | Tetap muncul di daftar/dashboard | Keputusan stok salah (BL-26) |

---

## 5. Temuan area error handling

| ID | Nama | Risiko | Validitas |
|---|---|---|---|
| BL-42 | Restore tidak atomik; tidak ada pemulihan otomatis | TINGGI | SUSPECTED |
| BL-03 | Gaji siklus sama lintas perangkat saling menimpa | TINGGI | SUSPECTED |
| BL-02 | Retur/void lintas perangkat divergen | KRITIS | SUSPECTED |
| BL-01 | Opname absolut dikirim sebagai delta | KRITIS | SUSPECTED |
| BL-41 | Duplikat kode barang menahan cursor | SEDANG | SUSPECTED |
| BL-13 | Retur/pelunasan tanpa idempotensi submit ganda | SEDANG | SUSPECTED |
| BL-14 | Pelunasan lintas perangkat melebihi sisa | SEDANG | SUSPECTED |
| BL-15 | Amplop void tidak self-contained | SEDANG | SUSPECTED |
| BL-20 | Restore multi-toko tanpa batas total | SEDANG | CONFIRMED |
| BL-30 | Koreksi remote dibuang bila nota belum ada/void | RENDAH | SUSPECTED |
| BL-31 | Kuota follow-up dikonsumsi sebelum commit | RENDAH | SUSPECTED |
| BL-32 | Backup toko nonaktif tanpa checkpoint | RENDAH | SUSPECTED |
| BL-27 | `actor == null` dianggap owner | RENDAH | CONFIRMED |

Detail lengkap ada di [`01_BUSINESS_LOGIC_DEFECTS.md`](01_BUSINESS_LOGIC_DEFECTS.md).

---

## 6. Rekomendasi retry safety (ringkas)

1. **Idempotency key untuk retur dan pelunasan** dari UI, bukan dibuat ulang setiap percobaan.
2. **Jangan blokir seluruh cursor** untuk kegagalan yang tidak terkait; karantina amplop bermasalah dan lanjutkan amplop independen.
3. **Deteksi konflik bisnis sebelum menulis**: retur melebihi qty, pelunasan melebihi sisa, gaji siklus sama, kode barang duplikat.
4. **Terapkan operasi idempoten di penerima** (upsert berdasarkan natural key + validasi batas), bukan hanya berdasarkan `sync_id`.
5. **Restore atomik + pemulihan startup** dari `.bak-*`/`.restore.tmp`, dengan verifikasi sebelum menghapus salinan lama.
6. **Standarkan hasil operasi**: bedakan "gagal, tidak tersimpan" dan "tersimpan, gagal menampilkan"; jangan tampilkan pesan gagal setelah commit.
7. **Catat alasan penolakan yang terlihat pengguna** untuk koreksi yang belum dapat diterapkan (retryable vs final).

---

## 7. Batas audit

- Tidak ada injeksi kegagalan, pembunuhan proses, atau simulasi jaringan.
- Status SUSPECTED diberikan pada skenario yang bergantung pada waktu/konkurensi/penghentian proses.
- Tidak ada pengujian apakah SQLite benar-benar rollback pada perangkat tertentu; kesimpulan berasal dari penggunaan `db.transaction` dan dokumentasi semantik transaksi.
- Perilaku filesystem (`rename`, `fsync`, delete) berbeda antarsistem operasi dan tidak diuji.
- Tidak ada analisis performa retry atau ukuran antrean pada data produksi.

**Kesimpulan area:** penanganan error lokal (transaksi, rollback, guard tombol, idempotensi nota, retry backoff, konflik) merupakan kekuatan aplikasi. Kelemahan serius muncul saat operasi **melintasi perangkat atau proses**: retur/void, gaji, pelunasan, opname, kode barang, dan restore. Pola umumnya adalah **aturan bisnis tidak divalidasi ulang di penerima** dan **satu kegagalan dapat menahan atau menimpa data lain**.
