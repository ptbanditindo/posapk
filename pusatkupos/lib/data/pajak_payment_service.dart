import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/money.dart';
import 'app_database.dart';
import 'pajak_report_service.dart';

class PajakPaymentInput {
  const PajakPaymentInput({
    required this.masa,
    required this.nominalCents,
    this.metode = 'CASH',
    this.referensi = '',
    this.catatan = '',
    this.dibayarAt,
    this.requestId,
  });

  final String masa;
  final int nominalCents;
  final String metode;
  final String referensi;
  final String catatan;
  final DateTime? dibayarAt;
  final String? requestId;
}

/// Pencatatan pembayaran PPN per masa. Hanya pemilik; pembayaran dibatasi
/// sisa kewajiban neto pada saat dicatat dan idempoten lewat `request_id`.
class PajakPaymentService {
  PajakPaymentService._();

  static final PajakPaymentService instance = PajakPaymentService._();

  String get _storeId => AppDatabase.instance.activeStoreId ?? 'utama';

  void _requireOwner(Operator actor) {
    if (!actor.isOwner) {
      throw StateError('Pembayaran PPN hanya dapat dicatat oleh pemilik.');
    }
  }

  Future<Map<String, Object?>> createPayment({
    required PajakPaymentInput input,
    required Operator actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    _requireOwner(actor);
    if (!PajakReportService.validMasa(input.masa)) {
      throw ArgumentError('Masa PPN harus berformat YYYY-MM.');
    }
    if (input.metode != 'CASH' && input.metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran PPN harus CASH atau TRANSFER.');
    }
    if (input.nominalCents <= 0) {
      throw ArgumentError('Nominal pembayaran PPN harus lebih dari nol.');
    }
    final requestId = input.requestId ?? newSyncId();
    final existing = await AppDatabase.instance.db.query(
      'pajak_pembayaran',
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final row = existing.first;
      return {
        'sync_id': row['sync_id'],
        'cash_sync_id': row['cash_sync_id'],
        'nominal': row['nominal'],
        'sisa_kewajiban': null,
      };
    }

    final rekap = await PajakReportService.instance.rekap(input.masa);
    final sisa = rekap.sisaKewajibanCents;
    if (sisa <= 0) {
      throw StateError(
        'Tidak ada sisa kewajiban PPN pada ${PajakReportService.masaLabel(input.masa)}.',
      );
    }
    if (input.nominalCents > sisa) {
      throw StateError(
        'Pembayaran melebihi sisa kewajiban ${formatRupiah(sisa)}.',
      );
    }

    final dibayarAt = (input.dibayarAt ?? DateTime.now());
    final dibayarIso = dibayarAt.toUtc().toIso8601String();

    return AppDatabase.instance.db.transaction((txn) async {
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final deviceId = await _deviceId(txn);
      final syncId = newSyncId();
      final cashSyncId = input.metode == 'CASH' ? newSyncId() : null;
      final row = {
        'sync_id': syncId,
        'store_id': _storeId,
        'device_id': deviceId,
        'origin_device_id': deviceId,
        'request_id': requestId,
        'masa': input.masa,
        'jenis': 'PPN',
        'metode': input.metode,
        'nominal': input.nominalCents,
        'referensi': _clean(input.referensi),
        'dibayar_at': dibayarIso,
        'operator': actor.label,
        'catatan': _clean(input.catatan),
        'cash_sync_id': cashSyncId,
        'status': 'AKTIF',
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      };
      final id = await txn.insert('pajak_pembayaran', row);
      if (cashSyncId != null) {
        await _writeCash(
          txn,
          cashSyncId: cashSyncId,
          sumberSyncId: syncId,
          nominal: -input.nominalCents,
          metode: input.metode,
          kategori: 'BAYAR_PPN',
          waktu: dibayarIso,
          operator: actor.label,
          catatan: 'Pembayaran PPN ${input.masa}',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }
      await _audit(
        txn,
        actor: actor,
        aksi: 'pembayaran_ppn',
        entityId: syncId,
        before: '{}',
        after: _json(row),
        hlcWall: hlc.wall,
        hlcCounter: hlc.counter,
      );
      if (enqueue != null) await enqueue(txn, id);
      return {
        'sync_id': syncId,
        'cash_sync_id': cashSyncId,
        'nominal': input.nominalCents,
        'sisa_kewajiban': sisa - input.nominalCents,
      };
    });
  }

  Future<void> voidPayment({
    required int paymentId,
    required String alasan,
    required Operator actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    _requireOwner(actor);
    final cleanReason = alasan.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan pembatalan pembayaran PPN wajib diisi.');
    }
    await AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'pajak_pembayaran',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Pembayaran PPN tidak ditemukan.');
      }
      final row = rows.first;
      if ('${row['status']}' == 'VOID') {
        throw StateError('Pembayaran PPN ini sudah dibatalkan.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      await txn.update(
        'pajak_pembayaran',
        {
          'status': 'VOID',
          'void_reason': cleanReason,
          'voided_at': now,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [paymentId],
      );
      final cashSyncId = row['cash_sync_id'] as String?;
      if (cashSyncId != null && cashSyncId.isNotEmpty) {
        await _writeCash(
          txn,
          cashSyncId: newSyncId(),
          sumberSyncId: '${row['sync_id']}',
          sumberEntity: 'pajak_pembayaran_void',
          nominal: (row['nominal'] as num?)?.toInt() ?? 0,
          metode: '${row['metode'] ?? 'CASH'}',
          kategori: 'BAYAR_PPN_VOID',
          waktu: now,
          operator: actor.label,
          catatan: 'Batal bayar PPN ${row['masa']}',
          hlcWall: hlc.wall,
          hlcCounter: hlc.counter,
        );
      }
      await _audit(
        txn,
        actor: actor,
        aksi: 'void_pembayaran_ppn',
        entityId: '${row['sync_id']}',
        before: _json(row),
        after: _json({
          'masa': row['masa'],
          'nominal': row['nominal'],
          'status': 'VOID',
        }),
        hlcWall: hlc.wall,
        hlcCounter: hlc.counter,
      );
      if (enqueue != null) await enqueue(txn, paymentId);
    });
  }

  Future<void> applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final syncId = '${payload['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final masa = '${payload['masa'] ?? ''}';
    final nominal = (payload['nominal'] as num?)?.toInt() ?? 0;
    if (!PajakReportService.validMasa(masa) || nominal <= 0) return;
    final status = '${payload['status'] ?? 'AKTIF'}' == 'VOID'
        ? 'VOID'
        : 'AKTIF';
    final now = nowIso();
    final existing = await txn.query(
      'pajak_pembayaran',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final current = existing.first;
      if ('${current['status']}' == 'VOID') return;
      if (status != 'VOID') return;
      await txn.update(
        'pajak_pembayaran',
        {
          'status': 'VOID',
          'void_reason': payload['void_reason'],
          'voided_at': payload['voided_at'] ?? now,
          'sync_hlc_wall': wall,
          'sync_hlc_counter': counter,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [current['id']],
      );
      final cashSyncId = current['cash_sync_id'] as String?;
      if (cashSyncId != null && cashSyncId.isNotEmpty) {
        await _writeCash(
          txn,
          cashSyncId: newSyncId(),
          sumberSyncId: syncId,
          sumberEntity: 'pajak_pembayaran_void',
          nominal: nominal,
          metode: '${current['metode'] ?? 'CASH'}',
          kategori: 'BAYAR_PPN_VOID',
          waktu: now,
          operator: '${payload['operator'] ?? current['operator'] ?? ''}',
          catatan: 'Batal bayar PPN ${current['masa']}',
          hlcWall: wall,
          hlcCounter: counter,
        );
      }
      return;
    }

    final requestId = '${payload['request_id'] ?? ''}'.trim();
    if (requestId.isNotEmpty) {
      final sameRequest = await txn.query(
        'pajak_pembayaran',
        columns: ['id'],
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (sameRequest.isNotEmpty) return;
    }

    final metode = '${payload['metode'] ?? 'CASH'}' == 'TRANSFER'
        ? 'TRANSFER'
        : 'CASH';
    final providedCash = '${payload['cash_sync_id'] ?? ''}'.trim();
    final cashSyncId = metode == 'CASH' && status == 'AKTIF'
        ? (providedCash.isEmpty ? newSyncId() : providedCash)
        : null;
    await txn.insert('pajak_pembayaran', {
      'sync_id': syncId,
      'store_id': '${payload['store_id'] ?? _storeId}',
      'device_id': '${payload['device_id'] ?? ''}',
      'origin_device_id': '${payload['origin_device_id'] ?? ''}',
      'request_id': requestId.isEmpty ? syncId : requestId,
      'masa': masa,
      'jenis': 'PPN',
      'metode': metode,
      'nominal': nominal,
      'referensi': _clean('${payload['referensi'] ?? ''}'),
      'dibayar_at': '${payload['dibayar_at'] ?? now}',
      'operator': payload['operator'],
      'catatan': _clean('${payload['catatan'] ?? ''}'),
      'cash_sync_id': cashSyncId,
      'status': status,
      'void_reason': payload['void_reason'],
      'voided_at': payload['voided_at'],
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': '${payload['created_at'] ?? now}',
      'updated_at': now,
    });
    if (cashSyncId != null) {
      await _writeCash(
        txn,
        cashSyncId: cashSyncId,
        sumberSyncId: syncId,
        nominal: -nominal,
        metode: metode,
        kategori: 'BAYAR_PPN',
        waktu: '${payload['dibayar_at'] ?? now}',
        operator: '${payload['operator'] ?? ''}',
        catatan: 'Pembayaran PPN $masa',
        hlcWall: wall,
        hlcCounter: counter,
      );
    }
  }

  Future<void> _writeCash(
    DatabaseExecutor txn, {
    required String cashSyncId,
    required String sumberSyncId,
    required int nominal,
    required String metode,
    required String kategori,
    required String waktu,
    required String operator,
    required String catatan,
    required int hlcWall,
    required int hlcCounter,
    String sumberEntity = 'pajak_pembayaran',
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

  Future<void> _audit(
    DatabaseExecutor txn, {
    required Operator actor,
    required String aksi,
    required String entityId,
    required String before,
    required String after,
    required int hlcWall,
    required int hlcCounter,
  }) async {
    final now = nowIso();
    await txn.insert('business_audits', {
      'sync_id': newSyncId(),
      'store_id': _storeId,
      'device_id': await _deviceId(txn),
      'waktu': now,
      'aktor': actor.label,
      'aktor_employee_sync_id': actor.employeeSyncId,
      'aksi': aksi,
      'entity': 'pajak_pembayaran',
      'entity_id': entityId,
      'before_json': before,
      'after_json': after,
      'alasan': null,
      'sync_hlc_wall': hlcWall,
      'sync_hlc_counter': hlcCounter,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<String> _deviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_settings',
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

  String _clean(String value) => value.trim();

  String _json(Map<String, Object?> row) {
    const keys = [
      'masa',
      'metode',
      'nominal',
      'referensi',
      'dibayar_at',
      'operator',
      'catatan',
    ];
    return jsonEncode({
      for (final key in keys) key: row[key],
    });
  }
}
