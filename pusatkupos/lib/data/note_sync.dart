import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
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
          'harga_satuan': item['harga_satuan'],
          'subtotal': item['subtotal'],
          'modal_satuan': item['modal_satuan'] ?? 0,
          'stock_sync_id': stockSync,
        });
      }
      returnPayloads.add({
        'sync_id': retur['sync_id'],
        'no_retur': retur['no_retur'],
        'total': retur['total'],
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
              'catatan': payment['catatan'],
            },
          )
          .toList(),
      'returns': returnPayloads,
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
          'updated_at': nowIso(),
        });
      }
      // Refund dibuat di perangkat yang melakukan void. Perangkat lain
      // hanya menyamakan status dan stok agar tidak menghitung refund dua
      // kali.
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
      if (existingRecord.isEmpty) {
        throw RetryableSyncException(
          'Pembayaran menunggu nota asal diterapkan.',
          code: 'nota_butuh_induk',
        );
      }
      for (final payment in payments) {
        await _upsertPayment(txn, existingRecord.first['id'] as int, payment);
      }
      await _recalculateRecordTotals(txn, existingRecord.first['id'] as int);
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
      var changed = false;
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
          await txn.insert('sync_conflicts', {
            'entity': 'nota',
            'entity_id': recordSync,
            'reason': 'no_nota_bentrok',
            'detail_json': jsonEncode({
              'no_nota_asal': incomingNoNota,
              'no_nota_baru': next,
            }),
            'status': 'review',
            'created_at': nowIso(),
          });
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
      var paymentAdded = false;
      for (final payment in payments) {
        final inserted = await _upsertPayment(
          txn,
          existingRecord.first['id'] as int,
          payment,
        );
        paymentAdded = paymentAdded || inserted;
      }
      changed = changed || paymentAdded;
      if (paymentAdded) {
        await _recalculateRecordTotals(txn, existingRecord.first['id'] as int);
      }
      var returnAdded = false;
      for (final retur in returns) {
        final inserted = await _upsertReturn(
          txn,
          existingRecord.first['id'] as int,
          recordSync,
          retur,
        );
        returnAdded = returnAdded || inserted;
      }
      changed = changed || returnAdded;
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
      await txn.insert('sync_conflicts', {
        'entity': 'nota',
        'entity_id': recordSync,
        'reason': 'no_nota_bentrok',
        'detail_json': jsonEncode({
          'no_nota_asal': noNotaAsal,
          'no_nota_baru': noNota,
        }),
        'status': 'review',
        'created_at': nowIso(),
      });
    }
    final recordId = await txn.insert('service_records', {
      'sync_id': recordSync,
      'unit_id': unitId,
      'customer_id': customerId,
      'no_nota': noNota,
      'request_id': null,
      'jenis_transaksi': record['jenis_transaksi'] ?? 'servis_langsung',
      'mode_saat_dibuat_json': record['mode_saat_dibuat_json'] ?? '{}',
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
      'metode_bayar': record['metode_bayar'] ?? 'CASH',
      'bayar': record['bayar'] ?? 0,
      'kembalian': record['kembalian'] ?? 0,
      'status_bayar': record['status_bayar'] ?? 'LUNAS',
      'jenis_bayar': record['jenis_bayar'] ?? 'LUNAS',
      'total_dibayar': record['total_dibayar'] ?? 0,
      'sisa_bayar': record['sisa_bayar'] ?? 0,
      'jatuh_tempo': record['jatuh_tempo'],
      'status': record['status'] ?? 'AKTIF',
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
      if (stockSync.isNotEmpty) {
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
            'updated_at': nowIso(),
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
    for (final payment in payments) {
      await _upsertPayment(txn, recordId, payment);
    }
    for (final retur in returns) {
      await _upsertReturn(txn, recordId, recordSync, retur);
    }
    return 'applied';
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
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    return true;
  }

  Future<bool> _upsertReturn(
    DatabaseExecutor txn,
    int recordId,
    String recordSync,
    Map<String, Object?> retur,
  ) async {
    final syncId = '${retur['sync_id'] ?? ''}';
    if (syncId.isEmpty) return false;
    final existing = await txn.query(
      'sale_returns',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;
    final recordRows = await txn.query(
      'service_records',
      columns: ['no_nota'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    final noNota = recordRows.isEmpty
        ? ''
        : '${recordRows.first['no_nota'] ?? ''}';
    final createdAt = retur['created_at'] ?? nowIso();
    final returnId = await txn.insert('sale_returns', {
      'sync_id': syncId,
      'service_record_id': recordId,
      'nota_sync_id': recordSync,
      'no_nota': noNota,
      'no_retur': retur['no_retur'] ?? '',
      'total': retur['total'] ?? 0,
      'alasan': retur['alasan'] ?? 'Retur dari perangkat lain',
      'dibuat_oleh': retur['dibuat_oleh'],
      'created_at': createdAt,
      'updated_at': nowIso(),
    });
    final items = (retur['items'] as List? ?? const [])
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    for (final item in items) {
      final jumlah = (item['jumlah'] as num?)?.toInt() ?? 0;
      final lineType = '${item['line_type'] ?? 'part'}';
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
      await txn.insert('sale_return_items', {
        'sync_id': '${item['sync_id'] ?? ''}'.isEmpty
            ? newSyncId()
            : '${item['sync_id']}',
        'return_id': returnId,
        'line_type': lineType,
        'line_sync_id': item['line_sync_id'] ?? '',
        'deskripsi': item['deskripsi'] ?? '',
        'jumlah': jumlah,
        'harga_satuan': item['harga_satuan'] ?? 0,
        'subtotal': item['subtotal'] ?? 0,
        'modal_satuan': item['modal_satuan'] ?? 0,
        'stock_item_id': stockId,
        'created_at': createdAt,
        'updated_at': nowIso(),
      });
      if (lineType != 'part' || stockId == null) continue;
      final stockRows = await txn.query(
        'stock_items',
        where: 'id = ?',
        whereArgs: [stockId],
        limit: 1,
      );
      if (stockRows.isEmpty) continue;
      final before = (stockRows.first['jumlah_milli'] as num?)?.toInt() ??
          ((stockRows.first['jumlah'] as num?)?.toInt() ?? 0) * 1000;
      final nextMilli = before + jumlah * 1000;
      await txn.update(
        'stock_items',
        {'jumlah': nextMilli ~/ 1000, 'jumlah_milli': nextMilli},
        where: 'id = ?',
        whereArgs: [stockId],
      );
      final movementKey = 'retur-$syncId-${item['sync_id'] ?? ''}';
      final movement = await txn.query(
        'stock_movements',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [movementKey],
        limit: 1,
      );
      if (movement.isEmpty) {
        await txn.insert('stock_movements', {
          'sync_id': movementKey,
          'stock_item_id': stockId,
          'nama_item': item['deskripsi'] ?? '',
          'jenis': 'MASUK',
          'jumlah': jumlah,
          'jumlah_milli': jumlah * 1000,
          'alasan': 'Retur $noNota',
          'service_record_id': recordId,
          'created_at': nowIso(),
          'updated_at': nowIso(),
        });
      }
    }
    return true;
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
