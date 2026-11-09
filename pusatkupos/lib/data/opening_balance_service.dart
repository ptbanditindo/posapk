import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/sync_conflict_rules.dart';
import 'app_database.dart';

class OpeningItemInput {
  const OpeningItemInput({
    required this.jenis,
    required this.refId,
    this.jumlahMilli = 0,
    this.nominal = 0,
    this.catatan,
  });

  final String jenis;
  final int refId;
  final int jumlahMilli;
  final int nominal;
  final String? catatan;
}

/// Saldo awal toko (BD-22): stok, utang supplier, dan piutang pelanggan tanpa
/// transaksi palsu. Hanya satu saldo awal aktif per toko.
class OpeningBalanceService {
  OpeningBalanceService._();

  static final OpeningBalanceService instance = OpeningBalanceService._();

  String get _storeId => AppDatabase.instance.activeStoreId ?? 'utama';

  Future<Map<String, Object?>?> active() async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'opening_balances',
      where: "store_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
      whereArgs: [_storeId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final items = await db.query(
      'opening_balance_items',
      where: 'opening_id = ? AND deleted_at IS NULL',
      whereArgs: [rows.first['id']],
      orderBy: 'jenis, id',
    );
    return {...rows.first, 'items': items};
  }

  Future<int> post({
    required List<OpeningItemInput> items,
    required Operator actor,
    String? catatan,
    Future<void> Function(Transaction txn, String syncId)? enqueue,
  }) async {
    if (!actor.isOwner) {
      throw StateError('Saldo awal hanya dapat dicatat oleh pemilik.');
    }
    if (items.isEmpty) {
      throw ArgumentError('Saldo awal harus memiliki minimal satu baris.');
    }
    return AppDatabase.instance.db.transaction((txn) async {
      final existing = await txn.query(
        'opening_balances',
        columns: ['id'],
        where: "store_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
        whereArgs: [_storeId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError('Saldo awal toko ini sudah pernah dicatat.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceRows = await txn.query(
        'app_settings',
        columns: ['key', 'value'],
        where: "key IN ('sync.relay_device_id', 'device.current_id')",
      );
      final deviceId = {
        for (final row in deviceRows) '${row['key']}': '${row['value']}',
      };
      final device = deviceId['sync.relay_device_id'] ??
          deviceId['device.current_id'] ??
          '';
      final openingSyncId = newSyncId();
      final openingId = await txn.insert('opening_balances', {
        'sync_id': openingSyncId,
        'store_id': _storeId,
        'device_id': device,
        'origin_device_id': device,
        'status': 'AKTIF',
        'posted_at': now,
        'posted_by': actor.label,
        'catatan': _clean(catatan),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      var stockCount = 0;
      var debtCount = 0;
      var receivableCount = 0;
      for (final item in items) {
        if (item.jenis == 'STOK') {
          final stockRows = await txn.query(
            'stock_items',
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [item.refId],
            limit: 1,
          );
          if (stockRows.isEmpty) {
            throw StateError('Barang saldo awal tidak ditemukan.');
          }
          if (item.jumlahMilli <= 0) {
            throw ArgumentError('Jumlah stok awal harus lebih dari nol.');
          }
          final stock = stockRows.first;
          final itemSyncId = newSyncId();
          await txn.insert('opening_balance_items', {
            'sync_id': itemSyncId,
            'store_id': _storeId,
            'device_id': device,
            'opening_id': openingId,
            'jenis': 'STOK',
            'ref_sync_id': stock['sync_id'],
            'ref_nama_snapshot': stock['nama'],
            'jumlah_milli': item.jumlahMilli,
            'nominal': 0,
            'catatan': _clean(item.catatan),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': now,
            'updated_at': now,
          });
          await _stockIn(
            txn,
            stock: stock,
            qtyMilli: item.jumlahMilli,
            sumberSyncId: itemSyncId,
            hlcWall: hlc.wall,
            hlcCounter: hlc.counter,
            operator: actor.label,
          );
          stockCount++;
        } else if (item.jenis == 'UTANG_SUPPLIER') {
          final rows = await txn.query(
            'suppliers',
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [item.refId],
            limit: 1,
          );
          if (rows.isEmpty) {
            throw StateError('Supplier saldo awal tidak ditemukan.');
          }
          if (item.nominal <= 0) {
            throw ArgumentError('Nominal utang awal harus lebih dari nol.');
          }
          await txn.insert('opening_balance_items', {
            'sync_id': newSyncId(),
            'store_id': _storeId,
            'device_id': device,
            'opening_id': openingId,
            'jenis': 'UTANG_SUPPLIER',
            'ref_sync_id': rows.first['sync_id'],
            'ref_nama_snapshot': rows.first['nama'],
            'jumlah_milli': 0,
            'nominal': item.nominal,
            'catatan': _clean(item.catatan),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': now,
            'updated_at': now,
          });
          debtCount++;
        } else if (item.jenis == 'PIUTANG_PELANGGAN') {
          final rows = await txn.query(
            'customers',
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [item.refId],
            limit: 1,
          );
          if (rows.isEmpty) {
            throw StateError('Pelanggan saldo awal tidak ditemukan.');
          }
          if (item.nominal <= 0) {
            throw ArgumentError('Nominal piutang awal harus lebih dari nol.');
          }
          await txn.insert('opening_balance_items', {
            'sync_id': newSyncId(),
            'store_id': _storeId,
            'device_id': device,
            'opening_id': openingId,
            'jenis': 'PIUTANG_PELANGGAN',
            'ref_sync_id': rows.first['sync_id'],
            'ref_nama_snapshot': rows.first['nama'],
            'jumlah_milli': 0,
            'nominal': item.nominal,
            'catatan': _clean(item.catatan),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': now,
            'updated_at': now,
          });
          receivableCount++;
        } else {
          throw ArgumentError('Jenis saldo awal tidak valid.');
        }
      }
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'device_id': device,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'saldo_awal',
        'entity': 'opening_balance',
        'entity_id': openingSyncId,
        'before_json': '{}',
        'after_json': '{"stok":$stockCount,"utang":$debtCount,'
            '"piutang":$receivableCount}',
        'alasan': _clean(catatan),
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, openingSyncId);
      return openingId;
    });
  }

  Future<void> voidActive({
    required String reason,
    required Operator actor,
    Future<void> Function(Transaction txn, String syncId)? enqueue,
  }) async {
    if (!actor.isOwner) {
      throw StateError('Saldo awal hanya dapat dikoreksi oleh pemilik.');
    }
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan koreksi saldo awal wajib diisi.');
    }
    await AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'opening_balances',
        where: "store_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
        whereArgs: [_storeId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Tidak ada saldo awal aktif.');
      final opening = rows.first;
      final items = await txn.query(
        'opening_balance_items',
        where: "opening_id = ? AND jenis = 'STOK' AND deleted_at IS NULL",
        whereArgs: [opening['id']],
      );
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      for (final item in items) {
        final stockRows = await txn.query(
          'stock_items',
          where: 'sync_id = ? AND deleted_at IS NULL',
          whereArgs: [item['ref_sync_id']],
          limit: 1,
        );
        if (stockRows.isEmpty) continue;
        final stock = stockRows.first;
        final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
        final available = (stock['jumlah_milli'] as num?)?.toInt() ?? 0;
        if (available < qty) {
          throw StateError(
            'Stok ${item['ref_nama_snapshot']} sudah berubah; '
            'koreksi lewat opname, bukan membatalkan saldo awal.',
          );
        }
        final before = available;
        final after = available - qty;
        await txn.update(
          'stock_items',
          {
            'jumlah': after ~/ 1000,
            'jumlah_milli': after,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [stock['id']],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'store_id': _storeId,
          'stock_item_id': stock['id'],
          'stock_sync_id': stock['sync_id'],
          'nama_item': stock['nama'],
          'jenis': 'KELUAR',
          'jumlah': qty ~/ 1000,
          'jumlah_milli': -qty,
          'stok_sebelum_milli': before,
          'stok_sesudah_milli': after,
          'sumber_entity': 'saldo_awal_void',
          'sumber_sync_id': item['sync_id'],
          'operator': actor.label,
          'alasan': 'Koreksi saldo awal: $cleanReason',
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': now,
          'updated_at': now,
        });
      }
      await txn.update(
        'opening_balances',
        {
          'status': 'VOID',
          'void_reason': cleanReason,
          'voided_at': now,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [opening['id']],
      );
      if (enqueue != null) await enqueue(txn, '${opening['sync_id']}');
    });
  }

  /// Penerapan saldo awal dari perangkat lain. Hanya satu saldo aktif per
  /// toko; data yang lebih lama diabaikan.
  Future<void> applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
    required String action,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final storeId = '${payload['store_id'] ?? _storeId}';
    final existing = await txn.query(
      'opening_balances',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      if (action == 'void' && '${existing.first['status']}' == 'AKTIF') {
        await _applyVoidRemote(
          txn,
          existing.first,
          payload,
          wall: wall,
          counter: counter,
        );
      }
      return;
    }
    if (action == 'void') {
      throw RetryableSyncException(
        'Pembatalan saldo awal menunggu data asal.',
        code: 'saldo_awal_butuh_induk',
      );
    }
    final active = await txn.query(
      'opening_balances',
      columns: ['id'],
      where: "store_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
      whereArgs: [storeId],
      limit: 1,
    );
    if (active.isNotEmpty) {
      await _conflict(
        txn,
        syncId,
        'saldo_awal_ganda',
        {'store_id': storeId, 'opening_aktif_id': active.first['id']},
      );
      return;
    }
    final now = nowIso();
    final openingId = await txn.insert('opening_balances', {
      'sync_id': syncId,
      'store_id': storeId,
      'device_id': '${payload['device_id'] ?? ''}',
      'origin_device_id': '${payload['origin_device_id'] ?? ''}',
      'status': 'AKTIF',
      'posted_at': payload['posted_at'] ?? now,
      'posted_by': payload['posted_by'],
      'catatan': _clean('${payload['catatan'] ?? ''}'),
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': payload['created_at'] ?? now,
      'updated_at': now,
    });
    final items = (payload['items'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    for (final item in items) {
      final jenis = '${item['jenis'] ?? ''}';
      final refSync = '${item['ref_sync_id'] ?? ''}';
      var qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      final nominal = (item['nominal'] as num?)?.toInt() ?? 0;
      if (jenis == 'STOK') {
        final stockRows = await txn.query(
          'stock_items',
          where: 'sync_id = ? AND deleted_at IS NULL',
          whereArgs: [refSync],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          throw RetryableSyncException(
            'Saldo awal menunggu barang ($refSync).',
            code: 'saldo_awal_tanpa_barang',
          );
        }
        if (qty <= 0) qty = 0;
        if (qty == 0) continue;
        final itemSyncId =
            '${item['sync_id'] ?? ''}'.isEmpty
            ? newSyncId()
            : '${item['sync_id']}';
        await txn.insert('opening_balance_items', {
          'sync_id': itemSyncId,
          'store_id': storeId,
          'device_id': '${payload['device_id'] ?? ''}',
          'opening_id': openingId,
          'jenis': 'STOK',
          'ref_sync_id': refSync,
          'ref_nama_snapshot': item['ref_nama_snapshot'],
          'jumlah_milli': qty,
          'nominal': 0,
          'catatan': _clean('${item['catatan'] ?? ''}'),
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'created_at': payload['created_at'] ?? now,
          'updated_at': now,
        });
        await _stockIn(
          txn,
          stock: stockRows.first,
          qtyMilli: qty,
          sumberSyncId: itemSyncId,
          hlcWall: wall,
          hlcCounter: counter,
          operator: '${payload['posted_by'] ?? 'Perangkat lain'}',
        );
      } else if (jenis == 'UTANG_SUPPLIER' || jenis == 'PIUTANG_PELANGGAN') {
        if (nominal <= 0) continue;
        await txn.insert('opening_balance_items', {
          'sync_id': '${item['sync_id'] ?? ''}'.isEmpty
              ? newSyncId()
              : '${item['sync_id']}',
          'store_id': storeId,
          'device_id': '${payload['device_id'] ?? ''}',
          'opening_id': openingId,
          'jenis': jenis,
          'ref_sync_id': refSync,
          'ref_nama_snapshot': item['ref_nama_snapshot'],
          'jumlah_milli': 0,
          'nominal': nominal,
          'catatan': _clean('${item['catatan'] ?? ''}'),
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'created_at': payload['created_at'] ?? now,
          'updated_at': now,
        });
      }
    }
  }

  Future<void> _applyVoidRemote(
    DatabaseExecutor txn,
    Map<String, Object?> opening,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final openingSync = '${opening['sync_id']}';
    final items = await txn.query(
      'opening_balance_items',
      where: "opening_id = ? AND jenis = 'STOK' AND deleted_at IS NULL",
      whereArgs: [opening['id']],
    );
    for (final item in items) {
      final stockRows = await txn.query(
        'stock_items',
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [item['ref_sync_id']],
        limit: 1,
      );
      if (stockRows.isEmpty) continue;
      final stock = stockRows.first;
      final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      final available = (stock['jumlah_milli'] as num?)?.toInt() ?? 0;
      if (available < qty) {
        await _conflict(
          txn,
          openingSync,
          'saldo_awal_stok_berubah',
          {
            'stock_sync_id': stock['sync_id'],
            'dibutuhkan_milli': qty,
            'tersedia_milli': available,
          },
        );
        continue;
      }
      final now = nowIso();
      final after = available - qty;
      await txn.update(
        'stock_items',
        {
          'jumlah': after ~/ 1000,
          'jumlah_milli': after,
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [stock['id']],
      );
      await txn.insert('stock_movements', {
        'sync_id': newSyncId(),
        'store_id': '${opening['store_id'] ?? _storeId}',
        'stock_item_id': stock['id'],
        'stock_sync_id': stock['sync_id'],
        'nama_item': stock['nama'],
        'jenis': 'KELUAR',
        'jumlah': qty ~/ 1000,
        'jumlah_milli': -qty,
        'stok_sebelum_milli': available,
        'stok_sesudah_milli': after,
        'sumber_entity': 'saldo_awal_void',
        'sumber_sync_id': item['sync_id'],
        'operator': '${payload['voided_by'] ?? 'Perangkat lain'}',
        'alasan': 'Koreksi saldo awal: ${payload['void_reason'] ?? ''}',
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'created_at': now,
        'updated_at': now,
      });
    }
    await txn.update(
      'opening_balances',
      {
        'status': 'VOID',
        'void_reason': payload['void_reason'],
        'voided_at': payload['voided_at'] ?? nowIso(),
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [opening['id']],
    );
  }

  Future<void> _conflict(
    DatabaseExecutor txn,
    String entityId,
    String reason,
    Map<String, Object?> detail,
  ) async {
    final existing = await txn.query(
      'sync_conflicts',
      columns: ['id'],
      where: "entity = 'opening_balance' AND entity_id = ? AND reason = ? "
          "AND status IN ('open', 'review')",
      whereArgs: [entityId, reason],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await txn.insert('sync_conflicts', {
      'entity': 'opening_balance',
      'entity_id': entityId,
      'reason': reason,
      'detail_json': jsonEncode(detail),
      'status': 'review',
      'retry_count': 0,
      'last_error': '',
      'created_at': nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<Map<String, int>> summary() async {
    final opening = await active();
    final items = opening?['items'] as List<Map<String, Object?>>? ?? const [];
    var stockQty = 0;
    var debt = 0;
    var receivable = 0;
    for (final item in items) {
      if (item['jenis'] == 'STOK') {
        stockQty += (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      } else if (item['jenis'] == 'UTANG_SUPPLIER') {
        debt += (item['nominal'] as num?)?.toInt() ?? 0;
      } else if (item['jenis'] == 'PIUTANG_PELANGGAN') {
        receivable += (item['nominal'] as num?)?.toInt() ?? 0;
      }
    }
    return {
      'stok_milli': stockQty,
      'utang': debt,
      'piutang': receivable,
      'baris': items.length,
    };
  }

  Future<void> _stockIn(
    DatabaseExecutor txn, {
    required Map<String, Object?> stock,
    required int qtyMilli,
    required String sumberSyncId,
    required int hlcWall,
    required int hlcCounter,
    required String operator,
  }) async {
    final before = (stock['jumlah_milli'] as num?)?.toInt() ?? 0;
    final after = before + qtyMilli;
    final now = nowIso();
    await txn.update(
      'stock_items',
      {
        'jumlah': after ~/ 1000,
        'jumlah_milli': after,
        'sync_hlc_wall': hlcWall,
        'sync_hlc_counter': hlcCounter,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [stock['id']],
    );
    await txn.insert('stock_movements', {
      'sync_id': newSyncId(),
      'store_id': _storeId,
      'stock_item_id': stock['id'],
      'stock_sync_id': stock['sync_id'],
      'nama_item': stock['nama'],
      'jenis': 'MASUK',
      'jumlah': qtyMilli ~/ 1000,
      'jumlah_milli': qtyMilli,
      'stok_sebelum_milli': before,
      'stok_sesudah_milli': after,
      'sumber_entity': 'saldo_awal',
      'sumber_sync_id': sumberSyncId,
      'operator': operator,
      'alasan': 'Saldo awal stok',
      'sync_hlc_wall': hlcWall,
      'sync_hlc_counter': hlcCounter,
      'created_at': now,
      'updated_at': now,
    });
    final costRows = await txn.query(
      'stock_cost_state',
      where: 'store_id = ? AND stock_sync_id = ?',
      whereArgs: [_storeId, stock['sync_id']],
      limit: 1,
    );
    final existingQty =
        costRows.isEmpty ? 0 : (costRows.first['qty_milli'] as num?)?.toInt() ?? 0;
    final modal = (stock['harga_modal'] as num?)?.toInt() ?? 0;
    final newQty = existingQty + qtyMilli;
    final hpp = newQty <= 0 ? 0 : modal;
    if (costRows.isEmpty) {
      await txn.insert('stock_cost_state', {
        'store_id': _storeId,
        'stock_sync_id': stock['sync_id'],
        'qty_milli': newQty,
        'hpp_rata_milli': hpp,
        'updated_at': now,
      });
    } else {
      await txn.update(
        'stock_cost_state',
        {'qty_milli': newQty, 'hpp_rata_milli': hpp, 'updated_at': now},
        where: 'store_id = ? AND stock_sync_id = ?',
        whereArgs: [_storeId, stock['sync_id']],
      );
    }
  }

  static String? _clean(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
