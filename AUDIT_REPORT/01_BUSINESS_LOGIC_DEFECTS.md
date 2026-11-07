# 01 — Register Cacat Logika Bisnis

**Metode:** analisis kode statis dan inspeksi source code. Tidak ada test, build, aplikasi, server, scanner, atau simulasi runtime yang dijalankan; tidak ada source code yang diubah.

Dokumen ini adalah register lengkap 42 temuan. Setiap temuan memuat ID, nama cacat, kategori, tingkat risiko, status validitas, lokasi berkas/baris, bukti source, alur sebab-akibat, skenario masalah, dampak bisnis, dampak integritas data, dan rekomendasi perbaikan. Analisis per area ada di berkas 02–10; urutan perbaikan di berkas 11.

**Legenda validitas:** CONFIRMED = dapat dibuktikan langsung dari kode; SUSPECTED = mekanisme terbukti, kejadian bergantung kondisi operasional yang tidak dijalankan pada audit statis; NEEDS VALIDATION = memerlukan konfirmasi aturan bisnis.

---

## BL-01 — Opname stok absolut dikirim sebagai delta ke perangkat lain

- **Kategori:** Inventori / Sinkronisasi
- **Tingkat risiko:** KRITIS
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:1005-1052`; `pusatkupos/lib/sync/sync_service.dart:1032-1060`; `pusatkupos/lib/sync/sync_service.dart:2947-2981`
- **Bukti source:** `opname()` menghitung `delta = jumlahFisikMilli - before.jumlahMilli`, menulis `jumlah_milli` absolut ke `stock_items`, lalu membuat movement `KOREKSI` sebesar `delta`. `enqueueStock()` **tidak** mengirim `jumlah/jumlah_milli` (hanya kode, nama, harga, minimum, satuan, desimal). Penerima memakai cabang `entity == 'stock'` untuk metadata dan movement `jumlah_milli` sebagai `next = before.jumlahMilli + qtyMilli`.
- **Alur sebab-akibat:** Opname di perangkat A → A menulis stok absolut dan mengirim delta relatif terhadap stok A. Perangkat B menerima movement dan menambahkan delta itu ke stok B yang mungkin sudah berbeda → stok B tidak pernah menjadi angka fisik yang dihitung A.
- **Skenario masalah:** A dan B sama-sama offline, stok awal 10. A menjual 2 (stok 8), B menjual 3 (stok 7). A melakukan opname fisik 10 → delta +2. B menerima delta +2 → stok B menjadi 9, bukan 10. Selisih ini berulang setiap opname.
- **Dampak bisnis:** Stok fisik dan stok sistem tidak pernah rekonsiliasi; barang bisa dianggap tersedia padahal habis, atau sebaliknya; nilai persediaan dan laba kotor part salah.
- **Dampak integritas data:** `stock_items.jumlah_milli` menyimpang permanen; `stock_movements` tidak lagi dapat direkonsiliasi dengan mutasi nyata; konflik `stok_negatif` dapat muncul tanpa sebab operasional.
- **Rekomendasi perbaikan:** Kirim nilai absolut opname sebagai field khusus (mis. `opname_absolut_milli`) dengan HLC dan nomor urut opname; penerima menetapkan nilai absolut bila HLC opname lebih baru, bukan menjumlahkan delta. Movement tetap dibuat sebagai catatan selisih lokal. Naikkan HLC `stock_items` pada setiap perubahan jumlah.

---

## BL-02 — Retur dan void lintas perangkat menghasilkan stok/nilai yang berbeda

- **Kategori:** Retur / Pembatalan / Sinkronisasi
- **Tingkat risiko:** KRITIS
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/note_sync.dart:309-398`; `pusatkupos/lib/data/note_sync.dart:922-1039`; `pusatkupos/lib/data/sale_return_service.dart:36-258`; `pusatkupos/lib/data/app_database.dart:2593-2765`
- **Bukti source:** `_upsertReturn` pada penerima tidak memeriksa apakah nota sudah `voided_at`, tidak membatasi jumlah retur terhadap jumlah terjual, dan langsung menambah stok (`retur-<return>-<item>`) sebelum dedupe movement. `voidRecord` lokal menolak void bila sudah ada retur, tetapi penerima void (`note_sync.dart:309-398`) hanya mengurangi stok sebesar qty part dikurangi retur yang **diketahuinya**; retur yang datang belakangan tetap diterapkan ke nota yang sudah VOID.
- **Alur sebab-akibat:** Dua perangkat offline menerima retur/void berbeda untuk nota yang sama. Saat sinkronisasi, masing-masing menerapkan keduanya tanpa aturan urutan/terminal state. Stok part dapat dipulihkan dua kali (retur + void) atau retur diterapkan pada nota VOID; payment REFUND dari retur tetap masuk.
- **Skenario masalah:** Nota 1 part qty 1. A membuat retur qty 1 (stok +1, refund). B (belum menerima retur) mem-void nota (stok +1 penuh, refund penuh). Setelah sinkron, stok bertambah 2 untuk barang yang hanya 1 keluar; pelanggan menerima dua refund.
- **Dampak bisnis:** Kerugian uang (refund ganda), stok fiktif, nota yang sudah dibatalkan masih memiliki retur aktif, dan laporan retur/void tidak dapat dipercaya.
- **Dampak integritas data:** `sale_returns`, `sale_return_items`, `service_payments`, `stock_items`, `stock_movements` saling bertentangan; status nota tidak lagi menjadi terminal state.
- **Rekomendasi perbaikan:** Jadikan VOID terminal state yang menolak/membatalkan retur berikutnya; tambahkan guard over-return di penerima (hitung total retur per line termasuk yang sudah ada); simpan penanda `voided_at` pada payload retur dan tolak retur bila nota void; gunakan idempotency key retur; terapkan movement dengan kunci unik dan HLC yang konsisten.

---

## BL-03 — Pembayaran gaji siklus yang sama dapat dilakukan dua perangkat lalu saling menimpa

- **Kategori:** Payroll / Keuangan / Sinkronisasi
- **Tingkat risiko:** TINGGI
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/employee_service.dart:277-356`; `pusatkupos/lib/data/schema.dart:709-732`; `pusatkupos/lib/sync/sync_service.dart:3337-3386`; `pusatkupos/lib/ui/screens/employees_screen.dart:119-161`
- **Bukti source:** `paySalary` memeriksa `salary_payments` untuk `cycle_start` **hanya di database lokal**, lalu menyisipkan pembayaran. Tabel memiliki `UNIQUE(employee_sync_id, cycle_start)` sehingga satu perangkat tidak dapat membuat dua baris, tetapi dua perangkat dapat masing-masing membuat satu baris dengan `sync_id` berbeda. Penerima `entity == 'salary'` mencari baris berdasarkan `employee_sync_id + cycle_start`; bila sudah ada, ia **memperbarui** baris itu (bukan mencatat konflik), dan `debt` diterapkan dengan `_remoteWins` berdasarkan HLC.
- **Alur sebab-akibat:** Perangkat A dan B offline sama-sama membayar siklus yang sama. Keduanya mencatat pengeluaran kas dan memotong hutang secara lokal. Saat sinkron, hanya satu baris gaji yang bertahan (satu menimpa yang lain), dan `employee_debts.terbayar` mengikuti versi HLC terbaru, bukan akumulasi dua pembayaran.
- **Skenario masalah:** Pemilik membayar gaji dari ponsel; kasir membayar siklus yang sama dari tablet yang belum sinkron. Uang keluar dua kali, tetapi laporan gaji hanya menunjukkan satu pembayaran dan potongan hutang tidak mencerminkan keduanya.
- **Dampak bisnis:** Kas keluar dua kali tanpa jejak pembayaran kedua; laporan gaji dan laba setelah gaji salah; saldo hutang karyawan tidak sesuai uang yang benar-benar dipotong.
- **Dampak integritas data:** Satu pembayaran hilang dari catatan karena digabung berdasarkan siklus; `salary_payments` dan `employee_debts` tidak dapat direkonsiliasi dengan kas.
- **Rekomendasi perbaikan:** Tambahkan kunci idempoten per siklus yang disepakati lintas perangkat (mis. hash `employee_sync_id + cycle_start`) dan perlakukan `sync_id` berbeda untuk siklus yang sama sebagai konflik yang harus ditinjau, bukan ditimpa; atau jadikan pembayaran gaji operasi yang memerlukan reservasi online di relay.

---

## BL-04 — Komisi dihitung ulang memakai tarif saat ini, bukan snapshot saat nota dibuat

- **Kategori:** Payroll / Komisi / Konsistensi
- **Tingkat risiko:** TINGGI
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:1828-1952` (khususnya 1912-1937)
- **Bukti source:** `recalculateRecordCommissions` membaca `employee_accounts.komisi_mode/komisi_barang_nilai/komisi_jasa_nilai` **saat rekalkulasi**. Bila baris akun tidak ditemukan, mode default `PERSEN` dan nilai 0 → nominal komisi menjadi 0 lalu disimpan.
- **Alur sebab-akibat:** Retur/koreksi memicu rekalkulasi → pembacaan tarif terkini → komisi nota lama berubah karena perubahan tarif setelah nota, bukan karena retur itu sendiri.
- **Skenario masalah:** Nota bulan lalu memakai komisi jasa 10%. Bulan ini pemilik menurunkan menjadi 5%, lalu pelanggan meretur 1 jasa. Rekalkulasi menghitung ulang **seluruh** komisi nota dengan 5% dan menimpa nominal lama.
- **Dampak bisnis:** Komisi yang sudah dijanjikan berubah surut; potensi sengketa dengan mekanik; payroll dan laba setelah komisi tidak stabil.
- **Dampak integritas data:** `service_record_commissions.nominal` tidak lagi mencerminkan kesepakatan saat transaksi; tidak ada jejak tarif yang dipakai.
- **Rekomendasi perbaikan:** Simpan snapshot tarif komisi (mode dan nilai) pada nota/komisi saat dibuat; rekalkulasi hanya memakai snapshot itu. Bila akun tidak ditemukan, pertahankan nominal lama dan catat konflik, jangan menulis 0.

