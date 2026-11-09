# 09 — AUDIT KEAMANAN

**Cakupan:** autentikasi sesi/PIN, otorisasi service, viewer, ekspor data, sinkronisasi, dan jalur eskalasi hak.
**Sifat:** analisis statis. Tidak ada pengujian penetrasi, runtime, atau perubahan source.
**Registri lengkap:** lihat `01_BUSINESS_LOGIC_DEFECTS.md`.

---

## 1. Model Kepercayaan

### 1.1 Aktor

| Aktor | Sumber | Izin |
|---|---|---|
| Owner | `owner_identity` + sesi/PIN | Semua |
| Karyawan | `employee_accounts` + `employee_store_access` | `role_base` + `extra_permissions` |
| Viewer | Profil ringkasan owner | Seharusnya hanya baca |
| Perangkat | `devices` + token | Sync sesuai allow-list |

### 1.2 Lapisan pemeriksaan

| Lapisan | Implementasi | Konsistensi |
|---|---|---|
| UI | `_operator`, `_featureAllows`, cek manual | Tidak lengkap; fallback owner |
| Service | `Permissions.require`, `Operator.can` | Tidak semua service memeriksa |
| Database | Trigger append-only, FK, CHECK | Baik untuk integritas, bukan otorisasi |
| Sync | `sync_conflict_rules.dart` allow-list | `supplier` tidak ada di allow-list karyawan |

**Prinsip yang gagal:** otorisasi tidak boleh bergantung pada UI. Saat ini beberapa service menerima `actor` sebagai **string bebas** atau tidak menerima aktor sama sekali.

---

## 2. Autentikasi dan Sesi

### 2.1 PIN

`PinService`:

- `verify` mengembalikan `true` untuk `ok` **dan** `weakLegacyPin`;
- PIN legacy tanpa iterasi diverifikasi dengan hash lama;
- PIN < 6 digit dapat diterima sebagai `weakLegacyPin`;
- tidak ada paksaan ganti PIN setelah verifikasi lemah.

**SEC-06 (MEDIUM).** PIN 4 digit pada perangkat lama terus dipakai. Risiko tebak tinggi.

**Perbaikan.** Tolak PIN < 6 digit di semua jalur; setelah verifikasi legacy/lemah, paksa layar ganti PIN sebelum akses.

### 2.2 Sesi hilang → owner sintetis

**SEC-09 (HIGH).** `EntryGate` membuat profil owner jika `profile == null && pinConfigured`. PIN karyawan berada di guard yang sama, sehingga PIN karyawan dapat membuka profil owner.

**Perbaikan.** Jangan sintesis owner dari keberadaan PIN; simpan mode/peran di storage yang sama dengan PIN; verifikasi ulang terhadap `owner_identity` dan minta kredensial owner.

### 2.3 Sign-out → onboarding takeover

**SEC-01 (CRITICAL).** Sign-out menghapus sesi/PIN tetapi mempertahankan database dan `owner_identity`. Onboarding berikutnya memanggil `ensureOwner()` yang mengembalikan owner lama, lalu membuat PIN baru.

**Skenario.** Siapa pun yang memegang perangkat dapat menekan “Keluar” → “Mulai gratis” → PIN baru → owner penuh (payroll, backup, ekspor, pengaturan).

**Perbaikan.** Sign-out meminta PIN owner atau mengunci/menghapus database; onboarding mendeteksi `owner_identity` dan meminta kredensial owner.

---

## 3. Otorisasi Service

### 3.1 Matriks

