import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../sync/archive_service.dart';
import '../sync/sync_service.dart';
import 'app_database.dart';
import 'audit_service.dart';
import 'license_service.dart';

class PurgeResult {
  const PurgeResult({
    this.purged = 0,
    this.blockedReason = '',
    this.remaining = 0,
  });

  final int purged;
  final String blockedReason;
  final int remaining;

  bool get blocked => blockedReason.isNotEmpty;

  String get message {
    if (blocked) return 'Purge ditahan: $blockedReason';
    if (purged == 0) return 'Tidak ada dokumen yang memenuhi syarat purge.';
    return '$purged dokumen dipurge. Sisa kandidat: $remaining.';
  }
}

/// Purge bertahap hanya setelah arsip terverifikasi. Flag `purge.enabled`
/// sengaja mati sampai escrow dan uji restore arsip lulus (F8-8). Tanpa
/// receipt arsip yang valid, riwayat lokal dipertahankan.
class PurgeService {
  PurgeService._();

  static final PurgeService instance = PurgeService._();

  static const Duration minimumAge = Duration(days: 365);
  static const Duration snapshotStable = Duration(days: 7);
  static const Duration syncFreshness = Duration(hours: 24);
  static const int batchLimit = 5;

  Future<String> _gate() async {
    final db = AppDatabase.instance;
    if (await db.getSetting('purge.enabled') != '1') {
      return 'purge_enabled belum diaktifkan; tunggu escrow dan uji restore '
          'arsip lulus.';
    }
    if (await db.getSetting('recovery.escrow_verified') != '1') {
      return 'escrow pemulihan belum terverifikasi.';
    }
    if (await db.getSetting('archive.restore_tested') != '1') {
      return 'uji restore arsip belum lulus.';
    }
    if (!await LicenseService.instance.isPremium()) {
      return 'lisensi premium tidak aktif.';
    }
    final now = DateTime.now().toUtc();
    final lastSync =
        DateTime.tryParse(await db.getSetting('sync.last_success_at') ?? '');
    if (lastSync == null ||
        now.difference(lastSync.toUtc()) > syncFreshness) {
      return 'sinkronisasi terakhir lebih dari 24 jam; purge ditunda.';
    }
    final stableSince =
        DateTime.tryParse(await db.getSetting('snapshot.stable_since') ?? '');
    if (stableSince == null ||
        now.difference(stableSince.toUtc()) < snapshotStable) {
      return 'revisi snapshot belum stabil 7 hari.';
    }
    return '';
  }

  Future<PurgeResult> run({int limit = batchLimit}) async {
    final blocked = await _gate();
    if (blocked.isNotEmpty) return PurgeResult(blockedReason: blocked);

    final db = AppDatabase.instance.db;
    final storeId = await SyncService.instance.storeId();
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(minimumAge)
        .toIso8601String();
    final rows = await db.rawQuery(
      '''
SELECT r.* FROM service_records r
WHERE r.deleted_at IS NULL
  AND r.waktu_service <= ?
  AND (r.status = 'VOID' OR r.status_bayar = 'LUNAS')
  AND COALESCE(r.sisa_bayar, 0) = 0
  AND r.synced_at IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM sale_returns sr
    WHERE sr.service_record_id = r.id AND sr.deleted_at IS NULL
      AND sr.status = 'AKTIF')
  AND NOT EXISTS (
    SELECT 1 FROM work_orders wo
    WHERE wo.nota_sync_id = r.sync_id AND wo.deleted_at IS NULL
      AND wo.status NOT IN ('selesai', 'diambil', 'batal'))
  AND NOT EXISTS (
    SELECT 1 FROM sync_conflicts c
    WHERE c.entity_id = r.sync_id AND c.status IN ('open', 'review'))
  AND NOT EXISTS (
    SELECT 1 FROM sync_outbox o
    WHERE o.entity_id = r.sync_id AND o.status IN ('pending', 'sending'))
ORDER BY r.waktu_service, r.id LIMIT ?
''',
      [cutoff, limit],
    );
    var purged = 0;
    var remaining = rows.length;
    for (final row in rows) {
      final syncId = '${row['sync_id'] ?? ''}';
      if (syncId.isEmpty) continue;
      final waktu = DateTime.tryParse('${row['waktu_service'] ?? ''}');
      if (waktu == null) continue;
      final periode =
          dateOnly.format(storeWallTime(waktu)).substring(0, 7);
      final closed = await db.query(
        'period_closings',
        columns: ['sync_id'],
        where: 'store_id = ? AND periode = ? AND status = ? '
            'AND deleted_at IS NULL',
        whereArgs: [storeId, periode, 'FINAL'],
        limit: 1,
      );
      if (closed.isEmpty) continue;
      if (!await ArchiveService.instance.verifyStoredReceipt(
        storeId: storeId,
        docId: syncId,
      )) {
        continue;
      }
      final receipt = await db.query(
        'archive_receipts',
        columns: ['object_id'],
        where: 'store_id = ? AND doc_id = ?',
        whereArgs: [storeId, syncId],
        limit: 1,
      );
      final receiptId =
          receipt.isEmpty ? '' : '${receipt.first['object_id'] ?? ''}';
      await _purgeOne(
        row,
        storeId: storeId,
        receiptId: receiptId,
        periode: periode,
      );
      purged++;
      remaining--;
    }
    return PurgeResult(purged: purged, remaining: remaining < 0 ? 0 : remaining);
  }

