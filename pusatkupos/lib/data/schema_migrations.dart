import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef SchemaMigration = Future<void> Function(DatabaseExecutor db);

/// Migrasi berversi setelah skema bersih v1.
///
/// Setiap kenaikan `AppDatabase.schemaVersion` wajib menambahkan satu entri di
/// sini. Migrasi harus idempoten dan tidak boleh menghapus data pengguna.
/// Sebelum migrasi dijalankan, `AppDatabase` menyalin berkas database ke
/// `<path>.bak-<waktu>` (lihat `backup_platform.backupExistingDatabase`) agar
/// rollback dapat dilakukan dengan mengembalikan berkas tersebut.
const Map<int, SchemaMigration> schemaMigrations = {};

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