---

## BL-05 — Total nota terkoreksi tidak konsisten antara daftar/detail/struk dan laporan

- **Kategori:** Laporan / Nota / Konsistensi
- **Tingkat risiko:** TINGGI
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:2375-2412`; `pusatkupos/lib/data/app_database.dart:2414-2470`; `pusatkupos/lib/data/app_database.dart:2858-2971`; `pusatkupos/lib/data/receipt_service.dart:274-313`; `pusatkupos/lib/data/models.dart:191-229`
- **Bukti source:** `listRecords`/`recordDetail` mengembalikan `service_records.total_servis` asli. `reportSummary` menghitung `totalCents = SUM(total_servis) + adjustmentTotal` dari `nota_adjustments` terbaru; laporan juga menampilkan Jasa + Part − Diskon secara terpisah. Struk mencetak `record.totalCents` (asli). `ServiceRecordSummary.sisaBayarCents` memakai total asli.
- **Alur sebab-akibat:** Koreksi nota menulis baris `nota_adjustments` dan `recalculateRecordTotals`, tetapi tidak mengubah `total_servis`. Layar yang membaca `total_servis` menampilkan angka lama; laporan yang menambahkan adjustment menampilkan angka baru.
- **Skenario masalah:** Nota Rp100.000 dikoreksi menjadi Rp90.000. Riwayat dan struk tetap Rp100.000; laporan periode menampilkan Total Rp90.000, tetapi baris Jasa+Part−Diskon masih menjumlah ke Rp100.000 → selisih Rp10.000 tidak dijelaskan.
- **Dampak bisnis:** Pemilik menerima dua angka berbeda untuk transaksi yang sama; pelanggan dapat memegang struk yang tidak sesuai koreksi; audit penjualan sulit.
- **Dampak integritas data:** Tidak ada satu sumber kebenaran untuk total efektif nota; laporan dan dokumen tidak dapat direkonsiliasi tanpa membaca tabel koreksi.
- **Rekomendasi perbaikan:** Tambahkan kolom/ekspresi `total_efektif` yang dipakai seragam oleh daftar, detail, struk, dashboard, dan laporan; bila koreksi mengubah komponen, simpan juga alokasi koreksi per jasa/part agar Jasa+Part−Diskon = Total.

---

## BL-06 — Karyawan nonaktif masih dapat menulis lewat token relay dan membuka kunci sesi lokal

- **Kategori:** Autentikasi / Izin
- **Tingkat risiko:** TINGGI
- **Status validitas:** CONFIRMED
- **Lokasi:** `relay/lib/server.dart:303-327`; `relay/lib/server.dart:208-226`; `pusatkupos/lib/ui/pin_gate.dart:55-125`
- **Bukti source:** `_employeeCanSend` mengambil `role_base/extra_permissions/permissions_explicit` dari `accounts` tetapi **tidak memeriksa `aktif`**. `_deviceAuth` hanya memeriksa `token_hash` dan `revoked_at`. `PinGate` memverifikasi PIN lalu menyusun ulang operator dari `SessionProfile` yang tersimpan (role + extra) tanpa membaca ulang `employee_accounts.aktif`.
- **Alur sebab-akibat:** Akun dinonaktifkan di database/relay, tetapi perangkat karyawan yang sudah login tetap memiliki token dan PIN lokal. Token tetap diterima relay; PIN tetap membuka sesi dengan izin lama.
- **Skenario masalah:** Karyawan berhenti dan akun dinonaktifkan. Perangkatnya yang masih memegang sesi dapat terus membuat nota/retur/ubah stok dan mengirim amplop sampai perangkatnya dicabut manual.
- **Dampak bisnis:** Mantan karyawan tetap dapat mengubah uang/stok; kontrol akses pemilik tidak berlaku real-time.
- **Dampak integritas data:** Perubahan tidak sah tetap tercatat atas nama akun yang seharusnya nonaktif.
- **Rekomendasi perbaikan:** Tolak amplop bila `accounts.aktif = false` (dan cabut perangkat terkait); pada unlock lokal, baca ulang akun dan tolak bila nonaktif; turunkan izin ke minimum saat status tidak dapat diverifikasi.

---

## BL-07 — Data akun karyawan tidak ikut snapshot/toko baru dan tidak dibuat saat login karyawan

- **Kategori:** Karyawan / Sinkronisasi / Integritas
- **Tingkat risiko:** TINGGI
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/sync/snapshot_sync.dart:12-90`; `pusatkupos/lib/sync/snapshot_platform_io.dart:76-90`; `pusatkupos/lib/data/employee_auth_service.dart:58-270`; `pusatkupos/lib/data/store_service.dart:70-132`; `pusatkupos/lib/data/app_database.dart:1912-1927`
- **Bukti source:** `snapshotTables` tidak memuat `employee_accounts` dan `document_counters`, dan `snapshotLocalTables` menghapusnya dari snapshot. Login karyawan memanggil relay dan menyimpan profil/token, tetapi **tidak** menyisipkan baris `employee_accounts` lokal. `createStore` hanya menyalin owner dan lisensi. Rekalkulasi komisi membaca `employee_accounts`; bila kosong → komisi 0.
- **Alur sebab-akibat:** Perangkat baru hasil bootstrap/restore snapshot tidak memiliki akun karyawan. Fitur yang bergantung pada akun (pemilihan mekanik, komisi, penanggung jawab persetujuan, payroll) kosong atau menghitung nol. Saat retur memicu rekalkulasi, komisi yang ada dapat ditimpa menjadi 0.
- **Skenario masalah:** Pemilik memasang aplikasi di tablet baru dan memakai snapshot. Daftar mekanik kosong; nota baru tidak bisa diberi komisi; setelah retur, komisi nota lama menjadi 0.
- **Dampak bisnis:** Payroll dan komisi tidak lengkap/berubah tanpa peringatan; toko baru tidak mengenali karyawan yang sudah ada.
- **Dampak integritas data:** `employee_accounts` hilang dari salinan; `service_record_commissions` dapat menjadi 0; data dokumen counters kembali dari awal.
- **Rekomendasi perbaikan:** Sertakan `employee_accounts` (tanpa PIN/password) dalam snapshot, atau sediakan sinkronisasi akun terpisah; buat baris akun lokal saat login karyawan; salin akun saat membuat toko; jangan menimpa komisi bila akun tidak ditemukan.

---

## BL-08 — Izin operator tidak dihitung ulang saat berpindah toko

