import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pajak.dart';
import 'schema.dart';

typedef SchemaMigration = Future<void> Function(DatabaseExecutor db);

Future<void> _addColumn(
  DatabaseExecutor db,
  String table,
  String column,
  String definition,
) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  final exists = info.any((row) => row['name'] == column);
  if (!exists) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }
}

/// Migrasi berversi setelah skema bersih v1.
///
/// Setiap kenaikan `AppDatabase.schemaVersion` wajib menambahkan satu entri di
/// sini. Migrasi harus idempoten dan tidak boleh menghapus data pengguna.
/// Sebelum migrasi dijalankan, `AppDatabase` menyalin berkas database ke
/// `<path>.bak-<waktu>` (lihat `backup_platform.backupExistingDatabase`) agar
/// rollback dapat dilakukan dengan mengembalikan berkas tersebut.
const Map<int, SchemaMigration> schemaMigrations = {
  2: _migratePpn,
  3: _migrateCleanV3,
  4: _migrateSalesCoreV4,
  5: _migrateReturnsV5,
  6: _migrateStockLedgerV6,
  7: _migrateOpeningFinanceV7,
  8: _migratePayrollActorV8,
  9: _migrateOpeningStockCostV9,
  10: _migrateCustomerCreditV10,
};

Future<bool> _tableExists(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [table],
  );
  return rows.isNotEmpty;
}

Future<void> _renameTableIfNeeded(
  DatabaseExecutor db,
  String from,
  String to,
) async {
  if (await _tableExists(db, from) && !await _tableExists(db, to)) {
    await db.execute('ALTER TABLE $from RENAME TO $to');
  }
}

/// `ALTER TABLE ... DROP COLUMN` baru tersedia di SQLite 3.35. Bila runtime
/// masih lebih lama, kolom usang dibiarkan: kode tidak lagi menulis/membacanya,
/// sedangkan memaksa rebuild tabel berisiko menghapus data pengguna.
Future<void> _dropColumnIfExists(
  DatabaseExecutor db,
  String table,
  String column,
) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  if (!info.any((row) => row['name'] == column)) return;
  try {
    await db.execute('ALTER TABLE $table DROP COLUMN $column');
  } on DatabaseException {
    // Runtime SQLite lama; abaikan agar database tetap dapat dibuka.
  }
}

