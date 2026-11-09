import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/quantity.dart';
import '../sync/sync_conflict_rules.dart';
import 'app_database.dart';
import 'models.dart';

extension NoteSyncDatabase on AppDatabase {
  Future<Map<String, Object?>> noteSyncPayload(
    int id, {
    DatabaseExecutor? executor,
  }) async {
    final target = executor ?? db;
    final rows = await target.rawQuery(
      '''
      SELECT r.*, c.sync_id AS customer_sync_id, c.nama AS customer_nama,
        c.nomor_hp AS customer_hp, c.alamat AS customer_alamat,
        c.wa_consent AS customer_wa_consent,
        c.do_not_contact AS customer_do_not_contact,
        c.created_at AS customer_created_at,
        u.sync_id AS unit_sync_id, u.unit_type, u.nopol, u.merek, u.tipe,
        u.jenis_mobil, u.tahun_mobil, u.no_rangka, u.no_mesin, u.km_terakhir,
        u.tipe_radiator, u.label_radiator,
        u.created_at AS unit_created_at
      FROM service_records r
      LEFT JOIN vehicle_or_units u ON u.id = r.unit_id
      LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)
      WHERE r.id = ? LIMIT 1
      ''',
      [id],
    );
    if (rows.isEmpty) throw StateError('Nota tidak ditemukan.');
    final row = rows.first;
    final jobs = await target.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final parts = await target.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final payments = await target.query(
      'service_payments',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final returnRows = await target.query(
      'sale_returns',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
    final mechanicRows = await target.query(
      'service_record_mechanics',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'urutan',
    );
    final returnPayloads = <Map<String, Object?>>[];
    for (final retur in returnRows) {
      final items = await target.query(
        'sale_return_items',
        where: 'return_id = ? AND deleted_at IS NULL',
        whereArgs: [retur['id']],
      );
      final itemPayloads = <Map<String, Object?>>[];
      for (final item in items) {
        String? stockSync;
        final stockId = item['stock_item_id'] as int?;
        if (stockId != null) {
          final stock = await target.query(
            'stock_items',
            columns: ['sync_id'],
            where: 'id = ?',
            whereArgs: [stockId],
            limit: 1,
          );
          if (stock.isNotEmpty) {
            stockSync = stock.first['sync_id'] as String?;
          }
        }
        itemPayloads.add({
          'sync_id': item['sync_id'],
          'line_type': item['line_type'],
          'line_sync_id': item['line_sync_id'],
          'deskripsi': item['deskripsi'],
          'jumlah': item['jumlah'],
          'jumlah_milli': item['jumlah_milli'] ??
              ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000,
          'qty_asal_milli': item['qty_asal_milli'],
          'harga_satuan': item['harga_satuan'],
          'subtotal': item['subtotal'],
          'modal_satuan': item['modal_satuan'] ?? 0,
          'stock_sync_id': stockSync,
        });
      }
      returnPayloads.add({
        'sync_id': retur['sync_id'],
        'request_id': retur['request_id'],
        'no_retur': retur['no_retur'],
        'status': retur['status'] ?? 'AKTIF',
        'total': retur['total'],
        'total_refund': retur['total_refund'] ?? 0,
        'alasan': retur['alasan'],
        'dibuat_oleh': retur['dibuat_oleh'],
        'created_at': retur['created_at'],
        'items': itemPayloads,
      });
    }
    final partPayloads = <Map<String, Object?>>[];
    for (final part in parts) {
      final stockId = part['stock_item_id'] as int?;
      Map<String, Object?>? stock;
      if (stockId != null) {
        final stockRows = await target.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [stockId],
          limit: 1,
        );
        if (stockRows.isNotEmpty) {
          final stockRow = stockRows.first;
          stock = {
            'sync_id': stockRow['sync_id'],
            'kode': stockRow['kode'],
            'nama': stockRow['nama'],
            'harga_modal': stockRow['harga_modal'],
            'harga_jual': stockRow['harga_jual'],
            'jumlah': stockRow['jumlah'],
            'jumlah_milli': stockRow['jumlah_milli'],
            'satuan': stockRow['satuan'] ?? 'pcs',
            'desimal': stockRow['desimal'] ?? 0,
            'stok_minimum': stockRow['stok_minimum'],
          };
        }
      }
      partPayloads.add({
        'sync_id': part['sync_id'] ?? newSyncId(),
        'stock_sync_id': stock?['sync_id'],
        'nama_part': part['nama_part'],
        'jumlah': part['jumlah'],
        'jumlah_milli': part['jumlah_milli'] ??
            ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000,
        'harga_satuan': part['harga_satuan'],
        'subtotal': part['subtotal'],
        'harga_modal': part['harga_modal'],
        'harga_jual_terdaftar': part['harga_jual_terdaftar'] ?? 0,
        'harga_batas_saat_transaksi':
            part['harga_batas_saat_transaksi'] ?? part['harga_modal'] ?? 0,
        'harga_final': part['harga_final'] ?? part['harga_satuan'] ?? 0,
        'diskon_alokasi': part['diskon_alokasi'] ?? 0,
        'alasan_diskon': part['alasan_diskon'],
        'disetujui_oleh': part['disetujui_oleh'],
        'interval_servis_bulan': part['interval_servis_bulan'] ?? 0,
        'stock': stock,
      });
    }
    return {
      'customer': row['customer_sync_id'] == null
          ? <String, Object?>{}
          : {
              'sync_id': row['customer_sync_id'],
              'nama': row['customer_nama'],
              'nomor_hp': row['customer_hp'],
              'alamat': row['customer_alamat'],
              'wa_consent': row['customer_wa_consent'] ?? 1,
              'do_not_contact': row['customer_do_not_contact'] ?? 0,
              'created_at': row['customer_created_at'],
            },
      'unit': row['unit_sync_id'] == null
          ? <String, Object?>{}
          : {
              'sync_id': row['unit_sync_id'],
              'customer_sync_id': row['customer_sync_id'],
              'unit_type': row['unit_type'],
              'nopol': row['nopol'],
              'merek': row['merek'],
              'tipe': row['tipe'],
              'jenis_mobil': row['jenis_mobil'],
              'tahun_mobil': row['tahun_mobil'],
              'no_rangka': row['no_rangka'],
              'no_mesin': row['no_mesin'],
              'km_terakhir': row['km_terakhir'],
              'tipe_radiator': row['tipe_radiator'],
              'label_radiator': row['label_radiator'],
              'created_at': row['unit_created_at'],
            },
      'record': {
        'sync_id': row['sync_id'],
        'no_nota': row['no_nota'],
        'jenis_transaksi': row['jenis_transaksi'] ?? 'servis_langsung',
        'mode_saat_dibuat_json': row['mode_saat_dibuat_json'] ?? '{}',
        'diskon_snapshot_json': row['diskon_snapshot_json'] ?? '{}',
        'pajak_snapshot_json': row['pajak_snapshot_json'] ?? '{}',
        'work_order_sync_id': row['work_order_sync_id'],
        'estimate_sync_id': row['estimate_sync_id'],
        'total_estimasi_terakhir': row['total_estimasi_terakhir'],
        'waktu_service': row['waktu_service'],
        'keluhan_awal': row['keluhan_awal'],
        'catatan_pengerjaan': row['catatan_pengerjaan'],
        'biaya_jasa': row['biaya_jasa'],
        'total_part': row['total_part'],
        'diskon': row['diskon'],
        'total_servis': row['total_servis'],
        'total_koreksi': row['total_koreksi'],
        'total_retur': row['total_retur'],
        'total_efektif': row['total_efektif'],
        'total_kas_diterima': row['total_kas_diterima'],
        'metode_bayar': row['metode_bayar'],
        'bayar': row['bayar'],
        'kembalian': row['kembalian'],
        'status_bayar': row['status_bayar'],
        'jenis_bayar': row['jenis_bayar'],
        'total_dibayar': row['total_dibayar'],
        'sisa_bayar': row['sisa_bayar'],
        'jatuh_tempo': row['jatuh_tempo'],
        'status': row['status'],
        'void_reason': row['void_reason'],
        'voided_at': row['voided_at'],
        'void_refund': row['void_refund'],
        'bergaransi': row['bergaransi'],
        'garansi_bulan': row['garansi_bulan'],
        'garansi_sampai': row['garansi_sampai'],
        'catatan_garansi': row['catatan_garansi'],
        'status_klaim': row['status_klaim'],
        'tanggal_klaim': row['tanggal_klaim'],
        'sparepart_only': row['sparepart_only'],
        'garansi_barang_aktif': row['garansi_barang_aktif'],
        'garansi_barang_nilai': row['garansi_barang_nilai'],
        'garansi_barang_satuan': row['garansi_barang_satuan'],
        'garansi_barang_sampai': row['garansi_barang_sampai'],
        'unit_ditinggal': row['unit_ditinggal'],
        'diambil_at': row['diambil_at'],
        'created_by': row['created_by'],
        'created_by_employee_id': row['created_by_employee_id'],
        'mechanic': row['mechanic'],
        'mechanic_employee_id': row['mechanic_employee_id'],
        'commission_snapshot_json': row['commission_snapshot_json'] ?? '{}',
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
      'jobs': jobs
          .map(
            (job) => {
              'sync_id': job['sync_id'] ?? newSyncId(),
              'harga_jasa_id': job['harga_jasa_id'],
              'deskripsi': job['deskripsi'],
              'jumlah': job['jumlah'],
              'harga': job['harga'],
              'subtotal': job['subtotal'],
              'harga_jual_terdaftar': job['harga_jual_terdaftar'] ?? 0,
              'harga_batas_saat_transaksi':
                  job['harga_batas_saat_transaksi'] ?? 0,
              'harga_final': job['harga_final'] ?? job['harga'] ?? 0,
              'diskon_alokasi': job['diskon_alokasi'] ?? 0,
              'alasan_diskon': job['alasan_diskon'],
              'disetujui_oleh': job['disetujui_oleh'],
              'interval_servis_bulan': job['interval_servis_bulan'] ?? 0,
            },
          )
          .toList(),
      'parts': partPayloads,
      'payments': payments
          .map(
            (payment) => {
              'sync_id': payment['sync_id'] ?? newSyncId(),
              'jenis': payment['jenis'],
              'metode': payment['metode'],
              'nominal': payment['nominal'],
              'waktu': payment['waktu'],
              'operator': payment['operator'],
              'request_id': payment['request_id'],
              'catatan': payment['catatan'],
            },
          )
          .toList(),
      'returns': returnPayloads,
      'mechanics': mechanicRows
          .map(
            (mechanic) => {
              'sync_id': mechanic['sync_id'] ?? newSyncId(),
              'employee_sync_id': mechanic['employee_sync_id'],
              'employee_nama_snapshot': mechanic['employee_nama_snapshot'],
              'peran': mechanic['peran'],
              'urutan': mechanic['urutan'] ?? 0,
            },
          )
          .toList(),
    };
  }

  Future<String> applyNotePayload(
    Database target,
    Map<String, Object?> payload, {
    required String action,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) {
    return target.transaction(
      (txn) => applyNotePayloadTx(
        txn,
        payload,
        action: action,
        enqueueCommission: enqueueCommission,
      ),
    );
  }

  Future<String> applyNotePayloadTx(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required String action,
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
    enqueueCommission,
  }) async {
    final record = Map<String, Object?>.from(
      payload['record'] as Map? ?? const {},
    );
    final customer = Map<String, Object?>.from(
      payload['customer'] as Map? ?? const {},
    );
    final unit = Map<String, Object?>.from(payload['unit'] as Map? ?? const {});
    final jobs = (payload['jobs'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final parts = (payload['parts'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final payments = (payload['payments'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final returns = (payload['returns'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final mechanics = (payload['mechanics'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final recordSync = record['sync_id'] as String? ?? '';
    if (recordSync.isEmpty) throw StateError('Nota tanpa sync_id.');
    final existingRecord = await txn.query(
      'service_records',
      where: 'sync_id = ?',
      whereArgs: [recordSync],
      limit: 1,
    );
    if (action == 'void') {
      if (existingRecord.isEmpty) {
        throw RetryableSyncException(
          'Pembatalan nota menunggu nota asal diterapkan.',
          code: 'nota_butuh_induk',
        );
      }
      if (existingRecord.first['voided_at'] != null) return 'duplicate';
      final reason =
          record['void_reason'] as String? ?? 'Void dari perangkat lain';
      // Retur yang sudah aktif di perangkat ini dapat membuat refund void
      // melebihi uang yang benar-benar diterima. Perubahan tetap diterapkan
      // agar sama dengan perangkat asal, tetapi pemilik wajib meninjaunya.
      final activeReturns = await txn.query(
        'sale_returns',
        columns: ['id'],
        where: "service_record_id = ? AND deleted_at IS NULL "
            "AND status = 'AKTIF'",
        whereArgs: [existingRecord.first['id']],
      );
      if (activeReturns.isNotEmpty) {
        await _recordPendingConflict(
          txn,
          entity: 'nota',
          entityId: recordSync,
          reason: 'void_setelah_retur',
          detail: {
            'no_nota': existingRecord.first['no_nota'],
            'retur_aktif': activeReturns.length,
            'void_refund': record['void_refund'] ?? 0,
          },
        );
      }
      for (final part in parts) {
        final stockSync = part['stock_sync_id'] as String? ?? '';
        if (stockSync.isEmpty) continue;
        final stock = await txn.query(
          'stock_items',
          where: 'sync_id = ?',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stock.isEmpty) continue;
        final movementKey = 'void-${part['sync_id']}';
        final movement = await txn.query(
          'stock_movements',
          where: 'sync_id = ?',
          whereArgs: [movementKey],
          limit: 1,
        );
        if (movement.isNotEmpty) continue;
        final qtyMilli = (part['jumlah_milli'] as num?)?.toInt() ??
            ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        final partSync = part['sync_id'] as String? ?? '';
        var returnedMilli = 0;
        if (partSync.isNotEmpty) {
          final returned = await txn.rawQuery(
            '''
SELECT COALESCE(SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000)), 0)
  AS total
FROM sale_return_items ri
JOIN sale_returns sr ON sr.id = ri.return_id
WHERE sr.service_record_id = ? AND sr.deleted_at IS NULL
  AND ri.deleted_at IS NULL AND ri.line_type = 'part'
  AND ri.line_sync_id = ?
''',
            [existingRecord.first['id'], partSync],
          );
          returnedMilli = (returned.first['total'] as num?)?.toInt() ?? 0;
        }
        final restockMilli = qtyMilli - returnedMilli;
        if (restockMilli <= 0) continue;
        final before = StockItem.fromRow(stock.first);
        final nextMilli = before.jumlahMilli + restockMilli;
        final stockHlc = await nextSyncHlc(txn);
        await txn.update(
          'stock_items',
          {
            'jumlah': wholeQuantity(nextMilli),
            'jumlah_milli': nextMilli,
            'sync_hlc_wall': stockHlc.wall,
            'sync_hlc_counter': stockHlc.counter,
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [stock.first['id']],
        );
        await txn.insert('stock_movements', {
          'sync_id': movementKey,
          'stock_item_id': stock.first['id'],
          'stock_sync_id': stock.first['sync_id'],
          'nama_item': part['nama_part'],
          'jenis': 'MASUK',
          'jumlah': wholeQuantity(restockMilli),
          'jumlah_milli': restockMilli,
          'stok_sebelum_milli': before.jumlahMilli,
          'stok_sesudah_milli': nextMilli,
          'sumber_entity': 'void',
          'sumber_sync_id': partSync,
          'alasan': 'Void $recordSync',
          'service_record_id': existingRecord.first['id'],
          'sync_hlc_wall': stockHlc.wall,
          'sync_hlc_counter': stockHlc.counter,
          'created_at': nowIso(),
          'updated_at': nowIso(),
        });
      }
      // Komisi pada nota VOID tidak boleh tetap aktif. Tandai lokal agar
      // laporan komisi konsisten meski amplop komisi belum/tidak diterima.
      final commissionRows = await txn.query(
        'service_record_commissions',
        columns: ['id'],
        where: "service_record_id = ? AND status = 'AKTIF'",
        whereArgs: [existingRecord.first['id']],
      );
      for (final commission in commissionRows) {
        await txn.update(
          'service_record_commissions',
          {
            'status': 'VOID',
            'nominal': 0,
            'voided_at': nowIso(),
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [commission['id']],
        );
      }
      // Void membawa seluruh pembayaran (termasuk refund) agar perangkat
      // penerima langsung konsisten meski amplop pembayaran tertunda.
      for (final payment in payments) {
        await _upsertPayment(txn, existingRecord.first['id'] as int, payment);
      }
      // Refund dihitung sekali oleh perangkat yang melakukan void; perangkat
      // lain menerapkan baris refund yang sama secara idempoten sehingga kas
      // tidak tercatat dua kali.
      await txn.update(
        'service_records',
        {
          'status': 'VOID',
          'void_reason': reason,
          'voided_at': record['voided_at'] ?? nowIso(),
          'sisa_bayar': 0,
          'total_efektif': 0,
          'total_kas_diterima': 0,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [existingRecord.first['id']],
      );
      // Ringkasan pembayaran tetap mengikuti ledger agar perangkat ini sama
      // dengan asal void meski amplop pembayaran terpisah belum diterima.
      await _syncVoidTotals(txn, existingRecord.first['id'] as int);
      return 'void';
    }
    if (action == 'payment') {
      if (existingRecord.isEmpty) {
        throw RetryableSyncException(
          'Pembayaran menunggu nota asal diterapkan.',
          code: 'nota_butuh_induk',
        );
      }
      final recordVoid = existingRecord.first['voided_at'] != null ||
          '${existingRecord.first['status']}' == 'VOID';
      for (final payment in payments) {
        // Nota VOID bersifat terminal; hanya refund yang boleh menyusul.
        if (recordVoid && '${payment['jenis'] ?? ''}' != 'REFUND') continue;
        await _upsertPayment(txn, existingRecord.first['id'] as int, payment);
      }
      if (recordVoid) {
        await _syncVoidTotals(txn, existingRecord.first['id'] as int);
      } else {
        await _recalculateRecordTotals(txn, existingRecord.first['id'] as int);
      }
      return 'payment';
    }
    if (action == 'warranty') {
      if (existingRecord.isEmpty) {
        throw RetryableSyncException(
          'Klaim garansi menunggu nota asal diterapkan.',
          code: 'nota_butuh_induk',
        );
      }
      await _applyPostSaleFields(
        txn,
        existingRecord.first,
        record,
        warranty: true,
        taken: false,
      );
      return 'warranty';
    }
    if (action == 'taken') {
      if (existingRecord.isEmpty) {
        throw RetryableSyncException(
          'Status pengambilan unit menunggu nota asal diterapkan.',
          code: 'nota_butuh_induk',
        );
      }
      await _applyPostSaleFields(
        txn,
        existingRecord.first,
        record,
        warranty: false,
        taken: true,
      );
      return 'taken';
    }
    if (existingRecord.isNotEmpty) {
      // Nota final tidak ditulis ulang. Hanya nomor nota koreksi, pembayaran
      // tambahan, dan status pasca-jual (garansi, unit diambil) yang boleh
      // menyusul.
      await _syncCommissionSnapshot(
        txn,
        existingRecord.first['id'] as int,
        record,
        mechanics,
      );
      var changed = false;
      // Penggabungan pelanggan di perangkat lain hanya bisa diterapkan lewat
      // referensi nota. Hanya referensi yang menunjuk pelanggan terhapus yang
      // diperbaiki agar nilai final nota tetap tidak ditulis ulang.
      final incomingCustomerSync = '${customer['sync_id'] ?? ''}';
      if (incomingCustomerSync.isNotEmpty) {
        final localCustomerId = existingRecord.first['customer_id'] as int?;
        var needsRepair = localCustomerId == null;
        if (localCustomerId != null) {
          final localCustomer = await txn.query(
            'customers',
            columns: ['deleted_at'],
            where: 'id = ?',
            whereArgs: [localCustomerId],
            limit: 1,
          );
          needsRepair = localCustomer.isEmpty ||
              localCustomer.first['deleted_at'] != null;
        }
        if (needsRepair) {
          final targetCustomer = await txn.query(
            'customers',
            columns: ['id'],
            where: 'sync_id = ? AND deleted_at IS NULL',
            whereArgs: [incomingCustomerSync],
            limit: 1,
          );
          if (targetCustomer.isNotEmpty &&
              targetCustomer.first['id'] != localCustomerId) {
            await txn.update(
              'service_records',
              {
                'customer_id': targetCustomer.first['id'],
                'updated_at': nowIso(),
              },
              where: 'id = ?',
              whereArgs: [existingRecord.first['id']],
            );
            existingRecord.first['customer_id'] = targetCustomer.first['id'];
            changed = true;
          }
        }
      }
      final incomingNoNota = '${record['no_nota'] ?? ''}'.trim();
      final localNoNota = '${existingRecord.first['no_nota'] ?? ''}';
      if (incomingNoNota.isNotEmpty && incomingNoNota != localNoNota) {
        final used = await txn.query(
          'service_records',
          columns: ['id'],
          where: 'no_nota = ? AND sync_id != ?',
          whereArgs: [incomingNoNota, recordSync],
          limit: 1,
        );
        if (used.isEmpty) {
          await txn.update(
            'service_records',
            {'no_nota': incomingNoNota, 'updated_at': nowIso()},
            where: 'sync_id = ?',
            whereArgs: [recordSync],
          );
          existingRecord.first['no_nota'] = incomingNoNota;
          changed = true;
        } else {
          final next = await allocateNextNota(txn);
          await txn.update(
            'service_records',
            {'no_nota': next, 'updated_at': nowIso()},
            where: 'sync_id = ?',
            whereArgs: [recordSync],
          );
          existingRecord.first['no_nota'] = next;
          await _recordPendingConflict(
            txn,
            entity: 'nota',
            entityId: recordSync,
            reason: 'no_nota_bentrok',
            detail: {
              'no_nota_asal': incomingNoNota,
              'no_nota_baru': next,
            },
          );
          changed = true;
        }
      }
      changed = changed ||
          await _applyPostSaleFields(
            txn,
            existingRecord.first,
            record,
            warranty: true,
            taken: true,
          );
      // Retur divalidasi lebih dulu: refund tunai hanya boleh ikut bila retur
      // yang menjadi dasarnya diterima.
      var returnAdded = false;
      final rejectedReturnSyncs = <String>{};
      for (final retur in returns) {
        final result = await _upsertReturn(
          txn,
          existingRecord.first['id'] as int,
          recordSync,
          retur,
        );
        returnAdded = returnAdded || result == 'added';
        if (result == 'rejected') {
          rejectedReturnSyncs.add('${retur['sync_id'] ?? ''}');
        }
      }
      var paymentAdded = false;
      final localVoid = existingRecord.first['voided_at'] != null ||
          '${existingRecord.first['status']}' == 'VOID';
      for (final payment in payments) {
        if (localVoid && '${payment['jenis'] ?? ''}' != 'REFUND') {
          continue;
        }
        final requestId = '${payment['request_id'] ?? ''}';
        if (requestId.isNotEmpty &&
            rejectedReturnSyncs.any((sync) => requestId == 'retur-$sync')) {
          continue;
        }
        final inserted = await _upsertPayment(
          txn,
          existingRecord.first['id'] as int,
          payment,
        );
        paymentAdded = paymentAdded || inserted;
      }
      changed = changed || returnAdded || paymentAdded;
      if (returnAdded || paymentAdded) {
        if (localVoid) {
          await _syncVoidTotals(txn, existingRecord.first['id'] as int);
        } else {
          await _recalculateRecordTotals(
            txn,
            existingRecord.first['id'] as int,
          );
        }
      }
      if (returnAdded) {
        // Tarif komisi memakai snapshot nota yang ikut dikirim, bukan tarif
        // master perangkat ini.
        await AppDatabase.instance.recalculateRecordCommissions(
          txn,
          existingRecord.first['id'] as int,
          enqueueCommission: enqueueCommission,
        );
      }
      return changed ? 'updated' : 'duplicate';
    }
    final customerSync = customer['sync_id'] as String? ?? '';
    int? customerId;
    if (customerSync.isNotEmpty) {
      final customerRows = await txn.query(
        'customers',
        where: 'sync_id = ?',
        whereArgs: [customerSync],
        limit: 1,
      );
      if (customerRows.isEmpty) {
        customerId = await txn.insert('customers', {
          'sync_id': customerSync,
          'nama': customer['nama'] ?? '',
          'nomor_hp': customer['nomor_hp'] ?? '',
          'alamat': customer['alamat'],
          'wa_consent': customer['wa_consent'] ?? 1,
          'do_not_contact': customer['do_not_contact'] ?? 0,
          'created_at': customer['created_at'] ?? nowIso(),
          'updated_at': nowIso(),
        });
      } else {
        customerId = customerRows.first['id'] as int;
        // Data master yang sudah ada tidak ditimpa snapshot nota yang lebih
        // lama; hanya kolom kosong yang diisi.
        final fill = <String, Object?>{};
        for (final key in const [
          'nama',
          'nomor_hp',
          'alamat',
          'wa_consent',
          'do_not_contact',
        ]) {
          final current = customerRows.first[key];
          final incoming = customer[key];
          if ((current == null || '$current'.isEmpty) && incoming != null) {
            fill[key] = incoming;
          }
        }
        if (fill.isNotEmpty) {
          await txn.update(
            'customers',
            fill,
            where: 'id = ?',
            whereArgs: [customerId],
          );
        }
      }
    }
    final unitSync = unit['sync_id'] as String? ?? '';
    int? unitId;
    if (unitSync.isNotEmpty) {
      final unitRows = await txn.query(
        'vehicle_or_units',
        where: 'sync_id = ?',
        whereArgs: [unitSync],
        limit: 1,
      );
      if (unitRows.isEmpty) {
        unitId = await txn.insert('vehicle_or_units', {
          'sync_id': unitSync,
          'customer_id': customerId,
          'unit_type': unit['unit_type'] ?? 'MOBIL',
          'nopol': unit['nopol'],
          'merek': unit['merek'],
          'tipe': unit['tipe'],
          'jenis_mobil': unit['jenis_mobil'],
          'tahun_mobil': unit['tahun_mobil'],
          'no_rangka': unit['no_rangka'],
          'no_mesin': unit['no_mesin'],
          'km_terakhir': unit['km_terakhir'],
          'tipe_radiator': unit['tipe_radiator'],
          'label_radiator': unit['label_radiator'],
          'created_at': unit['created_at'] ?? nowIso(),
          'updated_at': nowIso(),
        });
      } else {
        unitId = unitRows.first['id'] as int;
        final fill = <String, Object?>{};
        for (final key in const [
          'unit_type',
          'nopol',
          'merek',
          'tipe',
          'jenis_mobil',
          'tahun_mobil',
          'no_rangka',
          'no_mesin',
          'km_terakhir',
          'tipe_radiator',
          'label_radiator',
        ]) {
          final current = unitRows.first[key];
          final incoming = unit[key];
          if ((current == null || '$current'.isEmpty) && incoming != null) {
            fill[key] = incoming;
          }
        }
        if (fill.isNotEmpty) {
          await txn.update(
            'vehicle_or_units',
            fill,
            where: 'id = ?',
            whereArgs: [unitId],
          );
        }
      }
    }
    var noNota = record['no_nota'] as String? ?? await allocateNextNota(txn);
    final conflict = await txn.query(
      'service_records',
      columns: ['id'],
      where: 'no_nota = ?',
      whereArgs: [noNota],
      limit: 1,
    );
    if (conflict.isNotEmpty) {
      final noNotaAsal = noNota;
      noNota = await allocateNextNota(txn);
      await _recordPendingConflict(
        txn,
        entity: 'nota',
        entityId: recordSync,
        reason: 'no_nota_bentrok',
        detail: {
          'no_nota_asal': noNotaAsal,
          'no_nota_baru': noNota,
        },
      );
    }
    final incomingVoid =
        record['voided_at'] != null || '${record['status']}' == 'VOID';
    // BD-13: penjualan yang tiba belakangan dan membuat stok negatif
    // dibatalkan otomatis. Nota tetap disimpan sebagai jejak, tetapi stok,
    // kas, piutang, dan komisi tidak boleh terpengaruh.
    var autoCancel = false;
    final shortage = <Map<String, Object?>>[];
    if (!incomingVoid && parts.isNotEmpty) {
      final needed = <String, int>{};
      final names = <String, String>{};
      for (final part in parts) {
        final stockSync = part['stock_sync_id'] as String? ?? '';
        if (stockSync.isEmpty) continue;
        final qtyMilli = (part['jumlah_milli'] as num?)?.toInt() ??
            ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        if (qtyMilli <= 0) continue;
        needed[stockSync] = (needed[stockSync] ?? 0) + qtyMilli;
        names[stockSync] = '${part['nama_part'] ?? ''}';
      }
      for (final entry in needed.entries) {
        final stockRows = await txn.query(
          'stock_items',
          columns: ['jumlah_milli'],
          where: 'sync_id = ?',
          whereArgs: [entry.key],
          limit: 1,
        );
        if (stockRows.isEmpty) continue;
        final available =
            (stockRows.first['jumlah_milli'] as num?)?.toInt() ?? 0;
        if (available < entry.value) {
          shortage.add({
            'stock_sync_id': entry.key,
            'nama_item': names[entry.key],
            'dibutuhkan_milli': entry.value,
            'tersedia_milli': available,
          });
        }
      }
      autoCancel = shortage.isNotEmpty;
    }
    final autoCancelReason = autoCancel
        ? 'Dibatalkan otomatis: stok tidak mencukupi saat nota diterima '
              'dari perangkat lain.'
        : null;
    final recordId = await txn.insert('service_records', {
      'sync_id': recordSync,
      'unit_id': unitId,
      'customer_id': customerId,
      'no_nota': noNota,
      'request_id': null,
      'jenis_transaksi': record['jenis_transaksi'] ?? 'servis_langsung',
      'mode_saat_dibuat_json': record['mode_saat_dibuat_json'] ?? '{}',
      'diskon_snapshot_json': record['diskon_snapshot_json'] ?? '{}',
      'pajak_snapshot_json': record['pajak_snapshot_json'] ?? '{}',
      'work_order_sync_id': record['work_order_sync_id'],
      'estimate_sync_id': record['estimate_sync_id'],
      'total_estimasi_terakhir': record['total_estimasi_terakhir'],
      'waktu_service': record['waktu_service'] ?? nowIso(),
      'keluhan_awal': record['keluhan_awal'] ?? '',
      'catatan_pengerjaan': record['catatan_pengerjaan'],
      'biaya_jasa': record['biaya_jasa'] ?? 0,
      'total_part': record['total_part'] ?? 0,
      'diskon': record['diskon'] ?? 0,
      'total_servis': record['total_servis'] ?? 0,
      'total_koreksi': record['total_koreksi'] ?? 0,
      'total_retur': record['total_retur'] ?? 0,
      'total_efektif': autoCancel
          ? 0
          : record['total_efektif'] ?? record['total_servis'] ?? 0,
      'total_kas_diterima': autoCancel
          ? 0
          : record['total_kas_diterima'] ??
                record['total_dibayar'] ??
                0,
      'commission_snapshot_json': record['commission_snapshot_json'] ?? '{}',
      'metode_bayar': record['metode_bayar'] ?? 'CASH',
      'bayar': record['bayar'] ?? 0,
      'kembalian': record['kembalian'] ?? 0,
      'status_bayar': record['status_bayar'] ?? 'LUNAS',
      'jenis_bayar': record['jenis_bayar'] ?? 'LUNAS',
      'total_dibayar': record['total_dibayar'] ?? 0,
      'sisa_bayar': autoCancel ? 0 : record['sisa_bayar'] ?? 0,
      'jatuh_tempo': record['jatuh_tempo'],
      'status': autoCancel ? 'VOID' : record['status'] ?? 'AKTIF',
      'void_reason': autoCancel ? autoCancelReason : record['void_reason'],
      'voided_at': autoCancel ? nowIso() : record['voided_at'],
      'void_refund': autoCancel ? 0 : record['void_refund'] ?? 0,
      'version': record['version'] ?? 1,
      'bergaransi': record['bergaransi'] ?? 1,
      'garansi_bulan': record['garansi_bulan'] ?? 1,
      'garansi_sampai': record['garansi_sampai'],
      'catatan_garansi': record['catatan_garansi'],
      'status_klaim': record['status_klaim'] ?? 'Belum claim',
      'tanggal_klaim': record['tanggal_klaim'],
      'sparepart_only': record['sparepart_only'] ?? 0,
      'garansi_barang_aktif': record['garansi_barang_aktif'] ?? 0,
      'garansi_barang_nilai': record['garansi_barang_nilai'] ?? 0,
      'garansi_barang_satuan': record['garansi_barang_satuan'] ?? 'HARI',
      'garansi_barang_sampai': record['garansi_barang_sampai'],
      'unit_ditinggal': record['unit_ditinggal'] ?? 0,
      'diambil_at': record['diambil_at'],
      'created_by': record['created_by'],
      'created_by_employee_id': record['created_by_employee_id'],
      'mechanic': record['mechanic'],
      'mechanic_employee_id': record['mechanic_employee_id'],
      'created_at': record['created_at'] ?? nowIso(),
      'updated_at': record['updated_at'] ?? nowIso(),
    });
    await _syncCommissionSnapshot(txn, recordId, record, mechanics);
    for (final job in jobs) {
      await txn.insert('service_jobs', {
        'sync_id': job['sync_id'] ?? newSyncId(),
        'service_record_id': recordId,
        'harga_jasa_id': job['harga_jasa_id'],
        'deskripsi': job['deskripsi'] ?? '',
        'jumlah': job['jumlah'] ?? 0,
        'harga': job['harga'] ?? 0,
        'subtotal': job['subtotal'] ?? 0,
        'harga_jual_terdaftar': job['harga_jual_terdaftar'] ?? 0,
        'harga_batas_saat_transaksi': job['harga_batas_saat_transaksi'] ?? 0,
        'harga_final': job['harga_final'] ?? job['harga'] ?? 0,
        'diskon_alokasi': job['diskon_alokasi'] ?? 0,
        'alasan_diskon': job['alasan_diskon'],
        'disetujui_oleh': job['disetujui_oleh'],
        'interval_servis_bulan': job['interval_servis_bulan'] ?? 0,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
    }
    for (final part in parts) {
      final stock = part['stock'] as Map?;
      final stockSync =
          part['stock_sync_id'] as String? ??
          (stock?['sync_id'] as String?) ??
          '';
      int? stockId;
      if (!autoCancel && stockSync.isNotEmpty) {
        final stockRows = await txn.query(
          'stock_items',
          where: 'sync_id = ?',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stockRows.isEmpty) {
          final postSale =
              (stock?['jumlah_milli'] as num?)?.toInt() ??
              ((stock?['jumlah'] as num?)?.toInt() ?? 0) * 1000;
          final qtyMilli = (part['jumlah_milli'] as num?)?.toInt() ??
              ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000;
          stockId = await txn.insert('stock_items', {
            'sync_id': stockSync,
            'kode': stock?['kode'] ?? stockSync,
            'nama': stock?['nama'] ?? part['nama_part'],
            'harga_modal': stock?['harga_modal'] ?? 0,
            'harga_jual': stock?['harga_jual'] ?? 0,
            'jumlah': wholeQuantity(postSale + qtyMilli),
            'jumlah_milli': postSale + qtyMilli,
            'satuan': stock?['satuan'] ?? 'pcs',
            'desimal': stock?['desimal'] ?? 0,
            'stok_minimum': stock?['stok_minimum'] ?? 0,
            'created_at': nowIso(),
            'updated_at': nowIso(),
          });
        } else {
          stockId = stockRows.first['id'] as int;
        }
        final movementKey = 'sale-${part['sync_id']}';
        final movement = await txn.query(
          'stock_movements',
          where: 'sync_id = ?',
          whereArgs: [movementKey],
          limit: 1,
        );
        if (movement.isEmpty) {
          final qtyMilli = (part['jumlah_milli'] as num?)?.toInt() ??
              ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000;
          final current = await txn.query(
            'stock_items',
            where: 'id = ?',
            whereArgs: [stockId],
            limit: 1,
          );
          final before = StockItem.fromRow(current.first);
          final nextMilli = before.jumlahMilli - qtyMilli;
          final stockHlc = await nextSyncHlc(txn);
          await txn.update(
            'stock_items',
            {
              'jumlah': wholeQuantity(nextMilli),
              'jumlah_milli': nextMilli,
              'sync_hlc_wall': stockHlc.wall,
              'sync_hlc_counter': stockHlc.counter,
              'updated_at': nowIso(),
            },
            where: 'id = ?',
            whereArgs: [stockId],
          );
          await txn.insert('stock_movements', {
            'sync_id': movementKey,
            'stock_item_id': stockId,
            'stock_sync_id': stockSync,
            'nama_item': part['nama_part'],
            'jenis': 'KELUAR',
            'jumlah': wholeQuantity(-qtyMilli),
            'jumlah_milli': -qtyMilli,
            'stok_sebelum_milli': before.jumlahMilli,
            'stok_sesudah_milli': nextMilli,
            'sumber_entity': 'service_part',
            'sumber_sync_id': part['sync_id'],
            'alasan': 'Penjualan ${record['no_nota']}',
            'service_record_id': recordId,
            'sync_hlc_wall': stockHlc.wall,
            'sync_hlc_counter': stockHlc.counter,
            'created_at': nowIso(),
            'updated_at': nowIso(),
          });
          if (nextMilli < 0) {
            await _recordPendingConflict(
              txn,
              entity: 'stock',
              entityId: stockSync,
              reason: 'stok_negatif',
              detail: {
                'no_nota': noNota,
                'record_sync_id': recordSync,
                'stock_sync_id': stockSync,
                'nama_item': part['nama_part'],
                'stok_sebelum_milli': before.jumlahMilli,
                'stok_sesudah_milli': nextMilli,
                'sumber_entity': 'service_part',
              },
            );
          }
        }
      }
      await txn.insert('service_parts', {
        'sync_id': part['sync_id'] ?? newSyncId(),
        'service_record_id': recordId,
        'stock_item_id': stockId,
        'nama_part': part['nama_part'] ?? '',
        'jumlah': part['jumlah'] ?? 0,
        'jumlah_milli': part['jumlah_milli'] ??
            ((part['jumlah'] as num?)?.toInt() ?? 0) * 1000,
        'harga_satuan': part['harga_satuan'] ?? 0,
        'subtotal': part['subtotal'] ?? 0,
        'harga_modal': part['harga_modal'] ?? 0,
        'harga_jual_terdaftar': part['harga_jual_terdaftar'] ?? 0,
        'harga_batas_saat_transaksi':
            part['harga_batas_saat_transaksi'] ?? part['harga_modal'] ?? 0,
        'harga_final': part['harga_final'] ?? part['harga_satuan'] ?? 0,
        'diskon_alokasi': part['diskon_alokasi'] ?? 0,
        'alasan_diskon': part['alasan_diskon'],
        'disetujui_oleh': part['disetujui_oleh'],
        'interval_servis_bulan': part['interval_servis_bulan'] ?? 0,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
    }
    final rejectedReturnSyncs = <String>{};
    var returnAdded = false;
    if (autoCancel) {
      // Nota batal otomatis tidak boleh menambah kas, piutang, atau retur.
      await _recordPendingConflict(
        txn,
        entity: 'nota',
        entityId: recordSync,
        reason: 'stok_negatif',
        detail: {
          'no_nota': noNota,
          'auto_cancelled': true,
          'kekurangan': shortage,
        },
      );
    } else {
      for (final retur in returns) {
        final result = await _upsertReturn(txn, recordId, recordSync, retur);
        returnAdded = returnAdded || result == 'added';
        if (result == 'rejected') {
          rejectedReturnSyncs.add('${retur['sync_id'] ?? ''}');
        }
      }
      for (final payment in payments) {
        final requestId = '${payment['request_id'] ?? ''}';
        if (requestId.isNotEmpty &&
            rejectedReturnSyncs.any((sync) => requestId == 'retur-$sync')) {
          continue;
        }
        await _upsertPayment(txn, recordId, payment);
      }
    }
    // Nota baru bisa membawa pembayaran/retur sekaligus; ringkasan harus
    // dihitung dari ledger, bukan dari angka yang dikirim perangkat asal.
    if (autoCancel || incomingVoid) {
      await _syncVoidTotals(txn, recordId);
    } else {
      await _recalculateRecordTotals(txn, recordId);
    }
    if (returnAdded) {
      await AppDatabase.instance.recalculateRecordCommissions(
        txn,
        recordId,
        enqueueCommission: enqueueCommission,
      );
    }
    return autoCancel ? 'auto_cancelled' : 'applied';
  }

  /// Mekanik dan snapshot tarif ikut nota agar perangkat lain dapat
  /// merekalkulasi komisi dengan tarif saat nota dibuat.
  Future<void> _syncCommissionSnapshot(
    DatabaseExecutor txn,
    int recordId,
    Map<String, Object?> record,
    List<Map<String, Object?>> mechanics,
  ) async {
    for (final mechanic in mechanics) {
      final employeeSync = '${mechanic['employee_sync_id'] ?? ''}';
      if (employeeSync.isEmpty) continue;
      final existing = await txn.query(
        'service_record_mechanics',
        columns: ['id'],
        where: 'service_record_id = ? AND employee_sync_id = ?',
        whereArgs: [recordId, employeeSync],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      await txn.insert(
        'service_record_mechanics',
        {
          'sync_id': mechanic['sync_id'] ?? newSyncId(),
          'service_record_id': recordId,
          'employee_sync_id': employeeSync,
          'employee_nama_snapshot': mechanic['employee_nama_snapshot'],
          'peran': mechanic['peran'],
          'urutan': mechanic['urutan'] ?? 0,
          'created_at': nowIso(),
          'updated_at': nowIso(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final snapshot = '${record['commission_snapshot_json'] ?? ''}'.trim();
    if (snapshot.isEmpty || snapshot == '{}') return;
    final current = await txn.query(
      'service_records',
      columns: ['commission_snapshot_json'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    final local =
        '${current.isEmpty ? '' : current.first['commission_snapshot_json'] ?? ''}'
            .trim();
    if (local.isNotEmpty && local != '{}') return;
    await txn.update(
      'service_records',
      {'commission_snapshot_json': snapshot},
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  /// Status pasca-jual boleh menyusul tanpa menulis ulang nilai final nota.
  /// Klaim garansi dan waktu pengambilan bersifat monoton: nilai yang sudah
  /// tercatat tidak pernah dikembalikan oleh perangkat yang lebih lama.
  Future<bool> _applyPostSaleFields(
    DatabaseExecutor txn,
    Map<String, Object?> existing,
    Map<String, Object?> record, {
    required bool warranty,
    required bool taken,
  }) async {
    final values = <String, Object?>{};
    if (warranty) {
      final incomingClaim = '${record['status_klaim'] ?? ''}';
      final localClaim = '${existing['status_klaim'] ?? ''}';
      if (incomingClaim == 'Sudah claim' && localClaim != 'Sudah claim') {
        values['status_klaim'] = 'Sudah claim';
        values['tanggal_klaim'] = record['tanggal_klaim'] ?? nowIso();
      }
      if (record['garansi_sampai'] != null &&
          existing['garansi_sampai'] == null) {
        values['bergaransi'] = record['bergaransi'] ?? 1;
        values['garansi_sampai'] = record['garansi_sampai'];
        values['catatan_garansi'] = record['catatan_garansi'];
      }
    }
    if (taken) {
      if (record['diambil_at'] != null && existing['diambil_at'] == null) {
        values['diambil_at'] = record['diambil_at'];
      }
      if ((record['unit_ditinggal'] as num?)?.toInt() == 1 &&
          (existing['unit_ditinggal'] as num?)?.toInt() != 1) {
        values['unit_ditinggal'] = 1;
      }
    }
    if (values.isEmpty) return false;
    values['updated_at'] = nowIso();
    await txn.update(
      'service_records',
      values,
      where: 'id = ?',
      whereArgs: [existing['id']],
    );
    return true;
  }

  Future<bool> _upsertPayment(
    DatabaseExecutor txn,
    int recordId,
    Map<String, Object?> payment,
  ) async {
    final syncId = payment['sync_id'] as String? ?? '';
    final requestId = '${payment['request_id'] ?? ''}'.trim();
    if (syncId.isNotEmpty) {
      final rows = await txn.query(
        'service_payments',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isNotEmpty) return false;
    }
    if (requestId.isNotEmpty) {
      final rows = await txn.query(
        'service_payments',
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (rows.isNotEmpty) return false;
    }
    final paymentSyncId = syncId.isEmpty ? newSyncId() : syncId;
    await txn.insert('service_payments', {
      'sync_id': paymentSyncId,
      'service_record_id': recordId,
      'jenis': payment['jenis'] ?? 'PELUNASAN',
      'metode': payment['metode'] ?? 'CASH',
      'nominal': payment['nominal'] ?? 0,
      'waktu': payment['waktu'] ?? nowIso(),
      'operator': payment['operator'] ?? 'Pemilik',
      'request_id': requestId.isEmpty ? 'sync-$paymentSyncId' : requestId,
      'catatan': payment['catatan'],
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    // Buku kas ikut disamakan agar rekonsiliasi perangkat tidak berbeda.
    await txn.insert(
      'cash_ledger',
      {
        'sync_id': newSyncId(),
        'waktu': payment['waktu'] ?? nowIso(),
        'kategori': '${payment['jenis'] ?? ''}' == 'REFUND'
            ? 'REFUND'
            : 'PENJUALAN',
        'sumber_entity': 'service_payment',
        'sumber_sync_id': paymentSyncId,
        'nominal': payment['nominal'] ?? 0,
        'metode': payment['metode'] ?? 'CASH',
        'operator': payment['operator'],
        'catatan': payment['catatan'],
        'created_at': nowIso(),
        'updated_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return true;
  }

  /// Mengembalikan `added` (retur baru diterapkan), `duplicate` (sudah ada),
  /// atau `rejected` (ditolak karena nota VOID/qty melebihi sisa).
  Future<String> _upsertReturn(
    DatabaseExecutor txn,
    int recordId,
    String recordSync,
    Map<String, Object?> retur,
  ) async {
    final syncId = '${retur['sync_id'] ?? ''}';
    if (syncId.isEmpty) return 'duplicate';
    final requestId = '${retur['request_id'] ?? ''}'.trim();
    final existing = await txn.query(
      'sale_returns',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) return 'duplicate';
    if (requestId.isNotEmpty) {
      final existingRequest = await txn.query(
        'sale_returns',
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (existingRequest.isNotEmpty) return 'duplicate';
    }
    final recordRows = await txn.query(
      'service_records',
      columns: ['no_nota', 'status', 'voided_at'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (recordRows.isEmpty) return 'rejected';
    final recordRow = recordRows.first;
    final noNota = '${recordRow['no_nota'] ?? ''}';
    if (recordRow['voided_at'] != null ||
        '${recordRow['status']}' == 'VOID') {
      await _recordReturnConflict(
        txn,
        returSync: syncId,
        recordSync: recordSync,
        reason: 'retur_pada_nota_void',
        detail: {
          'no_retur': retur['no_retur'],
          'no_nota': noNota,
          'total': retur['total'] ?? 0,
        },
      );
      return 'rejected';
    }
    final items = (retur['items'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    final requested = <String, int>{};
    for (final item in items) {
      final lineType = '${item['line_type'] ?? 'part'}';
      final lineSync = '${item['line_sync_id'] ?? ''}';
      final jumlah = (item['jumlah'] as num?)?.toInt() ?? 0;
      final qtyMilli =
          (item['jumlah_milli'] as num?)?.toInt() ?? jumlah * 1000;
      if (lineSync.isEmpty || qtyMilli <= 0) {
        await _recordReturnConflict(
          txn,
          returSync: syncId,
          recordSync: recordSync,
          reason: 'retur_tidak_valid',
          detail: {
            'no_retur': retur['no_retur'],
            'line_type': lineType,
            'line_sync_id': lineSync,
            'jumlah_milli': qtyMilli,
          },
        );
        return 'rejected';
      }
      final key = '$lineType:$lineSync';
      requested[key] = (requested[key] ?? 0) + qtyMilli;
    }
    final soldByKey = <String, int>{};
    for (final entry in requested.entries) {
      final separator = entry.key.indexOf(':');
      final lineType = entry.key.substring(0, separator);
      final lineSync = entry.key.substring(separator + 1);
      final soldMilli = await _soldMilli(txn, recordId, lineType, lineSync);
      if (soldMilli < 0) {
        await _recordReturnConflict(
          txn,
          returSync: syncId,
          recordSync: recordSync,
          reason: 'retur_baris_tidak_ditemukan',
          detail: {
            'no_retur': retur['no_retur'],
            'line_type': lineType,
            'line_sync_id': lineSync,
          },
        );
        return 'rejected';
      }
      final returnedRows = await txn.rawQuery(
        '''
SELECT COALESCE(SUM(COALESCE(ri.jumlah_milli, ri.jumlah * 1000)), 0)
  AS total
FROM sale_return_items ri
JOIN sale_returns sr ON sr.id = ri.return_id
WHERE sr.service_record_id = ? AND sr.deleted_at IS NULL
  AND ri.deleted_at IS NULL AND ri.line_type = ?
  AND ri.line_sync_id = ?
''',
        [recordId, lineType, lineSync],
      );
      final returned =
          (returnedRows.first['total'] as num?)?.toInt() ?? 0;
      if (returned + entry.value > soldMilli) {
        await _recordReturnConflict(
          txn,
          returSync: syncId,
          recordSync: recordSync,
          reason: 'retur_melebihi_qty',
          detail: {
            'no_retur': retur['no_retur'],
            'line_type': lineType,
            'line_sync_id': lineSync,
            'terjual_milli': soldMilli,
            'sudah_retur_milli': returned,
            'retur_masuk_milli': entry.value,
          },
        );
        return 'rejected';
      }
      soldByKey[entry.key] = soldMilli;
    }
    final createdAt = retur['created_at'] ?? nowIso();
    var modalTotal = 0;
    for (final item in items) {
      final qtyMilli = (item['jumlah_milli'] as num?)?.toInt() ??
          ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000;
      final modal = (item['modal_satuan'] as num?)?.toInt() ?? 0;
      modalTotal += (modal * qtyMilli / 1000).round();
    }
    final total = (retur['total'] as num?)?.toInt() ?? 0;
    final requestedRefund =
        (retur['total_refund'] as num?)?.toInt() ?? 0;
    final totalRefund =
        requestedRefund.clamp(0, total < 0 ? 0 : total).toInt();
    final returnId = await txn.insert('sale_returns', {
      'sync_id': syncId,
      'service_record_id': recordId,
      'nota_sync_id': recordSync,
      'no_nota': noNota,
      'no_retur': retur['no_retur'] ?? '',
      'request_id': requestId.isEmpty ? 'sync-$syncId' : requestId,
      'status': 'AKTIF',
      'total': total,
      'total_modal_kembali': modalTotal,
      'total_refund': totalRefund,
      'alasan': retur['alasan'] ?? 'Retur dari perangkat lain',
      'dibuat_oleh': retur['dibuat_oleh'],
      'created_at': createdAt,
      'updated_at': nowIso(),
    });
    for (final item in items) {
      final jumlah = (item['jumlah'] as num?)?.toInt() ?? 0;
      final qtyMilli = (item['jumlah_milli'] as num?)?.toInt() ??
          jumlah * 1000;
      final lineType = '${item['line_type'] ?? 'part'}';
      final lineSyncId = '${item['line_sync_id'] ?? ''}';
      int? stockId;
      final stockSync = '${item['stock_sync_id'] ?? ''}';
      if (stockSync.isNotEmpty) {
        final stock = await txn.query(
          'stock_items',
          columns: ['id'],
          where: 'sync_id = ?',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stock.isNotEmpty) stockId = stock.first['id'] as int;
      }
      final itemSyncId = '${item['sync_id'] ?? ''}'.isEmpty
          ? newSyncId()
          : '${item['sync_id']}';
      await txn.insert('sale_return_items', {
        'sync_id': itemSyncId,
        'return_id': returnId,
        'line_type': lineType,
        'line_sync_id': lineSyncId,
        'deskripsi': item['deskripsi'] ?? '',
        'jumlah': jumlah,
        'jumlah_milli': qtyMilli,
        'qty_asal_milli': (item['qty_asal_milli'] as num?)?.toInt() ??
            soldByKey['$lineType:$lineSyncId'],
        'harga_satuan': item['harga_satuan'] ?? 0,
        'subtotal': item['subtotal'] ?? 0,
        'modal_satuan': item['modal_satuan'] ?? 0,
        'stock_item_id': stockId,
        'created_at': createdAt,
        'updated_at': nowIso(),
      });
      if (lineSyncId.isNotEmpty) {
        final table = lineType == 'jasa' ? 'service_jobs' : 'service_parts';
        await txn.rawUpdate(
          'UPDATE $table SET qty_retur_milli = qty_retur_milli + ?, '
          'updated_at = ? WHERE sync_id = ?',
          [qtyMilli, nowIso(), lineSyncId],
        );
      }
      if (lineType != 'part' || stockId == null) continue;
      final movementKey = 'retur-$syncId-$itemSyncId';
      final movement = await txn.query(
        'stock_movements',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [movementKey],
        limit: 1,
      );
      if (movement.isNotEmpty) continue;
      final stockRows = await txn.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [stockId],
        limit: 1,
      );
      if (stockRows.isEmpty) continue;
      final before = (stockRows.first['jumlah_milli'] as num?)?.toInt() ??
          ((stockRows.first['jumlah'] as num?)?.toInt() ?? 0) * 1000;
      final nextMilli = before + qtyMilli;
      final stockHlc = await nextSyncHlc(txn);
      await txn.update(
        'stock_items',
        {
          'jumlah': wholeQuantity(nextMilli),
          'jumlah_milli': nextMilli,
          'sync_hlc_wall': stockHlc.wall,
          'sync_hlc_counter': stockHlc.counter,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [stockId],
      );
      await txn.insert('stock_movements', {
        'sync_id': movementKey,
        'stock_item_id': stockId,
        'stock_sync_id': stockRows.first['sync_id'],
        'nama_item': item['deskripsi'] ?? '',
        'jenis': 'MASUK',
        'jumlah': wholeQuantity(qtyMilli),
        'jumlah_milli': qtyMilli,
        'stok_sebelum_milli': before,
        'stok_sesudah_milli': nextMilli,
        'sumber_entity': 'sale_return_item',
        'sumber_sync_id': itemSyncId,
        'alasan': 'Retur $noNota',
        'service_record_id': recordId,
        'sync_hlc_wall': stockHlc.wall,
        'sync_hlc_counter': stockHlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
    }
    return 'added';
  }

  Future<int> _soldMilli(
    DatabaseExecutor txn,
    int recordId,
    String lineType,
    String lineSyncId,
  ) async {
    if (lineSyncId.isEmpty) return -1;
    if (lineType == 'jasa') {
      final rows = await txn.query(
        'service_jobs',
        columns: ['jumlah'],
        where: 'service_record_id = ? AND sync_id = ?',
        whereArgs: [recordId, lineSyncId],
        limit: 1,
      );
      if (rows.isEmpty) return -1;
      return ((rows.first['jumlah'] as num?)?.toInt() ?? 0) * 1000;
    }
    final rows = await txn.query(
      'service_parts',
      columns: ['jumlah', 'jumlah_milli'],
      where: 'service_record_id = ? AND sync_id = ?',
      whereArgs: [recordId, lineSyncId],
      limit: 1,
    );
    if (rows.isEmpty) return -1;
    return (rows.first['jumlah_milli'] as num?)?.toInt() ??
        ((rows.first['jumlah'] as num?)?.toInt() ?? 0) * 1000;
  }

  /// Konflik retur dicatat sekali per retur+alasan; amplop tetap dianggap
  /// diterapkan agar antrean tidak macet menunggu keputusan pemilik.
  Future<void> _recordReturnConflict(
    DatabaseExecutor txn, {
    required String returSync,
    required String recordSync,
    required String reason,
    required Map<String, Object?> detail,
  }) async {
    await _recordPendingConflict(
      txn,
      entity: 'sale_return',
      entityId: returSync,
      reason: reason,
      detail: {'nota_sync_id': recordSync, ...detail},
    );
  }

  /// Satu baris tertunda per entitas+alasan; konflik berulang hanya
  /// memperbarui rinciannya sehingga indeks unik parsial tidak dilanggar.
  Future<void> _recordPendingConflict(
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

  Future<void> _recalculateRecordTotals(
    DatabaseExecutor txn,
    int recordId,
  ) =>
      AppDatabase.instance.recalculateRecordTotals(txn, recordId);

  /// Nota VOID tidak dihitung sebagai piutang, tetapi `total_dibayar` tetap
  /// diselaraskan dengan ledger pembayaran (termasuk refund) supaya laporan
  /// kas dan digest rekonsiliasi sama di semua perangkat.
  Future<void> _syncVoidTotals(
    DatabaseExecutor txn,
    int recordId,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
      'WHERE service_record_id = ?',
      [recordId],
    );
    final paid = (rows.first['total'] as num?)?.toInt() ?? 0;
    await txn.update(
      'service_records',
      {
        'total_dibayar': paid < 0 ? 0 : paid,
        'total_efektif': 0,
        'total_kas_diterima': 0,
        'sisa_bayar': 0,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }
}