- **Kategori:** Izin / Multi-toko
- **Tingkat risiko:** TINGGI
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/ui/home_shell.dart:142-168`; `pusatkupos/lib/state/app_state.dart:26-41`; `pusatkupos/lib/data/employee_auth_service.dart:58-160`; `pusatkupos/lib/data/store_settings.dart:143-205`
- **Bukti source:** Izin operator dihitung sekali saat login (`settings.accessFor(role, extras)`) dan disimpan di `Operator.permissions`. Ganti toko memanggil `AppState.reloadStore()` → `load()` hanya memuat nama, alamat, PIN, tema, dan auto-lock; `operator` tidak dihitung ulang. Setiap toko memiliki `store_settings.role_permissions_json` sendiri.
- **Alur sebab-akibat:** Operator karyawan dengan akses beberapa toko berpindah dari toko A (izin luas) ke toko B (izin sempit). `AppState.can()` masih memakai izin toko A.
- **Skenario masalah:** Di toko B pemilik mencabut `koreksi` dan `void` untuk peran KASIR, tetapi karyawan yang pindah dari toko A tetap melihat/menjalankan aksi tersebut sampai logout/login.
- **Dampak bisnis:** Pelanggaran pembatasan peran per toko; perubahan kebijakan pemilik tidak berlaku pada sesi berjalan.
- **Dampak integritas data:** Aksi terlarang tercatat di toko B dengan izin toko A.
- **Rekomendasi perbaikan:** Setelah `switchStore`, hitung ulang operator dari `StoreSettings` toko aktif (dan dari `employee_accounts`), lalu perbarui `AppState.operator`; tolak aksi bila store aktif tidak ada di `storeIds`.

---

## BL-09 — Otorisasi retur memakai izin `void`, bukan `retur`

- **Kategori:** Retur / Izin
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/sale_return_service.dart:52-61`; `pusatkupos/lib/ui/screens/history_screen.dart:256`; `pusatkupos/lib/data/access_control.dart:1-179`
- **Bukti source:** `createReturn` memanggil `Permissions.require(actor, permissionVoid)` dan `settings.roleAllows(role, 'void')`. Izin `retur` hanya dipakai untuk menampilkan tombol di UI. Tidak ada pemeriksaan `retur` di service lokal maupun aturan relay.
- **Alur sebab-akibat:** Pemilik dapat mengatur `void=false` dan `retur=true` (atau sebaliknya). UI memakai `retur`, service memakai `void`; kombinasi izin menghasilkan tombol yang tampil tetapi gagal, atau aksi yang dapat dipanggil meski `retur` dimatikan.
- **Skenario masalah:** Pemilik memberi peran `retur=true, void=false`. Karyawan melihat tombol retur tetapi service menolak. Sebaliknya, peran dengan `void=true, retur=false` dapat menjalankan retur lewat pemanggilan service.
- **Dampak bisnis:** Kebijakan retur tidak dapat diterapkan sesuai niat pemilik; alur retur membingungkan operator.
- **Dampak integritas data:** Retur dapat terjadi tanpa izin `retur` yang seharusnya menjadi kontrol.
- **Rekomendasi perbaikan:** Gunakan `permissionRetur` dan `roleAllows(role,'retur')` di service; samakan dengan UI; tambahkan pemeriksaan yang sama di relay untuk entity retur/nota action retur.

---

## BL-10 — Perubahan/deaktivasi akun lokal tidak otomatis dikirim ke relay

- **Kategori:** Akun / Sinkronisasi Relay
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/ui/screens/premium_screen.dart:133-182`; `pusatkupos/lib/ui/screens/premium_screen.dart:468-496`; `pusatkupos/lib/data/account_service.dart:202-243`
- **Bukti source:** `_pushAccountsToServer` hanya mengulang `_accounts.where((a) => a['aktif'] == 1)`; akun nonaktif tidak dikirim dengan `aktif:false`. `_editAccount` hanya memperbarui database lokal. `updateAccount` menaikkan `permission_version` dan menulis audit lokal.
- **Alur sebab-akibat:** Akun dinonaktifkan/diubah di perangkat pemilik, tetapi relay tetap memegang versi lama sampai tombol push manual dijalankan dan akun itu masih aktif.
- **Skenario masalah:** Pemilik menonaktifkan karyawan; relay masih mengizinkan login karyawan tersebut karena baris `accounts.aktif` belum berubah.
- **Dampak bisnis:** Akses karyawan yang sudah dinonaktifkan tetap berjalan; perubahan peran/izin tidak berlaku di login online.
- **Dampak integritas data:** Database lokal dan relay menyimpan status akun yang berbeda.
- **Rekomendasi perbaikan:** Kirim semua akun (termasuk `aktif:false`) saat push; push otomatis setelah perubahan akun; gunakan `permission_version` agar perubahan tidak hilang.

---

## BL-11 — Perubahan role/izin/toko karyawan tidak ikut envelope sinkronisasi

- **Kategori:** Karyawan / Sinkronisasi
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/sync/sync_service.dart:1305-1341`; `pusatkupos/lib/sync/sync_service.dart:3251-3295`
- **Bukti source:** `enqueueEmployee` mengirim `nama`, `aktif`, imbalan, payroll, bank, dan tanggal masuk; tidak mengirim `role_base`, `extra_permissions_json`, `permissions_explicit`, `store_ids_json`, username, PIN/password. Penerima hanya memperbarui nama/aktif/kompensasi.
- **Alur sebab-akibat:** Perubahan role/izin toko yang dilakukan lokal tidak sampai ke perangkat lain melalui envelope; perangkat lain tetap memakai role/izin lama.
- **Skenario masalah:** Pemilik mengubah KASIR menjadi MEKANIK di perangkat A; perangkat B masih menampilkan dan memberi akses KASIR.
- **Dampak bisnis:** Izin tidak konsisten antardevice; karyawan dapat memakai perangkat dengan izin lama.
- **Dampak integritas data:** `employee_accounts` antarperangkat berbeda untuk akun yang sama.
- **Rekomendasi perbaikan:** Kirim field role/izin/toko/username dalam payload (tanpa kredensial), dengan HLC dan validasi bahwa pengirim owner; atau jadikan akun sebagai data khusus relay/owner dan sebarkan salinan read-only.

---

## BL-12 — Estimasi: pembatalan tanpa otorisasi, revisi tanpa cek status/versi unik

- **Kategori:** Estimasi / Izin / Integritas
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/order_service.dart:318-340`; `pusatkupos/lib/data/order_service.dart:900-937`; `pusatkupos/lib/ui/screens/estimates_screen.dart:747-757`; `pusatkupos/lib/data/schema.dart:800`
- **Bukti source:** `cancelEstimate(syncId, actor: ...)` tidak memakai `actor` sama sekali. Revisi (`revisiDariSyncId`) membaca estimasi dasar tanpa memeriksa `status`, lalu menaikkan `versi = base.versi + 1`; index `(nomor_estimasi, versi)` **tidak unik**. UI menampilkan tombol Batal/Revisi untuk semua peran selama status `aktif`.
- **Alur sebab-akibat:** Siapa pun yang dapat membuka layar estimasi dapat membatalkan; dua perangkat dapat merevisi estimasi yang sama dan menghasilkan dua baris versi yang sama.
- **Skenario masalah:** MEKANIK membatalkan estimasi aktif; atau dua kasir offline merevisi estimasi yang sama → dua versi 2.
- **Dampak bisnis:** Estimasi hilang tanpa persetujuan; riwayat versi ambigu; konversi ke nota dapat memakai versi yang salah.
- **Dampak integritas data:** Status estimasi tidak sah; duplikasi versi; referensi `revisi_dari` ganda.
- **Rekomendasi perbaikan:** Wajibkan `buat_estimasi`/izin eksplisit untuk batal dan revisi; periksa status `aktif` sebelum revisi; buat unique index `(nomor_estimasi, versi)` dan tangani konflik; catat audit pembatalan.

---

## BL-13 — Retur dan pelunasan tidak memiliki idempotensi/penjagaan submit ganda

- **Kategori:** Retur / Pembayaran / Retry Safety
- **Tingkat risiko:** SEDANG
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/sale_return_service.dart:36-258`; `pusatkupos/lib/ui/screens/history_screen.dart:256-321`
- **Bukti source:** `createReturn` tidak menerima `requestId` dan tidak memeriksa retur identik; hanya membatasi jumlah baris yang tersisa. Pelunasan memakai `requestId = 'settle-<id>-<microseconds>'` yang selalu baru setiap percobaan. Tombol aksi pada sheet tidak memiliki status busy.
- **Alur sebab-akibat:** Ketukan ganda/retry setelah timeout membuat dua transaksi berbeda; pelunasan kedua dapat lolos bila nominalnya masih ≤ sisa saat itu.
- **Skenario masalah:** Pengguna menekan "Retur" dua kali karena UI tidak merespons; dua retur qty 1 dibuat untuk barang qty 2. Atau pelunasan Rp50.000 dikirim dua kali dari dua dialog.
- **Dampak bisnis:** Refund/stok keluar ganda; piutang lunas lebih cepat dari seharusnya.
- **Dampak integritas data:** Baris retur/payment duplikat; stok dan kas tidak cocok.
- **Rekomendasi perbaikan:** Terima `request_id` stabil dari UI (dibuat saat dialog dibuka, dipakai ulang saat retry) dengan unique constraint; nonaktifkan tombol selama proses; validasi ulang di service dengan kunci idempoten.

