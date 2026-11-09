import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/quantity.dart';
import 'app_database.dart';

/// Hasil satu penerapan pergerakan stok.
class StockMovementResult {
  const StockMovementResult({
    required this.movementId,
    required this.movementSyncId,
    required this.beforeMilli,
    required this.afterMilli,
    required this.valueCents,
    required this.avgCostMilli,
    required this.existing,
  });

  final int movementId;
  final String movementSyncId;
  final int beforeMilli;
  final int afterMilli;
  final int valueCents;
  final int avgCostMilli;

  /// True bila movement dengan `sync_id` yang sama sudah ada dan tidak
  /// diterapkan ulang.
  final bool existing;
}

/// Satu-satunya jalur mutasi stok.
///
/// Setiap penerapan memperbarui empat hal secara atomik:
/// 1. `stock_items.jumlah_milli` sebagai saldo,
/// 2. `stock_movements` sebagai riwayat append-only,
/// 3. `stock_cost_state` sebagai HPP rata-rata bergerak,
/// 4. `stock_balances` sebagai nilai persediaan per barang.
///
/// Pemanggil wajib sudah berada di dalam transaksi database sehingga
/// kegagalan di tengah jalur tidak meninggalkan saldo setengah jadi.
class StockLedger {
  StockLedger._();

  static final StockLedger instance = StockLedger._();

