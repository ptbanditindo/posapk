import 'dart:convert';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor;

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

/// Satu jalur penulisan audit untuk aksi istimewa (void, retur, penyesuaian
/// stok, katalog, restore, reset, dan grant harga).
///
/// Audit tidak pernah mengubah dokumen bisnis; ia hanya menambah baris
/// append-only yang ikut tersinkron dan tersimpan di arsip.
class AuditService {
  AuditService._();

  static final AuditService instance = AuditService._();

  Future<void> record(
    DatabaseExecutor executor, {
    required String aksi,
    required String entity,
    String entityId = '',
    required String aktor,
    String? aktorEmployeeSyncId,
    String? alasan,
    Map<String, Object?> before = const {},
    Map<String, Object?> after = const {},
  }) async {
    final now = nowIso();
    final storeId = AppDatabase.instance.activeStoreId ?? '';
    var deviceId = '';
    try {
      deviceId = await AppDatabase.instance.deviceCode(executor);
    } catch (_) {
      // Audit tetap ditulis walau kode perangkat belum tersedia.
    }
    await executor.insert('business_audits', {
      'sync_id': newSyncId(),
      'store_id': storeId,
      'device_id': deviceId,
      'waktu': now,
      'aktor': aktor,
      'aktor_employee_sync_id': aktorEmployeeSyncId,
      'aksi': aksi,
      'entity': entity,
      'entity_id': entityId,
      'before_json': jsonEncode(before),
      'after_json': jsonEncode(after),
      'alasan': alasan,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// Audit di luar transaksi bisnis. Dipakai saat transaksi tidak tersedia
  /// atau aksi terjadi di lapisan aplikasi (restore/reset).
  Future<void> recordNow({
    required String aksi,
    required String entity,
    String entityId = '',
    required String aktor,
    String? aktorEmployeeSyncId,
    String? alasan,
    Map<String, Object?> before = const {},
    Map<String, Object?> after = const {},
  }) async {
    await AppDatabase.instance.db.transaction(
      (txn) => record(
        txn,
        aksi: aksi,
        entity: entity,
        entityId: entityId,
        aktor: aktor,
        aktorEmployeeSyncId: aktorEmployeeSyncId,
        alasan: alasan,
        before: before,
        after: after,
      ),
    );
  }

  Future<void> recordOperator(
    DatabaseExecutor executor,
    Operator operator, {
    required String aksi,
    required String entity,
    String entityId = '',
    String? alasan,
    Map<String, Object?> before = const {},
    Map<String, Object?> after = const {},
  }) =>
      record(
        executor,
        aksi: aksi,
        entity: entity,
        entityId: entityId,
        aktor: operator.label,
        aktorEmployeeSyncId: operator.employeeSyncId,
        alasan: alasan,
        before: before,
        after: after,
      );
}
