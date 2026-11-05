import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../data/app_database.dart';
import 'crypto.dart';
import 'snapshot_platform_stub.dart'
    if (dart.library.io) 'snapshot_platform_io.dart';

const snapshotTables = [
  'customers',
  'vehicle_or_units',
  'stock_items',
  'harga_jasa',
  'service_records',
  'service_jobs',
  'service_parts',
  'service_payments',
  'service_record_mechanics',
  'service_record_commissions',
  'employee_debts',
  'salary_payments',
  'stock_movements',
  'nota_adjustments',
  'store_settings',
  'estimates',
  'estimate_items',
  'work_orders',
  'work_order_status_log',
  'day_digests',
  'reconciliation_requests',
  'followup_items',
  'followup_events',
  'wa_message_logs',
  'suppliers',
  'supplier_items',
  'supplier_followups',
];

const snapshotDeleteOrder = [
  'service_payments',
  'service_jobs',
  'service_parts',
  'service_record_mechanics',
  'service_record_commissions',
  'employee_debts',
  'salary_payments',
  'stock_movements',
  'estimate_items',
  'estimates',
  'work_order_status_log',
  'work_orders',
  'nota_adjustments',
  'reconciliation_requests',
  'day_digests',
  'store_settings',
  'followup_events',
  'wa_message_logs',
  'followup_items',
  'supplier_followups',
  'supplier_items',
  'suppliers',
  'service_records',
  'vehicle_or_units',
  'customers',
  'stock_items',
  'harga_jasa',
];

const snapshotLocalTables = [
  'owner_identity',
  'license',
  'employee_accounts',
  'permission_audits',
  'devices',
  'login_guards',
  'sync_outbox',
  'sync_inbox',
  'sync_cursor',
  'applied_deltas',
  'sync_conflicts',
  'device_sync_status',
  'document_counters',
];

const snapshotLocalSettingsWhere =
    "key = 'app.created_at' OR key = 'app.role' "
    "OR key LIKE 'employee.%' OR key LIKE 'sync.%' OR key LIKE 'device.%' "
    "OR key LIKE 'auth.%' OR key LIKE 'license.%' OR key LIKE 'backup.%' "
    "OR key LIKE 'telegram.%' OR key LIKE 'secure.%'";

extension SnapshotDatabase on AppDatabase {
  Future<Map<String, Object?>> createSnapshotPayload({
    required String storeId,
    required String deviceId,
    required String devicePrivateKey,
    required List<int> storeKey,
    required int storeSeq,
  }) async {
    final raw = await exportSnapshotBytes(
      db,
      dropTables: snapshotLocalTables,
      settingsWhere: snapshotLocalSettingsWhere,
    );
    final checksum = sha256Hex(raw);
    final (ciphertext, nonce) = await encryptPayload(storeKey, raw);
    final wall = DateTime.now().millisecondsSinceEpoch;
    final canonical = canonicalJson({
      'store_id': storeId,
      'device_id': deviceId,
      'checksum': checksum,
      'store_seq': storeSeq,
      'hlc_wall': wall,
      'hlc_counter': 0,
    });
    final signature = await signPayload(
      devicePrivateKey,
      utf8.encode(canonical),
    );
    return {
      'store_id': storeId,
      'device_id': deviceId,
      'store_seq': storeSeq,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'signature': signature,
      'checksum': checksum,
      'hlc_wall': wall,
      'hlc_counter': 0,
    };
  }

  Future<Map<String, Object?>> applySnapshotPayload(
    Map<String, Object?> snapshot, {
    required String senderPublicKey,
    required List<int> storeKey,
    required String storeId,
    required String deviceId,
  }) async {
    final nested = snapshot['snapshot'];
    final data = nested is Map
        ? Map<String, Object?>.from(nested)
        : Map<String, Object?>.from(snapshot);
    final ciphertext = data['ciphertext'] as String? ?? '';
    final nonce = data['nonce'] as String? ?? '';
    final checksum = data['checksum'] as String? ?? '';
    final signature = data['signature'] as String? ?? '';
    final storeSeq = (data['store_seq'] as num?)?.toInt() ?? 0;
    final hlcWall = (data['hlc_wall'] as num?)?.toInt() ?? 0;
    final hlcCounter = (data['hlc_counter'] as num?)?.toInt() ?? 0;
    final snapshotDevice = data['device_id'] as String? ?? '';
    final snapshotStore = data['store_id'] as String? ?? '';
    final snapshotId = data['id'] as String? ?? 'snapshot-$storeSeq';
    if (ciphertext.isEmpty || nonce.isEmpty || signature.isEmpty) {
      throw StateError('Snapshot tidak lengkap.');
    }
    if (snapshotStore.isNotEmpty && snapshotStore != storeId) {
      throw StateError('Snapshot milik toko lain.');
    }
    final marker = 'snapshot:$snapshotId';
    final existing = await db.query(
      'applied_deltas',
      where: 'idempotency_key = ?',
      whereArgs: [marker],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return {'applied': false, 'duplicate': true, 'store_seq': storeSeq};
    }
    final pending = await db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_outbox WHERE status = 'pending'",
    );
    if (((pending.first['total'] as int?) ?? 0) > 0) {
      throw StateError(
        'Kirim perubahan lokal ke relay sebelum menerapkan snapshot.',
      );
    }
    final inbox = await db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_inbox "
      "WHERE status IN ('pending', 'failed')",
    );
    if (((inbox.first['total'] as int?) ?? 0) > 0) {
      throw StateError(
        'Selesaikan perubahan masuk yang tertunda sebelum menerapkan '
        'snapshot.',
      );
    }
    final canonical = canonicalJson({
      'store_id': storeId,
      'device_id': snapshotDevice,
      'checksum': checksum,
      'store_seq': storeSeq,
      'hlc_wall': hlcWall,
      'hlc_counter': hlcCounter,
    });
    final valid = await verifyPayload(
      senderPublicKey,
      utf8.encode(canonical),
      signature,
    );
    if (!valid) throw StateError('Tanda tangan snapshot tidak valid.');
    final raw = await decryptPayload(storeKey, ciphertext, nonce);
    if (sha256Hex(raw) != checksum) {
      throw StateError('Checksum snapshot tidak cocok.');
    }
    final counts = await importSnapshotBytes(
      Uint8List.fromList(raw),
      db,
      tables: snapshotTables,
      deleteOrder: snapshotDeleteOrder,
    );
    await db.insert(
      'sync_cursor',
      {
        'store_id': storeId,
        'device_id': deviceId,
        'last_seq': storeSeq,
        'updated_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'applied_deltas',
      {
        'idempotency_key': marker,
        'envelope_id': snapshotId,
        'entity': 'snapshot',
        'entity_id': storeId,
        'applied_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return {
      'applied': true,
      'duplicate': false,
      'store_seq': storeSeq,
      'tables': counts,
    };
  }
}
