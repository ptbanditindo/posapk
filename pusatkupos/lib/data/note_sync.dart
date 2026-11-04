import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
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
        u.sync_id AS unit_sync_id, u.unit_type, u.nopol, u.jenis_mobil,
        u.tahun_mobil, u.tipe_radiator, u.label_radiator,
        u.created_at AS unit_created_at
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
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
        'harga_satuan': part['harga_satuan'],
        'subtotal': part['subtotal'],
        'harga_modal': part['harga_modal'],
        'stock': stock,
      });
    }
    return {
      'customer': {
        'sync_id': row['customer_sync_id'],
        'nama': row['customer_nama'],
        'nomor_hp': row['customer_hp'],
        'alamat': row['customer_alamat'],
        'wa_consent': row['customer_wa_consent'] ?? 1,
        'do_not_contact': row['customer_do_not_contact'] ?? 0,
        'created_at': row['customer_created_at'],
      },
      'unit': {
        'sync_id': row['unit_sync_id'],
        'customer_sync_id': row['customer_sync_id'],
        'unit_type': row['unit_type'],
        'nopol': row['nopol'],
        'jenis_mobil': row['jenis_mobil'],
        'tahun_mobil': row['tahun_mobil'],
        'tipe_radiator': row['tipe_radiator'],
        'label_radiator': row['label_radiator'],
        'created_at': row['unit_created_at'],
      },
      'record': {
        'sync_id': row['sync_id'],
        'no_nota': row['no_nota'],
        'waktu_service': row['waktu_service'],
        'keluhan_awal': row['keluhan_awal'],
        'catatan_pengerjaan': row['catatan_pengerjaan'],
        'biaya_jasa': row['biaya_jasa'],
        'total_part': row['total_part'],
        'diskon': row['diskon'],
        'total_servis': row['total_servis'],
        'metode_bayar': row['metode_bayar'],
        'bayar': row['bayar'],
        'kembalian': row['kembalian'],
        'status_bayar': row['status_bayar'],
        'jenis_bayar': row['jenis_bayar'],
        'total_dibayar': row['total_dibayar'],
        'sisa_bayar': row['sisa_bayar'],
        'status': row['status'],
        'void_reason': row['void_reason'],
        'voided_at': row['voided_at'],
        'created_by': row['created_by'],
        'created_by_employee_id': row['created_by_employee_id'],
        'mechanic': row['mechanic'],
        'mechanic_employee_id': row['mechanic_employee_id'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
      'jobs': jobs
          .map(
            (job) => {
              'sync_id': job['sync_id'] ?? newSyncId(),
              'deskripsi': job['deskripsi'],
              'jumlah': job['jumlah'],
              'harga': job['harga'],
              'subtotal': job['subtotal'],
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
              'catatan': payment['catatan'],
            },
          )
          .toList(),
    };
  }

  Future<String> applyNotePayload(
    Database target,
    Map<String, Object?> payload, {
    required String action,
  }) {
    return target.transaction(
      (txn) => applyNotePayloadTx(txn, payload, action: action),
    );
  }

  Future<String> applyNotePayloadTx(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required String action,
  }) async {
    final record =
        Map<String, Object?>.from(payload['record'] as Map? ?? const {});
    final customer =
        Map<String, Object?>.from(payload['customer'] as Map? ?? const {});
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
    final recordSync = record['sync_id'] as String? ?? '';
    if (recordSync.isEmpty) throw StateError('Nota tanpa sync_id.');
      final existingRecord = await txn.query(
        'service_records',
        where: 'sync_id = ?',
        whereArgs: [recordSync],
        limit: 1,
      );
      if (action == 'void') {
        if (existingRecord.isEmpty) return 'missing';
        if (existingRecord.first['voided_at'] != null) return 'duplicate';
        final reason =
            record['void_reason'] as String? ?? 'Void dari perangkat lain';
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
          final qtyMilli = (part['jumlah'] as int? ?? 0) * 1000;
          final before = StockItem.fromRow(stock.first);
          final nextMilli = before.jumlahMilli + qtyMilli;
          await txn.update(
            'stock_items',
            {'jumlah': nextMilli ~/ 1000, 'jumlah_milli': nextMilli},
            where: 'id = ?',
            whereArgs: [stock.first['id']],
          );
          await txn.insert('stock_movements', {
            'sync_id': movementKey,
            'stock_item_id': stock.first['id'],
            'nama_item': part['nama_part'],
            'jenis': 'MASUK',
            'jumlah': qtyMilli ~/ 1000,
            'jumlah_milli': qtyMilli,
            'alasan': 'Void $recordSync',
            'service_record_id': existingRecord.first['id'],
            'created_at': nowIso(),
          });
        }
        for (final payment in payments) {
          await _upsertPayment(txn, existingRecord.first['id'] as int, payment);
        }
        await txn.update(
          'service_records',
          {
            'status': 'VOID',
            'void_reason': reason,
            'voided_at': record['voided_at'] ?? nowIso(),
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [existingRecord.first['id']],
        );
        return 'void';
      }
      if (action == 'payment') {
        if (existingRecord.isEmpty) return 'missing';
        for (final payment in payments) {
          await _upsertPayment(txn, existingRecord.first['id'] as int, payment);
        }
        await _recalculateRecordTotals(txn, existingRecord.first['id'] as int);
        return 'payment';
      }
      if (existingRecord.isNotEmpty) return 'duplicate';
      final customerSync = customer['sync_id'] as String? ?? '';
      if (customerSync.isEmpty) throw StateError('Pelanggan tanpa sync_id.');
      final customerRows = await txn.query(
        'customers',
        where: 'sync_id = ?',
        whereArgs: [customerSync],
        limit: 1,
      );
      final int customerId;
      if (customerRows.isEmpty) {
        customerId = await txn.insert('customers', {
          'sync_id': customerSync,
          'nama': customer['nama'] ?? '',
          'nomor_hp': customer['nomor_hp'] ?? '',
          'alamat': customer['alamat'],
          'wa_consent': customer['wa_consent'] ?? 1,
          'do_not_contact': customer['do_not_contact'] ?? 0,
          'created_at': customer['created_at'] ?? nowIso(),
        });
      } else {
        customerId = customerRows.first['id'] as int;
        await txn.update(
          'customers',
          {
            'nama': customer['nama'] ?? customerRows.first['nama'],
            'nomor_hp':
                customer['nomor_hp'] ?? customerRows.first['nomor_hp'],
            'alamat': customer['alamat'] ?? customerRows.first['alamat'],
            'wa_consent':
                customer['wa_consent'] ?? customerRows.first['wa_consent'],
            'do_not_contact': customer['do_not_contact'] ??
                customerRows.first['do_not_contact'],
          },
          where: 'id = ?',
          whereArgs: [customerId],
        );
      }
      final unitSync = unit['sync_id'] as String? ?? '';
      if (unitSync.isEmpty) throw StateError('Unit tanpa sync_id.');
      final unitRows = await txn.query(
        'vehicle_or_units',
        where: 'sync_id = ?',
        whereArgs: [unitSync],
        limit: 1,
      );
      final int unitId;
      if (unitRows.isEmpty) {
        unitId = await txn.insert('vehicle_or_units', {
          'sync_id': unitSync,
          'customer_id': customerId,
          'unit_type': unit['unit_type'] ?? 'MOBIL',
          'nopol': unit['nopol'],
          'jenis_mobil': unit['jenis_mobil'],
          'tahun_mobil': unit['tahun_mobil'],
          'tipe_radiator': unit['tipe_radiator'],
          'label_radiator': unit['label_radiator'],
          'created_at': unit['created_at'] ?? nowIso(),
        });
      } else {
        unitId = unitRows.first['id'] as int;
        await txn.update(
          'vehicle_or_units',
          {
            'customer_id': customerId,
            'unit_type': unit['unit_type'] ?? unitRows.first['unit_type'],
            'nopol': unit['nopol'] ?? unitRows.first['nopol'],
            'jenis_mobil':
                unit['jenis_mobil'] ?? unitRows.first['jenis_mobil'],
            'tahun_mobil':
                unit['tahun_mobil'] ?? unitRows.first['tahun_mobil'],
            'tipe_radiator':
                unit['tipe_radiator'] ?? unitRows.first['tipe_radiator'],
            'label_radiator':
                unit['label_radiator'] ?? unitRows.first['label_radiator'],
          },
          where: 'id = ?',
          whereArgs: [unitId],
        );
      }
      var noNota =
          record['no_nota'] as String? ?? await allocateNextNota(txn);
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
        await txn.insert('sync_conflicts', {
          'entity': 'nota',
          'entity_id': recordSync,
          'reason': 'no_nota_bentrok',
          'detail_json': jsonEncode({
            'no_nota_asal': noNotaAsal,
            'no_nota_baru': noNota,
          }),
          'created_at': nowIso(),
        });
      }
      final recordId = await txn.insert('service_records', {
        'sync_id': recordSync,
        'unit_id': unitId,
        'no_nota': noNota,
        'request_id': null,
        'waktu_service': record['waktu_service'] ?? nowIso(),
        'keluhan_awal': record['keluhan_awal'] ?? '',
        'catatan_pengerjaan': record['catatan_pengerjaan'],
        'biaya_jasa': record['biaya_jasa'] ?? 0,
        'total_part': record['total_part'] ?? 0,
        'diskon': record['diskon'] ?? 0,
        'total_servis': record['total_servis'] ?? 0,
        'metode_bayar': record['metode_bayar'] ?? 'CASH',
        'bayar': record['bayar'] ?? 0,
        'kembalian': record['kembalian'] ?? 0,
        'status_bayar': record['status_bayar'] ?? 'LUNAS',
        'jenis_bayar': record['jenis_bayar'] ?? 'LUNAS',
        'total_dibayar': record['total_dibayar'] ?? 0,
        'sisa_bayar': record['sisa_bayar'] ?? 0,
        'status': record['status'] ?? 'AKTIF',
        'created_by': record['created_by'],
        'created_by_employee_id': record['created_by_employee_id'],
        'mechanic': record['mechanic'],
        'mechanic_employee_id': record['mechanic_employee_id'],
        'created_at': record['created_at'] ?? nowIso(),
        'updated_at': record['updated_at'] ?? nowIso(),
      });
      for (final job in jobs) {
        await txn.insert('service_jobs', {
          'sync_id': job['sync_id'] ?? newSyncId(),
          'service_record_id': recordId,
          'deskripsi': job['deskripsi'] ?? '',
          'jumlah': job['jumlah'] ?? 0,
          'harga': job['harga'] ?? 0,
          'subtotal': job['subtotal'] ?? 0,
        });
      }
      for (final part in parts) {
        final stock = part['stock'] as Map?;
        final stockSync = part['stock_sync_id'] as String? ??
            (stock?['sync_id'] as String?) ??
            '';
        int? stockId;
        if (stockSync.isNotEmpty) {
          final stockRows = await txn.query(
            'stock_items',
            where: 'sync_id = ?',
            whereArgs: [stockSync],
            limit: 1,
          );
          if (stockRows.isEmpty) {
            final postSale = (stock?['jumlah_milli'] as num?)?.toInt() ??
                ((stock?['jumlah'] as num?)?.toInt() ?? 0) * 1000;
            final qtyMilli = (part['jumlah'] as int? ?? 0) * 1000;
            stockId = await txn.insert('stock_items', {
              'sync_id': stockSync,
              'kode': stock?['kode'] ?? stockSync,
              'nama': stock?['nama'] ?? part['nama_part'],
              'harga_modal': stock?['harga_modal'] ?? 0,
              'harga_jual': stock?['harga_jual'] ?? 0,
              'jumlah': (postSale + qtyMilli) ~/ 1000,
              'jumlah_milli': postSale + qtyMilli,
              'satuan': stock?['satuan'] ?? 'pcs',
              'desimal': stock?['desimal'] ?? 0,
              'stok_minimum': stock?['stok_minimum'] ?? 0,
              'created_at': nowIso(),
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
            final qtyMilli = (part['jumlah'] as int? ?? 0) * 1000;
            final current = await txn.query(
              'stock_items',
              where: 'id = ?',
              whereArgs: [stockId],
              limit: 1,
            );
            final before = StockItem.fromRow(current.first);
            final nextMilli = before.jumlahMilli - qtyMilli;
            await txn.update(
              'stock_items',
              {'jumlah': nextMilli ~/ 1000, 'jumlah_milli': nextMilli},
              where: 'id = ?',
              whereArgs: [stockId],
            );
            await txn.insert('stock_movements', {
              'sync_id': movementKey,
              'stock_item_id': stockId,
              'nama_item': part['nama_part'],
              'jenis': 'KELUAR',
              'jumlah': -qtyMilli ~/ 1000,
              'jumlah_milli': -qtyMilli,
              'alasan': 'Penjualan ${record['no_nota']}',
              'service_record_id': recordId,
              'created_at': nowIso(),
            });
            if (nextMilli < 0) {
              await txn.insert('sync_conflicts', {
                'entity': 'stock',
                'entity_id': stockSync,
                'reason': 'stok_negatif',
                'detail_json': jsonEncode({
                  'no_nota': noNota,
                  'stock_sync_id': stockSync,
                  'jumlah_milli': nextMilli,
                }),
                'created_at': nowIso(),
              });
            }
          }
        }
        await txn.insert('service_parts', {
          'sync_id': part['sync_id'] ?? newSyncId(),
          'service_record_id': recordId,
          'stock_item_id': stockId,
          'nama_part': part['nama_part'] ?? '',
          'jumlah': part['jumlah'] ?? 0,
          'harga_satuan': part['harga_satuan'] ?? 0,
          'subtotal': part['subtotal'] ?? 0,
          'harga_modal': part['harga_modal'] ?? 0,
        });
      }
      for (final payment in payments) {
        await _upsertPayment(txn, recordId, payment);
      }
      return 'applied';
  }

  Future<void> _upsertPayment(
    DatabaseExecutor txn,
    int recordId,
    Map<String, Object?> payment,
  ) async {
    final syncId = payment['sync_id'] as String? ?? '';
    if (syncId.isNotEmpty) {
      final rows = await txn.query(
        'service_payments',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isNotEmpty) return;
    }
    await txn.insert('service_payments', {
      'sync_id': syncId.isEmpty ? newSyncId() : syncId,
      'service_record_id': recordId,
      'jenis': payment['jenis'] ?? 'PELUNASAN',
      'metode': payment['metode'] ?? 'CASH',
      'nominal': payment['nominal'] ?? 0,
      'waktu': payment['waktu'] ?? nowIso(),
      'operator': payment['operator'] ?? 'Pemilik',
      'request_id': null,
      'catatan': payment['catatan'],
    });
  }

  Future<void> _recalculateRecordTotals(
    DatabaseExecutor txn,
    int recordId,
  ) async {
    final record = await txn.query(
      'service_records',
      columns: ['total_servis'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (record.isEmpty) return;
    final paidRows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal), 0) AS total FROM service_payments '
      'WHERE service_record_id = ?',
      [recordId],
    );
    final total = record.first['total_servis'] as int? ?? 0;
    final paid = paidRows.first['total'] as int? ?? 0;
    final sisa = total - paid < 0 ? 0 : total - paid;
    await txn.update(
      'service_records',
      {
        'total_dibayar': paid,
        'sisa_bayar': sisa,
        'status_bayar': sisa == 0 ? 'LUNAS' : 'KREDIT',
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }
}
