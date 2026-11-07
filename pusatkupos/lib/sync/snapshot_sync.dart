import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../data/app_database.dart';
import 'crypto.dart';
import 'snapshot_platform_stub.dart'
    if (dart.library.io) 'snapshot_platform_io.dart';

const snapshotTables = [
  'employee_accounts',
  'employee_store_access',
  'document_counters',
  'customers',
  'vehicle_or_units',
  'stock_items',
  'harga_jasa',
  'service_records',
  'service_jobs',
  'service_parts',
  'service_payments',
  'sale_returns',
  'sale_return_items',
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
  'employee_store_access',
  'employee_accounts',
  'document_counters',
  'service_payments',
  'sale_return_items',
  'sale_returns',
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
  'permission_audits',
  'devices',
  'login_guards',
  'sync_outbox',
  'sync_inbox',
  'sync_cursor',
  'applied_deltas',
  'sync_conflicts',
  'device_sync_status',
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
      sanitize: const [
        // Akun ikut snapshot untuk komisi/komisi/payroll, tetapi kredensial
        // lokal tidak boleh ikut tersebar.
        'UPDATE employee_accounts SET password_hash = '', '
            'password_salt = '', pin_hash = NULL, pin_salt = NULL',
      ],
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
    final cursorRows = await db.rawQuery(
      'SELECT COALESCE(MAX(last_seq), 0) AS last_seq FROM sync_cursor '
      'WHERE store_id = ?',
      [storeId],
    );
    final localSeq = (cursorRows.first['last_seq'] as num?)?.toInt() ?? 0;
    if (storeSeq < localSeq) {
      return {
        'applied': false,
        'duplicate': false,
        'stale': true,
        'store_seq': storeSeq,
        'local_seq': localSeq,
      };
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
    final localCounters = await db.query('document_counters');
    final localAccounts = await db.query(
      'employee_accounts',
      columns: [
        'id',
        'sync_id',
        'password_hash',
        'password_salt',
        'password_iterations',
        'pin_hash',
        'pin_salt',
        'pin_iterations',
      ],
    );
    final counts = await importSnapshotBytes(
      Uint8List.fromList(raw),
      db,
      tables: snapshotTables,
      deleteOrder: snapshotDeleteOrder,
      afterImport: (txn) async {
        await _preserveLocalCounters(txn, localCounters);
        await _preserveLocalCredentials(txn, localAccounts);
        await _remapAccountReferences(txn, localAccounts);
        // Snapshot adalah titik awal baru: kunci idempotensi lama tidak boleh
        // menahan amplop yang tidak lagi termuat di dalam snapshot.
        await txn.delete('applied_deltas');
        await txn.insert(
          'sync_cursor',
          {
            'store_id': storeId,
            'device_id': deviceId,
            'last_seq': storeSeq,
            'updated_at': nowIso(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.insert(
          'applied_deltas',
          {
            'idempotency_key': marker,
            'store_id': storeId,
            'envelope_id': snapshotId,
            'entity': 'snapshot',
            'entity_id': storeId,
            'applied_at': nowIso(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      },
    );
    return {
      'applied': true,
      'duplicate': false,
      'store_seq': storeSeq,
      'tables': counts,
    };
  }
}

/// Snapshot menimpa seluruh tabel, termasuk counter dokumen milik perangkat
/// ini. Counter lokal dikembalikan ke nilai tertinggi agar nomor dokumen yang
/// sudah terbit tidak dipakai ulang setelah bootstrap.
Future<void> _preserveLocalCounters(
  DatabaseExecutor txn,
  List<Map<String, Object?>> localCounters,
) async {
  for (final row in localCounters) {
    final deviceId = '${row['device_id'] ?? ''}';
    final docType = '${row['doc_type'] ?? ''}';
    final tanggal = '${row['tanggal'] ?? ''}';
    if (deviceId.isEmpty || docType.isEmpty || tanggal.isEmpty) continue;
    final localLast = (row['terakhir'] as num?)?.toInt() ?? 0;
    final existing = await txn.query(
      'document_counters',
      columns: ['terakhir'],
      where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
      whereArgs: [deviceId, docType, tanggal],
      limit: 1,
    );
    final current = existing.isEmpty
        ? 0
        : (existing.first['terakhir'] as num?)?.toInt() ?? 0;
    if (localLast > current) {
      await txn.insert(
        'document_counters',
        {...row, 'terakhir': localLast},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

/// Kredensial akun sengaja dikosongkan di dalam snapshot. Bila perangkat ini
/// masih menyimpan kredensial lokal untuk akun yang sama (password atau PIN),
/// pertahankan agar sesi luring tidak hilang setelah bootstrap.
Future<void> _preserveLocalCredentials(
  DatabaseExecutor txn,
  List<Map<String, Object?>> localAccounts,
) async {
  for (final row in localAccounts) {
    final syncId = '${row['sync_id'] ?? ''}';
    if (syncId.isEmpty) continue;
    final passwordHash = '${row['password_hash'] ?? ''}';
    final pinHash = '${row['pin_hash'] ?? ''}';
    if (passwordHash.isEmpty && pinHash.isEmpty) continue;
    final imported = await txn.query(
      'employee_accounts',
      columns: ['id', 'password_hash'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (imported.isEmpty) continue;
    if ('${imported.first['password_hash'] ?? ''}'.isNotEmpty) continue;
    await txn.update(
      'employee_accounts',
      {
        'password_hash': row['password_hash'],
        'password_salt': row['password_salt'],
        'password_iterations': row['password_iterations'],
        'pin_hash': row['pin_hash'],
        'pin_salt': row['pin_salt'],
        'pin_iterations': row['pin_iterations'],
      },
      where: 'id = ?',
      whereArgs: [imported.first['id']],
    );
  }
}

/// `employee_accounts.id` adalah autoincrement lokal yang ikut tersalin dari
/// perangkat sumber. Tabel lokal yang menyimpan referensi integer ke akun
/// (`devices.employee_account_id`, `permission_audits.target_account_id`)
/// dipetakan ulang lewat `sync_id` agar tidak menunjuk akun yang salah
/// setelah snapshot diterapkan.
Future<void> _remapAccountReferences(
  DatabaseExecutor txn,
  List<Map<String, Object?>> localAccounts,
) async {
  final syncIdByLocalId = <int, String>{};
  final newIdBySyncId = <String, int>{};
  for (final row in localAccounts) {
    final id = (row['id'] as num?)?.toInt();
    if (id == null) continue;
    final syncId = '${row['sync_id'] ?? ''}'.trim();
    syncIdByLocalId[id] = syncId;
    if (syncId.isEmpty) continue;
    final imported = await txn.query(
      'employee_accounts',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (imported.isEmpty) continue;
    final newId = (imported.first['id'] as num?)?.toInt();
    if (newId != null) newIdBySyncId[syncId] = newId;
  }
  Future<int?> targetFor(int ref, String preferredSyncId) async {
    final syncId = preferredSyncId.isNotEmpty
        ? preferredSyncId
        : syncIdByLocalId[ref] ?? '';
    if (syncId.isEmpty) return null;
    final cached = newIdBySyncId[syncId];
    if (cached != null) return cached;
    final imported = await txn.query(
      'employee_accounts',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    return imported.isEmpty ? null : (imported.first['id'] as num?)?.toInt();
  }

  final devices = await txn.query(
    'devices',
    columns: ['id', 'employee_account_id', 'employee_sync_id'],
  );
  for (final device in devices) {
    final ref = (device['employee_account_id'] as num?)?.toInt();
    if (ref == null) continue;
    final target = await targetFor(ref, '${device['employee_sync_id'] ?? ''}');
    if (target == ref) continue;
    await txn.update(
      'devices',
      {'employee_account_id': target},
      where: 'id = ?',
      whereArgs: [device['id']],
    );
  }

  final audits = await txn.query(
    'permission_audits',
    columns: ['id', 'target_account_id'],
  );
  for (final audit in audits) {
    final ref = (audit['target_account_id'] as num?)?.toInt();
    if (ref == null) continue;
    final target = await targetFor(ref, '');
    if (target == ref) continue;
    await txn.update(
      'permission_audits',
      {'target_account_id': target},
      where: 'id = ?',
      whereArgs: [audit['id']],
    );
  }
}
