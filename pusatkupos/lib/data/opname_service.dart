import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

/// Hasil permintaan opname: diterapkan langsung atau ditahan menunggu
/// perangkat lain menyelesaikan sinkronisasi (BD-03).
class OpnameGateResult {
  const OpnameGateResult({
    required this.held,
    required this.missing,
    this.holdId,
  });

  final bool held;
  final int? holdId;
  final List<String> missing;
}

class OpnameHoldView {
  const OpnameHoldView({
    required this.id,
    required this.namaItem,
    required this.jumlahFisikMilli,
    required this.status,
    required this.createdAt,
    required this.missing,
    required this.warnOffline,
    required this.provisionalDue,
  });

  final int id;
  final String namaItem;
  final int jumlahFisikMilli;
  final String status;
  final DateTime createdAt;
  final List<String> missing;
  final bool warnOffline;
  final bool provisionalDue;

  bool get provisional => status == OpnameService.statusProvisional;
}

/// Gerbang opname menunggu sinkron.
///
/// Opname ditahan selama masih ada perangkat aktif yang belum menyelesaikan
/// sinkronisasi. Setelah 24 jam perangkat yang tertinggal diberi peringatan;
/// setelah 7 hari opname diterapkan sebagai opname sementara dan
/// direkonsiliasi otomatis ketika perangkat tersebut kembali.
class OpnameService {
  OpnameService._();

  static final OpnameService instance = OpnameService._();

  static const statusPending = 'TERTUNDA';
  static const statusProvisional = 'SEMENTARA';
  static const statusApplied = 'DITERAPKAN';
  static const statusCancelled = 'BATAL';

  static const offlineWarning = Duration(hours: 24);
  static const provisionalAfter = Duration(days: 7);

