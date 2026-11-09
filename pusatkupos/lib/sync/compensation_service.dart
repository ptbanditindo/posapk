import 'dart:convert';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../data/app_database.dart';
import '../data/sale_return_service.dart';
import 'sync_service.dart';

/// Menjalankan antrean kompensasi D25. Dokumen baru diterbitkan hanya oleh
/// perangkat asal dokumen yang kalah; perangkat lain tidak menyentuh antrean.
class CompensationService {
  CompensationService._();

  static final CompensationService instance = CompensationService._();

  Future<int> processPending({int limit = 20}) async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'sync_compensations',
      where: "status = 'pending'",
      orderBy: 'id',
      limit: limit,
    );
    var processed = 0;
    for (final row in rows) {
      final id = row['id'] as int;
      final returnSync = '${row['return_sync_id'] ?? ''}';
      if (returnSync.isEmpty) {
        await _finish(id, 'done', 'Retur kompensasi kosong.');
        processed++;
        continue;
      }
      final returnRows = await db.query(
        'sale_returns',
        where: 'sync_id = ?',
        whereArgs: [returnSync],
        limit: 1,
      );
      if (returnRows.isEmpty || '${returnRows.first['status']}' != 'AKTIF') {
        // Retur sudah dibatalkan atau tidak ada; tidak ada yang perlu
        // dikompensasi.
        await _finish(id, 'done', '');
        processed++;
        continue;
      }
      final retur = returnRows.first;
      final localDevice = await _localDeviceId();
      if ('${retur['device_id'] ?? ''}' != localDevice) {
        await _finish(
          id,
          'done',
          'Bukan perangkat asal retur; antrean dilewati.',
        );
        processed++;
        continue;
      }
      try {
        await SaleReturnService.instance.reverseReturn(
          returnId: retur['id'] as int,
          alasan: 'Kompensasi otomatis: void menang atas retur.',
          actor: Operator.owner,
          requestId: '${row['request_id']}',
          automatic: true,
          enqueueNote: (txn, recordId) =>
              SyncService.instance.enqueueNote(recordId, txn: txn),
          enqueueCommission: (txn, commissionId) =>
              SyncService.instance.enqueueCommission(commissionId, txn: txn),
        );
        await _finish(id, 'done', '');
        await _noteConflict(
          '${row['nota_sync_id'] ?? ''}',
          kompensasiStatus: 'selesai',
          ownerHelp: false,
        );
        processed++;
      } catch (error) {
        await _finish(id, 'failed', '$error');
        await _noteConflict(
          '${row['nota_sync_id'] ?? ''}',
          kompensasiStatus: 'gagal',
          ownerHelp: true,
          error: '$error',
        );
        processed++;
      }
    }
    return processed;
  }

  Future<String> _localDeviceId() async {
    final rows = await AppDatabase.instance.db.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final values = {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
    return values['sync.relay_device_id'] ?? values['device.current_id'] ?? '';
  }

  Future<void> _finish(int id, String status, String error) async {
    await AppDatabase.instance.db.update(
      'sync_compensations',
      {
        'status': status,
        'last_error': error,
        'retry_count': status == 'failed' ? 1 : 0,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _noteConflict(
    String notaSyncId, {
    required String kompensasiStatus,
    required bool ownerHelp,
    String error = '',
  }) async {
    if (notaSyncId.isEmpty) return;
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'sync_conflicts',
      columns: ['id', 'detail_json'],
      where: "entity = 'nota' AND entity_id = ? AND reason = 'void_menang'",
      whereArgs: [notaSyncId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    Map<String, Object?> detail = {};
    try {
      final decoded = jsonDecode('${rows.first['detail_json'] ?? '{}'}');
      if (decoded is Map) {
        detail = decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    detail['kompensasi_status'] = kompensasiStatus;
    detail['butuh_bantuan_owner'] = ownerHelp;
    if (error.isNotEmpty) detail['kompensasi_error'] = error;
    await db.update(
      'sync_conflicts',
      {
        'detail_json': jsonEncode(detail),
        'last_error': error,
        'status': ownerHelp ? 'open' : 'review',
      },
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
  }
}
