# 10 — AUDIT PENANGANAN ERROR

**Cakupan:** kegagalan startup, transaksi, database, sinkronisasi, backup/restore, pesan pengguna, rollback, dan pemulihan.
**Sifat:** analisis statis. Tidak ada test, build, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Prinsip yang Diuji

1. Setiap operasi tulis harus atomik atau memiliki kompensasi.
2. Kegagalan harus terlihat, dapat dipahami, dan tidak menyesatkan.
3. Retry harus idempoten.
4. Error tidak boleh meninggalkan state setengah jadi.
5. Operasi global (restore, pindah toko) harus memblokir operasi lain.

---

## 2. Titik Kegagalan Utama

| Titik | Penanganan saat ini | Risiko |
|---|---|---|
| Startup | Tidak ada `try/catch` | Aplikasi tidak dirender (FLW-01) |
| Buka database | `StateError` untuk versi tidak didukung | Tidak ada layar pemulihan (FLW-03) |
| Simpan nota | `try/catch` mencampur simpan & struk | Pesan salah (FLW-02) |
| Simpan nota | `request_id` early return | Payload baru hilang (BIZ-01) |
| Retur pembelian | Refund kumulatif | Kas ganda (PUR-01) |
| PPN remote | `ConflictAlgorithm.ignore` | Kas hilang diam-diam (FIN-06) |
| Sync nota | Unique index kode | Nota gagal total (DB-07) |
| Sync opname | Movement sebelum keputusan | Ledger tidak konsisten (DB-09) |
| Pindah toko | Tanpa cek sync | Database ditutup di tengah transaksi (DB-08) |
| Restore | Tanpa stop scheduler | Restore/backup rusak (BAK-01) |
| Backup polos | Checkpoint saja | Salinan tidak konsisten (BAK-02) |
| Feature flag | Fallback true | Fitur OFF tetap berjalan (FEAT-02) |
| Viewer | Read-write | Tulisan tidak diinginkan (SEC-07) |

---

## 3. Startup dan Database

### 3.1 FLW-01 — Tidak ada error boundary

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');
  await AppDatabase.instance.init();
  await seedDummyDataIfEnabled();
  await AppState.instance.load();
  BackupScheduler.instance.start();
  SyncScheduler.instance.start();
  runApp(const PusatkuApp());
}
```

Tidak ada `try/catch`, `runZonedGuarded`, atau `ErrorWidget.builder`. Kegagalan apa pun menghentikan `main` sebelum `runApp`.

**Dampak.** Layar kosong/aplikasi tertutup; tidak ada instruksi pemulihan; risiko pengguna menghapus data.

### 3.2 FLW-03 — Tidak ada mode pemulihan

`_rejectIncompatibleVersion` dan `_prepareSchemaUpgrade` melempar `StateError`. Tidak ada layar yang menangkap dan menawarkan restore/ekspor.

**Dampak.** Pengguna terkunci; dukungan harus manual.

### 3.3 DB-03 — Toko baru gagal dibuka

Database toko baru dibuat polos; saat dibuka jalur SQLCipher, file dapat dianggap rusak. Error muncul sebagai kegagalan database, bukan pesan “toko tidak terenkripsi”.

---

## 4. Transaksi Penjualan

### 4.1 Atomisitas

`createTransaction` berjalan dalam satu transaksi database. Jika terjadi error sebelum commit, seluruh perubahan rollback. Ini baik.

### 4.2 Kegagalan setelah commit

- `enqueue` outbox berada di transaksi yang sama; aman.
- `recordDetail` dan struk berjalan setelah commit; kegagalan di sini tidak membatalkan nota (FLW-02).
- UI tidak membedakan “nota tersimpan” dan “struk gagal”.

### 4.3 BIZ-01 — Idempotensi tanpa verifikasi payload

```dart
final existing = await txn.query('service_records',
  columns: ['id'], where: 'request_id = ?', whereArgs: [requestId], limit: 1);
