import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/sync_conflict_rules.dart';
import 'app_database.dart';
import 'feature_flags.dart';
import 'stock_ledger.dart';

class OpeningItemInput {
  const OpeningItemInput({
    required this.jenis,
    required this.refId,
    this.jumlahMilli = 0,
    this.nominal = 0,
    this.unitCostCents,
    this.catatan,
    this.jatuhTempo,
  });

  final String jenis;
  final int refId;
  final int jumlahMilli;
  final int nominal;

  /// Modal per satuan untuk baris STOK. `null` memakai modal master barang.
  /// Pemilik boleh mencatat modal saldo awal berbeda dari master.
  final int? unitCostCents;
  final String? catatan;

  /// Tanggal jatuh tempo (`yyyy-MM-dd`) untuk utang/piutang awal.
  final String? jatuhTempo;
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
        'app_meta',
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
          final modal = item.unitCostCents ??
              (stock['harga_modal'] as num?)?.toInt() ??
              0;
          if (modal < 0) {
            throw ArgumentError('Modal satuan tidak boleh negatif.');
          }
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
            'unit_cost_cents': modal,
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
            unitCostCents: modal,
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
          final supplier = rows.first;
          final itemSyncId = newSyncId();
          await txn.insert('opening_balance_items', {
            'sync_id': itemSyncId,
            'store_id': _storeId,
            'device_id': device,
            'opening_id': openingId,
            'jenis': 'UTANG_SUPPLIER',
            'ref_sync_id': supplier['sync_id'],
            'ref_nama_snapshot': supplier['nama'],
            'jumlah_milli': 0,
            'nominal': item.nominal,
            'catatan': _clean(item.catatan),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': now,
            'updated_at': now,
          });
          await txn.insert(
            'opening_payables',
            {
              'sync_id': itemSyncId,
              'store_id': _storeId,
              'opening_sync_id': openingSyncId,
              'supplier_sync_id': '${supplier['sync_id']}',
              'supplier_nama_snapshot': '${supplier['nama']}',
              'nominal_cents': item.nominal,
              'terbayar_cents': 0,
              'jatuh_tempo': _clean(item.jatuhTempo),
              'status': 'AKTIF',
              'sync_hlc_wall': hlc.wall,
              'sync_hlc_counter': hlc.counter,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
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
          final customer = rows.first;
          final itemSyncId = newSyncId();
          await txn.insert('opening_balance_items', {
            'sync_id': itemSyncId,
            'store_id': _storeId,
            'device_id': device,
            'opening_id': openingId,
            'jenis': 'PIUTANG_PELANGGAN',
            'ref_sync_id': customer['sync_id'],
            'ref_nama_snapshot': customer['nama'],
            'jumlah_milli': 0,
            'nominal': item.nominal,
            'catatan': _clean(item.catatan),
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': now,
            'updated_at': now,
          });
          await txn.insert(
            'opening_receivables',
            {
              'sync_id': itemSyncId,
              'store_id': _storeId,
              'opening_sync_id': openingSyncId,
              'customer_sync_id': '${customer['sync_id']}',
              'customer_nama_snapshot': '${customer['nama']}',
              'nominal_cents': item.nominal,
              'terbayar_cents': 0,
              'jatuh_tempo': _clean(item.jatuhTempo),
              'status': 'AKTIF',
              'sync_hlc_wall': hlc.wall,
              'sync_hlc_counter': hlc.counter,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
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
      final paidCount = await _paymentCountForOpening(
        txn,
        '${opening['sync_id']}',
      );
      if (paidCount > 0) {
        throw StateError(
          'Saldo awal yang sudah dibayar atau ditagih tidak dapat dikoreksi.',
        );
      }
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
        await StockLedger.instance.apply(
          txn,
          stockItemId: stock['id'] as int,
          stockSyncId: '${stock['sync_id']}',
          jenis: 'KELUAR',
          deltaMilli: -qty,
          sumberEntity: 'saldo_awal_void',
          sumberSyncId: '${item['sync_id']}',
          namaItem: '${stock['nama']}',
          operator: actor.label,
          alasan: 'Koreksi saldo awal: $cleanReason',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
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
      for (final table in ['opening_payables', 'opening_receivables']) {
        await txn.update(
          table,
          {
            'status': 'VOID',
            'updated_at': now,
          },
          where: "opening_sync_id = ? AND status <> 'VOID'",
          whereArgs: ['${opening['sync_id']}'],
        );
      }
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
      final row = existing.first;
      if (action == 'void' && '${row['status']}' == 'AKTIF') {
        final paidCount = await _paymentCountForOpening(txn, syncId);
        if (paidCount > 0) {
          await _conflict(txn, syncId, 'saldo_awal_sudah_dibayar', {
            'pembayaran': paidCount,
          });
          return;
        }
        await _applyVoidRemote(
          txn,
          row,
          payload,
          wall: wall,
          counter: counter,
        );
      } else if (action != 'void') {
        await _applyPaymentList(
          txn,
          payload['payments'],
          storeId: '${row['store_id'] ?? storeId}',
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
        final rawModal = (item['unit_cost_cents'] as num?)?.toInt();
        final modal = rawModal ??
            (stockRows.first['harga_modal'] as num?)?.toInt() ??
            0;
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
          'unit_cost_cents': modal < 0 ? 0 : modal,
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
          unitCostCents: modal < 0 ? 0 : modal,
          sumberSyncId: itemSyncId,
          hlcWall: wall,
          hlcCounter: counter,
          operator: '${payload['posted_by'] ?? 'Perangkat lain'}',
          storeId: storeId,
        );
      } else if (jenis == 'UTANG_SUPPLIER' || jenis == 'PIUTANG_PELANGGAN') {
        if (nominal <= 0) continue;
        final itemSyncId = '${item['sync_id'] ?? ''}'.isEmpty
            ? newSyncId()
            : '${item['sync_id']}';
        await txn.insert(
          'opening_balance_items',
          {
            'sync_id': itemSyncId,
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
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await _insertFinanceRow(
          txn,
          jenis: jenis,
          itemSyncId: itemSyncId,
          openingSyncId: syncId,
          storeId: storeId,
          refSyncId: refSync,
          refNama: '${item['ref_nama_snapshot'] ?? ''}',
          nominal: nominal,
          jatuhTempo: _clean('${item['jatuh_tempo'] ?? ''}'),
          wall: wall,
          counter: counter,
          createdAt: '${payload['created_at'] ?? now}',
          now: now,
        );
      }
    }
    await _applyPaymentList(
      txn,
      payload['payments'],
      storeId: storeId,
      wall: wall,
      counter: counter,
    );
  }

  Future<void> _insertFinanceRow(
    DatabaseExecutor txn, {
    required String jenis,
    required String itemSyncId,
    required String openingSyncId,
    required String storeId,
    required String refSyncId,
    required String refNama,
    required int nominal,
    required String? jatuhTempo,
    required int wall,
    required int counter,
    required String createdAt,
    required String now,
  }) async {
    if (jenis == 'UTANG_SUPPLIER') {
      await txn.insert(
        'opening_payables',
        {
          'sync_id': itemSyncId,
          'store_id': storeId,
          'opening_sync_id': openingSyncId,
          'supplier_sync_id': refSyncId,
          'supplier_nama_snapshot': refNama,
          'nominal_cents': nominal,
          'terbayar_cents': 0,
          'jatuh_tempo': jatuhTempo,
          'status': 'AKTIF',
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'created_at': createdAt,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return;
    }
    if (jenis == 'PIUTANG_PELANGGAN') {
      await txn.insert(
        'opening_receivables',
        {
          'sync_id': itemSyncId,
          'store_id': storeId,
          'opening_sync_id': openingSyncId,
          'customer_sync_id': refSyncId,
          'customer_nama_snapshot': refNama,
          'nominal_cents': nominal,
          'terbayar_cents': 0,
          'jatuh_tempo': jatuhTempo,
          'status': 'AKTIF',
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'created_at': createdAt,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
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
      await StockLedger.instance.apply(
        txn,
        stockItemId: stock['id'] as int,
        stockSyncId: '${stock['sync_id']}',
        jenis: 'KELUAR',
        deltaMilli: -qty,
        sumberEntity: 'saldo_awal_void',
        sumberSyncId: '${item['sync_id']}',
        namaItem: '${stock['nama']}',
        operator: '${payload['voided_by'] ?? 'Perangkat lain'}',
        alasan: 'Koreksi saldo awal: ${payload['void_reason'] ?? ''}',
        storeId: '${opening['store_id'] ?? _storeId}',
        hlcWall: wall,
        hlcCounter: counter,
      );
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

  /// Daftar utang awal yang masih memiliki sisa, urut jatuh tempo.
  Future<List<Map<String, Object?>>> openPayables() async {
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT sync_id, supplier_sync_id, supplier_nama_snapshot,
        nominal_cents, terbayar_cents, jatuh_tempo, status, created_at
      FROM opening_payables
      WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL
        AND nominal_cents > terbayar_cents
      ORDER BY COALESCE(jatuh_tempo, created_at)
      ''',
      [_storeId],
    );
  }

  /// Daftar piutang awal yang masih memiliki sisa, urut jatuh tempo.
  Future<List<Map<String, Object?>>> openReceivables() async {
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT sync_id, customer_sync_id, customer_nama_snapshot,
        nominal_cents, terbayar_cents, jatuh_tempo, status, created_at
      FROM opening_receivables
      WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL
        AND nominal_cents > terbayar_cents
      ORDER BY COALESCE(jatuh_tempo, created_at)
      ''',
      [_storeId],
    );
  }

  Future<Map<String, int>> financeTotals() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT
        (SELECT COALESCE(SUM(nominal_cents - terbayar_cents), 0)
           FROM opening_payables
          WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL)
          AS utang,
        (SELECT COALESCE(SUM(nominal_cents - terbayar_cents), 0)
           FROM opening_receivables
          WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL)
          AS piutang
      ''',
      [_storeId, _storeId],
    );
    return {
      'utang': (rows.first['utang'] as num?)?.toInt() ?? 0,
      'piutang': (rows.first['piutang'] as num?)?.toInt() ?? 0,
    };
  }

  Future<int> payPayable({
    required String payableSyncId,
    required int nominal,
    required String metode,
    required Operator actor,
    String? requestId,
    String? catatan,
    Future<void> Function(Transaction txn, String openingSyncId)? enqueue,
  }) async {
    Permissions.require(actor, permissionPayDebt);
    FeatureFlagsService.instance.requirePurchaseDebt();
    return _payOpeningFinance(
      parentTable: 'opening_payables',
      paymentTable: 'payable_payments',
      parentKey: 'payable_sync_id',
      parentSyncId: payableSyncId,
      nominal: nominal,
      metode: metode,
      actor: actor,
      requestId: requestId,
      catatan: catatan,
      payable: true,
      enqueue: enqueue,
    );
  }

  Future<int> collectReceivable({
    required String receivableSyncId,
    required int nominal,
    required String metode,
    required Operator actor,
    String? requestId,
    String? catatan,
    Future<void> Function(Transaction txn, String openingSyncId)? enqueue,
  }) async {
    if (!actor.canWriteMoney) {
      throw StateError('Peran ini tidak boleh menerima pembayaran.');
    }
    return _payOpeningFinance(
      parentTable: 'opening_receivables',
      paymentTable: 'receivable_payments',
      parentKey: 'receivable_sync_id',
      parentSyncId: receivableSyncId,
      nominal: nominal,
      metode: metode,
      actor: actor,
      requestId: requestId,
      catatan: catatan,
      payable: false,
      enqueue: enqueue,
    );
  }

  Future<int> _payOpeningFinance({
    required String parentTable,
    required String paymentTable,
    required String parentKey,
    required String parentSyncId,
    required int nominal,
    required String metode,
    required Operator actor,
    required bool payable,
    String? requestId,
    String? catatan,
    Future<void> Function(Transaction txn, String openingSyncId)? enqueue,
  }) async {
    if (nominal <= 0) {
      throw ArgumentError('Nominal pembayaran harus lebih dari nol.');
    }
    if (metode != 'CASH' && metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak valid.');
    }
    final request = (requestId ?? '').trim();
    if (request.isNotEmpty) {
      final existing = await AppDatabase.instance.db.query(
        paymentTable,
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [request],
        limit: 1,
      );
      if (existing.isNotEmpty) return existing.first['id'] as int;
    }
    return AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        parentTable,
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [parentSyncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError(
          payable ? 'Utang awal tidak ditemukan.' : 'Piutang awal tidak ditemukan.',
        );
      }
      final parent = rows.first;
      if ('${parent['status']}' == 'VOID') {
        throw StateError('Saldo awal ini sudah dikoreksi.');
      }
      final total = (parent['nominal_cents'] as num?)?.toInt() ?? 0;
      final paidBefore = (parent['terbayar_cents'] as num?)?.toInt() ?? 0;
      final outstanding = total - paidBefore;
      if (outstanding <= 0) {
        throw StateError('Saldo awal ini sudah lunas.');
      }
      if (nominal > outstanding) {
        throw StateError('Nominal melebihi sisa saldo awal.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final paymentSyncId = newSyncId();
      final cashSyncId = metode == 'CASH' ? newSyncId() : null;
      final paymentId = await txn.insert(paymentTable, {
        'sync_id': paymentSyncId,
        'store_id': _storeId,
        parentKey: parentSyncId,
        'request_id': request.isEmpty ? paymentSyncId : request,
        'nominal_cents': nominal,
        'metode': metode,
        'waktu': now,
        'operator': actor.label,
        'cash_sync_id': cashSyncId,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
      });
      final newPaid = paidBefore + nominal;
      await txn.update(
        parentTable,
        {
          'terbayar_cents': newPaid,
          'status': newPaid >= total ? 'LUNAS' : 'AKTIF',
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'sync_id = ?',
        whereArgs: [parentSyncId],
      );
      if (cashSyncId != null) {
        await _writeCash(
          txn,
          cashSyncId: cashSyncId,
          sumberSyncId: paymentSyncId,
          sumberEntity: payable ? 'opening_payable' : 'opening_receivable',
          nominal: payable ? -nominal : nominal,
          metode: metode,
          kategori: payable ? 'BAYAR_UTANG_AWAL' : 'TAGIH_PIUTANG_AWAL',
          waktu: now,
          operator: actor.label,
          catatan: payable
              ? 'Bayar utang awal ${parent['supplier_nama_snapshot'] ?? ''}'
              : 'Tagih piutang awal ${parent['customer_nama_snapshot'] ?? ''}',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'device_id': await _deviceId(txn),
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': payable ? 'bayar_utang_awal' : 'tagih_piutang_awal',
        'entity': payable ? 'opening_payable' : 'opening_receivable',
        'entity_id': parentSyncId,
        'before_json': '{"terbayar":$paidBefore}',
        'after_json': '{"terbayar":$newPaid}',
        'alasan': _clean(catatan),
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) {
        await enqueue(txn, '${parent['opening_sync_id']}');
      }
      return paymentId;
    });
  }

  Future<void> _applyPaymentList(
    DatabaseExecutor txn,
    Object? raw, {
    required String storeId,
    required int wall,
    required int counter,
  }) async {
    for (final entry in (raw as List? ?? const []).whereType<Map>()) {
      final payload = Map<String, Object?>.from(entry);
      final payable = '${payload['jenis'] ?? ''}' != 'PIUTANG';
      if ('${payload['store_id'] ?? ''}'.trim().isEmpty) {
        payload['store_id'] = storeId;
      }
      await _applyPaymentRemote(
        txn,
        payload,
        payable: payable,
        wall: wall,
        counter: counter,
      );
    }
  }

  Future<void> _applyPaymentRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required bool payable,
    required int wall,
    required int counter,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}'.trim();
    if (syncId.isEmpty) return;
    final paymentTable =
        payable ? 'payable_payments' : 'receivable_payments';
    final parentTable = payable ? 'opening_payables' : 'opening_receivables';
    final parentKey = payable ? 'payable_sync_id' : 'receivable_sync_id';
    final existing = await txn.query(
      paymentTable,
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final request = '${payload['request_id'] ?? ''}'.trim();
    if (request.isNotEmpty) {
      final sameRequest = await txn.query(
        paymentTable,
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [request],
        limit: 1,
      );
      if (sameRequest.isNotEmpty) return;
    }
    final parentSyncId = '${payload[parentKey] ?? ''}'.trim();
    final parents = await txn.query(
      parentTable,
      where: 'sync_id = ?',
      whereArgs: [parentSyncId],
      limit: 1,
    );
    if (parents.isEmpty) {
      throw RetryableSyncException(
        'Pembayaran saldo awal menunggu induk ($parentSyncId).',
        code: 'pembayaran_saldo_awal_butuh_induk',
      );
    }
    final parent = parents.first;
    final openingSyncId = '${parent['opening_sync_id'] ?? ''}';
    if ('${parent['status']}' == 'VOID') {
      await _conflict(
        txn,
        openingSyncId,
        'pembayaran_saldo_awal_void',
        {parentKey: parentSyncId},
      );
      return;
    }
    final nominal = (payload['nominal'] as num?)?.toInt() ?? 0;
    if (nominal <= 0) return;
    final total = (parent['nominal_cents'] as num?)?.toInt() ?? 0;
    final paidBefore = (parent['terbayar_cents'] as num?)?.toInt() ?? 0;
    final outstanding = total - paidBefore;
    if (outstanding <= 0) {
      await _conflict(txn, openingSyncId, 'pembayaran_melebihi_sisa', {
        parentKey: parentSyncId,
        'nominal': nominal,
        'sisa': 0,
      });
      return;
    }
    final applied = nominal > outstanding ? outstanding : nominal;
    if (applied < nominal) {
      await _conflict(txn, openingSyncId, 'pembayaran_melebihi_sisa', {
        parentKey: parentSyncId,
        'nominal': nominal,
        'sisa': outstanding,
        'diterapkan': applied,
      });
    }
    final metode =
        '${payload['metode'] ?? 'CASH'}' == 'TRANSFER' ? 'TRANSFER' : 'CASH';
    final providedCash = '${payload['cash_sync_id'] ?? ''}'.trim();
    final cashSyncId = metode == 'CASH'
        ? (providedCash.isEmpty ? newSyncId() : providedCash)
        : null;
    final now = nowIso();
    final waktu = '${payload['waktu'] ?? now}';
    await txn.insert(paymentTable, {
      'sync_id': syncId,
      'store_id': '${payload['store_id'] ?? parent['store_id'] ?? _storeId}',
      parentKey: parentSyncId,
      'request_id': request.isEmpty ? syncId : request,
      'nominal_cents': applied,
      'metode': metode,
      'waktu': waktu,
      'operator': '${payload['operator'] ?? ''}',
      'cash_sync_id': cashSyncId,
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': '${payload['created_at'] ?? now}',
    });
    final newPaid = paidBefore + applied;
    await txn.update(
      parentTable,
      {
        'terbayar_cents': newPaid,
        'status': newPaid >= total ? 'LUNAS' : 'AKTIF',
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'updated_at': now,
      },
      where: 'sync_id = ?',
      whereArgs: [parentSyncId],
    );
    if (cashSyncId != null) {
      await _writeCash(
        txn,
        cashSyncId: cashSyncId,
        sumberSyncId: syncId,
        sumberEntity: payable ? 'opening_payable' : 'opening_receivable',
        nominal: payable ? -applied : applied,
        metode: metode,
        kategori: payable ? 'BAYAR_UTANG_AWAL' : 'TAGIH_PIUTANG_AWAL',
        waktu: waktu,
        operator: '${payload['operator'] ?? ''}',
        catatan: payable
            ? 'Bayar utang awal ${parent['supplier_nama_snapshot'] ?? ''}'
            : 'Tagih piutang awal ${parent['customer_nama_snapshot'] ?? ''}',
        hlcWall: wall,
        hlcCounter: counter,
      );
    }
  }

  Future<int> _paymentCountForOpening(
    DatabaseExecutor txn,
    String openingSyncId,
  ) async {
    final rows = await txn.rawQuery(
      '''
      SELECT
        (SELECT COUNT(*) FROM payable_payments pp
           JOIN opening_payables op ON op.sync_id = pp.payable_sync_id
          WHERE op.opening_sync_id = ? AND pp.deleted_at IS NULL)
        + (SELECT COUNT(*) FROM receivable_payments rp
           JOIN opening_receivables orc ON orc.sync_id = rp.receivable_sync_id
          WHERE orc.opening_sync_id = ? AND rp.deleted_at IS NULL)
          AS total
      ''',
      [openingSyncId, openingSyncId],
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<void> _writeCash(
    DatabaseExecutor txn, {
    required String cashSyncId,
    required String sumberSyncId,
    required String sumberEntity,
    required int nominal,
    required String metode,
    required String kategori,
    required String waktu,
    required String operator,
    required String catatan,
    required int hlcWall,
    required int hlcCounter,
  }) async {
    if (nominal == 0) return;
    final now = nowIso();
    await txn.insert(
      'cash_ledger',
      {
        'sync_id': cashSyncId,
        'store_id': _storeId,
        'device_id': await _deviceId(txn),
        'waktu': waktu,
        'kategori': kategori,
        'sumber_entity': sumberEntity,
        'sumber_sync_id': sumberSyncId,
        'nominal': nominal,
        'metode': metode,
        'operator': operator,
        'catatan': catatan,
        'sync_hlc_wall': hlcWall,
        'sync_hlc_counter': hlcCounter,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<String> _deviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final settings = {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
    return settings['sync.relay_device_id'] ??
        settings['device.current_id'] ??
        '';
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
    int? unitCostCents,
    String? storeId,
  }) async {
    final modal = unitCostCents ??
        (stock['harga_modal'] as num?)?.toInt() ??
        0;
    await StockLedger.instance.apply(
      txn,
      stockItemId: stock['id'] as int,
      stockSyncId: '${stock['sync_id']}',
      jenis: 'MASUK',
      deltaMilli: qtyMilli,
      unitCostCents: modal,
      sumberEntity: 'saldo_awal',
      sumberSyncId: sumberSyncId,
      namaItem: '${stock['nama']}',
      operator: operator,
      alasan: 'Saldo awal stok',
      storeId: storeId ?? _storeId,
      hlcWall: hlcWall,
      hlcCounter: hlcCounter,
    );
  }

  static String? _clean(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