---

## BL-14 — Pelunasan piutang lintas perangkat dapat melebihi sisa tagihan

- **Kategori:** Keuangan / Sinkronisasi
- **Tingkat risiko:** SEDANG
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:2767-2856`
- **Bukti source:** `settleReceivable` membaca `sisa_bayar` lokal, menolak bila `nominal > sisa`, lalu menulis `total_dibayar += nominal` dan `sisa = max(0, ...)` langsung. Tidak ada rekalkulasi dari seluruh payment setelah sinkronisasi, dan tidak ada kunci lintas perangkat.
- **Alur sebab-akibat:** Dua perangkat offline masing-masing melihat sisa Rp100.000 dan menerima pelunasan Rp100.000; keduanya menyimpan payment penuh. Penerima kedua menghitung sisa 0, sehingga `total_dibayar` menjadi Rp200.000 untuk tagihan Rp100.000.
- **Skenario masalah:** Pelanggan membayar di kasir A; kasir B (offline) menerima pembayaran yang sama karena tidak tahu.
- **Dampak bisnis:** Kas diterima tercatat dua kali; piutang pelanggan tidak akurat; rekonsiliasi kas sulit.
- **Dampak integritas data:** `total_dibayar > total efektif`; `sisa_bayar` 0 menutupi kelebihan.
- **Rekomendasi perbaikan:** Setelah apply, panggil `recalculateRecordTotals` dari seluruh payment; tandai kelebihan sebagai konflik; gunakan idempotency key pembayaran; batasi pelunasan pada perangkat yang memegang nota atau lakukan reservasi sisa di relay.

---

## BL-15 — Amplop void tidak self-contained; total dibayar penerima bergantung pada amplop pembayaran terpisah

- **Kategori:** Pembatalan / Sinkronisasi / Laporan Kas
- **Tingkat risiko:** SEDANG
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/note_sync.dart:309-398`; `pusatkupos/lib/data/app_database.dart:2669-2712`; `pusatkupos/lib/sync/sync_service.dart:1067-1098`; `pusatkupos/lib/sync/sync_service.dart:1380-1412`
- **Bukti source:** `voidRecord` lokal menyisipkan payment negatif bertipe REFUND dengan kunci `void-<sync>` dan meng-enqueue amplop pembayaran terpisah (`enqueuePayment`). Payload void sendiri juga memuat `payments`, tetapi cabang apply void di `note_sync` **mengabaikan** `payments`; ia hanya mengubah status, stok, `sisa_bayar=0`, dan tidak memanggil `_recalculateRecordTotals`.
- **Alur sebab-akibat:** Perangkat asal mengirim dua amplop: void dan payment. Penerima yang menerapkan void saja akan memiliki status VOID dan `sisa=0`, tetapi `total_dibayar` serta `service_payments` masih memuat pembayaran lama sampai amplop payment diterapkan. Bila amplop payment tertunda lama atau gagal permanen (mis. penerima menolak amplop), divergensi kas bertahan tanpa peringatan.
- **Skenario masalah:** Void nota tunai Rp100.000. Amplop void diterima, amplop payment tertunda; di tablet laporan kas masih menunjukkan Rp100.000 diterima dan `total_dibayar` Rp100.000, sedangkan di ponsel pemilik sudah 0.
- **Dampak bisnis:** Laporan kas dan pendapatan dapat berbeda antardevice pada jendela waktu tertentu; bila amplop payment hilang, perbedaan menjadi permanen.
- **Dampak integritas data:** `service_payments` dan `total_dibayar` tidak konsisten dengan status VOID pada penerima; `sisa_bayar=0` menutupi kelebihan pembayaran.
- **Rekomendasi perbaikan:** Jadikan void self-contained: terapkan REFUND (atau rekalkulasi dari seluruh payment) di cabang void secara idempoten, dan/atau panggil `recalculateRecordTotals` setelah void; tetap kirim amplop payment sebagai jalur cadangan.

---

## BL-16 — Penggabungan pelanggan tidak memindahkan nota tanpa unit dan referensi lain

- **Kategori:** Pelanggan / Integritas Referensi
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:653-727`
- **Bukti source:** `mergeCustomers` memindahkan `vehicle_or_units.customer_id`, lalu menghapus (soft delete) pelanggan asal. `service_records` hanya dikumpulkan berdasarkan `unit_id IN (...)` untuk enqueue; `service_records.customer_id` tidak diubah. Nota tanpa unit (mis. jual sparepart) tidak masuk daftar. Tabel follow-up/WA yang menyimpan `customer_id` tidak diperbarui.
- **Alur sebab-akibat:** Nota tanpa unit tetap menunjuk pelanggan asal yang sudah dihapus. Pencarian/pelaporan per pelanggan tujuan tidak menemukan nota itu; data follow-up dapat menunjuk pelanggan yang sudah tidak ada.
- **Skenario masalah:** Pelanggan A dan B digabung. Nota jual sparepart tanpa kendaraan milik A tidak muncul di riwayat B dan tidak ikut pencarian nama.
- **Dampak bisnis:** Riwayat pelanggan tidak lengkap; follow-up/WA salah sasaran; piutang dapat terlewat.
- **Dampak integritas data:** Referensi `service_records.customer_id` dan tabel follow-up menunjuk baris yang sudah soft-deleted; tidak ada foreign key yang memperbaikinya.
- **Rekomendasi perbaikan:** Perbarui `service_records.customer_id` untuk semua nota asal (termasuk unit_id NULL), pindahkan referensi follow-up/WA, lalu hapus pelanggan asal; enqueue semua nota yang berubah.

---

## BL-17 — Daftar/detail riwayat mengabaikan `service_records.customer_id`

- **Kategori:** Nota / Tampilan Data
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:2400-2407`; `pusatkupos/lib/data/app_database.dart:2417-2424`
- **Bukti source:** Kedua query memakai `LEFT JOIN customers c ON c.id = u.customer_id`. Padahal nota menyimpan `customer_id` sendiri dan dapat memiliki `unit_id` NULL (jual sparepart). `receipt_service` dan `note_sync` sudah memakai `COALESCE(r.customer_id, u.customer_id)`.
- **Alur sebab-akibat:** Nota tanpa unit → `u.customer_id` NULL → `customer_nama` NULL. Pencarian berdasarkan nama pelanggan pada daftar riwayat juga tidak menemukan nota tersebut.
- **Skenario masalah:** Nota jual sparepart tanpa kendaraan tampil tanpa nama pelanggan di riwayat, meskipun pelanggan dipilih saat transaksi.
- **Dampak bisnis:** Identitas pelanggan hilang di layar operasional; pencarian dan penagihan piutang menjadi sulit.
- **Dampak integritas data:** Data tersimpan benar, tetapi dibaca salah; laporan per pelanggan tidak konsisten dengan detail.
- **Rekomendasi perbaikan:** Gunakan `LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)` pada kedua query.

---

## BL-18 — Struk mencetak total asli dan kembalian hanya dari pembayaran awal

