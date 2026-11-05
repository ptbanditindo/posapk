# Audit Menyeluruh PusatkuPOS + Struk yang Dapat Diedit

Tanggal audit: 5 November 2026
Pembaruan implementasi: 5 November 2026
Cakupan: `pusatkupos/` (Flutter + SQLite/SQLCipher) dan `relay/` (Dart Shelf + PostgreSQL)
Referensi fitur struk: `github.com/ptbanditindo/aplikasiposbengkel` (Python/FastAPI)

Status: seluruh temuan P0, P1, dan P2 sudah diperbaiki, editor struk v2 sudah
dibangun, dan sembilan fitur lanjutan sudah ditulis ke kode. Tidak ada
dependency baru yang dipasang. Rencana dan butir yang sudah selesai dihapus
dari dokumen ini; sisa pekerjaan ada di bagian 11.

---

## 0. Ringkasan Eksekutif

Audit menemukan tujuh kelas masalah utama. Semuanya sudah ditutup:

| Area | Temuan audit | Keadaan sekarang |
|---|---|---|
| Backup/restore | Backup Android tidak dapat dipulihkan, restore tidak atomik, hanya satu toko | Format 3 multi-toko, validasi semua payload, safety `.bak`, replace atomik, registry dibangun ulang |
| Relay/auth | Viewer dapat naik menjadi owner; entity dapat dipalsukan; bootstrap lintas toko | Scope token per peran, pengelolaan akun hanya owner, hash server-side, `hints_signature` wajib, cek keanggotaan toko |
| Sinkronisasi | Delta ditolak tetap di-ack; snapshot lama menimpa data baru; logout tidak mencabut token | Tri-state apply, snapshot non-regresi, seq floor, rahasia per toko, pencabutan token/kunci |
| Transaksi/harga | Modal jasa tidak dihitung; konversi estimasi memakai harga saat ini; diskon terpotong | Modal jasa masuk laporan, konversi memakai harga estimasi, alokasi diskon tanpa truncation |
| UI | Aksi gagal tanpa pesan, state basi, race | `try/catch/finally`, epoch load, `AppState.touch()`, validasi inline |
| Printer | Lebar dokumen salah, status cetak tidak jujur, codepage tidak dipilih | Dokumen dibangun ulang sesuai printer, status dibedakan, codepage + transliterasi |
| Struk | Hanya toggle dan empat teks | Template v2 lengkap, 58/80, logo, WhatsApp, JSON, diskon baris, jatuh tempo, banner pelunasan |

Sisa risiko utama bukan lagi bug kode, melainkan verifikasi perangkat: SQLCipher,
printer thermal, dan restore lintas perangkat belum diuji pada perangkat nyata
pada sesi terakhir.

---

## 1. Peta Kode

### 1.1 Struktur proyek

```text
posapk-main/
├── pusatkupos/                 aplikasi Flutter
│   ├── lib/
│   │   ├── app.dart, main.dart
│   │   ├── auth/               Operator, izin
│   │   ├── core/               uang, tanggal, kuantitas, ID, WA, file
│   │   ├── data/               database, layanan domain, backup, retur, struk
│   │   ├── sync/               protokol, kripto, klien relay, snapshot
│   │   ├── printer/            ESC/POS, raster logo, adapter BT/USB/network
│   │   ├── state/              AppState
│   │   └── ui/                 layar dan dialog
│   ├── android/                bridge printer Kotlin
│   ├── test/                   26 file test
│   └── web/                    wasm SQLite + service worker
└── relay/                      server sinkronisasi + lisensi
    ├── lib/server.dart         seluruh endpoint
    ├── lib/db.dart             PostgreSQL
    ├── lib/auth_rules.dart     aturan entity per peran
    ├── lib/license.dart        tanda tangan lisensi
    ├── lib/google.dart         login Google
    └── test/                   test aturan murni
```

### 1.2 Modul dan tanggung jawab

