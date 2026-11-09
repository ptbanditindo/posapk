import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/dates.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart'
    as platform;

/// Diagnostik perangkat (BD-25). Tidak memuat kredensial, token, passphrase,
/// atau data pribadi lengkap; pesan galat diredaksi sebelum diekspor.
class DiagnosticsService {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();

  static final RegExp _secretPattern = RegExp(
    r'(token|passphrase|password|secret|pin|kunci)\s*[:=]\s*\S+',
    caseSensitive: false,
  );
  static final RegExp _longTokenPattern = RegExp(r'\b[A-Za-z0-9+/=_-]{32,}\b');

  Future<Map<String, Object?>> collect() async {
    final db = AppDatabase.instance.db;
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final dbPath = AppDatabase.instance.databasePath;
    final sizes = {
      'database': await platform.fileSize(dbPath),
      'wal': await platform.fileSize('$dbPath-wal'),
      'shm': await platform.fileSize('$dbPath-shm'),
    };
    final outbox = await _statusCounts(db, 'sync_outbox');
    final inbox = await _statusCounts(db, 'sync_inbox');
    final conflicts = await db.rawQuery(
      'SELECT reason, status, COUNT(*) AS jumlah FROM sync_conflicts '
      "WHERE status IN ('open', 'review') GROUP BY reason, status",
    );
    final settings = await db.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.last_success_at', 'sync.last_error', "
          "'sync.last_attempt_at', 'device.kode_lokal')",
    );
    final settingMap = {
      for (final row in settings) '${row['key']}': '${row['value']}',
    };
    final recentAudits = await db.query(
      'business_audits',
      columns: ['waktu', 'aktor', 'aksi', 'entity', 'entity_id', 'alasan'],
      where: 'deleted_at IS NULL',
      orderBy: 'waktu DESC',
      limit: 30,
    );
    final outboxErrors = await db.query(
      'sync_outbox',
      columns: ['entity', 'action', 'status', 'retry_count', 'error'],
      where: "error <> ''",
      orderBy: 'id DESC',
      limit: 20,
    );
    final inboxErrors = await db.query(
      'sync_inbox',
      columns: [
        'entity',
        'status',
        'retry_count',
        'blocked_reason',
        'last_error',
      ],
      where: "last_error <> '' OR blocked = 1",
      orderBy: 'id DESC',
      limit: 20,
    );
    var backupBytes = 0;
    var backupFiles = 0;
    try {
      final folder = await platform.autoBackupFolder();
      for (final path in await platform.listBackupFiles(folder)) {
        backupBytes += await platform.fileSize(path);
        backupFiles++;
      }
    } catch (_) {
      // Backup otomatis tidak tersedia di platform ini.
    }
    return {
      'dibuat_pada': nowIso(),
      'versi_aplikasi': appVersion,
      'platform': defaultTargetPlatform.name,
      'versi': 'skema v${AppDatabase.schemaVersion}',
      'integrity_check':
          integrity.map((row) => '${row.values.first}').join('; '),
      'ukuran': sizes,
      'backup': {'jumlah_berkas': backupFiles, 'ukuran': backupBytes},
      'outbox': outbox,
      'inbox': inbox,
      'konflik': conflicts,
      'sinkronisasi': {
        for (final entry in settingMap.entries)
          entry.key: _redact(entry.value),
      },
      'audit_terakhir': recentAudits
          .map(
            (row) => {
              'waktu': row['waktu'],
              'aktor': row['aktor'],
              'aksi': row['aksi'],
              'entity': row['entity'],
              'alasan': _redact('${row['alasan'] ?? ''}'),
            },
          )
          .toList(),
      'outbox_galat': outboxErrors
          .map(
            (row) => {
              'entity': row['entity'],
              'action': row['action'],
              'status': row['status'],
              'retry': row['retry_count'],
              'error': _redact('${row['error'] ?? ''}'),
            },
          )
          .toList(),
      'inbox_galat': inboxErrors
          .map(
            (row) => {
              'entity': row['entity'],
              'status': row['status'],
              'retry': row['retry_count'],
              'blocked': _redact('${row['blocked_reason'] ?? ''}'),
              'error': _redact('${row['last_error'] ?? ''}'),
            },
          )
          .toList(),
      'log_terakhir': _recentLogs(),
    };
  }

  /// Log terakhir sudah diredaksi oleh [AppLog]; tetap dibatasi agar ekspor
  /// diagnostik tidak membengkak.
  static List<Map<String, Object?>> _recentLogs() {
    final entries = AppLog.instance.entries;
    final start = entries.length > 50 ? entries.length - 50 : 0;
    return [
      for (final entry in entries.sublist(start)) entry.toJson(),
    ];
  }

  Future<String> exportText() async => const JsonEncoder.withIndent(
        '  ',
      ).convert(await collect());

  /// Menyimpan hasil diagnostik ke folder aplikasi. Berkas ini dapat
  /// dilampirkan manual tanpa membuka akses ke database.
  Future<String> exportToFile() async {
    final folder = await platform.autoBackupFolder();
    final target = p.join(
      p.dirname(folder),
      'diagnostics',
    );
    return platform.writeBackupFile(
      target,
      'diagnostik-${DateTime.now().millisecondsSinceEpoch}.json',
      utf8.encode(await exportText()),
    );
  }

  Future<Map<String, int>> _statusCounts(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS jumlah FROM $table GROUP BY status',
    );
    return {
      for (final row in rows) '${row['status']}': (row['jumlah'] as num).toInt(),
    };
  }

  static String _redact(String value) {
    return value
        .replaceAllMapped(_secretPattern, (match) => '${match[1]}=***')
        .replaceAll(_longTokenPattern, '***');
  }
}