/// v2: kolom snapshot PPN pada nota/retur dan konfigurasi PPN per toko.
///
/// Tabel `pajak_pembayaran` dibuat oleh `createOperationalSchema` yang
/// dijalankan sesudah migrasi. Kolom baru memakai nilai netral (PPN nonaktif)
/// sehingga nota lama tetap valid.
Future<void> _migratePpn(DatabaseExecutor db) async {
  await _addColumn(
    db,
    'store_settings',
    'pajak_aktif',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'store_settings',
    'pajak_mode',
    "TEXT NOT NULL DEFAULT 'EKSLUSIF'",
  );
  await _addColumn(
    db,
    'store_settings',
    'pajak_persen_bp',
    'INTEGER NOT NULL DEFAULT 1100',
  );
  await _addColumn(
    db,
    'store_settings',
    'pajak_penanggung',
    "TEXT NOT NULL DEFAULT 'PEMBELI'",
  );
  await _addColumn(
    db,
    'service_records',
    'pajak_dpp',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'service_records',
    'pajak_diserap',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'service_records',
    'pajak_mode',
    "TEXT NOT NULL DEFAULT 'TANPA'",
  );
  await _addColumn(
    db,
    'service_records',
    'pajak_persen_bp',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'service_records',
    'pajak_penanggung',
    "TEXT NOT NULL DEFAULT 'PEMBELI'",
  );
  await _addColumn(db, 'sale_returns', 'dpp', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumn(db, 'sale_returns', 'pajak', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumn(
    db,
    'sale_returns',
    'pajak_diserap',
    'INTEGER NOT NULL DEFAULT 0',
  );

  // Trigger lama hanya menjaga kolom v1; ganti agar kolom PPN ikut beku.
  await db.execute(
    'DROP TRIGGER IF EXISTS trg_service_records_komponen_immutable',
  );
  await db.execute('''
    CREATE TRIGGER trg_service_records_komponen_immutable
    BEFORE UPDATE OF biaya_jasa, total_part, diskon, pajak, pajak_dpp,
      pajak_diserap, pajak_mode, pajak_persen_bp, pajak_penanggung,
      biaya_lain, total_servis, total_estimasi_terakhir,
      mode_saat_dibuat_json, diskon_snapshot_json, pajak_snapshot_json
    ON service_records
    FOR EACH ROW
    WHEN NEW.biaya_jasa IS NOT OLD.biaya_jasa
      OR NEW.total_part IS NOT OLD.total_part
      OR NEW.diskon IS NOT OLD.diskon
      OR NEW.pajak IS NOT OLD.pajak
      OR NEW.pajak_dpp IS NOT OLD.pajak_dpp
      OR NEW.pajak_diserap IS NOT OLD.pajak_diserap
      OR NEW.pajak_mode IS NOT OLD.pajak_mode
      OR NEW.pajak_persen_bp IS NOT OLD.pajak_persen_bp
      OR NEW.pajak_penanggung IS NOT OLD.pajak_penanggung
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

  await db.execute('DROP TRIGGER IF EXISTS trg_sale_returns_immutable');
  await db.execute('''
    CREATE TRIGGER trg_sale_returns_immutable
    BEFORE UPDATE OF service_record_id, nota_sync_id, no_nota, no_retur,
      request_id, status, total, total_modal_kembali, dpp, pajak,
      pajak_diserap, alasan, voided_at
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
      OR NEW.dpp IS NOT OLD.dpp
      OR NEW.pajak IS NOT OLD.pajak
      OR NEW.pajak_diserap IS NOT OLD.pajak_diserap
      OR NEW.alasan IS NOT OLD.alasan
      OR NEW.voided_at IS NOT OLD.voided_at
    BEGIN
      SELECT RAISE(ABORT, 'retur bersifat final');
    END
  ''');
}

/// v3: skema bersih — satu sumber kuantitas, keanggotaan toko, dan fondasi
/// audit/persediaan/payroll.
///
/// Migrasi idempoten dan tidak menghapus transaksi. Kolom `stock_items.jumlah`
/// di-backfill ke `jumlah_milli` sebelum dilepas; `employee_store_access`
/// sudah menjadi sumber keanggotaan sehingga salinan JSON di akun dibuang.
Future<void> _migrateCleanV3(DatabaseExecutor db) async {
  await _renameTableIfNeeded(db, 'app_settings', 'app_meta');
  await _renameTableIfNeeded(db, 'license', 'licenses');

  if (await _tableExists(db, 'stock_items')) {
    final stockColumns = await db.rawQuery('PRAGMA table_info(stock_items)');
    final hasJumlah = stockColumns.any((row) => row['name'] == 'jumlah');
    if (hasJumlah) {
      await db.execute(
        'UPDATE stock_items SET jumlah_milli = jumlah * 1000 '
        'WHERE COALESCE(jumlah_milli, 0) = 0 AND jumlah <> 0',
      );
    }
    await db.execute(
      'UPDATE stock_items SET jumlah_milli = 0 WHERE jumlah_milli IS NULL',
    );
    await _dropColumnIfExists(db, 'stock_items', 'jumlah');
  }

  if (await _tableExists(db, 'employee_accounts')) {
    await _dropColumnIfExists(db, 'employee_accounts', 'store_ids_json');
  }

  await db.execute('DROP TABLE IF EXISTS sync_peer_digests');

  // Tabel fondasi dibuat lewat helper yang sama dengan pembukaan database agar
  // migrasi dan skema baru tidak berbeda.
  await createOperationalSchema(db);

  await _backfillPayrollProfiles(db);
  await _backfillStockBalances(db);
}

Future<void> _backfillPayrollProfiles(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'employee_accounts') ||
      !await _tableExists(db, 'employee_payroll_profiles')) {
    return;
  }
  final columns = await db.rawQuery('PRAGMA table_info(employee_accounts)');
  final names = {for (final row in columns) '${row['name']}'};
  if (!names.contains('jenis_imbalan')) return;
  await db.execute('''
    INSERT OR IGNORE INTO employee_payroll_profiles (
      employee_sync_id, jenis_imbalan, gaji_bulanan_cents, komisi_mode,
      komisi_barang_bp, komisi_jasa_bp, payroll_period, payroll_tanggal,
      payroll_hari, bank_nama, bank_nomor, bank_pemilik, tanggal_masuk,
      updated_at
    )
    SELECT sync_id, jenis_imbalan, gaji_bulanan, komisi_mode,
      komisi_barang_nilai, komisi_jasa_nilai, payroll_period, payroll_tanggal,
      payroll_hari, bank_nama, bank_nomor, bank_pemilik, tanggal_masuk,
      updated_at
    FROM employee_accounts
    WHERE deleted_at IS NULL
  ''');
}

Future<void> _backfillStockBalances(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'stock_items') ||
      !await _tableExists(db, 'stock_balances')) {
    return;
  }
  await db.execute('''
    INSERT OR REPLACE INTO stock_balances (
      store_id, stock_sync_id, qty_milli, value_cents, avg_cost_cents,
      updated_at
    )
    SELECT COALESCE(NULLIF(store_id, ''), 'utama'), sync_id, jumlah_milli,
      (jumlah_milli * harga_modal) / 1000, harga_modal, updated_at
    FROM stock_items
  ''');
}

/// v4: snapshot penjualan/estimasi yang dapat diaudit — PPN per baris,
/// jenis transaksi estimasi, referensi katalog jasa, harga input vs tarif,
/// snapshot pelanggan/unit pada nota, dan hash payload idempotensi.
Future<void> _migrateSalesCoreV4(DatabaseExecutor db) async {
  await _addColumn(
    db,
    'estimates',
    'jenis_transaksi',
    "TEXT NOT NULL DEFAULT 'servis_langsung'",
  );
  await _addColumn(
    db,
    'estimates',
    'diskon_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(db, 'estimates', 'dpp_cents', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumn(db, 'estimates', 'ppn_cents', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumn(
    db,
    'estimates',
    'total_ditagih_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimates',
    'pajak_mode',
    "TEXT NOT NULL DEFAULT 'TANPA'",
  );
  await _addColumn(
    db,
    'estimates',
    'pajak_persen_bp',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimates',
    'pajak_penanggung',
    "TEXT NOT NULL DEFAULT 'PEMBELI'",
  );

  await _addColumn(db, 'estimate_items', 'jasa_sync_id', 'TEXT');
  await _addColumn(
    db,
    'estimate_items',
    'harga_input',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimate_items',
    'harga_bebas',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimate_items',
    'dpp_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimate_items',
    'ppn_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimate_items',
    'total_ditagih_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'estimate_items',
    'pajak_mode',
    "TEXT NOT NULL DEFAULT 'TANPA'",
  );
  await _addColumn(
    db,
    'estimate_items',
    'pajak_penanggung',
    "TEXT NOT NULL DEFAULT 'PEMBELI'",
  );

  await _addColumn(db, 'service_records', 'request_payload_hash', 'TEXT');
  await _addColumn(
    db,
    'service_records',
    'customer_nama',
    "TEXT NOT NULL DEFAULT ''",
  );
  await _addColumn(
    db,
    'service_records',
    'customer_hp',
    "TEXT NOT NULL DEFAULT ''",
  );
  await _addColumn(
    db,
    'service_records',
    'unit_nopol',
    "TEXT NOT NULL DEFAULT ''",
  );
  await _addColumn(
    db,
    'service_jobs',
    'harga_bebas',
    'INTEGER NOT NULL DEFAULT 0',
  );

  await _recreateV4Triggers(db);
  await _backfillEstimatesV4(db);
  await _backfillRecordSnapshotsV4(db);
}

Future<void> _recreateV4Triggers(DatabaseExecutor db) async {
  if (await _tableExists(db, 'service_records')) {
    await db.execute(
      'DROP TRIGGER IF EXISTS trg_service_records_komponen_immutable',
    );
    await db.execute('''
      CREATE TRIGGER trg_service_records_komponen_immutable
      BEFORE UPDATE OF biaya_jasa, total_part, diskon, pajak, pajak_dpp,
        pajak_diserap, pajak_mode, pajak_persen_bp, pajak_penanggung,
        biaya_lain, total_servis, total_estimasi_terakhir,
        mode_saat_dibuat_json, diskon_snapshot_json, pajak_snapshot_json,
        request_payload_hash, customer_nama, customer_hp, unit_nopol
      ON service_records
      FOR EACH ROW
      WHEN NEW.biaya_jasa IS NOT OLD.biaya_jasa
        OR NEW.total_part IS NOT OLD.total_part
        OR NEW.diskon IS NOT OLD.diskon
        OR NEW.pajak IS NOT OLD.pajak
        OR NEW.pajak_dpp IS NOT OLD.pajak_dpp
        OR NEW.pajak_diserap IS NOT OLD.pajak_diserap
        OR NEW.pajak_mode IS NOT OLD.pajak_mode
        OR NEW.pajak_persen_bp IS NOT OLD.pajak_persen_bp
        OR NEW.pajak_penanggung IS NOT OLD.pajak_penanggung
        OR NEW.biaya_lain IS NOT OLD.biaya_lain
        OR NEW.total_servis IS NOT OLD.total_servis
        OR NEW.total_estimasi_terakhir IS NOT OLD.total_estimasi_terakhir
        OR NEW.mode_saat_dibuat_json IS NOT OLD.mode_saat_dibuat_json
        OR NEW.diskon_snapshot_json IS NOT OLD.diskon_snapshot_json
        OR NEW.pajak_snapshot_json IS NOT OLD.pajak_snapshot_json
        OR NEW.request_payload_hash IS NOT OLD.request_payload_hash
        OR NEW.customer_nama IS NOT OLD.customer_nama
        OR NEW.customer_hp IS NOT OLD.customer_hp
        OR NEW.unit_nopol IS NOT OLD.unit_nopol
      BEGIN
        SELECT RAISE(ABORT, 'komponen biaya nota tidak boleh diubah');
      END
    ''');
  }
  if (await _tableExists(db, 'service_jobs')) {
    await db.execute(
      'DROP TRIGGER IF EXISTS trg_service_jobs_snapshot_immutable',
    );
    await db.execute('''
      CREATE TRIGGER trg_service_jobs_snapshot_immutable
      BEFORE UPDATE OF service_record_id, harga_jasa_id, harga_jasa_sync_id,
        deskripsi, jumlah, harga, subtotal, harga_jual_terdaftar,
        harga_bebas, harga_batas_saat_transaksi, harga_final, diskon_alokasi,
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
        OR NEW.harga_bebas IS NOT OLD.harga_bebas
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
  }
}

Map<String, Object?> _decodeObject(Object? raw) {
  if (raw is Map) {
    return {for (final entry in raw.entries) '${entry.key}': entry.value};
  }
  try {
    final decoded = jsonDecode('${raw ?? '{}'}');
    if (decoded is Map) {
      return {for (final entry in decoded.entries) '${entry.key}': entry.value};
    }
  } catch (_) {}
  return {};
}

bool _knownTransactionType(Object? raw) =>
    raw == 'jual_sparepart' ||
    raw == 'servis_langsung' ||
    raw == 'order_kerja' ||
    raw == 'pelunasan_order';

Future<void> _backfillEstimatesV4(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'estimates')) return;
  final estimates = await db.query('estimates', orderBy: 'id');
  for (final row in estimates) {
    final syncId = row['sync_id'] as String? ?? '';
    if (syncId.isEmpty) continue;
    final total = (row['total'] as num?)?.toInt() ?? 0;
    final mode = _decodeObject(row['mode_saat_dibuat_json']);
    final pajak = _decodeObject(mode['pajak_estimasi']);
    final aktif = pajak['aktif'] == true;
    final modePajak = aktif ? '${pajak['mode'] ?? pajakModeEksklusif}' : pajakModeTanpa;
    final penanggung =
        '${pajak['penanggung'] ?? pajakPenanggungPembeli}';
    final persenBp = aktif ? (pajak['persen_bp'] as num?)?.toInt() ?? 0 : 0;
    var dpp = (pajak['dpp'] as num?)?.toInt();
    var ppn = (pajak['pajak'] as num?)?.toInt();
    var ditagih = (pajak['total'] as num?)?.toInt();
    if (dpp == null || ppn == null || ditagih == null) {
      dpp = total;
      ppn = 0;
      ditagih = total;
    }
    if (!aktif && (dpp == 0 && ppn == 0) && total > 0) {
      dpp = total;
      ditagih = total;
    }
    final diskonRows = await db.rawQuery(
      'SELECT COALESCE(SUM(diskon_alokasi), 0) AS diskon '
      'FROM estimate_items WHERE estimate_sync_id = ?',
      [syncId],
    );
    final diskon =
        (diskonRows.first['diskon'] as num?)?.toInt() ?? 0;
    final jenisRaw = '${mode['jenis_transaksi'] ?? ''}';
    final jenis = _knownTransactionType(jenisRaw)
        ? jenisRaw
        : 'servis_langsung';
    await db.update(
      'estimates',
      {
        'jenis_transaksi': jenis,
        'diskon_cents': diskon,
        'dpp_cents': dpp < 0 ? 0 : dpp,
        'ppn_cents': ppn < 0 ? 0 : ppn,
        'total_ditagih_cents': ditagih < 0 ? 0 : ditagih,
        'pajak_mode': modePajak,
        'pajak_persen_bp': persenBp < 0 ? 0 : persenBp,
        'pajak_penanggung': penanggung,
      },
      where: 'sync_id = ?',
      whereArgs: [syncId],
    );

    final items = await db.query(
      'estimate_items',
      where: 'estimate_sync_id = ?',
      whereArgs: [syncId],
      orderBy: 'id',
    );
    if (items.isEmpty) continue;
    final bases = <int>[
      for (final item in items)
        ((item['subtotal'] as num?)?.toInt() ?? 0) < 0
            ? 0
            : (item['subtotal'] as num?)?.toInt() ?? 0,
    ];
    final snapshot = PajakSnapshot(
      active: aktif,
      mode: modePajak,
      persenBp: persenBp,
      penanggung: penanggung,
      dppCents: dpp < 0 ? 0 : dpp,
      pajakCents: ppn < 0 ? 0 : ppn,
      totalCents: ditagih < 0 ? 0 : ditagih,
      diserapCents:
          penanggung == pajakPenanggungBengkel && ppn > 0 ? ppn : 0,
    );
    final shares = PajakSnapshot.alokasiBaris(
      snapshot: snapshot,
      bases: bases,
    );
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final hargaTerdaftar =
          (item['harga_jual_terdaftar'] as num?)?.toInt() ?? 0;
      final share = shares[index];
      await db.update(
        'estimate_items',
        {
          'harga_input': (item['harga_input'] as num?)?.toInt() ?? hargaTerdaftar,
          'harga_bebas': (item['harga_bebas'] as num?)?.toInt() ?? 0,
          'dpp_cents': share.dppCents,
          'ppn_cents': share.pajakCents,
          'total_ditagih_cents': share.totalCents,
          'pajak_mode': modePajak,
          'pajak_penanggung': penanggung,
        },
        where: 'id = ?',
        whereArgs: [item['id']],
      );
    }
  }
}