| Modul | Tanggung jawab | Risiko utama |
|---|---|---|
| `lib/data/app_database.dart` | Skema v2, transaksi, stok, laporan, void, piutang, nomor dokumen | Titik pusat logika bisnis |
| `lib/data/schema.dart` | DDL, indeks, tabel sinkron, tabel retur | Perubahan skema harus aditif |
| `lib/data/order_service.dart` | Estimasi, konversi, work order | Harga konversi |
| `lib/data/sale_return_service.dart` | Retur tingkat baris, refund, stok kembali | Sisa jumlah dan pembulatan |
| `lib/sync/sync_service.dart` | Outbox/inbox, enroll, feed, snapshot | Ack semantik, cursor |
| `lib/data/note_sync.dart` | Terapkan nota + retur dari perangkat lain | Renumber nota, pemetaan stok |
| `lib/data/followup_service.dart` | Follow-up, status, WA | Status arsip |
| `lib/data/backup_service.dart` | ZIP backup multi-toko, restore, Telegram | SQLCipher, atomisitas |
| `lib/data/store_registry.dart` | Daftar toko dan toko aktif | Konsistensi setelah restore |
| `lib/data/account_service.dart` | Akun karyawan, izin | Lisensi, actor null |
| `lib/data/employee_service.dart` | Payroll, komisi, utang | Siklus gaji |
| `lib/data/store_settings.dart` | Jenis transaksi, peran, preset | Filter store |
| `lib/data/receipt_template.dart` | Template struk v2, JSON, validasi, migrasi | Kompatibilitas data lama |
| `lib/data/receipt_service.dart` | Susun blok struk, label, pembayaran, VOID | Konten dan perataan |
| `lib/printer/receipt_builder.dart` | Baris bergaya, pembungkusan, nominal | Lebar kolom |
| `lib/printer/printer_service.dart` | Payload struk, logo raster, cetak | Lebar printer, status |
| `lib/printer/escpos_builder.dart` | Byte ESC/POS, codepage, transliterasi | Encoding |
| `lib/ui/screens/receipt_settings_screen.dart` | Editor 6 tab, pratinjau, JSON | Validasi input |
| `lib/ui/receipt_dialog.dart` | Pratinjau 58/80, WhatsApp, cetak | State dokumen |
| `relay/lib/server.dart` | Semua endpoint | Otorisasi |
| `relay/lib/auth_rules.dart` | Entity per peran | Hanya hint tanda tangan |

### 1.3 Alur inti

**Transaksi kasir**

```text
POS screen
  → AppDatabase.createTransaction()
    → validasi jenis/peran/diskon
    → verifikasi harga master (jasa & stok)
    → PriceRules.allocate()
    → INSERT service_records, jobs, parts, payments, stock_movements
    → UPDATE stok, work_order, estimate
    → enqueue() ke sync_outbox
```

**Sinkronisasi**

```text
enqueue → sync_outbox (seq per device)
  → POST /relay/envelopes/batch
  → relay simpan amplop terenkripsi + relay_seq
  → device lain GET /relay/feed?since=cursor
  → sync_service.applyEnvelope()
  → INSERT applied_deltas + update cursor
  → POST /relay/feed/ack
```

**Retur**

```text
Riwayat → dialog retur (sisa per baris)
  → SaleReturnService.createReturn()
    → INSERT sale_returns + sale_return_items
    → UPDATE stok part + INSERT stock_movements (MASUK)
    → permission_audits
    → enqueue nota (payload membawa returns)
  → laporan: omzet neto = bruto - retur
```

**Backup**

```text
checkpoint → ekspor tiap toko ke plaintext sementara
  → SHA-256 + AES-256-GCM per toko
  → ZIP (manifest.json + stores/<n>.db.enc)
  → simpan ke file / upload Telegram
restore → validasi semua checksum + header SQLite
  → safety .bak → replace atomik → registry → reopen
```

**Struk**

