# 12 — REMEDIATION ROADMAP

Dokumen ini mengelompokkan perbaikan berdasarkan risiko dan menjelaskan urutan, dependensi, serta risiko kompatibilitas database. **Tidak ada perbaikan yang dijalankan oleh audit ini.**

---

## 1. Prinsip Remediasi

1. **Data dulu, fitur kemudian.** Lindungi data yang belum tersinkron sebelum menyentuh skema atau fitur baru.
2. **Aditif, bukan destruktif.** Migrasi baru harus menambah kolom/tabel/index; jangan menghapus kolom/data pengguna.
3. **Satu aturan domain, satu implementasi.** Hindari memperbaiki lokal dan remote secara terpisah dengan perilaku berbeda.
4. **Keputusan bisnis sebelum kode.** Retensi 1 tahun dan recovery kunci sudah diputuskan; stok memakai default audit (opsi B) sampai pemilik mengubahnya.
5. **Uji pada salinan data nyata**, bukan hanya database kosong. Test hijau bukan bukti kebenaran.
6. **Setiap migrasi wajib meninggalkan `.bak`** dan lolos `integrity_check` sebelum commit versi.

---

## 1.1 Keputusan Pemilik yang Sudah Dicatat (9 Nov 2026)

| # | Keputusan | Konsekuensi implementasi |
|---|---|---|
| 1 | Hapus fisik data lokal setelah 1 tahun; data lain disimpan di VPS | Bangun arsip ciphertext VPS lebih dulu; purge hanya untuk dokumen tersinkron + outbox kosong; arsip VPS tidak boleh ikut terhapus |
| 2 | Recovery store key memakai akun Gmail | Gmail = identitas/faktor pemulihan; wrapped key + PIN owner; wajib 2FA; desain escrow belum ada |
| 3 | Perilaku stok lokal kurang/berbeda | **Default audit: opsi B** — izinkan dengan konfirmasi, catat negatif/konflik, wajib opname. Dapat diubah ke blokir/PIN owner tanpa perubahan skema |

---

## 2. P0 — Wajib Sebelum Produksi (Data Loss / Keuangan / Keamanan)

| ID | Perbaikan | Alasan | Dependensi |
|---|---|---|---|
| SEC-02 / OFF-01 | Cegah logout menghapus data belum tersinkron: hitung outbox, wajib flush/ekspor, konfirmasi berlapis | Kehilangan transaksi permanen | Tidak ada skema |
| SEC-01 / FLW-01 | Autentikasi owner sebelum restore; batasi arsip ke toko yang sama | Penimpaan data tanpa izin | SEC-04 |
| INV-03 | Hentikan double refund void-setelah-retur; satukan kebijakan lokal/remote | Integritas keuangan | INV-02, INV-07 |
| SEC-13 | Implementasikan recovery kunci E2EE sesuai keputusan pemilik: akun Gmail + wrapped key + PIN owner + 2FA | Riwayat tidak dapat dibuka jika perangkat hilang | Desain escrow & validasi |
| SEC-12 | Rotasi store key saat perangkat dicabut | Akses kriptografis perangkat hilang tetap hidup | SEC-13, SYN-05 |
| SEC-04 / OFF-02 | Cegah restore membuang outbox lebih baru | Kehilangan transaksi | SEC-01 |
| Keputusan #1 | Bangun arsip ciphertext VPS **sebelum** mengaktifkan purge lokal 1 tahun | Menghapus data yang tidak ada salinannya | SYN-02, SEC-16 |

**Gate P0:** tidak boleh rilis produksi selama salah satu dari lima item pertama belum selesai atau secara eksplisit diterima pemilik dengan mitigasi tertulis.

---

## 3. P1 — Prioritas Tinggi (Transaksi, Stok, Laporan, Riwayat)

| ID | Perbaikan | Dependensi |
|---|---|---|
| TRX-08 | Grant persetujuan tunggal; PIN mengaktifkan harga bawah minimum | ARC-01 |
| TRX-07 | Kirim `alasanDiskon`; bedakan gratis vs diskon 100% | TRX-08 |
| TRX-01 | Harga acuan jasa manual + audit izin + masuk laporan harga bawah | TRX-08 |
| TRX-02 | Simpan harga acuan vs final; struk menampilkan keduanya | TRX-01 |
| INV-01 | Opname absolut + isolasi kegagalan per hold | INV-11 |
| INV-02 | Filter retur aktif pada restock void | INV-03 |
| INV-04 | Definisi valuasi saat saldo negatif | Keputusan bisnis #3 |
| REP-01 | Satukan basis retur (DPP vs ditagih) di laporan | INV-05 |
| REP-02 | Koreksi memengaruhi HPP/PPN secara konsisten | TRX-12 |
| REP-03 | Rekap DPP hanya nota ber-PPN; detail konsisten | — |
| REP-05 | Bandingkan tanggal pada zona waktu yang sama | — |
| FLW-02 | Paginasi + filter tanggal + pencarian lebih luas | Index DB |

---

## 4. P2 — Prioritas Menengah (Konsistensi, Keamanan, Operasional)

