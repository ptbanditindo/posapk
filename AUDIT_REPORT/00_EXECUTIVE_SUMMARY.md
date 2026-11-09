# 00 — EXECUTIVE SUMMARY

**Proyek:** PusatkuPOS (Flutter client `pusatkupos/` + relay Dart `relay/`)
**Jenis audit:** Read-only forensic audit — source code, business logic, integritas database, keamanan, arsitektur
**Tanggal audit:** 9 November 2026
**Basis kode:** commit `07f3ff1` (branch `main`)
**Metode:** Penelusuran kode nyata UI → service → repository → SQLite → relay → PostgreSQL. Tidak menggunakan nama fungsi, komentar, dokumentasi, atau test sebagai bukti kebenaran. Tidak ada file sumber yang diubah, tidak ada migrasi dijalankan, tidak ada data disentuh.

---

## 1. Ringkasan Verdict

PusatkuPOS memiliki **fondasi transaksi yang kuat**: nota, baris jasa/part, pembayaran, ledger stok, komisi, dan outbox sync ditulis dalam satu transaksi SQLite; idempotensi memakai `request_id` + hash payload; nomor nota unik; snapshot harga dilindungi trigger; ledger stok punya kunci idempoten; E2EE memakai Ed25519 + X25519 + AES-GCM dengan kunci per toko yang dibungkus per perangkat.

Namun audit menemukan **3 temuan CRITICAL**, **13 HIGH**, dan 47 MEDIUM yang membuat aplikasi **belum aman untuk produksi** pada skenario yang diminta. Tiga kelas masalah paling serius:

1. **Kehilangan data transaksi yang belum tersinkron.** Logout owner menghapus database lokal tanpa memeriksa/mengosongkan outbox; restore file mengganti DB dan membuang outbox yang lebih baru; restore dapat dilakukan sebelum login tanpa autentikasi owner.
2. **Integritas keuangan pada void setelah retur.** Kebijakan lokal menolak void bila ada retur aktif, tetapi jalur sync justru menerapkan void dari perangkat lain, mengembalikan seluruh stok, dan mencatat refund penuh di atas retur yang sudah direfund.
3. **Celah kontrol harga dan laporan.** Harga jasa bebas dari POS melewati pemeriksaan izin dan tidak pernah masuk laporan harga di bawah minimum; harga acuan (mis. 350.000) tidak tersimpan sehingga nego tidak dapat diaudit; laporan retur, koreksi, dan DPP tidak konsisten satu sama lain.

Skenario wajib:

| Skenario | Status | Inti masalah |
|---|---|---|
| SC-01 — Penjualan offline harga nego | **PARTIAL** | Harga final tersimpan & tersinkron, tetapi harga acuan 350.000 tidak tercatat; jasa bebas tanpa kontrol izin |
| SC-02 — Sync otomatis multi-device | **PARTIAL / BERISIKO** | Sync idempoten dan tahan retry, tetapi logout/restore dapat menghapus data belum terkirim; void-retur divergen |
| SC-03 — Riwayat lokal maksimum 1 tahun | **MISSING FEATURE** | Kebijakan: hapus fisik lokal setelah 1 tahun + arsip VPS; kode purge/arsip belum ada; UI 200 baris |
| SC-04 — Pencarian nota 2 tahun via VPS | **NOT IMPLEMENTED / MISSING FEATURE** | Relay hanya menyimpan ciphertext + envelope; tidak ada indeks pencarian, arsip, atau API pencarian; E2EE mencegah pencarian plaintext |
| SC-05 — E2EE end-to-end | **PARTIAL + NEEDS VALIDATION** | Recovery diputuskan via akun Gmail, tetapi escrow belum ada; tanpa rotasi kunci; metadata bocor; TLS DB default mati |

---

## 2. Registry Severity

| Severity | Jumlah | ID kanonik |
|---|---|---|
| CRITICAL | 3 | SEC-01, SEC-02, INV-03 |
| HIGH | 13 | TRX-01, TRX-07, TRX-08, INV-01, INV-02, INV-04, SEC-04, SEC-12, SEC-13, REP-01, REP-02, REP-03, REP-05 |
| MEDIUM | 47 | Lihat registry per domain |
| LOW | 16 | Lihat registry per domain |
| INFO | 3 | INV-14, OFF-04, FLG-04 |

Catatan: hitungan memakai ID kanonik. Laporan domain memuat temuan silang (mis. OFF-01 = SEC-02) dengan referensi ke ID kanonik agar tidak dihitung ganda.

---

## 3. Temuan Paling Kritis

