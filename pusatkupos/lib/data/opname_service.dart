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
    Future<void> Function(DatabaseExecutor txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int movementId)?
    enqueueMovement,
  }) async {
    Permissions.require(actor, permissionOpname);
    final db = AppDatabase.instance.db;
    late OpnameGateResult result;
    await db.transaction((txn) async {
      final missing = await _missingDevices(txn);
      if (missing.isEmpty) {
        await AppDatabase.instance.applyOpnameTx(
          txn,
          itemId: itemId,
          namaItem: namaItem,
          jumlahFisikMilli: jumlahFisikMilli,
          alasan: alasan,
          actor: actor,
          enqueue: enqueue,
          enqueueMovement: enqueueMovement,
        );
        result = const OpnameGateResult(held: false, missing: []);
        return;
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final holdId = await txn.insert('opname_holds', {
        'sync_id': newSyncId(),
        'store_id': AppDatabase.instance.activeStoreId ?? 'utama',
        'device_id': await _localDeviceId(txn),
        'stock_item_id': itemId,
        'stock_sync_id': await _stockSyncId(txn, itemId),
        'nama_item': namaItem,
        'jumlah_fisik_milli': jumlahFisikMilli,
        'alasan': (alasan ?? '').trim().isEmpty
            ? 'Opname stok'
            : alasan!.trim(),
        'status': statusPending,
        'missing_devices_json': jsonEncode(missing),
        'provisional': 0,
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
      final missing = await _missingDevices(db);
      final createdAt =
          DateTime.tryParse('${hold['created_at'] ?? ''}')?.toLocal();
      final age = createdAt == null
          ? const Duration(days: 365)
          : DateTime.now().difference(createdAt);
      final status = '${hold['status']}';
      final itemId = hold['stock_item_id'] as int;
      final namaItem = '${hold['nama_item'] ?? ''}';
      final fisik = (hold['jumlah_fisik_milli'] as num?)?.toInt() ?? 0;
      final missingNote = missing.isEmpty
          ? ''
          : ' Perangkat belum sinkron: '
                '${missing.map((row) => '${row['nama']}').join(', ')}.';
      if (status == statusPending && missing.isEmpty) {
        await db.transaction((txn) async {
          await AppDatabase.instance.applyOpnameTx(
            txn,
            itemId: itemId,
            namaItem: namaItem,
            jumlahFisikMilli: fisik,
            alasan:
                '${hold['alasan'] ?? 'Opname stok'} '
                '(semua perangkat sudah sinkron)',
            actor: actor,
            enqueue: enqueue,
            enqueueMovement: enqueueMovement,
          );
          await _finishHold(txn, hold, statusApplied, provisional: 0);
        });
        changed++;
        continue;
      }
      if (status == statusPending && age >= provisionalAfter) {
        await db.transaction((txn) async {
          await AppDatabase.instance.applyOpnameTx(
            txn,
            itemId: itemId,
            namaItem: namaItem,
            jumlahFisikMilli: fisik,
            alasan:
                '${hold['alasan'] ?? 'Opname stok'} '
                '(opname sementara setelah 7 hari).$missingNote',
            sumberEntity: 'opname_sementara',
            actor: actor,
            enqueue: enqueue,
            enqueueMovement: enqueueMovement,
          );
          await _finishHold(
            txn,
            hold,
            statusProvisional,
            provisional: 1,
            missing: missing,
          );
        });
        changed++;
        continue;
      }
      if (status == statusProvisional && missing.isEmpty) {
        await db.transaction((txn) async {
          // Data perangkat yang tertinggal sudah masuk; selisih terhadap
          // hitungan fisik dikoreksi sekali lagi agar saldo kembali sesuai
          // hasil opname.
          await AppDatabase.instance.applyOpnameTx(
            txn,
            itemId: itemId,
            namaItem: namaItem,
            jumlahFisikMilli: fisik,
            alasan:
                '${hold['alasan'] ?? 'Opname stok'} '
                '(rekonsiliasi setelah semua perangkat sinkron)',
            sumberEntity: 'opname_rekonsiliasi',
            actor: actor,
            enqueue: enqueue,
            enqueueMovement: enqueueMovement,
          );
          await _finishHold(txn, hold, statusApplied, provisional: 0);
        });
        changed++;
      }
    }
    return changed;
  }

  Future<void> _finishHold(
    DatabaseExecutor txn,
    Map<String, Object?> hold,
    String status, {
    required int provisional,
    List<Map<String, Object?>> missing = const [],
  }) async {
    await txn.update(
      'opname_holds',
      {
        'status': status,
        'provisional': provisional,
        'missing_devices_json': jsonEncode(missing),
        'applied_at': nowIso(),
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [hold['id']],
    );
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
      'app_settings',
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
