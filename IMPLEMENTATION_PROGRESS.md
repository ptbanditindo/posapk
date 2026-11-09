# Progres Implementasi — IMPLEMENTATION_PLAN.md

Dokumen ini mencatat status eksekusi per fase. Satu task dicentang hanya bila
kode sudah ditulis dan `dart analyze lib` bersih. Uji otomatis/skenario belum
dijalankan karena menunggu persetujuan pemilik.

- [1. Ringkasan fase](#1-ringkasan-fase)
- [2. F0 — Penjaga Keamanan & Data](#2-f0--penjaga-keamanan--data)
- [3. F1 — Baseline Schema & Integritas](#3-f1--baseline-schema--integritas)
- [4. F2 — Konsistensi Transaksi](#4-f2--konsistensi-transaksi)
- [5. F3 — Harga, Pembayaran, Zona Waktu](#5-f3--harga-pembayaran-zona-waktu)
- [6. F4 — Stok, HPP, Izin](#6-f4--stok-hpp-izin)
- [7. F5 — Offline 24 Jam, Outbox, Riwayat](#7-f5--offline-24-jam-outbox-riwayat)
- [8. F6 — Sync Lanjutan & Konflik](#8-f6--sync-lanjutan--konflik)
- [9. F7 — Arsip, Pencarian, Tutup Buku](#9-f7--arsip-pencarian-tutup-buku)
- [10. F8 — E2EE & Siklus Kunci](#10-f8--e2ee--siklus-kunci)
- [11. F9 — Error & Recovery](#11-f9--error--recovery)
- [12. F10 — Performa & Pembulatan](#12-f10--performa--pembulatan)
- [13. Berkas yang berubah](#13-berkas-yang-berubah)

## 1. Ringkasan fase

| Fase | Status | Catatan |
|---|---|---|
| F0 | Selesai | Semua guard logout/restore/sync/banner |
| F1 | Selesai | Baseline schema (v11) & laporan integritas di diagnostik |
| F2 | Selesai | Konsistensi transaksi; schema naik ke v12 |
| F3 | Selesai | Harga, pembayaran, zona waktu; schema naik ke v13 |
| F4 | Selesai (kecuali uji F4-8) | Stok, HPP, izin; tanpa perubahan schema |
| F5 | Selesai (kecuali uji F5-5) | Sync event-driven, status per dokumen, paginasi riwayat, panel sync, laporan/VOID |
| F6 | Selesai (kecuali uji F6-6) | Sync lanjutan, konflik, protokol, kompensasi |
| F7 | Selesai (kecuali uji F7-6/F7-7) | Arsip, purge (flag mati), pencarian, ekspor, tutup buku; schema v16 |
| F8 | Selesai (kecuali uji F8-8) | E2EE, escrow, rotasi kunci, viewer/role; schema v17; protokol v2 |
| F9 | Selesai (kecuali uji F9-4) | Diagnosis startup, antrean cetak, pesan error actionable, health surface |
| F10 | Selesai | Index performa, aritmetika integer, metrik feed/snapshot; schema v19 |

## 2. F0 — Penjaga Keamanan & Data

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F0-1 | Ringkasan outbox sebelum logout | Selesai | `entry_gate.dart`: dialog pending/failed + ekspor JSON; `sync_service.dart`: `outboxSummary()`, `exportOutboxJson()` |
| F0-2 | Hentikan hapus DB saat logout | Selesai | `entry_gate.dart`: `signOutSession` hanya mengakhiri sesi; `resetDeviceSession` terpisah dengan PIN pemilik; `session_service.dart`: `clearProfile()` |
| F0-3 | Autentikasi owner sebelum restore | Selesai (lokal) | `settings_screen.dart` + `startup_recovery.dart`: PIN pemilik wajib bila PIN terpasang; `backup_service.dart`/`backup_manifest.dart`: `owner_id` di manifest dan penolakan pemilik berbeda. Jalur cloud memakai token lisensi owner + store id yang sudah ada |
| F0-4 | Restore tidak membuang outbox baru | Selesai | `backup_service.dart`: `_restoreOutboxGuard` menahan restore bila ada pending/failed dengan `created_at` lebih baru dari manifest |
| F0-5 | Satukan aturan void/retur | Selesai | `note_sync.dart`: void remote ditolak saat retur aktif; `sale_return_service.dart`: validasi stok sebelum reversal |
| F0-6 | Filter retur aktif saat restock void | Selesai | `sale_return_service.dart`: reversal memeriksa stok tersedia agar retur tidak menggandakan stok |
| F0-7 | Karantina WAL/SHM | Selesai | `app_database.dart`: `openSafeMode()` memindahkan `.db`, `-wal`, `-shm`, `-journal`, penanda versi |
| F0-8 | `busy_timeout` + journal mode | Selesai | `app_database.dart`: `PRAGMA busy_timeout=5000` dan `journal_mode=WAL` eksplisit |
| F0-9 | Audit trail aksi istimewa | Selesai | `audit_service.dart`; dipakai void, stok manual, katalog, restore, reset, dan grant harga di bawah modal (F2-2) |
| F0-10 | Banner offline 24 jam | Selesai | `widgets/sync_status_banner.dart`: banner premium + relay aktif; footer backup lokal; dipasang di `home_shell.dart` |

Catatan F0-9: audit reset ditulis sebelum database dihapus; jejak sesudah
reset hanya tersisa di log diagnostik karena database target memang dibuang.
Audit restore ditulis ke database hasil restore.

## 3. F1 — Baseline Schema & Integritas

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F1-1 | Baseline schema baru (`purged_documents`, `period_closings`, salinan `archive_receipts`, `protocol_version`) | Selesai | `schema.dart`: `createIntegrityBaseline` (tabel + `protocol_version` di `app_meta`); dipanggil dari schema operasional dan migrasi v11; `app_database.dart`: `schemaVersion = 11`; `schema_migrations.dart`: `_migrateIntegrityBaselineV11`; `core/app_config.dart`: `protocolVersion = 1` |
| F1-2 | Deteksi duplikat sebelum unique index | Selesai | `diagnostics_service.dart`: `_duplicates` memeriksa `service_records.no_nota`, `service_payments.request_id`, `sync_outbox.idempotency_key`, pasangan sumber stok/kas |
| F1-3 | Rekonsiliasi ledger vs saldo | Selesai | `diagnostics_service.dart`: `_stockDifferences` (saldo vs agregat `stock_movements`), `_cashDifferences` (pembayaran vs `cash_ledger`) |
| F1-4 | Kebijakan non-negatif | Selesai | `diagnostics_service.dart`: `_negativeStock` melaporkan `jumlah_milli < 0`; laporan saja tanpa mengubah data |

Catatan F1: pemeriksaan integritas bersifat laporan (read-only); belum ada
perbaikan otomatis dan belum dijalankan uji. Versi schema naik ke 11 tanpa
rantai migrasi lama — database lama dibuka lewat jalur karantina F0-7. F2
menaikkan versi ke 12 lewat migrasi aditif `request_payload_hash`.

## 4. F2 — Konsistensi Transaksi

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F2-1 | Harga acuan dan final | Selesai | `price_rules.dart`: `PriceLine.hargaInput` terpisah dari `hargaTerdaftar` (subtotal/floor memakai input); `pos_screen.dart`: dialog jasa punya "Harga normal" dan "Harga disepakati"; `app_database.dart`: `createTransaction` menyimpan acuan + input, hash permintaan memuat `harga_acuan`; `order_service.dart`: estimasi menyimpan acuan/input |
| F2-2 | Grant persetujuan tunggal | Selesai | `approval_service.dart`: `ApprovalGrant` (label, isOwner, verifiedAt); `app_database.dart`: satu grant dipakai ulang untuk diskon, baris di bawah modal, dan limit kredit; `order_service.dart`: pola grant sama untuk estimasi; audit `harga_di_bawah_modal` mencatat approver, status owner, waktu verifikasi, dan baris |
| F2-3 | Alasan diskon dari POS | Selesai | `pos_screen.dart`: field alasan wajib saat harga nego/diskon; service menolak `alasan_diskon_wajib`, `harga_nol`, dan `persetujuan_diperlukan`; `diskon_snapshot_json.baris` membedakan gratis vs diskon penuh; `models.dart`/`reports_screen.dart`: label "Gratis"/"Diskon 100%"/"Harga nego/diskon" |
| F2-4 | Idempotensi pembelian/retur pembelian | Selesai | `purchase_service.dart`: hash kanonik payload disimpan di `request_payload_hash` dan retry dengan isi berbeda ditolak; `schema.dart`: kolom pada `supplier_purchases` dan `supplier_purchase_returns`; `schema_migrations.dart`: migrasi v12 |
| F2-5 | Audit katalog/stok/void | Selesai | Sudah terpasang sejak F0: `tambah_katalog`, `ubah_katalog`, `hapus_katalog`, `tambah_stok`, `ubah_stok`, void, restore, reset; F2 menambah `harga_di_bawah_modal` |
| F2-6 | Hapus jalur approval palsu | Selesai | `createTransaction` tidak lagi menerima `approvedByOverride`; `order_service.convertEstimateToNote` memverifikasi ulang PIN/grant alih-alih memakai `disetujuiOleh` estimasi |

Catatan F2: skema naik ke 12. Negosiasi per baris untuk part dibuka di F3-4.
Semua perubahan lolos `dart analyze lib`.

## 5. F3 — Harga, Pembayaran, Zona Waktu

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F3-1 | Struk acuan vs final | Selesai | `receipt_service.dart`: baris struk mencetak `Harga acuan` saat final berbeda dari acuan; subtotal memakai `harga_final` |
| F3-2 | Uang diterima vs kembalian | Selesai | `models.dart`: `ServiceRecordSummary.kembalianCents`; `receipt_service.dart`: CASH mencetak `bayar` mentah tersimpan dan `kembalian` tersimpan, non-CASH memakai total dibayar |
| F3-3 | Bayar penuh tanpa pembulatan | Selesai | `core/money.dart`: `formatRupiahInput` (desimal 2, parse balik); `pos_screen.dart`: tombol "Bayar penuh" memakai nilai sen yang dapat diparse ulang |
| F3-4 | Negosiasi per item | Selesai | `pos_screen.dart`: dialog jasa dan part punya harga acuan + harga disepakati + alasan per baris; `price_rules.dart`: `PriceLine.alasanDiskon` per baris menang atas alasan nota; `app_database.dart`: validasi alasan per baris, acuan katalog basi ditolak, harga part di atas master ditolak |
| F3-5 | Dipindah ke F4-9 | Selesai (dipindah) | Tidak ada kode di F3; menjadi F4-9 |
| F3-6 | Snapshot pajak UI = service | Selesai | `pos_screen.dart` dan `app_database.createTransaction` memakai `PajakSnapshot.hitung` dengan basis `bruto - diskon` yang sama; snapshot estimasi divalidasi `_validatePajakSnapshot` sebelum disalin |
| F3-7 | DPP/PPN penyesuaian | Selesai | `nota_adjustment_service.dart`: `_scaledTaxSnapshot` menyimpan `dpp_cents`/`ppn_cents`/`pajak_diserap_cents` diskalakan terhadap total efektif, juga saat `applyRemote`; `sync_service.dart`: payload koreksi memuat kolom pajak; `pajak_report_service.dart`: rekap dan rincian memakai `COALESCE(adj...)` dan tetap mengecualikan TANPA; `app_database.dart`: `marginRevenueFactorSql` memakai DPP efektif atau rasio total efektif agar laba ikut turun setelah koreksi |
| F3-8 | Qty sesuai satuan | Selesai | `app_database.dart`: jasa wajib `jumlah >= 1`; part wajib kelipatan satuan (`desimal` 0-3) dengan pesan `qty_satuan`; `pos_screen.dart`: parse qty memakai `desimal` barang sehingga 0,5 unit bulat ditolak, bukan dipotong 0 |
| F3-9 | Zona waktu toko | Selesai | `core/dates.dart`: offset tetap WIB/WITA/WIT + `setZonaWaktuToko`, `isoStartOfDay`/`isoEndOfDay`/`localTime`/`todayKey`; `store_settings.dart`: `zona_waktu` dibaca/ditulis/diterapkan dari sync dan langsung mengatur offset; `store_settings_screen.dart`: pilihan zona waktu; `purchase_service.marginReport` memakai rentang UTC zona toko, bukan `date()` SQLite |

Catatan F3: schema naik ke 13 lewat migrasi aditif (`nota_adjustments` kolom
pajak nullable, `store_settings.zona_waktu`). Nilai pajak koreksi diskalakan
proporsional; koreksi tanpa nilai pajak (baris lama) tetap memakai kolom nota.
Uji batas tengah malam dan uji lainnya belum dijalankan karena menunggu
persetujuan. Semua perubahan lolos `dart analyze lib`.

## 6. F4 — Stok, HPP, Izin

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F4-1 | Opname absolut + isolasi | Selesai | `opname_service.dart`: `record` menerima `requestId` tetap, hold menyimpan `movement_sync_id`, permintaan ulang mengembalikan hold yang sama; `applyOpnameTx` menerima `movementSyncId` sehingga retry idempoten; `processPending` membaca ulang status di dalam transaksi dan satu hold gagal tidak menghentikan hold lain |
| F4-2 | Retur: clamp & filter | Selesai | Sudah terpasang di F0-5/F0-6: `sale_return_service.dart` membatasi qty pada retur aktif dan restock void |
| F4-3 | HPP saldo negatif | Selesai | `stock_ledger.dart`: rata-rata tidak diwarisi saat saldo sebelum <= 0; nilai dihitung ulang dari basis yang sudah dibersihkan |
| F4-4 | Movement masuk/keluar eksplisit | Selesai | `stock_ledger.dart`: movement keluar menyimpan HPP yang dipakai (`harga_pokok_satuan_cents`); semua mutasi lewat `StockLedger.apply` sehingga saldo selalu punya asal movement |
| F4-5 | Retur memakai snapshot modal | Selesai | `sale_return_service.dart`: modal baris retur diambil dari movement `service_part`, lalu `harga_modal`, lalu `harga_batas_saat_transaksi` |
| F4-6 | Kartu stok + rekonsiliasi | Selesai | `app_database.dart`: `stockCard()` mengembalikan movement, saldo, nilai, dan HPP; `stock_screen.dart`: menu "Kartu stok" menampilkan riwayat dan peringatan selisih ledger vs saldo |
| F4-7 | Pemisahan izin stok | Selesai | `access_control.dart`: peran bawaan GUDANG (`lihat_stok` + `stok_masuk`) dan default KASIR hanya `stok_keluar`; `app_database.createTransaction` menolak penjualan berpart tanpa `stok_keluar`; `pos_screen.dart` memblokir tambah/simpan part tanpa izin; `sync_conflict_rules.dart` memeriksa izin movement per jenis |
| F4-8 | Uji stok & matriks izin | Belum dijalankan | Menunggu persetujuan pemilik; keputusan sesi: jangan jalankan uji/build |
| F4-9 | Modal baris = HPP ledger | Selesai | `app_database.createTransaction`: modal part dari `StockLedger.averageCostMilli`, bukan `harga_modal` master; harga acuan tetap harga jual master |
| F4-10 | Akun lokal gratis | Selesai | `account_service.createAccount`: gate premium dihapus; `premium_screen.dart`: tombol tambah akun aktif tanpa lisensi dan teks premium hanya menyebut sync/multi-toko |

Catatan F4: izin movement saat sync kini diperiksa per jenis (`MASUK` →
`stok_masuk`, `KELUAR` → `stok_keluar`, opname absolut → `opname`, koreksi
manual → `ubah_stok`) di `sync_conflict_rules.dart`, bukan satu izin
`ubah_stok`. F4-8 belum dijalankan sesuai keputusan untuk tidak menjalankan
uji. Semua perubahan lolos `dart analyze lib`.

## 7. F5 — Offline 24 Jam, Outbox, Riwayat

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F5-0 | Sync event-driven & offline 24 jam | Selesai | `sync_scheduler.dart`: debounce 3 detik, fallback 15 menit hanya saat foreground, timer dibatalkan saat paused/inactive/hidden/detached, sync saat start/resume; `sync_service.enqueue` memanggil `requestSync()` sehingga perubahan lokal memicu kirim. Tidak ada polling 60 detik dan tidak ada sync latar belakang |
| F5-1 | Status sync per dokumen | Selesai | `models.dart`: `ServiceRecordSummary.syncStatus`; `app_database.listRecords`/`recordDetail` mengambil status outbox `nota` terbaru lewat subquery; `history_screen.dart`: badge Menunggu/Tersinkron/Gagal/Gagal permanen |
| F5-2 | Paginasi & filter riwayat | Selesai | `history_screen.dart`: halaman 50 + "Muat lebih banyak", filter rentang tanggal, pencarian nomor/nama, filter Piutang; token pemuatan mencegah hasil lama menimpa hasil baru |
| F5-3 | Panel status sync utama | Selesai | `sync_status_banner.dart`: `SyncStatusStrip` hanya untuk premium + relay aktif, menampilkan relay, sync terakhir, pending/failed/konflik, dan tombol Sinkron; banner 24 jam tetap di atasnya; toko gratis tetap memakai `BackupStatusFooter` |
| F5-4 | Guard logout/restore | Selesai | Sudah terpasang di F0-1/F0-4: ringkasan outbox sebelum logout dan `_restoreOutboxGuard` menahan restore bila outbox lebih baru |
| F5-5 | Uji force close & offline 24 jam | Belum dijalankan | Menunggu persetujuan pemilik; keputusan sesi: jangan jalankan uji/build |
| F5-6 | Cakupan laporan & VOID | Selesai | Piutang laporan dan filter riwayat sama-sama memakai `service_records.sisa_bayar` dan mengecualikan `VOID`; kas laporan, dasbor, dan owner viewer sama-sama berasal dari `reportSummary.cashByMethod`; `history_screen.dart` memberi badge VOID; `owner_summary_service.dart` menambahkan komponen keuangan (omzet, retur, HPP, laba, DPP/PPN, komisi, gaji, kas per metode, piutang) ke ekspor bertanda tangan |

Catatan F5: tidak ada perubahan schema. Reconnect tidak memakai paket
konektivitas; percobaan ulang mengandalkan fallback 15 menit, resume aplikasi,
dan pemicu setiap perubahan lokal. F5-5 belum dijalankan sesuai keputusan untuk
tidak menjalankan uji. Semua perubahan lolos `dart analyze lib`.

## 8. F6 — Sync Lanjutan & Konflik

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F6-1 | Dead-letter & error kripto | Selesai | `sync_conflict_rules.dart`: `maxRetries`, `permanentReasons`, `suggestionForReason`; `sync_service.dart`: `_retryInbox` menandai `failed` tanpa menahan cursor, `_failOutbox` menyimpan pesan actionable, `exportOutboxJson` untuk dukungan |
| F6-2 | Kuota & pruning relay | Selesai | `relay/config.dart`: `storageWarnRatio`, `minSupportedProtocol`, `deviceActiveDays`; `relay/server.dart`: peringatan memakai rasio, kode `body_too_large`/`storage_full`, `_relevantDevicesCte` menyaring heartbeat 30 hari; `sync_service.dart`: re-enroll memindahkan outbox pending ke id relay baru (tidak membuang dokumen) |
| F6-3 | Konflik domain & feature flag | Selesai | `sync_conflict_rules.dart`: `compareHlc` (HLC lebih awal menang, `device_id` tie-break); `feature_flags.dart`: tie-break `device_id`; `sync_service.dart`: koreksi vs void memakai HLC dan mencatat pemenang; anak tanpa induk ditahan `nota_butuh_induk`; induk VOID menolak anak |
| F6-4 | Idempotensi permanen & snapshot | Selesai | `sync_service.cleanupSyncHistory`: `applied_deltas` tidak pernah dihapus; `snapshot_sync.dart`: `complete`, HLC tidak lebih tua dari `sync.hlc_floor`, manifest mencakup semua perangkat aktif; relay menyimpan/mengembalikan `schema_version`, `schema_contract_version`, `app_version` agar tanda tangan klien cocok |
| F6-5 | Audit status tablet | Selesai | `app_database.dart`/`order_service.dart`: status order mencatat aktor, waktu, HLC, perangkat; `sync_service.dart`: status remote disimpan dengan `...hlc` dan urutan HLC; `orders_screen.dart`: riwayat menampilkan perangkat dan HLC |
| F6-6 | Uji dua perangkat & offline 24 jam | Belum dijalankan | Menunggu persetujuan pemilik; keputusan sesi: jangan jalankan uji/build |
| F6-7 | Versi protokol | Selesai | `protocol.dart`: `protocol_version` ikut ditandatangani; `relay_client.dart`: header `X-Protocol-Version`; `relay/server.dart`: 426 + `min_supported` di submit/feed/ack/bootstrap/snapshot; `sync_service.dart`: 426 menahan outbox (tetap pending) dan menandai `sync.upgrade_required` berisi versi aplikasi; `sync_status_banner.dart`: strip “Perbarui aplikasi” |
| F6-8 | Dokumen kompensasi | Selesai | `note_sync.dart`: void/retur menyimpan HLC + perangkat, konflik `void_menang` dengan `pemenang`/`butuh_bantuan_owner`; `compensation_service.dart` (baru): membalik retur kalah hanya di perangkat asal dengan `request_id` deterministik; `sale_return_service.dart`: `automatic` melewati izin; `sync_scheduler.dart`: kompensasi dijalankan sebelum sync |
| F6-9 | Layar Konflik & bantuan owner | Selesai | `sync_conflicts_screen.dart`: status “Perlu bantuan owner” (7 hari via `ownerHelpAfter`), status kompensasi, saran dead-letter, tombol “Selesaikan (owner)” + “Abaikan”; `sync_service.dart`: setiap coba ulang/abaikan/penyelesaian owner dicatat di `business_audits` |

Catatan F6: `dart analyze lib` bersih untuk `pusatkupos/` dan `relay/`.
Uji F6-6 belum dijalankan sesuai keputusan “lupakan untuk test”. Re-enroll
memindahkan outbox pending ke id relay baru lalu menghapus `device.seq_floor`;
urutan seq tetap monoton dan relay menerima nomor awal baru. Snapshot menolak
perangkat aktif yang tidak ada di manifest, kecuali perangkat lokal sendiri
agar bootstrap perangkat baru tetap mungkin. Penyelesaian konflik mencatat
pilihan di `business_audits` dengan entity `sync_conflict` (append-only, tidak
mengubah dokumen bisnis).

## 9. F7 — Arsip, Pencarian, Tutup Buku

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F7-1 | Payload arsip lengkap | Selesai | `sync/archive_service.dart`: `_buildBundle` memuat nota, jasa, part, pembayaran, komisi, penyesuaian, dan retur beserta reversal; envelope per nota dengan schema/key version |
| F7-2 | Skema arsip | Selesai | `data/schema.dart`: `archive_documents`, `archive_index_tokens`, `archive_receipts`, `archive_envelopes`; `relay/lib/db.dart`: tabel arsip sisi server tanpa kolom plaintext |
| F7-3 | API arsip | Selesai | `relay/lib/server.dart`: `POST/GET /archive/documents`, `/archive/search`, `/archive/export`; token relay HMAC; tidak ada endpoint hapus; token baca-saja setelah premium berakhir |
| F7-4 | ArchiveClient | Selesai | `sync/archive_client.dart`: base URL arsip terpisah, token perangkat, retry, receipt; `archive_service.processPending` berjalan di scheduler tanpa memblokir jual/sync |
| F7-5 | Purge bertahap | Selesai (flag mati) | `data/purge_service.dart`: gate umur ≥1 tahun, periode FINAL, status lunas/void, receipt terverifikasi, outbox kosong, stok/kas aman, `purge.enabled`, escrow, premium, snapshot stabil; menulis `purged_documents` dan audit tanpa menghapus ledger |
| F7-6 | Uji e2e arsip | Belum dijalankan | Menunggu persetujuan pemilik; keputusan sesi: jangan jalankan uji/build |
| F7-7 | Durabilitas arsip | Dokumen selesai, uji belum | `relay/OPS.md` §9: snapshot penyedia, salinan offsite, uji restore triwulanan, RPO ≤ 24 jam, RTO ≤ 4 jam; uji restore belum dijalankan |
| F7-8 | Pencarian arsip & riwayat | Selesai | `ui/screens/archive_search_screen.dart`: “Cari di server”, paginasi, dekripsi lokal, tampilan struk, tombol ekspor; `ui/screens/history_screen.dart`: entri pencarian server dan baris “Ada di arsip” dari `purged_documents` |
| F7-9 | Operasional relay/arsip | Dokumen selesai, deployment belum | `relay/OPS.md` §4/§8/§10: TLS, CORS, kuota sync/arsip, monitoring, backup PostgreSQL, dua URL (`PUSATKU_SERVICE_URL` + `PUSATKU_ARCHIVE_URL`); deployment dua VM belum diuji |
| F7-10 | Ekspor arsip lengkap | Selesai | `archive_service.exportArchive`: unduh ciphertext, dekripsi lokal, simpan berkas; dipakai juga saat premium berakhir; server tidak pernah menerima plaintext |
| F7-11 | Tutup buku & buka dari arsip | Selesai | `data/period_closing_service.dart`: tutup manual/otomatis 7 hari setelah akhir bulan dari perangkat owner, snapshot memakai sumber `reportSummary`; `data/archive_return_service.dart`: retur nota terpurge lewat `ref_doc_id`, stok/kas/pajak dialokasikan dan disinkronkan sebagai entitas `archive_return`; `ui/screens/reports_screen.dart`: navigasi bulan dan laporan bulan tertutup dirender dari snapshot |

Catatan F7: schema lokal naik ke **v16** lewat migrasi aditif
(`period_closings` diperluas + tabel `archive_returns`/`archive_return_items`).
Purge tetap mati (`purge.enabled` default off) sampai escrow dan uji restore
arsip lulus di F8-8. Snapshot tutup buku tidak ikut dipurge, sehingga angka
laporan bulan lama identik sebelum dan sesudah purge; retur atas nota terpurge
berjalan online karena membaca ciphertext dari arsip. Uji F7-6 dan uji restore
F7-7 belum dijalankan sesuai keputusan “lupakan untuk test”.

## 10. F8 — E2EE & Siklus Kunci

| ID | Task | Status | Bukti kode |
|---|---|---|---|
| F8-1 | Escrow pemulihan | Selesai | `data/escrow_service.dart`: master key acak, frasa 12 kata + Argon2id (64 MiB/3/2), wrap AES-GCM ber-AAD, share Shamir 2-dari-3 (`shamir:v1:`), escrow semua toko terdaftar; `ui/screens/escrow_screen.dart` (baru): buat/verifikasi frasa & share, pulihkan, unggah/unduh Drive, ekspor/impor berkas; `settings_screen.dart`: entri “Kelola escrow” |
| F8-2 | Rotasi & versi kunci | Selesai | `sync/sync_service.dart`: ring kunci `sync.store_key_ring`, `rotateStoreKey` menulis ulang wrap ke semua perangkat lalu mengaktifkan versi baru, kunci lama disimpan; `sync/relay_client.dart`: `key_version` pada wrap/envelope/arsip; `relay/lib/server.dart`: kolom `key_version` di `store_keys`/`envelopes`/`archive_documents`, tanda tangan kanonik memuat versi, `409 stale_key` untuk wrap lebih lama, feed/bootstrap/arsip mengembalikan versi; `relay/lib/db.dart`: migrasi aditif; `schema_migrations.dart` v17 |
| F8-3 | Distribusi kunci otomatis | Selesai | `sync_service.syncStoreKeysToDevices()`: owner membungkus kunci aktif untuk perangkat tanpa kunci/versi lama; `_shareKeysIfNeeded` berjalan tiap sync (throttle 10 menit) dan mencatat `key.grant`; `relay_client.devices(limit/offset/storeId)` + `owner_access_api`; `premium_screen.dart`: tombol “Selaraskan akses kunci”, “Rotasi kunci toko”, label versi kunci per perangkat |
| F8-4 | Kebocoran metadata | Selesai (dokumen) | `relay/OPS.md` §11: metadata yang terlihat relay, blind index HMAC normalisasi + pemisahan jenis, batas yang tetap ada (pola token sama) |
| F8-5 | TLS & CORS ketat | Selesai | `relay/lib/config.dart` + `.env.example`: `RELAY_ALLOWED_ORIGINS`; `relay/lib/server.dart`: origin hanya dipantulkan bila terdaftar, preflight asing `403 origin_denied`, `Vary: Origin`, error tak terduga `500 internal_error` tanpa detail; `OPS.md` §4/§10 diperbarui |
| F8-6 | PIN & DB at-rest | Selesai | `data/pin_service.dart`: hash/salt/iterasi hanya di SecureStore; migrasi legacy dari `app_meta` lalu menghapusnya; `README.md`: matriks platform + kewajiban BitLocker/EFS/LUKS, SQLCipher Android/iOS/macOS |
| F8-7 | Viewer & role | Selesai | `data/app_database.dart`: `runViewerSyncWrite` memakai koneksi kedua `singleInstance: false` di zona sinkronisasi; koneksi utama tetap `query_only=ON`; `saveCatalog`/`deleteCatalog` wajib aktor, izin, dan owner; `data/access_control.dart`: `employeeRole()` menolak `owner`; diterapkan di `account_service` (lokal + remote), `employee_auth_service`, `sync_service` (entitas employee), dan `snapshot_sync` |
| F8-8 | Uji recovery | Belum dijalankan | Menunggu persetujuan pemilik; `purge.enabled` tetap mati |
| F8-9 | Dipindah ke F4-10 | Selesai (dipindah) | Lihat F4-10 |
| F8-10 | Mode perangkat dicabut | Selesai | `relay/lib/server.dart`: token dicabut dibalas `403 device_revoked` (bukan 401); `relay/lib/server.dart` mencatat `device_events`; `sync_service.dart`: `sync.device_revoked_at`, sync ditahan, outbox tidak dibuang, flag dihapus saat pasangkan ulang; `widgets/sync_status_banner.dart`: banner terkunci + aksi “Ekspor & reset”/“Keluar”; reset tetap lewat `resetDeviceSession` (ekspor antrean + PIN owner, tanpa wipe otomatis) |

Catatan F8: schema lokal naik ke **v17** (`_migrateKeyVersionV17`) dan protokol
sinkronisasi menjadi **v2** (`key_version` ikut ditandatangani); relay memakai
`RELAY_MIN_PROTOCOL=1` secara default agar perangkat v1 tetap terlayani sampai
seluruh armada diperbarui. Web tetap memakai jalur lama untuk tulis ringkasan
karena `singleInstance: false` tidak didukung sqflite web; web bukan target
produksi. Uji F8-8 (Google hilang, perangkat hilang, akun diambil alih, rotasi,
restore arsip) belum dijalankan sesuai keputusan “lupakan untuk test”, sehingga
`purge.enabled` tetap mati. F8-9 sudah dipindah ke F4-10.

## 11. F9 — Error & Recovery

| Task | Judul | Status | Bukti |
| --- | --- | --- | --- |
| F9-1 | Diagnosis sebelum safe mode | Selesai | `core/startup_diagnosis.dart` (baru): `diagnoseStartupError` memetakan DB terkunci, disk penuh, read-only/izin, file rusak, kunci/dekripsi, versi skema, dan file hilang ke penyebab + tindakan; `core/startup.dart` mencatat `startup.fail`/`startup.safe_mode.fail` dengan diagnosis sebelum karantina; `ui/startup_recovery.dart` menampilkan kartu “Diagnosis awal”; karantina tetap hanya lewat tombol “Buka mode aman” |
| F9-2 | Antrean cetak | Selesai | `data/print_queue_service.dart` (baru): `print_jobs` (status PENDING/PRINTED/FAILED/SUPERSEDED), enqueue memakai ulang job gagal, retry menambah `attempts`, job sukses menandai kegagalan lama `SUPERSEDED`; `ui/receipt_dialog.dart` memakai antrean, menampilkan status cetak + “Cetak ulang” dan jumlah percobaan; `data/schema.dart` + migrasi v18 |
| F9-3 | Pesan kripto/token | Selesai | `ui/error_messages.dart` (baru): `describeError`/`friendlyError` memetakan `device_revoked`, `protocol_unsupported`/`upgrade_required`, `stale_key`, `license_expired`/`license_inactive`, `storage_full`, `body_too_large`, `rate_limited`/`relay_sibuk`, `incomplete_store`, `origin_denied`, timeout, 401/403/409/426/5xx, `ProtocolVersionException`, `RetryableSyncException`, `EscrowException`, serta DB terkunci/dekripsi/token; dipakai di `sync_status_banner.dart`, `escrow_screen.dart`, `archive_search_screen.dart`, `receipt_dialog.dart` |
| F9-4 | Uji kegagalan | Belum dijalankan | Skenario storage penuh, DB locked, token kedaluwarsa, arsip mati menunggu persetujuan pemilik (keputusan sesi: lupakan test) |
| F9-5 | Health surface | Selesai | `ui/widgets/health_surface.dart` (baru): `HealthSnapshot` + `OperationalHealthStrip` (polling 5 menit) merangkum backup lokal, sinkronisasi, arsip, dan antrean cetak; `HealthDialog` menampilkan rincian dan tombol muat ulang; `data/archive_service.status()` menyediakan jumlah arsip/pending/gagal; dipasang di `ui/home_shell.dart` |

Catatan F9: banner sync yang ada tetap dipertahankan; health surface hanya
menambah ringkasan kegagalan berkepanjangan (backup > 7 hari, arsip gagal,
cetak gagal) tanpa mengubah alur sync. Tidak ada data yang dipindah atau
dihapus otomatis oleh diagnosis.

## 12. F10 — Performa & Pembulatan

| Task | Judul | Status | Bukti |
| --- | --- | --- | --- |
| F10-1 | Index & query 2 tahun | Selesai | `data/schema.dart`: `createPerformanceIndexes` (12 index) untuk `service_records` (waktu, no_nota, customer_nama, piutang parsial), `service_payments`, `cash_ledger`, `stock_movements`, `sync_outbox`, `purged_documents`, `sale_returns`, `archive_documents`; migrasi v19; dipanggil dari skema operasional |
| F10-2 | Aritmetika integer | Selesai | `data/app_database.dart`: `roundDivideSql` (pembulatan half-away-from-zero) dan `marginRevenueSql` mengalikan DPP/efektif dengan pembagian integer; `recordModalSql` menjadi getter integer; ringkasan laporan memakai helper yang sama; `data/purchase_service.dart`: `marginReport`/`stockValuation` tidak lagi memakai `ROUND(.../1000.0)` |
| F10-3 | Snapshot/feed | Selesai | `sync/sync_service.dart`: log `sync.feed.page` (sejak, jumlah envelope, diterapkan, konflik, latest, ms), `sync.snapshot.create` (panjang ciphertext, seq, ms), dan `sync.snapshot.apply` (panjang ciphertext, diterapkan, ms) lewat `AppLog` untuk mengukur sync besar |

Catatan F10: pembulatan uang tetap sen penuh; tidak ada perubahan format
tampilan. Index bersifat aditif dan aman dijalankan berulang.

## 13. Berkas yang berubah

F0 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/audit_service.dart` (baru)
- `lib/data/app_database.dart`
- `lib/data/backup_manifest.dart`
- `lib/data/backup_service.dart`
- `lib/data/note_sync.dart`
- `lib/data/sale_return_service.dart`
- `lib/data/session_service.dart`
- `lib/sync/sync_service.dart`
- `lib/ui/entry_gate.dart`
- `lib/ui/home_shell.dart`
- `lib/ui/pin_gate.dart`
- `lib/ui/screens/settings_screen.dart`
- `lib/ui/startup_recovery.dart`
- `lib/ui/widgets/sync_status_banner.dart` (baru)

Verifikasi: `dart analyze lib` → tidak ada masalah.

F1 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/core/app_config.dart`
- `lib/data/schema.dart`
- `lib/data/app_database.dart`
- `lib/data/schema_migrations.dart`
- `lib/data/diagnostics_service.dart`
- `lib/ui/screens/diagnostics_screen.dart`

F2 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/approval_service.dart`
- `lib/data/price_rules.dart`
- `lib/data/app_database.dart`
- `lib/data/order_service.dart`
- `lib/data/purchase_service.dart`
- `lib/data/schema.dart`
- `lib/data/schema_migrations.dart`
- `lib/data/receipt_service.dart`
- `lib/data/models.dart`
- `lib/ui/screens/pos_screen.dart`
- `lib/ui/screens/reports_screen.dart`

Verifikasi F2: `dart analyze lib` → tidak ada masalah.

F3 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/core/dates.dart`
- `lib/core/money.dart`
- `lib/core/quantity.dart` (tidak berubah; dipakai validasi satuan)
- `lib/data/app_database.dart`
- `lib/data/models.dart`
- `lib/data/nota_adjustment_service.dart`
- `lib/data/pajak_report_service.dart`
- `lib/data/price_rules.dart`
- `lib/data/purchase_service.dart`
- `lib/data/receipt_service.dart`
- `lib/data/schema.dart`
- `lib/data/schema_migrations.dart`
- `lib/data/store_settings.dart`
- `lib/sync/sync_service.dart`
- `lib/ui/screens/pos_screen.dart`
- `lib/ui/screens/store_settings_screen.dart`

Verifikasi F3: `dart analyze lib` → tidak ada masalah.

F4 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/access_control.dart`
- `lib/data/account_service.dart`
- `lib/data/app_database.dart`
- `lib/data/opname_service.dart`
- `lib/data/sale_return_service.dart`
- `lib/data/stock_ledger.dart`
- `lib/sync/sync_conflict_rules.dart`
- `lib/ui/pin_gate.dart`
- `lib/ui/screens/pos_screen.dart`
- `lib/ui/screens/premium_screen.dart`
- `lib/ui/screens/stock_screen.dart`

Verifikasi F4: `dart analyze lib` → tidak ada masalah. Uji belum dijalankan.

F5 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/app_database.dart`
- `lib/data/models.dart`
- `lib/data/owner_summary_service.dart`
- `lib/sync/sync_scheduler.dart`
- `lib/sync/sync_service.dart`
- `lib/ui/home_shell.dart`
- `lib/ui/screens/history_screen.dart`
- `lib/ui/widgets/sync_status_banner.dart`

Verifikasi F5: `dart analyze lib` → tidak ada masalah. Uji belum dijalankan.

F6 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/app_database.dart`
- `lib/data/feature_flags.dart`
- `lib/data/note_sync.dart`
- `lib/data/order_service.dart`
- `lib/data/sale_return_service.dart`
- `lib/sync/compensation_service.dart` (baru)
- `lib/sync/protocol.dart`
- `lib/sync/relay_client.dart`
- `lib/sync/snapshot_sync.dart`
- `lib/sync/sync_conflict_rules.dart`
- `lib/sync/sync_scheduler.dart`
- `lib/sync/sync_service.dart`
- `lib/ui/screens/orders_screen.dart`
- `lib/ui/screens/sync_conflicts_screen.dart`
- `lib/ui/widgets/sync_status_banner.dart`

Relatif `relay/`:

- `lib/config.dart`
- `lib/db.dart`
- `lib/server.dart`

Verifikasi F6: `dart analyze lib` pada `pusatkupos/` dan `relay/` → tidak ada
masalah. Uji F6-6 belum dijalankan.

F7 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/core/app_config.dart` (URL arsip terpisah)
- `lib/core/dates.dart` (`monthId`)
- `lib/data/app_database.dart` (merge stub arsip, laporan retur arsip)
- `lib/data/archive_return_service.dart` (baru)
- `lib/data/models.dart` (`purged`, `archiveDocId`)
- `lib/data/period_closing_service.dart` (baru; snapshot + auto close)
- `lib/data/purge_service.dart` (baru; flag mati)
- `lib/data/schema.dart` (v16, tabel arsip/retur arsip, snapshot)
- `lib/data/schema_migrations.dart` (migrasi v16 aditif)
- `lib/sync/archive_client.dart` (baru)
- `lib/sync/archive_service.dart` (baru; bundle, upload, cari, buka, ekspor)
- `lib/sync/sync_scheduler.dart` (arsip, tutup buku, purge)
- `lib/sync/sync_service.dart` (entitas `archive_return`, payload tutup buku)
- `lib/ui/screens/archive_search_screen.dart` (baru)
- `lib/ui/screens/history_screen.dart` (pencarian server + baris arsip)
- `lib/ui/screens/reports_screen.dart` (navigasi bulan + laporan snapshot)
- `lib/ui/owner_viewer.dart` (keluarkan stub arsip dari ringkasan owner)

Relatif `relay/`:

- `lib/config.dart` (kuota arsip)
- `lib/db.dart` (skema arsip)
- `lib/server.dart` (endpoint arsip, CORS, kuota, receipt)
- `OPS.md` (dua layanan, snapshot/offsite, RPO/RTO, CORS, kuota)

Verifikasi F7: `dart analyze lib` pada `pusatkupos/` dan `relay/` → tidak ada
masalah. Uji F7-6 dan uji restore F7-7 belum dijalankan.

F8 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/app_database.dart` (viewer sync write, katalog berizin)
- `lib/data/access_control.dart` (`employeeRole`)
- `lib/data/account_service.dart` (validasi peran akun + remote)
- `lib/data/employee_auth_service.dart` (sanitasi peran, hapus flag dicabut)
- `lib/data/pin_service.dart` (hash PIN hanya di SecureStore)
- `lib/data/device_service.dart` (audit revoke)
- `lib/data/escrow_service.dart` (escrow semua toko)
- `lib/data/owner_access_api.dart` (paginasi perangkat)
- `lib/data/schema_migrations.dart` (v17 `key_version`)
- `lib/sync/relay_client.dart` (`key_version`, paginasi perangkat)
- `lib/sync/sync_service.dart` (rotasi, distribusi kunci, mode dicabut)
- `lib/sync/snapshot_sync.dart` (sanitasi peran snapshot)
- `lib/ui/owner_viewer.dart` (penulisan ringkasan lewat zona sync)
- `lib/ui/screens/escrow_screen.dart` (baru)
- `lib/ui/screens/premium_screen.dart` (rotasi/selaraskan kunci, label versi)
- `lib/ui/screens/settings_screen.dart` (entri escrow)
- `lib/ui/widgets/sync_status_banner.dart` (banner perangkat dicabut)
- `README.md` (matriks platform + at-rest)

Relatif `relay/`:

- `lib/config.dart` (`allowedOrigins`)
- `lib/db.dart` (`key_version`, `device_events`)
- `lib/server.dart` (versi kunci, audit perangkat, CORS ketat, `device_revoked`)
- `.env.example` (`RELAY_ALLOWED_ORIGINS`, `RELAY_MIN_PROTOCOL`)
- `OPS.md` (§5 rotasi kunci/escrow, §10 CORS, §11 metadata/blind index)

Verifikasi F8: `dart analyze lib` pada `pusatkupos/` dan `relay/` → tidak ada
masalah. Uji F8-8 belum dijalankan.

F9 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/core/startup_diagnosis.dart` (baru)
- `lib/core/startup.dart` (log diagnosis sebelum karantina)
- `lib/ui/startup_recovery.dart` (kartu diagnosis awal)
- `lib/ui/error_messages.dart` (baru; pemetaan error actionable)
- `lib/data/print_queue_service.dart` (baru; antrean cetak + retry)
- `lib/data/schema.dart` (`print_jobs` + index)
- `lib/data/schema_migrations.dart` (migrasi v18)
- `lib/data/app_database.dart` (schema v18 untuk antrean cetak; v19 menyusul di F10)
- `lib/ui/receipt_dialog.dart` (status cetak + cetak ulang)
- `lib/sync/archive_service.dart` (`status()` untuk health surface)
- `lib/ui/widgets/health_surface.dart` (baru)
- `lib/ui/home_shell.dart` (pasang health strip)
- `lib/ui/widgets/sync_status_banner.dart` (pesan error pengguna)
- `lib/ui/screens/escrow_screen.dart` (pesan error pengguna)
- `lib/ui/screens/archive_search_screen.dart` (pesan error pengguna)

F10 menyentuh berkas berikut (relatif `pusatkupos/`):

- `lib/data/app_database.dart` (`roundDivideSql`, `marginRevenueSql`, modal integer, agregasi laporan)
- `lib/data/purchase_service.dart` (margin & valuasi stok integer)
- `lib/data/schema.dart` (`createPerformanceIndexes`)
- `lib/data/schema_migrations.dart` (migrasi v19)
- `lib/sync/sync_service.dart` (metrik feed/snapshot)

Verifikasi F9/F10: `dart analyze lib` pada `pusatkupos/` dan `relay/` → tidak
ada masalah. Uji F9-4 belum dijalankan.