Future<void> _backfillRecordSnapshotsV4(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'service_records') ||
      !await _tableExists(db, 'customers') ||
      !await _tableExists(db, 'vehicle_or_units')) {
    return;
  }
  await db.execute('''
    UPDATE service_records SET
      customer_nama = COALESCE((
        SELECT c.nama FROM customers c WHERE c.id = COALESCE(
          service_records.customer_id,
          (SELECT u.customer_id FROM vehicle_or_units u
            WHERE u.id = service_records.unit_id)
        )
      ), ''),
      customer_hp = COALESCE((
        SELECT c.nomor_hp FROM customers c WHERE c.id = COALESCE(
          service_records.customer_id,
          (SELECT u.customer_id FROM vehicle_or_units u
            WHERE u.id = service_records.unit_id)
        )
      ), ''),
      unit_nopol = COALESCE((
        SELECT u.nopol FROM vehicle_or_units u
        WHERE u.id = service_records.unit_id
      ), '')
    WHERE COALESCE(customer_nama, '') = ''
      OR COALESCE(customer_hp, '') = ''
      OR COALESCE(unit_nopol, '') = ''
  ''');
}

/// v5: retur dapat direversal. Menambah basis pajak eksplisit per baris retur,
/// metode refund, akumulasi refund pembelian, dan tabel reversal append-only.
Future<void> _migrateReturnsV5(DatabaseExecutor db) async {
  await _addColumn(
    db,
    'sale_returns',
    'dpp_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'sale_returns',
    'ppn_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'sale_returns',
    'total_ditagih_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'sale_returns',
    'metode_refund',
    "TEXT NOT NULL DEFAULT 'CASH'",
  );
  await _addColumn(db, 'sale_returns', 'void_reason', 'TEXT');
  await _addColumn(db, 'sale_returns', 'voided_by', 'TEXT');
  await _addColumn(
    db,
    'sale_return_items',
    'dpp_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'sale_return_items',
    'ppn_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'sale_return_items',
    'total_ditagih_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'supplier_purchases',
    'refund_accumulated_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'supplier_purchase_returns',
    'metode_refund',
    "TEXT NOT NULL DEFAULT 'CASH'",
  );
  await _addColumn(db, 'supplier_purchase_returns', 'void_reason', 'TEXT');
  await _addColumn(db, 'supplier_purchase_returns', 'voided_by', 'TEXT');
  await _addColumn(
    db,
    'supplier_purchase_returns',
    'dpp_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'supplier_purchase_returns',
    'ppn_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'supplier_purchase_returns',
    'total_ditagih_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await _addColumn(
    db,
    'supplier_purchase_return_items',
    'harga_pokok_satuan',
    'INTEGER NOT NULL DEFAULT 0',
  );

  await db.execute('''
    UPDATE sale_returns
    SET dpp_cents = dpp, ppn_cents = pajak, total_ditagih_cents = total
    WHERE dpp_cents = 0 AND ppn_cents = 0 AND total_ditagih_cents = 0
  ''');
  await db.execute('''
    UPDATE sale_return_items
    SET dpp_cents = CASE
          WHEN (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id) > 0
          THEN (SELECT dpp FROM sale_returns r
              WHERE r.id = sale_return_items.return_id) *
            subtotal /
            (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id)
          ELSE 0 END,
      ppn_cents = CASE
          WHEN (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id) > 0
          THEN (SELECT pajak FROM sale_returns r
              WHERE r.id = sale_return_items.return_id) *
            subtotal /
            (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id)
          ELSE 0 END,
      total_ditagih_cents = CASE
          WHEN (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id) > 0
          THEN (SELECT total FROM sale_returns r
              WHERE r.id = sale_return_items.return_id) *
            subtotal /
            (SELECT SUM(subtotal) FROM sale_return_items x
              WHERE x.return_id = sale_return_items.return_id)
          ELSE 0 END
    WHERE dpp_cents = 0 AND ppn_cents = 0 AND total_ditagih_cents = 0
  ''');
  await db.execute('''
    UPDATE supplier_purchases
    SET refund_accumulated_cents = COALESCE((
      SELECT SUM(total_kas_kembali) FROM supplier_purchase_returns r
      WHERE r.purchase_id = supplier_purchases.id
        AND r.status = 'AKTIF' AND r.deleted_at IS NULL
    ), 0)
  ''');
  await db.execute('''
    UPDATE supplier_purchase_return_items
    SET harga_pokok_satuan = modal_satuan
    WHERE harga_pokok_satuan = 0
  ''');
  await db.execute('''
    UPDATE supplier_purchase_returns
    SET metode_refund = COALESCE((
      SELECT p.metode FROM supplier_payments p
      WHERE p.purchase_id = supplier_purchase_returns.purchase_id
        AND p.nominal > 0 AND p.deleted_at IS NULL
      ORDER BY p.waktu DESC LIMIT 1
    ), 'CASH')
  ''');

  await _recreateReturnTriggersV5(db);
  if (await _tableExists(db, 'sale_returns')) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_return_reversals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        store_id TEXT NOT NULL DEFAULT '',
        device_id TEXT NOT NULL DEFAULT '',
        return_id INTEGER NOT NULL,
        return_sync_id TEXT NOT NULL DEFAULT '',
        request_id TEXT NOT NULL UNIQUE,
        total_refund_cents INTEGER NOT NULL DEFAULT 0,
        alasan TEXT NOT NULL,
        dibuat_oleh TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        CHECK (total_refund_cents >= 0),
        FOREIGN KEY (return_id) REFERENCES sale_returns(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_sale_return_reversal '
      'ON sale_return_reversals(return_id) WHERE deleted_at IS NULL',
    );
  }
  if (await _tableExists(db, 'supplier_purchase_returns')) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_return_reversals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        store_id TEXT NOT NULL DEFAULT '',
        device_id TEXT NOT NULL DEFAULT '',
        return_id INTEGER NOT NULL,
        return_sync_id TEXT NOT NULL DEFAULT '',
        request_id TEXT NOT NULL UNIQUE,
        total_kas_cents INTEGER NOT NULL DEFAULT 0,
        alasan TEXT NOT NULL,
        dibuat_oleh TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        CHECK (total_kas_cents >= 0),
        FOREIGN KEY (return_id) REFERENCES supplier_purchase_returns(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_purchase_return_reversal '
      'ON purchase_return_reversals(return_id) WHERE deleted_at IS NULL',
    );
    await db.execute(
      'CREATE TRIGGER IF NOT EXISTS trg_purchase_return_status_transition '
      'BEFORE UPDATE OF status ON supplier_purchase_returns '
      'FOR EACH ROW WHEN NEW.status IS NOT OLD.status '
      "AND NOT (OLD.status = 'AKTIF' AND NEW.status = 'VOID') "
      "BEGIN SELECT RAISE(ABORT, 'status retur pembelian tidak valid'); END",
    );
    await db.execute(
      'CREATE TRIGGER IF NOT EXISTS trg_purchase_return_void_final '
      'BEFORE UPDATE ON supplier_purchase_returns '
      "FOR EACH ROW WHEN OLD.status = 'VOID' AND ("
      "NEW.status IS NOT 'VOID' OR NEW.total IS NOT OLD.total "
      'OR NEW.total_kas_kembali IS NOT OLD.total_kas_kembali '
      'OR NEW.voided_at IS NOT OLD.voided_at) '
      "BEGIN SELECT RAISE(ABORT, 'retur pembelian sudah final'); END",
    );
  }
}

