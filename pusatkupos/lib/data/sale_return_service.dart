import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/quantity.dart';
import 'app_database.dart';
import 'models.dart';
import 'pajak.dart';
import 'store_settings.dart';

class ReturnLineInput {
  ReturnLineInput({
    required this.lineType,
    required this.lineSyncId,
    required int jumlah,
    int? qtyMilli,
  })  : jumlah = jumlah,
        qtyMilli = qtyMilli ?? jumlah * 1000;

  final String lineType; // jasa | part
  final String lineSyncId;
  final int jumlah;
  final int qtyMilli;
}

/// Retur penjualan tingkat baris. Nota asli tidak diubah; total retur
/// dikurangkan dari laporan sebagai penjualan neto.
class SaleReturnService {
  SaleReturnService._();

  static final SaleReturnService instance = SaleReturnService._();

  Future<int> createReturn({
    required int recordId,
    required List<ReturnLineInput> items,
    required String alasan,
    required Operator actor,
    required String requestId,
    Future<void> Function(Transaction txn, int id)? enqueue,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
        enqueueCommission,
  }) async {
    final cleanReason = alasan.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan retur wajib diisi.');
    }
    if (items.isEmpty) {
      throw ArgumentError('Pilih minimal satu baris yang diretur.');
    }
    final cleanRequest = requestId.trim();
    if (cleanRequest.isEmpty) {
      throw ArgumentError('Kunci idempoten retur wajib diisi.');
    }
    Permissions.require(actor, permissionRetur);
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor.role;
    if (!actor.isOwner && !settings.roleAllows(role, 'retur')) {
      throw StateError('Peran $role tidak berhak membuat retur.');
    }
    return AppDatabase.instance.db.transaction((txn) async {
      final existing = await txn.query(
        'sale_returns',
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [cleanRequest],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        if (enqueue != null) await enqueue(txn, id);
        return id;
      }
      final recordRows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (recordRows.isEmpty) throw StateError('Nota tidak ditemukan.');
      final record = recordRows.first;
      if (record['voided_at'] != null || record['status'] == 'VOID') {
        throw StateError('Nota yang dibatalkan tidak dapat diretur.');
      }
      final noNota = record['no_nota'] as String? ?? '';
      final notaSyncId = record['sync_id'] as String? ?? '';
      final lines = await _returnableLines(txn, recordId);
      final bySync = {
        for (final line in lines) '${line['line_type']}:${line['sync_id']}': line,
      };
      final picked = <String, int>{};
      for (final item in items) {
        if (item.qtyMilli <= 0) {
          throw ArgumentError('Jumlah retur harus lebih dari nol.');
        }
        final key = '${item.lineType}:${item.lineSyncId}';
        picked[key] = (picked[key] ?? 0) + item.qtyMilli;
      }
      final resolved = <Map<String, Object?>>[];
      var total = 0;
      var modalTotal = 0;
      for (final entry in picked.entries) {
        final line = bySync[entry.key];
        if (line == null) {
          throw StateError('Baris retur tidak ditemukan pada nota.');
        }
        final original = (line['qty_milli'] as num?)?.toInt() ?? 0;
        final returned = (line['returned'] as num?)?.toInt() ?? 0;
        final sisa = original - returned;
        if (entry.value > sisa) {
          throw StateError(
            'Jumlah retur ${line['deskripsi']} melebihi sisa '
            '${formatQuantity(sisa, 3)}.',
          );
        }
        final net = ((line['subtotal'] as num?)?.toInt() ?? 0) -
            ((line['diskon_alokasi'] as num?)?.toInt() ?? 0);
        final refund =
            original == 0 ? 0 : (net * entry.value / original).round();
        final modal = (line['modal'] as num?)?.toInt() ?? 0;
        total += refund;
        modalTotal += (modal * entry.value / 1000).round();
        resolved.add({
          ...line,
          'jumlah_retur_milli': entry.value,
          'refund': refund,
          'modal_satuan': modal,
        });
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final mode = record['pajak_mode'] as String? ?? pajakModeTanpa;
      final penanggung =
          record['pajak_penanggung'] as String? ?? pajakPenanggungPembeli;
      final pajakNota = (record['pajak'] as num?)?.toInt() ?? 0;
      final baseNota = ((record['biaya_jasa'] as num?)?.toInt() ?? 0) +
          ((record['total_part'] as num?)?.toInt() ?? 0) -
          ((record['diskon'] as num?)?.toInt() ?? 0);
      final dppNota = (record['pajak_dpp'] as num?)?.toInt() ?? baseNota;
      final previous = await txn.rawQuery(
        '''
        SELECT COALESCE(SUM(dpp), 0) AS dpp,
          COALESCE(SUM(pajak), 0) AS pajak
        FROM sale_returns
        WHERE service_record_id = ? AND deleted_at IS NULL
          AND status = 'AKTIF'
        ''',
        [recordId],
      );
      final dppSebelum = (previous.first['dpp'] as num?)?.toInt() ?? 0;
      final pajakSebelum = (previous.first['pajak'] as num?)?.toInt() ?? 0;
      var returTerakhir = true;
      for (final line in lines) {
        final original = (line['qty_milli'] as num?)?.toInt() ?? 0;
        final returned = (line['returned'] as num?)?.toInt() ?? 0;
        final key = '${line['line_type']}:${line['sync_id']}';
        final pickedQty = picked[key] ?? 0;
        if (original - returned - pickedQty > 0) {
          returTerakhir = false;
          break;
        }
      }
      final sisaDpp = dppNota - dppSebelum < 0 ? 0 : dppNota - dppSebelum;
      final sisaPajak = pajakNota - pajakSebelum < 0 ? 0 : pajakNota - pajakSebelum;
      int dppRetur;
      int pajakRetur;
      if (pajakNota <= 0 || mode == pajakModeTanpa) {
        dppRetur = total;
        pajakRetur = 0;
      } else if (returTerakhir) {
        // Retur terakhir menyerap sisa pembulatan agar total PPN retur sama
        // dengan PPN nota.
        dppRetur = sisaDpp;
        pajakRetur = sisaPajak;
      } else if (baseNota <= 0) {
        dppRetur = 0;
        pajakRetur = 0;
      } else {
        dppRetur = (dppNota * total / baseNota).round();
        pajakRetur = (pajakNota * total / baseNota).round();
        if (dppRetur > sisaDpp) dppRetur = sisaDpp;
        if (pajakRetur > sisaPajak) pajakRetur = sisaPajak;
      }
      final pajakDiserap =
          penanggung == pajakPenanggungBengkel ? pajakRetur : 0;
      final refundDitagihkan = penanggung == pajakPenanggungBengkel
          ? dppRetur
          : mode == pajakModeInklusif
              ? total
              : dppRetur + pajakRetur;
      total = refundDitagihkan;
      final noRetur = await AppDatabase.instance.allocateDocumentNumber(
        txn,
        docType: 'retur',
        prefix: 'R',
      );
      final returnSyncId = newSyncId();
      final returnId = await txn.insert('sale_returns', {
        'sync_id': returnSyncId,
        'service_record_id': recordId,
        'nota_sync_id': notaSyncId,
        'no_nota': noNota,
        'no_retur': noRetur,
        'request_id': cleanRequest,
        'status': 'AKTIF',
        'total': total,
        'total_modal_kembali': modalTotal,
        'dpp': dppRetur,
        'pajak': pajakRetur,
        'pajak_diserap': pajakDiserap,
        'alasan': cleanReason,
        'dibuat_oleh': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      for (final line in resolved) {
        final lineType = line['line_type'] as String;
        final qtyMilli = line['jumlah_retur_milli'] as int;
        final refund = line['refund'] as int;
        final itemSyncId = newSyncId();
        final stockItemId = line['stock_item_id'] as int?;
        Map<String, Object?>? stockRow;
        var stockSyncId = line['stock_sync_id'] as String?;
        if (lineType == 'part' && stockItemId != null) {
          final rows = await txn.query(
            'stock_items',
            where: 'id = ?',
            whereArgs: [stockItemId],
            limit: 1,
          );
          if (rows.isNotEmpty) {
            stockRow = rows.first;
            stockSyncId = rows.first['sync_id'] as String?;
          }
        }
        await txn.insert('sale_return_items', {
          'sync_id': itemSyncId,
          'return_id': returnId,
          'line_type': lineType,
          'line_sync_id': line['sync_id'] as String? ?? '',
          'service_job_sync_id': lineType == 'jasa'
              ? line['sync_id'] as String?
              : null,
          'service_part_sync_id': lineType == 'part'
              ? line['sync_id'] as String?
              : null,
          'deskripsi': line['deskripsi'] as String? ?? '',
          'jumlah': wholeQuantity(qtyMilli),
          'jumlah_milli': qtyMilli,
          'qty_asal_milli': (line['qty_milli'] as num?)?.toInt() ?? 0,
          'harga_satuan': qtyMilli == 0
              ? 0
              : (refund * 1000 / qtyMilli).round(),
          'subtotal': refund,
          'modal_satuan': line['modal_satuan'] as int? ?? 0,
          'stock_item_id': stockItemId,
          'stock_sync_id': stockSyncId,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': now,
          'updated_at': now,
        });
        if (lineType == 'jasa') {
          await txn.rawUpdate(
            'UPDATE service_jobs SET qty_retur_milli = '
            'qty_retur_milli + ?, updated_at = ? WHERE sync_id = ?',
            [qtyMilli, now, line['sync_id']],
          );
          continue;
        }
        await txn.rawUpdate(
          'UPDATE service_parts SET qty_retur_milli = '
          'qty_retur_milli + ?, updated_at = ? WHERE sync_id = ?',
          [qtyMilli, now, line['sync_id']],
        );
        if (stockItemId == null || stockRow == null) continue;
        final before = (stockRow['jumlah_milli'] as num?)?.toInt() ??
            ((stockRow['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        final nextMilli = before + qtyMilli;
        final stockHlc = await AppDatabase.instance.nextSyncHlc(txn);
        await txn.update(
          'stock_items',
          {
            'jumlah': wholeQuantity(nextMilli),
            'jumlah_milli': nextMilli,
            'sync_hlc_wall': stockHlc.wall,
            'sync_hlc_counter': stockHlc.counter,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [stockItemId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': stockItemId,
          'stock_sync_id': stockSyncId,
          'nama_item': line['deskripsi'] as String? ?? '',
          'jenis': 'MASUK',
          'jumlah': wholeQuantity(qtyMilli),
          'jumlah_milli': qtyMilli,
          'stok_sebelum_milli': before,
          'stok_sesudah_milli': nextMilli,
          'sumber_entity': 'sale_return_item',
          'sumber_sync_id': itemSyncId,
          'service_record_id': recordId,
          'operator': actor.label,
          'alasan': 'Retur $noNota',
          'created_at': now,
          'updated_at': now,
        });
      }
      final totalServis = (record['total_servis'] as num?)?.toInt() ?? 0;
      final totals = await txn.rawQuery(
        '''
        SELECT
          COALESCE((SELECT SUM(nominal) FROM service_payments
            WHERE service_record_id = ?), 0) AS paid,
          COALESCE((SELECT SUM(total) FROM sale_returns
            WHERE service_record_id = ? AND deleted_at IS NULL), 0) AS returns,
          ${AppDatabase.latestAdjustmentTotalSql(
            notaSyncIdExpr: '?',
            fallbackExpr: '?',
          )} AS adjusted_total
        ''',
        [recordId, recordId, notaSyncId, totalServis],
      );
      final paidSoFar = (totals.first['paid'] as num?)?.toInt() ?? 0;
      final returnsSoFar = (totals.first['returns'] as num?)?.toInt() ?? 0;
      final adjustedTotal =
          (totals.first['adjusted_total'] as num?)?.toInt() ?? totalServis;
      // Refund tunai hanya boleh sebesar kas yang benar-benar diterima.
      // Setelah koreksi ke 0, tagihan yang belum dibayar tidak boleh berubah
      // menjadi REFUND tunai saat barang diretur.
      final owedAfter = adjustedTotal - returnsSoFar;
      final refundable = paidSoFar - (owedAfter < 0 ? 0 : owedAfter);
      final cashRefund = refundable.clamp(0, total).toInt();
      if (cashRefund > 0) {
        final refundSyncId = newSyncId();
        await txn.insert('service_payments', {
          'sync_id': refundSyncId,
          'service_record_id': recordId,
          'jenis': 'REFUND',
          'metode': record['metode_bayar'] ?? 'CASH',
          'nominal': -cashRefund,
          'waktu': now,
          'operator': actor.label,
          'request_id': 'retur-$returnSyncId',
          'kas_kategori': 'REFUND',
          'catatan': 'Retur $noRetur',
          'created_at': now,
          'updated_at': now,
        });
        await txn.insert('cash_ledger', {
          'sync_id': newSyncId(),
          'waktu': now,
          'kategori': 'REFUND',
          'sumber_entity': 'service_payment',
          'sumber_sync_id': refundSyncId,
          'nominal': -cashRefund,
          'metode': record['metode_bayar'] ?? 'CASH',
          'operator': actor.label,
          'catatan': 'Retur $noRetur',
          'created_at': now,
          'updated_at': now,
        });
      }
      await txn.update(
        'sale_returns',
        {'total_refund': cashRefund, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [returnId],
      );
      await AppDatabase.instance.recalculateRecordTotals(txn, recordId);
      await AppDatabase.instance.recalculateRecordCommissions(
        txn,
        recordId,
        enqueueCommission: enqueueCommission,
      );
      await txn.insert('permission_audits', {
        'sync_id': newSyncId(),
        'actor': actor.label,
        'target_account_id': actor.employeeId,
        'action': 'retur_nota',
        'detail_json': jsonEncode({
          'no_nota': noNota,
          'no_retur': noRetur,
          'total': total,
          'refund_tunai': cashRefund,
          'modal': modalTotal,
          'dpp': dppRetur,
          'pajak': pajakRetur,
          'pajak_diserap': pajakDiserap,
          'alasan': cleanReason,
        }),
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, returnId);
      return returnId;
    });
  }

  Future<List<SaleReturnRow>> listForRecord(int recordId) async {
    final rows = await AppDatabase.instance.db.query(
      'sale_returns',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [recordId],
      orderBy: 'created_at DESC',
    );
    final result = <SaleReturnRow>[];
    for (final row in rows) {
      result.add(await _withItems(row));
    }
    return result;
  }

  Future<List<SaleReturnRow>> listReturns(
    DateTime from,
    DateTime to, {
    String query = '',
    int limit = 200,
  }) async {
    final clean = query.trim();
    final args = <Object?>[isoStartOfDay(from), isoEndOfDay(to)];
    var filter = '';
    if (clean.isNotEmpty) {
      filter = 'AND (r.no_retur LIKE ? OR r.no_nota LIKE ?)';
      args
        ..add('%$clean%')
        ..add('%$clean%');
    }
    args.add(limit);
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT r.* FROM sale_returns r
      WHERE r.created_at BETWEEN ? AND ? AND r.deleted_at IS NULL
      $filter
      ORDER BY r.created_at DESC
      LIMIT ?
      ''',
      args,
    );
    return rows.map(SaleReturnRow.fromRow).toList();
  }

  Future<List<Map<String, Object?>>> _returnableLines(
    DatabaseExecutor txn,
    int recordId,
  ) async {
    final jobs = await txn.rawQuery(
      '''
      SELECT j.sync_id, 'jasa' AS line_type, j.deskripsi,
        j.jumlah, j.jumlah * 1000 AS qty_milli,
        j.subtotal, j.diskon_alokasi,
        j.harga_batas_saat_transaksi AS modal,
        NULL AS stock_item_id,
        COALESCE((SELECT SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000))
          FROM sale_return_items ri
          JOIN sale_returns sr ON sr.id = ri.return_id
          WHERE sr.deleted_at IS NULL AND ri.line_type = 'jasa'
            AND ri.line_sync_id = j.sync_id), 0) AS returned
      FROM service_jobs j WHERE j.service_record_id = ?
      ''',
      [recordId],
    );
    final parts = await txn.rawQuery(
      '''
      SELECT p.sync_id, 'part' AS line_type, p.nama_part AS deskripsi,
        p.jumlah, COALESCE(p.jumlah_milli, p.jumlah * 1000) AS qty_milli,
        p.subtotal, p.diskon_alokasi,
        p.harga_batas_saat_transaksi AS modal,
        p.stock_item_id,
        COALESCE((SELECT SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000))
          FROM sale_return_items ri
          JOIN sale_returns sr ON sr.id = ri.return_id
          WHERE sr.deleted_at IS NULL AND ri.line_type = 'part'
            AND ri.line_sync_id = p.sync_id), 0) AS returned
      FROM service_parts p WHERE p.service_record_id = ?
      ''',
      [recordId],
    );
    return [...jobs, ...parts]
        .where(
          (line) =>
              ((line['qty_milli'] as num?)?.toInt() ?? 0) >
              ((line['returned'] as num?)?.toInt() ?? 0),
        )
        .toList();
  }

  Future<SaleReturnRow> _withItems(Map<String, Object?> row) async {
    final id = row['id'] as int;
    final items = await AppDatabase.instance.db.query(
      'sale_return_items',
      where: 'return_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    return SaleReturnRow.fromRow(
      row,
      items: items
          .map(
            (item) => SaleReturnItemRow(
              lineType: item['line_type'] as String? ?? 'part',
              lineSyncId: item['line_sync_id'] as String? ?? '',
              deskripsi: item['deskripsi'] as String? ?? '',
              jumlah: (item['jumlah'] as num?)?.toInt() ?? 0,
              qtyMilli: (item['jumlah_milli'] as num?)?.toInt() ?? 0,
              qtyAsalMilli: (item['qty_asal_milli'] as num?)?.toInt(),
              hargaSatuanCents:
                  (item['harga_satuan'] as num?)?.toInt() ?? 0,
              subtotalCents: (item['subtotal'] as num?)?.toInt() ?? 0,
              modalSatuanCents:
                  (item['modal_satuan'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList(),
    );
  }
}
