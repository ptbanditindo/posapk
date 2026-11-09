# 14 — IMPLEMENTATION ORDER

Dokumen ini menerjemahkan roadmap menjadi urutan implementasi berbasis dependency graph. Setiap fase hanya boleh dimulai setelah fase prasyaratnya stabil. Tidak ada implementasi yang dijalankan dalam audit ini.

**Status keputusan (9 Nov 2026):**
- #1 Retensi: **diputuskan** — hapus fisik lokal setelah 1 tahun, arsip di VPS.
- #2 Recovery kunci: **diputuskan tingkat tinggi** — memakai akun Gmail; desain escrow belum.
- #3 Stok lokal vs server: **default audit opsi B** — izinkan dengan konfirmasi + catat negatif/konflik; dapat diubah ke blokir/PIN owner.

---

## 1. Dependency Graph

```
[F0] Guard keselamatan (tanpa skema)
   │
   ├──> [F1] Integritas DB & model
   │        │
   │        ├──> [F2] Konsistensi transaksi
   │        │        │
   │        │        ├──> [F3] Harga & pembayaran
   │        │        │        │
   │        │        │        └──> [F4] Stok & valuasi
   │        │        │                 │
   │        │        │                 └──> [F5] Offline & outbox
   │        │        │                          │
   │        │        │                          └──> [F6] Sync & idempotensi
   │        │        │                                   │
   │        │        │                                   ├──> [F7] Arsip & pencarian*
   │        │        │                                   │
   │        │        │                                   └──> [F8] E2EE & siklus kunci*
   │        │        │                                            │
   │        │        │                                            └──> [F9] Error & recovery
   │        │        │                                                     │
   │        └────────┴────────────────────────────────────────────────────> [F10] Performa
```

`*` F7 dan F8 memerlukan keputusan bisnis #1 dan #2 sebelum desain final.

---

## 2. F0 — Guard Keselamatan (tanpa migrasi)

**Tujuan:** menghentikan jalur kehilangan data dan refund ganda sebelum perubahan lain.

| Task | Menutup | Kriteria selesai |
|---|---|---|
| Hitung outbox pending + tampilkan sebelum logout/restore | SEC-02, OFF-01, OFF-02 | Tidak ada logout/restore tanpa ringkasan pending dan konfirmasi |
| Autentikasi owner untuk restore (termasuk pra-login) | SEC-01, FLW-01 | Restore memerlukan PIN owner + toko cocok |
| Tolak void remote bila retur aktif **atau** batalkan retur secara eksplisit | INV-03 | Tidak mungkin refund void penuh di atas retur aktif |
| Tulis ADR kebijakan kunci (recovery/rotasi) | SEC-12, SEC-13 | Keputusan pemilik tercatat sebelum implementasi |
| Hentikan penghapusan WAL saat karantina | SEC-03, DB-06 | WAL/SHM dipindahkan bersama DB |

**Tidak menyentuh skema.** Bisa dirilis sebagai patch darurat.

---

## 3. F1 — Integritas DB & Model

**Prasyarat:** F0 selesai.

| Task | Menutup | Catatan kompatibilitas |
|---|---|---|
| Audit duplikat `request_id`, `no_nota`, movement sebelum unique index | DB | Dedupe dengan laporan, bukan hapus otomatis |
| Migrasi v11 aditif: kolom harga acuan/final, status sync, audit | TRX-02, OFF-03 | Backfill dari data yang ada; `NULL` diizinkan |
| Definisikan CHECK stok setelah keputusan #3 | DB-01, INV-14 | Jangan pasang CHECK bila negatif masih diizinkan |
| Set `busy_timeout` + journal mode eksplisit | DB-02, ERR-04 | Uji backup/restore bersamaan |
| Jalur rollback migrasi otomatis dari `.bak` | DB-05 | Uji pada salinan data |
| Rekonsiliasi ledger vs saldo (laporan, bukan mutasi) | INV-08, INV-10 | Laporkan selisih; jangan perbaiki otomatis |

**Gate:** migrasi lolos pada salinan data nyata, `integrity_check` bersih, `.bak` terverifikasi.

---

