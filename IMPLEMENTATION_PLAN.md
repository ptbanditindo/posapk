# PusatkuPOS — Rencana Implementasi Satu Putaran

**Status:** desain selesai, belum ada kode yang diubah.
**Tanggal:** 9 November 2026.
**Sumber:** 15 laporan `AUDIT_REPORT/` + keputusan pemilik pada sesi desain.

Dokumen ini adalah satu-satunya sumber keputusan dan urutan kerja. `AUDIT_REPORT/`
tetap menjadi bukti kode. Jika ada pertentangan, dokumen ini menang untuk
keputusan, dan laporan audit menang untuk bukti implementasi.

Aturan kerja:

1. Implementasi berjalan F0 → F10. Tidak ada pertanyaan bisnis baru di tengah
   jalan; semua default sudah ditetapkan di §2.
2. Satu task selesai hanya jika kode, uji otomatis, dan skenario manualnya lulus.
3. Jika kode nyata berbeda dari bukti audit, berhenti dan perbarui dokumen ini
   sebelum mengubah perilaku. Jangan berimprovisasi.
4. Tidak ada migrasi bertahap. Schema ditulis ulang sebagai baseline baru
   selama belum ada pengguna produksi.
5. Jangan mengubah data historis untuk memperbaiki laporan. Koreksi selalu
   dokumen baru.

---

## 1. Batasan yang Tidak Berubah

- Aplikasi tetap **local-first** agar kasir tidak menunggu jaringan, tetapi
  target operasional pengguna premium adalah **online dan tersinkron**.
  Offline adalah pengecualian yang harus pulih cepat, bukan mode normal.
- **Sync adalah fitur utama premium.** Setiap commit memicu sync, status per
  dokumen terlihat, dan konflik diselesaikan dekat real-time.
- Relay tidak pernah membaca plaintext transaksi. Semua payload tetap E2EE.
- Satu toko dapat memiliki banyak perangkat; tidak ada batas jumlah login.
  Setiap perangkat tetap harus disetujui owner dan dapat dicabut.
- Uang disimpan dalam sen integer; qty dalam milli; pembulatan hanya di
  tampilan/struk akhir.
- Tablet mekanik **tidak boleh** menulis stok, menjual, atau membuat nota.
- Retensi lokal 1 tahun untuk riwayat service/nota; VPS menyimpan arsip lengkap
  selamanya.
- Dua VPS: satu untuk komunikasi (relay), satu untuk penyimpanan (arsip).
- Tidak ada penghapusan otomatis data historis selain purge lokal yang lolos
  gate di §3.6.
- Tidak ada plaintext nama, telepon, item, harga, atau nominal di VPS arsip.

### 1.1 Model Operasi Premium

Pengguna premium diasumsikan hampir selalu punya internet. Local-first dipakai
untuk kecepatan dan ketahanan, bukan karena offline dianggap normal.

| Aturan | Target |
|---|---|
| Sync setelah commit | mulai <= 1,5 detik setelah transaksi selesai |
| Commit → terlihat di perangkat lain | <= 30 detik saat jaringan baik |
| Fallback periodik saat aplikasi terbuka | setiap 60 detik |
| Sync saat jaringan kembali | segera setelah event konektivitas |
| Sync saat aplikasi dibuka/resume | segera |
| Sync manual | tarik untuk menyegarkan |
| Ambang status "terlambat" | belum sync sukses > 5 menit saat online |
| Banner offline | setelah 24 jam tanpa sync sukses (fallback, bukan indikator utama) |

Pemicu sync: commit lokal (debounce), konektivitas kembali, resume aplikasi,
timer 60 detik saat foreground, dan aksi manual. Deteksi konektivitas memakai
event jaringan + health check relay; event jaringan saja tidak menjamin relay
hidup.

Keputusan stok saat online: jika sync terakhir > 5 menit, coba sync dengan
batas tunggu 5 detik sebelum transaksi yang bergantung stok. Jika sync gagal,
perlakukan sebagai offline: pakai ledger lokal dan blokir jika stok kurang.
Jangan menahan kasir menunggu jaringan tanpa batas.

---

## 2. Keputusan Final

Kolom **Sumber** membedakan keputusan eksplisit pemilik dan default kerja yang
dipakai agar implementasi tidak berhenti. Default hanya mengubah aturan
service/UI, bukan arah arsitektur.

| ID | Keputusan | Sumber | Konsekuensi |
|---|---|---|---|
| D1 | Stok adalah agregat seluruh movement, bukan angka yang diketik | Pemilik | `stock_items.jumlah_milli` hanya berubah lewat `StockLedger.apply` |
| D2 | Hanya kasir yang boleh mencatat barang keluar dan barang masuk | Pemilik | Tablet read-only stok; pembelian dan penjualan dari perangkat kasir |
| D3 | Saat offline stok lokal kurang, penjualan diblokir | Pemilik | Tidak ada penjualan negatif lokal; pesan menyebut sisa stok |
| D4 | Saat online, sync dan konvergensi ledger dijalankan sebelum keputusan stok; saat offline, ledger lokal dipakai dan stok kurang diblokir | Pemilik | "Stok server" = hasil konvergensi movement, bukan angka plaintext di relay |
| D5 | Opname adalah koreksi hitung fisik, berbeda dari penambahan barang | Pemilik | Opname disimpan sebagai delta dengan basis absolut; barang masuk lewat pembelian |
| D6 | Void ditolak selama retur aktif; retur harus dibatalkan lebih dulu | Pemilik | Tidak ada refund ganda lokal/remote |
| D7 | Logout tidak menghapus data; penghapusan hanya lewat "Reset perangkat" | Pemilik | Logout = tutup sesi; reset = aksi terpisah dengan autentikasi owner |
| D8 | Restore wajib Google Sign-In owner dan arsip toko yang sama | Pemilik | Tidak ada restore pra-login; restore tidak menimpa toko lain |
| D9 | Lokal purge riwayat service/nota setelah 1 tahun | Pemilik | Master, ledger stok, ledger kas, audit, dan pembelian tetap lokal |
| D10 | VPS menyimpan seluruh data lengkap selamanya | Pemilik | Arsip per dokumen + stream envelope; tidak pernah dipangkas |
| D11 | Dua VPS: relay komunikasi dan arsip penyimpanan | Pemilik | Client mengunggah langsung ke arsip dengan token dari relay |
| D12 | Pencarian arsip: exact nomor nota, token nama, rentang tanggal | Default kerja | Tidak ada pencarian teks bebas di server; hasil didekripsi lokal |
| D13 | Recovery: akun Google + Drive app data + PIN owner; admin memegang offline recovery key | Pemilik | Rotasi kunci wajib saat perangkat dicabut; kunci lama disimpan |
| D14 | Harga: acuan + final per baris; nego per item; di bawah modal/negosiasi butuh persetujuan owner | Default kerja | PIN hanya membuka grant; grant dicatat sebagai audit |
| D15 | Laporan: nilai ditagih untuk penjualan, DPP untuk pajak; koreksi = dokumen negatif | Default kerja | Zona waktu toko; tidak ada recompute snapshot lama |
| D16 | Platform: Android kasir, Windows owner, tablet Android mekanik | Default kerja | Tanpa batas jumlah perangkat; rilis bertahap F0–F8 |
| D17 | Status sync langsung di aplikasi + banner offline 24 jam sebagai fallback | Pemilik | Indikator utama adalah status sync; banner 24 jam bukan mekanisme utama |
| D18 | Schema ditulis ulang sebagai baseline, tanpa rantai migrasi | Pemilik | Database dev lama di-backup lalu dibuat ulang sebelum rilis |
| D19 | Deteksi konektivitas memakai event jaringan (`connectivity_plus`) + health check relay; timer 60 detik tetap berjalan sebagai fallback | Default kerja | Event jaringan saja tidak dianggap online sampai health check relay berhasil |
| D20 | Sync premium memakai fallback foreground 60 detik; interval lama 10–20 menit dan setting `sync.interval_minutes` dihapus | Default kerja | Debounce setelah commit mencegah polling berlebihan; timer hanya jaring pengaman |

