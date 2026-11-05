import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';
import 'approval_service.dart';
import 'models.dart';
import 'price_rules.dart';
import 'store_settings.dart';

class EstimateItemInput {
  const EstimateItemInput({
    required this.jenis,
    required this.deskripsi,
    required this.jumlah,
    required this.hargaCents,
    required this.modalCents,
    this.stockItemId,
    this.jasaId,
    this.intervalBulan = 0,
  });

  final String jenis; // jasa | part
  final String deskripsi;
  final int jumlah;
  final int hargaCents;
  final int modalCents;
  final int? stockItemId;
  final int? jasaId;
  final int intervalBulan;
}

class EstimateRecord {
  const EstimateRecord({
    required this.id,
    required this.syncId,
    required this.nomorEstimasi,
    required this.versi,
    required this.totalCents,
    required this.status,
    this.workOrderSyncId,
    this.customerSyncId,
    this.unitSyncId,
    this.masaBerlaku,
    this.revisiDariSyncId,
    this.convertedNotaSyncId,
    this.totalEstimasiTerakhir,
    this.dibuatOleh,
  });

  final int id;
  final String syncId;
  final String nomorEstimasi;
  final int versi;
  final int totalCents;
  final String status;
  final String? workOrderSyncId;
  final String? customerSyncId;
  final String? unitSyncId;
  final String? masaBerlaku;
  final String? revisiDariSyncId;
  final String? convertedNotaSyncId;
  final int? totalEstimasiTerakhir;
  final String? dibuatOleh;

  bool get kedaluwarsa {
    final expiry = DateTime.tryParse(masaBerlaku ?? '');
    if (expiry == null) return false;
    final today = DateTime.now();
    return DateTime(
      today.year,
      today.month,
      today.day,
    ).isAfter(DateTime(expiry.year, expiry.month, expiry.day));
  }

  factory EstimateRecord.fromRow(Map<String, Object?> row) => EstimateRecord(
    id: row['id'] as int,
    syncId: row['sync_id'] as String,
    nomorEstimasi: row['nomor_estimasi'] as String? ?? '',
    versi: (row['versi'] as num?)?.toInt() ?? 1,
    totalCents: (row['total'] as num?)?.toInt() ?? 0,
    status: row['status'] as String? ?? 'aktif',
    workOrderSyncId: row['work_order_sync_id'] as String?,
    customerSyncId: row['customer_sync_id'] as String?,
    unitSyncId: row['unit_sync_id'] as String?,
    masaBerlaku: row['masa_berlaku'] as String?,
    revisiDariSyncId: row['revisi_dari_sync_id'] as String?,
    convertedNotaSyncId: row['converted_nota_sync_id'] as String?,
    totalEstimasiTerakhir: (row['total_estimasi_terakhir'] as num?)?.toInt(),
    dibuatOleh: row['dibuat_oleh'] as String?,
  );
}

class WorkOrderRecord {
  const WorkOrderRecord({
    required this.id,
    required this.syncId,
    required this.keluhan,
    required this.status,
    required this.waktuMasuk,
    this.nomorOrder,
    this.nomorAntrian,
    this.customerSyncId,
    this.unitSyncId,
    this.mekanikSyncId,
    this.mekanikNama,
    this.notaSyncId,
    this.modeSaatDibuat = const {},
  });

  final int id;
  final String syncId;
  final String keluhan;
  final String status;
  final String waktuMasuk;
  final String? nomorOrder;
  final String? nomorAntrian;
  final String? customerSyncId;
  final String? unitSyncId;
  final String? mekanikSyncId;
  final String? mekanikNama;
  final String? notaSyncId;
  final Map<String, Object?> modeSaatDibuat;

  bool get dalamPengerjaan => const {
    'diagnosa',
    'menunggu_persetujuan',
    'menunggu_sparepart',
    'dikerjakan',
  }.contains(status);

