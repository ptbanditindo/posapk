import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/crypto.dart';
import '../sync/sync_conflict_rules.dart';
import 'app_database.dart';
import 'feature_flags.dart';
import 'stock_ledger.dart';

class PurchaseLineInput {
  const PurchaseLineInput({
    required this.stockItemId,
    required this.qtyMilli,
    required this.hargaSatuan,
  });

  final int stockItemId;
  final int qtyMilli;
  final int hargaSatuan;
}

class PurchaseInput {
  const PurchaseInput({
    required this.supplierId,
    required this.lines,
    this.tanggal,
    this.terminHari = 0,
    this.jenisBayar = 'KREDIT',
    this.diskon = 0,
    this.ongkir = 0,
    this.ppn = 0,
    this.bayarAwal = 0,
    this.metode = 'CASH',
    this.catatan,
    this.requestId,
  });

  final int supplierId;
  final List<PurchaseLineInput> lines;
  final DateTime? tanggal;
  final int terminHari;
  final String jenisBayar;
  final int diskon;
  final int ongkir;
  final int ppn;
  final int bayarAwal;
  final String metode;
  final String? catatan;
  final String? requestId;
}

class PurchaseReturnLineInput {
  const PurchaseReturnLineInput({
    required this.purchaseItemId,
    required this.qtyMilli,
  });

  final int purchaseItemId;
  final int qtyMilli;
}

class PurchasePaymentInput {
  const PurchasePaymentInput({
    required this.purchaseId,
    required this.nominal,
    required this.metode,
    this.catatan,
    this.requestId,
  });

  final int purchaseId;
  final int nominal;
  final String metode;
  final String? catatan;
  final String? requestId;
}

class PurchaseService {
  PurchaseService._();

  static final PurchaseService instance = PurchaseService._();

  String get _storeId => AppDatabase.instance.activeStoreId ?? 'utama';

  void _requireActor(Operator actor, String permission) {
    Permissions.require(actor, permission);
  }

