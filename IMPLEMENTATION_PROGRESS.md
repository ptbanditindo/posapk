# IMPLEMENTATION PROGRESS — PUSATKUPOS

**Rencana induk:** [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)
**Aturan:** centang `[x]` hanya ketika implementasi kode untuk tugas tersebut benar-benar selesai. `[!]` = terhambat/butuh keputusan bisnis. `[-]` = tidak diperlukan (alasan ditulis).
**Pengujian:** belum dijalankan dan tidak boleh dijalankan sampai FASE 7.

---

## STATUS PROGRES

Total tugas: 63

- Selesai: 0
- Belum selesai: 63
- Terhambat: 0

Fase aktif: FASE 1 — FONDASI SKEMA BERSIH DAN KONTRAK DATA

Tugas terakhir selesai: —

Tugas berikutnya: TASK-001

---

## FASE 1 — FONDASI SKEMA BERSIH DAN KONTRAK DATA

- [ ] TASK-001 — Hapus jalur migrasi lama; skema bersih kanonik; versi baru; tolak database lama.
- [ ] TASK-002 — Redesain tabel master dan integritas soft-delete (BL-26, BL-41).
- [ ] TASK-003 — Redesain `service_records`: komponen immutable, `total_efektif`, VOID terminal (BL-05, BL-15, BL-34).
- [ ] TASK-004 — Redesain baris nota/estimasi: snapshot harga/modal, qty retur (BL-02, BL-04, BL-18).
- [ ] TASK-005 — Redesain pembayaran + ledger kas, idempotensi (BL-13, BL-14, BL-15, BL-39).
- [ ] TASK-006 — Snapshot komisi (BL-04, BL-34, BL-40).
- [ ] TASK-007 — Ledger stok append-only + opname absolut (BL-01, BL-21, BL-24).
- [ ] TASK-008 — Payroll: kunci siklus global, jejak hutang (BL-03).
- [ ] TASK-009 — Retur: state terminal, batas per baris, idempotensi (BL-02, BL-13, BL-41).
- [ ] TASK-010 — Akun/role/akses toko/versi izin/viewer (BL-07, BL-08, BL-10, BL-11, BL-28).
- [ ] TASK-011 — Tabel sinkronisasi + skema PostgreSQL relay (BL-15, BL-30, BL-33, BL-41).
- [ ] TASK-012 — Sesuaikan model dan mapper Dart (semua).

## FASE 2 — OTORISASI, AKUN, DAN IDENTITAS

- [ ] TASK-013 — Wajibkan actor pada operasi tulis (BL-27).
- [ ] TASK-014 — `createEstimate` wajib actor (BL-37).
- [ ] TASK-015 — Izin `retur` di service/UI/relay (BL-09).
- [ ] TASK-016 — Izin order kerja per jenis (BL-36).
- [ ] TASK-017 — Otorisasi batal/revisi estimasi + unique versi (BL-12).
- [ ] TASK-018 — Follow-up: operator, izin, kuota setelah commit, tanggal aman (BL-31).
- [ ] TASK-019 — Hitung ulang izin saat pindah toko (BL-08).
- [ ] TASK-020 — Principal viewer read-only (BL-28).
- [ ] TASK-021 — Tolak akun nonaktif di relay dan unlock lokal (BL-06).
- [ ] TASK-022 — Push semua akun + auto push + `permission_version` (BL-10).
- [ ] TASK-023 — Envelope karyawan membawa role/izin/toko (BL-11).
- [ ] TASK-024 — Akun dalam snapshot/login/buat toko (BL-07).

## FASE 3 — TRANSAKSI, KEUANGAN, INVENTORI, DAN KONFLIK DATA