  factory WorkOrderRecord.fromRow(Map<String, Object?> row) => WorkOrderRecord(
    id: row['id'] as int,
    syncId: row['sync_id'] as String,
    keluhan: row['keluhan'] as String? ?? '',
    status: row['status'] as String? ?? 'antri',
    waktuMasuk: row['waktu_masuk'] as String? ?? '',
    nomorOrder: row['nomor_order'] as String?,
    nomorAntrian: row['nomor_antrian'] as String?,
    customerSyncId: row['customer_sync_id'] as String?,
    unitSyncId: row['unit_sync_id'] as String?,
    mekanikSyncId: row['mekanik_sync_id'] as String?,
    mekanikNama: row['mekanik_nama'] as String?,
    notaSyncId: row['nota_sync_id'] as String?,
    modeSaatDibuat: _decodeMap(row['mode_saat_dibuat_json']),
  );
}

class WorkOrderStatusLog {
  const WorkOrderStatusLog({
    required this.id,
    required this.syncId,
    required this.workOrderSyncId,
    required this.status,
    required this.waktu,
    this.pembuat,
    this.perangkat,
  });

  final int id;
  final String syncId;
  final String workOrderSyncId;
  final String status;
  final String waktu;
  final String? pembuat;
  final String? perangkat;

  factory WorkOrderStatusLog.fromRow(Map<String, Object?> row) =>
      WorkOrderStatusLog(
        id: row['id'] as int,
        syncId: row['sync_id'] as String,
        workOrderSyncId: row['work_order_sync_id'] as String,
        status: row['status'] as String,
        waktu: row['waktu'] as String? ?? '',
        pembuat: row['pembuat'] as String?,
        perangkat: row['perangkat'] as String?,
      );
}

class OrderService {
  OrderService._();

  static final OrderService instance = OrderService._();

