# 06 — SYNC & MULTI-DEVICE AUDIT

Ruang lingkup: sinkronisasi otomatis, eventual consistency, duplikasi, double decrement stok, stok basi, transaksi belum tersinkron, tablet mekanik offline, retry, sync terputus, aplikasi ditutup saat sync, divergensi lokal/server. Asumsi operasional: **1 toko = 1 kasir**; tablet mekanik adalah perangkat pendamping baca yang boleh memperbarui status, bukan kasir kedua.

---

## 1. Arsitektur Sync Nyata

### 1.1 Envelope
- Payload dienkripsi AES-GCM dengan store key; envelope ditandatangani Ed25519 perangkat.
- Metadata: store, device, seq, HLC, entity, action, entity id, key id.
- Server memverifikasi tanda tangan, idempotensi id, dan urutan seq; menyimpan ciphertext.
- Klien hanya ack setelah server menerima; apply di perangkat tujuan hanya setelah dekripsi.

### 1.2 Urutan dan konflik
- HLC (wall/counter) menjadi urutan logis; perangkat memiliki seq.
- Server menolak seq yang melompat/duplikat; klien memundurkan ack ke `blockedSeq − 1` bila ada celah.
- `applyNotePayloadTx` idempoten terhadap nota/pembayaran/retur.
- Konflik dicatat (mis. `no_nota` bentrok, `void_setelah_retur`, `stok_negatif`).

### 1.3 Bootstrap dan snapshot
- Perangkat baru memakai snapshot terenkripsi per toko + feed setelah cursor.
- Snapshot berisi state master dan nota terbaru; tidak menyimpan riwayat penuh.
- Riwayat yang sudah dipangkas memicu bootstrap snapshot (bukan pemulihan log).

### 1.4 Retensi relay
- Envelope dipangkas hanya ketika **semua perangkat aktif mengakui** antrean.
- Snapshot disimpan satu per toko (terbaru).
- Tidak ada arsip berbasis waktu dan tidak ada API pencarian server.

---

## 2. Registry Temuan