- **Transaksi:** TRX-03, TRX-04, TRX-05, TRX-06, TRX-09, TRX-10, TRX-11.
- **Inventori:** INV-05, INV-06, INV-07, INV-08, INV-09, INV-10, INV-11, INV-12, INV-13.
- **Database:** DB-01, DB-02, DB-03, DB-05; DB-06 sudah tercakup SEC-03.
- **Sync:** SYN-01, SYN-02, SYN-03, SYN-04, SYN-05, SYN-07.
- **Keamanan:** SEC-05, SEC-06, SEC-07, SEC-08, SEC-14, SEC-15, SEC-16; SEC-09/10/11.
- **Alur:** FLW-03, FLW-04, FLW-05, FLW-06.
- **Error:** ERR-01 … ERR-08.
- **Feature flag:** FLG-01, FLG-02, FLG-03.

---

## 5. P3 — Penyempurnaan

- Pembulatan sen (TRX-09, DB-04, REP-08).
- Qty desimal sesuai satuan (TRX-10).
- Konsistensi istilah/label struk.
- Audit tampilan status VOID (REP-07).
- Ekspor ringkasan owner (REP-09).

---

## 6. Urutan Eksekusi dan Alasannya

```
P0 Guard (tanpa skema)
  → Integritas DB/model (migrasi v11)
    → Konsistensi transaksi
      → Harga & pembayaran
        → Stok
          → Offline & outbox
            → Sync & idempotensi
              → Arsip & pencarian (butuh keputusan #1)
                → E2EE & kunci (butuh keputusan #2)
                  → Error handling & recovery
                    → Performa
```

**Mengapa urutan ini:**
- Guard P0 tidak menunggu skema dan langsung mencegah kehilangan data.
- Constraint/index harus selesai sebelum mengubah alur, agar data baru tidak menambah pelanggaran.
- Stok bergantung pada definisi modal yang benar (transaksi) dan valuasi (DB).
- Sync bergantung pada aturan domain tunggal; memperbaiki sync sebelum domain berarti menduplikasi bug.
- Arsip/pencarian mustahil tanpa keputusan retensi dan desain indeks terenkripsi.
- Rotasi/recovery kunci bergantung pada model ancaman dan kebijakan bisnis.

---

## 7. Peringatan Kompatibilitas Database & Risiko Data

| Perubahan | Risiko | Mitigasi |
|---|---|---|
| Menambah CHECK `jumlah_milli >= 0` | Gagal pada data negatif existing | Bersihkan/ tandai negatif dulu; putuskan kebijakan; migrasi bertahap |
| Menambah unique index `request_id` | Gagal bila ada duplikat lama | Deteksi & dedupe dengan audit sebelum index |
| Menambah kolom harga acuan/final | Data lama tidak punya nilai | Backfill dari snapshot yang ada; tandai `NULL` + laporan |
| Rotasi store key | Envelope lama tidak terbaca bila kunci lama dihapus | Simpan versi kunci; pertahankan kunci lama sampai semua perangkat migrasi; re-enkripsi snapshot |
| Mengubah kebijakan void/retur | Data lama dapat tidak konsisten dengan aturan baru | Jangan mutasi otomatis; buat laporan rekonsiliasi + keputusan manual |
| Migrasi v11 | Kegagalan di tengah | Backup pra-upgrade, uji pada salinan, rollback otomatis dari `.bak` |
| Purge 1 tahun | Menghapus data yang belum tersinkron atau belum diarsipkan | **Kebijakan: hapus fisik lokal, arsip VPS.** Hanya untuk dokumen terkonfirmasi server + outbox kosong + arsip terverifikasi; jangan hapus arsip VPS |
| Mengaktifkan TLS DB | Koneksi lama gagal | Uji sertifikat, siapkan rollback konfigurasi |
| Menghapus API `runViewerWrite` | Pemanggil internal rusak | Audit pemanggil; ganti dengan koneksi read-only |

---

## 8. Kriteria Selesai per Gate

- **P0:** tidak ada jalur UI/service yang menghapus/mengganti DB tanpa cek outbox dan autentikasi owner; double refund tidak mungkin; kebijakan kunci tertulis.
- **P1:** nota dengan harga nego memiliki acuan + persetujuan + tampil konsisten; opname tidak memacetkan sync; laporan dapat direkonsiliasi ke nota.
- **P2:** semua temuan MEDIUM memiliki pemilik, tiket, dan uji regresi; tidak ada error tersembunyi pada scheduler.
- **P3:** tidak ada selisih pembulatan yang dilaporkan pengguna.

---

## 9. Yang Tidak Boleh Dilakukan Saat Remediasi

- Jangan menjalankan migrasi destruktif pada data pengguna tanpa backup yang terverifikasi.
- Jangan mengubah data historis untuk "memperbaiki" laporan; buat koreksi baru.
- Jangan mengaktifkan purge/arsip sebelum keputusan bisnis.
- Jangan merotasi kunci tanpa rencana distribusi dan rollback.
- Jangan menganggap test lulus sebagai bukti integritas; verifikasi dengan data nyata dan skenario SC-01…SC-05.