  /// Mengembalikan `null` bila `simpan_estimasi_lepas` dimatikan: estimasi
  /// hanya dicetak, tidak ada baris yang disimpan.
  Future<EstimateRecord?> createEstimate({
    int? customerId,
    int? unitId,
    String? workOrderSyncId,
    String? revisiDariSyncId,
    String? alasanRevisi,
    required List<EstimateItemInput> items,
    int diskonCents = 0,
    String? alasanDiskon,
    int masaBerlakuHari = 7,
    String? ownerPin,
    String? approverSecret,
    Operator? actor,
    Map<String, Object?>? modeSaatDibuat,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor?.role ?? 'owner';
    if (!settings.typeEnabled(transactionEstimasiSaja)) {
      throw StateError('Estimasi sedang dimatikan pemilik.');
    }
    if (!settings.roleCanSelect(role, transactionEstimasiSaja)) {
      throw StateError('Peran $role tidak berhak membuat estimasi.');
    }
    if (!settings.simpanEstimasiLepas) {
      return null;
    }
    if (items.isEmpty) {
      throw ArgumentError('Estimasi membutuhkan minimal satu baris.');
    }
    final lines = <PriceLine>[];
    for (final item in items) {
      if (item.jumlah <= 0) {
        throw ArgumentError('Jumlah ${item.deskripsi} harus lebih dari nol.');
      }
      lines.add(
        PriceLine(
          jenis: item.jenis,
          label: item.deskripsi,
          jumlah: item.jumlah,
          hargaTerdaftar: item.hargaCents,
          hargaModal: item.modalCents,
          stockItemId: item.stockItemId,
          jasaId: item.jasaId,
          intervalBulan: item.intervalBulan,
        ),
      );
    }
    final isOwner = actor?.isOwner ?? true;
    final requiresApproval = !isOwner && settings.approvalBelowCost;
    var ownerApproved = isOwner;
    String? approver = isOwner ? (actor?.label ?? 'Pemilik') : null;
    final hasApprovalInput =
        (ownerPin ?? '').trim().isNotEmpty ||
        (approverSecret ?? '').trim().isNotEmpty;
    PriceAllocation allocation;
    try {
      allocation = PriceRules.allocate(
        lines,
        diskonCents: diskonCents,
        ownerApproved: ownerApproved,
        allowBelowMinimum: !requiresApproval,
        alasanDiskon: alasanDiskon,
        disetujuiOleh: approver,
      );
    } on PriceRuleViolation catch (error) {
      if (error.code != 'di_bawah_batas_minimal') rethrow;
      if (!hasApprovalInput) rethrow;
      try {
        final approval = await ApprovalService.instance.verify(
          settings: settings,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
        );
        ownerApproved = true;
        approver = approval.isOwner ? 'Pemilik (PIN)' : approval.label;
      } on ApprovalException catch (failure) {
        throw PriceRuleViolation('persetujuan_gagal', failure.message);
      }
      allocation = PriceRules.allocate(
        lines,
        diskonCents: diskonCents,
        ownerApproved: true,
        alasanDiskon: alasanDiskon,
        disetujuiOleh: approver,
      );
    }
    return AppDatabase.instance.db.transaction((txn) async {
      String nomor;
      var versi = 1;
      if ((revisiDariSyncId ?? '').isNotEmpty) {
        final base = await txn.query(
          'estimates',
          where: 'sync_id = ?',
          whereArgs: [revisiDariSyncId],
          limit: 1,
        );
        if (base.isEmpty) throw StateError('Estimasi asal tidak ditemukan.');
        nomor = base.first['nomor_estimasi'] as String;
        versi = ((base.first['versi'] as num?)?.toInt() ?? 1) + 1;
        final baseHlc = await AppDatabase.instance.nextSyncHlc(txn);
        await txn.update(
          'estimates',
          {
            'status': 'direvisi',
            'sync_hlc_wall': baseHlc.wall,
            'sync_hlc_counter': baseHlc.counter,
            'updated_at': nowIso(),
          },
          where: 'sync_id = ?',
          whereArgs: [revisiDariSyncId],
        );
        if (enqueue != null) await enqueue(txn, revisiDariSyncId!);
      } else {
        nomor = await AppDatabase.instance.allocateDocumentNumber(
          txn,
          docType: 'estimasi',
          prefix: 'E',
        );
      }
      String? customerSync;
      if (customerId != null) {
        final rows = await txn.query(
          'customers',
          columns: ['sync_id'],
          where: 'id = ?',
          whereArgs: [customerId],
          limit: 1,
        );
        customerSync = rows.isEmpty ? null : rows.first['sync_id'] as String?;
      }
      String? unitSync;
      if (unitId != null) {
        final rows = await txn.query(
          'vehicle_or_units',
          columns: ['sync_id', 'customer_id'],
          where: 'id = ?',
          whereArgs: [unitId],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('Kendaraan tidak ditemukan.');
        unitSync = rows.first['sync_id'] as String?;
        if (customerSync == null && rows.first['customer_id'] != null) {
          final customer = await txn.query(
            'customers',
            columns: ['sync_id'],
            where: 'id = ?',
            whereArgs: [rows.first['customer_id']],
            limit: 1,
          );
          customerSync = customer.isEmpty
              ? null
              : customer.first['sync_id'] as String?;
        }
      }
      final now = nowIso();
      final tanggal = DateTime.now();
      final syncId = newSyncId();
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await txn.insert('estimates', {
        'sync_id': syncId,
        'nomor_estimasi': nomor,
        'work_order_sync_id': _nullableValue(workOrderSyncId),
        'customer_sync_id': customerSync,
        'unit_sync_id': unitSync,
        'versi': versi,
        'revisi_dari_sync_id': _nullableValue(revisiDariSyncId),
        'alasan_revisi': _nullableValue(alasanRevisi),
        'masa_berlaku': tanggal
            .add(Duration(days: masaBerlakuHari < 1 ? 1 : masaBerlakuHari))
            .toIso8601String(),
        'total': allocation.total,
        'status': 'aktif',
        'disetujui_oleh': ownerApproved ? approver : null,
        'mode_saat_dibuat_json': jsonEncode(
          modeSaatDibuat ??
              settings.modeSnapshot(jenisTransaksi: transactionEstimasiSaja),
        ),
        'dibuat_oleh': actor?.label ?? 'Pemilik',
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final line = allocation.lines[index];
        await txn.insert('estimate_items', {
          'sync_id': newSyncId(),
          'estimate_sync_id': syncId,
          'jenis': item.jenis,
          'stock_sync_id': item.stockItemId == null
              ? null
              : (await txn.query(
                  'stock_items',
                  columns: ['sync_id'],
                  where: 'id = ?',
                  whereArgs: [item.stockItemId],
                  limit: 1,
                )).map((row) => row['sync_id'] as String?).firstOrNull,
          'deskripsi': item.deskripsi,
          'jumlah': item.jumlah,
          'harga_jual_terdaftar': item.hargaCents,
          'harga_batas_saat_transaksi': item.modalCents,
          'harga_final': line.hargaFinal,
          'harga_modal': item.modalCents,
          'diskon_alokasi': line.diskonAlokasi,
          'interval_servis_bulan': item.intervalBulan,
          'subtotal': item.jumlah * line.hargaFinal,
          'created_at': now,
          'updated_at': now,
        });
      }
      if (enqueue != null) await enqueue(txn, syncId);
      return (await _estimateBySyncId(syncId, txn))!;
    });
  }

  Future<EstimateRecord?> _estimateBySyncId(
    String syncId,
    DatabaseExecutor txn,
  ) async {
    final rows = await txn.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : EstimateRecord.fromRow(rows.first);
  }

  Future<int> convertEstimateToNote({
    required String estimateSyncId,
    required String metodeBayar,
    required int bayarCents,
    String? ownerPin,
    String? approverSecret,
    Operator? actor,
    Future<void> Function(Transaction txn, int recordId)? enqueueNote,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueEstimate,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueOrder,
  }) async {
    final rows = await AppDatabase.instance.db.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [estimateSyncId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Estimasi tidak ditemukan.');
    final estimate = EstimateRecord.fromRow(rows.first);
    if (estimate.status != 'aktif' || estimate.kedaluwarsa) {
      throw StateError('Estimasi tidak lagi aktif.');
    }
    final items = await AppDatabase.instance.db.query(
      'estimate_items',
      where: 'estimate_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [estimateSyncId],
    );
    final jobs = <JobDraft>[];
    final parts = <PartDraft>[];
    for (final item in items) {
      final jumlah = (item['jumlah'] as num?)?.toInt() ?? 0;
      final harga = (item['harga_final'] as num?)?.toInt() ?? 0;
      final modal = (item['harga_modal'] as num?)?.toInt() ?? 0;
      if (item['jenis'] == 'part') {
        final stockSync = item['stock_sync_id'] as String? ?? '';
        final stock = await AppDatabase.instance.db.query(
          'stock_items',
          where: 'sync_id = ?',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stock.isEmpty) {
          throw StateError('Barang estimasi tidak ditemukan.');
        }
        final stockItem = StockItem.fromRow(stock.first);
        parts.add(
          PartDraft(
            stockItemId: stockItem.id,
            nama: stockItem.nama,
            jumlah: jumlah,
            hargaCents: stockItem.hargaJualCents,
            modalCents: stockItem.hargaModalCents,
            intervalBulan:
                (item['interval_servis_bulan'] as num?)?.toInt() ?? 0,
          ),
        );
      } else {
        jobs.add(
          JobDraft(
            deskripsi: item['deskripsi'] as String? ?? '',
            jumlah: jumlah,
            hargaCents: harga,
            modalCents: modal,
            intervalBulan:
                (item['interval_servis_bulan'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    final hargaTotal = jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents);
    final partTotal = parts.fold<int>(
      0,
      (sum, part) => sum + part.subtotalCents,
    );
    final diskon = (hargaTotal + partTotal) - estimate.totalCents;
    return AppDatabase.instance.createTransaction(
      jenisTransaksi: transactionOrderKerja,
      keluhan: 'Konversi estimasi ${estimate.nomorEstimasi}',
      jobs: jobs,
      parts: parts,
      diskonCents: diskon < 0 ? 0 : diskon,
      metodeBayar: metodeBayar,
      bayarCents: bayarCents,
      actor: actor,
      ownerPin: ownerPin,
      approverSecret: approverSecret,
      estimateSyncId: estimateSyncId,
      totalEstimasiTerakhir: estimate.totalCents,
      alasanDiskon: 'Konversi estimasi ${estimate.nomorEstimasi}',
      enqueue: enqueueNote,
      enqueueEstimate: enqueueEstimate,
      enqueueOrder: enqueueOrder,
    );
  }

  Future<WorkOrderRecord> createWorkOrder({
    int? customerId,
    int? unitId,
    required String keluhan,
    String? mekanikSyncId,
    String? mekanikNama,
    Operator? actor,
    Map<String, Object?>? modeSaatDibuat,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueStatus,
  }) async {
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor?.role ?? 'owner';
    if (!settings.typeEnabled(transactionOrderKerja)) {
      throw StateError('Order kerja sedang dimatikan pemilik.');
    }
    if (role != 'owner' && !settings.roleAllows(role, 'buat_nota')) {
      throw StateError('Peran $role tidak berhak membuka order kerja.');
    }
    final snapshot =
        modeSaatDibuat ??
        settings.modeSnapshot(jenisTransaksi: transactionOrderKerja);
    final stages = (snapshot['stages'] as Map?) ?? settings.stages;
    bool stageOn(String key) =>
        stages[key] != false && settings.stageEnabled(key);
    final pengerjaanOn = stageOn(stageStatusPengerjaan);
    return AppDatabase.instance.db.transaction((txn) async {
      final now = nowIso();
      final syncId = newSyncId();
      final nomorOrder = stageOn(stageNomorOrder)
          ? await AppDatabase.instance.allocateDocumentNumber(
              txn,
              docType: 'order',
              prefix: 'WK',
            )
          : null;
      final nomorAntrian = stageOn(stageNomorAntrian)
          ? await AppDatabase.instance.allocateQueueNumber(txn)
          : null;
      String? customerSync;
      if (customerId != null) {
        final rows = await txn.query(
          'customers',
          columns: ['sync_id'],
          where: 'id = ?',
          whereArgs: [customerId],
          limit: 1,
        );
        customerSync = rows.isEmpty ? null : rows.first['sync_id'] as String?;
      }
      String? unitSync;
      if (unitId != null) {
        final rows = await txn.query(
          'vehicle_or_units',
          columns: ['sync_id', 'customer_id'],
          where: 'id = ?',
          whereArgs: [unitId],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('Kendaraan tidak ditemukan.');
        unitSync = rows.first['sync_id'] as String?;
        if (customerSync == null && rows.first['customer_id'] != null) {
          final customer = await txn.query(
            'customers',
            columns: ['sync_id'],
            where: 'id = ?',
            whereArgs: [rows.first['customer_id']],
            limit: 1,
          );
          customerSync = customer.isEmpty
              ? null
              : customer.first['sync_id'] as String?;
        }
      }
      final status = pengerjaanOn ? 'antri' : 'dibuka';
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await txn.insert('work_orders', {
        'sync_id': syncId,
        'nomor_order': nomorOrder,
        'nomor_antrian': nomorAntrian,
        'customer_sync_id': customerSync,
        'unit_sync_id': unitSync,
        'keluhan': keluhan.trim(),
        'status': status,
        'mekanik_sync_id': _nullableValue(mekanikSyncId),
        'mekanik_nama': _nullableValue(mekanikNama),
        'waktu_masuk': now,
        'mode_saat_dibuat_json': jsonEncode(snapshot),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      if (enqueueStatus != null && pengerjaanOn) {
        final statusId = await _appendStatus(
          txn,
          workOrderSyncId: syncId,
          status: status,
          actor: actor,
          waktu: now,
        );
        await enqueueStatus(txn, statusId);
      }
      if (enqueue != null) await enqueue(txn, syncId);
      final rows = await txn.query(
        'work_orders',
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      return WorkOrderRecord.fromRow(rows.first);
    });
  }

  Future<String> _appendStatus(
    DatabaseExecutor txn, {
    required String workOrderSyncId,
    required String status,
    required Operator? actor,
    required String waktu,
  }) async {
    final syncId = newSyncId();
    final hlc = await AppDatabase.instance.nextSyncHlc(txn);
    final deviceId = await AppDatabase.instance.deviceCode(txn);
    await txn.insert('work_order_status_log', {
      'sync_id': syncId,
      'work_order_sync_id': workOrderSyncId,
      'status': status,
      'waktu': waktu,
      'pembuat': actor?.label ?? 'Pemilik',
      'perangkat': deviceId,
      'sync_hlc_wall': hlc.wall,
      'sync_hlc_counter': hlc.counter,
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    return syncId;
  }

  Future<WorkOrderRecord> changeStatus({
    required String workOrderSyncId,
    required String status,
    Operator? actor,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueStatus,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueOrder,
  }) async {
    final rows = await AppDatabase.instance.db.query(
      'work_orders',
      where: 'sync_id = ?',
      whereArgs: [workOrderSyncId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Order kerja tidak ditemukan.');
    final order = WorkOrderRecord.fromRow(rows.first);
    final snapshot = order.modeSaatDibuat;
    final stages = (snapshot['stages'] as Map?) ?? const {};
    final pengerjaanOn = stages[stageStatusPengerjaan] != false;
    final allowedStatuses = pengerjaanOn
        ? workOrderStatuses
        : workOrderStatusesMinimal;
    if (!allowedStatuses.contains(status)) {
      throw ArgumentError('Status "$status" tidak dikenal untuk order ini.');
    }
    if (stages[stagePersetujuanPelanggan] == false &&
        status == 'menunggu_persetujuan') {
      throw StateError('Tahap persetujuan pelanggan sedang dimatikan.');
    }
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor?.role ?? 'owner';
    final canChange =
        role == 'owner' || settings.roleAllows(role, 'ubah_status');
    if (!canChange) {
      throw StateError('Peran $role tidak berhak mengubah status order.');
    }
    final current = await _currentStatus(workOrderSyncId) ?? order.status;
    final permitted = allowedWorkOrderTransitions(current);
    final forbidden = !permitted.contains(status);
    if (forbidden && role != 'owner') {
      throw StateError(
        'Perubahan status $current → $status hanya dapat dilakukan pemilik.',
      );
    }
    final ownerCancelWorked = status == 'batal' && order.dalamPengerjaan;
    if (ownerCancelWorked && role != 'owner') {
      throw StateError(
        'Order yang sudah dikerjakan hanya boleh dibatalkan pemilik.',
      );
    }
    return AppDatabase.instance.db.transaction((txn) async {
      final now = nowIso();
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final statusSync = await _appendStatus(
        txn,
        workOrderSyncId: workOrderSyncId,
        status: status,
        actor: actor,
        waktu: now,
      );
      await txn.update(
        'work_orders',
        {
          'status': status,
          'waktu_selesai': status == 'selesai' ? now : null,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': now,
        },
        where: 'sync_id = ?',
        whereArgs: [workOrderSyncId],
      );
      if (forbidden) {
        await txn.insert('sync_conflicts', {
          'entity': 'work_order_status',
          'entity_id': workOrderSyncId,
          'reason': 'transisi_status_dilarang',
          'detail_json': jsonEncode({
            'dari': current,
            'ke': status,
            'oleh': actor?.label ?? 'Pemilik',
          }),
          'status': 'review',
          'created_at': now,
        });
      }
      if (enqueueStatus != null) await enqueueStatus(txn, statusSync);
      if (enqueueOrder != null) await enqueueOrder(txn, workOrderSyncId);
      final updated = await txn.query(
        'work_orders',
        where: 'sync_id = ?',
        whereArgs: [workOrderSyncId],
        limit: 1,
      );
      return WorkOrderRecord.fromRow(updated.first);
    });
  }

  Future<String?> _currentStatus(String workOrderSyncId) async {
    final rows = await AppDatabase.instance.db.query(
      'work_order_status_log',
      columns: ['status'],
      where: 'work_order_sync_id = ?',
      whereArgs: [workOrderSyncId],
      orderBy: 'sync_hlc_wall DESC, sync_hlc_counter DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['status'] as String?;
  }

  Future<List<WorkOrderRecord>> listWorkOrders({bool activeOnly = true}) async {
    final rows = await AppDatabase.instance.db.query(
      'work_orders',
      where: activeOnly ? "status NOT IN ('diambil','batal')" : null,
      orderBy: 'waktu_masuk DESC',
    );
    return rows.map(WorkOrderRecord.fromRow).toList();
  }

  /// Baris order lengkap dengan nama pelanggan dan unit untuk tampilan daftar.
  Future<List<Map<String, Object?>>> listWorkOrderRows({
    bool activeOnly = true,
  }) {
    final where = activeOnly
        ? "WHERE w.deleted_at IS NULL AND w.status NOT IN ('diambil','batal')"
        : 'WHERE w.deleted_at IS NULL';
    return AppDatabase.instance.db.rawQuery('''
      SELECT w.*, c.nama AS customer_nama,
        v.nopol, v.merek, v.tipe, v.unit_type
      FROM work_orders w
      LEFT JOIN customers c ON c.sync_id = w.customer_sync_id
      LEFT JOIN vehicle_or_units v ON v.sync_id = w.unit_sync_id
      $where
      ORDER BY w.waktu_masuk DESC
    ''');
  }

  Future<List<WorkOrderStatusLog>> statusLog(String workOrderSyncId) async {
    final rows = await AppDatabase.instance.db.query(
      'work_order_status_log',
      where: 'work_order_sync_id = ?',
      whereArgs: [workOrderSyncId],
      orderBy: 'sync_hlc_wall, sync_hlc_counter',
    );
    return rows.map(WorkOrderStatusLog.fromRow).toList();
  }

  Future<List<EstimateRecord>> listEstimates({
    bool unconvertedOnly = false,
  }) async {
    final where = <String>['deleted_at IS NULL'];
    if (unconvertedOnly) {
      where.add("status = 'aktif'");
      where.add('converted_nota_sync_id IS NULL');
    }
    final rows = await AppDatabase.instance.db.query(
      'estimates',
      where: where.join(' AND '),
      orderBy: 'created_at DESC',
    );
    return rows.map(EstimateRecord.fromRow).toList();
  }

  /// Baris estimasi dengan nama pelanggan, unit, dan nomor nota hasil
  /// konversi untuk tampilan daftar.
  Future<List<Map<String, Object?>>> listEstimateRows({
    bool unconvertedOnly = false,
  }) {
    final where = unconvertedOnly
        ? "WHERE e.deleted_at IS NULL AND e.status = 'aktif' "
              'AND e.converted_nota_sync_id IS NULL'
        : 'WHERE e.deleted_at IS NULL';
    return AppDatabase.instance.db.rawQuery('''
      SELECT e.*, c.nama AS customer_nama,
        v.nopol, v.merek, v.tipe, v.unit_type,
        r.no_nota AS nota_nomor, r.total_servis AS nota_total
      FROM estimates e
      LEFT JOIN customers c ON c.sync_id = e.customer_sync_id
      LEFT JOIN vehicle_or_units v ON v.sync_id = e.unit_sync_id
      LEFT JOIN service_records r ON r.sync_id = e.converted_nota_sync_id
      $where
      ORDER BY e.created_at DESC
    ''');
  }

  Future<List<EstimateRecord>> expiredEstimates({int days = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final rows = await AppDatabase.instance.db.query(
      'estimates',
      where:
          "status = 'aktif' AND masa_berlaku IS NOT NULL "
          'AND masa_berlaku < ?',
      whereArgs: [cutoff.toIso8601String()],
      orderBy: 'masa_berlaku',
    );
    return rows.map(EstimateRecord.fromRow).toList();
  }

  Future<List<Map<String, Object?>>> varianceReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final start = (from ?? DateTime.now().subtract(const Duration(days: 30)))
        .toIso8601String();
    final end = (to ?? DateTime.now()).toIso8601String();
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT r.no_nota, r.estimate_sync_id, r.total_servis,
        r.total_estimasi_terakhir,
        (r.total_servis - COALESCE(r.total_estimasi_terakhir, r.total_servis))
          AS selisih,
        r.created_by
      FROM service_records r
      WHERE r.estimate_sync_id IS NOT NULL
        AND r.voided_at IS NULL
        AND r.waktu_service BETWEEN ? AND ?
      ORDER BY r.waktu_service DESC
      ''',
      [start, end],
    );
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  Future<List<Map<String, Object?>>> unconvertedByCashier() async {
    final rows = await AppDatabase.instance.db.rawQuery('''
      SELECT dibuat_oleh AS kasir, COUNT(*) AS jumlah, SUM(total) AS nilai
      FROM estimates
      WHERE status = 'aktif' AND converted_nota_sync_id IS NULL
        AND deleted_at IS NULL
      GROUP BY dibuat_oleh
      ORDER BY jumlah DESC
      ''');
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }
}

String? _nullableValue(String? value) {
  final clean = value?.trim() ?? '';
  return clean.isEmpty ? null : clean;
}

Map<String, Object?> _decodeMap(Object? raw) {
  if (raw is Map) {
    return {for (final entry in raw.entries) '${entry.key}': entry.value};
  }
  try {
    final decoded = jsonDecode('${raw ?? '{}'}');
    if (decoded is Map) {
      return {for (final entry in decoded.entries) '${entry.key}': entry.value};
    }
  } catch (_) {}
  return {};
}