## 4. F2 — Konsistensi Transaksi

**Prasyarat:** F1 (model harga/audit tersedia).

| Task | Menutup |
|---|---|
| Satu `ApprovalGrant` (scope, approver, bukti) | TRX-08, SEC-08, ARC-01 |
| Kirim `alasanDiskon` dari POS | TRX-07 |
| Harga acuan jasa manual + audit izin | TRX-01 |
| Satukan aturan void/retur lokal & remote | INV-03, ARC-03 |
| Idempotensi opname hold | INV-11 |
| Idempotensi pembelian/retur pembelian dari UI | INV-12 |
| Tulis `business_audits` untuk void, stok, katalog | ARC-04, INV-09 |

**Gate:** uji skenario diskon, harga bawah minimum, harga nol, void-retur, dan retry ganda.

---

## 5. F3 — Harga & Pembayaran

**Prasyarat:** F2.

| Task | Menutup |
|---|---|
| Simpan harga acuan + final per baris; struk menampilkan keduanya | TRX-02 |
| Struk: uang diterima mentah vs ter-clamp | TRX-03 |
| Hapus pembulatan nominal transaksi (bayar penuh) | TRX-04 |
| Negosiasi per item (fitur) | TRX-05 |
| Modal baris = HPP ledger | TRX-06 |
| Snapshot pajak UI = service | TRX-11 |
| Pemisahan DPP/PPN penyesuaian | TRX-12 |
| Qty sesuai satuan | TRX-10 |

**Gate:** total baris = subtotal = total; struk dapat direkonsiliasi; transfer tanpa overpay.

---

## 6. F4 — Stok & Valuasi

**Prasyarat:** F3 (modal/HPP tunggal) + **keputusan bisnis #3** (default audit: opsi B — izinkan dengan konfirmasi + catat negatif/konflik; dapat diubah ke blokir/PIN owner).

| Task | Menutup |
|---|---|
| Opname absolut + isolasi kegagalan | INV-01, INV-13 |
| Filter retur aktif pada restock void | INV-02 |
| Satukan pembatalan retur (clamp) | INV-07 |
| Definisi valuasi stok negatif | INV-04 |
| Movement masuk eksplisit untuk nota baru | INV-06 |
| Simpan unit cost keluar + rebuild terkontrol | INV-08 |
| Retur memakai snapshot modal nota | INV-05 |
| UI kartu stok + rekonsiliasi | INV-10 |

**Gate:** saldo = jumlah movement; HPP konsisten setelah koreksi; opname tidak memacetkan sync.

---

## 7. F5 — Offline & Outbox

**Prasyarat:** F4 (mutasi stok konsisten).

| Task | Menutup |
|---|---|
| Status sync per dokumen di riwayat | OFF-03 |
| Larangan hapus DB tanpa flush/ekspor | OFF-01 (diperkuat) |
| Restore: merge/ekspor outbox | OFF-02 |
| Indikator kesehatan backup/sync | ARC-05, ERR-05 |
| Uji force close pada setiap titik transaksi | — |

**Gate:** skenario "matikan jaringan → buat 50 nota → tutup paksa → restart → sync" tidak kehilangan/menggandakan data.

---

## 8. F6 — Sync & Idempotensi

**Prasyarat:** F5.

| Task | Menutup |
|---|---|
| Dead-letter envelope tak terverifikasi | ERR-02, ERR-08 |
| Kebijakan pruning + alert storage | SYN-01, ERR-06 |
| Aturan konflik void/retur/opname yang eksplisit | INV-03, INV-01 |
| Aturan konflik feature flag | FLG-03 |
| Snapshot: verifikasi kesegaran/HLC | SYN-04 |
| Idempotensi permanen per entity | SYN-06 |
| Audit aktor transisi status tablet | SYN-09 |

**Gate:** simulasi dua perangkat, putus-nyambung, retry, dan perangkat mati; tidak ada duplikasi/kehilangan.

---

## 9. F7 — Arsip & Pencarian

**Prasyarat:** F6 + **keputusan bisnis #1** (sudah diputuskan: hapus fisik lokal, arsip VPS).