Default D12, D14, D15, D16, D19, dan D20 boleh diubah setelah dokumen ini
disetujui. Perubahan tersebut tidak membatalkan D1–D11 dan tidak memerlukan
perubahan arsitektur.

---

## 3. Aturan Domain

### 3.1 Stok

**Invarian:** untuk setiap `stock_items`, saldo = jumlah seluruh movement yang
tercatat. Tidak ada penulisan langsung ke `jumlah_milli` di luar
`StockLedger.apply`.

Sumber movement yang wajib ada:

| Jenis | Sumber | Arah |
|---|---|---|
| Penjualan | `service_record` | keluar |
| Retur penjualan | `sale_return` | masuk |
| Void penjualan | `service_record` | masuk, hanya qty yang tidak aktif diretur |
| Pembelian | `purchase` | masuk |
| Retur pembelian | `purchase_return` | keluar |
| Opname | `opname` | koreksi absolut |
| Saldo awal | `opening_balance` | masuk |
| Penyesuaian manual | `manual` | masuk/keluar, wajib alasan + operator |

Aturan:

1. Penjualan lokal memeriksa saldo sebelum commit. Jika `saldo - qty < 0`,
   transaksi ditolak (D3). Tidak ada dialog "lanjutkan".
2. Penerapan sync boleh menghasilkan saldo negatif karena movement dari
   perangkat lain. Saldo negatif tidak diperbaiki otomatis; muncul di laporan
   dan memicu opname.
3. HPP memakai rata-rata bergerak. Movement keluar menyimpan
   `harga_pokok_satuan_cents`; movement retur memakai snapshot HPP penjualan,
   bukan harga master saat ini.
4. Jika saldo sebelum masuk <= 0, pemulihan stok tidak boleh menggelembungkan
   rata-rata. Nilai masuk tetap dipakai, tetapi HPP baris keluar berikutnya
   dihitung dari basis yang sudah dibersihkan; tidak ada HPP negatif.
5. Opname:
   - kasir menghitung fisik;
   - sistem menyimpan `opname_absolut_milli` (hasil hitung) dan
     `opname_basis_milli` (saldo lokal saat hitung);
   - movement yang dikirim adalah delta idempoten, bukan angka absolut yang
     menimpa perangkat lain;
   - `request_id` wajib; hold yang gagal tidak memblokir hold lain.
6. Rekonsiliasi harian: saldo vs jumlah movement, saldo negatif, movement tanpa
   dokumen, dan dokumen tanpa movement. Laporan tidak mengubah data.
7. Tidak ada `CHECK (jumlah_milli >= 0)` pada saldo, karena sync sah dapat
   menghasilkan negatif. Yang ditegakkan adalah guard lokal dan laporan.

### 3.2 Harga dan Persetujuan

Data yang sudah tersedia di `service_jobs`: `harga_jual_terdaftar`,
`harga_batas_saat_transaksi`, `harga_final`, `diskon_alokasi`, `alasan_diskon`,
`disetujui_oleh`. Tidak perlu kolom baru untuk harga acuan.

Aturan:

1. **Harga acuan** = `harga_jual_terdaftar`.
   - Jasa katalog: harga katalog saat transaksi.
   - Jasa manual: kasir wajib mengisi "Harga normal" dan "Harga disepakati".
   - Part: harga jual master saat transaksi.
2. **Harga final** = `harga_final`. Jika final < acuan, `alasan_diskon` wajib
   dan permission `permissionChangeServicePrice` diperlukan untuk non-owner.
3. Jika final < modal (part, atau jasa yang punya modal) atau final = 0:
   - owner PIN / approver secret diverifikasi di luar transaksi;
   - satu grant berlaku untuk seluruh baris di transaksi itu;
   - grant dicatat di `business_audits` dengan aksi
     `harga_di_bawah_modal`, berisi approver, alasan, daftar baris, waktu,
     dan masa berlaku;
   - nota menyimpan `disetujui_oleh` + `alasan_diskon` per baris.
4. PIN tidak pernah menjadi otorisasi itu sendiri. PIN hanya membuka layar
   persetujuan; grant yang memberi izin.
5. Modal baris = HPP rata-rata ledger saat transaksi, bukan harga master.
6. Struk menampilkan harga acuan, diskon, dan harga final bila berbeda.
7. Jasa manual dengan modal 0 adalah jasa tenaga kerja; laporan laba
   menampilkannya sebagai kelompok "jasa tanpa modal", bukan laba 100% tanpa
   penjelasan.

### 3.3 Void dan Retur

1. Sebelum void lokal atau penerapan void remote, periksa `sale_returns`
   dengan `status = 'AKTIF'` untuk nota tersebut.
2. Jika ada retur aktif: tolak void. Kasir harus membatalkan retur lebih dulu.
3. Restock void hanya untuk qty yang belum diretur:
   `qty_jual - qty_retur_aktif`.
4. Pembatalan retur lokal membatasi qty pada stok yang masih tersedia; jika
   barang sudah terjual lagi, pembatalan ditolak dan ditampilkan sebagai
   konflik.
5. Penerapan remote memakai aturan yang sama. Void remote yang melanggar
   aturan masuk dead-letter/konflik, tidak diterapkan sebagian.
6. Refund void = nilai efektif nota - nilai retur aktif. Refund retur memakai
   snapshot DPP/PPN dan HPP penjualan.
7. Semua aksi void/retur menulis `business_audits`.

### 3.4 Laporan dan Pajak

1. Snapshot pajak per nota (`pajak_snapshot_json`, `pajak_dpp`, `pajak`,
   `pajak_diserap`) adalah sumber kebenaran. Laporan tidak menghitung ulang
   dengan tarif saat ini.
2. Dua basis yang harus konsisten:
   - **Penjualan:** nilai ditagih (`total`/`total_efektif`).
   - **Pajak:** DPP dan PPN dari snapshot.
3. Retur adalah dokumen negatif: mengurangi DPP, PPN, omzet, dan HPP pada
   periode retur. Nota asal tidak diubah.