- [ ] TASK-025 — Idempotensi retur dan pelunasan (BL-13).
- [ ] TASK-026 — Pelunasan: rekalkulasi, tolak/konflik kelebihan (BL-14).
- [ ] TASK-027 — Gaji ganda menjadi konflik (BL-03).
- [ ] TASK-028 — Penerima retur/void: batas, terminal, idempoten (BL-02).
- [ ] TASK-029 — Void menyesuaikan komisi dan pembayaran (BL-34).
- [ ] TASK-030 — Void self-contained (BL-15).
- [ ] TASK-031 — Opname absolut lintas perangkat (BL-01).
- [ ] TASK-032 — Stok bersamaan: cegah/konflik (BL-21).
- [ ] TASK-033 — Kebijakan stok negatif konsisten (BL-24).
- [ ] TASK-034 — Rekalkulasi komisi memakai snapshot (BL-04).
- [ ] TASK-035 — Penerima retur merekalkulasi komisi (BL-40).
- [ ] TASK-036 — Konflik kode barang tidak memblokir antrean (BL-41).
- [ ] TASK-037 — Merge pelanggan memindahkan semua referensi (BL-16).
- [ ] TASK-038 — Kode perangkat/counter dokumen kuat (BL-33).

## FASE 4 — PERHITUNGAN, TAMPILAN, DAN LAPORAN

- [ ] TASK-039 — Total efektif di semua query/layar (BL-05).
- [ ] TASK-040 — Join pelanggan `COALESCE` (BL-17).
- [ ] TASK-041 — Struk total efektif (BL-18).
- [ ] TASK-042 — Kembalian per pembayaran (BL-39).
- [ ] TASK-043 — Dashboard omzet bruto/neto/kas (BL-19).
- [ ] TASK-044 — Digest rekonsiliasi memuat nilai (BL-23).
- [ ] TASK-045 — Jatuh tempo memakai sisa efektif (BL-25).
- [ ] TASK-046 — Filter soft-delete stok (BL-26).
- [ ] TASK-047 — Adjustment retry/konflik (BL-30).
- [ ] TASK-048 — Tombstone relasi supplier (BL-38).

## FASE 5 — SINKRONISASI DUA ARAH DAN KONFLIK MULTI-PERANGKAT

- [ ] TASK-049 — Kontrak amplop: idempoten, konflik terpisah, cursor maju (BL-01, BL-02, BL-15, BL-30, BL-41).
- [ ] TASK-050 — Validasi ulang izin/akun/stok di penerima (BL-11, BL-24).
- [ ] TASK-051 — Konflik gaji/pelunasan ditinjau (BL-03, BL-14).
- [ ] TASK-052 — Snapshot/bootstrap membawa akun dan counter (BL-07).
- [ ] TASK-053 — Waktu server dan lisensi di relay (BL-29, BL-35).

## FASE 6 — BACKUP, RESTORE, KEAMANAN, DAN KETAHANAN PROSES

- [ ] TASK-054 — Restore atomik + pemulihan startup (BL-42).
- [ ] TASK-055 — Batas agregat restore + ruang disk + staging (BL-20).
- [ ] TASK-056 — Passphrase tidak ditampilkan (BL-22).
- [ ] TASK-057 — Checkpoint toko nonaktif (BL-32).
- [ ] TASK-058 — Waktu server tepercaya untuk lisensi (BL-29).
- [ ] TASK-059 — Relay memeriksa lisensi pada `_deviceAuth` (BL-35).

## FASE 7 — VERIFIKASI STATIS, PENGUJIAN AKHIR, LAPORAN

- [ ] TASK-060 — Sapu konsistensi statis seluruh pemanggil/query.
- [ ] TASK-061 — Pengujian akhir sesuai teknologi repo.
- [ ] TASK-062 — Build APK.
- [ ] TASK-063 — `IMPLEMENTATION_FINAL_REPORT.md`.

---

## CATATAN KEPUTUSAN BISNIS

Lihat **Bagian 5** `IMPLEMENTATION_PLAN.md` (BD-01 s.d. BD-12). Default konservatif dipakai sementara dan ditandai di kode; keputusan final belum diambil.

---

## RIWAYAT PERUBAHAN

| Tanggal | Tugas | Berkas diubah | Ringkasan |
|---|---|---|---|
| 2026-11-07 | Perencanaan | `IMPLEMENTATION_PLAN.md`, `IMPLEMENTATION_PROGRESS.md` | Memetakan 42 temuan menjadi 63 tugas dalam 7 fase; belum ada source code yang diubah. |
