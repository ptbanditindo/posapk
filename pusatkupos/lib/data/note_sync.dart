import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

extension NoteSyncDatabase on AppDatabase {
  Future<Map<String, Object?>> noteSyncPayload(int id) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.sync_id AS customer_sync_id, c.nama AS customer_nama,
        c.nomor_hp AS customer_hp, c.alamat AS customer_alamat,
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
    final jobs = await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final parts = await db.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final payments = await db.query(
      'service_payments',
      where: 'service_record_id = ?',
      whereArgs: [id],
    );
    final partPayloads = <Map<String, Object?>>[];
    for (final part in parts) {
      final stockId = part['stock_item_id'] as int?;
      Map<String, Object?>? stock;
      if (stockId != null) {
        final stockRows = await db.query(
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
    return target.transaction((txn) async {
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
          final qty = part['jumlah'] as int? ?? 0;
          await txn.rawUpdate(
            'UPDATE stock_items SET jumlah = jumlah + ? WHERE id = ?',
            [qty, stock.first['id']],
          );
          await txn.insert('stock_movements', {
            'sync_id': movementKey,
            'stock_item_id': stock.first['id'],
            'nama_item': part['nama_part'],
            'jenis': 'MASUK',
            'jumlah': qty,
            'alasan': 'Void $recordSync',
            'service_record_id': existingRecord.first['id'],
            'created_at': nowIso(),
          });
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
          'created_at': customer['created_at'] ?? nowIso(),
        });
      } else {
        customerId = customerRows.first['id'] as int;
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
      }
      final recordId = await txn.insert('service_records', {
        'sync_id': recordSync,
        'unit_id': unitId,
        'no_nota': record['no_nota'],
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
            final postSale = stock?['jumlah'] as int? ?? 0;
            final qty = part['jumlah'] as int? ?? 0;
            stockId = await txn.insert('stock_items', {
              'sync_id': stockSync,
              'kode': stock?['kode'] ?? stockSync,
              'nama': stock?['nama'] ?? part['nama_part'],
              'harga_modal': stock?['harga_modal'] ?? 0,
              'harga_jual': stock?['harga_jual'] ?? 0,
              'jumlah': postSale + qty,
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
            final qty = part['jumlah'] as int? ?? 0;
            await txn.rawUpdate(
              'UPDATE stock_items SET jumlah = jumlah - ? WHERE id = ?',
              [qty, stockId],
            );
            await txn.insert('stock_movements', {
              'sync_id': movementKey,
              'stock_item_id': stockId,
              'nama_item': part['nama_part'],
              'jenis': 'KELUAR',
              'jumlah': -qty,
              'alasan': 'Penjualan ${record['no_nota']}',
              'service_record_id': recordId,
              'created_at': nowIso(),
            });
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
        await txn.insert('service_payments', {
          'sync_id': payment['sync_id'] ?? newSyncId(),
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
      return 'applied';
    });
  }
}