4. Penyesuaian nota memisahkan komponen jasa, part, diskon, DPP, dan PPN.
   Nilai yang tidak ber-PPN tidak boleh masuk rekap DPP.
5. Laba kotor:
   - jika PPN aktif: DPP - HPP;
   - jika PPN tidak aktif: nilai ditagih - HPP.
6. Tanggal laporan memakai zona waktu toko (default `Asia/Jakarta`). Data
   disimpan UTC; filter tanggal dikonversi ke rentang UTC yang sama.
7. Semua agregasi uang memakai integer. Tidak ada pembagian REAL di SQL.
   Pembulatan hanya di tampilan/struk.
8. Laporan wajib: harian kasir, penjualan, laba kotor, stok, piutang, pajak,
   komisi. Piutang hanya nota kredit yang belum lunas dan tidak VOID; kas
   hanya mutasi CASH/TRANSFER.
9. Nota VOID tetap tampil dengan badge dan nilai 0, bukan hilang dari riwayat.

### 3.5 Sync dan Idempotensi

1. Setiap dokumen punya `request_id` + hash payload. Request yang sama
   mengembalikan dokumen yang sama; payload berbeda ditolak.
2. Outbox memiliki status per dokumen: pending, sending, acked, failed,
   dead-letter. UI riwayat menampilkan status per dokumen.
3. Cursor hanya maju setelah envelope diterapkan. Envelope yang gagal
   diverifikasi masuk dead-letter setelah N percobaan dan tidak menahan
   envelope lain.
4. `applied_deltas` disimpan permanen (atau minimal selama umur arsip), bukan
   dipangkas 90 hari.
5. Snapshot hanya dipercaya jika HLC-nya tidak lebih tua dari cursor perangkat
   dan daftar perangkat aktif cocok. Snapshot tidak menggantikan arsip.
6. Konflik void/retur/opname/feature flag memakai satu aturan domain di
   `sync_conflict_rules.dart`; tidak ada aturan lokal dan remote yang berbeda.
7. Pruning envelope relay hanya setelah semua perangkat **aktif** ack.
   Perangkat aktif = belum dicabut dan heartbeat-nya <= 30 hari. Perangkat
   tanpa heartbeat > 30 hari tidak menahan pruning; saat kembali, perangkat
   harus re-enroll dan menerima snapshot. Tidak ada batas jumlah perangkat,
   tetapi daftar perangkat harus dapat dipaginasi dan diaudit.
8. Perubahan status work order dari tablet mencatat aktor, waktu, dan HLC.
9. Sync dipicu setelah commit (debounce 1,5 detik), saat konektivitas kembali,
   saat resume, setiap 60 detik selama foreground, dan manual. Event
   konektivitas diikuti health check relay sebelum dianggap online.
10. Target: commit → sync mulai <= 1,5 detik; perangkat lain menerima
    <= 30 detik saat jaringan baik. Jika belum sync sukses > 5 menit saat
    online, status "terlambat" ditampilkan dan sync dipaksa.
11. Sebelum transaksi yang bergantung stok, jika data > 5 menit basi dan
    online, coba sync dengan batas tunggu 5 detik. Gagal sync = perlakukan
    sebagai offline; jangan menahan kasir tanpa batas.
12. Arsip diunggah paralel setelah commit dan tidak menunggu sync relay.

### 3.6 Retensi, Arsip, dan Purge

1. Setiap nota diarsipkan **segera setelah commit**, bukan saat mau purge.
2. Arsip berisi dua lapis:
   - bundle per dokumen (nota + jobs + parts + payments + returns +
     commissions + adjustments + pajak + struk);
   - stream envelope lengkap untuk master, stok, kas, dan audit.
3. Bundle dienkripsi dengan store key; server hanya menyimpan ciphertext,
   hash, metadata minimal, dan token indeks HMAC.
4. Upload idempoten per `(store_id, doc_type, doc_id, content_hash)`. Respons
   berupa receipt bertanda tangan arsip: hash, waktu, object id, signature.
5. Purge lokal hanya jika semua benar:
   - umur dokumen >= 1 tahun;
   - receipt arsip tersimpan dan terverifikasi;
   - relay sudah ack dokumen;
   - outbox dokumen kosong.
6. Purge menghapus pohon service/nota: `service_records`, `service_jobs`,
   `service_parts`, `payments`, `sale_returns`, `service_record_commissions`,
   `nota_adjustments`, struk, dan lampiran. Tidak menghapus `stock_movements`,
   `cash_ledger`, `business_audits`, master, pembelian, atau opname.
7. Purge berjalan per dokumen dengan batas batch, menulis audit, dan tidak
   pernah memanggil endpoint hapus arsip.
8. VPS arsip tidak memiliki endpoint delete. Data hanya bisa ditambah dan
   dibaca.
9. "Selamanya" hanya sah jika ada snapshot penyedia + salinan offsite dan uji
   restore. Satu VPS penyimpanan tanpa backup bukan arsip permanen.

### 3.7 Kunci dan Recovery

1. Store key dibuat acak; setiap perangkat menerima wrapped key dengan
   X25519 + HKDF; payload AES-GCM; envelope ditandatangani Ed25519.
2. Jalur utama recovery: akun Google owner + wrapped key di Google Drive app
   data + PIN owner. PIN tidak dikirim ke server.
3. Jalur darurat: offline recovery key dipegang admin. Admin memverifikasi
   identitas owner, mencatat audit, lalu membuka escrow. Kunci ini tidak
   disimpan di VPS.
4. Rotasi store key wajib saat perangkat dicabut. Envelope dan arsip menyimpan
   `key_version`; kunci lama disimpan agar payload historis tetap terbaca.
5. Perangkat baru masuk lewat persetujuan owner, bukan pembagian kunci manual.
6. Pencabutan perangkat membatasi akses baru; token arsip yang masih berlaku
   kedaluwarsa maksimal 24 jam. Ini risiko yang diterima dan dicatat.
7. Metadata yang terlihat server: store id, jenis dokumen, tanggal, ukuran,
   dan token HMAC nama. Tidak ada plaintext isi.

### 3.8 Logout, Reset, dan Restore

1. **Logout:** hentikan sync, hapus sesi/PIN aktif, pertahankan database,
   outbox, kunci, dan lisensi lokal. Tampilkan ringkasan outbox dan konfirmasi.
2. **Reset perangkat:** aksi terpisah di menu perangkat. Wajib autentikasi
   owner, hitung outbox, tawarkan ekspor/flush, konfirmasi berlapis, cabut
   perangkat di relay, lalu hapus database dan kunci lokal.
3. **Restore:** hanya setelah Google Sign-In owner; arsip harus milik toko
   yang sama; manifest diverifikasi; database saat ini di-backup; outbox yang
   lebih baru dipertahankan atau digabung; restore memakai staging +
   `recoverInterruptedRestore`.
4. Tidak ada restore dari layar pra-login.
5. Restore tidak boleh menimpa arsip VPS.

---

## 4. Arsitektur Target