```text
ReceiptService.build(recordId, width)
  → baca template v2 dari app_settings
  → susun blok (header, meta, items, totals, payment, warranty, bank, footer)
  → ReceiptDocument(lines, width, logo, copies, codepage)
  → PrinterService.printReceipt()
    → ESC/POS: teks bergaya + logo GS v 0
    → TEXT/SYSTEM/BROWSER: teks polos
```

---

## 2. Metode dan Batas Audit

- Audit dilakukan dengan membaca kode sumber langsung dan menyusuri pemanggil.
- Tidak ada dependency baru yang dipasang selama audit maupun perbaikan.
- Sesi terakhir tidak memiliki SDK Flutter/Dart, sehingga verifikasi bersifat
  statis: keseimbangan delimiter, pencocokan simbol antar-lapis, dan
  penelusuran jalur data. Pengujian perilaku dilakukan pemilik lewat APK atau
  localhost.
- Hasil test tahap sebelumnya dicatat di `LAPORAN_PERBAIKAN_SYNC.md` dan tidak
  diulang di sini.

Definisi severity:

| Kode | Arti |
|---|---|
| P0 | Kehilangan data, bypass keamanan, atau fitur inti tidak berfungsi |
| P1 | Salah hitung/salah perilaku yang terlihat pengguna, atau kegagalan yang sulit dipulihkan |
| P2 | Bug logika terbatas, edge case, atau risiko operasional |
| P3 | Kebersihan kode, konsistensi, atau perbaikan kecil |

---

## 3. Temuan P0 (Kritis) — Sudah Diperbaiki

| ID | Masalah | Perbaikan |
|---|---|---|
| P0-01 | Backup Android berisi database SQLCipher, sedangkan restore memvalidasi header plaintext lalu membukanya dengan SQLite biasa | Ekspor plaintext terkontrol (`sqlcipher_export`) sebelum validasi; restore memahami format terenkripsi |
| P0-02 | Restore menyalin berkas sebelum semua validasi selesai; kegagalan di tengah menghasilkan database kosong | Validasi semua payload lebih dulu, safety `.bak`, replace atomik, rollback saat gagal |
| P0-03 | Backup hanya berisi satu database toko | Format 3: manifest `stores[]` + payload per toko; format lama tetap dapat dipulihkan |
| P0-04 | Viewer dapat membuat kode pairing owner dan menulis akun | Scope token per peran; pengelolaan akun hanya owner; hash password di server; hash tidak dikirim balik |
| P0-05 | Karyawan dapat memalsukan entity pada amplop | `hints_signature` wajib dan diverifikasi relay; client memeriksa ulang entity hasil dekripsi |
| P0-06 | Bootstrap tidak memeriksa keanggotaan toko | Relay menolak bootstrap lintas toko (403) |
| P0-07 | Snapshot lama dapat menimpa data yang lebih baru | Snapshot non-regresi: cursor/seq lebih tinggi tidak ditimpa |
| P0-08 | Delta yang ditolak tetap ditandai `applied_deltas` dan di-ack | Tri-state apply; hanya delta yang benar-benar diterapkan yang di-ack |
| P0-09 | Logout tidak mencabut token dan kunci sinkronisasi | Logout/pencabutan menghapus token, kunci per toko, dan menghentikan sync |
| P0-10 | Pairing memasang akun dari objek yang tidak ditandatangani | Akun dipasang dari payload bertanda tangan; klaim kedua ditolak |

---

## 4. Temuan P1 (Tinggi) — Sudah Diperbaiki