Future<void> _recreateReturnTriggersV5(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'sale_returns')) return;
  await db.execute('DROP TRIGGER IF EXISTS trg_sale_returns_immutable');
  await db.execute('''
    CREATE TRIGGER trg_sale_returns_immutable
    BEFORE UPDATE OF service_record_id, nota_sync_id, no_nota, no_retur,
      request_id, status, total, total_modal_kembali, dpp, pajak,
      pajak_diserap, dpp_cents, ppn_cents, total_ditagih_cents, metode_refund,
      alasan, voided_at, void_reason, voided_by
    ON sale_returns
    FOR EACH ROW
    WHEN NEW.service_record_id IS NOT OLD.service_record_id
      OR NEW.nota_sync_id IS NOT OLD.nota_sync_id
      OR NEW.no_nota IS NOT OLD.no_nota
      OR NEW.no_retur IS NOT OLD.no_retur
      OR NEW.request_id IS NOT OLD.request_id
      OR NEW.total IS NOT OLD.total
      OR NEW.total_modal_kembali IS NOT OLD.total_modal_kembali
      OR NEW.dpp IS NOT OLD.dpp
      OR NEW.pajak IS NOT OLD.pajak
      OR NEW.pajak_diserap IS NOT OLD.pajak_diserap
      OR NEW.dpp_cents IS NOT OLD.dpp_cents
      OR NEW.ppn_cents IS NOT OLD.ppn_cents
      OR NEW.total_ditagih_cents IS NOT OLD.total_ditagih_cents
      OR NEW.metode_refund IS NOT OLD.metode_refund
      OR NEW.alasan IS NOT OLD.alasan
      OR (
        NEW.status IS NOT OLD.status
        AND NOT (OLD.status = 'AKTIF' AND NEW.status = 'VOID')
      )
      OR (
        NEW.voided_at IS NOT OLD.voided_at
        AND NOT (OLD.status = 'AKTIF' AND NEW.status = 'VOID')
      )
      OR (
        NEW.void_reason IS NOT OLD.void_reason
        AND NOT (OLD.status = 'AKTIF' AND NEW.status = 'VOID')
      )
      OR (
        NEW.voided_by IS NOT OLD.voided_by
        AND NOT (OLD.status = 'AKTIF' AND NEW.status = 'VOID')
      )
    BEGIN
      SELECT RAISE(ABORT, 'retur bersifat final');
    END
  ''');
  await db.execute('DROP TRIGGER IF EXISTS trg_sale_return_items_batas');
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
          AND sr.status = 'AKTIF'
          AND ri.line_type = NEW.line_type
          AND ri.line_sync_id = NEW.line_sync_id
      ), 0) > NEW.qty_asal_milli
    BEGIN
      SELECT RAISE(ABORT, 'qty retur melebihi qty terjual');
    END
  ''');
}

/// v6: ledger stok-first — basis opname, biaya per unit pada movement, dan
/// nilai persediaan yang dapat direkonstruksi.
Future<void> _migrateStockLedgerV6(DatabaseExecutor db) async {
  if (await _tableExists(db, 'stock_movements')) {
    await _addColumn(db, 'stock_movements', 'opname_basis_milli', 'INTEGER');
    await _addColumn(
      db,
      'stock_movements',
      'harga_pokok_satuan_cents',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (await _tableExists(db, 'opname_holds')) {
    await _addColumn(db, 'opname_holds', 'basis_milli', 'INTEGER');
  }
  if (await _tableExists(db, 'stock_items') &&
      await _tableExists(db, 'stock_balances')) {
    await db.execute('''
      INSERT OR IGNORE INTO stock_balances (
        store_id, stock_sync_id, qty_milli, value_cents, avg_cost_cents,
        updated_at
      )
      SELECT COALESCE(NULLIF(store_id, ''), 'utama'), sync_id, jumlah_milli,
        (jumlah_milli * harga_modal) / 1000, harga_modal, updated_at
      FROM stock_items
    ''');
  }
}

/// v7: saldo awal utang/piutang menjadi dokumen yang dapat dibayar/ditagih,
/// lengkap dengan riwayat pembayaran dan sinkronisasi per saldo awal.
Future<void> _migrateOpeningFinanceV7(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS opening_payables (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      opening_sync_id TEXT NOT NULL DEFAULT '',
      supplier_sync_id TEXT NOT NULL DEFAULT '',
      supplier_nama_snapshot TEXT NOT NULL DEFAULT '',
      nominal_cents INTEGER NOT NULL,
      terbayar_cents INTEGER NOT NULL DEFAULT 0,
      jatuh_tempo TEXT,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('AKTIF', 'LUNAS', 'VOID')),
      CHECK (nominal_cents > 0),
      CHECK (terbayar_cents >= 0 AND terbayar_cents <= nominal_cents)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_opening_payables '
    'ON opening_payables(store_id, status)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS payable_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      payable_sync_id TEXT NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      nominal_cents INTEGER NOT NULL,
      metode TEXT NOT NULL DEFAULT 'CASH',
      waktu TEXT NOT NULL,
      operator TEXT NOT NULL,
      cash_sync_id TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (nominal_cents > 0),
      CHECK (metode IN ('CASH', 'TRANSFER'))
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_payable_payments '
    'ON payable_payments(payable_sync_id)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS opening_receivables (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      opening_sync_id TEXT NOT NULL DEFAULT '',
      customer_sync_id TEXT NOT NULL DEFAULT '',
      customer_nama_snapshot TEXT NOT NULL DEFAULT '',
      nominal_cents INTEGER NOT NULL,
      terbayar_cents INTEGER NOT NULL DEFAULT 0,
      jatuh_tempo TEXT,
      status TEXT NOT NULL DEFAULT 'AKTIF',
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (status IN ('AKTIF', 'LUNAS', 'VOID')),
      CHECK (nominal_cents > 0),
      CHECK (terbayar_cents >= 0 AND terbayar_cents <= nominal_cents)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_opening_receivables '
    'ON opening_receivables(store_id, status)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS receivable_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_id TEXT NOT NULL UNIQUE,
      store_id TEXT NOT NULL DEFAULT '',
      receivable_sync_id TEXT NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      nominal_cents INTEGER NOT NULL,
      metode TEXT NOT NULL DEFAULT 'CASH',
      waktu TEXT NOT NULL,
      operator TEXT NOT NULL,
      cash_sync_id TEXT,
      sync_hlc_wall INTEGER NOT NULL DEFAULT 0,
      sync_hlc_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      deleted_at TEXT,
      CHECK (nominal_cents > 0),
      CHECK (metode IN ('CASH', 'TRANSFER'))
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_receivable_payments '
    'ON receivable_payments(receivable_sync_id)',
  );

  if (await _tableExists(db, 'opening_balance_items') &&
      await _tableExists(db, 'opening_balances')) {
    await db.execute('''
      INSERT OR IGNORE INTO opening_payables (
        sync_id, store_id, opening_sync_id, supplier_sync_id,
        supplier_nama_snapshot, nominal_cents, terbayar_cents,
        status, created_at, updated_at
      )
      SELECT obi.sync_id, obi.store_id, ob.sync_id, obi.ref_sync_id,
        obi.ref_nama_snapshot, obi.nominal, 0, 'AKTIF',
        obi.created_at, obi.updated_at
      FROM opening_balance_items obi
      JOIN opening_balances ob ON ob.id = obi.opening_id
      WHERE obi.jenis = 'UTANG_SUPPLIER' AND obi.deleted_at IS NULL
        AND ob.deleted_at IS NULL AND ob.status = 'AKTIF'
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO opening_receivables (
        sync_id, store_id, opening_sync_id, customer_sync_id,
        customer_nama_snapshot, nominal_cents, terbayar_cents,
        status, created_at, updated_at
      )
      SELECT obi.sync_id, obi.store_id, ob.sync_id, obi.ref_sync_id,
        obi.ref_nama_snapshot, obi.nominal, 0, 'AKTIF',
        obi.created_at, obi.updated_at
      FROM opening_balance_items obi
      JOIN opening_balances ob ON ob.id = obi.opening_id
      WHERE obi.jenis = 'PIUTANG_PELANGGAN' AND obi.deleted_at IS NULL
        AND ob.deleted_at IS NULL AND ob.status = 'AKTIF'
    ''');
  }
}

/// v8: jejak pembayar gaji dan pemisahan komponen gaji pokok.
///
/// `paid_by` menyimpan aktor yang menjalankan pembayaran; `gaji_pokok`
/// memisahkan komponen gaji tetap dari komisi dan bonus tanpa mengubah total
/// `nominal` pada data lama.
Future<void> _migratePayrollActorV8(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'salary_payments')) return;
  await _addColumn(db, 'salary_payments', 'paid_by', 'TEXT');
  await _addColumn(db, 'salary_payments', 'paid_by_employee_sync_id', 'TEXT');
  await _addColumn(
    db,
    'salary_payments',
    'gaji_pokok',
    'INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute('''
    UPDATE salary_payments
       SET gaji_pokok = MAX(0, nominal - komisi_total - bonus)
     WHERE gaji_pokok = 0 AND nominal > komisi_total + bonus
  ''');
}

/// v9: modal per baris stok saldo awal boleh berbeda dari master.
///
/// Baris lama di-backfill dari `stock_items.harga_modal` saat migrasi; modal
/// yang benar-benar dipakai saat posting tetap tercatat pada movement/ledger.
Future<void> _migrateOpeningStockCostV9(DatabaseExecutor db) async {
  if (!await _tableExists(db, 'opening_balance_items')) return;
  await _addColumn(
    db,
    'opening_balance_items',
    'unit_cost_cents',
    'INTEGER NOT NULL DEFAULT 0',
  );
  if (await _tableExists(db, 'stock_items')) {
    await db.execute('''
      UPDATE opening_balance_items
      SET unit_cost_cents = COALESCE((
        SELECT harga_modal FROM stock_items s
        WHERE s.sync_id = opening_balance_items.ref_sync_id
      ), 0)
      WHERE jenis = 'STOK' AND unit_cost_cents = 0
    ''');
  }
}

/// v10: limit kredit pelanggan dan pencatat persetujuan kredit pada nota.
///
/// Limit `0` berarti tanpa batas agar pelanggan lama tetap dapat bertransaksi
/// seperti sebelumnya. Nota lama tidak perlu diubah.
Future<void> _migrateCustomerCreditV10(DatabaseExecutor db) async {
  if (await _tableExists(db, 'customers')) {
    await _addColumn(
      db,
      'customers',
      'limit_kredit_cents',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (await _tableExists(db, 'service_records')) {
    await _addColumn(db, 'service_records', 'kredit_disetujui_oleh', 'TEXT');
  }
}

Future<void> runSchemaMigrations(
  DatabaseExecutor db, {
  required int from,
  required int to,
}) async {
  for (var version = from + 1; version <= to; version++) {
    final migration = schemaMigrations[version];
    if (migration == null) {
      throw StateError(
        'Migrasi skema v${version - 1} -> v$version belum tersedia. '
        'Turunkan versi aplikasi atau tambahkan migrasi.',
      );
    }
    await migration(db);
  }
}
