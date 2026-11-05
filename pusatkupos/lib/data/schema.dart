import 'package:sqflite/sqflite.dart';

/// Migrasi aditif untuk database yang dibuat sebelum versi 2.
Future<void> migrateSchemaV2(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(service_records)');
  final hasJatuhTempo = columns.any((row) => row['name'] == 'jatuh_tempo');
  if (!hasJatuhTempo) {
    await db.execute('ALTER TABLE service_records ADD COLUMN jatuh_tempo TEXT');
  }
  await createReturnTables(db);
  await _addColumnIfMissing(
    db,
    'sale_returns',
    'no_retur',
    "TEXT NOT NULL DEFAULT ''",
  );
  await _addColumnIfMissing(
    db,
    'sale_return_items',
    'modal_satuan',
    'INTEGER NOT NULL DEFAULT 0',
  );
}

Future<void> _addColumnIfMissing(
  Database db,
  String table,
  String column,
  String definition,
) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  if (info.isEmpty) return;
  if (info.any((row) => row['name'] == column)) return;
  await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
}

Future<void> createReturnTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sale_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      nota_sync_id TEXT NOT NULL,
      no_nota TEXT NOT NULL,
      no_retur TEXT NOT NULL DEFAULT '',
      total INTEGER NOT NULL DEFAULT 0,
      alasan TEXT NOT NULL,
      dibuat_oleh TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_sale_returns_nota '
    'ON sale_returns(service_record_id)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sale_return_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      return_id INTEGER NOT NULL,
      line_type TEXT NOT NULL,
      line_sync_id TEXT NOT NULL DEFAULT '',
      deskripsi TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      harga_satuan INTEGER NOT NULL DEFAULT 0,
      subtotal INTEGER NOT NULL DEFAULT 0,
      modal_satuan INTEGER NOT NULL DEFAULT 0,
      stock_item_id INTEGER,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (return_id) REFERENCES sale_returns(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_sale_return_items_return '
    'ON sale_return_items(return_id)',
  );
}