| Area | ID | Perbaikan |
|---|---|---|
| Transaksi & laporan | P1-01 | Modal jasa dihitung (`totalModalJasaCents`) dan masuk laba |
| | P1-02 | Konversi estimasi memakai harga estimasi per baris; perubahan harga master dikonfirmasi |
| | P1-03, P1-04 | Alokasi diskon dengan batas per baris; sisa pembulatan didistribusikan; total tanpa truncation |
| | P1-05 | Baris menyimpan harga final dan alokasi diskon; struk menampilkan diskon per baris |
| | P1-06, P1-07 | Kuantitas desimal didukung; parser format Indonesia membedakan ribuan dan desimal |
| | P1-08 | `actor == null` tidak lagi otomatis dianggap owner |
| Sinkronisasi | P1-09 | `device.seq_floor` dipertahankan sebelum pemangkasan outbox |
| | P1-10, P1-11 | Timeout HTTP/watchdog; envelope penyebab dicari dari detail relay |
| | P1-12 | Token, store key, dan kunci signing disimpan per `store_id` |
| | P1-13 | Epoch `key_id`; kegagalan dekripsi menjadi hard stop |
| | P1-14 | Snapshot/bootstrap wajib sebelum feed pertama |
| | P1-15 | Retry konflik menyimpan dan mengirim ulang envelope asli |
| | P1-16 | Estimasi versi lebih tinggi mengganti item |
| | P1-17, P1-18 | Digest di-upsert per `(store_id, source_device_id, tanggal, data_type)`; tanggal lokal eksplisit |
| | P1-19 | Nomor nota hasil resolusi konflik dikirim ulang sebagai koreksi |
| | P1-20 | Scheduler memakai `try/finally` dan interval awal yang benar |
| UI | P1-21 | Kartu pairing membaca `store_ids_json` dan meminta pilih toko |
| | P1-22 | Backup memakai `try/catch/finally` dan menampilkan pesan |
| | P1-23 | Hasil load karyawan dibuang bila pilihan berubah |
| | P1-24, P1-25 | Gate diskon UI sama dengan service; diskon > bruto ditolak sebelum simpan |
| | P1-26 | Garansi 1 bulan tidak lagi ditimpa default |
| | P1-27, P1-31 | `AppState.touch()` setelah simpan pengaturan/order |
| | P1-28 | Load laporan memakai token epoch + `finally` |
| | P1-29 | Alasan void < 3 karakter ditolak inline, dialog tidak tertutup |
| | P1-30 | Edit stok absolut hanya untuk owner; non-owner diarahkan ke opname |
| | P1-32 | Tombol cetak menangani error dokumen |
| Printer | P1-33 | Dokumen dibangun ulang sesuai lebar printer target |
| | P1-34 | Status cetak membedakan dialog dibuka dan selesai |
| | P1-35, P1-36 | Alamat printer aktif diperiksa; BLE reconnect setelah GATT drop |
| | P1-37 | Codepage CP437/CP850/CP1252 + transliterasi |
| | P1-38, P1-39 | MTU dinegosiasikan; write/flush/close memiliki timeout |
| | P1-40, P1-41 | Perbandingan halaman 1-based; ukuran font dihitung dari lebar halaman |
| Backup & akun | P1-42 | Retry Telegram dibatasi ke folder backup dan pola nama file |
| | P1-43 | Arsip dienkripsi; rahasia tidak ikut diekspor |
| | P1-44 | Restore meregenerasi `kode_lokal` dan mereset counter |
| | P1-45 | Semua operasi akun memeriksa lisensi |
| | P1-46 | Profil/izin disegarkan; akun nonaktif dipaksa logout |
| | P1-47, P1-48 | Rentang gaji mingguan benar; payroll dihitung di dalam transaksi pembayaran |

---

## 5. Temuan P2/P3 — Sudah Diperbaiki

| Kelompok | ID | Perbaikan |
|---|---|---|
| Sync | P2-01–P2-05 | Clamp skew HLC; verifikasi seluruh field inner; transaksi + indeks unik seq; inbox gagal tidak memblokir feed; pemangkasan `applied_deltas` mengikuti cursor peer |
| Data | P2-06–P2-18 | Filter `store_id`; baca-lalu-tulis dalam transaksi; arsip manual dipertahankan; `LoginGuard` atomik; persetujuan fail-closed; jadwal backup tahan jam mundur; normalisasi nomor 62; pembulatan kuantitas; simpan pengaturan transaksional; konsistensi pembayaran; audit pengambilan unit |
| UI | P2-19–P2-30 | `hasError` + retry; `try/catch` pada aksi; validasi harga/bonus/field; `PopScope` saat sibuk; chip navigasi valid; dispose controller; cek `mounted`; `formatQuantity`; pesan stok kurang |
| Printer | P2-31–P2-39 | Bungkus baris; timeout proporsional; BLE tanpa nama; GATT ditutup; listener scan dibatalkan; JSON printer `.bak` + tulis atomik; encoding dipertahankan; identitas USB memakai `deviceId`/serial |

