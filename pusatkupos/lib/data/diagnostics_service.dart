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
    final duplicates = await _duplicates(db);
    final stockDifferences = await _stockDifferences(db);
    final cashDifferences = await _cashDifferences(db);
    final negativeStock = await _negativeStock(db);
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
      'integritas': {
        'duplikat': duplicates,
        'stok_selisih': stockDifferences,
        'kas_selisih': cashDifferences,
        'stok_negatif': negativeStock,
      },
      'log_terakhir': _recentLogs(),
    };
  }

  /// Laporan duplikat sebelum unique index (F1-2). Pada skema baru kolom
  /// kuncinya sudah unik; laporan ini menangkap sisa data lama.
  Future<List<Map<String, Object?>>> _duplicates(DatabaseExecutor db) async {
    const queries = <String, String>{
      'service_records.no_nota':
          "SELECT no_nota AS kunci, COUNT(*) AS jumlah, GROUP_CONCAT(id) AS ids "
              'FROM service_records WHERE deleted_at IS NULL '
              "AND no_nota <> '' GROUP BY no_nota HAVING COUNT(*) > 1",
      'service_payments.request_id':
          "SELECT request_id AS kunci, COUNT(*) AS jumlah, "
              'GROUP_CONCAT(id) AS ids FROM service_payments '
              "WHERE request_id <> '' GROUP BY request_id HAVING COUNT(*) > 1",
      'sync_outbox.idempotency_key':
          'SELECT idempotency_key AS kunci, COUNT(*) AS jumlah, '
              'GROUP_CONCAT(id) AS ids FROM sync_outbox '
              'GROUP BY idempotency_key HAVING COUNT(*) > 1',
      'stock_movements.sumber':
          "SELECT store_id || '|' || sumber_entity || '|' || sumber_sync_id "
              "|| '|' || jenis AS kunci, COUNT(*) AS jumlah, "
              'GROUP_CONCAT(id) AS ids FROM stock_movements '
              "WHERE sumber_sync_id <> '' AND deleted_at IS NULL "
              'GROUP BY store_id, sumber_entity, sumber_sync_id, jenis '
              'HAVING COUNT(*) > 1',
      'cash_ledger.sumber':
          "SELECT store_id || '|' || sumber_entity || '|' || sumber_sync_id "
              'AS kunci, COUNT(*) AS jumlah, GROUP_CONCAT(id) AS ids '
              'FROM cash_ledger WHERE sumber_sync_id <> \'\' '
              'AND deleted_at IS NULL '
              'GROUP BY store_id, sumber_entity, sumber_sync_id '
              'HAVING COUNT(*) > 1',
    };
    final report = <Map<String, Object?>>[];
    for (final entry in queries.entries) {
      final rows = await db.rawQuery(entry.value);
      for (final row in rows) {
        report.add({
          'tabel': entry.key,
          'kunci': '${row['kunci'] ?? ''}',
          'jumlah': (row['jumlah'] as num?)?.toInt() ?? 0,
          'ids': '${row['ids'] ?? ''}',
        });
      }
    }
    return report;
  }

  /// Saldo stok harus sama dengan jumlah movement yang terlihat (F1-3).
  Future<List<Map<String, Object?>>> _stockDifferences(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery('''
      SELECT s.id, s.sync_id, s.nama,
             s.jumlah_milli AS saldo,
             COALESCE(SUM(m.jumlah_milli), 0) AS ledger,
             s.jumlah_milli - COALESCE(SUM(m.jumlah_milli), 0) AS selisih
      FROM stock_items s
      LEFT JOIN stock_movements m
        ON m.stock_item_id = s.id AND m.deleted_at IS NULL
      WHERE s.deleted_at IS NULL
      GROUP BY s.id
      HAVING selisih <> 0
      ORDER BY ABS(selisih) DESC
      LIMIT 50
    ''');
    return rows
        .map(
          (row) => {
            'stock_sync_id': row['sync_id'],
            'nama': row['nama'],
            'saldo_milli': row['saldo'],
            'ledger_milli': row['ledger'],
            'selisih_milli': row['selisih'],
          },
        )
        .toList();
  }

  /// Kas pembayaran dan ledger kas harus sama nominalnya (F1-3).
  Future<List<Map<String, Object?>>> _cashDifferences(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery('''
      SELECT p.sync_id, p.jenis, p.nominal AS sumber,
             COALESCE(l.nominal, 0) AS ledger,
             p.nominal - COALESCE(l.nominal, 0) AS selisih
      FROM service_payments p
      LEFT JOIN cash_ledger l
        ON l.sumber_sync_id = p.sync_id
       AND l.sumber_entity = 'service_payment'
       AND l.deleted_at IS NULL
      WHERE p.deleted_at IS NULL
        AND (l.id IS NULL OR l.nominal <> p.nominal)
      ORDER BY ABS(selisih) DESC
      LIMIT 50
    ''');
    return rows
        .map(
          (row) => {
            'payment_sync_id': row['sync_id'],
            'jenis': row['jenis'],
            'sumber': row['sumber'],
            'ledger': row['ledger'],
            'selisih': row['selisih'],
          },
        )
        .toList();
  }

  /// Stok negatif tetap terlihat setelah sync (F1-4), tetapi penjualan lokal
  /// tidak boleh membuatnya.
  Future<List<Map<String, Object?>>> _negativeStock(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery('''
      SELECT sync_id, nama, jumlah_milli
      FROM stock_items
      WHERE deleted_at IS NULL AND jumlah_milli < 0
      ORDER BY jumlah_milli ASC
      LIMIT 50
    ''');
    return rows
        .map(
          (row) => {
            'stock_sync_id': row['sync_id'],
            'nama': row['nama'],
            'jumlah_milli': row['jumlah_milli'],
          },
        )
        .toList();
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
