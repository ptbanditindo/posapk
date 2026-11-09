import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
};

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
  await db.execute('DROP TRIGGER IF EXISTS trg_service_records_komponen_immutable');
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