- **Kategori:** Nota / Struk / Keuangan
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/receipt_service.dart:274-313`
- **Bukti source:** Blok total mencetak `record.biayaJasaCents`, `totalPartCents`, `diskonCents`, dan `record.totalCents` (total_servis asli). Kembalian dihitung hanya bila `bayarCents > totalCents` dan metode CASH. Koreksi (`nota_adjustments`) dan retur tidak mengurangi total yang dicetak; pelunasan berikutnya tidak memengaruhi kembalian.
- **Alur sebab-akibat:** Nota dikoreksi/diretur setelah pembayaran, tetapi cetak ulang struk tetap menampilkan nilai lama dan kembalian lama.
- **Skenario masalah:** Nota Rp500.000 dikoreksi menjadi Rp450.000; struk cetak ulang tetap Rp500.000, pelanggan meminta selisih yang tidak tercermin.
- **Dampak bisnis:** Bukti transaksi tidak sesuai nilai efektif; sengketa pelanggan; laporan dan struk tidak cocok.
- **Dampak integritas data:** Dokumen cetak tidak merepresentasikan state database saat ini.
- **Rekomendasi perbaikan:** Cetak total efektif (termasuk adjustment) dan retur; cetak rincian koreksi/retur; hitung kembalian dari kas yang benar-benar diterima pada transaksi awal, bukan dari total terkini.

---

## BL-19 — "Pendapatan hari ini" adalah omzet bruto, bukan neto retur/kas

- **Kategori:** Dashboard / Laporan
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:3125-3156`; `pusatkupos/lib/ui/screens/dashboard_screen.dart:93-100`
- **Bukti source:** `dashboard()` memakai `summary.totalCents` dari `reportSummary` (total setelah koreksi, **sebelum retur**). Retur dihitung terpisah di `returCents`. Dashboard memberi label "Pendapatan hari ini".
- **Alur sebab-akibat:** Nota dan retur pada hari yang sama → dashboard menampilkan nilai sebelum retur. Jika retur terjadi hari berikutnya, pendapatan hari itu tidak pernah dikoreksi.
- **Skenario masalah:** Omzet Rp10.000.000, retur Rp2.000.000 hari yang sama; dashboard tetap Rp10.000.000.
- **Dampak bisnis:** Pemilik melebih-lebihkan pendapatan; keputusan stok/kas salah.
- **Dampak integritas data:** Tidak ada kesalahan penyimpanan, tetapi definisi metrik tidak konsisten dengan laporan neto.
- **Rekomendasi perbaikan:** Ganti label menjadi "Omzet bruto" atau tampilkan juga "Neto setelah retur" dan "Kas diterima"; gunakan definisi yang sama dengan laporan.

---

## BL-20 — Restore multi-toko tidak membatasi total ukuran hasil dekompresi

- **Kategori:** Backup / Restore
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/backup_service.dart:949-977`; bandingkan `pusatkupos/lib/data/backup_service.dart:312-318`
- **Bukti source:** Saat membuat arsip, setiap database dibatasi 512 MB dan **total** semua toko dibatasi 512 MB. Saat restore multi-toko, hanya `payloadFile.size` dan panjang payload per toko yang dibatasi 512 MB; tidak ada akumulasi total.
- **Alur sebab-akibat:** Arsip berisi banyak toko (masing-masing <512 MB) dapat mengisi disk saat restore; restore dapat gagal di tengah setelah beberapa toko diganti.
- **Skenario masalah:** Lima toko @400 MB (arsip dibuat versi lama/aplikasi lain) → restore menulis ~2 GB.
- **Dampak bisnis:** Restore gagal/disk penuh; operasional toko berhenti; risiko kehilangan data bila pemulihan darurat gagal.
- **Dampak integritas data:** Sebagian toko sudah diganti, sebagian belum; meskipun ada rollback, kegagalan disk dapat membuat rollback juga gagal.
- **Rekomendasi perbaikan:** Terapkan batas agregat yang sama saat restore; periksa ruang disk sebelum menulis; gunakan direktori staging dan verifikasi total sebelum mengganti database aktif.

---

## BL-21 — Penjualan bersamaan lintas perangkat dapat menjual stok yang sama

- **Kategori:** Inventori / Penjualan / Sinkronisasi
- **Tingkat risiko:** SEDANG
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:1350-1400`; `pusatkupos/lib/sync/sync_service.dart:2947-2981`
- **Bukti source:** Validasi kecukupan stok hanya menjumlahkan qty yang diminta terhadap `stock_items` lokal. Penerima movement hanya mencatat konflik `stok_negatif` dan tetap menerapkan `next = before + qty` (negatif).
- **Alur sebab-akibat:** Dua perangkat offline sama-sama melihat stok 1 dan masing-masing menjual 1; saat sinkron, stok menjadi −1 tanpa penolakan transaksi.
- **Skenario masalah:** Dua kasir menjual barang terakhir pada waktu bersamaan.
- **Dampak bisnis:** Barang tidak tersedia saat diambil; stok negatif; pelanggan kecewa.
- **Dampak integritas data:** `stock_items` negatif dan konflik hanya untuk ditinjau, bukan dicegah.
- **Rekomendasi perbaikan:** Gunakan reservasi stok di relay atau aturan konflik yang membatalkan penjualan kedua; minimal blokir finalisasi nota yang membuat stok negatif dan minta konfirmasi owner.

---

## BL-22 — Passphrase backup otomatis ditampilkan dalam teks jelas

- **Kategori:** Backup / Keamanan
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/ui/screens/settings_screen.dart:56-67, 97-123`; `pusatkupos/lib/data/backup_service.dart:182-204`
- **Bukti source:** `_loadBackup` mengisi `_backupPassphrase.text` dengan `autoPassphrase()`; `_saveBackup` menyimpan nilai itu. Passphrase yang sama melindungi arsip backup (AES-256-GCM). Komentar kode menyebut tampilan ini disengaja, tetapi nilainya ditampilkan di layar tanpa autentikasi ulang.
- **Alur sebab-akibat:** Siapa pun yang memegang perangkat dalam keadaan terbuka (atau melihat layar) dapat membaca passphrase dan membuka arsip backup yang disalin ke luar perangkat.
- **Skenario masalah:** Teknisi/keluarga melihat layar Pengaturan → Backup, mencatat passphrase, lalu membuka file backup.
- **Dampak bisnis:** Seluruh database (transaksi, pelanggan, harga, kredensial hash) dapat dibaca; kebocoran data usaha.
- **Dampak integritas data:** Tidak mengubah data, tetapi melemahkan kerahasiaan backup.
- **Rekomendasi perbaikan:** Jangan tampilkan passphrase; gunakan tombol "salin ke clipboard" dengan konfirmasi PIN/owner, atau tampilkan sekali saat pembuatan dengan peringatan; pertimbangkan kunci yang diturunkan dari kredensial perangkat.

---

## BL-23 — Rekonsiliasi hanya membandingkan ID nota, bukan nilai/retur/pembayaran

- **Kategori:** Sinkronisasi / Laporan
- **Tingkat risiko:** SEDANG
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/reconciliation_service.dart:17-46`
- **Bukti source:** `digestFor` hanya memilih `sync_id` dari `service_records` untuk jenis `nota`, menghitung jumlah dan hash; tidak memasukkan total, status, retur, koreksi, atau pembayaran.
- **Alur sebab-akibat:** Dua perangkat dapat memiliki daftar nota yang sama tetapi nilai/retur/pembayaran berbeda (mis. BL-15) dan rekonsiliasi tetap menyatakan cocok.
- **Skenario masalah:** Void diterapkan berbeda (BL-15) tetapi digest harian sama → pemilik tidak diberi peringatan.
- **Dampak bisnis:** Rasa aman palsu; divergensi keuangan tidak terdeteksi.
- **Dampak integritas data:** Tidak ada deteksi dini terhadap perbedaan nilai.
- **Rekomendasi perbaikan:** Sertakan hash nilai efektif, total retur, jumlah pembayaran, dan status void; atau buat digest terpisah untuk keuangan.

---

## BL-24 — Kebijakan stok negatif tidak konsisten

