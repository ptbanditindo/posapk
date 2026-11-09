# 11 — FEATURE TOGGLE & MODULE ISOLATION AUDIT

Ruang lingkup: aktivasi/deaktivasi fitur, default, persistensi, perubahan runtime, dampak DB, navigasi, transaksi, laporan, dependensi sync; memastikan fitur nonaktif tidak menjalankan logika bisnis di belakang layar dan transaksi lama tetap terbaca.

---

## 1. Mekanisme yang Ditemukan

- `store_features` menyimpan `enabled`, `version`, `updated_by`, `updated_at`, `sync_hlc_*`, `sync_id`.
- `FeatureFlagsService.requireEnabled` melempar `StateError` bila fitur mati ([feature_flags.dart:170](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L170)).
- `FeatureGate` menjadi gerbang tunggal untuk service lokal dan penerapan delta remote.
- `setEnabled` hanya untuk owner (`actor.isOwner`), menulis `business_audits` dan `feature_audits`, menaikkan `version`, dan meng-enqueue perubahan ([feature_flags.dart:212](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L212)).
- `acceptsRemoteAt` menerima data historis yang dibuat **sebelum** fitur dinonaktifkan, dan menolak data setelahnya ([feature_flags.dart:189](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L189)).
- Dependensi: fitur anak tidak dapat diaktifkan bila induk mati.

**Kontrol positif:** default fail-closed; perubahan fitur diaudit; data lama tetap diterima; flag tidak menghapus data.

---

## 2. Registry Temuan

### FLG-01 — Menonaktifkan fitur induk tidak menonaktifkan fitur anak
- **Severity:** MEDIUM
- **Kategori:** ARCHITECTURE GAP
- **Status:** Terkonfirmasi
- **Lokasi:** [feature_flags.dart:228](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L228)
- **Fungsi/Kelas:** `setEnabled`
- **Implementasi:** Pemeriksaan `dependsOn` hanya dilakukan saat **mengaktifkan** anak. Saat induk dinonaktifkan, baris anak tetap `enabled = 1`. Sebagian service anak memanggil `requireEnabled(induk)` juga (mis. `requirePurchaseDebt`), tetapi tidak semua modul anak melakukan pemeriksaan ganda.
- **Penyebab:** Dependensi dianggap syarat aktivasi, bukan invarian runtime.
- **Dampak:** Fitur anak dapat tetap tampil/berjalan tanpa induk; perilaku berbeda antar modul.
- **Rekomendasi:** Saat induk dinonaktifkan, nonaktifkan anak secara transaksional atau tegakkan invarian di `isEnabled` (anak dianggap mati bila induk mati).
- **Dependensi:** —

### FLG-02 — Tidak ada deteksi siklus/depth pada `dependsOn`
- **Severity:** LOW
- **Kategori:** POTENTIAL DEFECT
- **Status:** Terkonfirmasi
- **Lokasi:** [feature_flags.dart:33](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L33)
- **Fungsi/Kelas:** `StoreFeature.dependsOn`
- **Implementasi:** Katalog statis saat ini tidak memiliki siklus, tetapi tidak ada validasi yang mencegah siklus bila katalog diperluas.
- **Dampak:** Bila siklus ditambahkan, aktivasi dapat mustahil atau rekursi.
- **Rekomendasi:** Validasi katalog saat startup/test.
- **Dependensi:** —

### FLG-03 — Perubahan fitur bersamaan dari dua perangkat: kebijakan konflik tidak eksplisit
- **Severity:** LOW
- **Kategori:** NEEDS VALIDATION
- **Status:** Belum dapat dipastikan dari kode yang dibaca
- **Lokasi:** [sync_service.dart](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/sync/sync_service.dart) penerapan `store_features`
- **Implementasi:** Perubahan membawa `version` dan HLC. Penerapan remote memakai mekanisme HLC, tetapi tidak ada aturan "version lebih besar menang" yang terdokumentasi di kode penerapan yang diperiksa.
- **Dampak:** Dua owner (jarang, karena 1 toko 1 kasir) dapat saling menimpa.
- **Rekomendasi:** Tetapkan aturan last-writer-wins berbasis HLC atau version + audit konflik.
- **Dependensi:** SYN-04.

### FLG-04 — Fitur nonaktif tetap dapat dibaca dalam laporan (sesuai harapan)
- **Severity:** INFO (kontrol positif)
- **Kategori:** —
- **Status:** PASS
- **Lokasi:** [feature_flags.dart:189](file:///C:/Users/Administrator/Downloads/posapk/pusatkupos/lib/data/feature_flags.dart#L189)
- **Implementasi:** `acceptsRemoteAt` menerima dokumen historis; laporan membaca data lama tanpa memanggil `requireEnabled`.
- **Dampak:** Tidak ada; transaksi lama tetap dapat dibaca.
- **Rekomendasi:** Pertahankan.

---

## 3. Matriks Isolasi Modul

| Uji | Hasil | Catatan |
|---|---|---|
| Fitur mati memblokir pembuatan baru di service | PASS | `requireEnabled`/`requirePurchaseDebt` |
| Fitur mati menyembunyikan navigasi | PASS (UI) | `AppState.can` |
| Fitur mati tidak menjalankan logika bisnis | PARTIAL | Tergantung modul; anak tanpa cek ganda dapat lolos (FLG-01) |
| Transaksi lama tetap terbaca | PASS | Tidak ada filter flag di laporan |
| Data historis dari perangkat lain diterima | PASS | `acceptsRemoteAt` |
| Perubahan fitur tersinkron | PASS | Enqueue + HLC/version |
| Perubahan fitur diaudit | PASS | `business_audits` + `feature_audits` |
| Hanya owner dapat mengubah | PASS | `setEnabled` |
| Menonaktifkan induk menonaktifkan anak | **FAIL** | FLG-01 |

---

## 4. Kesimpulan

Feature toggle dirancang dengan baik: fail-closed, owner-only, auditable, dan sadar histori. Kelemahan utama adalah invarian dependensi yang hanya ditegakkan saat aktivasi, serta kebijakan konflik perubahan fitur yang belum eksplisit. Tidak ditemukan bukti bahwa fitur nonaktif menghapus atau merusak data lama.
