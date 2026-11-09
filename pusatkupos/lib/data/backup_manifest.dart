/// Metadata dan inventaris isi backup.
///
/// `schema_version` menyatakan versi skema database di dalam arsip,
/// `schema_contract_version` menyatakan kontrak format manifest/restore, dan
/// `app_version` hanya informasi diagnostik. Ketiganya diperiksa sebelum
/// restore agar arsip dari aplikasi yang lebih baru ditolak dengan pesan jelas.
library;

class BackupTableInventory {
  const BackupTableInventory({required this.rows, required this.sha256});

  final int rows;
  final String sha256;

  Map<String, Object?> toJson() => {'rows': rows, 'sha256': sha256};

  static BackupTableInventory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rows = (raw['rows'] as num?)?.toInt();
    final sha = raw['sha256'];
    if (rows == null || sha is! String) return null;
    return BackupTableInventory(rows: rows, sha256: sha);
  }
}

class BackupInventory {
  const BackupInventory({required this.userVersion, required this.tables});

  final int userVersion;
  final Map<String, BackupTableInventory> tables;

  Map<String, Object?> toJson() {
    final names = tables.keys.toList()..sort();
    return {
      'user_version': userVersion,
      'tables': {
        for (final name in names) name: tables[name]!.toJson(),
      },
    };
  }

  static BackupInventory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawTables = raw['tables'];
    if (rawTables is! Map) return null;
    final tables = <String, BackupTableInventory>{};
    for (final entry in rawTables.entries) {
      final value = BackupTableInventory.fromJson(entry.value);
      if (value != null) tables['${entry.key}'] = value;
    }
    return BackupInventory(
      userVersion: (raw['user_version'] as num?)?.toInt() ?? 0,
      tables: tables,
    );
  }
}

Map<String, Object?> buildBackupManifest({
  required int format,
  required int schemaVersion,
  required int contractVersion,
  required String appVersion,
  required String createdAt,
  required String activeStoreId,
  required List<Map<String, Object?>> stores,
  String ownerId = '',
}) {
  return {
    'format': format,
    'app': 'PusatkuPOS',
    'created_at': createdAt,
    // Identitas pemilik dipakai restore lokal untuk menolak backup milik akun
    // lain pada perangkat yang sudah memiliki identitas owner.
    'owner_id': ownerId,
    'schema_version': schemaVersion,
    'schema_contract_version': contractVersion,
    'app_version': appVersion,
    'active_store_id': activeStoreId,
    'stores': stores,
  };
}

/// Pesan penolakan bila manifest berasal dari versi yang belum dikenal,
/// atau `null` bila arsip dapat dipulihkan.
String? validateBackupManifest(
  Map<String, dynamic> manifest, {
  required int schemaVersion,
  required int contractVersion,
}) {
  final backupSchema = (manifest['schema_version'] as num?)?.toInt() ?? 0;
  if (backupSchema > schemaVersion) {
    return 'Backup dibuat oleh aplikasi versi lebih baru (skema v$backupSchema). '
        'Perbarui aplikasi sebelum memulihkan.';
  }
  final backupContract =
      (manifest['schema_contract_version'] as num?)?.toInt() ?? 0;
  if (backupContract > contractVersion) {
    return 'Format backup (kontrak v$backupContract) belum didukung aplikasi '
        'ini (kontrak v$contractVersion). Perbarui aplikasi.';
  }
  return null;
}

/// Membandingkan inventaris yang tercatat di manifest dengan isi arsip yang
/// benar-benar dipulihkan. Perbedaan jumlah baris atau checksum berarti arsip
/// terpotong/berubah dan harus ditolak.
String? compareBackupInventory(
  BackupInventory? expected,
  BackupInventory actual,
) {
  if (expected == null) return null;
  final missing = expected.tables.keys
      .where((name) => !actual.tables.containsKey(name))
      .toList()
    ..sort();
  if (missing.isNotEmpty) {
    return 'Tabel backup tidak ditemukan: ${missing.join(', ')}.';
  }
  final extra = actual.tables.keys
      .where((name) => !expected.tables.containsKey(name))
      .toList()
    ..sort();
  if (extra.isNotEmpty) {
    return 'Arsip memuat tabel tak dikenal: ${extra.join(', ')}.';
  }
  for (final name in expected.tables.keys) {
    final want = expected.tables[name]!;
    final got = actual.tables[name]!;
    if (want.rows != got.rows) {
      return 'Jumlah baris tabel $name tidak cocok '
          '(${got.rows} pada arsip, ${want.rows} pada manifest).';
    }
    if (want.sha256 != got.sha256) {
      return 'Checksum tabel $name tidak cocok.';
    }
  }
  return null;
}