```
HP kasir / tablet / PC owner
   │                                   │
   │ HTTPS: auth, sync, envelope       │ HTTPS: upload/search arsip
   ▼                                   ▼
VPS 1 — Komunikasi                VPS 2 — Penyimpanan
relay + PostgreSQL operasional    API arsip + object storage
- Google login                    + indeks HMAC (append-only)
- enrollment perangkat            - ciphertext per dokumen
- ingest/feed/ack/snapshot        - stream envelope
- token arsip berumur pendek      - receipt bertanda tangan
   │                                   │
   └──────── token ────────────────────┘
        (relay menandatangani, arsip memverifikasi)
```

### 4.1 Tanggung Jawab

| Komponen | Boleh | Tidak boleh |
|---|---|---|
| Client | membuat nota, menghitung stok, enkripsi/dekripsi, upload arsip | mengirim plaintext, menghapus arsip |
| Relay | auth, envelope, feed, ack, snapshot, token arsip | membaca isi, menghitung stok, menghapus arsip |
| Arsip | simpan ciphertext, indeks HMAC, receipt, pencarian | dekripsi, kalkulasi bisnis, delete |
| Google | identitas owner, Drive app data | menyimpan PIN atau plaintext |

### 4.2 Alur

**Penjualan:** kasir membuat nota → SQLite transaction (nota + baris + bayar +
kas + stok + komisi + audit + outbox) → UI langsung selesai → sync ke relay
dipicu (debounce 1,5 detik) dan arsip upload berjalan paralel di background.

**Sync:** outbox → envelope terenkripsi + tanda tangan → relay verifikasi →
feed perangkat lain → dekripsi lokal → apply idempoten → ack → cursor maju.
Sync menjadi jalur utama; arsip tidak boleh menahan sync.

**Arsip:** bundle dokumen + envelope → enkripsi → upload ke arsip → receipt →
client simpan receipt. Jika arsip mati, penjualan dan sync tetap jalan; upload
di-retry.

**Pencarian:** cari lokal → jika kosong, tombol "Cari di server" → kirim exact
nota/token HMAC/rentang tanggal → arsip kembalikan ciphertext + metadata →
client dekripsi dan tampilkan struk.

**Purge:** dokumen umur 1 tahun + receipt + ack + outbox kosong → hapus pohon
lokal → audit. Arsip tidak disentuh.

**Recovery:** Google Sign-In → unduh wrapped key dari Drive → PIN owner →
unwrap → perangkat baru aktif. Jika Google hilang → admin + offline key +
verifikasi identitas + audit.

### 4.3 API Arsip

| Endpoint | Fungsi | Otorisasi |
|---|---|---|
| `POST /v1/documents` | upload idempoten | token scope `archive:write` |
| `GET /v1/documents/{id}` | ambil ciphertext | token scope `archive:read` |
| `POST /v1/search` | cari exact nota/token/tanggal | token scope `archive:read` |
| `GET /v1/receipts/{id}` | receipt | token scope `archive:read` |
| `POST /v1/archive-token` | terbitkan token (di relay) | device token + store |

Token: JWT ditandatangani relay, `aud=archive`, `store_id`, `device_id`,
scope, `exp` 24 jam. Arsip memverifikasi tanda tangan dengan public key relay;
tidak ada scope delete. Relay tidak memegang kredensial tulis arsip.

### 4.4 Skema Arsip

```text
archive_documents
  id, store_id, doc_type, doc_id, request_id, content_hash,
  ciphertext_path, size_bytes, doc_date, key_version, schema_version,
  archived_at, receipt_signature

archive_index_tokens
  store_id, doc_type, token_hmac, doc_id
  (token = HMAC search_key atas nomor nota atau kata nama ternormalisasi)

archive_receipts
  store_id, doc_id, content_hash, object_id, archived_at, signature

archive_envelopes
  store_id, envelope_id, device_id, seq, hlc, ciphertext_path, received_at
```

Tidak ada kolom plaintext nama, telepon, item, harga, atau nominal.

### 4.5 Kegagalan

| Kondisi | Perilaku |
|---|---|
| Relay mati | jual tetap; sync tertunda; arsip upload jalan selama token cache berlaku; purge menunggu ack |
| Arsip mati | jual dan sync tetap; pencarian arsip dan purge tertunda; upload retry |
| Keduanya mati | operasi lokal penuh; tidak ada purge; tidak ada pencarian arsip |
| Storage arsip penuh | upload ditolak dengan pesan kuota; alert; jual tetap jalan |
| Kunci hilang | sync berhenti dengan pesan actionable; jalur recovery ditampilkan |

### 4.6 Konfigurasi

- `PUSATKU_SERVICE_URL` — relay.
- `PUSATKU_ARCHIVE_URL` — arsip.
- Dua sertifikat TLS; health check terpisah.
- Port database tidak pernah publik; arsip di belakang HTTPS (opsional tunnel).
- Kuota per toko, alert kapasitas, snapshot penyedia, salinan offsite.

---

## 5. Urutan Eksekusi dan Gate

| Fase | Fokus | Menjaga | Tidak menjaga | Bypass jika dilewati |
|---|---|---|---|---|
| F0 | Guard data/keuangan | logout/restore tidak menghapus data; void-retur tidak double refund; DB aman | integritas schema, arsip | data hilang sebelum sempat diperbaiki |
| F1 | Baseline schema & integritas | model harga/stok/audit lengkap; duplikat terdeteksi | perilaku UI | bug baru menumpuk di schema lama |
| F2 | Konsistensi transaksi | satu aturan harga/approval/void | laporan dan arsip | aturan lokal/remote berbeda |
| F3 | Harga & pembayaran | struk dan total dapat direkonsiliasi | stok dan sync | selisih uang tidak terlacak |
| F4 | Stok & valuasi | saldo = movement; HPP konsisten; kasir satu-satunya penulis | sync dan arsip | stok negatif/HPP salah menyebar |
| F5 | Outbox & sync dekat real-time | commit memicu sync; status per dokumen; riwayat dapat dicari | relay dan arsip | transaksi tidak sampai ke perangkat lain |
| F6 | Sync lanjutan & idempotensi | tidak ada duplikasi/kehilangan lintas perangkat | arsip permanen | konflik menyebar |
| F7 | Arsip & pencarian | data 2 tahun dapat dicari; purge aman | siklus kunci | purge menghapus satu-satunya salinan |
| F8 | E2EE & siklus kunci | perangkat dicabut tidak membuka payload baru; recovery | error UI | kunci hilang = riwayat hilang |
| F9 | Error & recovery | kegagalan tidak merusak data lain; pesan actionable | performa | error tersembunyi |
| F10 | Performa & pembulatan | query 2 tahun dan aritmetika integer | fitur baru | laporan lambat/selisih sen |

Gate rilis:

- **P0 (F0):** tidak ada jalur UI/service yang menghapus/mengganti DB tanpa cek
  outbox dan autentikasi owner; double refund tidak mungkin.