  Future<int> createPurchase({
    required PurchaseInput input,
    required Operator actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    FeatureFlagsService.instance.requirePurchaseDebt();
    _requireActor(actor, permissionCreatePurchase);
    if (input.lines.isEmpty) {
      throw ArgumentError('Pembelian harus memiliki minimal satu barang.');
    }
    if (input.jenisBayar != 'TUNAI' && input.jenisBayar != 'KREDIT') {
      throw ArgumentError('Jenis bayar tidak valid.');
    }
    if (input.diskon < 0 || input.ongkir < 0 || input.ppn < 0) {
      throw ArgumentError('Diskon, ongkir, dan PPN tidak boleh negatif.');
    }
    if (input.bayarAwal < 0) {
      throw ArgumentError('Pembayaran awal tidak boleh negatif.');
    }
    if (input.terminHari < 0) {
      throw ArgumentError('Termin hari tidak boleh negatif.');
    }
    if (input.metode != 'CASH' && input.metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak valid.');
    }
    final requestId = input.requestId ?? newSyncId();
    final requestHash = sha256Hex(
      utf8.encode(
        canonicalJson({
          'jenis': 'pembelian',
          'supplier_id': input.supplierId,
          'tanggal': input.tanggal?.toIso8601String(),
          'termin_hari': input.terminHari,
          'jenis_bayar': input.jenisBayar,
          'diskon': input.diskon,
          'ongkir': input.ongkir,
          'ppn': input.ppn,
          'bayar_awal': input.bayarAwal,
          'metode': input.metode,
          'catatan': _clean(input.catatan),
          'items': [
            for (final line in input.lines)
              {
                'stock_item_id': line.stockItemId,
                'qty_milli': line.qtyMilli,
                'harga': line.hargaSatuan,
              },
          ],
        }),
      ),
    );
    final existing = await AppDatabase.instance.db.query(
      'supplier_purchases',
      columns: ['id', 'request_payload_hash'],
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final stored = existing.first['request_payload_hash'] as String?;
      if (stored != null && stored != requestHash) {
        throw StateError(
          'Permintaan $requestId sudah dipakai untuk pembelian dengan isi '
          'berbeda. Muat ulang lalu ulangi.',
        );
      }
      return existing.first['id'] as int;
    }

    return AppDatabase.instance.db.transaction((txn) async {
      final supplierRows = await txn.query(
        'suppliers',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [input.supplierId],
        limit: 1,
      );
      if (supplierRows.isEmpty) {
        throw StateError('Supplier tidak ditemukan.');
      }
      final supplier = supplierRows.first;
      final tanggal = input.tanggal ?? DateTime.now();
      final tanggalKey = dateOnly.format(tanggal);
      final lines = <Map<String, Object?>>[];
      var subtotal = 0;
      for (final line in input.lines) {
        if (line.qtyMilli <= 0) {
          throw ArgumentError('Jumlah barang harus lebih dari nol.');
        }
        if (line.hargaSatuan < 0) {
          throw ArgumentError('Harga satuan tidak boleh negatif.');
        }
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [line.stockItemId],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          throw StateError('Barang tidak ditemukan.');
        }
        final stock = stockRows.first;
        final lineSubtotal = _mulDiv(line.qtyMilli, line.hargaSatuan, 1000);
        subtotal += lineSubtotal;
        lines.add({
          'stock': stock,
          'qty': line.qtyMilli,
          'harga': line.hargaSatuan,
          'subtotal': lineSubtotal,
        });
      }
      if (input.diskon > subtotal) {
        throw ArgumentError('Diskon melebihi subtotal pembelian.');
      }
      final total = subtotal - input.diskon + input.ongkir + input.ppn;
      if (input.jenisBayar == 'TUNAI' && input.bayarAwal < total) {
        throw StateError('Pembelian tunai harus dibayar penuh.');
      }
      if (input.bayarAwal > total) {
        throw ArgumentError('Pembayaran awal melebihi total pembelian.');
      }
      _allocateCosts(
        lines,
        diskon: input.diskon,
        ongkir: input.ongkir,
        subtotal: subtotal,
      );

      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceId = await _deviceId(txn);
      final purchaseSyncId = newSyncId();
      final noPembelian = await _nextNumber(
        txn,
        docType: 'pembelian',
        prefix: 'PB',
        tanggal: tanggal,
      );
      final jatuhTempo = input.jenisBayar == 'KREDIT'
          ? dateOnly.format(
              DateTime(tanggal.year, tanggal.month, tanggal.day)
                  .add(Duration(days: input.terminHari)),
            )
          : null;
      final purchaseId = await txn.insert('supplier_purchases', {
        'sync_id': purchaseSyncId,
        'store_id': _storeId,
        'device_id': deviceId,
        'origin_device_id': deviceId,
        'no_pembelian': noPembelian,
        'request_id': requestId,
        'request_payload_hash': requestHash,
        'supplier_id': input.supplierId,
        'supplier_sync_id': supplier['sync_id'],
        'supplier_nama_snapshot': supplier['nama'],
        'tanggal': tanggalKey,
        'jatuh_tempo': jatuhTempo,
        'termin_hari': input.terminHari,
        'jenis_bayar': input.jenisBayar,
        'status': 'AKTIF',
        'subtotal': subtotal,
        'diskon': input.diskon,
        'ongkir': input.ongkir,
        'ppn': input.ppn,
        'total': total,
        'total_dibayar': 0,
        'sisa_utang': total,
        'catatan': _clean(input.catatan),
        'created_by': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });

      for (final line in lines) {
        final stock = line['stock'] as Map<String, Object?>;
        final qty = line['qty'] as int;
        final itemSyncId = newSyncId();
        await txn.insert('supplier_purchase_items', {
          'sync_id': itemSyncId,
          'store_id': _storeId,
          'device_id': deviceId,
          'purchase_id': purchaseId,
          'stock_item_id': stock['id'],
          'stock_sync_id': stock['sync_id'],
          'nama_snapshot': stock['nama'],
          'satuan': stock['satuan'] ?? 'pcs',
          'jumlah_milli': qty,
          'harga_satuan': line['harga'],
          'subtotal': line['subtotal'],
          'diskon_alokasi': line['diskon_alokasi'],
          'ongkir_alokasi': line['ongkir_alokasi'],
          'harga_pokok_satuan': line['harga_pokok_satuan'],
          'qty_retur_milli': 0,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': now,
          'updated_at': now,
        });
        await _applyStockIn(
          txn,
          stockItemId: stock['id'] as int,
          stockSyncId: '${stock['sync_id']}',
          nama: '${stock['nama']}',
          qtyMilli: qty,
          hargaPokokSatuan: line['harga_pokok_satuan'] as int,
          sumberSyncId: itemSyncId,
          alasan: 'Pembelian $noPembelian',
          operator: actor.label,
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }

      if (input.bayarAwal > 0) {
        final paymentSyncId = newSyncId();
        await txn.insert('supplier_payments', {
          'sync_id': paymentSyncId,
          'store_id': _storeId,
          'device_id': deviceId,
          'purchase_id': purchaseId,
          'request_id': '$requestId-dp',
          'jenis': 'DP',
          'metode': input.metode,
          'nominal': input.bayarAwal,
          'waktu': now,
          'operator': actor.label,
          'catatan': 'Pembayaran awal $noPembelian',
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': now,
          'updated_at': now,
        });
        await _writeCash(
          txn,
          sumberSyncId: paymentSyncId,
          nominal: -input.bayarAwal,
          metode: input.metode,
          kategori: 'PEMBELIAN',
          operator: actor.label,
          catatan: 'Pembayaran $noPembelian',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }
      await _recalculateTotals(txn, purchaseId);
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'device_id': deviceId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'pembelian_baru',
        'entity': 'supplier_purchase',
        'entity_id': purchaseSyncId,
        'before_json': '{}',
        'after_json': '{}',
        'alasan': null,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, purchaseId);
      return purchaseId;
    });
  }

  Future<int> addPayment({
    required PurchasePaymentInput input,
    required Operator actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    FeatureFlagsService.instance.requirePurchaseDebt();
    _requireActor(actor, permissionPayDebt);
    if (input.nominal <= 0) {
      throw ArgumentError('Nominal pembayaran harus lebih dari nol.');
    }
    if (input.metode != 'CASH' && input.metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak valid.');
    }
    final requestId = input.requestId ?? newSyncId();
    final existing = await AppDatabase.instance.db.query(
      'supplier_payments',
      columns: ['id'],
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'supplier_purchases',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [input.purchaseId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Pembelian tidak ditemukan.');
      final purchase = rows.first;
      if ('${purchase['status']}' != 'AKTIF') {
        throw StateError('Pembelian yang sudah dibatalkan tidak dapat dibayar.');
      }
      final sisa = (purchase['sisa_utang'] as num?)?.toInt() ?? 0;
      if (input.nominal > sisa) {
        throw StateError('Pembayaran melebihi sisa utang.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceId = await _deviceId(txn);
      final paymentSyncId = newSyncId();
      final paymentId = await txn.insert('supplier_payments', {
        'sync_id': paymentSyncId,
        'store_id': _storeId,
        'device_id': deviceId,
        'purchase_id': input.purchaseId,
        'request_id': requestId,
        'jenis': 'PELUNASAN',
        'metode': input.metode,
        'nominal': input.nominal,
        'waktu': now,
        'operator': actor.label,
        'catatan': _clean(input.catatan),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      await _writeCash(
        txn,
        sumberSyncId: paymentSyncId,
        nominal: -input.nominal,
        metode: input.metode,
        kategori: 'BAYAR_UTANG',
        operator: actor.label,
        catatan: 'Bayar ${purchase['no_pembelian']}',
        hlcWall: hlc.wall,
        hlcCounter: hlc.counter,
      );
      await _recalculateTotals(txn, input.purchaseId);
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'device_id': deviceId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'bayar_utang_supplier',
        'entity': 'supplier_payment',
        'entity_id': paymentSyncId,
        'before_json': '{}',
        'after_json': '{}',
        'alasan': null,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, paymentId);
      return paymentId;
    });
  }

  Future<void> voidPurchase({
    required int purchaseId,
    required String reason,
    required Operator actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    FeatureFlagsService.instance.requirePurchaseDebt();
    _requireActor(actor, permissionCreatePurchase);
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan pembatalan wajib diisi.');
    }
    await AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'supplier_purchases',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [purchaseId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Pembelian tidak ditemukan.');
      final purchase = rows.first;
      if ('${purchase['status']}' != 'AKTIF') {
        throw StateError('Pembelian sudah dibatalkan.');
      }
      final paidRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(nominal), 0) AS total FROM supplier_payments '
        'WHERE purchase_id = ? AND deleted_at IS NULL AND voided_at IS NULL',
        [purchaseId],
      );
      final paid = (paidRows.first['total'] as num?)?.toInt() ?? 0;
      if (paid > 0 || ((purchase['total_dibayar'] as num?)?.toInt() ?? 0) > 0) {
        throw StateError(
          'Pembelian yang sudah dibayar tidak dapat dibatalkan. '
          'Gunakan retur pembelian untuk sisa barang.',
        );
      }
      final returnRows = await txn.query(
        'supplier_purchase_returns',
        columns: ['id'],
        where: "purchase_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
        whereArgs: [purchaseId],
        limit: 1,
      );
      if (returnRows.isNotEmpty) {
        throw StateError('Pembelian yang sudah diretur tidak dapat dibatalkan.');
      }
      final items = await txn.query(
        'supplier_purchase_items',
        where: 'purchase_id = ? AND deleted_at IS NULL',
        whereArgs: [purchaseId],
      );
      for (final item in items) {
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [item['stock_item_id']],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          throw StateError('Barang pembelian tidak ditemukan.');
        }
        final available =
            (stockRows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
        final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
        if (available < qty) {
          throw StateError(
            'Barang ${item['nama_snapshot']} sudah terjual atau tidak '
            'lengkap; gunakan retur pembelian.',
          );
        }
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      for (final item in items) {
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [item['stock_item_id']],
          limit: 1,
        );
        final stock = stockRows.first;
        await _applyStockOut(
          txn,
          stockItemId: stock['id'] as int,
          stockSyncId: '${stock['sync_id']}',
          nama: '${stock['nama']}',
          qtyMilli: (item['jumlah_milli'] as num).toInt(),
          sumberSyncId: '${item['sync_id']}',
          alasan: 'Pembatalan ${purchase['no_pembelian']}',
          operator: actor.label,
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
          sumberEntity: 'pembelian_void_item',
        );
      }
      await txn.update(
        'supplier_purchases',
        {
          'status': 'VOID',
          'sisa_utang': 0,
          'void_reason': cleanReason,
          'voided_at': now,
          'voided_by': actor.label,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [purchaseId],
      );
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'pembelian_void',
        'entity': 'supplier_purchase',
        'entity_id': '${purchase['sync_id']}',
        'before_json': '{"status":"AKTIF"}',
        'after_json': '{"status":"VOID"}',
        'alasan': cleanReason,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, purchaseId);
    });
  }

  Future<int> createReturn({
    required int purchaseId,
    required List<PurchaseReturnLineInput> lines,
    required String alasan,
    required Operator actor,
    String? metodeRefund,
    String? requestId,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    FeatureFlagsService.instance.requirePurchaseDebt();
    _requireActor(actor, permissionCreatePurchase);
    final cleanReason = alasan.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan retur wajib diisi.');
    }
    if (lines.isEmpty) {
      throw ArgumentError('Retur harus memiliki minimal satu baris.');
    }
    final request = requestId ?? newSyncId();
    final requestHash = sha256Hex(
      utf8.encode(
        canonicalJson({
          'jenis': 'retur_pembelian',
          'purchase_id': purchaseId,
          'alasan': cleanReason,
          'metode_refund': (metodeRefund ?? '').trim(),
          'lines': [
            for (final line in lines)
              {
                'purchase_item_id': line.purchaseItemId,
                'qty_milli': line.qtyMilli,
              },
          ],
        }),
      ),
    );
    final existing = await AppDatabase.instance.db.query(
      'supplier_purchase_returns',
      columns: ['id', 'request_payload_hash'],
      where: 'request_id = ?',
      whereArgs: [request],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final stored = existing.first['request_payload_hash'] as String?;
      if (stored != null && stored != requestHash) {
        throw StateError(
          'Permintaan $request sudah dipakai untuk retur pembelian dengan isi '
          'berbeda. Muat ulang lalu ulangi.',
        );
      }
      return existing.first['id'] as int;
    }
    return AppDatabase.instance.db.transaction((txn) async {
      final purchaseRows = await txn.query(
        'supplier_purchases',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [purchaseId],
        limit: 1,
      );
      if (purchaseRows.isEmpty) throw StateError('Pembelian tidak ditemukan.');
      final purchase = purchaseRows.first;
      if ('${purchase['status']}' != 'AKTIF') {
        throw StateError('Retur pada pembelian VOID ditolak.');
      }
      final refundMethod = await _resolveRefundMethod(
        txn,
        purchaseId,
        metodeRefund,
      );
      final purchasePpn = (purchase['ppn'] as num?)?.toInt() ?? 0;
      final purchaseBase =
          ((purchase['total'] as num?)?.toInt() ?? 0) - purchasePpn;
      var totalDpp = 0;
      var totalPpn = 0;
      final prepared = <Map<String, Object?>>[];
      for (final line in lines) {
        if (line.qtyMilli <= 0) {
          throw ArgumentError('Jumlah retur harus lebih dari nol.');
        }
        final itemRows = await txn.query(
          'supplier_purchase_items',
          where: 'id = ? AND purchase_id = ? AND deleted_at IS NULL',
          whereArgs: [line.purchaseItemId, purchaseId],
          limit: 1,
        );
        if (itemRows.isEmpty) {
          throw StateError('Baris pembelian tidak ditemukan.');
        }
        final item = itemRows.first;
        final purchased = (item['jumlah_milli'] as num).toInt();
        final returned = (item['qty_retur_milli'] as num?)?.toInt() ?? 0;
        if (returned + line.qtyMilli > purchased) {
          throw StateError(
            'Jumlah retur ${item['nama_snapshot']} melebihi yang dibeli.',
          );
        }
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [item['stock_item_id']],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          throw StateError('Barang retur tidak ditemukan.');
        }
        final available =
            (stockRows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
        if (available < line.qtyMilli) {
          throw StateError(
            'Stok ${item['nama_snapshot']} tidak cukup untuk diretur.',
          );
        }
        final harga = (item['harga_satuan'] as num?)?.toInt() ?? 0;
        final modal = (item['harga_pokok_satuan'] as num?)?.toInt() ?? 0;
        final subtotal = _mulDiv(line.qtyMilli, modal, 1000);
        final ppn = purchaseBase <= 0
            ? 0
            : _mulDiv(subtotal, purchasePpn, purchaseBase);
        totalDpp += subtotal;
        totalPpn += ppn;
        prepared.add({
          'item': item,
          'stock': stockRows.first,
          'qty': line.qtyMilli,
          'harga': harga,
          'modal': modal,
          'subtotal': subtotal + ppn,
        });
      }
      final totalDitagih = totalDpp + totalPpn;
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceId = await _deviceId(txn);
      final returnSyncId = newSyncId();
      final noRetur = await _nextNumber(
        txn,
        docType: 'retur_pembelian',
        prefix: 'RPB',
        tanggal: DateTime.now(),
      );
      final returnId = await txn.insert('supplier_purchase_returns', {
        'sync_id': returnSyncId,
        'store_id': _storeId,
        'device_id': deviceId,
        'origin_device_id': deviceId,
        'purchase_id': purchaseId,
        'purchase_sync_id': purchase['sync_id'],
        'no_retur': noRetur,
        'request_id': request,
        'request_payload_hash': requestHash,
        'status': 'AKTIF',
        'total': totalDitagih,
        'total_modal_kembali': totalDpp,
        'total_kas_kembali': 0,
        'metode_refund': refundMethod,
        'dpp_cents': totalDpp,
        'ppn_cents': totalPpn,
        'total_ditagih_cents': totalDitagih,
        'alasan': cleanReason,
        'dibuat_oleh': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      for (final line in prepared) {
        final item = line['item'] as Map<String, Object?>;
        final itemSyncId = newSyncId();
        await txn.insert('supplier_purchase_return_items', {
          'sync_id': itemSyncId,
          'store_id': _storeId,
          'device_id': deviceId,
          'return_id': returnId,
          'purchase_item_id': item['id'],
          'purchase_item_sync_id': item['sync_id'],
          'nama_snapshot': item['nama_snapshot'],
          'jumlah_milli': line['qty'],
          'harga_satuan': line['harga'],
          'subtotal': line['subtotal'],
          'modal_satuan': line['modal'],
          'harga_pokok_satuan': line['modal'],
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': now,
          'updated_at': now,
        });
        await txn.update(
          'supplier_purchase_items',
          {
            'qty_retur_milli':
                ((item['qty_retur_milli'] as num?)?.toInt() ?? 0) +
                    (line['qty'] as int),
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [item['id']],
        );
        final stock = line['stock'] as Map<String, Object?>;
        await _applyStockOut(
          txn,
          stockItemId: stock['id'] as int,
          stockSyncId: '${stock['sync_id']}',
          nama: '${stock['nama']}',
          qtyMilli: line['qty'] as int,
          sumberSyncId: itemSyncId,
          alasan: 'Retur pembelian $noRetur',
          operator: actor.label,
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }
      final previousRefund =
          (purchase['refund_accumulated_cents'] as num?)?.toInt() ?? 0;
      final targetRefund = await _recalculateTotals(txn, purchaseId);
      final refund = targetRefund > previousRefund
          ? targetRefund - previousRefund
          : 0;
      if (refund > 0) {
        await txn.update(
          'supplier_purchase_returns',
          {'total_kas_kembali': refund, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [returnId],
        );
        await txn.update(
          'supplier_purchases',
          {
            'refund_accumulated_cents': previousRefund + refund,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [purchaseId],
        );
        await _writeCash(
          txn,
          sumberSyncId: returnSyncId,
          nominal: refund,
          metode: refundMethod,
          kategori: 'RETUR_PEMBELIAN',
          operator: actor.label,
          catatan: 'Retur $noRetur',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
          sumberEntity: 'supplier_purchase_return',
        );
      }
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'retur_pembelian',
        'entity': 'supplier_purchase_return',
        'entity_id': returnSyncId,
        'before_json': '{}',
        'after_json': '{}',
        'alasan': cleanReason,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, returnId);
      return returnId;
    });
  }

  Future<void> reverseReturn({
    required int returnId,
    required String alasan,
    required Operator actor,
    String? requestId,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    FeatureFlagsService.instance.requirePurchaseDebt();
    if (!actor.isOwner) {
      throw StateError('Reversal retur pembelian hanya untuk pemilik.');
    }
    final cleanReason = alasan.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan reversal wajib diisi.');
    }
    final request = requestId ?? newSyncId();
    await AppDatabase.instance.db.transaction((txn) async {
      final existing = await txn.query(
        'purchase_return_reversals',
        columns: ['return_id'],
        where: 'request_id = ?',
        whereArgs: [request],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      final rows = await txn.query(
        'supplier_purchase_returns',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [returnId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Retur pembelian tidak ditemukan.');
      final retur = rows.first;
      if ('${retur['status']}' != 'AKTIF') {
        throw StateError('Retur pembelian sudah dibatalkan.');
      }
      final purchaseRows = await txn.query(
        'supplier_purchases',
        where: 'id = ?',
        whereArgs: [retur['purchase_id']],
        limit: 1,
      );
      if (purchaseRows.isEmpty) throw StateError('Pembelian tidak ditemukan.');
      final purchase = purchaseRows.first;
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceId = await _deviceId(txn);
      final kasKembali = (retur['total_kas_kembali'] as num?)?.toInt() ?? 0;
      final reversalSyncId = newSyncId();
      await txn.insert('purchase_return_reversals', {
        'sync_id': reversalSyncId,
        'store_id': _storeId,
        'device_id': deviceId,
        'return_id': returnId,
        'return_sync_id': '${retur['sync_id']}',
        'request_id': request,
        'total_kas_cents': kasKembali,
        'alasan': cleanReason,
        'dibuat_oleh': actor.label,
        'created_at': now,
        'updated_at': now,
      });
      final items = await txn.query(
        'supplier_purchase_return_items',
        where: 'return_id = ? AND deleted_at IS NULL',
        whereArgs: [returnId],
      );
      for (final item in items) {
        final purchaseItemRows = await txn.query(
          'supplier_purchase_items',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [item['purchase_item_id']],
          limit: 1,
        );
        if (purchaseItemRows.isEmpty) {
          throw StateError('Baris pembelian retur tidak ditemukan.');
        }
        final purchaseItem = purchaseItemRows.first;
        final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
        final returned =
            (purchaseItem['qty_retur_milli'] as num?)?.toInt() ?? 0;
        final next = returned - qty;
        await txn.update(
          'supplier_purchase_items',
          {'qty_retur_milli': next < 0 ? 0 : next, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [purchaseItem['id']],
        );
        final stockRows = await txn.query(
          'stock_items',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [purchaseItem['stock_item_id']],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          throw StateError('Barang retur tidak ditemukan.');
        }
        final stock = stockRows.first;
        await _applyStockIn(
          txn,
          stockItemId: stock['id'] as int,
          stockSyncId: '${stock['sync_id']}',
          nama: '${stock['nama']}',
          qtyMilli: qty,
          hargaPokokSatuan: (item['harga_pokok_satuan'] as num?)?.toInt() ??
              (item['modal_satuan'] as num?)?.toInt() ??
              0,
          sumberSyncId: '${item['sync_id']}',
          alasan: 'Reversal retur ${retur['no_retur']}',
          operator: actor.label,
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
          sumberEntity: 'retur_pembelian_reversal',
        );
      }
      await txn.update(
        'supplier_purchase_returns',
        {
          'status': 'VOID',
          'void_reason': cleanReason,
          'voided_at': now,
          'voided_by': actor.label,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [returnId],
      );
      final previousRefund =
          (purchase['refund_accumulated_cents'] as num?)?.toInt() ?? 0;
      final remaining = previousRefund - kasKembali;
      await txn.update(
        'supplier_purchases',
        {
          'refund_accumulated_cents': remaining < 0 ? 0 : remaining,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [purchase['id']],
      );
      if (kasKembali > 0) {
        await _writeCash(
          txn,
          sumberSyncId: reversalSyncId,
          nominal: -kasKembali,
          metode: '${retur['metode_refund'] ?? 'CASH'}',
          kategori: 'REVERSAL_RETUR_PEMBELIAN',
          operator: actor.label,
          catatan: 'Reversal retur ${retur['no_retur']}',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
          sumberEntity: 'purchase_return_reversal',
        );
      }
      await _recalculateTotals(txn, purchase['id'] as int);
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': _storeId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'reversal_retur_pembelian',
        'entity': 'supplier_purchase_return',
        'entity_id': '${retur['sync_id']}',
        'before_json': '{"status":"AKTIF"}',
        'after_json': '{"status":"VOID"}',
        'alasan': cleanReason,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, returnId);
    });
  }

  Future<List<Map<String, Object?>>> listPurchases({
    String query = '',
    int limit = 200,
  }) async {
    final term = query.trim();
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT p.*,
        (SELECT COUNT(*) FROM supplier_purchase_items i
          WHERE i.purchase_id = p.id AND i.deleted_at IS NULL) AS jumlah_baris
      FROM supplier_purchases p
      WHERE p.deleted_at IS NULL
        AND (? = '' OR p.no_pembelian LIKE ? OR p.supplier_nama_snapshot LIKE ?)
      ORDER BY p.tanggal DESC, p.id DESC
      LIMIT ?
      ''',
      [term, '%$term%', '%$term%', limit],
    );
  }

  Future<List<Map<String, Object?>>> listDebts({bool onlyDue = false}) async {
    final today = dateOnly.format(DateTime.now());
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT * FROM supplier_purchases
      WHERE deleted_at IS NULL AND status = 'AKTIF' AND sisa_utang > 0
        ${onlyDue ? "AND jatuh_tempo IS NOT NULL AND jatuh_tempo <= ?" : ''}
      ORDER BY jatuh_tempo IS NULL, jatuh_tempo, id
      ''',
      onlyDue ? [today] : const [],
    );
  }

  Future<Map<String, Object?>?> purchaseDetail(int id) async {
    final rows = await AppDatabase.instance.db.query(
      'supplier_purchases',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final items = await AppDatabase.instance.db.query(
      'supplier_purchase_items',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    final payments = await AppDatabase.instance.db.query(
      'supplier_payments',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'waktu',
    );
    final returns = await AppDatabase.instance.db.query(
      'supplier_purchase_returns',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'created_at',
    );
    return {...rows.first, 'items': items, 'payments': payments, 'returns': returns};
  }

  Future<List<Map<String, Object?>>> agingBySupplier() async {
    final rows = await listDebts();
    final today = DateTime.now();
    final groups = <int, Map<String, Object?>>{};
    void addRow({
      required int supplierId,
      required String supplierNama,
      required String tanggal,
      required int amount,
    }) {
      final base = groups.putIfAbsent(
        supplierId,
        () => {
          'supplier_id': supplierId,
          'supplier_nama': supplierNama,
          'b0_30': 0,
          'b31_60': 0,
          'b61_90': 0,
          'b90': 0,
          'total': 0,
        },
      );
      final parsed = DateTime.tryParse(tanggal) ?? today;
      final age = today.difference(parsed).inDays;
      final key = age <= 30
          ? 'b0_30'
          : age <= 60
              ? 'b31_60'
              : age <= 90
                  ? 'b61_90'
                  : 'b90';
      base[key] = (base[key] as int) + amount;
      base['total'] = (base['total'] as int) + amount;
    }

    for (final row in rows) {
      addRow(
        supplierId: (row['supplier_id'] as num).toInt(),
        supplierNama: '${row['supplier_nama_snapshot']}',
        tanggal: '${row['tanggal']}',
        amount: (row['sisa_utang'] as num?)?.toInt() ?? 0,
      );
    }
    // Saldo awal utang supplier ikut aging memakai sisa yang belum dibayar.
    final openingRows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT supplier_sync_id, supplier_nama_snapshot,
        nominal_cents - terbayar_cents AS sisa,
        COALESCE(jatuh_tempo, created_at) AS posted_at
      FROM opening_payables
      WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL
        AND nominal_cents > terbayar_cents
      ''',
      [_storeId],
    );
    for (final row in openingRows) {
      final supplierRows = await AppDatabase.instance.db.query(
        'suppliers',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [row['supplier_sync_id']],
        limit: 1,
      );
      final supplierId = supplierRows.isEmpty
          ? 0
          : (supplierRows.first['id'] as num).toInt();
      addRow(
        supplierId: supplierId,
        supplierNama: '${row['supplier_nama_snapshot']}',
        tanggal: '${row['posted_at']}',
        amount: (row['sisa'] as num?)?.toInt() ?? 0,
      );
    }
    final result = groups.values.toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    return result;
  }

  /// Jatuh tempo H-3 dan yang sudah lewat. Log disimpan agar pengingat yang
  /// sama tidak tampil berulang pada hari yang sama.
  Future<List<Map<String, Object?>>> dueReminders() async {
    final db = AppDatabase.instance.db;
    final today = DateTime.now();
    final dueDate = dateOnly.format(today);
    final soon = dateOnly.format(today.add(const Duration(days: 3)));
    final rows = await db.query(
      'supplier_purchases',
      where: "deleted_at IS NULL AND status = 'AKTIF' AND sisa_utang > 0 "
          "AND jatuh_tempo IS NOT NULL AND jatuh_tempo <= ?",
      whereArgs: [soon],
      orderBy: 'jatuh_tempo',
    );
    final reminders = <Map<String, Object?>>[];
    for (final row in rows) {
      final due = '${row['jatuh_tempo']}';
      final level = due.compareTo(dueDate) < 0 ? 'LEWAT' : 'H3';
      final existing = await db.query(
        'debt_reminder_logs',
        columns: ['id'],
        where: 'purchase_sync_id = ? AND level = ? AND due_date = ?',
        whereArgs: [row['sync_id'], level, due],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      await db.insert('debt_reminder_logs', {
        'purchase_sync_id': row['sync_id'],
        'level': level,
        'due_date': due,
        'shown_at': nowIso(),
      });
      reminders.add({...row, 'level': level});
    }
    return reminders;
  }

  Future<Map<String, int>> purchaseTotals() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      volumeQuery,
      [_storeId],
    );
    final row = rows.first;
    final opening = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT COALESCE(SUM(nominal_cents - terbayar_cents), 0) AS total
      FROM opening_payables
      WHERE store_id = ? AND status <> 'VOID' AND deleted_at IS NULL
      ''',
      [_storeId],
    );
    final openingDebt = (opening.first['total'] as num?)?.toInt() ?? 0;
    final purchaseDebt = (row['total_utang'] as num?)?.toInt() ?? 0;
    return {
      'total_pembelian': (row['total_pembelian'] as num?)?.toInt() ?? 0,
      'total_utang': purchaseDebt,
      'total_utang_awal': openingDebt,
      'total_utang_semua': purchaseDebt + openingDebt,
      'total_dibayar': (row['total_dibayar'] as num?)?.toInt() ?? 0,
      'jumlah_nota': (row['jumlah_nota'] as num?)?.toInt() ?? 0,
    };
  }

  /// Margin per barang memakai snapshot modal pada baris nota, bukan modal
  /// master yang bisa berubah setelah transaksi.
  Future<List<Map<String, Object?>>> marginReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final start = isoStartOfDay(from ?? DateTime(2000));
    final end = isoEndOfDay(to ?? DateTime(2100));
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT
        sp.stock_sync_id,
        sp.stock_item_id,
        sp.nama_part,
        SUM(sp.jumlah_milli - sp.qty_retur_milli) AS qty_milli,
        ${AppDatabase.roundDivideSql(
          'SUM((sp.jumlah_milli - sp.qty_retur_milli) * sp.harga_final)',
          '1000',
        )} AS pendapatan,
        ${AppDatabase.roundDivideSql(
          'SUM((sp.jumlah_milli - sp.qty_retur_milli) * sp.harga_modal)',
          '1000',
        )} AS hpp,
        ${AppDatabase.roundDivideSql(
          'SUM((sp.jumlah_milli - sp.qty_retur_milli) * '
              '(sp.harga_final - sp.harga_modal))',
          '1000',
        )} AS margin
      FROM service_parts sp
      JOIN service_records r ON r.id = sp.service_record_id
      WHERE r.deleted_at IS NULL AND r.status = 'AKTIF'
        AND sp.deleted_at IS NULL
        AND r.waktu_service BETWEEN ? AND ?
      GROUP BY sp.stock_sync_id, sp.stock_item_id, sp.nama_part
      ORDER BY margin DESC
      ''',
      [start, end],
    );
  }

  Future<List<Map<String, Object?>>> stockValuation() async {
    return AppDatabase.instance.db.rawQuery(
      '''
      SELECT s.id, s.nama, s.satuan, s.jumlah_milli,
        COALESCE(c.hpp_rata_milli, s.harga_modal, 0) AS hpp_satuan,
        ${AppDatabase.roundDivideSql(
          's.jumlah_milli * COALESCE(c.hpp_rata_milli, s.harga_modal, 0)',
          '1000',
        )} AS nilai_persediaan
      FROM stock_items s
      LEFT JOIN stock_cost_state c
        ON c.stock_sync_id = s.sync_id AND c.store_id = ?
      WHERE s.deleted_at IS NULL
      ORDER BY nilai_persediaan DESC
      ''',
      [_storeId],
    );
  }

  static const volumeQuery = '''
    SELECT
      COALESCE(SUM(CASE WHEN status = 'AKTIF' THEN total ELSE 0 END), 0)
        AS total_pembelian,
      COALESCE(SUM(CASE WHEN status = 'AKTIF' THEN sisa_utang ELSE 0 END), 0)
        AS total_utang,
      COALESCE(SUM(CASE WHEN status = 'AKTIF' THEN total_dibayar ELSE 0 END), 0)
        AS total_dibayar,
      COUNT(CASE WHEN status = 'AKTIF' THEN 1 END) AS jumlah_nota
    FROM supplier_purchases
    WHERE deleted_at IS NULL AND store_id = ?
  ''';

  /// Penerapan pembelian dari perangkat lain. Stok masuk, HPP, kas DP, dan
  /// utang dihitung ulang di perangkat ini dari payload yang sama sehingga
  /// hasil akhirnya identik tanpa bergantung pada amplop pergerakan stok.
  Future<void> applyPurchaseRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
    required String action,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final existing = await txn.query(
      'supplier_purchases',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      if (action == 'void' && '${existing.first['status']}' == 'AKTIF') {
        await _applyPurchaseVoidRemote(
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
        'Pembatalan pembelian menunggu nota asal diterapkan.',
        code: 'pembelian_butuh_induk',
      );
    }
    final supplierSync = '${payload['supplier_sync_id'] ?? ''}';
    final supplierNama = '${payload['supplier_nama_snapshot'] ?? ''}'.trim();
    var supplierId = 0;
    if (supplierSync.isNotEmpty) {
      final supplierRows = await txn.query(
        'suppliers',
        columns: ['id'],
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [supplierSync],
        limit: 1,
      );
      if (supplierRows.isNotEmpty) {
        supplierId = supplierRows.first['id'] as int;
      } else {
        supplierId = await txn.insert('suppliers', {
          'sync_id': supplierSync,
          'store_id': '${payload['store_id'] ?? _storeId}',
          'device_id': '${payload['device_id'] ?? ''}',
          'nama': supplierNama.isEmpty ? 'Supplier' : supplierNama,
          'aktif': 1,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': nowIso(),
        });
      }
    }
    if (supplierId == 0) {
      await _conflict(
        txn,
        entity: 'supplier_purchase',
        entityId: syncId,
        reason: 'pembelian_tanpa_supplier',
        detail: {'error': 'supplier_sync_id kosong'},
      );
      return;
    }
    var noPembelian = '${payload['no_pembelian'] ?? ''}'.trim();
    if (noPembelian.isEmpty) noPembelian = 'PB-$syncId';
    final clash = await txn.query(
      'supplier_purchases',
      columns: ['id'],
      where: 'store_id = ? AND no_pembelian = ? AND deleted_at IS NULL',
      whereArgs: ['${payload['store_id'] ?? _storeId}', noPembelian],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      final asal = noPembelian;
      noPembelian = '$asal-${syncId.substring(syncId.length - 4)}';
      await _conflict(
        txn,
        entity: 'supplier_purchase',
        entityId: syncId,
        reason: 'no_pembelian_bentrok',
        detail: {'no_pembelian_asal': asal, 'no_pembelian_baru': noPembelian},
      );
    }
    final items = (payload['items'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    final now = nowIso();
    final purchaseId = await txn.insert('supplier_purchases', {
      'sync_id': syncId,
      'store_id': '${payload['store_id'] ?? _storeId}',
      'device_id': '${payload['device_id'] ?? ''}',
      'origin_device_id': '${payload['origin_device_id'] ?? ''}',
      'no_pembelian': noPembelian,
      'request_id': '${payload['request_id'] ?? syncId}',
      'supplier_id': supplierId,
      'supplier_sync_id': supplierSync,
      'supplier_nama_snapshot':
          supplierNama.isEmpty ? 'Supplier' : supplierNama,
      'tanggal': '${payload['tanggal'] ?? dateOnly.format(DateTime.now())}',
      'jatuh_tempo': payload['jatuh_tempo'],
      'termin_hari': (payload['termin_hari'] as num?)?.toInt() ?? 0,
      'jenis_bayar': '${payload['jenis_bayar'] ?? 'KREDIT'}',
      'status': 'AKTIF',
      'subtotal': (payload['subtotal'] as num?)?.toInt() ?? 0,
      'diskon': (payload['diskon'] as num?)?.toInt() ?? 0,
      'ongkir': (payload['ongkir'] as num?)?.toInt() ?? 0,
      'ppn': (payload['ppn'] as num?)?.toInt() ?? 0,
      'total': (payload['total'] as num?)?.toInt() ?? 0,
      'total_dibayar': 0,
      'sisa_utang': (payload['total'] as num?)?.toInt() ?? 0,
      'catatan': _clean('${payload['catatan'] ?? ''}'),
      'created_by': payload['created_by'],
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': payload['created_at'] ?? now,
      'updated_at': payload['updated_at'] ?? now,
    });
    for (final item in items) {
      final itemSync = '${item['sync_id'] ?? ''}';
      if (itemSync.isEmpty) continue;
      final stockSync = '${item['stock_sync_id'] ?? ''}';
      final stockRows = await txn.query(
        'stock_items',
        columns: ['id', 'sync_id', 'nama'],
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [stockSync],
        limit: 1,
      );
      if (stockRows.isEmpty) {
        throw RetryableSyncException(
          'Pembelian menunggu barang ($stockSync).',
          code: 'pembelian_tanpa_barang',
        );
      }
      final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      if (qty <= 0) continue;
      final hargaPokok =
          (item['harga_pokok_satuan'] as num?)?.toInt() ??
          (item['harga_satuan'] as num?)?.toInt() ??
          0;
      await txn.insert('supplier_purchase_items', {
        'sync_id': itemSync,
        'store_id': '${payload['store_id'] ?? _storeId}',
        'device_id': '${payload['device_id'] ?? ''}',
        'purchase_id': purchaseId,
        'stock_item_id': stockRows.first['id'],
        'stock_sync_id': stockSync,
        'nama_snapshot': item['nama_snapshot'] ?? stockRows.first['nama'],
        'satuan': item['satuan'] ?? 'pcs',
        'jumlah_milli': qty,
        'harga_satuan': (item['harga_satuan'] as num?)?.toInt() ?? 0,
        'subtotal': (item['subtotal'] as num?)?.toInt() ?? 0,
        'diskon_alokasi': (item['diskon_alokasi'] as num?)?.toInt() ?? 0,
        'ongkir_alokasi': (item['ongkir_alokasi'] as num?)?.toInt() ?? 0,
        'harga_pokok_satuan': hargaPokok,
        'qty_retur_milli': 0,
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'created_at': payload['created_at'] ?? now,
        'updated_at': now,
      });
      await _applyStockIn(
        txn,
        stockItemId: stockRows.first['id'] as int,
        stockSyncId: stockSync,
        nama: '${stockRows.first['nama']}',
        qtyMilli: qty,
        hargaPokokSatuan: hargaPokok,
        sumberSyncId: itemSync,
        alasan: 'Pembelian $noPembelian',
        operator: '${payload['created_by'] ?? 'Perangkat lain'}',
        hlcWall: wall,
        hlcCounter: counter,
      );
    }
    final payments = (payload['payments'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    for (final payment in payments) {
      await applyPaymentRemote(txn, {
        ...payment,
        'purchase_sync_id': syncId,
      }, wall: wall, counter: counter);
    }
    await _recalculateTotals(txn, purchaseId);
  }

  Future<void> applyPaymentRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final existing = await txn.query(
      'supplier_payments',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final requestId = '${payload['request_id'] ?? ''}'.trim();
    if (requestId.isNotEmpty) {
      final sameRequest = await txn.query(
        'supplier_payments',
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (sameRequest.isNotEmpty) return;
    }
    final purchaseSync = '${payload['purchase_sync_id'] ?? ''}';
    final purchases = await txn.query(
      'supplier_purchases',
      where: 'sync_id = ? AND deleted_at IS NULL',
      whereArgs: [purchaseSync],
      limit: 1,
    );
    if (purchases.isEmpty) {
      throw RetryableSyncException(
        'Pembayaran menunggu pembelian ($purchaseSync).',
        code: 'pembayaran_butuh_induk',
      );
    }
    final purchase = purchases.first;
    if ('${purchase['status']}' != 'AKTIF') {
      await _conflict(
        txn,
        entity: 'supplier_payment',
        entityId: syncId,
        reason: 'pembayaran_pada_pembelian_void',
        detail: {'purchase_sync_id': purchaseSync},
      );
      return;
    }
    final nominal = (payload['nominal'] as num?)?.toInt() ?? 0;
    final sisa = (purchase['sisa_utang'] as num?)?.toInt() ?? 0;
    if (nominal <= 0) return;
    final applied = nominal > sisa ? sisa : nominal;
    if (nominal > sisa) {
      await _conflict(
        txn,
        entity: 'supplier_payment',
        entityId: syncId,
        reason: 'pembayaran_melebihi_sisa',
        detail: {'nominal': nominal, 'sisa_utang': sisa, 'diterapkan': applied},
      );
    }
    if (applied <= 0) return;
    final now = nowIso();
    final paymentSyncId = syncId;
    await txn.insert('supplier_payments', {
      'sync_id': paymentSyncId,
      'store_id': '${payload['store_id'] ?? _storeId}',
      'device_id': '${payload['device_id'] ?? ''}',
      'purchase_id': purchase['id'],
      'request_id': requestId.isEmpty ? syncId : requestId,
      'jenis': '${payload['jenis'] ?? 'PELUNASAN'}',
      'metode': '${payload['metode'] ?? 'CASH'}',
      'nominal': applied,
      'waktu': payload['waktu'] ?? now,
      'operator': payload['operator'],
      'catatan': _clean('${payload['catatan'] ?? ''}'),
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': payload['created_at'] ?? now,
      'updated_at': now,
    });
    await _writeCash(
      txn,
      sumberSyncId: paymentSyncId,
      nominal: -applied,
      metode: '${payload['metode'] ?? 'CASH'}',
      kategori: 'BAYAR_UTANG',
      operator: '${payload['operator'] ?? ''}',
      catatan: 'Bayar ${purchase['no_pembelian']}',
      hlcWall: wall,
      hlcCounter: counter,
    );
    await _recalculateTotals(txn, purchase['id'] as int);
  }

  Future<void> applyReturnRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final existing = await txn.query(
      'supplier_purchase_returns',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final row = existing.first;
      if ('${payload['status'] ?? 'AKTIF'}' == 'VOID' &&
          '${row['status']}' == 'AKTIF') {
        await _applyPurchaseReturnVoidRemote(
          txn,
          row,
          payload,
          wall: wall,
          counter: counter,
        );
      }
      return;
    }
    final purchaseSync = '${payload['purchase_sync_id'] ?? ''}';
    final purchases = await txn.query(
      'supplier_purchases',
      where: 'sync_id = ? AND deleted_at IS NULL',
      whereArgs: [purchaseSync],
      limit: 1,
    );
    if (purchases.isEmpty) {
      throw RetryableSyncException(
        'Retur pembelian menunggu pembelian ($purchaseSync).',
        code: 'retur_pembelian_butuh_induk',
      );
    }
    final purchase = purchases.first;
    if ('${purchase['status']}' != 'AKTIF') {
      await _conflict(
        txn,
        entity: 'supplier_purchase_return',
        entityId: syncId,
        reason: 'retur_pembelian_void',
        detail: {'purchase_sync_id': purchaseSync},
      );
      return;
    }
    var noRetur = '${payload['no_retur'] ?? ''}'.trim();
    if (noRetur.isEmpty) noRetur = 'RPB-$syncId';
    final clash = await txn.query(
      'supplier_purchase_returns',
      columns: ['id'],
      where: 'store_id = ? AND no_retur = ? AND deleted_at IS NULL',
      whereArgs: ['${payload['store_id'] ?? _storeId}', noRetur],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      noRetur = '$noRetur-${syncId.substring(syncId.length - 4)}';
    }
    final now = nowIso();
    final returnId = await txn.insert('supplier_purchase_returns', {
      'sync_id': syncId,
      'store_id': '${payload['store_id'] ?? _storeId}',
      'device_id': '${payload['device_id'] ?? ''}',
      'origin_device_id': '${payload['origin_device_id'] ?? ''}',
      'purchase_id': purchase['id'],
      'purchase_sync_id': purchaseSync,
      'no_retur': noRetur,
      'request_id': '${payload['request_id'] ?? syncId}',
      'status': 'AKTIF',
      'total': 0,
      'total_modal_kembali': 0,
      'total_kas_kembali': 0,
      'metode_refund': '${payload['metode_refund'] ?? 'CASH'}',
      'dpp_cents': 0,
      'ppn_cents': 0,
      'total_ditagih_cents': 0,
      'alasan': '${payload['alasan'] ?? 'Retur pembelian'}',
      'dibuat_oleh': payload['dibuat_oleh'],
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': payload['created_at'] ?? now,
      'updated_at': now,
    });
    var totalDpp = 0;
    var totalPpn = 0;
    final purchasePpn = (purchase['ppn'] as num?)?.toInt() ?? 0;
    final purchaseBase =
        ((purchase['total'] as num?)?.toInt() ?? 0) - purchasePpn;
    final items = (payload['items'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    for (final item in items) {
      final itemSync = '${item['sync_id'] ?? ''}';
      final purchaseItemSync = '${item['purchase_item_sync_id'] ?? ''}';
      final itemRows = await txn.query(
        'supplier_purchase_items',
        where: 'purchase_id = ? AND sync_id = ? AND deleted_at IS NULL',
        whereArgs: [purchase['id'], purchaseItemSync],
        limit: 1,
      );
      if (itemRows.isEmpty) {
        await _conflict(
          txn,
          entity: 'supplier_purchase_return',
          entityId: syncId,
          reason: 'retur_pembelian_melebihi_qty',
          detail: {'purchase_item_sync_id': purchaseItemSync},
        );
        continue;
      }
      final purchaseItem = itemRows.first;
      var qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      final purchased = (purchaseItem['jumlah_milli'] as num).toInt();
      final returned =
          (purchaseItem['qty_retur_milli'] as num?)?.toInt() ?? 0;
      if (qty <= 0) continue;
      if (returned + qty > purchased) {
        qty = purchased - returned;
        await _conflict(
          txn,
          entity: 'supplier_purchase_return',
          entityId: syncId,
          reason: 'retur_pembelian_melebihi_qty',
          detail: {
            'purchase_item_sync_id': purchaseItemSync,
            'diminta_milli': (item['jumlah_milli'] as num?)?.toInt() ?? 0,
            'diterapkan_milli': qty,
          },
        );
      }
      if (qty <= 0) continue;
      final stockRows = await txn.query(
        'stock_items',
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [purchaseItem['stock_sync_id']],
        limit: 1,
      );
      if (stockRows.isEmpty) {
        throw RetryableSyncException(
          'Retur pembelian menunggu barang.',
          code: 'retur_pembelian_tanpa_barang',
        );
      }
      final stock = stockRows.first;
      final available = (stock['jumlah_milli'] as num?)?.toInt() ?? 0;
      var appliedQty = qty;
      if (available < qty) {
        appliedQty = available < 0 ? 0 : available;
        await _conflict(
          txn,
          entity: 'supplier_purchase_return',
          entityId: syncId,
          reason: 'stok_negatif',
          detail: {
            'stock_sync_id': stock['sync_id'],
            'diminta_milli': qty,
            'tersedia_milli': available,
            'diterapkan_milli': appliedQty,
          },
        );
      }
      if (appliedQty <= 0) continue;
      final harga =
          (item['harga_satuan'] as num?)?.toInt() ??
          (purchaseItem['harga_satuan'] as num?)?.toInt() ??
          0;
      final modal =
          (item['harga_pokok_satuan'] as num?)?.toInt() ??
          (item['modal_satuan'] as num?)?.toInt() ??
          (purchaseItem['harga_pokok_satuan'] as num?)?.toInt() ??
          0;
      final subtotal = _mulDiv(appliedQty, modal, 1000);
      final ppn = purchaseBase <= 0
          ? 0
          : _mulDiv(subtotal, purchasePpn, purchaseBase);
      totalDpp += subtotal;
      totalPpn += ppn;
      await txn.insert('supplier_purchase_return_items', {
        'sync_id': itemSync.isEmpty ? newSyncId() : itemSync,
        'store_id': '${payload['store_id'] ?? _storeId}',
        'device_id': '${payload['device_id'] ?? ''}',
        'return_id': returnId,
        'purchase_item_id': purchaseItem['id'],
        'purchase_item_sync_id': purchaseItemSync,
        'nama_snapshot': item['nama_snapshot'],
        'jumlah_milli': appliedQty,
        'harga_satuan': harga,
        'subtotal': subtotal + ppn,
        'modal_satuan': modal,
        'harga_pokok_satuan': modal,
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'created_at': payload['created_at'] ?? now,
        'updated_at': now,
      });
      await txn.update(
        'supplier_purchase_items',
        {
          'qty_retur_milli': returned + appliedQty,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [purchaseItem['id']],
      );
      await _applyStockOut(
        txn,
        stockItemId: stock['id'] as int,
        stockSyncId: '${stock['sync_id']}',
        nama: '${stock['nama']}',
        qtyMilli: appliedQty,
        sumberSyncId: itemSync,
        alasan: 'Retur pembelian $noRetur',
        operator: '${payload['dibuat_oleh'] ?? 'Perangkat lain'}',
        hlcWall: wall,
        hlcCounter: counter,
      );
    }
    final totalDitagih = totalDpp + totalPpn;
    await txn.update(
      'supplier_purchase_returns',
      {
        'total': totalDitagih,
        'total_modal_kembali': totalDpp,
        'dpp_cents': totalDpp,
        'ppn_cents': totalPpn,
        'total_ditagih_cents': totalDitagih,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [returnId],
    );
    final refundMethod =
        '${payload['metode_refund'] ?? 'CASH'}'.toUpperCase() == 'TRANSFER'
        ? 'TRANSFER'
        : 'CASH';
    final previousRefund =
        (purchase['refund_accumulated_cents'] as num?)?.toInt() ?? 0;
    final targetRefund = await _recalculateTotals(txn, purchase['id'] as int);
    final refund = targetRefund > previousRefund
        ? targetRefund - previousRefund
        : 0;
    if (refund > 0) {
      await txn.update(
        'supplier_purchase_returns',
        {'total_kas_kembali': refund, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [returnId],
      );
      await txn.update(
        'supplier_purchases',
        {
          'refund_accumulated_cents': previousRefund + refund,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [purchase['id']],
      );
      await _writeCash(
        txn,
        sumberSyncId: syncId,
        nominal: refund,
        metode: refundMethod,
        kategori: 'RETUR_PEMBELIAN',
        operator: '${payload['dibuat_oleh'] ?? ''}',
        catatan: 'Retur $noRetur',
        hlcWall: wall,
        hlcCounter: counter,
        sumberEntity: 'supplier_purchase_return',
      );
    }
  }

  Future<void> _applyPurchaseReturnVoidRemote(
    DatabaseExecutor txn,
    Map<String, Object?> retur,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final returnId = retur['id'] as int;
    final purchaseRows = await txn.query(
      'supplier_purchases',
      where: 'id = ?',
      whereArgs: [retur['purchase_id']],
      limit: 1,
    );
    if (purchaseRows.isEmpty) return;
    final purchase = purchaseRows.first;
    final now = nowIso();
    final kasKembali = (retur['total_kas_kembali'] as num?)?.toInt() ?? 0;
    final items = await txn.query(
      'supplier_purchase_return_items',
      where: 'return_id = ? AND deleted_at IS NULL',
      whereArgs: [returnId],
    );
    for (final item in items) {
      final purchaseItemRows = await txn.query(
        'supplier_purchase_items',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [item['purchase_item_id']],
        limit: 1,
      );
      if (purchaseItemRows.isEmpty) continue;
      final purchaseItem = purchaseItemRows.first;
      final qty = (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      final returned =
          (purchaseItem['qty_retur_milli'] as num?)?.toInt() ?? 0;
      final next = returned - qty;
      await txn.update(
        'supplier_purchase_items',
        {'qty_retur_milli': next < 0 ? 0 : next, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [purchaseItem['id']],
      );
      final stockRows = await txn.query(
        'stock_items',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [purchaseItem['stock_item_id']],
        limit: 1,
      );
      if (stockRows.isEmpty) continue;
      final stock = stockRows.first;
      await _applyStockIn(
        txn,
        stockItemId: stock['id'] as int,
        stockSyncId: '${stock['sync_id']}',
        nama: '${stock['nama']}',
        qtyMilli: qty,
        hargaPokokSatuan: (item['harga_pokok_satuan'] as num?)?.toInt() ??
            (item['modal_satuan'] as num?)?.toInt() ??
            0,
        sumberSyncId: '${item['sync_id']}',
        alasan: 'Reversal retur ${retur['no_retur']}',
        operator: '${payload['voided_by'] ?? payload['dibuat_oleh'] ?? ''}',
        hlcWall: wall,
        hlcCounter: counter,
        sumberEntity: 'retur_pembelian_reversal',
      );
    }
    await txn.update(
      'supplier_purchase_returns',
      {
        'status': 'VOID',
        'void_reason': '${payload['void_reason'] ?? 'Reversal retur'}',
        'voided_at': payload['voided_at'] ?? now,
        'voided_by': payload['voided_by'] ?? payload['dibuat_oleh'],
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [returnId],
    );
    final previousRefund =
        (purchase['refund_accumulated_cents'] as num?)?.toInt() ?? 0;
    final remaining = previousRefund - kasKembali;
    await txn.update(
      'supplier_purchases',
      {
        'refund_accumulated_cents': remaining < 0 ? 0 : remaining,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [purchase['id']],
    );
    if (kasKembali > 0) {
      await _writeCash(
        txn,
        sumberSyncId: '${retur['sync_id']}',
        nominal: -kasKembali,
        metode: '${retur['metode_refund'] ?? 'CASH'}',
        kategori: 'REVERSAL_RETUR_PEMBELIAN',
        operator: '${payload['voided_by'] ?? ''}',
        catatan: 'Reversal retur ${retur['no_retur']}',
        hlcWall: wall,
        hlcCounter: counter,
        sumberEntity: 'purchase_return_reversal',
      );
    }
    await _recalculateTotals(txn, purchase['id'] as int);
  }

  Future<void> _applyPurchaseVoidRemote(
    DatabaseExecutor txn,
    Map<String, Object?> purchase,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final purchaseId = purchase['id'] as int;
    final purchaseSync = '${purchase['sync_id']}';
    final paidRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM supplier_payments '
      'WHERE purchase_id = ? AND deleted_at IS NULL AND voided_at IS NULL',
      [purchaseId],
    );
    final paid = (paidRows.first['total'] as num?)?.toInt() ?? 0;
    final returnRows = await txn.query(
      'supplier_purchase_returns',
      columns: ['id'],
      where: "purchase_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
      whereArgs: [purchaseId],
      limit: 1,
    );
    final items = await txn.query(
      'supplier_purchase_items',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [purchaseId],
    );
    var stockOk = true;
    for (final item in items) {
      final stockRows = await txn.query(
        'stock_items',
        columns: ['jumlah_milli'],
        where: 'sync_id = ? AND deleted_at IS NULL',
        whereArgs: [item['stock_sync_id']],
        limit: 1,
      );
      if (stockRows.isEmpty) {
        stockOk = false;
        break;
      }
      final available = (stockRows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
      if (available < ((item['jumlah_milli'] as num?)?.toInt() ?? 0)) {
        stockOk = false;
        break;
      }
    }
    if (paid > 0 || returnRows.isNotEmpty || !stockOk) {
      await _conflict(
        txn,
        entity: 'supplier_purchase',
        entityId: purchaseSync,
        reason: 'pembelian_void_final',
        detail: {
          'total_dibayar': paid,
          'ada_retur': returnRows.isNotEmpty,
          'stok_cukup': stockOk,
        },
      );
      return;
    }
    final now = nowIso();
    for (final item in items) {
      final stockRows = await txn.query(
        'stock_items',
        where: 'sync_id = ?',
        whereArgs: [item['stock_sync_id']],
        limit: 1,
      );
      final stock = stockRows.first;
      await _applyStockOut(
        txn,
        stockItemId: stock['id'] as int,
        stockSyncId: '${stock['sync_id']}',
        nama: '${stock['nama']}',
        qtyMilli: (item['jumlah_milli'] as num).toInt(),
        sumberSyncId: '${item['sync_id']}',
        alasan: 'Pembatalan ${purchase['no_pembelian']}',
        operator: '${payload['voided_by'] ?? 'Perangkat lain'}',
        hlcWall: wall,
        hlcCounter: counter,
        sumberEntity: 'pembelian_void_item',
      );
    }
    await txn.update(
      'supplier_purchases',
      {
        'status': 'VOID',
        'sisa_utang': 0,
        'void_reason': payload['void_reason'],
        'voided_at': payload['voided_at'] ?? now,
        'voided_by': payload['voided_by'],
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [purchaseId],
    );
  }

  Future<void> _conflict(
    DatabaseExecutor txn, {
    required String entity,
    required String entityId,
    required String reason,
    required Map<String, Object?> detail,
  }) async {
    final existing = await txn.query(
      'sync_conflicts',
      columns: ['id'],
      where: "entity = ? AND entity_id = ? AND reason = ? "
          "AND status IN ('open', 'review')",
      whereArgs: [entity, entityId, reason],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await txn.update(
        'sync_conflicts',
        {'detail_json': jsonEncode(detail)},
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return;
    }
    await txn.insert('sync_conflicts', {
      'entity': entity,
      'entity_id': entityId,
      'reason': reason,
      'detail_json': jsonEncode(detail),
      'status': 'review',
      'retry_count': 0,
      'last_error': '',
      'created_at': nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _applyStockIn(
    DatabaseExecutor txn, {
    required int stockItemId,
    required String stockSyncId,
    required String nama,
    required int qtyMilli,
    required int hargaPokokSatuan,
    required String sumberSyncId,
    required String alasan,
    required String operator,
    required int hlcWall,
    required int hlcCounter,
    String sumberEntity = 'pembelian_item',
  }) async {
    await StockLedger.instance.apply(
      txn,
      stockItemId: stockItemId,
      stockSyncId: stockSyncId,
      jenis: 'MASUK',
      deltaMilli: qtyMilli,
      unitCostCents: hargaPokokSatuan,
      sumberEntity: sumberEntity,
      sumberSyncId: sumberSyncId,
      namaItem: nama,
      alasan: alasan,
      operator: operator,
      storeId: _storeId,
      hlcWall: hlcWall,
      hlcCounter: hlcCounter,
    );
  }

  Future<void> _applyStockOut(
    DatabaseExecutor txn, {
    required int stockItemId,
    required String stockSyncId,
    required String nama,
    required int qtyMilli,
    required String sumberSyncId,
    required String alasan,
    required String operator,
    required int hlcWall,
    required int hlcCounter,
    String sumberEntity = 'retur_pembelian_item',
  }) async {
    await StockLedger.instance.apply(
      txn,
      stockItemId: stockItemId,
      stockSyncId: stockSyncId,
      jenis: 'KELUAR',
      deltaMilli: -qtyMilli,
      sumberEntity: sumberEntity,
      sumberSyncId: sumberSyncId,
      namaItem: nama,
      alasan: alasan,
      operator: operator,
      storeId: _storeId,
      hlcWall: hlcWall,
      hlcCounter: hlcCounter,
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

  Future<void> _writeCash(
    DatabaseExecutor txn, {
    required String sumberSyncId,
    required int nominal,
    required String metode,
    required String kategori,
    required String operator,
    required String catatan,
    required int hlcWall,
    required int hlcCounter,
    String sumberEntity = 'supplier_payment',
  }) async {
    final now = nowIso();
    await txn.insert('cash_ledger', {
      'sync_id': newSyncId(),
      'store_id': _storeId,
      'waktu': now,
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
    });
  }

  Future<String> _resolveRefundMethod(
    DatabaseExecutor txn,
    int purchaseId,
    String? requested,
  ) async {
    final explicit = (requested ?? '').trim().toUpperCase();
    if (explicit.isNotEmpty) {
      if (explicit != 'CASH' && explicit != 'TRANSFER') {
        throw ArgumentError('Metode refund tidak valid.');
      }
      return explicit;
    }
    final rows = await txn.query(
      'supplier_payments',
      columns: ['metode'],
      where: 'purchase_id = ? AND deleted_at IS NULL AND voided_at IS NULL '
          'AND nominal > 0',
      whereArgs: [purchaseId],
      orderBy: 'waktu DESC, id DESC',
      limit: 1,
    );
    final metode =
        rows.isEmpty ? 'CASH' : '${rows.first['metode']}'.toUpperCase();
    return metode == 'TRANSFER' ? 'TRANSFER' : 'CASH';
  }

  Future<int> _recalculateTotals(DatabaseExecutor txn, int purchaseId) async {
    final purchaseRows = await txn.query(
      'supplier_purchases',
      columns: ['total'],
      where: 'id = ?',
      whereArgs: [purchaseId],
      limit: 1,
    );
    if (purchaseRows.isEmpty) return 0;
    final total = (purchaseRows.first['total'] as num?)?.toInt() ?? 0;
    final paidRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM supplier_payments '
      'WHERE purchase_id = ? AND deleted_at IS NULL AND voided_at IS NULL',
      [purchaseId],
    );
    final returnRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(total), 0) AS total FROM supplier_purchase_returns '
      "WHERE purchase_id = ? AND status = 'AKTIF' AND deleted_at IS NULL",
      [purchaseId],
    );
    final paid = (paidRows.first['total'] as num?)?.toInt() ?? 0;
    final retur = (returnRows.first['total'] as num?)?.toInt() ?? 0;
    final net = total - retur;
    final sisa = (net - paid) < 0 ? 0 : net - paid;
    final refund = (paid - net) < 0 ? 0 : paid - net;
    await txn.update(
      'supplier_purchases',
      {
        'total_dibayar': paid,
        'sisa_utang': sisa,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [purchaseId],
    );
    return refund;
  }

  void _allocateCosts(
    List<Map<String, Object?>> lines, {
    required int diskon,
    required int ongkir,
    required int subtotal,
  }) {
    var remainingDiskon = diskon;
    var remainingOngkir = ongkir;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final lineSubtotal = line['subtotal'] as int;
      final last = index == lines.length - 1;
      final diskonAlokasi = last || subtotal == 0
          ? remainingDiskon
          : _mulDiv(diskon, lineSubtotal, subtotal);
      final ongkirAlokasi = last || subtotal == 0
          ? remainingOngkir
          : _mulDiv(ongkir, lineSubtotal, subtotal);
      remainingDiskon -= diskonAlokasi;
      remainingOngkir -= ongkirAlokasi;
      line['diskon_alokasi'] = diskonAlokasi;
      line['ongkir_alokasi'] = ongkirAlokasi;
      line['harga_pokok_satuan'] = _mulDiv(
        lineSubtotal - diskonAlokasi + ongkirAlokasi,
        1000,
        line['qty'] as int,
      );
    }
  }

  Future<String> _nextNumber(
    DatabaseExecutor txn, {
    required String docType,
    required String prefix,
    required DateTime tanggal,
  }) async {
    final device = await AppDatabase.instance.deviceCode(txn);
    final key = dateOnly.format(tanggal);
    final rows = await txn.query(
      'document_counters',
      where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
      whereArgs: [device, docType, key],
      limit: 1,
    );
    final next = rows.isEmpty ? 1 : ((rows.first['terakhir'] as num).toInt() + 1);
    final number = '$prefix-$device-${next.toString().padLeft(4, '0')}';
    if (rows.isEmpty) {
      await txn.insert('document_counters', {
        'device_id': device,
        'doc_type': docType,
        'tanggal': key,
        'terakhir': next,
        'last_no': number,
      });
    } else {
      await txn.update(
        'document_counters',
        {'terakhir': next, 'last_no': number},
        where: 'device_id = ? AND doc_type = ? AND tanggal = ?',
        whereArgs: [device, docType, key],
      );
    }
    return number;
  }

  static int _mulDiv(int value, int multiplier, int divisor) {
    if (divisor == 0) return 0;
    final numerator = BigInt.from(value) * BigInt.from(multiplier);
    final result = (numerator + BigInt.from(divisor ~/ 2)) ~/
        BigInt.from(divisor);
    return result.toInt();
  }

  static String? _clean(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