- **Kategori:** Inventori / Aturan Bisnis
- **Tingkat risiko:** SEDANG
- **Status validitas:** NEEDS VALIDATION
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:978-1003`; `pusatkupos/lib/ui/screens/stock_screen.dart:797-810`; `pusatkupos/lib/data/access_control.dart:1-179`
- **Bukti source:** `stockOut` hanya memeriksa qty > 0, tidak memeriksa stok tersisa. Dialog stok keluar juga tidak memblokir qty > stok. `saveStockItem` menolak stok negatif, dashboard menghitung stok negatif sebagai masalah, tetapi `stockOut` dan penerima movement mengizinkannya.
- **Alur sebab-akibat:** Barang dapat dikeluarkan melebihi stok tanpa konfirmasi; stok negatif kemudian dianggap "konflik" di dashboard.
- **Skenario masalah:** Stok 2, keluar 5 → stok −3; dashboard menandai konflik, tetapi transaksi sudah tersimpan.
- **Dampak bisnis:** Perlu validasi apakah stok negatif memang diizinkan (mis. barang datang belum dicatat). Bila tidak, ini melemahkan kontrol inventori.
- **Dampak integritas data:** Stok negatif dan konflik bercampur; sulit membedakan kesalahan input dan kondisi nyata.
- **Rekomendasi perbaikan:** Tetapkan aturan: blokir stok keluar > stok, atau izinkan dengan persetujuan owner dan alasan wajib; samakan perilaku UI/service/penerima.

---

## BL-25 — Penanda jatuh tempo memakai total asli dan mengabaikan retur/koreksi

- **Kategori:** Piutang / Tampilan
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/models.dart:218-229`; `pusatkupos/lib/ui/screens/history_screen.dart:172, 804`
- **Bukti source:** `sisaBayarCents = totalCents - paid`; `totalCents` adalah `total_servis` asli, tidak memasukkan adjustment/retur. `jatuhTempoLewat` memakai nilai itu.
- **Alur sebab-akibat:** Retur/koreksi menurunkan sisa di database, tetapi badge memakai perhitungan lama.
- **Skenario masalah:** Nota Rp100.000, dibayar Rp100.000, lalu retur Rp20.000 dan kas dikembalikan. `sisaBayar` menjadi 0 → badge "lewat" tidak muncul (kondisi ini justru benar); kasus lain: dibayar Rp80.000, retur Rp80.000 (sisa 0) → badge tetap menghitung 20.000 terlambat.
- **Dampak bisnis:** Daftar piutang menandai pelanggan yang sebenarnya lunas, atau sebaliknya.
- **Dampak integritas data:** Data benar; tampilan salah.
- **Rekomendasi perbaikan:** Gunakan `sisa_bayar` tersimpan atau rumus yang sama dengan `recalculateRecordTotals`.

---

## BL-26 — Filter stok dan pemeriksaan kode mengabaikan status hapus

- **Kategori:** Inventori / Integritas
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:780-792`; `pusatkupos/lib/data/app_database.dart:839-851`; `pusatkupos/lib/data/app_database.dart:877-897`; `pusatkupos/lib/data/app_database.dart:1350-1400`; `pusatkupos/lib/data/app_database.dart:3128-3140`
- **Bukti source:** `listStock` tidak memakai `deleted_at IS NULL`; pengecekan kode duplikat memakai semua baris termasuk yang soft-deleted dan tidak membedakan baris itu dari baris aktif; validasi stok penjualan tidak memeriksa `stock_items.deleted_at`; query stok menipis/negatif dashboard juga tidak memfilter `deleted_at`. Tidak ada jalur hapus barang di UI lokal, sehingga kondisi ini terutama muncul dari payload sinkronisasi atau versi lain.
- **Alur sebab-akibat:** Barang yang dihapus dapat muncul kembali, memblokir kode yang seharusnya bebas, atau tetap dihitung di dashboard. Meskipun saat ini belum ada UI hapus barang, payload sinkronisasi memiliki `deleted_at`, sehingga kondisi ini laten.
- **Skenario masalah:** Barang dihapus di perangkat lain lalu payload diterapkan; daftar stok masih menampilkannya; pembuatan barang baru dengan kode sama ditolak.
- **Dampak bisnis:** Data master kotor; laporan stok tidak akurat.
- **Dampak integritas data:** Baris terhapus tetap diperlakukan aktif.
- **Rekomendasi perbaikan:** Tambahkan filter `deleted_at IS NULL` pada semua query stok; jangan mengembalikan `deleted_at` ke NULL saat edit; sediakan alur hapus/pulihkan yang jelas.

---

## BL-27 — `actor == null` diperlakukan sebagai pemilik

- **Kategori:** Izin / Audit
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:1274`; `pusatkupos/lib/data/app_database.dart:1404`; `pusatkupos/lib/data/app_database.dart:812`; `pusatkupos/lib/data/order_service.dart:212, 286`; `pusatkupos/lib/data/order_service.dart:728`
- **Bukti source:** Beberapa service memakai `actor?.isOwner ?? true` dan `role = actor?.role ?? 'owner'`, serta melewati `Permissions.require` bila `actor == null`. Audit mencatat `actor?.label ?? 'Pemilik'`.
- **Alur sebab-akibat:** Pemanggil yang lupa mengirim operator dianggap pemilik penuh, termasuk boleh di bawah modal.
- **Skenario masalah:** Jalur internal baru/refactor memanggil `createTransaction` tanpa actor → diskon di bawah modal lolos tanpa persetujuan, audit atas nama Pemilik.
- **Dampak bisnis:** Potensi penyalahgunaan harga dan audit trail menyesatkan.
- **Dampak integritas data:** Tidak ada jejak operator sebenarnya.
- **Rekomendasi perbaikan:** Wajibkan actor untuk operasi tulis; bila null, tolak atau gunakan operator "sistem" tanpa hak istimewa.

---

## BL-28 — Principal viewer dianggap owner dan database viewer dapat ditulis

- **Kategori:** Autentikasi / Mode Viewer
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/session_service.dart:48`; `pusatkupos/lib/data/session_service.dart:121-131`; `pusatkupos/lib/ui/pin_gate.dart:85-95`; `pusatkupos/lib/data/app_database.dart:93-108`
- **Bukti source:** `isOwner => mode != 'employee'`, sehingga mode `viewer` menghasilkan operator `kind: 'owner'` dengan `can()` selalu true. Database viewer adalah salinan lokal yang dapat ditulis; pembatasan hanya dari shell UI.
- **Alur sebab-akibat:** Bila ada jalur UI/URL yang membuka layar tulis di mode viewer, tidak ada lapisan service yang menolak.
- **Skenario masalah:** Perangkat ringkasan membuka layar yang tidak dimaksudkan dan menulis ke salinan lokal, membuat ringkasan tidak lagi mencerminkan toko.
- **Dampak bisnis:** Data ringkasan bisa menyimpang; kontrol "hanya baca" bergantung pada UI.
- **Dampak integritas data:** Salinan viewer dapat berubah tanpa sinkronisasi balik.
- **Rekomendasi perbaikan:** Tambahkan `kind: 'viewer'` dan `can()` yang menolak semua izin tulis; buka database viewer read-only bila platform mendukung; validasi di service.

---

## BL-29 — Masa berlaku lisensi memakai jam perangkat

- **Kategori:** Lisensi
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/license_verifier.dart:39-41`
- **Bukti source:** Status aktif dihitung dengan `periodEnd.isAfter(DateTime.now().toUtc())`; tidak ada waktu server yang ditandatangani/di-cache sebagai acuan.
- **Alur sebab-akibat:** Jam perangkat mundur → lisensi kedaluwarsa tampak aktif; jam maju → lisensi aktif tampak kedaluwarsa.
- **Skenario masalah:** Pengguna mengubah tanggal perangkat untuk memperpanjang akses premium.
- **Dampak bisnis:** Potensi kehilangan pendapatan lisensi; pengguna sah dapat terkunci.
- **Dampak integritas data:** Tidak mengubah data transaksi.
- **Rekomendasi perbaikan:** Gunakan `server_time` dari relay yang ditandatangani, simpan waktu terakhir terlihat, dan tolak mundur waktu yang tidak wajar.

---

## BL-30 — Penyesuaian nota dari relay dibuang diam-diam bila nota belum ada/void

- **Kategori:** Sinkronisasi / Koreksi
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/nota_adjustment_service.dart:286-329`
- **Bukti source:** `applyRemote` mengembalikan `void` tanpa error bila nota tidak ditemukan atau `voided_at != null`; envelope dianggap berhasil dan kursor maju.
- **Alur sebab-akibat:** Koreksi yang tiba sebelum nota (urutan envelope) atau setelah void hilang permanen di perangkat itu.
- **Skenario masalah:** Envelope koreksi diterapkan lebih dulu karena nota belum tersedia → koreksi tidak pernah dicoba lagi.
- **Dampak bisnis:** Nilai nota berbeda antardevice tanpa peringatan.
- **Dampak integritas data:** `nota_adjustments` hilang di salah satu perangkat.
- **Rekomendasi perbaikan:** Lempar `RetryableSyncException` bila nota belum ada; catat konflik bila nota void; jangan menandai envelope selesai untuk kasus yang belum final.

---

## BL-31 — Follow-up: tanpa aktor/izin, kuota dikonsumsi sebelum commit, tanggal dapat terhapus

- **Kategori:** Follow-up / Izin / Retry
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/followup_service.dart:646-675`; `pusatkupos/lib/data/followup_service.dart:690-842`; `pusatkupos/lib/data/followup_service.dart:844-973`
- **Bukti source:** `followUp` dan `changeStatus` tidak menerima `Operator` dan tidak memanggil `Permissions.require`. Kuota remote dikonsumsi sebelum transaksi database lokal; bila transaksi gagal, kredit tetap terpakai. `changeStatus` menghapus `tanggal_service`/`janji_bayar`/`tunda_sampai` pada status yang tidak cocok.
- **Alur sebab-akibat:** Peran tanpa izin follow-up dapat mengubah status lewat pemanggilan langsung; kegagalan lokal menghabiskan kuota; data tanggal hilang saat status berubah.
- **Skenario masalah:** Gagal menyimpan karena database sibuk setelah kuota terpakai → kuota berkurang tanpa pesan terkirim.
- **Dampak bisnis:** Kuota WA premium terbuang; jadwal servis pelanggan hilang; kontrol izin tidak konsisten.
- **Dampak integritas data:** `followup_items` kehilangan tanggal; kuota tidak cocok dengan riwayat.
- **Rekomendasi perbaikan:** Teruskan operator dan periksa izin; konsumsi kuota setelah commit atau kompensasi bila gagal; pertahankan tanggal lama kecuali status baru memang membutuhkannya, dengan konfirmasi.