| Service/Operasi | Aktor | Izin | Catatan |
|---|---|---|---|
| `createTransaction` | `Operator` | `buat_nota` (via UI?) | Perlu verifikasi service; harga jasa bebas tidak diperiksa |
| `voidRecord` | `Operator` | owner/izin void | Alasan wajib |
| `createReturn` (jual) | `Operator` | izin retur? | Tidak ada pemeriksaan eksplisit di service |
| `createPurchase` | `Operator` | `requireEnabled` + izin | Lebih baik dari yang lain |
| `voidPurchase` | `Operator` | owner? | Perlu verifikasi |
| `saveSupplier` | **tidak ada** | **tidak ada** | SEC-03 |
| `createAccount`/reset | **string actor default 'owner'** | **tidak ada** | SEC-02 |
| `paySalary` | **tidak ada** | **tidak ada** | SEC-04/FIN-05 |
| `saveStockItem` | `Operator`? | izin stok? | Perlu verifikasi |
| `applyOpname` | `Operator`? | izin opname? | Perlu verifikasi |
| `setEnabled` fitur | `Operator` | owner-only | Baik |
| Ekspor ringkasan | UI | **tidak ada** | SEC-08 |
| Pajak payment | `Operator`? | izin? | Perlu verifikasi |

**Catatan:** sel “perlu verifikasi” berarti pemanggilan service tidak menunjukkan pemeriksaan pada potongan source yang dibaca; ini bukan klaim bahwa tidak ada pemeriksaan di tempat lain. Temuan resmi hanya untuk yang terbukti.

### 3.2 SEC-02 — Account service default owner

```dart
Future<Map<String, Object?>> createAccount({
  ...
  String actor = 'owner',
}) async {
  if (!await LicenseService.instance.isPremium()) { ... }
  ...
  await recordAudit(actor: actor, ...);
}
```

Tidak ada `Permissions.require`; `actor` adalah string yang dapat diisi pemanggil. `updateAccount`, `resetPassword`, `resetPin` memiliki pola serupa.

**Dampak.** Pembuatan akun dan reset kredensial tidak terlindungi di lapisan bisnis; `permission_audits.actor` dapat dipalsukan.

**Perbaikan.** Wajibkan `Operator actor`, verifikasi `actor.isOwner` (atau izin eksplisit), turunkan label aktor dari objek.

### 3.3 SEC-03 — Supplier tanpa otorisasi

Tidak ada `Operator`, `Permissions`, `actor`, atau `requireEnabled` di `supplier_service.dart`. Siapa pun yang dapat memanggil service dapat menambah/mengubah/menghapus supplier dan relasi barang.

Selain itu, allow-list sync karyawan tidak memuat `supplier` (`sync_conflict_rules.dart:169-186`), sehingga perubahan lokal karyawan tidak dikirim ke perangkat lain; data supplier master tetap berbeda.

**Perbaikan.** Tambahkan aktor + izin `ubah_supplier`; masukkan `supplier` ke allow-list dengan aturan owner-only atau izin eksplisit.

### 3.4 SEC-04/FIN-05 — Payroll tanpa aktor

`paySalary` tidak menerima aktor/izin, tidak mencatat aktor pembayar, dan mengisi `cash_ledger.operator` dengan nama karyawan yang dibayar.

**Dampak.** Gaji dan pemotongan hutang dapat dijalankan tanpa persetujuan; audit kas tidak menunjukkan penyetuju.

### 3.5 SEC-05 — Fallback owner di UI

**Detail di 08.** UI menganggap operator null sebagai owner. Ini adalah otorisasi berbasis keberhasilan pemuatan state.

### 3.6 SEC-07 — Viewer read-write

`openViewerDatabase` memanggil `_open()` tanpa `readOnly: true`. `Permissions.can` tidak menolak viewer; hanya `Operator.can` yang menolak. Jalur yang memakai `Permissions.require` dapat mengizinkan viewer jika permission-nya ada.

**Dampak.** Mode “hanya baca” tidak dijamin di lapisan service; database ringkasan dapat berubah.

**Perbaikan.** Buka viewer `readOnly: true`; satukan pemeriksaan di `Permissions.can` (tolak viewer eksplisit).

---

## 4. Data Sensitif dan Ekspor

### 4.1 SEC-08 — Ekspor ringkasan owner tanpa izin

Tombol ekspor di `settings_screen.dart:876-894` tidak memeriksa `AppState.can(...)` atau peran owner. `OwnerSummaryService.export` menandatangani payload berisi `license_token`, daftar perangkat, dan toko dengan kunci privat owner di perangkat.

**Dampak.** Karyawan dengan akses menu Pengaturan dapat menyimpan token lisensi dan daftar perangkat.