### SYN-01 — Satu perangkat offline non-revoked memblokir pruning; storage penuh menghentikan pengiriman
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP / PERFORMANCE ISSUE
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/server.dart:1050](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart#L1050), [relay/lib/sync_round.dart:41](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/sync_round.dart#L41), [relay/lib/config.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/config.dart)
- **Fungsi/Kelas:** Pruning envelope; `sync_round`
- **Implementasi:** Pruning menunggu ack seluruh perangkat aktif. Perangkat yang hilang tetapi belum dicabut menahan semua envelope. Batas penyimpanan default 256 MB; saat penuh server mengembalikan 413 dan klien berhenti mengirim.
- **Penyebab:** Retensi berbasis ack minimum, tanpa kebijakan perangkat mati.
- **Dampak:** Database relay membengkak; sync seluruh toko berhenti; nota baru tetap lokal (aman) tetapi tidak pernah sampai ke tablet/server.
- **Skenario:** SC-02.
- **Rekomendasi:** Kebijakan pencabutan perangkat otomatis setelah N hari tidak aktif; alert storage; pruning berbasis waktu dengan snapshot sebagai fallback; metrik backlog.
- **Dependensi:** SYN-05, SEC-12.

### SYN-02 — Snapshot hanya state terbaru; tidak ada arsip riwayat
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart), [relay/bin/relay.dart:368](file:///C:/Users/Administrator/Downloads/posapk/relay/bin/relay.dart#L368)
- **Fungsi/Kelas:** Snapshot/feed relay
- **Implementasi:** Relay menyimpan satu snapshot per toko dan envelope sampai di-ack. Setelah pruning, riwayat hanya ada di perangkat yang sudah menerimanya. Tidak ada tabel arsip dokumen.
- **Penyebab:** Relay dirancang sebagai kanal sinkronisasi, bukan arsip.
- **Dampak:** Perangkat baru tidak dapat mengunduh nota lama di luar snapshot; skenario SC-04 tidak mungkin.
- **Rekomendasi:** Tambahkan arsip ciphertext per dokumen (bukan envelope sementara) dengan indeks metadata, atau nyatakan arsip sebagai di luar lingkup.
- **Dependensi:** SYN-03, SEC-16.

### SYN-03 — Tidak ada retensi berbasis waktu untuk envelope
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Kebijakan sudah diputuskan; implementasi belum ada
- **Lokasi:** [relay/bin/relay.dart:368](file:///C:/Users/Administrator/Downloads/posapk/relay/bin/relay.dart#L368)
- **Fungsi/Kelas:** `_maintenance`
- **Implementasi:** Maintenance memangkas token/enroll/invite yang kedaluwarsa dan melaporkan backlog. Envelope hanya dipangkas saat semua perangkat ack. Tidak ada TTL.
- **Keputusan pemilik (9 Nov 2026):** data lokal dihapus fisik setelah 1 tahun; data lainnya disimpan di VPS. Ini menuntut arsip ciphertext per dokumen di relay, bukan hanya envelope sementara.
- **Dampak:** Backlog tak terbatas; biaya penyimpanan naik; tidak ada jaminan ketersediaan riwayat lama.
- **Rekomendasi:** Bangun arsip ciphertext + kebijakan retensi 1 tahun; purge lokal hanya setelah arsip terverifikasi.
- **Dependensi:** Keputusan bisnis #1, SYN-02.

### SYN-04 — Kepercayaan snapshot bergantung pada daftar perangkat relay; kesegaran HLC tidak diperiksa
- **Severity:** MEDIUM
- **Kategori:** POTENTIAL DEFECT / SECURITY WEAKNESS
- **Status:** NEEDS VALIDATION (tergantung model ancaman)
- **Lokasi:** [sync_service.dart:346](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L346)
- **Fungsi/Kelas:** `bootstrapNow`/`_bootstrapNowBody`
- **Implementasi:** Snapshot diverifikasi terhadap kunci perangkat yang terdaftar di relay. Tidak ada pemeriksaan bahwa snapshot lebih baru dari state lokal berdasarkan HLC sebelum menimpa.
- **Penyebab:** Relay dianggap tepercaya untuk urutan snapshot.
- **Dampak:** Relay yang dikompromikan/dioperasikan salah dapat memaksa rollback state perangkat.
- **Rekomendasi:** Sertakan HLC/versi snapshot yang ditandatangani beberapa perangkat atau owner key; tolak snapshot yang lebih lama dari state lokal.
- **Dependensi:** SEC-12, SEC-13.

### SYN-05 — Penambahan perangkat baru memerlukan pembagian store key manual
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP / NEEDS CLARIFICATION
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart), [settings_screen.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/settings_screen.dart)
- **Fungsi/Kelas:** Enroll perangkat; distribusi kunci
- **Implementasi:** Store key dibungkus untuk perangkat melalui aksi owner (mis. tombol/kode). Tidak ada mekanisme otomatis saat perangkat baru login.
- **Penyebab:** Tidak ada escrow kunci pusat (lihat SEC-13).
- **Dampak:** Onboarding tablet mekanik gagal tanpa owner; bila owner tidak ada, riwayat tidak dapat dibuka.
- **Rekomendasi:** Alur enrollment dengan persetujuan owner + kode sekali pakai; dokumentasikan prosedur.
- **Dependensi:** SEC-13.

### SYN-06 — Jendela deduplikasi `applied_deltas` menyusut
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart:5299](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L5299)
- **Fungsi/Kelas:** `cleanupSyncHistory`
- **Implementasi:** `applied_deltas` dipangkas >90 hari dan dibatasi 20.000 baris terbaru; `device.seq_floor` dicatat.
- **Penyebab:** Kontrol ukuran DB.
- **Dampak:** Envelope yang sangat terlambat (>90 hari atau di luar 20k) dapat diterapkan ulang bila idempotensi dokumen tidak menangkapnya. Idempotensi tingkat dokumen sebagian besar menutup ini.
- **Rekomendasi:** Pastikan setiap entity memiliki kunci idempoten permanen; jangan hanya mengandalkan `applied_deltas`.
- **Dependensi:** —