  Future<void> _purgeOne(
    Map<String, Object?> row, {
    required String storeId,
    required String receiptId,
    required String periode,
  }) async {
    final db = AppDatabase.instance.db;
    final recordId = (row['id'] as num?)?.toInt() ?? 0;
    final syncId = '${row['sync_id'] ?? ''}';
    final noNota = '${row['no_nota'] ?? ''}';
    final waktu = '${row['waktu_service'] ?? ''}';
    final total = (row['total_efektif'] as num?)?.toInt() ?? 0;
    final status =
        '${row['status']}' == 'VOID' ? 'VOID' : '${row['status_bayar']}';
    final now = nowIso();
    await db.transaction((txn) async {
      final returns = await txn.query(
        'sale_returns',
        columns: ['id'],
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      for (final retur in returns) {
        final returnId = (retur['id'] as num?)?.toInt() ?? 0;
        await txn.delete(
          'sale_return_items',
          where: 'return_id = ?',
          whereArgs: [returnId],
        );
        await txn.delete(
          'sale_return_reversals',
          where: 'return_id = ?',
          whereArgs: [returnId],
        );
      }
      await txn.delete(
        'sale_returns',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      await txn.delete(
        'nota_adjustments',
        where: 'nota_sync_id = ?',
        whereArgs: [syncId],
      );
      await txn.delete(
        'service_record_commissions',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      await txn.delete(
        'service_record_mechanics',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      await txn.delete(
        'service_payments',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      await txn.delete(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      await txn.delete(
        'service_jobs',
        where: 'service_record_id = ?',
        whereArgs: [recordId],
      );
      // Salinan ciphertext lokal boleh dilepas setelah receipt valid; arsip
      // server tetap permanen dan tidak pernah menerima permintaan hapus.
      await txn.delete(
        'archive_documents',
        where: 'store_id = ? AND doc_type = ? AND doc_id = ?',
        whereArgs: [storeId, ArchiveService.docTypeNota, syncId],
      );
      await txn.delete(
        'archive_index_tokens',
        where: 'store_id = ? AND doc_type = ? AND doc_id = ?',
        whereArgs: [storeId, ArchiveService.docTypeNota, syncId],
      );
      await txn.insert(
        'purged_documents',
        {
          'doc_id': syncId,
          'store_id': storeId,
          'no_nota': noNota,
          'tanggal': waktu,
          'total_cents': total,
          'status': status,
          'receipt_id': receiptId,
          'purged_at': now,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      );
      await AuditService.instance.record(
        txn,
        aksi: 'purge_nota',
        entity: 'service_record',
        entityId: syncId,
        aktor: Operator.owner.label,
        alasan: 'Purge setelah arsip terverifikasi',
        before: {
          'no_nota': noNota,
          'tanggal': waktu,
          'total_cents': total,
          'status': status,
        },
        after: {'periode': periode, 'receipt_id': receiptId},
      );
    });
  }
}