---

## BL-32 — Backup toko nonaktif dibaca tanpa checkpoint

- **Kategori:** Backup
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/backup_service.dart:381-399`; `pusatkupos/lib/data/app_database.dart:311-334`
- **Bukti source:** Untuk toko nonaktif pada perangkat non-SQLCipher, `platform.readFile(store.databasePath)` dibaca langsung tanpa `PRAGMA wal_checkpoint`. Jalur SQLCipher melakukan checkpoint; jalur aktif memanggil `exportPortableCopy` yang melakukan checkpoint.
- **Alur sebab-akibat:** Bila toko ditutup tidak bersih (crash) dan masih menyisakan WAL, berkas utama tidak memuat transaksi terakhir.
- **Skenario masalah:** Aplikasi crash saat memakai toko B, lalu backup dibuat dari toko A; arsip toko B kehilangan transaksi terakhir.
- **Dampak bisnis:** Backup tampak berhasil tetapi tidak lengkap.
- **Dampak integritas data:** Kehilangan data pada restore meskipun backup "sukses".
- **Rekomendasi perbaikan:** Buka toko nonaktif sementara dengan mode baca dan checkpoint, atau gunakan `VACUUM INTO`/`sqlcipher_export` untuk semua toko; verifikasi checksum dan jumlah baris kunci.

---

## BL-33 — Kode perangkat 3 karakter dan penghitung dokumen lokal berpotensi bentrok

- **Kategori:** Penomoran / Multi-perangkat
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:2042-2076`; `pusatkupos/lib/data/app_database.dart:2115-2153`; `pusatkupos/lib/sync/snapshot_sync.dart:12-90`
- **Bukti source:** `deviceCode` memakai 3 karakter terakhir ID perangkat atau 3 karakter acak. Nomor dokumen = cabang + kode perangkat + tanggal + urutan; penghitung disimpan di `document_counters` yang tidak ikut snapshot.
- **Alur sebab-akibat:** Dua perangkat dengan kode sama membuat urutan yang sama pada hari yang sama; perangkat hasil bootstrap memulai penghitung dari nol.
- **Skenario masalah:** Dua perangkat menghasilkan nomor nota identik; penerima melakukan renumber dan mencatat konflik, sehingga nomor nota berbeda antardevice.
- **Dampak bisnis:** Nomor nota tidak unik secara operasional; komunikasi dengan pelanggan membingungkan.
- **Dampak integritas data:** Konflik `no_nota_bentrok`; nomor dokumen tidak stabil.
- **Rekomendasi perbaikan:** Gunakan kode perangkat yang lebih panjang/acak dan unik; sertakan penghitung dokumen dalam snapshot; gunakan nomor berbasis UUID/ULID untuk referensi internal.

---

## BL-34 — Void tidak menyesuaikan komisi dan pembayaran tersimpan

- **Kategori:** Pembatalan / Payroll
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/app_database.dart:2593-2765`
- **Bukti source:** `voidRecord` mengubah status, sisa, dan stok; tidak menghapus/menolkan `service_record_commissions`, tidak memperbarui `total_dibayar` (hanya `sisa=0`), dan refund hanya dibuat dari payment positif non-REFUND.
- **Alur sebab-akibat:** Komisi tetap ada untuk nota VOID; payroll memfilter VOID sehingga tidak dibayar, tetapi laporan komisi/detail nota masih menampilkan komisi. Nota VOID menampilkan pembayaran lama tanpa penjelasan refund.
- **Skenario masalah:** Nota VOID dengan komisi Rp50.000 tetap terlihat di detail; laporan komisi per nota dapat membingungkan.
- **Dampak bisnis:** Laporan komisi tidak bersih; audit void sulit.
- **Dampak integritas data:** Baris komisi yatim; `total_dibayar` tidak mencerminkan refund.
- **Rekomendasi perbaikan:** Nolkan atau tandai komisi VOID dengan alasan; simpan refund eksplisit dan hitung ulang total_dibayar; tampilkan status VOID secara konsisten di semua laporan.

---

## BL-35 — Relay menerima token perangkat tanpa memeriksa status lisensi

- **Kategori:** Lisensi / Relay
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `relay/lib/server.dart:208-226`; `relay/lib/server.dart:2338-2375`
- **Bukti source:** `_deviceAuth` hanya memeriksa hash token dan `revoked_at`; tidak memeriksa `owners.license_period_end` atau plan. Lisensi diperiksa saat login Google/enroll, bukan pada setiap sinkronisasi.
- **Alur sebab-akibat:** Lisensi kedaluwarsa tetapi perangkat yang sudah terdaftar tetap dapat mengirim/menarik data premium.
- **Skenario masalah:** Langganan berakhir; sinkronisasi tetap berjalan.
- **Dampak bisnis:** Fitur premium tetap dipakai tanpa lisensi; potensi kehilangan pendapatan.
- **Dampak integritas data:** Tidak merusak data.
- **Rekomendasi perbaikan:** Periksa masa lisensi owner pada `_deviceAuth` (dengan toleransi offline), atau kembalikan status lisensi dan batasi endpoint premium.

---

## BL-36 — Pembuatan order kerja memakai izin `buat_nota` dan mengabaikan jenis order

- **Kategori:** Order / Izin
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/order_service.dart:610-617`; bandingkan `pusatkupos/lib/data/store_settings.dart:192-205`
- **Bukti source:** `createWorkOrder` memeriksa `settings.typeEnabled(order_kerja)` dan `roleAllows(role, 'buat_nota')`; tidak memakai `roleCanSelect(role, order_kerja)` maupun izin `buat_order`.
- **Alur sebab-akibat:** Peran dengan `buat_nota` tetapi tanpa izin jenis order tetap dapat membuat order lewat service; peran dengan `buat_order` tetapi tanpa `buat_nota` ditolak.
- **Skenario masalah:** Pemilik mematikan `jenis_order_kerja` untuk peran tertentu, tetapi service masih mengizinkan pembuatan.
- **Dampak bisnis:** Kebijakan jenis transaksi per peran tidak berlaku penuh.
- **Dampak integritas data:** Order tercatat dari peran yang seharusnya tidak berhak.
- **Rekomendasi perbaikan:** Gunakan `roleCanSelect(role, transactionOrderKerja)` dan/atau `buat_order`.

---

## BL-37 — `createEstimate` memperlakukan actor null sebagai pemilik

- **Kategori:** Estimasi / Izin
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/order_service.dart:286-314`
- **Bukti source:** `isOwner = actor?.isOwner ?? true`; diskon di bawah batas diizinkan bila `isOwner`, dan persetujuan hanya diminta untuk non-owner.
- **Alur sebab-akibat:** Pemanggilan tanpa actor menghasilkan estimasi dengan harga di bawah modal tanpa persetujuan.
- **Skenario masalah:** Refactor/otomasi memanggil `createEstimate` tanpa operator; diskon lolos.
- **Dampak bisnis:** Estimasi terlalu murah; margin hilang.
- **Dampak integritas data:** Tidak ada persetujuan/audit.
- **Rekomendasi perbaikan:** Wajibkan actor dan tolak null; samakan dengan `createTransaction`.

---

## BL-38 — Hapus supplier menghapus relasi tanpa tombstone

- **Kategori:** Supplier / Sinkronisasi
- **Tingkat risiko:** RENDAH
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/supplier_service.dart:123-153`
- **Bukti source:** `deleteSupplier` melakukan `DELETE` fisik pada `supplier_items` dan `supplier_followups` lokal, lalu soft-delete supplier dan enqueue supplier. Relasi yang dihapus tidak memiliki sync_id/tombstone sendiri.
- **Alur sebab-akibat:** Penerima menerima supplier `deleted_at` dan menyembunyikan supplier, tetapi baris relasi lokal tetap ada; bila supplier dipulihkan, relasi lama dapat muncul kembali atau berbeda antardevice.
- **Skenario masalah:** Supplier dihapus lalu dipulihkan; daftar barang supplier tidak sama dengan perangkat lain.
- **Dampak bisnis:** Follow-up supplier dan pemetaan barang tidak konsisten.
- **Dampak integritas data:** Relasi yatim/lokal-only.
- **Rekomendasi perbaikan:** Soft-delete relasi dengan tombstone yang disinkronkan, atau kirim daftar relasi terbaru dalam payload supplier (sudah ada `stock_sync_ids`) dan terapkan penggantian penuh.