### SYN-07 — `data_request`/`data_response` bukan pencarian arsip
- **Severity:** MEDIUM
- **Kategori:** MISSING FEATURE
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_service.dart:2163](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2163), [sync_service.dart:5073](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L5073)
- **Fungsi/Kelas:** `enqueueDataRequest`/`enqueueDataResponse`; handler relay
- **Implementasi:** Mekanisme ini mengirim ringkasan harian untuk rekonsiliasi, bukan kueri pencarian. Tidak ada parameter pencarian nota/pelanggan/tanggal.
- **Penyebab:** Fitur arsip belum dibangun.
- **Dampak:** SC-04 tidak dapat dipenuhi; aplikasi tidak dapat mengambil nota 2 tahun dari server.
- **Rekomendasi:** Bangun API arsip terenkripsi + indeks pencarian (lihat SEC-16); atau nyatakan SC-04 sebagai di luar lingkup.
- **Dependensi:** SYN-02, SEC-16.

### SYN-08 — Kegagalan sync tidak terlihat per dokumen
- **Severity:** MEDIUM (kanonik: OFF-03)
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [sync_scheduler.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_scheduler.dart)
- **Implementasi:** Error ditelan ke `sync.last_error`; tidak ada status per nota.
- **Dampak:** Pengguna tidak tahu nota belum sampai ke perangkat lain.
- **Rekomendasi:** Lihat OFF-03.

### SYN-09 — Perubahan status dari tablet mekanik tidak memiliki audit aktor yang konsisten
- **Severity:** LOW
- **Kategori:** NEEDS VALIDATION
- **Status:** Belum dapat dibuktikan menyeluruh dari kode
- **Lokasi:** Modul work order/status ([order_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/order_service.dart))
- **Implementasi:** Status diperbarui melalui service dengan aktor; sebagian jalur mencatat `operator`, sebagian tidak. Perlu pengujian per status.
- **Dampak:** Sulit membuktikan siapa mengubah status pada tablet mekanik.
- **Rekomendasi:** Standarkan audit aktor untuk semua transisi status.
- **Dependensi:** ARC-04.

---

## 3. Uji Multi-Device

| Uji | Hasil | Catatan |
|---|---|---|
| Kasir offline membuat nota | PASS | Lokal + outbox |
| Tablet mekanik menerima nota setelah sync | PASS | Feed terenkripsi |
| Double apply nota | PASS | Idempotensi |
| Double decrement stok | PASS di jalur normal | Movement key |
| Stok kasir basi vs server | **PARTIAL** | Default opsi B: izinkan dengan konfirmasi, catat negatif/konflik; bukan blokir diam-diam |
| Aplikasi ditutup saat sync | PASS | Cursor/ack hanya setelah apply; envelope diulang |
| Retry setelah timeout | PASS | Idempotensi |
| Void setelah retur | **FAIL** | INV-03 |
| Opname multi-device | **FAIL** | INV-01 |
| Perangkat mati menghalangi pruning | **FAIL** | SYN-01 |
| Divergensi lokal/server terdeteksi | PARTIAL | Konflik dicatat, tidak selalu diselesaikan |

---

## 4. Skenario SC-02 — Verdict

**Status: PARTIAL / BERISIKO TINGGI.**

Yang berjalan: eventual consistency untuk nota normal, idempotensi, retry, ack setelah apply, dan perlindungan terhadap duplikasi.

Yang tidak memenuhi: tidak ada jaminan data belum tersinkron selamat dari logout/restore; kebijakan void-retur berbeda antar jalur; opname dapat memacetkan antrean; satu perangkat offline dapat menghentikan retensi; tidak ada status per dokumen.

Karena asumsi **1 kasir + 1 tablet pendamping**, risiko dua kasir menulis bersamaan rendah, tetapi risiko tablet mekanik mengubah status saat kasir offline tetap ada dan belum diaudit penuh (SYN-09).