  /// Menerapkan pergerakan delta terhadap saldo saat ini.
  ///
  /// [deltaMilli] bertanda: positif menambah stok, negatif mengurangi.
  /// [unitCostCents] hanya dipakai untuk penambahan (pembelian, saldo awal,
  /// koreksi positif). Bila null, nilai memakai HPP rata-rata berjalan;
  /// bila rata-rata belum ada, memakai `harga_modal` master.
  ///
  /// Untuk opname, kirim [opnameAbsolutMilli] dan [opnameBasisMilli] agar
  /// jejak hitung fisik tersimpan. Nilai absolut tidak pernah menimpa saldo;
  /// pemanggil menghitung delta terhadap basis saat hitung.
  Future<StockMovementResult> apply(
    DatabaseExecutor txn, {
    int? stockItemId,
    String? stockSyncId,
    required String jenis,
    required int deltaMilli,
    int? unitCostCents,
    required String sumberEntity,
    required String sumberSyncId,
    String? movementSyncId,
    String? namaItem,
    String? alasan,
    String? operator,
    int? serviceRecordId,
    String? storeId,
    bool allowNegative = false,
    int? opnameAbsolutMilli,
    int? opnameBasisMilli,
    int? hlcWall,
    int? hlcCounter,
    String? createdAt,
  }) async {
    final syncId = movementSyncId ?? newSyncId();
    final existing = await txn.query(
      'stock_movements',
      columns: [
        'id',
        'stok_sebelum_milli',
        'stok_sesudah_milli',
        'jumlah_milli',
      ],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final row = existing.first;
      final stock = await _resolveStock(
        txn,
        stockItemId: stockItemId,
        stockSyncId: stockSyncId,
      );
      final after =
          (row['stok_sesudah_milli'] as num?)?.toInt() ??
          (stock == null ? 0 : _milli(stock));
      final itemSyncId = stock == null ? '' : '${stock['sync_id']}';
      final state = stock == null
          ? null
          : await _loadState(
              txn,
              storeId ?? _storeId,
              itemSyncId,
            );
      return StockMovementResult(
        movementId: row['id'] as int,
        movementSyncId: syncId,
        beforeMilli:
            (row['stok_sebelum_milli'] as num?)?.toInt() ?? after,
        afterMilli: after,
        valueCents: state?.valueCents ?? 0,
        avgCostMilli: state?.avgCostMilli ?? 0,
        existing: true,
      );
    }
    final stock = await _resolveStock(
      txn,
      stockItemId: stockItemId,
      stockSyncId: stockSyncId,
    );
    if (stock == null) {
      throw StateError('Barang tidak ditemukan.');
    }
    final itemId = stock['id'] as int;
    final itemSyncId = '${stock['sync_id']}';
    final effectiveStore = storeId ?? _storeId;
    final before = _milli(stock);
    final after = before + deltaMilli;
    if (after < 0 && !allowNegative) {
      throw StateError('Stok ${stock['nama']} tidak cukup.');
    }
    final hlc = hlcWall == null || hlcCounter == null
        ? await AppDatabase.instance.nextSyncHlc(txn)
        : null;
    final wall = hlcWall ?? hlc!.wall;
    final counter = hlcCounter ?? hlc!.counter;
    final stamp = createdAt ?? nowIso();

    final state = await _applyValuation(
      txn,
      storeId: effectiveStore,
      stockSyncId: itemSyncId,
      beforeMilli: before,
      deltaMilli: deltaMilli,
      unitCostCents: unitCostCents,
      masterCostCents: (stock['harga_modal'] as num?)?.toInt() ?? 0,
      updatedAt: stamp,
    );

    await txn.update(
      'stock_items',
      {
        'jumlah_milli': after,
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'updated_at': stamp,
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
    final movementId = await txn.insert('stock_movements', {
      'sync_id': syncId,
      'store_id': effectiveStore,
      'stock_item_id': itemId,
      'stock_sync_id': itemSyncId,
      'nama_item': namaItem ?? stock['nama'],
      'jenis': jenis,
      'jumlah': wholeQuantity(deltaMilli),
      'jumlah_milli': deltaMilli,
      'stok_sebelum_milli': before,
      'stok_sesudah_milli': after,
      'opname_absolut_milli': opnameAbsolutMilli,
      'opname_basis_milli': opnameBasisMilli,
      'harga_pokok_satuan_cents': state.unitCostCents,
      'sumber_entity': sumberEntity,
      'sumber_sync_id': sumberSyncId,
      'service_record_id': serviceRecordId,
      'operator': operator,
      'alasan': alasan,
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': stamp,
      'updated_at': stamp,
    });
    return StockMovementResult(
      movementId: movementId,
      movementSyncId: syncId,
      beforeMilli: before,
      afterMilli: after,
      valueCents: state.valueCents,
      avgCostMilli: state.avgCostMilli,
      existing: false,
    );
  }

  /// HPP rata-rata berjalan untuk satu barang tanpa mengubah apa pun.
  /// Dipakai penjualan agar snapshot HPP per nota memakai nilai persediaan,
  /// bukan `harga_modal` master.
  Future<int> averageCostMilli(
    DatabaseExecutor txn, {
    int? stockItemId,
    String? stockSyncId,
    String? storeId,
  }) async {
    final stock = await _resolveStock(
      txn,
      stockItemId: stockItemId,
      stockSyncId: stockSyncId,
    );
    if (stock == null) return 0;
    final state = await _loadState(
      txn,
      storeId ?? _storeId,
      '${stock['sync_id']}',
    );
    if (state != null && state.avgCostMilli > 0) return state.avgCostMilli;
    return (stock['harga_modal'] as num?)?.toInt() ?? 0;
  }

  /// Membangun ulang `stock_balances` dan `stock_cost_state` dari
  /// `stock_movements`. Dipakai saat rekonsiliasi atau setelah restore.
  ///
  /// Movement diurutkan menurut waktu pembuatan lalu id agar hasilnya
  /// deterministik. Biaya per unit hanya tersedia untuk pembelian dan saldo
  /// awal; movement lain dinilai pada rata-rata berjalan.
  Future<int> rebuild(
    DatabaseExecutor txn, {
    String? storeId,
  }) async {
    final effectiveStore = storeId ?? _storeId;
    final stocks = await txn.query(
      'stock_items',
      columns: ['id', 'sync_id', 'harga_modal', 'jumlah_milli'],
    );
    await txn.delete(
      'stock_balances',
      where: 'store_id = ?',
      whereArgs: [effectiveStore],
    );
    await txn.delete(
      'stock_cost_state',
      where: 'store_id = ?',
      whereArgs: [effectiveStore],
    );
    var rebuilt = 0;
    for (final stock in stocks) {
      final syncId = '${stock['sync_id']}';
      final movements = await txn.query(
        'stock_movements',
        columns: [
          'jumlah_milli',
          'harga_pokok_satuan_cents',
          'stok_sesudah_milli',
        ],
        where: 'stock_sync_id = ? AND deleted_at IS NULL',
        whereArgs: [syncId],
        orderBy: 'created_at ASC, id ASC',
      );
      var qty = 0;
      var avg = (stock['harga_modal'] as num?)?.toInt() ?? 0;
      var value = 0;
      for (final movement in movements) {
        final delta = (movement['jumlah_milli'] as num?)?.toInt() ?? 0;
        final storedUnit =
            (movement['harga_pokok_satuan_cents'] as num?)?.toInt() ?? 0;
        final unitCost = storedUnit > 0 ? storedUnit : avg;
        if (delta > 0) {
          value += (delta * unitCost) ~/ 1000;
          qty += delta;
        } else if (delta < 0) {
          final out = -delta;
          value -= (out * avg) ~/ 1000;
          qty -= out;
          if (qty < 0) qty = 0;
        }
        if (value < 0) value = 0;
        if (qty <= 0) {
          qty = qty < 0 ? 0 : qty;
          if (qty == 0) {
            value = 0;
            avg = 0;
          }
        } else {
          avg = ((value * 1000 + qty ~/ 2) ~/ qty);
        }
      }
      final balanceQty = _milli(stock);
      await txn.insert('stock_balances', {
        'store_id': effectiveStore,
        'stock_sync_id': syncId,
        'qty_milli': balanceQty,
        'value_cents': value,
        'avg_cost_cents': avg,
        'updated_at': nowIso(),
      });
      await txn.insert('stock_cost_state', {
        'store_id': effectiveStore,
        'stock_sync_id': syncId,
        'qty_milli': balanceQty,
        'hpp_rata_milli': avg,
        'updated_at': nowIso(),
      });
      rebuilt++;
    }
    return rebuilt;
  }

  Future<_StockState> _applyValuation(
    DatabaseExecutor txn, {
    required String storeId,
    required String stockSyncId,
    required int beforeMilli,
    required int deltaMilli,
    required int? unitCostCents,
    required int masterCostCents,
    required String updatedAt,
  }) async {
    final current = await _loadState(txn, storeId, stockSyncId);
    // Saldo kosong/negatif tidak boleh mewarisi rata-rata lama: nilai
    // persediaan sudah nol, jadi HPP baru mulai dari modal master.
    final stateAvg = current?.avgCostMilli ?? 0;
    var avg = beforeMilli <= 0
        ? masterCostCents
        : (stateAvg > 0 ? stateAvg : masterCostCents);
    var value = beforeMilli <= 0 ? 0 : (beforeMilli * avg) ~/ 1000;
    var usedUnitCost = 0;
    if (deltaMilli > 0) {
      usedUnitCost = unitCostCents ?? (avg > 0 ? avg : masterCostCents);
      value += (deltaMilli * usedUnitCost) ~/ 1000;
    } else if (deltaMilli < 0) {
      usedUnitCost = avg;
      value -= ((-deltaMilli) * avg) ~/ 1000;
    }
    var afterQty = beforeMilli + deltaMilli;
    if (afterQty < 0) afterQty = 0;
    if (value < 0) value = 0;
    if (afterQty == 0) {
      value = 0;
      avg = 0;
    } else {
      avg = (value * 1000 + afterQty ~/ 2) ~/ afterQty;
    }
    if (current == null) {
      await txn.insert('stock_balances', {
        'store_id': storeId,
        'stock_sync_id': stockSyncId,
        'qty_milli': afterQty,
        'value_cents': value,
        'avg_cost_cents': avg,
        'updated_at': updatedAt,
      });
    } else {
      await txn.update(
        'stock_balances',
        {
          'qty_milli': afterQty,
          'value_cents': value,
          'avg_cost_cents': avg,
          'updated_at': updatedAt,
        },
        where: 'store_id = ? AND stock_sync_id = ?',
        whereArgs: [storeId, stockSyncId],
      );
    }
    final costRows = await txn.query(
      'stock_cost_state',
      columns: ['stock_sync_id'],
      where: 'store_id = ? AND stock_sync_id = ?',
      whereArgs: [storeId, stockSyncId],
      limit: 1,
    );
    if (costRows.isEmpty) {
      await txn.insert('stock_cost_state', {
        'store_id': storeId,
        'stock_sync_id': stockSyncId,
        'qty_milli': afterQty,
        'hpp_rata_milli': avg,
        'updated_at': updatedAt,
      });
    } else {
      await txn.update(
        'stock_cost_state',
        {
          'qty_milli': afterQty,
          'hpp_rata_milli': avg,
          'updated_at': updatedAt,
        },
        where: 'store_id = ? AND stock_sync_id = ?',
        whereArgs: [storeId, stockSyncId],
      );
    }
    return _StockState(
      valueCents: value,
      avgCostMilli: avg,
      unitCostCents: usedUnitCost,
    );
  }

  Future<_StockState?> _loadState(
    DatabaseExecutor txn,
    String storeId,
    String stockSyncId,
  ) async {
    final rows = await txn.query(
      'stock_balances',
      columns: ['value_cents', 'avg_cost_cents'],
      where: 'store_id = ? AND stock_sync_id = ?',
      whereArgs: [storeId, stockSyncId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return _StockState(
        valueCents: (rows.first['value_cents'] as num?)?.toInt() ?? 0,
        avgCostMilli: (rows.first['avg_cost_cents'] as num?)?.toInt() ?? 0,
      );
    }
    final costRows = await txn.query(
      'stock_cost_state',
      columns: ['qty_milli', 'hpp_rata_milli'],
      where: 'store_id = ? AND stock_sync_id = ?',
      whereArgs: [storeId, stockSyncId],
      limit: 1,
    );
    if (costRows.isEmpty) return null;
    final qty = (costRows.first['qty_milli'] as num?)?.toInt() ?? 0;
    final avg = (costRows.first['hpp_rata_milli'] as num?)?.toInt() ?? 0;
    return _StockState(valueCents: (qty * avg) ~/ 1000, avgCostMilli: avg);
  }

  Future<Map<String, Object?>?> _resolveStock(
    DatabaseExecutor txn, {
    int? stockItemId,
    String? stockSyncId,
  }) async {
    if (stockItemId == null && (stockSyncId ?? '').isEmpty) return null;
    final rows = await txn.query(
      'stock_items',
      where: stockItemId != null ? 'id = ?' : 'sync_id = ?',
      whereArgs: [stockItemId ?? stockSyncId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    if (rows.first['deleted_at'] != null) return null;
    return rows.first;
  }

  String get _storeId => AppDatabase.instance.activeStoreId ?? 'utama';

  int _milli(Map<String, Object?> row) =>
      (row['jumlah_milli'] as num?)?.toInt() ??
      ((row['jumlah'] as num?)?.toInt() ?? 0) * 1000;
}

class _StockState {
  const _StockState({
    required this.valueCents,
    required this.avgCostMilli,
    this.unitCostCents = 0,
  });

  final int valueCents;
  final int avgCostMilli;
  final int unitCostCents;
}
