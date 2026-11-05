import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

/// Rekonsiliasi dihitung dari SQLite perangkat sendiri. Relay hanya
/// menyimpan amplop terenkripsi; tidak ada metadata tanggal di relay.
class ReconciliationService {
  ReconciliationService._();

  static final ReconciliationService instance = ReconciliationService._();

  Future<({int jumlah, String hash})> digestFor(
    String tanggal, {
    String dataType = 'nota',
    DatabaseExecutor? executor,
  }) async {
    if (dataType != 'nota') {
      // Jenis lain belum punya definisi ringkasan; jangan mengirim hash
      // palsu yang akan memicu rekonsiliasi salah.
      return (jumlah: 0, hash: '');
    }
    final db = executor ?? AppDatabase.instance.db;
    // `waktu_service` disimpan sebagai UTC; `tanggal` adalah tanggal lokal.
    // Bandingkan dengan rentang UTC dari tengah malam lokal, bukan substr
    // tanggal UTC (yang bergeser beberapa jam di zona waktu non-UTC).
    final start = DateTime.parse('${tanggal}T00:00:00').toUtc();
    final end = start.add(const Duration(days: 1));
    final rows = await db.query(
      'service_records',
      columns: ['sync_id'],
      where: 'waktu_service >= ? AND waktu_service < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'sync_id',
    );
    final ids = rows
        .map((row) => row['sync_id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final hash = sha256.convert(utf8.encode(ids.join('\n'))).toString();
    return (jumlah: ids.length, hash: hash);
  }

  /// Menerbitkan ringkasan untuk hari ini dan hari-hari sebelumnya. Dipanggil
  /// paling banyak sekali per hari agar antrean tidak membengkak.
  Future<int> publishRecent({
    int days = 30,
    DatabaseExecutor? executor,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    final db = executor ?? AppDatabase.instance.db;
    final today = _dateKey(DateTime.now());
    final last = await _setting(db, 'sync.day_digest_last_date');
    final lastAt = DateTime.tryParse(
      await _setting(db, 'sync.day_digest_last_at') ?? '',
    );
    // Pemeriksaan penuh 30 hari cukup tiap 6 jam. Di antara itu, ringkasan
    // hari ini tetap dihitung ulang agar koreksi siang hari ikut terkirim.
    final full =
        last != today ||
        lastAt == null ||
        DateTime.now().difference(lastAt) >= const Duration(hours: 6);
    final source = await _relayDeviceId(db);
    if (source.isEmpty) return 0;
    final store = AppDatabase.instance.activeStoreId ?? 'utama';
    var published = 0;
    final now = nowIso();
    final count = full ? days : 1;
    for (var offset = 0; offset < count; offset++) {
      final tanggal = _dateKey(
        DateTime.now().subtract(Duration(days: offset)),
      );
      final digest = await digestFor(tanggal, executor: db);
      final rows = await db.query(
        'day_digests',
        columns: ['sync_id', 'jumlah', 'hash'],
        where:
            'store_id = ? AND source_device_id = ? AND tanggal = ? '
            'AND data_type = ?',
        whereArgs: [store, source, tanggal, 'nota'],
        limit: 1,
      );
      if (rows.isNotEmpty &&
          (rows.first['jumlah'] as num?)?.toInt() == digest.jumlah &&
          rows.first['hash'] == digest.hash) {
        continue;
      }
      final syncId = rows.isEmpty
          ? newSyncId()
          : rows.first['sync_id'] as String;
      if (rows.isEmpty) {
        await db.insert('day_digests', {
          'sync_id': syncId,
          'store_id': store,
          'device_id': source,
          'source_device_id': source,
          'tanggal': tanggal,
          'data_type': 'nota',
          'jumlah': digest.jumlah,
          'hash': digest.hash,
          'created_at': now,
          'updated_at': now,
        });
      } else {
        await db.update(
          'day_digests',
          {
            'jumlah': digest.jumlah,
            'hash': digest.hash,
            'updated_at': now,
          },
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
      if (enqueue != null) await enqueue(db, syncId);
      published++;
    }
    await _setSetting(db, 'sync.day_digest_last_date', today);
    await _setSetting(db, 'sync.day_digest_last_at', now);
    return published;
  }

  Future<List<Map<String, Object?>>> openRequests() async {
    return AppDatabase.instance.db.query(
      'reconciliation_requests',
      where: "status != 'done' AND deleted_at IS NULL",
      orderBy: 'created_at DESC',
    );
  }

  Future<String> _relayDeviceId(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync.relay_device_id'],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['value'] as String? ?? '';
  }

  Future<String?> _setting(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setSetting(
    DatabaseExecutor db,
    String key,
    String value,
  ) async {
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String _dateKey(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