**Perbaikan.** Batasi ke owner (`actor.isOwner`), minta PIN owner, dan jangan sertakan token lisensi penuh.

### 4.2 Database dan kunci

- Database Android terenkripsi SQLCipher; kunci dikelola aplikasi.
- Database toko baru dapat dibuat polos (DB-03) → data toko kedua tidak terenkripsi.
- Ekspor polos (BAK-02) menghasilkan file tanpa enkripsi.
- `license.token` dan `owner_identity.public_key` disimpan di database; token lisensi juga dapat diekspor (SEC-08).

### 4.3 Log dan audit

- `business_audits` menyimpan aktor, aksi, before/after.
- `permission_audits` menyimpan aktor, tetapi dapat dipalsukan (SEC-02).
- `cash_ledger.operator` dapat berisi nama karyawan yang dibayar, bukan pelaku (FIN-05).
- Tidak ada redaksi data sensitif pada pesan error yang ditampilkan.

---

## 5. Sinkronisasi dan Batas Kepercayaan

### 5.1 Allow-list entitas

`sync_conflict_rules.dart`:

- `ownerOnlyEntities` memuat `store_feature` dan entitas sensitif lain (baris 146-148).
- `employeeEntities` memuat entitas yang boleh dikirim karyawan (baris 169-186), **tidak** termasuk `supplier`.
- Pemeriksaan pengirim (baris 211+) menolak entitas di luar allow-list.

**Konsekuensi:**
- Perubahan supplier oleh karyawan tersimpan lokal tetapi tidak tersinkron (SEC-03).
- Feature flag dari karyawan ditolak; baik untuk keamanan, tetapi UI tetap dapat menampilkan tombol jika tidak diperiksa.

### 5.2 Payload remote

- `applySnapshotPayload` memverifikasi checksum dan signature.
- `applyPaymentRemote`/`applyRemote` pada PPN menerima `cash_sync_id` dari payload tanpa validasi kepemilikan (FIN-06).
- `note_sync` membuat stok dari payload dengan `kode` yang dapat bentrok (DB-07).
- Tidak ada verifikasi bahwa `store_id` pada payload cocok dengan toko aktif untuk semua entitas.

### 5.3 Konflik

`sync_conflicts` mencatat konflik, tetapi tidak ada UI penyelesaian yang lengkap? Ada layar konflik, tetapi resolusi otomatis terbatas. Konflik yang tidak diselesaikan dapat memblokir antrean.

---

## 6. Skenario Ancaman

### 6.1 Pemegang perangkat mengambil alih owner

1. Karyawan atau orang lain menekan “Keluar”.
2. Onboarding “Mulai gratis”.
3. `ensureOwner` mengembalikan owner lama.
4. PIN baru dibuat; akses owner penuh.
5. Ekspor backup/lisensi, ubah harga, bayar gaji, hapus data.

**Temuan:** SEC-01 (CRITICAL), diperkuat SEC-05/09.

### 6.2 Sesi rusak menjadi owner

1. Secure storage dibersihkan atau upgrade gagal.
2. `EntryGate` membuat profil owner karena PIN terkonfigurasi.
3. PIN karyawan diterima → owner.

**Temuan:** SEC-09.

### 6.3 Karyawan mengubah supplier

1. Karyawan membuka layar supplier.
2. Service tidak memeriksa izin; perubahan tersimpan lokal.
3. Perubahan tidak tersinkron; data master berbeda antar perangkat.

**Temuan:** SEC-03.

### 6.4 Viewer menulis

1. Profil viewer membuka database ringkasan.
2. Database dibuka read-write.
3. Service yang memakai `Permissions.require` (bukan `Operator.can`) mengizinkan aksi.
4. Ringkasan owner berubah.

**Temuan:** SEC-07.

### 6.5 Ekspor lisensi oleh karyawan

1. Karyawan membuka Pengaturan.
2. Menekan “Ekspor ringkasan owner”.
3. Payload berisi token lisensi dan daftar perangkat tersimpan.

**Temuan:** SEC-08.

---

## 7. Temuan Domain