  Future<OpnameGateResult> record({
    required int itemId,
    required String namaItem,
    required int jumlahFisikMilli,
    String? alasan,
    required Operator actor,
    String? requestId,
    Future<void> Function(DatabaseExecutor txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int movementId)?
    enqueueMovement,
  }) async {
    Permissions.require(actor, permissionOpname);
    final db = AppDatabase.instance.db;
    final requestSyncId = (requestId ?? '').trim().isEmpty
        ? newSyncId()
        : requestId!.trim();
    late OpnameGateResult result;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'opname_holds',
        where: 'sync_id = ?',
        whereArgs: [requestSyncId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.first;
        final status = '${row['status']}';
        final open = status == statusPending || status == statusProvisional;
        result = OpnameGateResult(
          held: open,
          holdId: row['id'] as int,
          missing: open
              ? _decodeMissing(row['missing_devices_json'])
              : const [],
        );
        return;
      }
      final missing = await _missingDevices(txn);
      if (missing.isEmpty) {
        await AppDatabase.instance.applyOpnameTx(
          txn,
          itemId: itemId,
          namaItem: namaItem,
          jumlahFisikMilli: jumlahFisikMilli,
          alasan: alasan,
          actor: actor,
          movementSyncId: requestSyncId,
          enqueue: enqueue,
          enqueueMovement: enqueueMovement,
        );
        result = const OpnameGateResult(held: false, missing: []);
        return;
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final basisRows = await txn.query(
        'stock_items',
        columns: ['jumlah_milli'],
        where: 'id = ?',
        whereArgs: [itemId],
        limit: 1,
      );
      final basisMilli = basisRows.isEmpty
          ? 0
          : (basisRows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
      final holdId = await txn.insert('opname_holds', {
        'sync_id': requestSyncId,
        'store_id': AppDatabase.instance.activeStoreId ?? 'utama',
        'device_id': await _localDeviceId(txn),
        'stock_item_id': itemId,
        'stock_sync_id': await _stockSyncId(txn, itemId),
        'nama_item': namaItem,
        'jumlah_fisik_milli': jumlahFisikMilli,
        'basis_milli': basisMilli,
        'alasan': (alasan ?? '').trim().isEmpty
            ? 'Opname stok'
            : alasan!.trim(),
        'status': statusPending,
        'missing_devices_json': jsonEncode(missing),
        'provisional': 0,
        'movement_sync_id': requestSyncId,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      result = OpnameGateResult(
        held: true,
        holdId: holdId,
        missing: missing.map((row) => '${row['nama']}').toList(),
      );
    });
    return result;
  }

  Future<List<OpnameHoldView>> pendingHolds() async {
    final rows = await AppDatabase.instance.db.query(
      'opname_holds',
      where: "status IN (?, ?) AND deleted_at IS NULL",
      whereArgs: [statusPending, statusProvisional],
      orderBy: 'created_at ASC',
    );
    final missing = await _missingDevices(AppDatabase.instance.db);
    final names = missing.map((row) => '${row['nama']}').toList();
    final now = DateTime.now();
    return rows.map((row) {
      final createdAt =
          DateTime.tryParse('${row['created_at'] ?? ''}')?.toLocal() ??
          now;
      final age = now.difference(createdAt);
      return OpnameHoldView(
        id: row['id'] as int,
        namaItem: '${row['nama_item'] ?? ''}',
        jumlahFisikMilli: (row['jumlah_fisik_milli'] as num?)?.toInt() ?? 0,
        status: '${row['status']}',
        createdAt: createdAt,
        missing: names,
        warnOffline: age >= offlineWarning && names.isNotEmpty,
        provisionalDue:
            '${row['status']}' == statusPending &&
            age >= provisionalAfter &&
            names.isNotEmpty,
      );
    }).toList();
  }

  /// Dipanggil saat aplikasi dibuka dan setelah sinkronisasi selesai.
  /// Menyelesaikan opname tertunda yang perangkatnya sudah kembali, dan
  /// menerapkan opname sementara untuk penantian lebih dari 7 hari.
  Future<int> processPending({
    Operator? actor,
    Future<void> Function(DatabaseExecutor txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int movementId)?
    enqueueMovement,
  }) async {
    final db = AppDatabase.instance.db;
    final holds = await db.query(
      'opname_holds',
      where: "status IN (?, ?) AND deleted_at IS NULL",
      whereArgs: [statusPending, statusProvisional],
      orderBy: 'created_at ASC',
    );
    if (holds.isEmpty) return 0;
    var changed = 0;
    for (final hold in holds) {
      try {
        final handled = await db.transaction((txn) async {
          // Status dibaca ulang di dalam transaksi agar dua pemanggilan
          // processPending tidak menerapkan hold yang sama dua kali.
          final fresh = await txn.query(
            'opname_holds',
            where: 'id = ?',
            whereArgs: [hold['id']],
            limit: 1,
          );
          if (fresh.isEmpty || fresh.first['deleted_at'] != null) return false;
          final row = fresh.first;
          final status = '${row['status']}';
          if (status != statusPending && status != statusProvisional) {
            return false;
          }
          final missing = await _missingDevices(txn);
          final createdAt =
              DateTime.tryParse('${row['created_at'] ?? ''}')?.toLocal();
          final age = createdAt == null
              ? const Duration(days: 365)
              : DateTime.now().difference(createdAt);
          final itemId = row['stock_item_id'] as int;
          final namaItem = '${row['nama_item'] ?? ''}';
          final fisik = (row['jumlah_fisik_milli'] as num?)?.toInt() ?? 0;
          final basisMilli = (row['basis_milli'] as num?)?.toInt();
          final movementSyncId = _movementId(row);
          final missingNote = missing.isEmpty
              ? ''
              : ' Perangkat belum sinkron: '
                    '${missing.map((item) => '${item['nama']}').join(', ')}.';
          if (status == statusPending && missing.isEmpty) {
            await AppDatabase.instance.applyOpnameTx(
              txn,
              itemId: itemId,
              namaItem: namaItem,
              jumlahFisikMilli: fisik,
              basisMilli: basisMilli,
              alasan:
                  '${row['alasan'] ?? 'Opname stok'} '
                  '(semua perangkat sudah sinkron)',
              actor: actor,
              movementSyncId: movementSyncId,
              enqueue: enqueue,
              enqueueMovement: enqueueMovement,
            );
            await _finishHold(
              txn,
              row,
              statusApplied,
              provisional: 0,
              movementSyncId: movementSyncId,
            );
            return true;
          }
          if (status == statusPending && age >= provisionalAfter) {
            await AppDatabase.instance.applyOpnameTx(
              txn,
              itemId: itemId,
              namaItem: namaItem,
              jumlahFisikMilli: fisik,
              basisMilli: basisMilli,
              alasan:
                  '${row['alasan'] ?? 'Opname stok'} '
                  '(opname sementara setelah 7 hari).$missingNote',
              sumberEntity: 'opname_sementara',
              actor: actor,
              movementSyncId: movementSyncId,
              enqueue: enqueue,
              enqueueMovement: enqueueMovement,
            );
            await _finishHold(
              txn,
              row,
              statusProvisional,
              provisional: 1,
              missing: missing,
              movementSyncId: movementSyncId,
            );
            return true;
          }
          if (status == statusProvisional && missing.isEmpty) {
            // Opname sementara sudah diterapkan sebagai delta. Data perangkat
            // yang tertinggal kini masuk sebagai movement sendiri; menerapkan
            // ulang delta yang sama akan menghitung selisih dua kali.
            await _finishHold(
              txn,
              row,
              statusApplied,
              provisional: 0,
              movementSyncId: movementSyncId,
            );
            return true;
          }
          return false;
        });
        if (handled) changed++;
      } catch (_) {
        // Hold yang gagal tetap TERTUNDA dan dicoba lagi; hold lain tidak
        // ikut terblokir.
      }
    }
    return changed;
  }

  String _movementId(Map<String, Object?> hold) {
    final stored = '${hold['movement_sync_id'] ?? ''}'.trim();
    if (stored.isNotEmpty) return stored;
    final request = '${hold['sync_id'] ?? ''}'.trim();
    return request.isEmpty ? newSyncId() : request;
  }

  Future<void> _finishHold(
    DatabaseExecutor txn,
    Map<String, Object?> hold,
    String status, {
    required int provisional,
    List<Map<String, Object?>> missing = const [],
    String? movementSyncId,
  }) async {
    await txn.update(
      'opname_holds',
      {
        'status': status,
        'provisional': provisional,
        'missing_devices_json': jsonEncode(missing),
        'movement_sync_id': movementSyncId ?? hold['movement_sync_id'],
        'applied_at': nowIso(),
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [hold['id']],
    );
  }

  List<String> _decodeMissing(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is List) {
        return [
          for (final item in decoded)
            if (item is Map && '${item['nama'] ?? ''}'.isNotEmpty)
              '${item['nama']}',
        ];
      }
    } catch (_) {}
    return const [];
  }

  Future<List<Map<String, Object?>>> _missingDevices(
    DatabaseExecutor db,
  ) async {
    final self = await _localDeviceId(db);
    final rows = await db.query(
      'device_sync_status',
      columns: ['device_id', 'nama', 'state', 'pending'],
      where: self.isEmpty ? null : 'device_id != ?',
      whereArgs: self.isEmpty ? null : [self],
    );
    return rows
        .where((row) => '${row['state']}' == 'pending')
        .map(
          (row) => <String, Object?>{
            'id': row['device_id'],
            'nama': '${row['nama'] ?? 'Perangkat'}',
          },
        )
        .toList();
  }

  Future<String> _localDeviceId(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final values = {
      for (final row in rows) '${row['key']}': '${row['value'] ?? ''}',
    };
    return values['sync.relay_device_id'] ??
        values['device.current_id'] ??
        '';
  }

  Future<String> _stockSyncId(DatabaseExecutor txn, int itemId) async {
    final rows = await txn.query(
      'stock_items',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    return rows.isEmpty ? '' : '${rows.first['sync_id'] ?? ''}';
  }
}
