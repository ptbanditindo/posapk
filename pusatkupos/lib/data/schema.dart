import 'package:sqflite/sqflite.dart';

/// Skema database lokal PusatkuPOS.
///
/// Database dirancang bersih dari kebutuhan bisnis saat ini. Tidak ada jalur
/// migrasi dari skema lama: aplikasi menolak database dengan versi berbeda dan
/// membuat database baru. Semua tabel transaksi bersifat append-only; koreksi,
/// retur, dan pembatalan disimpan sebagai baris/state, bukan dengan menghapus
/// riwayat.
///
/// Konvensi:
/// - Uang dalam rupiah integer.
/// - Kuantitas barang dalam `jumlah_milli` (1/1000 satuan); `jumlah` adalah
///   nilai utuh untuk tampilan/kompatibilitas baca.
/// - Setiap entitas tersinkron memiliki `sync_id`, `store_id`, `device_id`,
///   HLC, dan `deleted_at`.
Future<void> createCleanSchema(Database db) async {
  // ---------------------------------------------------------------------------
  // Identitas perangkat, pemilik, lisensi, dan pengaturan
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE owner_identity (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      owner_id TEXT NOT NULL,
      public_key TEXT NOT NULL,
      recovery_hash TEXT,
      recovery_salt TEXT,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE license (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      plan TEXT NOT NULL DEFAULT 'free',
      period_end TEXT,
      device_limit INTEGER NOT NULL DEFAULT 1,
      store_limit INTEGER NOT NULL DEFAULT 1,
      provider TEXT NOT NULL DEFAULT 'manual',
      token TEXT,
      activated_at TEXT,
      server_time TEXT,
      last_verified_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE login_guards (
      scope TEXT PRIMARY KEY,
      failures INTEGER NOT NULL DEFAULT 0,
      lock_until TEXT
    )
  ''');

  // ---------------------------------------------------------------------------
  // Akun, peran, izin, dan akses toko
  //
  // Akun melekat pada user, bukan perangkat. `store_ids_json` dipertahankan
  // untuk tampilan cepat, sedangkan `employee_store_access` menjadi sumber
  // otorisasi per toko yang dapat disinkronkan dan diaudit.
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE employee_accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      username TEXT NOT NULL,
      nama TEXT NOT NULL,
      role_base TEXT NOT NULL DEFAULT 'KASIR',
      extra_permissions_json TEXT NOT NULL DEFAULT '[]',
      store_ids_json TEXT NOT NULL DEFAULT '[]',
      password_hash TEXT NOT NULL,
      password_salt TEXT NOT NULL,
      password_iterations INTEGER NOT NULL DEFAULT 120000,
      pin_hash TEXT,
      pin_salt TEXT,
      pin_iterations INTEGER NOT NULL DEFAULT 120000,
      must_change_password INTEGER NOT NULL DEFAULT 1,
      aktif INTEGER NOT NULL DEFAULT 1,
      permission_version INTEGER NOT NULL DEFAULT 1,
      permissions_explicit INTEGER NOT NULL DEFAULT 0,
      last_login_at TEXT,
      last_permission_sync_at TEXT,
      jenis_imbalan TEXT NOT NULL DEFAULT 'KOMISI',
      gaji_bulanan INTEGER NOT NULL DEFAULT 0,
      komisi_mode TEXT NOT NULL DEFAULT 'PERSEN',
      komisi_barang_nilai INTEGER NOT NULL DEFAULT 0,
      komisi_jasa_nilai INTEGER NOT NULL DEFAULT 0,
      payroll_period TEXT NOT NULL DEFAULT 'BULANAN',
      payroll_tanggal INTEGER NOT NULL DEFAULT 1,
      payroll_hari INTEGER NOT NULL DEFAULT 1,
      bank_nama TEXT,
      bank_nomor TEXT,
      bank_pemilik TEXT,
      tanggal_masuk TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_employee_username_aktif '
    'ON employee_accounts(username) WHERE deleted_at IS NULL',
  );
  await db.execute(
    'CREATE INDEX ix_employee_aktif ON employee_accounts(aktif, deleted_at)',
  );
  await db.execute('''
    CREATE TABLE employee_store_access (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL,
      employee_sync_id TEXT NOT NULL,
      role_base TEXT NOT NULL DEFAULT 'KASIR',
      extra_permissions_json TEXT NOT NULL DEFAULT '[]',
      permissions_explicit INTEGER NOT NULL DEFAULT 0,
      aktif INTEGER NOT NULL DEFAULT 1,
      version INTEGER NOT NULL DEFAULT 1,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE (store_id, employee_sync_id)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_store_access_employee '
    'ON employee_store_access(employee_sync_id, store_id)',
  );
  await db.execute('''
    CREATE TABLE permission_audits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      actor TEXT NOT NULL,
      target_account_id INTEGER,
      target_employee_sync_id TEXT,
      action TEXT NOT NULL,
      detail_json TEXT NOT NULL DEFAULT '{}',
      before_json TEXT NOT NULL DEFAULT '{}',
      after_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE devices (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      nama TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'owner',
      employee_account_id INTEGER,
      employee_sync_id TEXT,
      public_key TEXT NOT NULL,
      encryption_key TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      last_seen_at TEXT,
      last_server_time TEXT,
      revoked_at TEXT,
      revoked_reason TEXT NOT NULL DEFAULT ''
    )
  ''');

  // ---------------------------------------------------------------------------
  // Audit bisnis umum untuk aksi kritis (void, retur, opname, gaji, izin)
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE business_audits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      waktu TEXT NOT NULL,
      aktor TEXT NOT NULL,
      aktor_employee_sync_id TEXT,
      aksi TEXT NOT NULL,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL DEFAULT '',
      before_json TEXT NOT NULL DEFAULT '{}',
      after_json TEXT NOT NULL DEFAULT '{}',
      alasan TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_business_audits_entity '
    'ON business_audits(entity, entity_id, waktu)',
  );

  // ---------------------------------------------------------------------------
  // Data master tersinkron
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE customers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nama TEXT NOT NULL,
      nama_normalized TEXT NOT NULL DEFAULT '',
      nomor_hp TEXT NOT NULL,
      nomor_hp_normalized TEXT NOT NULL DEFAULT '',
      alamat TEXT,
      catatan TEXT,
      sumber TEXT,
      wa_consent INTEGER NOT NULL DEFAULT 1,
      do_not_contact INTEGER NOT NULL DEFAULT 0,
      last_contact_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_customers_nama ON customers(nama_normalized)',
  );
  await db.execute(
    'CREATE INDEX ix_customers_hp ON customers(nomor_hp_normalized)',
  );
  await db.execute(
    'CREATE INDEX ix_customers_deleted ON customers(deleted_at)',
  );

  await db.execute('''
    CREATE TABLE vehicle_or_units (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      customer_id INTEGER,
      unit_type TEXT NOT NULL DEFAULT 'MOBIL',
      nopol TEXT,
      merek TEXT,
      tipe TEXT,
      tahun_mobil INTEGER,
      no_rangka TEXT,
      no_mesin TEXT,
      km_terakhir INTEGER,
      jenis_mobil TEXT,
      tipe_radiator TEXT,
      label_radiator TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_units_customer ON vehicle_or_units(customer_id)',
  );
  await db.execute('CREATE INDEX ix_units_nopol ON vehicle_or_units(nopol)');
  await db.execute(
    'CREATE INDEX ix_units_deleted ON vehicle_or_units(deleted_at)',
  );

  await db.execute('''
    CREATE TABLE stock_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      kode TEXT NOT NULL,
      barcode TEXT,
      nama TEXT NOT NULL,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      harga_jual INTEGER NOT NULL DEFAULT 0,
      harga_jual_minimum INTEGER NOT NULL DEFAULT 0,
      jumlah INTEGER NOT NULL DEFAULT 0,
      jumlah_milli INTEGER,
      stok_minimum INTEGER NOT NULL DEFAULT 0,
      satuan TEXT NOT NULL DEFAULT 'pcs',
      desimal INTEGER NOT NULL DEFAULT 0,
      lokasi_rak TEXT,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (harga_modal >= 0),
      CHECK (harga_jual >= 0),
      CHECK (stok_minimum >= 0)
    )
  ''');
  // Kode hanya unik untuk barang aktif. Barang yang dihapus tidak boleh
  // memblokir penggunaan kode yang sama.
  await db.execute(
    'CREATE UNIQUE INDEX ux_stock_kode_aktif '
    'ON stock_items(kode) WHERE deleted_at IS NULL',
  );
  await db.execute(
    'CREATE UNIQUE INDEX ux_stock_barcode_aktif '
    'ON stock_items(barcode) WHERE barcode IS NOT NULL AND deleted_at IS NULL',
  );
  await db.execute(
    'CREATE INDEX ix_stock_items_nama ON stock_items(nama)',
  );
  await db.execute(
    'CREATE INDEX ix_stock_items_deleted ON stock_items(deleted_at)',
  );

  await db.execute('''
    CREATE TABLE harga_jasa (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nama TEXT NOT NULL,
      harga_jual INTEGER NOT NULL DEFAULT 0,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (harga_jual >= 0),
      CHECK (harga_modal >= 0)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_harga_jasa_deleted ON harga_jasa(deleted_at)',
  );

  await db.execute('''
    CREATE TABLE suppliers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nama TEXT NOT NULL,
      nomor_hp TEXT,
      alamat TEXT,
      catatan TEXT,
      aktif INTEGER NOT NULL DEFAULT 1,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_suppliers_deleted ON suppliers(deleted_at)',
  );
  await db.execute('''
    CREATE TABLE supplier_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      supplier_id INTEGER NOT NULL,
      stock_item_id INTEGER NOT NULL,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
      FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
    )
  ''');
  // Relasi yang dihapus tidak boleh menghalangi penambahan ulang pasangan
  // supplier+barang yang sama.
  await db.execute(
    'CREATE UNIQUE INDEX ux_supplier_item_aktif '
    'ON supplier_items(supplier_id, stock_item_id) WHERE deleted_at IS NULL',
  );
  await db.execute(
    'CREATE INDEX ix_supplier_items_deleted ON supplier_items(deleted_at)',
  );
  await db.execute('''
    CREATE TABLE supplier_followups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      supplier_id INTEGER NOT NULL,
      stock_item_id INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'BELUM',
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
      FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_supplier_followup_aktif '
    'ON supplier_followups(supplier_id, stock_item_id) '
    'WHERE deleted_at IS NULL',
  );
  await db.execute(
    'CREATE INDEX ix_supplier_followups_deleted '
    'ON supplier_followups(deleted_at)',
  );

  await db.execute('''
    CREATE TABLE followup_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      jenis TEXT NOT NULL,
      item_key TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      stage INTEGER NOT NULL DEFAULT 0,
      interval_bulan INTEGER NOT NULL DEFAULT 0,
      reference_date TEXT,
      jatuh_tempo TEXT,
      customer_id INTEGER,
      unit_id INTEGER,
      service_record_id INTEGER,
      followup_terakhir TEXT,
      janji_bayar TEXT,
      tanggal_service TEXT,
      tunda_sampai TEXT,
      no_response_count INTEGER NOT NULL DEFAULT 0,
      perlu_telepon INTEGER NOT NULL DEFAULT 0,
      alasan_arsip TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_followup_item_aktif '
    "ON followup_items(item_key) WHERE status <> 'ARSIP'",
  );
  await db.execute(
    'CREATE INDEX ix_followup_customer ON followup_items(customer_id)',
  );
  await db.execute(
    'CREATE INDEX ix_followup_deleted ON followup_items(deleted_at)',
  );
  await db.execute('''
    CREATE TABLE followup_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      item_id INTEGER NOT NULL,
      jenis TEXT NOT NULL,
      status TEXT,
      catatan TEXT,
      dibuat_oleh TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (item_id) REFERENCES followup_items(id) ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE wa_message_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      customer_id INTEGER,
      jenis TEXT NOT NULL,
      status TEXT NOT NULL,
      nomor_masked TEXT,
      provider_message_id TEXT,
      error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');

  // ---------------------------------------------------------------------------
  // Nota dan baris transaksi (append-only, snapshot nilai)
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE service_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      unit_id INTEGER,
      customer_id INTEGER,
      no_nota TEXT NOT NULL UNIQUE,
      request_id TEXT UNIQUE,
      jenis_transaksi TEXT NOT NULL DEFAULT 'servis_langsung',
      mode_saat_dibuat_json TEXT NOT NULL DEFAULT '{}',
      diskon_snapshot_json TEXT NOT NULL DEFAULT '{}',
      pajak_snapshot_json TEXT NOT NULL DEFAULT '{}',
      work_order_sync_id TEXT,
      estimate_sync_id TEXT,
      total_estimasi_terakhir INTEGER,
      waktu_service TEXT NOT NULL,
      keluhan_awal TEXT NOT NULL,
      catatan_pengerjaan TEXT,
      biaya_jasa INTEGER NOT NULL DEFAULT 0,
      total_part INTEGER NOT NULL DEFAULT 0,
      diskon INTEGER NOT NULL DEFAULT 0,
      pajak INTEGER NOT NULL DEFAULT 0,
      biaya_lain INTEGER NOT NULL DEFAULT 0,
      total_servis INTEGER NOT NULL DEFAULT 0,
      total_koreksi INTEGER NOT NULL DEFAULT 0,
      total_retur INTEGER NOT NULL DEFAULT 0,
      total_efektif INTEGER NOT NULL DEFAULT 0,
      total_kas_diterima INTEGER NOT NULL DEFAULT 0,
      commission_snapshot_json TEXT NOT NULL DEFAULT '{}',
      metode_bayar TEXT NOT NULL DEFAULT 'CASH',
      bayar INTEGER NOT NULL DEFAULT 0,
      kembalian INTEGER NOT NULL DEFAULT 0,
      status_bayar TEXT NOT NULL DEFAULT 'LUNAS',
      jenis_bayar TEXT NOT NULL DEFAULT 'LUNAS',
      total_dibayar INTEGER NOT NULL DEFAULT 0,
      sisa_bayar INTEGER NOT NULL DEFAULT 0,
      jatuh_tempo TEXT,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      void_reason TEXT,
      voided_at TEXT,
      void_refund INTEGER NOT NULL DEFAULT 0,
      created_by TEXT,
      created_by_employee_id TEXT,
      cashier_employee_id TEXT,
      mechanic TEXT,
      mechanic_employee_id TEXT,
      bergaransi INTEGER NOT NULL DEFAULT 1,
      garansi_bulan INTEGER NOT NULL DEFAULT 1,
      garansi_sampai TEXT,
      catatan_garansi TEXT,
      status_klaim TEXT NOT NULL DEFAULT 'Belum claim',
      tanggal_klaim TEXT,
      sparepart_only INTEGER NOT NULL DEFAULT 0,
      garansi_barang_aktif INTEGER NOT NULL DEFAULT 0,
      garansi_barang_nilai INTEGER NOT NULL DEFAULT 0,
      garansi_barang_satuan TEXT NOT NULL DEFAULT 'HARI',
      garansi_barang_sampai TEXT,
      unit_ditinggal INTEGER NOT NULL DEFAULT 0,
      diambil_at TEXT,
      version INTEGER NOT NULL DEFAULT 1,
      synced_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (biaya_jasa >= 0),
      CHECK (total_part >= 0),
      CHECK (diskon >= 0),
      CHECK (pajak >= 0),
      CHECK (biaya_lain >= 0),
      CHECK (total_servis >= 0),
      CHECK (total_efektif >= 0),
      CHECK (bayar >= 0),
      CHECK (kembalian >= 0),
      CHECK (total_dibayar >= 0),
      CHECK (sisa_bayar >= 0),
      CHECK (void_refund >= 0),
      CHECK (status IN ('AKTIF', 'VOID')),
      CHECK (status = 'AKTIF' OR voided_at IS NOT NULL),
      FOREIGN KEY (unit_id) REFERENCES vehicle_or_units(id) ON DELETE SET NULL,
      FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_service_records_waktu '
    'ON service_records(store_id, waktu_service)',
  );
  await db.execute(
    'CREATE INDEX ix_service_records_jenis '
    'ON service_records(jenis_transaksi)',
  );
  await db.execute(
    'CREATE INDEX ix_service_records_customer '
    'ON service_records(customer_id, waktu_service)',
  );
  await db.execute(
    'CREATE INDEX ix_service_records_status '
    'ON service_records(status, waktu_service)',
  );
  await db.execute(
    'CREATE INDEX ix_service_records_laporan '
    'ON service_records(store_id, jenis_transaksi, waktu_service)',
  );
  // Nilai final nota dibekukan setelah dibuat. Koreksi, retur, dan void
  // mengubah kolom ringkasan (total_koreksi/total_retur/total_efektif),
  // bukan komponen asal, agar struk dan laporan tetap dapat diaudit.
  await db.execute('''
    CREATE TRIGGER trg_service_records_komponen_immutable
    BEFORE UPDATE OF biaya_jasa, total_part, diskon, pajak, biaya_lain,
      total_servis, total_estimasi_terakhir, mode_saat_dibuat_json,
      diskon_snapshot_json, pajak_snapshot_json
    ON service_records
    FOR EACH ROW
    WHEN NEW.biaya_jasa IS NOT OLD.biaya_jasa
      OR NEW.total_part IS NOT OLD.total_part
      OR NEW.diskon IS NOT OLD.diskon
      OR NEW.pajak IS NOT OLD.pajak
      OR NEW.biaya_lain IS NOT OLD.biaya_lain
      OR NEW.total_servis IS NOT OLD.total_servis
      OR NEW.total_estimasi_terakhir IS NOT OLD.total_estimasi_terakhir
      OR NEW.mode_saat_dibuat_json IS NOT OLD.mode_saat_dibuat_json
      OR NEW.diskon_snapshot_json IS NOT OLD.diskon_snapshot_json
      OR NEW.pajak_snapshot_json IS NOT OLD.pajak_snapshot_json
    BEGIN
      SELECT RAISE(ABORT, 'komponen biaya nota tidak boleh diubah');
    END
  ''');
  // VOID adalah state terminal: nota yang sudah dibatalkan tidak boleh
  // diaktifkan kembali atau diubah nilai efektifnya.
  await db.execute('''
    CREATE TRIGGER trg_service_records_void_final
    BEFORE UPDATE ON service_records
    FOR EACH ROW
    WHEN OLD.status = 'VOID' AND (
      NEW.status IS NOT 'VOID'
      OR NEW.voided_at IS NOT OLD.voided_at
      OR NEW.void_reason IS NOT OLD.void_reason
      OR NEW.void_refund IS NOT OLD.void_refund
      OR NEW.total_efektif IS NOT OLD.total_efektif
      OR NEW.total_koreksi IS NOT OLD.total_koreksi
      OR NEW.total_retur IS NOT OLD.total_retur
      OR NEW.sisa_bayar IS NOT OLD.sisa_bayar
    )
    BEGIN
      SELECT RAISE(ABORT, 'nota VOID bersifat final');
    END
  ''');

  await db.execute('''
    CREATE TABLE service_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      harga_jasa_id INTEGER,
      harga_jasa_sync_id TEXT,
      deskripsi TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      qty_retur_milli INTEGER NOT NULL DEFAULT 0,
      harga INTEGER NOT NULL,
      subtotal INTEGER NOT NULL,
      harga_jual_terdaftar INTEGER NOT NULL DEFAULT 0,
      harga_batas_saat_transaksi INTEGER NOT NULL DEFAULT 0,
      harga_final INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      diskon_persen_snapshot INTEGER NOT NULL DEFAULT 0,
      alasan_diskon TEXT,
      disetujui_oleh TEXT,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      komisi_mode_snapshot TEXT,
      komisi_nilai_snapshot INTEGER,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jumlah > 0),
      CHECK (harga >= 0),
      CHECK (subtotal >= 0),
      CHECK (harga_jual_terdaftar >= 0),
      CHECK (harga_batas_saat_transaksi >= 0),
      CHECK (harga_final >= 0),
      CHECK (diskon_alokasi >= 0),
      CHECK (diskon_alokasi <= subtotal),
      CHECK (diskon_persen_snapshot BETWEEN 0 AND 100),
      CHECK (qty_retur_milli >= 0),
      CHECK (qty_retur_milli <= jumlah * 1000),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_service_jobs_record '
    'ON service_jobs(service_record_id)',
  );
  await db.execute(
    'CREATE INDEX ix_service_jobs_sync ON service_jobs(sync_id)',
  );
  // Snapshot baris jasa dibekukan; hanya qty retur yang boleh bertambah.
  await db.execute('''
    CREATE TRIGGER trg_service_jobs_snapshot_immutable
    BEFORE UPDATE OF service_record_id, harga_jasa_id, harga_jasa_sync_id,
      deskripsi, jumlah, harga, subtotal, harga_jual_terdaftar,
      harga_batas_saat_transaksi, harga_final, diskon_alokasi,
      diskon_persen_snapshot, interval_servis_bulan,
      komisi_mode_snapshot, komisi_nilai_snapshot
    ON service_jobs
    FOR EACH ROW
    WHEN NEW.service_record_id IS NOT OLD.service_record_id
      OR NEW.harga_jasa_id IS NOT OLD.harga_jasa_id
      OR NEW.harga_jasa_sync_id IS NOT OLD.harga_jasa_sync_id
      OR NEW.deskripsi IS NOT OLD.deskripsi
      OR NEW.jumlah IS NOT OLD.jumlah
      OR NEW.harga IS NOT OLD.harga
      OR NEW.subtotal IS NOT OLD.subtotal
      OR NEW.harga_jual_terdaftar IS NOT OLD.harga_jual_terdaftar
      OR NEW.harga_batas_saat_transaksi IS NOT OLD.harga_batas_saat_transaksi
      OR NEW.harga_final IS NOT OLD.harga_final
      OR NEW.diskon_alokasi IS NOT OLD.diskon_alokasi
      OR NEW.diskon_persen_snapshot IS NOT OLD.diskon_persen_snapshot
      OR NEW.interval_servis_bulan IS NOT OLD.interval_servis_bulan
      OR NEW.komisi_mode_snapshot IS NOT OLD.komisi_mode_snapshot
      OR NEW.komisi_nilai_snapshot IS NOT OLD.komisi_nilai_snapshot
    BEGIN
      SELECT RAISE(ABORT, 'snapshot baris jasa bersifat final');
    END
  ''');

  await db.execute('''
    CREATE TABLE service_parts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      stock_item_id INTEGER,
      stock_sync_id TEXT,
      nama_part TEXT NOT NULL,
      satuan TEXT NOT NULL DEFAULT 'pcs',
      jumlah INTEGER NOT NULL,
      jumlah_milli INTEGER NOT NULL,
      qty_retur_milli INTEGER NOT NULL DEFAULT 0,
      harga_satuan INTEGER NOT NULL,
      subtotal INTEGER NOT NULL,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      harga_jual_terdaftar INTEGER NOT NULL DEFAULT 0,
      harga_batas_saat_transaksi INTEGER NOT NULL DEFAULT 0,
      harga_final INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      diskon_persen_snapshot INTEGER NOT NULL DEFAULT 0,
      alasan_diskon TEXT,
      disetujui_oleh TEXT,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jumlah_milli > 0),
      CHECK (harga_satuan >= 0),
      CHECK (subtotal >= 0),
      CHECK (harga_modal >= 0),
      CHECK (harga_jual_terdaftar >= 0),
      CHECK (harga_batas_saat_transaksi >= 0),
      CHECK (harga_final >= 0),
      CHECK (diskon_alokasi >= 0),
      CHECK (diskon_alokasi <= subtotal),
      CHECK (diskon_persen_snapshot BETWEEN 0 AND 100),
      CHECK (qty_retur_milli >= 0),
      CHECK (qty_retur_milli <= jumlah_milli),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_service_parts_record '
    'ON service_parts(service_record_id)',
  );
  await db.execute(
    'CREATE INDEX ix_service_parts_sync ON service_parts(sync_id)',
  );
  // Snapshot baris part dibekukan; hanya qty retur yang boleh bertambah.
  await db.execute('''
    CREATE TRIGGER trg_service_parts_snapshot_immutable
    BEFORE UPDATE OF service_record_id, stock_item_id, stock_sync_id,
      nama_part, satuan, jumlah, jumlah_milli, harga_satuan, subtotal,
      harga_modal, harga_jual_terdaftar, harga_batas_saat_transaksi,
      harga_final, diskon_alokasi, diskon_persen_snapshot,
      interval_servis_bulan
    ON service_parts
    FOR EACH ROW
    WHEN NEW.service_record_id IS NOT OLD.service_record_id
      OR NEW.stock_item_id IS NOT OLD.stock_item_id
      OR NEW.stock_sync_id IS NOT OLD.stock_sync_id
      OR NEW.nama_part IS NOT OLD.nama_part
      OR NEW.satuan IS NOT OLD.satuan
      OR NEW.jumlah IS NOT OLD.jumlah
      OR NEW.jumlah_milli IS NOT OLD.jumlah_milli
      OR NEW.harga_satuan IS NOT OLD.harga_satuan
      OR NEW.subtotal IS NOT OLD.subtotal
      OR NEW.harga_modal IS NOT OLD.harga_modal
      OR NEW.harga_jual_terdaftar IS NOT OLD.harga_jual_terdaftar
      OR NEW.harga_batas_saat_transaksi IS NOT OLD.harga_batas_saat_transaksi
      OR NEW.harga_final IS NOT OLD.harga_final
      OR NEW.diskon_alokasi IS NOT OLD.diskon_alokasi
      OR NEW.diskon_persen_snapshot IS NOT OLD.diskon_persen_snapshot
      OR NEW.interval_servis_bulan IS NOT OLD.interval_servis_bulan
    BEGIN
      SELECT RAISE(ABORT, 'snapshot baris part bersifat final');
    END
  ''');

  await db.execute('''
    CREATE TABLE service_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      jenis TEXT NOT NULL DEFAULT 'PELUNASAN',
      metode TEXT NOT NULL DEFAULT 'CASH',
      nominal INTEGER NOT NULL,
      waktu TEXT NOT NULL,
      operator TEXT NOT NULL DEFAULT 'Pemilik',
      request_id TEXT NOT NULL UNIQUE,
      alokasi_json TEXT NOT NULL DEFAULT '{}',
      kas_kategori TEXT NOT NULL DEFAULT 'PENJUALAN',
      kas_shift_id TEXT,
      reference_no TEXT,
      catatan TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jenis IN ('DP', 'PELUNASAN', 'REFUND')),
      CHECK (metode IN ('CASH', 'TRANSFER')),
      CHECK (
        (jenis = 'REFUND' AND nominal < 0)
        OR (jenis <> 'REFUND' AND nominal > 0)
      ),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_service_payments_record '
    'ON service_payments(service_record_id, waktu)',
  );
  await db.execute(
    'CREATE INDEX ix_service_payments_shift '
    'ON service_payments(kas_shift_id) WHERE kas_shift_id IS NOT NULL',
  );

  // Buku kas: setiap pembayaran/refund menghasilkan satu baris kas yang dapat
  // direkonsiliasi. Nominal bertanda (positif masuk, negatif keluar).
  await db.execute('''
    CREATE TABLE cash_ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      waktu TEXT NOT NULL,
      kategori TEXT NOT NULL,
      sumber_entity TEXT NOT NULL,
      sumber_sync_id TEXT NOT NULL,
      nominal INTEGER NOT NULL,
      metode TEXT NOT NULL DEFAULT 'CASH',
      kas_shift_id TEXT,
      operator TEXT,
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (nominal <> 0),
      CHECK (metode IN ('CASH', 'TRANSFER'))
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_cash_ledger_source '
    'ON cash_ledger(store_id, sumber_entity, sumber_sync_id)',
  );
  await db.execute(
    'CREATE INDEX ix_cash_ledger_waktu ON cash_ledger(waktu)',
  );

  // ---------------------------------------------------------------------------
  // Ledger stok append-only
  //
  // `stock_items.jumlah_milli` adalah saldo; `stock_movements` adalah riwayat
  // perubahan. Setiap movement mencatat saldo sebelum/sesudah dan sumbernya.
  // Opname menyimpan nilai absolut agar penerima tidak menambahkan delta yang
  // salah basis.
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE stock_movements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      stock_item_id INTEGER,
      stock_sync_id TEXT,
      nama_item TEXT,
      jenis TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      jumlah_milli INTEGER,
      stok_sebelum_milli INTEGER,
      stok_sesudah_milli INTEGER,
      opname_absolut_milli INTEGER,
      alasan TEXT,
      sumber_entity TEXT NOT NULL DEFAULT '',
      sumber_sync_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER,
      operator TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_stock_movements_item '
    'ON stock_movements(stock_item_id, created_at)',
  );
  await db.execute(
    'CREATE UNIQUE INDEX ux_stock_movement_source '
    'ON stock_movements(store_id, sumber_entity, sumber_sync_id, jenis) '
    "WHERE sumber_sync_id <> ''",
  );

  // Koreksi nilai nota. Baris baru merujuk nota asli; nota tidak diubah.
  await db.execute('''
    CREATE TABLE nota_adjustments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nota_sync_id TEXT NOT NULL,
      jenis TEXT NOT NULL DEFAULT 'KOREKSI',
      nilai_selisih INTEGER NOT NULL,
      nilai_baru INTEGER NOT NULL,
      nominal_jasa INTEGER NOT NULL DEFAULT 0,
      nominal_part INTEGER NOT NULL DEFAULT 0,
      diskon INTEGER NOT NULL DEFAULT 0,
      alasan TEXT NOT NULL,
      dibuat_oleh TEXT,
      disetujui_oleh TEXT,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      applied_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_adjustments_nota ON nota_adjustments(nota_sync_id)',
  );

  // Retur append-only. State VOID pada nota bersifat terminal.
  await db.execute('''
    CREATE TABLE sale_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      nota_sync_id TEXT NOT NULL,
      no_nota TEXT NOT NULL,
      no_retur TEXT NOT NULL DEFAULT '',
      request_id TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      total INTEGER NOT NULL DEFAULT 0,
      total_modal_kembali INTEGER NOT NULL DEFAULT 0,
      total_refund INTEGER NOT NULL DEFAULT 0,
      alasan TEXT NOT NULL,
      dibuat_oleh TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('AKTIF', 'VOID')),
      CHECK (total >= 0),
      CHECK (total_modal_kembali >= 0),
      CHECK (total_refund >= 0),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_sale_returns_nota '
    'ON sale_returns(service_record_id)',
  );
  // Retur bersifat append-only: identitas dan nilai baris tidak boleh diubah
  // setelah dibuat. `total_refund` hanya boleh diisi sekali dari nol.
  await db.execute('''
    CREATE TRIGGER trg_sale_returns_immutable
    BEFORE UPDATE OF service_record_id, nota_sync_id, no_nota, no_retur,
      request_id, status, total, total_modal_kembali, alasan, voided_at
    ON sale_returns
    FOR EACH ROW
    WHEN NEW.service_record_id IS NOT OLD.service_record_id
      OR NEW.nota_sync_id IS NOT OLD.nota_sync_id
      OR NEW.no_nota IS NOT OLD.no_nota
      OR NEW.no_retur IS NOT OLD.no_retur
      OR NEW.request_id IS NOT OLD.request_id
      OR NEW.status IS NOT OLD.status
      OR NEW.total IS NOT OLD.total
      OR NEW.total_modal_kembali IS NOT OLD.total_modal_kembali
      OR NEW.alasan IS NOT OLD.alasan
      OR NEW.voided_at IS NOT OLD.voided_at
    BEGIN
      SELECT RAISE(ABORT, 'retur bersifat final');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER trg_sale_returns_refund_sekali
    BEFORE UPDATE OF total_refund ON sale_returns
    FOR EACH ROW
    WHEN OLD.total_refund <> 0 AND NEW.total_refund IS NOT OLD.total_refund
    BEGIN
      SELECT RAISE(ABORT, 'refund retur sudah dibukukan');
    END
  ''');
  await db.execute('''
    CREATE TABLE sale_return_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      return_id INTEGER NOT NULL,
      line_type TEXT NOT NULL,
      line_sync_id TEXT NOT NULL DEFAULT '',
      service_job_sync_id TEXT,
      service_part_sync_id TEXT,
      deskripsi TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      jumlah_milli INTEGER NOT NULL,
      qty_asal_milli INTEGER,
      harga_satuan INTEGER NOT NULL DEFAULT 0,
      subtotal INTEGER NOT NULL DEFAULT 0,
      modal_satuan INTEGER NOT NULL DEFAULT 0,
      stock_item_id INTEGER,
      stock_sync_id TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (line_type IN ('jasa', 'part')),
      CHECK (line_sync_id <> ''),
      CHECK (jumlah_milli > 0),
      CHECK (qty_asal_milli IS NULL OR (qty_asal_milli >= 0 AND jumlah_milli <= qty_asal_milli)),
      CHECK (harga_satuan >= 0),
      CHECK (subtotal >= 0),
      CHECK (modal_satuan >= 0),
      FOREIGN KEY (return_id) REFERENCES sale_returns(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_sale_return_items_return '
    'ON sale_return_items(return_id)',
  );
  await db.execute(
    'CREATE UNIQUE INDEX ux_sale_return_line '
    'ON sale_return_items(return_id, line_type, line_sync_id)',
  );
  await db.execute('''
    CREATE TRIGGER trg_sale_return_items_immutable
    BEFORE UPDATE OF return_id, line_type, line_sync_id, service_job_sync_id,
      service_part_sync_id, deskripsi, jumlah, jumlah_milli, qty_asal_milli,
      harga_satuan, subtotal, modal_satuan, stock_item_id, stock_sync_id
    ON sale_return_items
    FOR EACH ROW
    WHEN NEW.return_id IS NOT OLD.return_id
      OR NEW.line_type IS NOT OLD.line_type
      OR NEW.line_sync_id IS NOT OLD.line_sync_id
      OR NEW.service_job_sync_id IS NOT OLD.service_job_sync_id
      OR NEW.service_part_sync_id IS NOT OLD.service_part_sync_id
      OR NEW.deskripsi IS NOT OLD.deskripsi
      OR NEW.jumlah IS NOT OLD.jumlah
      OR NEW.jumlah_milli IS NOT OLD.jumlah_milli
      OR NEW.qty_asal_milli IS NOT OLD.qty_asal_milli
      OR NEW.harga_satuan IS NOT OLD.harga_satuan
      OR NEW.subtotal IS NOT OLD.subtotal
      OR NEW.modal_satuan IS NOT OLD.modal_satuan
      OR NEW.stock_item_id IS NOT OLD.stock_item_id
      OR NEW.stock_sync_id IS NOT OLD.stock_sync_id
    BEGIN
      SELECT RAISE(ABORT, 'baris retur bersifat final');
    END
  ''');
  // Batas retur dihitung lintas semua retur aktif untuk baris nota yang sama,
  // bukan hanya di dalam satu dokumen retur.
  await db.execute('''
    CREATE TRIGGER trg_sale_return_items_batas
    BEFORE INSERT ON sale_return_items
    FOR EACH ROW
    WHEN NEW.qty_asal_milli IS NOT NULL AND NEW.qty_asal_milli >= 0
      AND NEW.jumlah_milli + COALESCE((
        SELECT SUM(ri.jumlah_milli)
        FROM sale_return_items ri
        JOIN sale_returns sr ON sr.id = ri.return_id
        WHERE sr.deleted_at IS NULL AND ri.deleted_at IS NULL
          AND ri.line_type = NEW.line_type
          AND ri.line_sync_id = NEW.line_sync_id
      ), 0) > NEW.qty_asal_milli
    BEGIN
      SELECT RAISE(ABORT, 'qty retur melebihi qty terjual');
    END
  ''');

  await db.execute('''
    CREATE TABLE service_record_mechanics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      employee_sync_id TEXT NOT NULL,
      employee_nama_snapshot TEXT,
      peran TEXT,
      urutan INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE(service_record_id, employee_sync_id),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');

  // Snapshot tarif komisi: perubahan tarif master tidak mengubah nota lama.
  await db.execute('''
    CREATE TABLE service_record_commissions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      employee_sync_id TEXT NOT NULL,
      employee_nama_snapshot TEXT,
      mode_snapshot TEXT NOT NULL DEFAULT 'PERSEN',
      nilai_snapshot INTEGER NOT NULL DEFAULT 0,
      dasar_jasa INTEGER NOT NULL DEFAULT 0,
      dasar_barang INTEGER NOT NULL DEFAULT 0,
      nominal INTEGER NOT NULL DEFAULT 0,
      nominal_override INTEGER,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      catatan TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE(service_record_id, employee_sync_id),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE employee_debts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      employee_sync_id TEXT NOT NULL,
      employee_nama_snapshot TEXT,
      nominal INTEGER NOT NULL,
      terbayar INTEGER NOT NULL DEFAULT 0,
      sumber TEXT,
      jatuh_tempo TEXT,
      catatan TEXT,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (nominal >= 0),
      CHECK (terbayar >= 0),
      CHECK (terbayar <= nominal)
    )
  ''');
  await db.execute('''
    CREATE TABLE salary_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      employee_sync_id TEXT NOT NULL,
      employee_nama_snapshot TEXT,
      periode TEXT NOT NULL,
      cycle_start TEXT NOT NULL,
      cycle_end TEXT NOT NULL,
      cycle_key TEXT NOT NULL DEFAULT '',
      tanggal TEXT NOT NULL,
      nominal INTEGER NOT NULL,
      potongan_hutang INTEGER NOT NULL DEFAULT 0,
      cicilan_hutang INTEGER NOT NULL DEFAULT 0,
      bonus INTEGER NOT NULL DEFAULT 0,
      komisi_total INTEGER NOT NULL DEFAULT 0,
      kas_keluar INTEGER NOT NULL DEFAULT 0,
      metode TEXT NOT NULL DEFAULT 'CASH',
      status TEXT NOT NULL DEFAULT 'AKTIF',
      konflik_sync_id TEXT,
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (nominal >= 0),
      CHECK (potongan_hutang >= 0),
      CHECK (cicilan_hutang >= 0),
      CHECK (bonus >= 0),
      CHECK (komisi_total >= 0),
      CHECK (kas_keluar >= 0),
      CHECK (metode IN ('CASH', 'TRANSFER')),
      CHECK (cycle_key <> ''),
      UNIQUE(employee_sync_id, cycle_start)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_commissions_employee '
    'ON service_record_commissions(employee_sync_id)',
  );
  await db.execute(
    'CREATE INDEX ix_debts_employee ON employee_debts(employee_sync_id)',
  );
  await db.execute(
    'CREATE INDEX ix_salary_employee ON salary_payments(employee_sync_id)',
  );
  await db.execute(
    'CREATE UNIQUE INDEX ux_salary_cycle_key '
    "ON salary_payments(cycle_key) WHERE cycle_key <> ''",
  );

  // ---------------------------------------------------------------------------
  // Pengaturan toko, estimasi, dan work order
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE store_settings (
      store_id TEXT PRIMARY KEY,
      sync_id TEXT NOT NULL UNIQUE,
      device_id TEXT NOT NULL DEFAULT '',
      transaction_types_json TEXT NOT NULL DEFAULT '{}',
      order_stages_json TEXT NOT NULL DEFAULT '{}',
      simpan_estimasi_lepas INTEGER NOT NULL DEFAULT 1,
      approval_below_cost INTEGER NOT NULL DEFAULT 0,
      vehicle_required INTEGER NOT NULL DEFAULT 1,
      approver_mode TEXT NOT NULL DEFAULT 'owner',
      approver_employee_sync_id TEXT,
      role_permissions_json TEXT NOT NULL DEFAULT '{}',
      preset TEXT NOT NULL DEFAULT 'layanan_langsung',
      permission_version INTEGER NOT NULL DEFAULT 1,
      schema_contract_version INTEGER NOT NULL DEFAULT 1,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');

  await db.execute('''
    CREATE TABLE estimates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      nomor_estimasi TEXT NOT NULL,
      work_order_sync_id TEXT,
      customer_sync_id TEXT,
      unit_sync_id TEXT,
      versi INTEGER NOT NULL DEFAULT 1,
      revisi_dari_sync_id TEXT,
      alasan_revisi TEXT,
      masa_berlaku TEXT,
      total INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'aktif',
      disetujui_oleh TEXT,
      disetujui_at TEXT,
      dibatalkan_oleh TEXT,
      dibatalkan_at TEXT,
      alasan_batal TEXT,
      mode_saat_dibuat_json TEXT NOT NULL DEFAULT '{}',
      converted_nota_sync_id TEXT,
      total_estimasi_terakhir INTEGER,
      dibuat_oleh TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_estimates_nomor_versi '
    'ON estimates(store_id, nomor_estimasi, versi) WHERE deleted_at IS NULL',
  );
  await db.execute('''
    CREATE TABLE estimate_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      estimate_sync_id TEXT NOT NULL,
      jenis TEXT NOT NULL,
      stock_sync_id TEXT,
      deskripsi TEXT NOT NULL,
      satuan TEXT NOT NULL DEFAULT 'pcs',
      jumlah INTEGER NOT NULL,
      jumlah_milli INTEGER NOT NULL,
      harga_jual_terdaftar INTEGER NOT NULL DEFAULT 0,
      harga_batas_saat_transaksi INTEGER NOT NULL DEFAULT 0,
      harga_final INTEGER NOT NULL DEFAULT 0,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      subtotal INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (COALESCE(jumlah_milli, jumlah * 1000) > 0),
      CHECK (harga_jual_terdaftar >= 0),
      CHECK (harga_batas_saat_transaksi >= 0),
      CHECK (harga_final >= 0),
      CHECK (harga_modal >= 0),
      CHECK (diskon_alokasi >= 0),
      CHECK (subtotal >= 0)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_estimate_items_estimate '
    'ON estimate_items(estimate_sync_id)',
  );

  await db.execute('''
    CREATE TABLE work_orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nomor_order TEXT,
      nomor_antrian TEXT,
      customer_sync_id TEXT,
      unit_sync_id TEXT,
      keluhan TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'antri',
      mekanik_sync_id TEXT,
      mekanik_nama TEXT,
      waktu_masuk TEXT NOT NULL,
      waktu_selesai TEXT,
      nota_sync_id TEXT,
      mode_saat_dibuat_json TEXT NOT NULL DEFAULT '{}',
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX ux_work_orders_nomor '
    'ON work_orders(store_id, nomor_order) '
    'WHERE nomor_order IS NOT NULL AND deleted_at IS NULL',
  );
  await db.execute('''
    CREATE TABLE work_order_status_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      work_order_sync_id TEXT NOT NULL,
      status TEXT NOT NULL,
      waktu TEXT NOT NULL,
      pembuat TEXT,
      perangkat TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_wo_status_order '
    'ON work_order_status_log(work_order_sync_id, sync_hlc_wall)',
  );

  await db.execute('''
    CREATE TABLE document_counters (
      device_id TEXT NOT NULL,
      doc_type TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      terakhir INTEGER NOT NULL DEFAULT 0,
      last_no TEXT,
      PRIMARY KEY (device_id, doc_type, tanggal)
    )
  ''');

  // ---------------------------------------------------------------------------
  // Rekonsiliasi harian
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE day_digests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      source_device_id TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      data_type TEXT NOT NULL,
      jumlah INTEGER NOT NULL DEFAULT 0,
      hash TEXT NOT NULL DEFAULT '',
      nilai_hash TEXT NOT NULL DEFAULT '',
      retur_hash TEXT NOT NULL DEFAULT '',
      payment_hash TEXT NOT NULL DEFAULT '',
      void_count INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE(store_id, source_device_id, tanggal, data_type)
    )
  ''');
  await db.execute('''
    CREATE TABLE reconciliation_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      target_device_id TEXT NOT NULL DEFAULT '',
      tanggal TEXT NOT NULL,
      data_type TEXT NOT NULL,
      alasan TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      resolved_at TEXT,
      resolved_by TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');

  // ---------------------------------------------------------------------------
  // Antrean sinkronisasi dan status
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE sync_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      hlc_wall INTEGER NOT NULL,
      hlc_counter INTEGER NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL DEFAULT '',
      action TEXT NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '{}',
      payload_hash TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending',
      retry_count INTEGER NOT NULL DEFAULT 0,
      next_retry_at TEXT,
      last_attempt_at TEXT,
      error TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      sent_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_inbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      store_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      relay_seq INTEGER NOT NULL DEFAULT 0,
      envelope_id TEXT NOT NULL DEFAULT '',
      idempotency_key TEXT NOT NULL DEFAULT '',
      entity TEXT NOT NULL DEFAULT '',
      entity_id TEXT NOT NULL DEFAULT '',
      envelope_json TEXT NOT NULL DEFAULT '{}',
      last_error TEXT NOT NULL DEFAULT '',
      retry_count INTEGER NOT NULL DEFAULT 0,
      next_retry_at TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      blocked INTEGER NOT NULL DEFAULT 0,
      blocked_reason TEXT NOT NULL DEFAULT '',
      applied_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (envelope_id),
      UNIQUE (idempotency_key)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_sync_inbox_due ON sync_inbox(status, next_retry_at)',
  );
  await db.execute(
    'CREATE INDEX ix_sync_inbox_blocked ON sync_inbox(blocked, relay_seq)',
  );
  await db.execute('''
    CREATE TABLE sync_cursor (
      store_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      last_seq INTEGER NOT NULL DEFAULT 0,
      last_envelope_id TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL,
      PRIMARY KEY (store_id, device_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE applied_deltas (
      idempotency_key TEXT PRIMARY KEY,
      store_id TEXT NOT NULL DEFAULT '',
      envelope_id TEXT NOT NULL DEFAULT '',
      entity TEXT NOT NULL DEFAULT '',
      entity_id TEXT NOT NULL DEFAULT '',
      reconciled INTEGER NOT NULL DEFAULT 0,
      applied_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_conflicts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      store_id TEXT NOT NULL DEFAULT '',
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL DEFAULT '',
      reason TEXT NOT NULL,
      severity TEXT NOT NULL DEFAULT 'SEDANG',
      detail_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'open',
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NOT NULL DEFAULT '',
      inbox_id INTEGER,
      resolution TEXT,
      resolved_by TEXT,
      created_at TEXT NOT NULL,
      resolved_at TEXT
    )
  ''');
  // Satu konflik tertunda per entitas+alasan; konflik berulang memperbarui
  // baris yang sama agar tidak membanjiri daftar tinjauan. Status `review`
  // ikut dijaga karena datanya sudah diterapkan dan hanya menunggu keputusan.
  await db.execute(
    'CREATE UNIQUE INDEX ux_sync_conflict_pending '
    'ON sync_conflicts(entity, entity_id, reason) '
    "WHERE status IN ('open', 'review')",
  );
  await db.execute('''
    CREATE TABLE device_sync_status (
      device_id TEXT PRIMARY KEY,
      nama TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'owner',
      state TEXT NOT NULL,
      last_seq INTEGER NOT NULL DEFAULT 0,
      pending INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_peer_digests (
      source_device_id TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      data_type TEXT NOT NULL,
      jumlah INTEGER NOT NULL DEFAULT 0,
      hash TEXT NOT NULL DEFAULT '',
      received_at TEXT NOT NULL,
      PRIMARY KEY (source_device_id, tanggal, data_type)
    )
  ''');

  await createOperationalSchema(db);
}

/// Tabel modul operasional yang ditambahkan setelah skema inti.
///
/// Fungsi ini idempoten dan dipanggil saat database dibuka agar instalasi
/// lama pada masa pengembangan tetap mendapatkan tabel baru tanpa migrasi
/// data. Tabel transaksi tetap append-only dan memakai HLC yang sama.
Future<void> createOperationalSchema(Database db) async {
  // ---------------------------------------------------------------------------
  // Fitur opsional per toko
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE IF NOT EXISTS store_features (
      store_id TEXT NOT NULL,
      feature_key TEXT NOT NULL,
      sync_id TEXT NOT NULL UNIQUE,
      device_id TEXT NOT NULL DEFAULT '',
      enabled INTEGER NOT NULL DEFAULT 1,
      version INTEGER NOT NULL DEFAULT 1,
      updated_by TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      PRIMARY KEY (store_id, feature_key)
    )
  ''');

  // ---------------------------------------------------------------------------
  // Penahanan opname (BD-03)
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE IF NOT EXISTS opname_holds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      stock_item_id INTEGER NOT NULL,
      stock_sync_id TEXT NOT NULL,
      nama_item TEXT NOT NULL DEFAULT '',
      jumlah_fisik_milli INTEGER NOT NULL,
      alasan TEXT,
      status TEXT NOT NULL DEFAULT 'TERTUNDA',
      missing_devices_json TEXT NOT NULL DEFAULT '[]',
      provisional INTEGER NOT NULL DEFAULT 0,
      movement_sync_id TEXT,
      applied_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('TERTUNDA', 'SEMENTARA', 'DITERAPKAN', 'BATAL')),
      CHECK (jumlah_fisik_milli >= 0)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_opname_holds_status '
    'ON opname_holds(store_id, status)',
  );

  // ---------------------------------------------------------------------------
  // Pembelian dan utang supplier (BD-12)
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_purchases (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      no_pembelian TEXT NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      supplier_id INTEGER NOT NULL,
      supplier_sync_id TEXT NOT NULL DEFAULT '',
      supplier_nama_snapshot TEXT NOT NULL DEFAULT '',
      tanggal TEXT NOT NULL,
      jatuh_tempo TEXT,
      termin_hari INTEGER NOT NULL DEFAULT 0,
      jenis_bayar TEXT NOT NULL DEFAULT 'KREDIT',
      status TEXT NOT NULL DEFAULT 'AKTIF',
      subtotal INTEGER NOT NULL DEFAULT 0,
      diskon INTEGER NOT NULL DEFAULT 0,
      ongkir INTEGER NOT NULL DEFAULT 0,
      ppn INTEGER NOT NULL DEFAULT 0,
      total INTEGER NOT NULL DEFAULT 0,
      total_dibayar INTEGER NOT NULL DEFAULT 0,
      sisa_utang INTEGER NOT NULL DEFAULT 0,
      catatan TEXT,
      created_by TEXT,
      void_reason TEXT,
      voided_at TEXT,
      voided_by TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jenis_bayar IN ('TUNAI', 'KREDIT')),
      CHECK (status IN ('AKTIF', 'VOID')),
      CHECK (subtotal >= 0),
      CHECK (diskon >= 0),
      CHECK (ongkir >= 0),
      CHECK (ppn >= 0),
      CHECK (total >= 0),
      CHECK (total_dibayar >= 0),
      CHECK (total_dibayar <= total),
      CHECK (sisa_utang >= 0),
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_purchase_no_aktif '
    'ON supplier_purchases(store_id, no_pembelian) WHERE deleted_at IS NULL',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_purchases_supplier '
    'ON supplier_purchases(supplier_id, tanggal)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_purchases_due '
    'ON supplier_purchases(store_id, sisa_utang, jatuh_tempo)',
  );
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS trg_purchase_void_final
    BEFORE UPDATE ON supplier_purchases
    FOR EACH ROW
    WHEN OLD.status = 'VOID' AND (
      NEW.status IS NOT 'VOID'
      OR NEW.total IS NOT OLD.total
      OR NEW.sisa_utang IS NOT OLD.sisa_utang
      OR NEW.total_dibayar IS NOT OLD.total_dibayar
      OR NEW.voided_at IS NOT OLD.voided_at
    )
    BEGIN
      SELECT RAISE(ABORT, 'pembelian VOID bersifat final');
    END
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_purchase_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      purchase_id INTEGER NOT NULL,
      stock_item_id INTEGER NOT NULL,
      stock_sync_id TEXT NOT NULL DEFAULT '',
      nama_snapshot TEXT NOT NULL DEFAULT '',
      satuan TEXT NOT NULL DEFAULT 'pcs',
      jumlah_milli INTEGER NOT NULL,
      harga_satuan INTEGER NOT NULL DEFAULT 0,
      subtotal INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      ongkir_alokasi INTEGER NOT NULL DEFAULT 0,
      harga_pokok_satuan INTEGER NOT NULL DEFAULT 0,
      qty_retur_milli INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jumlah_milli > 0),
      CHECK (harga_satuan >= 0),
      CHECK (subtotal >= 0),
      CHECK (diskon_alokasi >= 0),
      CHECK (ongkir_alokasi >= 0),
      CHECK (harga_pokok_satuan >= 0),
      CHECK (qty_retur_milli >= 0),
      CHECK (qty_retur_milli <= jumlah_milli),
      FOREIGN KEY (purchase_id) REFERENCES supplier_purchases(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_purchase_item_barang '
    'ON supplier_purchase_items(purchase_id, stock_sync_id)',
  );

  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      purchase_id INTEGER NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      jenis TEXT NOT NULL DEFAULT 'PELUNASAN',
      metode TEXT NOT NULL DEFAULT 'CASH',
      nominal INTEGER NOT NULL,
      waktu TEXT NOT NULL,
      operator TEXT,
      catatan TEXT,
      cash_sync_id TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jenis IN ('DP', 'PELUNASAN')),
      CHECK (metode IN ('CASH', 'TRANSFER')),
      CHECK (nominal > 0),
      FOREIGN KEY (purchase_id) REFERENCES supplier_purchases(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_supplier_payments_purchase '
    'ON supplier_payments(purchase_id, waktu)',
  );

  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_purchase_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      purchase_id INTEGER NOT NULL,
      purchase_sync_id TEXT NOT NULL DEFAULT '',
      no_retur TEXT NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      total INTEGER NOT NULL DEFAULT 0,
      total_modal_kembali INTEGER NOT NULL DEFAULT 0,
      total_kas_kembali INTEGER NOT NULL DEFAULT 0,
      alasan TEXT NOT NULL,
      dibuat_oleh TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('AKTIF', 'VOID')),
      CHECK (total >= 0),
      CHECK (total_modal_kembali >= 0),
      CHECK (total_kas_kembali >= 0),
      FOREIGN KEY (purchase_id) REFERENCES supplier_purchases(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_purchase_return_no '
    'ON supplier_purchase_returns(store_id, no_retur) '
    'WHERE deleted_at IS NULL',
  );

  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_purchase_return_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      return_id INTEGER NOT NULL,
      purchase_item_id INTEGER NOT NULL,
      purchase_item_sync_id TEXT NOT NULL DEFAULT '',
      nama_snapshot TEXT NOT NULL DEFAULT '',
      jumlah_milli INTEGER NOT NULL,
      harga_satuan INTEGER NOT NULL DEFAULT 0,
      subtotal INTEGER NOT NULL DEFAULT 0,
      modal_satuan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jumlah_milli > 0),
      CHECK (harga_satuan >= 0),
      CHECK (subtotal >= 0),
      CHECK (modal_satuan >= 0),
      FOREIGN KEY (return_id) REFERENCES supplier_purchase_returns(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_purchase_return_line '
    'ON supplier_purchase_return_items(return_id, purchase_item_sync_id)',
  );
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS trg_purchase_return_batas
    BEFORE INSERT ON supplier_purchase_return_items
    FOR EACH ROW
    BEGIN
      SELECT RAISE(ABORT, 'qty retur pembelian melebihi qty dibeli')
      WHERE NEW.jumlah_milli + COALESCE((
        SELECT SUM(ri.jumlah_milli)
        FROM supplier_purchase_return_items ri
        JOIN supplier_purchase_returns rr ON rr.id = ri.return_id
        WHERE rr.deleted_at IS NULL AND rr.status = 'AKTIF'
          AND ri.deleted_at IS NULL
          AND ri.purchase_item_id = NEW.purchase_item_id
      ), 0) > COALESCE((
        SELECT jumlah_milli FROM supplier_purchase_items
        WHERE id = NEW.purchase_item_id
      ), 0);
    END
  ''');

  // Saldo HPP rata-rata bergerak per toko/barang (BD-15).
  await db.execute('''
    CREATE TABLE IF NOT EXISTS stock_cost_state (
      store_id TEXT NOT NULL DEFAULT '',
      stock_sync_id TEXT NOT NULL,
      qty_milli INTEGER NOT NULL DEFAULT 0,
      hpp_rata_milli INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (store_id, stock_sync_id)
    )
  ''');

  // ---------------------------------------------------------------------------
  // Saldo awal toko (BD-22)
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE IF NOT EXISTS opening_balances (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      origin_device_id TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'AKTIF',
      posted_at TEXT NOT NULL,
      posted_by TEXT,
      catatan TEXT,
      void_reason TEXT,
      voided_at TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('AKTIF', 'VOID'))
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_opening_aktif '
    'ON opening_balances(store_id) '
    "WHERE status = 'AKTIF' AND deleted_at IS NULL",
  );

  await db.execute('''
    CREATE TABLE IF NOT EXISTS opening_balance_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      opening_id INTEGER NOT NULL,
      jenis TEXT NOT NULL,
      ref_sync_id TEXT NOT NULL DEFAULT '',
      ref_nama_snapshot TEXT NOT NULL DEFAULT '',
      jumlah_milli INTEGER NOT NULL DEFAULT 0,
      nominal INTEGER NOT NULL DEFAULT 0,
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (jenis IN ('STOK', 'UTANG_SUPPLIER', 'PIUTANG_PELANGGAN')),
      CHECK (jumlah_milli >= 0),
      CHECK (nominal >= 0),
      CHECK (
        (jenis = 'STOK' AND jumlah_milli > 0)
        OR (jenis <> 'STOK' AND nominal > 0)
      ),
      FOREIGN KEY (opening_id) REFERENCES opening_balances(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_opening_items '
    'ON opening_balance_items(opening_id, jenis)',
  );

  // Pengingat jatuh tempo yang sudah ditampilkan (BD-21).
  await db.execute('''
    CREATE TABLE IF NOT EXISTS debt_reminder_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_sync_id TEXT NOT NULL,
      level TEXT NOT NULL,
      due_date TEXT NOT NULL,
      shown_at TEXT NOT NULL,
      UNIQUE (purchase_sync_id, level, due_date)
    )
  ''');
}