- **P1 (F1–F4):** nota nego punya acuan + grant + audit; opname tidak memacetkan
  antrean; laporan dapat direkonsiliasi ke nota.
- **P2 (F5–F8):** sync dua perangkat selesai <= 30 detik pada jaringan baik;
  tidak ada duplikasi/kehilangan; arsip 2 tahun berfungsi; perangkat dicabut
  tidak membuka payload baru.
- **Produksi:** P0–P2 lulus pada salinan data nyata, bukan hanya DB kosong.

---

## 6. Task

Nomor `#xx` merujuk task tracker yang sudah ada. Nomor `(baru)` adalah task
yang ditambahkan oleh dokumen ini dan harus dibuat di tracker saat fase dimulai.

### F0 — Guard (tanpa schema)

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F0-1 | Ringkasan outbox sebelum logout (#26) | `entry_gate.dart`, `home_shell.dart`: hitung pending/failed, dialog konfirmasi, opsi ekspor | Logout dengan pending selalu menampilkan ringkasan; tidak ada logout diam-diam | — |
| F0-2 | Hentikan hapus DB saat logout (#27) | `signOutSession`: jangan hapus DB/kunci; tambah alur `resetDevice` terpisah | Logout mempertahankan DB dan outbox; reset hanya lewat aksi owner | F0-1 |
| F0-3 | Autentikasi owner sebelum restore (#28) | `backup_service.dart`, layar pra-login: Google Sign-In owner + store id | Restore tanpa owner ditolak; toko berbeda ditolak | — |
| F0-4 | Restore tidak membuang outbox baru (#29) | Bandingkan manifest/outbox; merge atau tahan restore; staging | Outbox lebih baru tidak hilang setelah restore | F0-3 |
| F0-5 | Satukan aturan void/retur (#30) | `sale_return_service.dart`, `note_sync.dart`, `sync_conflict_rules.dart`: tolak void saat retur aktif | Void lokal/remote sama-sama ditolak saat retur aktif | — |
| F0-6 | Filter retur aktif saat restock void (#31) | Query restock memakai qty retur aktif | Qty yang sudah diretur tidak diretur dua kali | F0-5 |
| F0-7 | Karantina WAL/SHM (#32) | Safe mode memindahkan `.db`, `-wal`, `-shm` bersama | Tidak ada transaksi commit yang hilang dari karantina | — |
| F0-8 | busy_timeout + journal mode (#33) | `AppDatabase.open`: `busy_timeout`, journal eksplisit, pesan sibuk | Backup/restore bersamaan tidak memicu `database is locked` mentah | — |
| F0-9 | Audit trail aksi istimewa (#34) | Satu service audit untuk void, stok manual, katalog, restore, reset, grant | Setiap aksi istimewa punya aktor, alasan, before/after | — |
| F0-10 | Banner offline 24 jam (#35) | `home_shell.dart` + `SyncService.status()`: pakai waktu sync sukses terakhir; jika belum pernah, pakai `created_at` dokumen pending tertua | Banner muncul setelah 24 jam tanpa sync sukses; pesan konflik berbeda | D17 |

### F1 — Baseline Schema & Integritas

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F1-1 | Baseline schema baru (baru) | `schema.dart`: tabel `archive_receipts`, kolom/indeks yang kurang; versi baseline baru; tanpa rantai migrasi | DB baru membuat seluruh tabel; tidak ada kolom legacy | F0 |
| F1-2 | Deteksi duplikat sebelum unique index (baru) | Query audit `request_id`, `no_nota`, movement; laporan duplikat; dedupe manual | Tidak ada index yang gagal karena data duplikat | F1-1 |
| F1-3 | Rekonsiliasi ledger vs saldo (baru) | Laporan selisih stok/kas; tidak mengubah data | Saldo = jumlah movement terlihat; selisih punya daftar | F1-1 |
| F1-4 | Kebijakan non-negatif (baru) | Guard lokal + laporan; tidak memasang CHECK saldo | Penjualan lokal tidak negatif; sync negatif tetap terlihat | F1-1 |

Catatan: karena belum ada pengguna produksi, database dev lama di-backup lalu
dibuat ulang. Tidak ada `ALTER TABLE` bertahap.

### F2 — Konsistensi Transaksi

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F2-1 | Harga acuan dan final (#21) | `JobDraft` + dialog POS: jasa manual punya "Harga normal" dan "Harga disepakati"; `createTransaction` memakai acuan, bukan harga final | Nota nego menyimpan acuan 350.000 dan final 325.000; struk menampilkan keduanya | F1 |
| F2-2 | Grant persetujuan tunggal (#21/#34) | `approval_service.dart` mengembalikan grant; `createTransaction` memakai grant; audit mencatat approver/alasan/baris | Satu PIN mengizinkan semua baris di bawah modal pada transaksi itu; tidak ada `approvedByOverride` tanpa verifikasi | F2-1 |
| F2-3 | Alasan diskon dari POS (#21) | Kirim `alasanDiskon`; wajib saat final < acuan; bedakan gratis vs diskon 100% | Tidak ada diskon tanpa alasan; laporan bisa membedakan | F2-1 |
| F2-4 | Idempotensi pembelian/retur pembelian (baru) | `purchase_service.dart`: `request_id` + hash untuk purchase dan purchase return | Retry UI tidak menggandakan pembelian/retur | F1 |
| F2-5 | Audit katalog/stok/void (#34) | Panggil audit service dari `saveCatalog`, `deleteCatalog`, stok manual, void | Semua aksi punya jejak aktor dan alasan | F0-9 |
| F2-6 | Hapus jalur approval palsu (baru) | Hapus/validasi `approvedByOverride` yang dipercaya tanpa verifikasi | Tidak ada approver string yang bisa dipalsukan UI | F2-2 |

### F3 — Harga & Pembayaran

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F3-1 | Struk acuan vs final (#51 baru) | `receipt_service.dart`: tampilkan acuan, diskon, final | Struk dapat direkonsiliasi ke baris nota | F2-1 |
| F3-2 | Uang diterima vs kembalian (#51) | Simpan/print nominal mentah dan ter-clamp; jangan menampilkan angka yang tidak tersimpan | Struk dan DB menunjukkan angka yang sama | F3-1 |
| F3-3 | Bayar penuh tanpa pembulatan (#51) | Tombol bayar penuh memakai total sen; transfer tidak ditolak karena pembulatan | Total 325.001 dapat dibayar penuh via transfer | F3-2 |
| F3-4 | Negosiasi per item (#21) | UI mengizinkan final berbeda per baris; alokasi diskon nota tetap proporsional | Dua baris dapat punya final berbeda dengan alasan masing-masing | F2-1 |
| F3-5 | Modal baris = HPP ledger (#38) | `PriceLine.hargaModal` dari HPP rata-rata; movement keluar menyimpan unit cost | Laba baris memakai HPP, bukan harga master | F4-3 |
| F3-6 | Snapshot pajak UI = service (#22) | Layar memakai `PajakSnapshot.hitung` yang sama dengan service; tidak ada hitung ganda | Angka layar = angka tersimpan | F2-1 |
| F3-7 | DPP/PPN penyesuaian (#22) | `nota_adjustment_service.dart` memisahkan jasa/part/diskon dan DPP/PPN | Rekap pajak cocok dengan detail penyesuaian | F3-6 |
| F3-8 | Qty sesuai satuan (#51) | Validasi qty bulat/desimal per satuan; qty < 1 ditolak, bukan dipotong 0 | Tidak ada baris qty 0 karena pembulatan | F1 |

### F4 — Stok & Valuasi

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F4-1 | Opname absolut + isolasi (#37) | `opname_service.dart`: absolut + basis + request id; hold gagal tidak memblokir | Opname basi masuk konflik, antrean lain tetap jalan | F1 |
| F4-2 | Retur: clamp & filter (#31/#52 baru) | Pembatalan retur membatasi qty; restock void memfilter retur aktif | Tidak ada stok ganda dari retur/void | F0-5 |
| F4-3 | HPP saldo negatif (#38) | `stock_ledger.dart`: jangan menggelembungkan rata-rata saat saldo <= 0 | HPP setelah koreksi negatif tidak melonjak | F1 |
| F4-4 | Movement masuk/keluar eksplisit (#39) | Nota baru menulis movement masuk; keluar menyimpan unit cost; `rebuild` terkontrol | Saldo = movement; tidak ada saldo tanpa asal | F1 |
| F4-5 | Retur memakai snapshot modal (#39) | Retur membaca HPP dari movement penjualan, bukan master | Refund modal akurat setelah harga master berubah | F4-4 |
| F4-6 | Kartu stok + rekonsiliasi (#52) | `stock_screen.dart`: riwayat movement per item, saldo, selisih | Kasir dapat melihat asal saldo dan menandai negatif | F4-4 |
| F4-7 | Kasir satu-satunya penulis (#41/#42/#43) | Permission tablet read-only; sync sebelum keputusan stok; blokir qty > saldo | Tablet tidak bisa menjual/mengubah stok; offline kurang ditolak | F4-1 |
| F4-8 | Uji stok kasir/tablet (#44) | Skenario offline, reconnect, opname, retur, void, force close | Tidak ada selisih saldo pada semua skenario | F4-7 |

### F5 — Outbox, Sync Dekat Real-Time, Riwayat

Sync adalah jalur utama pengguna premium. Fase ini memastikan setiap commit
langsung dikirim, terlihat di perangkat lain dalam hitungan detik, dan setiap
kegagalan punya status yang dapat dibaca kasir.

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F5-0 | Pemicu sync premium (baru) | `sync_scheduler.dart` + `sync_service.dart`: ganti interval 10–20 menit dengan fallback 60 detik; tambah `connectivity_plus` + health check relay, debounce 1,5 detik setelah commit, resume, tarik manual; satu sync in-flight | Commit terlihat di perangkat lain <= 30 detik; reconnect memicu sync; timer 60 detik bekerja saat foreground | F0-1 |
| F5-1 | Status sync per dokumen (baru) | `sync_service.dart` + riwayat: badge pending/acked/failed/dead-letter | Kasir tahu dokumen mana yang belum terkirim | F5-0 |
| F5-2 | Paginasi & filter riwayat (baru) | `listRecords` + `history_screen.dart`: limit/offset, tanggal, nomor, nama | Nota ke-201 dapat dibuka; filter tanggal bekerja | F1 |
| F5-3 | Panel status sync utama (baru) | HomeShell: waktu sync terakhir, jumlah pending/failed, online/offline relay, aksi sync manual; banner 24 jam dari F0-10 sebagai fallback | Kasir melihat keterlambatan > 5 menit tanpa membuka riwayat; banner hanya muncul saat benar-benar tertinggal | F5-1 |
| F5-4 | Guard logout/restore (#26/#29) | Lihat F0-1/F0-4; tambah uji regresi | Tidak ada jalur kehilangan outbox | F0 |
| F5-5 | Uji force close (#44) | Matikan proses di setiap titik transaksi/sync/restore | Nota commit bertahan; sync mengulang tanpa duplikasi; pemicu sync pulih setelah restart | F5-0 |
| F5-6 | Cakupan laporan & VOID (baru) | Piutang/kas satu definisi; badge VOID; ekspor owner lengkap | Angka antar layar sama; nota VOID terlihat | F3 |

### F6 — Sync Lanjutan & Idempotensi

Fase ini menangani kasus yang lebih sulit dari sync normal: retry panjang,
envelope rusak, konflik domain, dan perangkat yang lama tidak aktif. Offline
tidak dianggap mode normal; setiap kegagalan sync harus terlihat dan pulih
otomatis saat jaringan kembali.

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F6-1 | Dead-letter & error kripto (baru) | `sync_service.dart`: batas retry, dead-letter, pesan kunci/token | Envelope rusak tidak menahan cursor; pesan actionable | F5-1 |
| F6-2 | Kuota & pruning relay (baru) | `relay/config.dart`, `server.dart`: alert 413, pruning setelah ack perangkat aktif; heartbeat 30 hari | Perangkat mati lama tidak menahan pruning; storage penuh tidak menghentikan pengiriman diam-diam | F6-1 |
| F6-3 | Konflik domain & feature flag (baru) | `sync_conflict_rules.dart`, `feature_flags.dart`: void/retur/opname/flag; induk mati = anak mati | Tidak ada dua aturan berbeda; flag konsisten | F4 |
| F6-4 | Idempotensi permanen & snapshot (baru) | `applied_deltas` jangka panjang; verifikasi HLC snapshot | Retry lama tidak menggandakan; snapshot basi ditolak | F6-3 |
| F6-5 | Audit status tablet (#34) | Status work order mencatat aktor/waktu/HLC | Perubahan tablet dapat diaudit | F6-3 |
| F6-6 | Uji dua perangkat (baru) | Simulasi commit→sync <= 30 detik, putus-nyambung, retry, perangkat mati, konflik | Tidak ada duplikasi/kehilangan; latensi target terukur | F6-4 |

### F7 — Arsip & Pencarian

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F7-1 | Payload arsip lengkap (#49) | Dokumen kanonik per nota + envelope stream; schema/key version | Komisi dan penyesuaian ikut terarsip | F1 |
| F7-2 | Skema arsip (#9) | Tabel `archive_documents`, `archive_index_tokens`, `archive_receipts`, `archive_envelopes` | Skema immutable; tidak ada kolom plaintext | F7-1 |
| F7-3 | API arsip (#10) | Upload/receipt/search/get; token relay; tanpa delete | Upload idempoten; token tidak bisa menghapus | F7-2 |
| F7-4 | ArchiveClient (#11) | Base URL arsip, token, retry, simpan receipt | Upload tidak memblokir jual/sync | F7-3 |
| F7-5 | Purge bertahap (#40) | `purge_service.dart`: umur + receipt + ack + outbox kosong; audit | Purge hanya setelah arsip terverifikasi | F7-4 |
| F7-6 | Uji e2e arsip (#12) | Dua layanan terpisah; backlog, duplikat, search, arsip mati, purge tertahan | Semua skenario lulus | F7-5 |
| F7-7 | Durabilitas arsip (#48) | Snapshot penyedia + offsite + uji restore; RPO/RTO | Kerusakan satu VPS tidak menghapus arsip | F7-2 |
| F7-8 | Pencarian arsip & riwayat (#54 baru) | Tombol "Cari di server", paginasi, dekripsi lokal, tampilan struk | Nota 2 tahun ditemukan saat online | F7-4 |
| F7-9 | Operasional relay/arsip (#23/#13) | TLS, CORS, kuota, monitoring, backup PostgreSQL, dua URL | Deployment dua VPS terdokumentasi dan teruji | F7-7 |

### F8 — E2EE & Siklus Kunci

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F8-1 | Escrow recovery (#45) | Google Drive wrapped key + PIN; admin offline key; audit | Perangkat hilang dapat dipulihkan; admin tidak bisa diam-diam | F7 |
| F8-2 | Rotasi kunci (baru) | `key_version`, rewrap perangkat aktif, simpan kunci lama | Perangkat dicabut tidak membuka payload baru | F8-1 |
| F8-3 | Enrollment perangkat (baru) | Persetujuan owner; daftar perangkat paginasi + audit; hapus pembagian kunci manual | Tidak ada batas jumlah perangkat; perangkat baru tidak memegang kunci tanpa izin | F8-2 |
| F8-4 | Metadata & blind index (baru) | Token HMAC nama/nota; dokumentasi kebocoran | Pencarian tanpa plaintext | F7-2 |
| F8-5 | Transport & error (baru) | TLS default, CORS terbatas, error server minimal | Tidak ada endpoint permisif | F7-9 |
| F8-6 | PIN & DB desktop (baru) | Hapus hash PIN dari `app_meta`; SQLCipher/BitLocker + ACL | DB desktop tidak plaintext | F1 |
| F8-7 | Viewer & role (baru) | `runViewerWrite` dikunci; `role_base=owner` divalidasi; katalog berizin | Viewer tidak bisa menulis; role tidak escalates | F1 |
| F8-8 | Uji recovery (baru) | Google hilang, perangkat hilang, akun diambil alih, rotasi | Semua jalur recovery terbukti | F8-1 |

### F9 — Error & Recovery

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F9-1 | Diagnosis sebelum safe mode (baru) | Startup membaca error sebelum memindahkan DB | Penyebab terlihat; data tidak langsung dikarantina | F0-7 |
| F9-2 | Antrean cetak (baru) | Status cetak per nota, retry, cetak ulang | Printer gagal tidak menghilangkan struk | F3 |
| F9-3 | Pesan kripto/token (baru) | Petakan error ke instruksi; arahkan ke recovery | Pengguna tahu langkah berikutnya | F6-1 |
| F9-4 | Uji kegagalan (baru) | Storage penuh, DB locked, token kedaluwarsa, arsip mati | Tidak ada data lain yang rusak | F8 |
| F9-5 | Health surface (baru) | Ringkasan backup/sync/arsip di HomeShell | Kegagalan berkepanjangan terlihat | F5-3 |

### F10 — Performa & Pembulatan

| ID | Task | Perubahan utama | Terima | Dep |
|---|---|---|---|---|
| F10-1 | Index & query 2 tahun (baru) | Index pencarian/paginasi; ukur laporan pada data 2 tahun | Riwayat/pencarian dalam batas waktu | F7 |
| F10-2 | Aritmetika integer (baru) | Hilangkan REAL di agregasi; satu aturan pembulatan | Tidak ada selisih 1–2 sen | F3 |
| F10-3 | Snapshot/feed (baru) | Ukur dan optimasi snapshot/feed | Sync besar tetap wajar | F6 |

---

## 7. Peta Temuan ke Fase

Semua temuan audit harus punya rumah. Tabel ini yang menjamin tidak ada yang
terlewat.

| Temuan | Fase/Task |
|---|---|
| SEC-01, FLW-01 | F0-3 |
| SEC-02, OFF-01 | F0-1, F0-2 |
| SEC-03, DB-06, ERR-03 | F0-7 |
| SEC-04, OFF-02 | F0-4 |
| SEC-05, FLW-06 | F8-7 |
| SEC-06, SEC-07 | F8-7 |
| SEC-08 | F2-2 |
| SEC-09, SEC-10 | F8-6 |
| SEC-11, FLW-03 | F9-1 |
| SEC-12 | F8-2 |
| SEC-13 | F8-1 |
| SEC-14, SEC-15 | F8-5 |
| SEC-16 | F8-4 |
| TRX-01, TRX-02 | F2-1 |
| TRX-03, TRX-04 | F3-1, F3-2, F3-3 |
| TRX-05 | F3-4 |
| TRX-06 | F3-5 |
| TRX-07 | F2-1, F2-3 |
| TRX-08 | F2-2 |
| TRX-09 | F10-2 |
| TRX-10 | F3-8 |
| TRX-11, TRX-12 | F3-6, F3-7 |
| REP-01..REP-05 | F3-6, F3-7 |
| REP-06, FLW-04 | F5-6 |
| REP-07, REP-09 | F5-6 |
| REP-08, DB-04 | F10-2 |
| INV-01, INV-11, INV-13 | F4-1 |
| INV-02 | F0-6 |
| INV-03 | F0-5 |
| INV-04 | F4-3 |
| INV-05 | F4-5 |
| INV-06, INV-08 | F4-4 |
| INV-07 | F4-2 |
| INV-09 | F0-9, F2-5 |
| INV-10 | F4-6 |
| INV-12 | F2-4 |
| INV-14, DB-01 | F1-4 |
| DB-02, ERR-04 | F0-8 |
| DB-03, OFF-05 | F8-6 |
| DB-05 | F1-1 |
| OFF-03, SYN-08 | F5-1 |
| OFF-04 | F5-5 |
| OFF-06 | F0-7 |
| SYN-01, ERR-06 | F6-2 |
| SYN-02, SYN-03, ARC-06 | F7 |
| SYN-04 | F6-4 |
| SYN-05 | F8-3 |
| SYN-06 | F6-4 |
| SYN-07 | F7-8 |
| SYN-09 | F6-5 |
| ARC-01 | F2-1 |
| ARC-02 | F3-5 |
| ARC-03 | F0-5 |
| ARC-04 | F0-9, F2-5 |
| ARC-05, ERR-05 | F5-3, F9-5 |
| FLW-02 | F5-2, F7-8 |
| FLW-05 | F0-1 |
| ERR-01 | F9-2 |
| ERR-02, ERR-07, ERR-08 | F6-1, F9-3 |
| FLG-01, FLG-02, FLG-03 | F6-3 |
| FLG-04 | Uji regresi F6-3 |
| SC-01 | F2, F3 |
| SC-02 | F0, F4, F6 |
| SC-03 | F5, F7 |
| SC-04 | F7 |
| SC-05 | F8 |

---

## 8. Rencana Uji

### 8.1 Lapisan

| Lapisan | Isi | Lokasi |
|---|---|---|
| Unit | harga, pajak, alokasi diskon, HPP, opname, retur, purge, payload arsip | `pusatkupos/test/` |
| Integrasi | transaksi SQLite, apply sync, endpoint relay, API arsip | `pusatkupos/test/`, `relay/test/`, `archive/test/` |
| E2E | dua perangkat, dua VPS, force close, restore, recovery | harness baru |
| Data nyata | salinan DB produksi/dev yang berisi data, bukan DB kosong | manual + skrip uji |

### 8.2 Uji wajib per fase

- **F0:** logout dengan outbox; restore pra-login; void saat retur; WAL/SHM;
  DB locked.
- **F1:** schema baru; deteksi duplikat; rekonsiliasi ledger.
- **F2:** nego 350.000 → 325.000; harga di bawah modal; harga nol; grant
  tunggal; audit.
- **F3:** struk vs DB vs laporan; bayar penuh transfer; pajak inklusif/
  eksklusif; penyesuaian.
- **F4:** opname basi; stok negatif; retur/void; movement sources; tablet
  read-only; reconnect.
- **F5:** 50 nota berturut-turut → commit → perangkat lain <= 30 detik; tutup
  paksa → restart → sync; reconnect; timer 60 detik; riwayat 201+; filter
  tanggal.
- **F6:** dua perangkat; commit → sync <= 30 detik; putus-nyambung; retry;
  envelope rusak; perangkat lama; feature flag; konflik.
- **F7:** upload backlog; duplikat; search 2 tahun; arsip mati; purge tertahan;
  restore arsip.
- **F8:** perangkat dicabut; Google hilang; admin recovery; rotasi.
- **F9:** storage penuh; cetak gagal; token kedaluwarsa.
- **F10:** query 2 tahun; selisih pembulatan.

### 8.3 Skenario SC-01..SC-05

| Skenario | Target |
|---|---|
| SC-01 nego offline | acuan + final + grant + struk + laporan |
| SC-02 multi-device | tidak ada duplikasi/kehilangan; void/retur/opname konsisten |
| SC-03 riwayat 1 tahun | lokal 1 tahun + purge aman; arsip VPS lengkap |
| SC-04 cari 2 tahun | pencarian server + dekripsi lokal + struk |
| SC-05 E2EE | server buta isi; recovery/rotasi terbukti |

---

## 9. Peta File

| Area | File utama |
|---|---|
| Transaksi/harga | `lib/data/app_database.dart`, `lib/data/price_rules.dart`, `lib/data/models.dart`, `lib/ui/screens/pos_screen.dart` |
| Pajak/laporan | `lib/data/pajak.dart`, `lib/data/nota_adjustment_service.dart`, layar laporan |
| Stok | `lib/data/stock_ledger.dart`, `lib/data/opname_service.dart`, `lib/data/sale_return_service.dart`, `lib/ui/screens/stock_screen.dart` |
| Sync | `lib/sync/sync_service.dart`, `lib/sync/sync_scheduler.dart`, `lib/sync/sync_conflict_rules.dart`, `lib/sync/relay_client.dart`, `lib/sync/crypto.dart` |
| Offline/backup | `lib/ui/entry_gate.dart`, `lib/data/backup_service.dart`, `lib/ui/home_shell.dart` |
| E2EE/identitas | `lib/data/google_auth_service.dart`, `lib/data/session_service.dart`, `lib/data/secure_store.dart` |
| Relay | `relay/lib/server.dart`, `relay/lib/db.dart`, `relay/lib/config.dart`, `relay/lib/auth_rules.dart` |
| Arsip baru | `archive/` (service, schema, API, test) |
| Uji | `pusatkupos/test/`, `relay/test/`, `archive/test/` |

---

## 10. Yang Tidak Dilakukan

- Tidak ada rantai migrasi/kolom legacy.
- Offline tidak dianggap mode normal; tidak ada alur yang membiarkan transaksi
  menumpuk tanpa status sync dan peringatan.
- Tidak ada plaintext transaksi di relay atau arsip.
- Tidak ada perhitungan stok di server.
- Tidak ada auto-perbaikan data historis.
- Tidak ada notifikasi OS untuk peringatan 24 jam.
- Tidak ada endpoint hapus arsip.
- Tidak ada pencarian teks bebas di server.
- Tidak ada penjualan negatif lokal.
- Tidak ada restore tanpa owner.
- Tidak ada logout yang menghapus data.

---

## 11. Risiko dan Mitigasi

| Risiko | Mitigasi |
|---|---|
| Satu VPS arsip rusak = arsip hilang | Snapshot + offsite + uji restore (F7-7) |
| Token arsip dicabut terlambat (24 jam) | TTL pendek, audit, rotasi kunci (F8-2) |
| Satu perangkat offline lama menahan pruning | Perangkat aktif = heartbeat <= 30 hari; re-enroll + snapshot saat kembali (F6-2) |
| Sync tertunda tanpa terlihat | Status sync utama + ambang 5 menit + banner 24 jam (F5-0/F5-3) |
| Keputusan stok memakai data basi | Sync paksa 5 detik bila sync terakhir > 5 menit; gagal = perlakukan sebagai offline dan blokir (F4-7) |
| Polling 60 detik membebani relay | Debounce, satu sync in-flight, backoff, dan event konektivitas (F5-0/F6-1) |
| Opname basi jika ada penulis stok lain | Tegakkan kasir satu-satunya penulis (F4-7); jika tidak, ubah ke HLC absolut |
| Payload arsip tidak lengkap | Kontrak payload + uji komisi/penyesuaian (F7-1) |
| Storage tumbuh selamanya | Kuota, monitoring, rencana ekspansi (F7-9) |
| Reset schema menghapus DB dev | Backup wajib sebelum upgrade; hanya selama belum ada pengguna produksi |
| Kunci hilang | Google + admin offline key + uji recovery (F8-1/F8-8) |
| Laporan lama tidak dapat direkonsiliasi setelah purge | Arsip + pencarian + dekripsi lokal (F7-8) |

---

## 12. Definisi Selesai

Satu putaran implementasi dinyatakan selesai jika:

1. F0–F8 lulus gate dan seluruh temuan di §7 punya bukti uji.
2. Target §1.1 terbukti: commit memicu sync <= 1,5 detik, perangkat lain
   menerima <= 30 detik pada jaringan baik, fallback 60 detik berjalan, dan
   keterlambatan > 5 menit selalu terlihat di UI.
3. Tidak ada jalur kehilangan data yang tersisa: logout, restore, reset, purge,
   void/retur, opname, sync, kunci.
4. Skenario SC-01..SC-05 lulus pada salinan data nyata.
5. Dua VPS berjalan terpisah: relay tidak bisa menghapus arsip; arsip tidak
   bisa membaca plaintext.
6. Riwayat 1 tahun lokal + pencarian 2 tahun via arsip bekerja.
7. Semua default di §2 tercatat; jika ada yang diubah, dokumen ini diperbarui
   sebelum kode berubah.