/// Skema awal versi 1.
///
/// Sebelum rilis pertama ke pengguna, seluruh riwayat migrasi digabung di sini.
/// Setelah rilis, setiap perubahan wajib berupa migrasi aditif.
Future<void> createCleanSchema(Database db) async {
  // ---------------------------------------------------------------------------
  // Pengaturan dan identitas lokal
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
      activated_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE employee_accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      username TEXT NOT NULL UNIQUE,
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
      last_login_at TEXT,
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
  await db.execute('''
    CREATE TABLE permission_audits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      actor TEXT NOT NULL,
      target_account_id INTEGER,
      action TEXT NOT NULL,
      detail_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE devices (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      nama TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'owner',
      employee_account_id INTEGER,
      public_key TEXT NOT NULL,
      encryption_key TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      last_seen_at TEXT,
      revoked_at TEXT,
      revoked_reason TEXT NOT NULL DEFAULT ''
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
  // Data master tersinkron
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE customers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nama TEXT NOT NULL,
      nomor_hp TEXT NOT NULL,
      alamat TEXT,
      wa_consent INTEGER NOT NULL DEFAULT 1,
      do_not_contact INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute('CREATE INDEX ix_customers_nama ON customers(nama)');

  // Satu tabel kendaraan untuk mobil, motor, dan unit lain.
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

  await db.execute('''
    CREATE TABLE stock_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      kode TEXT NOT NULL UNIQUE,
      nama TEXT NOT NULL,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      harga_jual INTEGER NOT NULL DEFAULT 0,
      jumlah INTEGER NOT NULL DEFAULT 0,
      jumlah_milli INTEGER,
      stok_minimum INTEGER NOT NULL DEFAULT 0,
      satuan TEXT NOT NULL DEFAULT 'pcs',
      desimal INTEGER NOT NULL DEFAULT 0,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute('CREATE INDEX ix_stock_items_nama ON stock_items(nama)');

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
      deleted_at TEXT
    )
  ''');

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
  await db.execute('''
    CREATE TABLE supplier_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      supplier_id INTEGER NOT NULL,
      stock_item_id INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE(supplier_id, stock_item_id),
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
      FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
    )
  ''');
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
      UNIQUE(supplier_id, stock_item_id),
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
      FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE CASCADE
    )
  ''');

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
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');

  // ---------------------------------------------------------------------------
  // Transaksi (append-only) dan baris snapshot harga
  // ---------------------------------------------------------------------------
  await db.execute('''
    CREATE TABLE service_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      unit_id INTEGER,
      customer_id INTEGER,
      no_nota TEXT NOT NULL UNIQUE,
      request_id TEXT UNIQUE,
      jenis_transaksi TEXT NOT NULL DEFAULT 'servis_langsung',
      mode_saat_dibuat_json TEXT NOT NULL DEFAULT '{}',
      work_order_sync_id TEXT,
      estimate_sync_id TEXT,
      total_estimasi_terakhir INTEGER,
      waktu_service TEXT NOT NULL,
      keluhan_awal TEXT NOT NULL,
      catatan_pengerjaan TEXT,
      biaya_jasa INTEGER NOT NULL DEFAULT 0,
      total_part INTEGER NOT NULL DEFAULT 0,
      diskon INTEGER NOT NULL DEFAULT 0,
      total_servis INTEGER NOT NULL DEFAULT 0,
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
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (unit_id) REFERENCES vehicle_or_units(id) ON DELETE SET NULL,
      FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_service_records_waktu ON service_records(waktu_service)',
  );
  await db.execute(
    'CREATE INDEX ix_service_records_jenis ON service_records(jenis_transaksi)',
  );
  await db.execute('''
    CREATE TABLE service_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      harga_jasa_id INTEGER,
      deskripsi TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      harga INTEGER NOT NULL,
      subtotal INTEGER NOT NULL,
      harga_jual_terdaftar INTEGER NOT NULL DEFAULT 0,
      harga_batas_saat_transaksi INTEGER NOT NULL DEFAULT 0,
      harga_final INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      alasan_diskon TEXT,
      disetujui_oleh TEXT,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE service_parts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      stock_item_id INTEGER,
      nama_part TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      harga_satuan INTEGER NOT NULL,
      subtotal INTEGER NOT NULL,
      harga_modal INTEGER NOT NULL DEFAULT 0,
      harga_jual_terdaftar INTEGER NOT NULL DEFAULT 0,
      harga_batas_saat_transaksi INTEGER NOT NULL DEFAULT 0,
      harga_final INTEGER NOT NULL DEFAULT 0,
      diskon_alokasi INTEGER NOT NULL DEFAULT 0,
      alasan_diskon TEXT,
      disetujui_oleh TEXT,
      interval_servis_bulan INTEGER NOT NULL DEFAULT 0,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE service_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      jenis TEXT NOT NULL DEFAULT 'PELUNASAN',
      metode TEXT NOT NULL DEFAULT 'CASH',
      nominal INTEGER NOT NULL,
      waktu TEXT NOT NULL,
      operator TEXT NOT NULL DEFAULT 'Pemilik',
      request_id TEXT UNIQUE,
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE stock_movements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      stock_item_id INTEGER,
      nama_item TEXT,
      jenis TEXT NOT NULL,
      jumlah INTEGER NOT NULL,
      jumlah_milli INTEGER,
      alasan TEXT,
      service_record_id INTEGER,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');

  // Koreksi append-only: baris baru yang merujuk nota asli.
  await db.execute('''
    CREATE TABLE nota_adjustments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      nota_sync_id TEXT NOT NULL,
      nilai_selisih INTEGER NOT NULL,
      nilai_baru INTEGER NOT NULL,
      alasan TEXT NOT NULL,
      dibuat_oleh TEXT,
      disetujui_oleh TEXT,
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

  // Retur append-only. Nota asal tidak diubah; omzet neto dihitung dengan
  // mengurangi baris retur pada rentang tanggal.
  await createReturnTables(db);

  await db.execute('''
    CREATE TABLE service_record_mechanics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      employee_sync_id TEXT NOT NULL,
      urutan INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      UNIQUE(service_record_id, employee_sync_id),
      FOREIGN KEY (service_record_id) REFERENCES service_records(id)
        ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE service_record_commissions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      service_record_id INTEGER NOT NULL,
      employee_sync_id TEXT NOT NULL,
      nominal INTEGER NOT NULL DEFAULT 0,
      nominal_override INTEGER,
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
      nominal INTEGER NOT NULL,
      terbayar INTEGER NOT NULL DEFAULT 0,
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE salary_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      device_id TEXT NOT NULL DEFAULT '',
      employee_sync_id TEXT NOT NULL,
      periode TEXT NOT NULL,
      cycle_start TEXT NOT NULL,
      cycle_end TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      nominal INTEGER NOT NULL,
      potongan_hutang INTEGER NOT NULL DEFAULT 0,
      cicilan_hutang INTEGER NOT NULL DEFAULT 0,
      bonus INTEGER NOT NULL DEFAULT 0,
      metode TEXT NOT NULL DEFAULT 'CASH',
      catatan TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
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
    'CREATE INDEX ix_estimates_nomor ON estimates(nomor_estimasi, versi)',
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
      jumlah INTEGER NOT NULL,
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
      deleted_at TEXT
    )
  ''');

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
      PRIMARY KEY (device_id, doc_type, tanggal)
    )
  ''');

  // ---------------------------------------------------------------------------
  // Rekonsiliasi harian (dihitung dari SQLite, relay hanya jembatan)
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
      status TEXT NOT NULL DEFAULT 'pending',
      retry_count INTEGER NOT NULL DEFAULT 0,
      next_retry_at TEXT,
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
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (envelope_id),
      UNIQUE (idempotency_key)
    )
  ''');
  await db.execute(
    'CREATE INDEX ix_sync_inbox_due ON sync_inbox(status, next_retry_at)',
  );
  await db.execute('''
    CREATE TABLE sync_cursor (
      store_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      last_seq INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (store_id, device_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE applied_deltas (
      idempotency_key TEXT PRIMARY KEY,
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
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL DEFAULT '',
      reason TEXT NOT NULL,
      detail_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'open',
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NOT NULL DEFAULT '',
      inbox_id INTEGER,
      created_at TEXT NOT NULL,
      resolved_at TEXT
    )
  ''');
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
    CREATE TABLE IF NOT EXISTS sync_peer_digests (
      source_device_id TEXT NOT NULL,
      tanggal TEXT NOT NULL,
      data_type TEXT NOT NULL,
      jumlah INTEGER NOT NULL DEFAULT 0,
      hash TEXT NOT NULL DEFAULT '',
      received_at TEXT NOT NULL,
      PRIMARY KEY (source_device_id, tanggal, data_type)
    )
  ''');
}