---

## BL-39 — Kembalian struk hanya mencerminkan pembayaran awal

- **Kategori:** Struk / Keuangan
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/receipt_service.dart:301-308`
- **Bukti source:** Kembalian dihitung hanya jika `record.bayarCents > record.totalCents && metode == CASH`. `bayarCents` adalah pembayaran awal; pelunasan berikutnya dan refund tidak mengubahnya.
- **Alur sebab-akibat:** Nota kredit dilunasi tunai → struk cetak ulang tidak menampilkan kembalian pelunasan; refund tunai tidak ditampilkan.
- **Skenario masalah:** Sisa Rp50.000 dibayar dengan Rp100.000 → struk hanya menampilkan riwayat pembayaran, bukan kembalian Rp50.000.
- **Dampak bisnis:** Bukti kas kurang jelas; potensi salah kembalian.
- **Dampak integritas data:** Tidak ada perubahan data.
- **Rekomendasi perbaikan:** Tampilkan kembalian per pembayaran tunai (termasuk pelunasan/refund), atau hentikan pencetakan kembalian pada cetak ulang.

---

## BL-40 — Penerima retur tidak merekalkulasi komisi

- **Kategori:** Retur / Komisi / Sinkronisasi
- **Tingkat risiko:** RENDAH
- **Status validitas:** CONFIRMED
- **Lokasi:** `pusatkupos/lib/data/note_sync.dart:922-1039`; bandingkan `pusatkupos/lib/data/sale_return_service.dart:235-240`
- **Bukti source:** Perangkat asal memanggil `recalculateRecordCommissions` dan meng-enqueue komisi yang berubah; penerima `_upsertReturn` hanya menambah stok dan item retur, tidak merekalkulasi komisi.
- **Alur sebab-akibat:** Bila envelope komisi tidak diterima/terlewat, komisi penerima tetap penuh padahal retur mengurangi jasa/margin.
- **Skenario masalah:** Retur jasa 50% diterapkan di perangkat B, tetapi komisi mekanik di B tetap 100%.
- **Dampak bisnis:** Laporan komisi antardevice berbeda.
- **Dampak integritas data:** `service_record_commissions` tidak konsisten.
- **Rekomendasi perbaikan:** Panggil rekalkulasi komisi di penerima setelah retur diterapkan, dengan snapshot tarif (lihat BL-04), atau jadikan baris komisi hasil perhitungan perangkat asal sebagai satu-satunya sumber dan terapkan secara idempoten.

---

## BL-41 — Kode barang duplikat lintas perangkat memblokir sinkronisasi

- **Kategori:** Inventori / Sinkronisasi / Retry Safety
- **Tingkat risiko:** SEDANG
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/schema.dart:293-298`; `pusatkupos/lib/data/app_database.dart:839-851`; `pusatkupos/lib/sync/sync_service.dart:2890-2902`; `pusatkupos/lib/sync/sync_service.dart:1990-2015`
- **Bukti source:** `stock_items.kode` memiliki `UNIQUE` di skema. `saveStockItem` hanya memeriksa duplikat **di database lokal**. Penerima `entity == 'stock'` menyisipkan barang baru berdasarkan `sync_id` tanpa memeriksa apakah `kode` sudah dipakai barang lain dan tanpa renumber/konflik. Kegagalan apply ditangkap sebagai konflik, `cursor` tidak dimajukan melewati amplop itu, dan seluruh amplop berikutnya tertahan sampai pengguna menindaklanjuti.
- **Alur sebab-akibat:** Dua perangkat membuat barang dengan kode sama secara offline (masing-masing lolos validasi lokal) → perangkat pertama menang → perangkat kedua menerima insert yang melanggar `UNIQUE(kode)` → amplop gagal berulang → sinkronisasi berhenti di urutan tersebut.
- **Skenario masalah:** Pemilik menambah "OLI-001" di ponsel dan di tablet. Tablet sinkron lebih dulu; amplop barang dari ponsel gagal dan menahan semua amplop setelahnya.
- **Dampak bisnis:** Sinkronisasi berhenti; data perangkat lain tidak masuk; pengguna harus menyelesaikan konflik manual. Barang yang sama dapat tercatat ganda bila kode diubah untuk melewati konflik.
- **Dampak integritas data:** Dua entitas dengan `sync_id` berbeda untuk barang yang sama; tidak ada penggabungan otomatis; amplop lain tertahan.
- **Rekomendasi perbaikan:** Tangkap pelanggaran `UNIQUE(kode)` pada apply, catat konflik `kode_bentrok` dengan opsi gabung/renumber, dan jangan menahan amplop yang tidak terkait; atau jadikan kode barang unik pada tingkat owner/relay agar dibuat sekali.

---

## BL-42 — Restore mengganti database secara non-atomik dan tidak memulihkan otomatis bila proses berhenti

- **Kategori:** Backup / Restore / Error Handling
- **Tingkat risiko:** TINGGI
- **Status validitas:** SUSPECTED
- **Lokasi:** `pusatkupos/lib/data/backup_platform_io.dart:47-55`; `pusatkupos/lib/data/backup_service.dart:838-878`; `pusatkupos/lib/data/backup_service.dart:1060-1114`
- **Bukti source:** `replaceDatabase` menghapus sidecar, lalu **menghapus berkas database lama**, lalu me-rename berkas sementara. Salinan pengaman `.bak-*` hanya dipakai di dalam blok `catch` pada proses yang sama; tidak ada pemindaian `.bak-*`/`.restore.tmp` saat aplikasi dibuka. Restore multi-toko mengganti berkas toko satu per satu, dan registry diperbarui setelah semua penggantian.
- **Alur sebab-akibat:** Proses berhenti (app dibunuh, baterai habis, listrik padam) setelah database lama dihapus tetapi sebelum rename selesai → tidak ada database di path aktif. Saat dibuka lagi, `openDatabase` membuat skema kosong baru; salinan `.bak-*` tetap ada tetapi tidak dipakai otomatis. Pada restore multi-toko, sebagian toko dapat memakai data baru dan sebagian data lama.
- **Skenario masalah:** Pemilik memulihkan backup saat baterai lemah; perangkat mati di tengah penggantian. Aplikasi terbuka seolah baru tanpa data, dan pemilik tidak mengetahui salinan pengaman ada di folder aplikasi.
- **Dampak bisnis:** Data usaha tampak hilang seluruhnya; operasional berhenti sampai pemulihan manual dilakukan; pada multi-toko, data antartoko menjadi tidak sinkron.
- **Dampak integritas data:** Database aktif hilang/baru kosong meskipun backup valid; tidak ada pemulihan otomatis; registry dapat menunjuk campuran berkas lama/baru.
- **Rekomendasi perbaikan:** Gunakan pertukaran atomik (rename database lama ke `.old`, rename berkas baru ke path aktif, hapus `.old` setelah verifikasi), fsync sebelum/sesudah rename, dan pada startup pulihkan otomatis dari `.bak-*`/`.restore.tmp` bila database aktif hilang atau gagal dibuka. Untuk multi-toko, siapkan staging dan commit registry setelah semua berkas terverifikasi.

---

## Ringkasan jumlah

| Risiko | ID |
|---|---|
| KRITIS (2) | BL-01, BL-02 |
| TINGGI (7) | BL-03, BL-04, BL-05, BL-06, BL-07, BL-08, BL-42 |
| SEDANG (17) | BL-09 s.d. BL-24, BL-41 |
| RENDAH (16) | BL-25 s.d. BL-40 |