---

## 6. Akar Masalah Lintas Modul

1. **Sumber kebenaran ganda.** Pengaturan toko, identitas, dan konfigurasi
   printer dibaca dari tempat berbeda; kini dinormalisasi di layanan domain.
2. **`actor == null` dianggap owner.** Pola ini sudah dihapus; actor wajib atau
   flag owner eksplisit.
3. **Sinkronisasi mempercayai petunjuk luar.** Relay memverifikasi tanda tangan
   dan klien memeriksa ulang entity hasil dekripsi.
4. **Ack lebih cepat dari penerapan.** `applied_deltas` hanya ditulis untuk delta
   yang benar-benar diterapkan.
5. **Asumsi plaintext pada backup.** Jalur ekspor/impor kini SQLCipher-aware.
6. **Zona waktu campur.** Tanggal lokal eksplisit dipakai untuk digest dan
   laporan; timestamp tetap ISO UTC.
7. **Pembulatan rupiah tidak eksplisit.** Alokasi diskon dan sisa unit memiliki
   aturan yang diuji.
8. **UI menduplikasi aturan bisnis.** Gate diskon dan izin disamakan dengan
   service.
9. **`catch` menelan error.** Aksi kritis menampilkan pesan dan tidak mengunci
   tombol.
10. **Cakupan test tidak merata.** Test aturan bisnis kuat; test perangkat
    (SQLCipher, printer) masih menjadi pekerjaan terbuka.

---

## 7. Pekerjaan yang Sudah Diselesaikan

| Area | Hasil | Berkas utama |
|---|---|---|
| Backup multi-toko | Format arsip 3 dengan manifest `stores[]`, payload AES-256-GCM per toko, checksum, validasi menyeluruh, restore atomik, dan pembangunan ulang registry | `lib/data/backup_service.dart`, `lib/data/store_registry.dart`, `lib/data/app_database.dart` |
| Retur / penjualan neto | Tabel append-only, sisa jumlah per baris, refund proporsional, stok kembali + pergerakan stok, audit, laporan neto | `lib/data/sale_return_service.dart`, `lib/data/schema.dart`, `lib/data/app_database.dart`, `lib/ui/screens/history_screen.dart`, `lib/ui/screens/reports_screen.dart` |
| Sinkron retur | Payload nota membawa `returns`; penerima memetakan stok lewat `stock_sync_id`; tabel retur ikut snapshot | `lib/data/note_sync.dart`, `lib/sync/snapshot_sync.dart` |
| Editor struk v2 | Template JSON, blok dan label, migrasi dari 25 toggle + 4 teks lama, pratinjau, cetak tes | `lib/data/receipt_template.dart`, `lib/data/receipt_settings.dart`, `lib/data/receipt_service.dart`, `lib/ui/screens/receipt_settings_screen.dart` |
| Logo raster | Bitmap 1-bit dari `dart:ui`, perintah `GS v 0`, lebar 10–40 mm | `lib/printer/printer_service.dart`, `lib/printer/logo_platform*.dart` |
| WhatsApp | Deep link `wa.me` dengan normalisasi nomor dan pemotongan teks | `lib/ui/receipt_dialog.dart`, `lib/core/wa_link.dart` |
| Ekspor/impor JSON | Validasi versi dan `validate()` saat impor | `lib/ui/screens/receipt_settings_screen.dart` |
| Pratinjau debounce | Jadwal 300 ms, peringatan validasi, `errorText` per label, tombol simpan nonaktif saat invalid | `lib/ui/screens/receipt_settings_screen.dart` |
| Jatuh tempo + pelunasan | Tanggal disimpan/disinkronkan/dicetak; banner `STRUK PELUNASAN` | `lib/ui/screens/pos_screen.dart`, `lib/data/app_database.dart`, `lib/data/receipt_service.dart` |
| Diskon per baris | Harga terdaftar, harga final, alokasi diskon per baris; baris diskon di struk | `lib/data/models.dart`, `lib/data/app_database.dart`, `lib/data/receipt_service.dart` |
| Pratinjau 58/80 mm | `SegmentedButton` 58/80; dokumen dibangun ulang 32/48 kolom | `lib/ui/receipt_dialog.dart` |

