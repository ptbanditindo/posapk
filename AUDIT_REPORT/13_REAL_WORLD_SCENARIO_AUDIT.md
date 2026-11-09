# 13 — REAL-WORLD SCENARIO AUDIT

Matriks status: **PASS**, **PARTIAL**, **FAIL**, **NOT IMPLEMENTED**, **NEEDS CLARIFICATION**, **NEEDS VALIDATION**.
PASS hanya diberikan bila kode mendukung seluruh skenario, bukan sebagian.

---

## SC-01 — Penjualan Offline dengan Harga Negosiasi (350.000 → 325.000)

### Kode yang terlibat
- [pos_screen.dart:1680](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1680) — dialog jasa.
- [app_database.dart:1793](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1793) — `createTransaction`.
- [price_rules.dart:87](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/price_rules.dart#L87) — alokasi.
- [note_sync.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart) — payload sync.
- [receipt_service.dart:229](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/receipt_service.dart#L229) — struk.
- [app_database.dart:4198](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L4198) — `belowPriceSales`.

### Alur aktual
1. Kasir offline membuka POS.
2. Untuk menegosiasi jasa, kasir memakai jasa **non-katalog** karena harga katalog `readOnly` ([pos_screen.dart:1688](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/pos_screen.dart#L1688)). `JobDraft` mengirim `hargaTerdaftarCents = 0` dan `hargaCents = 325.000`.
3. `createTransaction` melihat `hargaTerdaftarCents = 0` → **melewati** pemeriksaan `permissionChangeServicePrice`.
4. `PriceLine` dibangun dengan `hargaTerdaftar: job.hargaCents` = 325.000 → subtotal 325.000, final 325.000.
5. Nota, baris, pembayaran, ledger stok, dan outbox ditulis dalam satu transaksi SQLite.
6. Payload sync mengekspor `harga_final = 325.000`; server menyimpan ciphertext.
7. Struk mencetak 325.000; riwayat menampilkan detail nota.

### Kebutuhan vs kenyataan
| Kebutuhan | Status | Bukti |
|---|---|---|
| Harga normal 350.000 tersimpan | **TIDAK** | Tidak ada kolom/argumen harga acuan untuk jasa bebas; UI mengirim 0 |
| Harga final 325.000 tersimpan lokal | **YA** | `harga_final`, subtotal |
| Harga final dipakai subtotal/total | **YA** | `PriceRules.allocate`, `bruto` |
| Harga final dipakai pembayaran | **YA** | total dari snapshot pajak |
| Harga final dipakai struk | **YA** | Baris mencetak 325.000 |
| Harga final dipakai laporan | **PARTIAL** | Margin memakai final; modal jasa bebas 0; laporan harga bawah tidak mendeteksi |
| Harga final tidak ditimpa saat sync | **YA** | Payload membawa final; penerima tidak menulis ulang harga |
| Tidak berubah saat harga master berubah | **YA** | Snapshot baris + trigger |
| Persetujuan/audit nego | **TIDAK** | Izin dilewati; tidak ada alasan/approver |

### Temuan terkait
TRX-01 (HIGH), TRX-02 (MEDIUM), TRX-06, TRX-08, REP-01.

### Risiko bisnis
Harga final benar dan tidak hilang, tetapi pemilik tidak dapat membuktikan bahwa 325.000 adalah nego dari 350.000, tidak dapat melihat siapa menyetujui, dan laporan harga bawah tidak menangkapnya. Modal jasa bebas 0 membuat laba jasa terlihat penuh.

### Status akhir: **PARTIAL**

---

## SC-02 — Sync Otomatis & Multi-Device (Kasir + Tablet Mekanik)

### Kode yang terlibat
- [sync_service.dart:2289](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2289) — siklus sync.
- [note_sync.dart:400](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/note_sync.dart#L400) — penerapan nota.
- [opname_service.dart:171](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/opname_service.dart#L171) — opname.
- [entry_gate.dart:97](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/entry_gate.dart#L97) — logout.
- [backup_service.dart:1015](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L1015) — restore.
- Relay: [server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart), [sync_round.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/sync_round.dart).

### Alur aktual
1. Kasir offline membuat nota; outbox lokal.
2. Tablet mekanik juga offline; status work order diubah lokal.
3. Saat online, kasir mengirim envelope terenkripsi + bertanda tangan; relay memverifikasi id/seq/tanda tangan, menyimpan ciphertext.
4. Tablet menarik feed, mendekripsi, menerapkan nota secara idempoten; ack setelah apply.
5. Jika sync terputus, cursor tidak maju melewati envelope yang gagal; retry mengulang envelope yang sama tanpa duplikasi.
6. Aplikasi ditutup saat sync: envelope diulang dari cursor; apply idempoten.

### Kebutuhan vs kenyataan
| Kebutuhan | Status | Bukti |
|---|---|---|
| Eventual consistency | **YA** | Feed + HLC + ack |
| Tidak ada duplikasi nota | **YA** | `request_id`, sync id, idempotensi apply |
| Tidak ada double decrement stok | **YA** di jalur normal | Movement key `sale-<partSync>` |
| Menangani stok basi | **PARTIAL** | Default B: izinkan + konfirmasi; remote mencatat konflik |
| Menangani transaksi belum tersinkron | **TIDAK** saat logout/restore | SEC-02, SEC-04 |
| Tablet offline lalu mengejar | **YA** | Feed + snapshot |
| Retry tanpa duplikasi | **YA** | Idempotensi |
| Sync terputus di tengah | **YA** | Cursor/ack |
| Aplikasi ditutup saat sync | **YA** | Envelope diulang |
| Divergensi lokal/server terdeteksi | **PARTIAL** | Konflik dicatat, tidak selalu diselesaikan |
| Void setelah retur | **TIDAK** | INV-03 (double refund) |
| Opname multi-device | **TIDAK** | INV-01 |
| Retensi/pruning | **TIDAK** | Perangkat offline memblokir (SYN-01) |

### Temuan terkait
SEC-02, SEC-04, INV-01, INV-03, SYN-01, SYN-04, OFF-03.

### Risiko bisnis
Skenario normal berjalan, tetapi ada tiga jalur kehilangan/kerusakan: logout/restore menghapus data pending; void-retur membayar refund ganda; opname memacetkan antrean. Untuk 1 kasir + 1 tablet, risiko konkurensi rendah, tetapi risiko operasional tetap tinggi.

### Status akhir: **PARTIAL / BERISIKO TINGGI**

---

## SC-03 — Riwayat Lokal Maksimum 1 Tahun

### Kode yang terlibat
- [app_database.dart:3397](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3397) — `listRecords`.
- [history_screen.dart:53](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart#L53) — UI.
- [sync_service.dart:5299](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L5299) — cleanup.
- [relay/bin/relay.dart:368](file:///C:/Users/Administrator/Downloads/posapk/relay/bin/relay.dart#L368) — maintenance.

### Alur aktual
1. Tidak ada kode yang menghapus nota lokal berdasarkan umur. Cleanup hanya memangkas outbox terkirim >90 hari dan `applied_deltas`.
2. UI riwayat memanggil `limit: 200` tanpa paginasi; nota ke-201 dan seterusnya tidak tampil.
3. Tidak ada filter tanggal; pencarian hanya nomor nota/nama pelanggan.
4. Di relay, envelope dipangkas setelah semua perangkat ack; tidak ada arsip berbasis waktu. Snapshot hanya state terbaru.
5. Nota yang belum tersinkron **tidak** dihapus oleh cleanup rutin; tetapi dapat hilang lewat logout/restore.

### Kebutuhan vs kenyataan
| Kebutuhan | Status |
|---|---|
| Riwayat 1 tahun dapat diakses | **TIDAK** (UI 200 baris) |
| Membedakan batas tampilan vs hapus fisik | **KEBIJAKAN SUDAH DIPUTUSKAN**: hapus fisik lokal, arsip VPS |
| Transaksi belum tersinkron tidak dihapus karena umur | **YA** untuk cleanup; **TIDAK** untuk logout/restore |
| Arsip server | **TIDAK ADA** — harus dibangun sebelum purge |
| Kebijakan hapus vs sembunyikan | **DIPUTUSKAN**: hapus fisik lokal setelah 1 tahun |

### Keputusan pemilik (9 Nov 2026)
Hapus fisik data lokal setelah 1 tahun; data lainnya disimpan di server VPS. Prasyarat implementasi: arsip ciphertext per dokumen di VPS, verifikasi sudah tersinkron, outbox kosong, dan purge tidak menyentuh arsip VPS. Tanpa arsip VPS, purge akan menghilangkan data.

### Temuan terkait
FLW-02, SYN-02, SYN-03, SEC-02, Keputusan bisnis #1.

### Risiko bisnis
Data sebenarnya masih ada di SQLite (kecuali dihapus manual/logout), tetapi pengguna tidak dapat menemukannya. Kebijakan retensi sudah ditetapkan, namun kode purge dan arsip VPS belum ada; menyatakan "riwayat 1 tahun" saat ini belum didukung implementasi.

### Status akhir: **MISSING FEATURE** (kebijakan sudah diputuskan, implementasi belum ada)

---

## SC-04 — Pencarian Nota 2 Tahun Melalui VPS

### Kode yang terlibat
- [history_screen.dart:53](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/screens/history_screen.dart#L53).
- [app_database.dart:3397](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L3397).
- [sync_service.dart:2163](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart#L2163) — data request/response.
- [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart) — tidak ada route pencarian.
- E2EE: ciphertext + metadata.

### Alur aktual
1. Pengguna mencari di riwayat lokal. `LIKE` hanya pada `no_nota`/nama, maksimum 200 baris, tanpa paginasi/tanggal.
2. Tidak ada tombol/layanan "cari di server".
3. `data_request`/`data_response` adalah ringkasan rekonsiliasi harian, bukan kueri pencarian.
4. Relay tidak menyimpan plaintext dan tidak memiliki indeks pencarian; snapshot hanya state terbaru. Envelope lama sudah dipangkas setelah ack.
5. Karena itu, nota 2 tahun yang tidak ada di 200 baris lokal **tidak dapat ditemukan**.

### Kebutuhan vs kenyataan
| Kebutuhan | Status |
|---|---|
| Cari lokal dulu | **PARTIAL** (terbatas) |
| Fallback ke arsip VPS | **TIDAK ADA** |
| Bekerja di bawah E2EE | **TIDAK ADA mekanisme** |
| Dekripsi lokal hasil pencarian | **TIDAK ADA** |
| Tampilkan struk lama | Tidak dapat diuji karena data tidak dapat diambil |
| Pencarian nomor/pelanggan/tanggal | Hanya nomor/nama; tanpa tanggal |
| Paginasi/performa | **TIDAK ADA** paginasi |
| Otorisasi pencarian | Tidak ada API |
| Not-found/offline | Hanya perilaku lokal |

### Temuan terkait
FLW-02, SYN-02, SYN-03, SYN-07, SEC-16, ARC-06.

### Risiko bisnis
Klaim pencarian arsip 2 tahun tidak dapat dipenuhi. Untuk memenuhinya, dibutuhkan keputusan retensi, arsip ciphertext, dan indeks pencarian non-plaintext; tanpa itu, E2EE dan pencarian server saling bertentangan.

### Status akhir: **NOT IMPLEMENTED / MISSING FEATURE**

---

## SC-05 — E2EE End-to-End

### Kode yang terlibat
- [sync_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart) — enkripsi, pembungkusan kunci, enroll.
- [relay/lib/server.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/server.dart) — ingest/feed/snapshot.
- [relay/lib/auth_rules.dart](file:///C:/Users/Administrator/Downloads/posapk/relay/lib/auth_rules.dart).
- [session_recovery.dart:32](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/ui/session_recovery.dart#L32).
- [backup_service.dart:257](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/backup_service.dart#L257).

### Alur aktual
1. Store key dibuat acak; dibungkus per perangkat dengan X25519 + HKDF; payload dienkripsi AES-GCM; envelope ditandatangani Ed25519.
2. Relay memverifikasi tanda tangan/id/seq, menyimpan ciphertext + metadata. Tidak ada jalur membaca plaintext.
3. Perangkat penerima mendekripsi lokal lalu menerapkan.
4. Backup memakai AES-256-GCM + PBKDF2 210k; auto passphrase disimpan di SecureStore.

### Kebutuhan vs kenyataan
| Kebutuhan | Status | Bukti |
|---|---|---|
| Server tidak membaca nama/telepon/item/harga/nominal/catatan | **YA** | Ciphertext |
| Enkripsi sebelum kirim | **YA** | Encrypt → sign |
| Ciphertext di transport & storage | **YA** | Envelope |
| Integritas & replay | **YA** | GCM + signature + id/seq |
| Device auth/enrollment | **YA** (manual) | Enroll + wrap |
| Rotasi kunci | **TIDAK** | SEC-12 |
| Recovery kunci | **DIPUTUSKAN via akun Gmail; escrow belum ada** | SEC-13 |
| Metadata leakage minimal | **TIDAK** | SEC-16 |
| Server hanya auth/envelope/storage | **YA** | Tidak ada kalkulasi bisnis |
| Backup terenkripsi | **YA** | Backup service |
| Pencarian arsip di server | **TIDAK** | Tanpa blind index |
| Kebijakan recovery | **DIPUTUSKAN (tingkat tinggi)**: akun Gmail | Perlu desain escrow + 2FA |

### Temuan terkait
SEC-12, SEC-13, SEC-14, SEC-15, SEC-16, SYN-05.

### Risiko bisnis
Kerahasiaan isi terhadap server terpenuhi. Namun E2EE belum operasional: kehilangan kunci = kehilangan riwayat; perangkat dicabut tetap memegang kunci; metadata membocorkan pola; dan arsip/pencarian belum mungkin. Kebijakan recovery sudah diputuskan memakai akun Gmail, tetapi mekanisme escrow-nya belum ada. Klaim "E2EE penuh" hanya valid untuk kerahasiaan isi saat transit/penyimpanan, bukan untuk lifecycle kunci.

### Status akhir: **PARTIAL + NEEDS VALIDATION** (kebijakan recovery sudah diputuskan, desain escrow belum)

---

## Ringkasan Matriks

| Skenario | Status | Temuan utama |
|---|---|---|
| SC-01 | **PARTIAL** | TRX-01, TRX-02, TRX-06 |
| SC-02 | **PARTIAL / BERISIKO TINGGI** | SEC-02, SEC-04, INV-01, INV-03, SYN-01 |
| SC-03 | **MISSING FEATURE** (kebijakan sudah diputuskan) | FLW-02, SYN-02, keputusan #1 |
| SC-04 | **NOT IMPLEMENTED / MISSING FEATURE** | SYN-07, SEC-16, ARC-06 |
| SC-05 | **PARTIAL + NEEDS VALIDATION** | SEC-12, SEC-13, SEC-16, keputusan #2 |

---

## Lampiran — Penjelasan Stok Lokal vs Server (Keputusan #3)

### Contoh sederhana
Kasir offline mencatat **stok oli = 2**. Kenyataannya:
- barang masuk 3 botol belum tersinkron, sehingga server mencatat **5**; atau
- mekanik di tablet sudah memakai 3 botol, sehingga server mencatat **2** tetapi kasir masih melihat **5**.

Kasir lalu menjual **3 botol**. Pertanyaannya: apa yang harus dilakukan aplikasi?

| Pilihan | Perilaku | Kelebihan | Kekurangan |
|---|---|---|---|
| **A. Blokir** (perilaku lokal saat ini) | Nota ditolak: "Stok tidak cukup" | Stok tidak pernah negatif | Penjualan hilang padahal barang mungkin ada di rak |
| **B. Izinkan dengan konfirmasi** (rekomendasi) | Kasir melihat "stok sistem 2, jual 3?", lalu lanjut; stok lokal menjadi −1 dan ditandai perlu dicek | Penjualan tetap jalan; selisih tercatat | Perlu disiplin opname; stok negatif harus terlihat |
| **C. Ikuti server saat online** | Saat online, stok server yang dipakai; saat offline, stok lokal | Data lebih segar saat online | Butuh kueri stok server; offline tetap basi |
| **D. Wajib PIN owner** | Penjualan di atas stok hanya bisa dengan persetujuan owner | Kontrol ketat | Kasir tidak bisa melayani saat owner tidak ada |

### Rekomendasi audit
Untuk asumsi **1 toko = 1 kasir**, pilihan **B** paling seimbang: transaksi fisik yang sudah terjadi tidak dibatalkan, tetapi selisih tidak hilang diam-diam. Nota harus mencatat `stok_negatif`/`stok_basi`, muncul di laporan, dan memicu opname. Pilihan A aman untuk integritas stok tetapi berpotensi kehilangan penjualan; pilihan C menambah ketergantungan jaringan; pilihan D terlalu berat untuk operasional harian.

**Status keputusan:** pemilik tidak memiliki preferensi; audit memakai **opsi B sebagai default sementara**. Perubahan ke A/C/D dapat dilakukan tanpa mengubah skema, hanya mengubah aturan service + UI.

**Syarat minimum bila opsi B dipakai:**
1. Dialog konfirmasi menampilkan stok sistem, qty yang diminta, dan dampak negatif.
2. Nota menyimpan alasan/flag `stok_negatif` dan `stok_basi`.
3. Server menerima tetapi mencatat konflik; tidak menimpa data lokal yang belum terkirim.
4. Laporan opname menampilkan semua stok negatif dan selisih terhadap server.
5. Stok negatif harus diselesaikan (opname) dalam batas waktu yang disepakati.