if (existing.isNotEmpty) {
  final id = existing.first['id'] as int;
  if (enqueue != null) await enqueue(txn, id);
  return id;
}
```

Payload baru dengan `request_id` lama mengembalikan dokumen lama tanpa perbandingan. UI menampilkan sukses; perubahan tidak tersimpan.

**Perbaikan.** Simpan hash payload bersama `request_id`; tolak jika hash berbeda.

### 4.4 Validasi yang hilang

- Harga jasa bebas tidak divalidasi service (SAL-03).
- Kredit tanpa jatuh tempo/limit (SAL-04).
- Stok tidak dicek atomik; lost update mungkin (lihat 04).

---

## 5. Retur dan Void

### 5.1 Retur penjualan

- Trigger qty mencegah retur melebihi qty.
- `request_id` mencegah duplikasi dokumen.
- Tidak ada void/reversal (RET-01); kesalahan permanen.
- Refund kas di-clamp; tetapi basis DPP/ditagih tidak konsisten (RET-02).

### 5.2 Retur pembelian

- Qty dibatasi trigger.
- Refund kumulatif ditulis berulang (PUR-01) — ini adalah **kegagalan logika yang tidak terlihat sebagai error**; pengguna melihat retur berhasil, tetapi kas salah.
- Metode CASH hardcoded (PUR-04).

### 5.3 Void

- VOID terminal; trigger mencegah perubahan.
- Cost state tidak dikembalikan (FIN-01).
- Retur aktif tidak dibatalkan otomatis.
- Aktor bergantung UI (SEC-05).

---

## 6. Sinkronisasi

### 6.1 DB-07 — Gagal total karena kode bentrok

`note_sync` membuat stok dengan `kode` payload. Jika kode sudah dipakai barang lokal lain, unique index menolak seluruh penerapan nota. Antrean sync mengulang dan gagal terus; tidak ada resolusi otomatis.

**Perbaikan.** Cari berdasarkan `sync_id`; jika kode bentrok, buat kode sementara unik dan catat konflik, jangan gagalkan seluruh nota.

### 6.2 DB-09 — Movement sebelum keputusan

Movement ditulis sebelum `applyQuantity` diperiksa. Konflik opname tetap meninggalkan movement dengan `stok_sesudah` yang tidak diterapkan.

**Perbaikan.** Pindahkan insert movement setelah keputusan; untuk konflik, simpan di `sync_conflicts` atau tandai movement ditolak.

### 6.3 FIN-06 — Insert kas dengan `ignore`

```dart
await txn.insert('cash_ledger', {...}, conflictAlgorithm: ConflictAlgorithm.ignore);
```

Baris yang bentrok dibuang diam-diam; kas tidak tercatat, tetapi pembayaran PPN tercatat. Tidak ada error ke pengguna.

**Perbaikan.** Gunakan insert yang gagal keras atau catat konflik; hasilkan `cash_sync_id` lokal bila tidak ada.

### 6.4 DB-08 — Pindah toko saat sync

Tidak ada pemeriksaan `isSyncing`; database ditutup di tengah operasi. Error sync dapat berupa exception database yang tidak informatif; sebagian transaksi mungkin sudah ditulis.

### 6.5 Konflik

`sync_conflicts` mencatat konflik, tetapi tidak semua konflik memiliki jalur penyelesaian di UI. Konflik `open` dapat memblokir antrean.

---

## 7. Backup dan Restore

### 7.1 BAK-01 — Restore tanpa stop

Tidak ada `SyncScheduler.stop()`, `BackupScheduler.stop()`, atau penantian `isSyncing`. Restore menutup database saat proses lain berjalan.

**Dampak.** Outbox/inbox tidak konsisten; restore tampak berhasil tetapi sync rusak.

### 7.2 BAK-02 — Backup polos tidak atomik

`wal_checkpoint(FULL)` tidak menghentikan penulis. Salinan dapat kehilangan transaksi terakhir.

### 7.3 DB-02/04/05/06 — Restore menerima database tidak valid

- versi dipaksa;
- tanpa metadata versi;
- daftar tabel tidak lengkap;
- tanpa `foreign_key_check`.

**Dampak.** Restore “berhasil” tetapi aplikasi error atau data inti hilang.

### 7.4 Restore terputus

Tidak ada file sementara + rename atomik, tidak ada rollback ke file lama, tidak ada penanda “restore belum selesai”. Crash di tengah restore dapat meninggalkan database tidak lengkap.

---

## 8. Feature Flag dan UI

### 8.1 FEAT-02 — Fallback true

Sebelum `load()` atau saat toko berubah, flag mengembalikan default true. Fitur OFF dapat dipakai sesaat.

### 8.2 FEAT-01 — Service tidak menegakkan

Hanya pembelian memanggil `requireEnabled`. Estimasi/order/followup/unit/whatsapp dapat menulis meski OFF.

### 8.3 Error UI

- Pesan “Gagal menyimpan: $error” menampilkan detail internal; tidak selalu ramah pengguna.
- Tidak ada kode error/kategori untuk membedakan validasi, konflik, dan kegagalan sistem.
- Snackbar hilang setelah beberapa detik; tidak ada log yang dapat dilihat pengguna.

---

## 9. Matriks Operasi → Kegagalan → State

| Operasi | Kegagalan | Yang dilihat pengguna | State database |
|---|---|---|---|
| Simpan nota | Error sebelum commit | “Gagal menyimpan” | Rollback, aman |
| Simpan nota | Struk gagal | “Gagal menyimpan” | Nota tersimpan (menyesatkan) |
| Simpan ulang `request_id` lama | Payload berbeda | Sukses | Nota lama (perubahan hilang) |
| Retur beli kedua | Logika kumulatif | Sukses | Kas ganda |
| PPN remote | `ignore` | Sukses | Kas hilang |
| Koreksi stok kedua | Unique index | Error | Rollback |
| Sync nota | Kode bentrok | Sync gagal berulang | Nota tidak masuk |
| Opname kalah HLC | Movement tetap ditulis | Sukses | Ledger tidak konsisten |
| Pindah toko saat sync | DB ditutup | Error sync | Transaksi terputus |
| Restore | Scheduler aktif | Restore sukses | Outbox rusak |
| Restore versi lama | Versi dipaksa | Error runtime | Skema tidak cocok |
| Startup | DB rusak | Layar kosong | Tidak dapat diakses |

---

## 10. Rekomendasi

### 10.1 Error boundary dan pemulihan

1. Bungkus `main` dengan `runZonedGuarded` dan tampilkan layar error.
2. Layar pemulihan: versi DB, restore, ekspor diagnostik, mode aman.
3. Jangan pernah menghapus database otomatis.
4. Simpan log error lokal yang dapat diekspor.

### 10.2 Transaksi dan idempotensi

1. Hash payload bersama `request_id`.
2. Pisahkan `try` simpan dan struk.
3. Gunakan insert yang gagal keras untuk kas; catat konflik.
4. Validasi semua aturan bisnis di service, bukan UI.

### 10.3 Operasi global

1. State machine `restoring`/`switching_store` yang memblokir aksi.
2. Hentikan scheduler dan tunggu sync selesai.
3. File sementara + rename atomik + rollback.
4. Validasi lengkap sebelum mengganti database.

### 10.4 Sync

1. Resolusi konflik kode stok tanpa menggagalkan seluruh nota.
2. Movement setelah keputusan opname.
3. Tampilkan konflik yang belum selesai dan izinkan retry/resolusi.

### 10.5 Pesan

1. Kategorikan error: validasi, konflik, izin, database, jaringan.
2. Pesan yang dapat ditindaklanjuti, bukan dump exception.
3. Setelah simpan sukses, jangan pernah menampilkan “gagal simpan” untuk kegagalan struk.

---

## 11. Pertanyaan Aturan Bisnis

1. Apakah pengguna boleh mengulang transaksi yang gagal dengan `request_id` yang sama?
2. Apakah konflik sync harus memblokir transaksi baru atau hanya antrean?
3. Apakah restore boleh dilanjutkan otomatis setelah crash?
4. Apakah error database harus dikirim ke dukungan secara otomatis?

---

## 12. Ringkasan

- Penanganan error transaksi database cukup baik (rollback), tetapi **error pasca-commit, error logika, dan error operasi global** tidak terlihat.
- Banyak kegagalan bersifat “sukses di UI, salah di database”: PUR-01, FIN-06, BIZ-01, DB-09.
- Startup tidak memiliki jalan pemulihan; restore tidak memiliki rollback.
- Perbaikan harus mencakup error boundary, idempotensi payload, validasi service, dan state machine operasi global.