---

## 8. Fitur Struk yang Sudah Dibangun

| Fitur | Keadaan |
|---|---|
| Template tersimpan | `app_settings['receipt.template.v2']`, JSON tervalidasi |
| Blok | header, meta, items, totals, payment, warranty, bank, footer |
| Urutan & visibilitas | Blok dapat digeser dan disembunyikan |
| Label | Semua label dapat diedit; label kosong ditolak |
| Placeholder | `{{nama_toko}}`, `{{tagline}}`, `{{alamat}}`, `{{kontak}}`, dan lainnya |
| Pelanggan/unit/mekanik | Blok meta dengan label yang dapat diubah |
| Riwayat pembayaran | Tampil bila lebih dari satu pembayaran atau DP |
| Sisa / DP / jatuh tempo | Tampil untuk nota yang belum lunas |
| Banner pelunasan | `STRUK PELUNASAN` untuk nota lunas hasil pelunasan/multi-pembayaran |
| Banner VOID | Tampil beserta alasan pembatalan |
| Garansi | Status, tanggal, dan catatan garansi |
| Rekening | Nama bank, nomor, atas nama, catatan |
| Footer | Beberapa baris + alignment + tebal |
| Tanda tangan | Baris tanda tangan dan garis |
| Logo | Raster ESC/POS, lebar mm, preview |
| Diskon per baris | Harga terdaftar × jumlah, lalu baris diskon |
| 58/80 mm | Pratinjau dan cetak sesuai lebar printer |
| Codepage | CP437/CP850/CP1252 + transliterasi karakter Indonesia |
| Salinan | 1–3 rangkap |
| WhatsApp | Kirim teks struk ke nomor pelanggan |
| Ekspor/impor | JSON template untuk backup antarperangkat |
| Pratinjau langsung | Debounce 300 ms + validasi inline |

---

## 9. Build dan Verifikasi

- Tidak ada dependency baru pada `pubspec.yaml` maupun `relay/pubspec.yaml`.
- Build yang disarankan setelah SDK tersedia:

```bash
cd pusatkupos
flutter pub get
flutter analyze
flutter test

cd ../relay
dart pub get
dart analyze
dart test
```

- Verifikasi sesi terakhir (statis): keseimbangan delimiter 143 berkas Dart,
  pencocokan simbol antar-lapis, jalur restore format 1/2/3, dan tidak ada
  dependency baru.
- Pengujian manual yang disarankan:
  1. Buat nota, lakukan retur sebagian, cek stok dan omzet neto.
  2. Backup dua toko, ubah data, restore, pastikan kedua toko dan toko aktif
     pulih.
  3. Ubah template struk, pasang logo, geser 58/80, ekspor JSON, impor lagi,
     lalu kirim ke WhatsApp.

---

## 10. Kriteria Lulus Audit Perbaikan