| ID | Nama | Risiko | Status | Bukti utama |
|---|---|---|---|---|
| SEC-01 | Sign-out lalu onboarding takeover | CRITICAL | CONFIRMED | `entry_gate.dart:74-96`; `onboarding.dart:96-107,323-358`; `license_service.dart:99-120` |
| SEC-02 | Account service default owner | HIGH | CONFIRMED | `account_service.dart:118-190,326-380,389-430` |
| SEC-03 | Supplier service tanpa otorisasi | HIGH | CONFIRMED | `supplier_service.dart:51-159`; `sync_conflict_rules.dart:169-186` |
| SEC-04 | Payroll tanpa aktor/izin | HIGH | CONFIRMED | `employee_service.dart:283-370` |
| SEC-05 | Fallback `Operator.owner` | HIGH | CONFIRMED | `home_shell.dart:273-289` |
| SEC-06 | PIN legacy lemah | MEDIUM | CONFIRMED | `pin_service.dart:22-30,52-96` |
| SEC-07 | Viewer read-write; cek tidak konsisten | MEDIUM | CONFIRMED | `app_database.dart:98-114`; `permissions.dart:20-30`; `operator.dart:32` |
| SEC-08 | Ekspor ringkasan owner tanpa izin | MEDIUM | CONFIRMED | `settings_screen.dart:876-894`; `owner_summary_service.dart:20-72` |
| SEC-09 | Sesi hilang disintesis owner | HIGH | CONFIRMED | `entry_gate.dart:31-44`; `pin_service.dart:32-40` |

---

## 8. Rekomendasi Keamanan

### 8.1 Autentikasi

1. Satu sumber identitas: `owner_identity` + `employee_accounts`; sesi tidak boleh disintesis.
2. Sign-out aman: minta PIN owner atau kunci database.
3. PIN minimum 6 digit; migrasi paksa PIN legacy.
4. Rate limit/login guard untuk PIN dan password (sudah ada `login_guards`, pastikan dipakai konsisten).
5. Sesi memiliki `role`, `owner_id`, `employee_sync_id`, dan `store_id` yang ditandatangani/diverifikasi.

### 8.2 Otorisasi

1. Setiap service mutasi menerima `Operator actor` (bukan string).
2. `Permissions.require(actor, permission)` di awal setiap operasi.
3. `Permissions.can` menolak viewer secara eksplisit.
4. Service owner-only: akun, payroll, supplier, backup/restore, ekspor, feature toggle.
5. Audit aktor diturunkan dari objek, bukan parameter bebas.

### 8.3 Viewer

1. Buka database `readOnly: true`.
2. Tolak semua operasi tulis di service.
3. Pisahkan file/database viewer dari database operasional.

### 8.4 Ekspor dan data sensitif

1. Ekspor ringkasan owner hanya owner + PIN.
2. Jangan sertakan token lisensi penuh; gunakan hash/ID.
3. Enkripsi semua ekspor.
4. Redaksi data sensitif pada log dan pesan error.

### 8.5 Sync

1. Validasi `store_id` dan kepemilikan payload.
2. Jangan menerima `cash_sync_id` dari remote tanpa verifikasi.
3. Tambahkan `supplier` ke allow-list dengan aturan yang jelas.
4. Tampilkan dan selesaikan konflik; jangan biarkan antrean macet.

---

## 9. Pertanyaan Aturan Bisnis

1. Siapa yang boleh menambah/mengubah supplier?
2. Siapa yang boleh membayar gaji dan melihat slip?
3. Apakah viewer boleh melihat data semua toko atau hanya ringkasan?
4. Apakah sign-out harus menghapus database atau mengunci perangkat?
5. Apakah owner boleh memiliki lebih dari satu perangkat tanpa verifikasi ulang?

---

## 10. Ringkasan

- Keamanan aplikasi bergantung pada **state sesi yang dapat hilang** dan **service yang tidak konsisten memeriksa aktor**.
- Tiga jalur eskalasi (SEC-01/05/09) cukup untuk mengambil alih pembukuan.
- Supplier, payroll, akun, dan ekspor adalah operasi sensitif tanpa kontrol service yang memadai.
- Perbaikan harus dimulai dari identitas tunggal dan otorisasi di service; UI bukan batas keamanan.
