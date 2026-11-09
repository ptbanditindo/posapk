import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/quantity.dart';
import 'app_database.dart';
import 'audit_service.dart';
import 'pajak.dart';
import 'stock_ledger.dart';
import 'store_settings.dart';

class ArchiveReturnLineInput {
  ArchiveReturnLineInput({
    required this.lineType,
    required this.lineSyncId,
    required this.qtyMilli,
  });

  final String lineType; // jasa | part
  final String lineSyncId;
  final int qtyMilli;
}

/// Retur atas nota yang sudah dipurge. Bundel arsip terdekripsi hanya dibaca
/// untuk menentukan baris, harga, dan snapshot pajak; tabel nota tidak pernah
/// ditulis ulang. Dokumen retur baru merujuk nota lewat `ref_doc_id`.
class ArchiveReturnService {
  ArchiveReturnService._();

  static final ArchiveReturnService instance = ArchiveReturnService._();

  Future<int> create({
    required Map<String, Object?> document,
    required List<ArchiveReturnLineInput> items,
    required String alasan,
    required Operator actor,
    required String requestId,
    String? metodeRefund,
    Future<void> Function(Transaction txn, int returnId)? enqueue,
    Future<void> Function(Transaction txn, int movementId)? enqueueMovement,
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
    if (!actor.isOwner && !settings.roleAllows(actor.role, 'retur')) {
      throw StateError('Peran ${actor.role} tidak berhak membuat retur.');
    }
    final refDocId = '${document['doc_id'] ?? ''}';
    if (refDocId.isEmpty) {
      throw StateError('Dokumen arsip tidak memiliki identitas.');
    }
    final db = AppDatabase.instance.db;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'archive_returns',
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
      final record = Map<String, Object?>.from(
        document['record'] as Map? ?? const {},
      );
      if ('${record['status']}' == 'VOID') {
        throw StateError('Nota yang dibatalkan tidak dapat diretur.');
      }
      final refundMethod = (metodeRefund ?? 'CASH').trim().toUpperCase();
      if (refundMethod != 'CASH' && refundMethod != 'TRANSFER') {
        throw ArgumentError('Metode refund tidak valid.');
      }
      final lines = _bundleLines(document);
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
      final returnedBefore = await _returnedBefore(txn, refDocId);
      final resolved = <Map<String, Object?>>[];
      var total = 0;
      for (final entry in picked.entries) {
        final line = bySync[entry.key];
        if (line == null) {
          throw StateError('Baris retur tidak ditemukan pada arsip nota.');
        }
        final original = (line['qty_milli'] as num?)?.toInt() ?? 0;
        final returned = returnedBefore[entry.key] ?? 0;
        final sisa = original - returned;
        if (entry.value > sisa) {
          throw StateError(
            'Jumlah retur ${line['deskripsi']} melebihi sisa '
            '${formatQuantity(sisa, 3)}.',
          );
        }
        final net =
            ((line['subtotal'] as num?)?.toInt() ?? 0) -
            ((line['diskon_alokasi'] as num?)?.toInt() ?? 0);
        final refund = original == 0
            ? 0
            : (net * entry.value / original).round();
        total += refund;
        resolved.add({
          ...line,
          'jumlah_retur_milli': entry.value,
          'refund': refund,
        });
      }
      var returTerakhir = true;
      for (final line in lines) {
        final key = '${line['line_type']}:${line['sync_id']}';
        final original = (line['qty_milli'] as num?)?.toInt() ?? 0;
        final returned = returnedBefore[key] ?? 0;
        final pickedQty = picked[key] ?? 0;
        if (original - returned - pickedQty > 0) {
          returTerakhir = false;
          break;
        }
      }
      final pajak = _taxFor(
        record: record,
        previous: await _previousReturns(txn, refDocId),
        total: total,
        returTerakhir: returTerakhir,
      );
      total = pajak.ditagih;
      final refundWeights = <int>[
        for (final line in resolved) line['refund'] as int,
      ];
      final dppPerLine = _allocateByWeight(refundWeights, pajak.dpp);
      final ppnPerLine = _allocateByWeight(refundWeights, pajak.pajak);
      final mode = '${record['pajak_mode'] ?? pajakModeTanpa}';
      final penanggung =
          '${record['pajak_penanggung'] ?? pajakPenanggungPembeli}';
      final ditagihWeights = pajak.pajak <= 0 || mode == pajakModeInklusif
          ? refundWeights
          : penanggung == pajakPenanggungBengkel
          ? dppPerLine
          : <int>[
              for (var i = 0; i < dppPerLine.length; i++)
                dppPerLine[i] + ppnPerLine[i],
            ];
      final ditagihPerLine = _allocateByWeight(ditagihWeights, total);
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final noNota = '${record['no_nota'] ?? ''}';
      final noRetur = await AppDatabase.instance.allocateDocumentNumber(
        txn,
        docType: 'retur',
        prefix: 'R',
      );
      final returnSyncId = newSyncId();
      final deviceId = await _localDeviceId(txn);
      final storeId = '${document['store_id'] ?? ''}';
      final returnId = await txn.insert('archive_returns', {
        'sync_id': returnSyncId,
        'store_id': storeId,
        'device_id': deviceId,
        'ref_doc_id': refDocId,
        'no_nota': noNota,
        'no_retur': noRetur,
        'request_id': cleanRequest,
        'status': 'AKTIF',
        'total': total,
        'total_refund': 0,
        'dpp': pajak.dpp,
        'pajak': pajak.pajak,
        'pajak_diserap': pajak.diserap,
        'metode_refund': refundMethod,
        'alasan': cleanReason,
        'dibuat_oleh': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      var index = 0;
      for (final line in resolved) {
        final lineType = '${line['line_type']}';
        final qtyMilli = line['jumlah_retur_milli'] as int;
        final refund = line['refund'] as int;
        final lineDpp = dppPerLine[index];
        final linePpn = ppnPerLine[index];
        final lineDitagih = ditagihPerLine[index];
        index++;
        final itemSyncId = newSyncId();
        final stockSyncId = line['stock_sync_id'] as String?;
        await txn.insert('archive_return_items', {
          'sync_id': itemSyncId,
          'return_id': returnId,
          'return_sync_id': returnSyncId,
          'line_type': lineType,
          'line_sync_id': '${line['sync_id'] ?? ''}',
          'deskripsi': '${line['deskripsi'] ?? ''}',
          'jumlah_milli': qtyMilli,
          'qty_asal_milli': (line['qty_milli'] as num?)?.toInt() ?? 0,
          'harga_satuan':
              qtyMilli == 0 ? 0 : (refund * 1000 / qtyMilli).round(),
          'subtotal': refund,
          'modal_satuan': (line['modal'] as num?)?.toInt() ?? 0,
          'dpp_cents': lineDpp,
          'ppn_cents': linePpn,
          'total_ditagih_cents': lineDitagih,
          'stock_sync_id': stockSyncId,
          'created_at': now,
          'updated_at': now,
        });
        if (lineType != 'part' || stockSyncId == null || stockSyncId.isEmpty) {
          continue;
        }
        final stock = await txn.query(
          'stock_items',
          columns: ['id'],
          where: 'sync_id = ?',
          whereArgs: [stockSyncId],
          limit: 1,
        );
        if (stock.isEmpty) continue;
        final movement = await StockLedger.instance.apply(
          txn,
          stockItemId: stock.first['id'] as int,
          stockSyncId: stockSyncId,
          jenis: 'MASUK',
          deltaMilli: qtyMilli,
          sumberEntity: 'archive_return_item',
          sumberSyncId: itemSyncId,
          namaItem: line['deskripsi'] as String? ?? '',
          operator: actor.label,
          alasan: 'Retur arsip $noNota',
        );
        if (enqueueMovement != null) {
          await enqueueMovement(txn, movement.movementId);
        }
      }
      final paid = _bundlePaid(document);
      final adjustedTotal = (record['total_servis'] as num?)?.toInt() ?? total;
      final returnedSejakPurge =
          (await _previousReturns(txn, refDocId)).ditagih + total;
      final owedAfter = adjustedTotal - returnedSejakPurge;
      final refundable = paid - (owedAfter < 0 ? 0 : owedAfter);
      final cashRefund = refundable.clamp(0, total).toInt();
      if (cashRefund > 0) {
        await txn.insert('cash_ledger', {
          'sync_id': newSyncId(),
          'waktu': now,
          'kategori': 'REFUND',
          'sumber_entity': 'archive_return',
          'sumber_sync_id': returnSyncId,
          'nominal': -cashRefund,
          'metode': refundMethod,
          'operator': actor.label,
          'catatan': 'Retur arsip $noRetur',
          'created_at': now,
          'updated_at': now,
        });
      }
      await txn.update(
        'archive_returns',
        {'total_refund': cashRefund, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [returnId],
      );
      await AuditService.instance.recordOperator(
        txn,
        actor,
        aksi: 'retur_arsip',
        entity: 'archive_return',
        entityId: returnSyncId,
        alasan: cleanReason,
        after: {
          'ref_doc_id': refDocId,
          'no_nota': noNota,
          'no_retur': noRetur,
          'total': total,
          'refund_tunai': cashRefund,
          'dpp': pajak.dpp,
          'pajak': pajak.pajak,
        },
      );
      if (enqueue != null) await enqueue(txn, returnId);
      return returnId;
    });
  }

  /// Baris yang masih dapat diretur untuk satu dokumen arsip.
  Future<List<Map<String, Object?>>> returnableLines(
    Map<String, Object?> document,
  ) async {
    final refDocId = '${document['doc_id'] ?? ''}';
    final returned = await _returnedBefore(AppDatabase.instance.db, refDocId);
    final rows = <Map<String, Object?>>[];
    for (final line in _bundleLines(document)) {
      final key = '${line['line_type']}:${line['sync_id']}';
      final original = (line['qty_milli'] as num?)?.toInt() ?? 0;
      final sisa = original - (returned[key] ?? 0);
      if (sisa <= 0) continue;
      rows.add({...line, 'sisa_milli': sisa});
    }
    return rows;
  }

  List<Map<String, Object?>> _bundleLines(Map<String, Object?> document) {
    final lines = <Map<String, Object?>>[];
    for (final raw in (document['jobs'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final line = Map<String, Object?>.from(raw);
      lines.add({
        'line_type': 'jasa',
        'sync_id': '${line['sync_id'] ?? ''}',
        'deskripsi': '${line['deskripsi'] ?? ''}',
        'qty_milli':
            (line['jumlah_milli'] as num?)?.toInt() ??
            ((line['jumlah'] as num?)?.toInt() ?? 0) * 1000,
        'subtotal': (line['subtotal'] as num?)?.toInt() ?? 0,
        'diskon_alokasi': (line['diskon_alokasi'] as num?)?.toInt() ?? 0,
        'modal': (line['harga_batas_saat_transaksi'] as num?)?.toInt() ?? 0,
        'stock_sync_id': null,
      });
    }
    for (final raw in (document['parts'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final line = Map<String, Object?>.from(raw);
      lines.add({
        'line_type': 'part',
        'sync_id': '${line['sync_id'] ?? ''}',
        'deskripsi': '${line['nama_part'] ?? ''}',
        'qty_milli':
            (line['jumlah_milli'] as num?)?.toInt() ??
            ((line['jumlah'] as num?)?.toInt() ?? 0) * 1000,
        'subtotal': (line['subtotal'] as num?)?.toInt() ?? 0,
        'diskon_alokasi': (line['diskon_alokasi'] as num?)?.toInt() ?? 0,
        'modal':
            (line['harga_modal'] as num?)?.toInt() ??
            (line['harga_batas_saat_transaksi'] as num?)?.toInt() ??
            0,
        'stock_sync_id': line['stock_sync_id'],
      });
    }
    return lines;
  }

  Future<Map<String, int>> _returnedBefore(
    DatabaseExecutor executor,
    String refDocId,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT i.line_type, i.line_sync_id,
        COALESCE(SUM(COALESCE(i.jumlah_milli, 0)), 0) AS qty
      FROM archive_return_items i
      JOIN archive_returns r ON r.id = i.return_id
      WHERE r.ref_doc_id = ? AND r.deleted_at IS NULL
        AND r.status = 'AKTIF' AND i.deleted_at IS NULL
      GROUP BY i.line_type, i.line_sync_id
      ''',
      [refDocId],
    );
    return {
      for (final row in rows)
        '${row['line_type']}:${row['line_sync_id']}':
            (row['qty'] as num?)?.toInt() ?? 0,
    };
  }

  Future<_ArchiveReturnTotals> _previousReturns(
    DatabaseExecutor executor,
    String refDocId,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT COALESCE(SUM(dpp), 0) AS dpp,
        COALESCE(SUM(pajak), 0) AS pajak,
        COALESCE(SUM(total), 0) AS total
      FROM archive_returns
      WHERE ref_doc_id = ? AND deleted_at IS NULL AND status = 'AKTIF'
      ''',
      [refDocId],
    );
    final row = rows.first;
    return _ArchiveReturnTotals(
      dpp: (row['dpp'] as num?)?.toInt() ?? 0,
      pajak: (row['pajak'] as num?)?.toInt() ?? 0,
      ditagih: (row['total'] as num?)?.toInt() ?? 0,
    );
  }

  int _bundlePaid(Map<String, Object?> document) {
    var paid = 0;
    for (final raw in (document['payments'] as List? ?? const [])) {
      if (raw is! Map) continue;
      paid += (raw['nominal'] as num?)?.toInt() ?? 0;
    }
    return paid;
  }

  _ArchiveTax _taxFor({
    required Map<String, Object?> record,
    required _ArchiveReturnTotals previous,
    required int total,
    required bool returTerakhir,
  }) {
    final mode = '${record['pajak_mode'] ?? pajakModeTanpa}';
    final penanggung =
        '${record['pajak_penanggung'] ?? pajakPenanggungPembeli}';
    final pajakNota = (record['pajak'] as num?)?.toInt() ?? 0;
    final baseNota =
        ((record['biaya_jasa'] as num?)?.toInt() ?? 0) +
        ((record['total_part'] as num?)?.toInt() ?? 0) -
        ((record['diskon'] as num?)?.toInt() ?? 0);
    final dppNota = (record['pajak_dpp'] as num?)?.toInt() ?? baseNota;
    final sisaDpp = dppNota - previous.dpp < 0 ? 0 : dppNota - previous.dpp;
    final sisaPajak =
        pajakNota - previous.pajak < 0 ? 0 : pajakNota - previous.pajak;
    int dpp;
    int pajak;
    if (pajakNota <= 0 || mode == pajakModeTanpa) {
      dpp = total;
      pajak = 0;
    } else if (returTerakhir) {
      dpp = sisaDpp;
      pajak = sisaPajak;
    } else if (baseNota <= 0) {
      dpp = 0;
      pajak = 0;
    } else {
      dpp = (dppNota * total / baseNota).round();
      pajak = (pajakNota * total / baseNota).round();
      if (dpp > sisaDpp) dpp = sisaDpp;
      if (pajak > sisaPajak) pajak = sisaPajak;
    }
    final diserap = penanggung == pajakPenanggungBengkel ? pajak : 0;
    final ditagih = penanggung == pajakPenanggungBengkel
        ? dpp
        : mode == pajakModeInklusif
        ? total
        : dpp + pajak;
    return _ArchiveTax(dpp: dpp, pajak: pajak, diserap: diserap, ditagih: ditagih);
  }

  List<int> _allocateByWeight(List<int> weights, int total) {
    if (weights.isEmpty) return const [];
    final sum = weights.fold<int>(0, (a, b) => a + b);
    if (sum <= 0) return List<int>.filled(weights.length, 0);
    final shares = <int>[];
    var used = 0;
    for (var i = 0; i < weights.length; i++) {
      final share = i == weights.length - 1
          ? total - used
          : (total * weights[i] / sum).round();
      shares.add(share < 0 ? 0 : share);
      used += shares.last;
    }
    return shares;
  }

  Future<String> _localDeviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final values = {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
    return values['sync.relay_device_id'] ?? values['device.current_id'] ?? '';
  }
}

class _ArchiveTax {
  const _ArchiveTax({
    required this.dpp,
    required this.pajak,
    required this.diserap,
    required this.ditagih,
  });

  final int dpp;
  final int pajak;
  final int diserap;
  final int ditagih;
}

class _ArchiveReturnTotals {
  const _ArchiveReturnTotals({
    required this.dpp,
    required this.pajak,
    required this.ditagih,
  });

  final int dpp;
  final int pajak;
  final int ditagih;
}