| Area | Kriteria |
|---|---|
| Backup | Backup Android dapat direstore di perangkat lain; gagal restore tidak mengosongkan DB |
| Multi-toko | Seluruh toko dan toko aktif pulih dari satu arsip |
| Relay | Viewer tidak bisa enroll owner/menulis akun; entity spoof ditolak |
| Sync | Delta ditolak tidak di-ack; snapshot lama ditolak; seq tidak pernah mundur |
| Retur | Sisa jumlah benar, stok kembali, laporan neto, retur diterima perangkat lain |
| Logout | Token dan kunci perangkat terhapus; sync berhenti |
| Laporan | Laba = total - modal part - modal jasa - komisi - gaji - retur |
| Estimasi | Total konversi = total estimasi, atau konfirmasi eksplisit |
| Struk | Template dapat diedit, dipratinjau, disimpan, dicetak 58/80, dan tahan karakter Indonesia |
| Printer | Lebar dokumen sama dengan lebar printer; status cetak jujur |
| Test | Test regresi P0/P1 tetap lulus; perangkat fisik diuji pemilik |

---

## 11. Sisa Pekerjaan

1. Uji perangkat fisik untuk SQLCipher, backup/restore lintas perangkat, dan
   printer thermal.
2. Uji runtime layar POS, Riwayat/Retur, Laporan, Pengaturan Struk, dan dialog
   struk.
3. Sinkron latar sejati (WorkManager/BackgroundTasks).
4. Enkripsi lokal di Windows/Linux/web.
5. Kartu laporan "estimasi belum dikonversi per kasir".

---

## 12. Lampiran

### 12.1 File yang diaudit

**Flutter inti**
`lib/main.dart`, `lib/app.dart`, `lib/state/app_state.dart`, `lib/auth/*`,
`lib/core/*`, `lib/data/app_database.dart`, `schema.dart`, `models.dart`,
`order_service.dart`, `price_rules.dart`, `approval_service.dart`,
`nota_adjustment_service.dart`, `sale_return_service.dart`, `receipt_service.dart`,
`receipt_template.dart`, `receipt_settings.dart`, `backup_service.dart`,
`backup_scheduler.dart`, `store_registry.dart`, `account_service.dart`,
`employee_service.dart`, `employee_auth_service.dart`, `session_service.dart`,
`pin_service.dart`, `login_guard.dart`, `device_service.dart`,
`pairing_service.dart`, `license_service.dart`, `license_verifier.dart`,
`google_auth_service.dart`, `owner_access_api.dart`, `store_service.dart`,
`store_settings.dart`, `supplier_service.dart`, `followup_service.dart`,
`reconciliation_service.dart`, `note_sync.dart`, `secure_store.dart`.

**Sinkronisasi**
`lib/sync/sync_service.dart`, `protocol.dart`, `crypto.dart`, `relay_client.dart`,
`snapshot_sync.dart`, `snapshot_platform_io.dart`, `sync_conflict_rules.dart`,
`sync_scheduler.dart`, `sync_secrets.dart`.

**UI**
`lib/ui/*.dart`, `lib/ui/screens/*.dart`, `lib/ui/widgets/*.dart`.

**Printer**
`lib/printer/*.dart`,
`android/app/src/main/kotlin/com/pusatkupos/pusatkupos/printer/*.kt`.

**Relay**
`relay/lib/server.dart`, `auth_rules.dart`, `canonical.dart`, `config.dart`,
`db.dart`, `google.dart`, `license.dart`, `sync_round.dart`, `bin/relay.dart`.

### 12.2 Referensi Python

- `services/receipt_service.py` — penyusun struk, 25 field, pembayaran, VOID,
  garansi, label, teks WA, payload 58/80.
- `services/escpos_service.py` — `ReceiptBuilder`, alignment, bold, double,
  `to_escpos`, feed+cut.
- `services/settings_service.py` — `RECEIPT_FIELDS`, `bengkel.*`, `ops.*`.
- `services/printer_settings_service.py` — validasi printer, 58/80, mode,
  encoding, satu primary, penulisan atomik.
- `api/printer_routes.py` — endpoint baca/tulis konfigurasi printer.

### 12.3 Catatan status

- Dokumen ini sudah mencerminkan kode setelah perbaikan, bukan rencana.
- Test tahap sebelumnya tercatat di `LAPORAN_PERBAIKAN_SYNC.md`.
- Sesi terakhir hanya melakukan verifikasi statis karena SDK tidak tersedia dan
  dependency tidak boleh dipasang.