### CRITICAL
- **SEC-01** — Restore backup dapat dilakukan dari layar pemulihan startup **sebelum login**, tanpa PIN/izin owner, dan mengganti database aktif. Siapa pun yang memegang perangkat dapat menimpa data.
- **SEC-02** — Logout owner menghapus seluruh database lokal dan backup otomatis tanpa memeriksa outbox atau memberi peringatan jumlah transaksi belum tersinkron.
- **INV-03** — Void setelah retur: lokal menolak, sync menerapkan; refund void penuh dapat dibayarkan dua kali (retur + void) dan restock dihitung dari qty yang salah.

### HIGH
- **TRX-01** — Jasa yang dibuat manual di POS selalu berharga terdaftar 0, sehingga pemeriksaan izin harga dilewati; harga bebas dapat diisi siapa pun tanpa jejak persetujuan.
- **TRX-07** — Jasa harga nol mustahil dibuat lewat POS karena `alasanDiskon` tidak pernah dikirim UI; pemilik pun tidak bisa membuat jasa gratis.
- **TRX-08** — Persetujuan PIN/penanggung jawab tidak mengaktifkan `allowBelowMinimum`; persetujuan hanya bekerja untuk diskon, bukan harga di bawah minimum/harga nol.
- **INV-01** — Opname berbasis saldo basi gagal permanen; kegagalan terjadi setelah ack sync sehingga antrean bisa macet.
- **INV-02** — Restock void dari sync mengurangi retur tanpa filter `status='AKTIF'`, sehingga qty yang diretur tidak dikembalikan dengan benar.
- **INV-04** — Pemulihan stok negatif menggelembungkan HPP rata-rata (contoh: −5 lalu +10@1.000 → rata-rata 2.000).
- **SEC-12** — Pencabutan perangkat tidak merotasi store key; perangkat yang dicabut tetap memegang kunci untuk membuka ciphertext lama/berikutnya yang masih memakai kunci sama.
- **SEC-13** — Tidak ada escrow/recovery store key; kehilangan perangkat atau kunci berarti riwayat terenkripsi tidak dapat dibuka, dan kode pemulihan hanya mereset PIN.

### HIGH (pelaporan)
- **REP-01** — Baris retur memakai DPP, tetapi Total/Penjualan Neto memakai nilai ditagih termasuk PPN; laporan tidak dapat direkonsiliasi.
- **REP-02** — Koreksi nota mengubah omzet tetapi tidak HPP/laba/PPN; margin menjadi salah.
- **REP-03** — Rekap DPP headline menjumlahkan nota `TANPA` PPN, sedangkan detail mengecualikannya; DPP dilaporkan terlalu besar.
- **REP-05** — `marginReport` membandingkan tanggal lokal dengan `waktu_service` UTC; transaksi WIB 00:00–06:59 masuk ke hari sebelumnya.

**MEDIUM yang perlu perhatian:** TRX-02 — harga acuan nego tidak tersimpan (baris mencatat harga input sebagai "harga terdaftar"), sehingga nego 350.000 → 325.000 tidak dapat dibedakan dari harga normal.

---

## 4. Keputusan Bisnis (status 9 November 2026)

### 4.1 Retensi 1 tahun — **DIPUTUSKAN**
**Keputusan pemilik:** hapus fisik data lokal setelah 1 tahun; data lainnya tetap disimpan di server VPS.

Implikasi yang wajib dipenuhi sebelum purge diaktifkan:
1. Hanya dokumen yang **sudah dikonfirmasi server** dan **outbox-nya kosong** yang boleh dihapus. Nota yang belum tersinkron tidak boleh disentuh.
2. **Arsip VPS belum ada di kode saat ini.** Relay hanya menyimpan envelope sementara dan memangkasnya setelah semua perangkat ack; snapshot hanya state terbaru. Tanpa arsip ciphertext per dokumen, menghapus lokal = menghilangkan data.
3. Karena E2EE, arsip VPS berisi ciphertext. Pencarian 2 tahun memerlukan indeks non-plaintext (HMAC/token) dan dekripsi lokal setelah data diambil.
4. Hapus lokal tidak boleh menghapus arsip VPS; keduanya harus dipisahkan.

Status implementasi: **MISSING FEATURE** (kebijakan sudah ada, kode purge dan arsip belum ada).

### 4.2 Recovery store key E2EE — **DIPUTUSKAN (tingkat tinggi)**
**Keputusan pemilik:** menggunakan akun Gmail.

Implikasi desain yang masih perlu divalidasi:
1. Gmail/Google Sign-In dipakai sebagai **identitas dan faktor pemulihan**, bukan tempat menyimpan plaintext.
2. Store key harus tetap acak; yang disimpan adalah **wrapped key** (mis. di Google Drive app data folder) yang hanya bisa dibuka dengan PIN owner + sesi Google yang sah.
3. Wajib ada 2FA pada akun Google; akun yang diambil alih tidak boleh otomatis membuka seluruh riwayat.
4. Perlu prosedur rotasi kunci dan pencabutan perangkat (SEC-12) yang tidak bergantung pada akun Google.
5. Perlu keputusan lanjutan: apakah wrapped key disimpan di Drive, di server aplikasi, atau di keduanya; dan apa yang terjadi bila akun Google hilang.