| Task | Menutup |
|---|---|
| Bangun arsip ciphertext per dokumen di VPS | SYN-02 |
| Tetapkan retensi 1 tahun: purge lokal, arsip VPS tetap | SYN-03, SC-03 |
| Paginasi + filter tanggal + pencarian lokal | FLW-02 |
| Indeks pencarian non-plaintext (HMAC/token) | SEC-16 |
| API pencarian dengan otorisasi + paginasi | SYN-07, SC-04 |
| Dekripsi lokal hasil pencarian + tampilkan struk | SC-04 |
| Purge lokal hanya untuk dokumen terkonfirmasi server + outbox kosong + arsip terverifikasi | SC-03 |

**Gate:** cari nota 2 tahun (nomor, pelanggan, tanggal) saat online; hasil terdekripsi lokal; tidak ada plaintext di server.

---

## 10. F8 — E2EE & Siklus Kunci

**Prasyarat:** F6 + **keputusan bisnis #2** (sudah diputuskan: akun Gmail; desain escrow perlu divalidasi).

| Task | Menutup |
|---|---|
| Rancang escrow wrapped key berbasis akun Gmail + PIN owner | SEC-13 |
| Versi kunci di envelope + simpan kunci lama | SEC-12 |
| Rotasi saat pencabutan + re-enkripsi snapshot | SEC-12 |
| Uji perangkat hilang, akun Google hilang, akun diambil alih | SEC-13 |
| Enrollment perangkat dengan persetujuan owner | SYN-05 |
| Minimalkan metadata + dokumentasi kebocoran | SEC-16 |
| TLS default aman + CORS terbatas | SEC-14 |
| Kurangi detail error server | SEC-15 |
| Hapus hash PIN dari DB / enkripsi desktop | SEC-09, DB-03 |

**Gate:** perangkat dicabut tidak dapat membuka payload baru; perangkat hilang dapat dipulihkan sesuai kebijakan; metadata terdaftar.

---

## 11. F9 — Error Handling & Recovery

**Prasyarat:** F8 (pesan kunci/rotasi jelas).

| Task | Menutup |
|---|---|
| Diagnosis error sebelum karantina | FLW-03, SEC-11 |
| Antrean/status cetak | ERR-01 |
| Pemetaan error kripto ke instruksi | ERR-07 |
| Health surface + notifikasi | ERR-05 |
| Uji storage penuh, DB locked, token expiry | ERR-04, ERR-06 |

**Gate:** setiap kegagalan yang diuji tidak merusak data lain dan menghasilkan pesan yang dapat ditindaklanjuti.

---

## 12. F10 — Performa

**Prasyarat:** F7/F9.

| Task | Menutup |
|---|---|
| Index untuk pencarian/paginasi | FLW-02 |
| Ukur query laporan pada data 2 tahun | REP, DB |
| Optimasi snapshot/feed | SYN |
| Standarkan aritmetika integer | DB-04, TRX-09 |

**Gate:** waktu buka riwayat/pencarian dan ukuran DB dalam batas yang disepakati; tidak ada selisih pembulatan baru.

---

## 13. Ringkasan Urutan

| Fase | Fokus | Temuan utama |
|---|---|---|
| F0 | Guard data/keuangan | SEC-01/02, INV-03 |
| F1 | DB/model | DB-01..06, TRX-02 |
| F2 | Transaksi | TRX-01/07/08, ARC-01/03 |
| F3 | Harga/bayar | TRX-03..06, TRX-09..12 |
| F4 | Stok | INV-01..10 |
| F5 | Offline/outbox | OFF-01..03 |
| F6 | Sync | SYN-01..09, ERR-02/06/08 |
| F7 | Arsip/cari | SC-03, SC-04, SYN-02/03/07 |
| F8 | E2EE/kunci | SEC-09, SEC-12..16 |
| F9 | Error/recovery | ERR-01..07, FLW-03 |
| F10 | Performa | DB-04, FLW-02 |

**Aturan:** jangan lompat ke F7/F8 sebelum keputusan bisnis #1/#2; jangan pasang constraint baru sebelum data dibersihkan/diputuskan; jangan mengubah data historis untuk memperbaiki laporan.