Status implementasi: **PARTIAL + NEEDS VALIDATION** (kriptografi ada, escrow berbasis Gmail belum ada).

### 4.3 Stok lokal kurang/berbeda dari server — **DIPUTUSKAN SEMENTARA (default audit)**
Pemilik tidak memiliki preferensi. Audit memakai **opsi B** sebagai default sementara: penjualan **diizinkan dengan konfirmasi**, stok negatif dicatat, konflik sync ditandai, dan selisih masuk laporan opname. Perilaku ini dapat diubah ke blokir/PIN owner bila pemilik menghendaki. Penjelasan lengkap ada di [13_REAL_WORLD_SCENARIO_AUDIT.md](file:///C:/Users/Administrator/Downloads/posapk/AUDIT_REPORT/13_REAL_WORLD_SCENARIO_AUDIT.md).

---

## 5. Yang Sudah Benar (Kontrol Positif Terverifikasi)

- Nota + baris + pembayaran + ledger stok + komisi + link order/estimasi dalam **satu transaksi DB** ([app_database.dart:1958](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1958)).
- Idempotensi `request_id` + hash payload; payload berbeda ditolak ([app_database.dart:1916](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/app_database.dart#L1916)).
- Nomor nota unik dan snapshot harga dilindungi trigger (migrasi v4/v5).
- Ledger stok idempoten per `movementSyncId`; saldo negatif lokal diblokir ([stock_ledger.dart:88](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/stock_ledger.dart#L88)).
- Void idempoten dan refund hanya sekali; retur dibatasi trigger kumulatif.
- `PRAGMA foreign_keys = ON`; 52 indeks; CHECK constraint nominal utama.
- PIN PBKDF2 600k + lockout; otorisasi di service layer; feature flag fail-closed.
- Backup terenkripsi AES-256-GCM + PBKDF2 210k; restore memakai staging, `integrity_check`, dan rollback.
- Printer tidak memiliki efek samping transaksi; kegagalan cetak tidak menggandakan nota.

---

## 6. Indeks Deliverable

| File | Isi |
|---|---|
| 00_EXECUTIVE_SUMMARY.md | Ringkasan, verdict, registry severity, 3 keputusan bisnis |
| 01_BUSINESS_LOGIC_DEFECTS.md | Registry temuan lintas domain + format wajib |
| 02_TRANSACTION_AUDIT.md | Alur penjualan, harga, diskon, pajak, bayar, void, retur |
| 03_INVENTORY_AUDIT.md | Stok, opname, ledger, HPP, pembelian, retur |
| 04_DATABASE_INTEGRITY_AUDIT.md | Skema, FK, index, migrasi, atomisitas, korupsi |
| 05_OFFLINE_FIRST_AUDIT.md | SQLite lokal, outbox, restart, force close |
| 06_SYNC_MULTI_DEVICE_AUDIT.md | Relay, idempotensi, konflik, pruning, multi-device |
| 07_ARCHITECTURE_AUDIT.md | Layering, ketergantungan modul, gap arsitektur |
| 08_APPLICATION_FLOW_AUDIT.md | Entry point, routing, startup, lifecycle |
| 09_SECURITY_E2EE_AUDIT.md | Autentikasi, otorisasi, kriptografi, kunci, kebocoran |
| 10_ERROR_HANDLING_AUDIT.md | Timeout, DB, printer, force close, token, storage |
| 11_FEATURE_TOGGLE_AUDIT.md | Flag, isolasi modul, data lama |
| 12_REMEDIATION_ROADMAP.md | Prioritas perbaikan + risiko kompatibilitas DB |
| 13_REAL_WORLD_SCENARIO_AUDIT.md | Matriks SC-01 … SC-05 |
| 14_IMPLEMENTATION_ORDER.md | Urutan implementasi berbasis dependency graph |

---

## 7. Batasan Audit

- Audit bersifat **statis**. Tidak ada eksekusi aplikasi, pengujian perangkat nyata, atau uji relay produksi.
- Kebenaran perilaku runtime (mis. perilaku SQLCipher di perangkat tertentu, timer Android saat background) ditandai **NEEDS VALIDATION** bila tidak dapat dibuktikan dari kode.
- Test yang ada di repository **tidak** dianggap bukti kebenaran implementasi.
- Line number merujuk commit audit dan dapat bergeser setelah perubahan kode.
