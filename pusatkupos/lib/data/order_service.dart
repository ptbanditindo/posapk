import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/money.dart';
import 'app_database.dart';
import 'approval_service.dart';
import 'feature_flags.dart';
import 'models.dart';
import 'pajak.dart';
import 'price_rules.dart';
import 'store_settings.dart';

class EstimateItemInput {
  EstimateItemInput({
    required this.jenis,
    required this.deskripsi,
    required int jumlah,
    required this.hargaCents,
    required this.modalCents,
    this.stockItemId,
    this.jasaId,
    this.intervalBulan = 0,
    this.hargaTerdaftarCents,
    int? qtyMilli,
  })  : jumlah = jumlah,
        qtyMilli = qtyMilli ?? jumlah * 1000;

  final String jenis; // jasa | part
  final String deskripsi;
  final int jumlah;
  final int qtyMilli;
  final int hargaCents;
  final int modalCents;
  final int? stockItemId;
  final int? jasaId;
  final int intervalBulan;

  /// Tarif acuan saat jasa tidak lagi ada di katalog (mis. revisi estimasi
  /// lama). Nol berarti jasa bebas tanpa tarif acuan.
  final int? hargaTerdaftarCents;
}

class EstimateRecord {
  const EstimateRecord({
    required this.id,
    required this.syncId,
    required this.nomorEstimasi,
    required this.versi,
    required this.totalCents,
    required this.status,
    this.jenisTransaksi = transactionServisLangsung,
    this.diskonCents = 0,
    this.dppCents = 0,
    this.ppnCents = 0,
    this.totalDitagihCents = 0,
    this.pajakMode = pajakModeTanpa,
    this.pajakPersenBp = 0,
    this.pajakPenanggung = pajakPenanggungPembeli,
    this.workOrderSyncId,
    this.customerSyncId,
    this.unitSyncId,
    this.masaBerlaku,
    this.revisiDariSyncId,
    this.convertedNotaSyncId,
    this.totalEstimasiTerakhir,
    this.dibuatOleh,
    this.disetujuiOleh,
  });

  final int id;
  final String syncId;
  final String nomorEstimasi;
  final int versi;
  final int totalCents;
  final String status;
  final String jenisTransaksi;
  final int diskonCents;
  final int dppCents;
  final int ppnCents;
  final int totalDitagihCents;
  final String pajakMode;
  final int pajakPersenBp;
  final String pajakPenanggung;
  final String? workOrderSyncId;
  final String? customerSyncId;
  final String? unitSyncId;
  final String? masaBerlaku;
  final String? revisiDariSyncId;
  final String? convertedNotaSyncId;
  final int? totalEstimasiTerakhir;
  final String? dibuatOleh;
  final String? disetujuiOleh;

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
    jenisTransaksi:
        row['jenis_transaksi'] as String? ?? transactionServisLangsung,
    diskonCents: (row['diskon_cents'] as num?)?.toInt() ?? 0,
    dppCents: (row['dpp_cents'] as num?)?.toInt() ?? 0,
    ppnCents: (row['ppn_cents'] as num?)?.toInt() ?? 0,
    totalDitagihCents: (row['total_ditagih_cents'] as num?)?.toInt() ?? 0,
    pajakMode: row['pajak_mode'] as String? ?? pajakModeTanpa,
    pajakPersenBp: (row['pajak_persen_bp'] as num?)?.toInt() ?? 0,
    pajakPenanggung:
        row['pajak_penanggung'] as String? ?? pajakPenanggungPembeli,
    workOrderSyncId: row['work_order_sync_id'] as String?,
    customerSyncId: row['customer_sync_id'] as String?,
    unitSyncId: row['unit_sync_id'] as String?,
    masaBerlaku: row['masa_berlaku'] as String?,
    revisiDariSyncId: row['revisi_dari_sync_id'] as String?,
    convertedNotaSyncId: row['converted_nota_sync_id'] as String?,
    totalEstimasiTerakhir: (row['total_estimasi_terakhir'] as num?)?.toInt(),
    dibuatOleh: row['dibuat_oleh'] as String?,
    disetujuiOleh: row['disetujui_oleh'] as String?,
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
    this.hlcWall = 0,
    this.hlcCounter = 0,
  });

  final int id;
  final String syncId;
  final String workOrderSyncId;
  final String status;
  final String waktu;
  final String? pembuat;
  final String? perangkat;
  final int hlcWall;
  final int hlcCounter;

  factory WorkOrderStatusLog.fromRow(Map<String, Object?> row) =>
      WorkOrderStatusLog(
        id: row['id'] as int,
        syncId: row['sync_id'] as String,
        workOrderSyncId: row['work_order_sync_id'] as String,
        status: row['status'] as String,
        waktu: row['waktu'] as String? ?? '',
        pembuat: row['pembuat'] as String?,
        perangkat: row['perangkat'] as String?,
        hlcWall: (row['sync_hlc_wall'] as num?)?.toInt() ?? 0,
        hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt() ?? 0,
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
    String jenisTransaksi = transactionServisLangsung,
    int diskonCents = 0,
    String? alasanDiskon,
    int masaBerlakuHari = 7,
    String? ownerPin,
    String? approverSecret,
    required Operator actor,
    Map<String, Object?>? modeSaatDibuat,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    FeatureGate.require(featureEstimasi);
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor.role;
    if (!settings.typeEnabled(transactionEstimasiSaja)) {
      throw StateError('Estimasi sedang dimatikan pemilik.');
    }
    if (!actor.isOwner) Permissions.require(actor, 'buat_estimasi');
    if (!settings.roleCanSelect(role, transactionEstimasiSaja)) {
      throw StateError('Peran $role tidak berhak membuat estimasi.');
    }
    if (!settings.simpanEstimasiLepas) {
      return null;
    }
    if (items.isEmpty) {
      throw ArgumentError('Estimasi membutuhkan minimal satu baris.');
    }
    if (jenisTransaksi == transactionEstimasiSaja) {
      throw ArgumentError(
        'Estimasi harus menargetkan jenis transaksi nota, bukan estimasi.',
      );
    }
    if (!transactionTypes.contains(jenisTransaksi)) {
      throw ArgumentError('Jenis transaksi "$jenisTransaksi" tidak dikenal.');
    }
    if (!settings.typeEnabled(jenisTransaksi)) {
      throw StateError(
        'Jenis transaksi "$jenisTransaksi" sedang dimatikan pemilik.',
      );
    }
    final isOwner = actor.isOwner;
    final hasReason = (alasanDiskon ?? '').trim().isNotEmpty;
    ApprovalGrant? approvalGrant;
    var approver = isOwner ? actor.label : null;
    Future<ApprovalGrant> verifyApproval() async {
      if (isOwner) {
        return approvalGrant ??= ApprovalGrant(
          label: actor.label,
          isOwner: true,
        );
      }
      if (approvalGrant != null) return approvalGrant!;
      final hasApprovalInput =
          (ownerPin ?? '').trim().isNotEmpty ||
          (approverSecret ?? '').trim().isNotEmpty;
      if (!hasApprovalInput) {
        throw StateError(
          'Tindakan ini memerlukan persetujuan pemilik atau penanggung jawab.',
        );
      }
      try {
        approvalGrant = await ApprovalService.instance.verify(
          settings: settings,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
        );
      } on ApprovalException catch (failure) {
        throw PriceRuleViolation('persetujuan_gagal', failure.message);
      }
      approver = approvalGrant!.isOwner
          ? 'Pemilik (PIN)'
          : approvalGrant!.label;
      return approvalGrant!;
    }

    if (!isOwner &&
        ((ownerPin ?? '').trim().isNotEmpty ||
            (approverSecret ?? '').trim().isNotEmpty)) {
      await verifyApproval();
    }
    final allowBelowMinimum = isOwner || approvalGrant != null;
    final lines = <PriceLine>[];
    final jasaSyncIds = <String?>[];
    final hargaTerdaftars = <int>[];
    final hargaBebasFlags = <int>[];
    for (final item in items) {
      if (item.qtyMilli <= 0) {
        throw ArgumentError('Jumlah ${item.deskripsi} harus lebih dari nol.');
      }
      if (item.jenis == 'part' && item.stockItemId == null) {
        throw StateError(
          'Barang ${item.deskripsi} harus dipilih dari daftar stok.',
        );
      }
      if (jenisTransaksi == transactionJualSparepart && item.jenis != 'part') {
        throw StateError('Penjualan sparepart hanya boleh memuat barang.');
      }
      if (item.hargaCents == 0 && !allowBelowMinimum) {
        throw PriceRuleViolation(
          'harga_nol',
          'Harga ${item.deskripsi} tidak boleh nol tanpa persetujuan '
              'pemilik.',
        );
      }
      if (item.hargaCents == 0 && !hasReason) {
        throw PriceRuleViolation(
          'alasan_diskon_wajib',
          'Harga ${item.deskripsi} nol. Isi alasan diskon terlebih dahulu.',
        );
      }
      var modal = item.modalCents < 0 ? 0 : item.modalCents;
      var hargaTerdaftar = item.hargaTerdaftarCents ?? 0;
      String? jasaSync;
      var hargaBebas = false;
      if (item.jenis == 'jasa' && item.jasaId != null) {
        final rows = await AppDatabase.instance.db.query(
          'harga_jasa',
          columns: ['sync_id', 'harga_jual', 'harga_modal', 'deleted_at'],
          where: 'id = ?',
          whereArgs: [item.jasaId],
          limit: 1,
        );
        if (rows.isEmpty || rows.first['deleted_at'] != null) {
          throw StateError(
            'Jasa ${item.deskripsi} tidak ditemukan di daftar tarif.',
          );
        }
        final hargaJual = (rows.first['harga_jual'] as num?)?.toInt() ?? 0;
        if (item.hargaCents != hargaJual) {
          throw StateError(
            'Harga jasa ${item.deskripsi} berubah menjadi '
            '${formatRupiah(hargaJual)}. Muat ulang kasir lalu ulangi.',
          );
        }
        modal = (rows.first['harga_modal'] as num?)?.toInt() ?? 0;
        hargaTerdaftar = hargaJual;
        jasaSync = rows.first['sync_id'] as String?;
      } else if (item.stockItemId != null) {
        final rows = await AppDatabase.instance.db.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [item.stockItemId],
          limit: 1,
        );
        if (rows.isEmpty || rows.first['deleted_at'] != null) {
          throw StateError('Barang ${item.deskripsi} tidak ditemukan.');
        }
        final stock = StockItem.fromRow(rows.first);
        if (stock.hargaJualCents != item.hargaCents) {
          throw StateError(
            'Harga jual ${stock.nama} berubah menjadi '
            '${formatRupiah(stock.hargaJualCents)}. '
            'Muat ulang kasir lalu ulangi.',
          );
        }
        modal = stock.hargaModalCents;
        hargaTerdaftar = stock.hargaJualCents;
      } else if (item.jenis == 'jasa') {
        // Jasa bebas adalah keahlian, bukan pembelian: tidak wajib memiliki
        // modal. Tarif acuan hanya diisi bila pemanggil menyediakannya.
        hargaBebas = true;
        if (hargaTerdaftar < 0) hargaTerdaftar = 0;
      }
      jasaSyncIds.add(jasaSync);
      hargaTerdaftars.add(hargaTerdaftar);
      hargaBebasFlags.add(hargaBebas ? 1 : 0);
      if (hargaTerdaftar > item.hargaCents && !hasReason) {
        throw PriceRuleViolation(
          'alasan_diskon_wajib',
          'Harga ${item.deskripsi} di bawah harga acuan. '
              'Isi alasan negosiasi/diskon.',
        );
      }
      lines.add(
        PriceLine(
          jenis: item.jenis,
          label: item.deskripsi,
          jumlah: item.jumlah,
          qtyMilli: item.qtyMilli,
          hargaTerdaftar: hargaTerdaftar > 0 ? hargaTerdaftar : item.hargaCents,
          hargaInput: item.hargaCents,
          hargaModal: modal,
          stockItemId: item.stockItemId,
          jasaId: item.jasaId,
          intervalBulan: item.intervalBulan,
        ),
      );
    }
    if (!isOwner &&
        diskonCents > 0 &&
        settings.approvalDiscount &&
        approvalGrant == null) {
      throw StateError(
        'Diskon memerlukan persetujuan pemilik atau penanggung jawab.',
      );
    }
    PriceAllocation allocation;
    try {
      allocation = PriceRules.allocate(
        lines,
        diskonCents: diskonCents,
        allowBelowMinimum: allowBelowMinimum,
        alasanDiskon: alasanDiskon,
        disetujuiOleh: approver,
      );
    } on PriceRuleViolation catch (violation) {
      if (!isOwner &&
          approvalGrant == null &&
          (violation.code == 'di_bawah_batas_minimal' ||
              violation.code == 'diskon_melebihi_margin')) {
        throw PriceRuleViolation(
          'persetujuan_diperlukan',
          '${violation.message} Diperlukan persetujuan pemilik atau '
              'penanggung jawab.',
        );
      }
      rethrow;
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
        if ((base.first['status'] as String? ?? '') != 'aktif') {
          throw StateError('Hanya estimasi aktif yang dapat direvisi.');
        }
        nomor = base.first['nomor_estimasi'] as String;
        versi = ((base.first['versi'] as num?)?.toInt() ?? 1) + 1;
        final bentrok = await txn.query(
          'estimates',
          columns: ['id'],
          where: 'nomor_estimasi = ? AND versi = ? AND deleted_at IS NULL',
          whereArgs: [nomor, versi],
          limit: 1,
        );
        if (bentrok.isNotEmpty) {
          throw StateError(
            'Versi $versi untuk $nomor sudah ada. Muat ulang daftar estimasi.',
          );
        }
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
      final pajak = PajakSnapshot.hitung(
        brutoCents: allocation.total,
        config: settings.pajakConfig,
      );
      final pajakBaris = PajakSnapshot.alokasiBaris(
        snapshot: pajak,
        bases: [
          for (final line in allocation.lines)
            line.subtotal - line.diskonAlokasi,
        ],
      );
      final modeSnapshot = Map<String, Object?>.from(
        modeSaatDibuat ??
            settings.modeSnapshot(jenisTransaksi: transactionEstimasiSaja),
      )
        ..['jenis_transaksi'] = jenisTransaksi
        ..['pajak_estimasi'] = pajak.toJson();
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
        'jenis_transaksi': jenisTransaksi,
        'diskon_cents': allocation.diskon,
        'dpp_cents': pajak.dppCents,
        'ppn_cents': pajak.pajakCents,
        'total_ditagih_cents': pajak.totalCents,
        'pajak_mode': pajak.mode,
        'pajak_persen_bp': pajak.persenBp,
        'pajak_penanggung': pajak.penanggung,
        'total': pajak.totalCents,
        'status': 'aktif',
        'disetujui_oleh': approver,
        'mode_saat_dibuat_json': jsonEncode(modeSnapshot),
        'dibuat_oleh': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final line = allocation.lines[index];
        final share = pajakBaris[index];
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
          'jasa_sync_id': jasaSyncIds[index],
          'deskripsi': item.deskripsi,
          'jumlah': item.qtyMilli ~/ 1000,
          'jumlah_milli': item.qtyMilli,
          'harga_jual_terdaftar': hargaTerdaftars[index],
          'harga_input': item.hargaCents,
          'harga_bebas': hargaBebasFlags[index],
          'dpp_cents': share.dppCents,
          'ppn_cents': share.pajakCents,
          'total_ditagih_cents': share.totalCents,
          'pajak_mode': pajak.mode,
          'pajak_penanggung': pajak.penanggung,
          'harga_batas_saat_transaksi': line.hargaModal,
          'harga_final': line.hargaFinal,
          'harga_modal': line.hargaModal,
          'diskon_alokasi': line.diskonAlokasi,
          'interval_servis_bulan': item.intervalBulan,
          'subtotal': line.subtotal - line.diskonAlokasi,
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
    Future<void> Function(DatabaseExecutor txn, int commissionId)?
        enqueueCommission,
  }) async {
    FeatureGate.require(featureEstimasi);
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
      final qtyMilli =
          (item['jumlah_milli'] as num?)?.toInt() ?? jumlah * 1000;
      final hargaFinal = (item['harga_final'] as num?)?.toInt() ?? 0;
      final hargaTerdaftar =
          (item['harga_jual_terdaftar'] as num?)?.toInt() ?? 0;
      final hargaInput =
          (item['harga_input'] as num?)?.toInt() ?? hargaTerdaftar;
      final hargaBebas =
          ((item['harga_bebas'] as num?)?.toInt() ?? 0) == 1;
      final modal = (item['harga_modal'] as num?)?.toInt() ?? 0;
      final interval = (item['interval_servis_bulan'] as num?)?.toInt() ?? 0;
      if (item['jenis'] == 'part') {
        final stockSync = item['stock_sync_id'] as String? ?? '';
        final stock = await AppDatabase.instance.db.query(
          'stock_items',
          where: 'sync_id = ?',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stock.isEmpty || stock.first['deleted_at'] != null) {
          throw StateError('Barang estimasi tidak ditemukan.');
        }
        final stockItem = StockItem.fromRow(stock.first);
        parts.add(
          PartDraft(
            stockItemId: stockItem.id,
            nama: stockItem.nama,
            jumlah: qtyMilli ~/ 1000,
            qtyMilli: qtyMilli,
            hargaCents: hargaInput <= 0 ? hargaFinal : hargaInput,
            modalCents: stockItem.hargaModalCents,
            hargaTerdaftarCents: hargaTerdaftar,
            intervalBulan: interval,
          ),
        );
      } else {
        final jasaSync = (item['jasa_sync_id'] as String?)?.trim() ?? '';
        int? jasaId;
        var reference = hargaTerdaftar;
        var modalJasa = modal;
        var bebas = hargaBebas;
        if (jasaSync.isNotEmpty) {
          final catalog = await AppDatabase.instance.db.query(
            'harga_jasa',
            where: 'sync_id = ?',
            whereArgs: [jasaSync],
            limit: 1,
          );
          if (catalog.isNotEmpty) {
            jasaId = catalog.first['id'] as int?;
            final current =
                (catalog.first['harga_jual'] as num?)?.toInt() ?? 0;
            modalJasa = (catalog.first['harga_modal'] as num?)?.toInt() ?? 0;
            if (reference <= 0) reference = current;
            // Estimasi adalah penawaran yang sudah disetujui pelanggan.
            // Bila tarif master berubah, harga penawaran dipertahankan dan
            // baris ditandai bebas agar tidak ditolak validasi tarif.
            if (hargaInput != current) bebas = true;
          } else {
            bebas = true;
          }
        } else {
          bebas = true;
        }
        jobs.add(
          JobDraft(
            deskripsi: item['deskripsi'] as String? ?? '',
            jumlah: jumlah,
            hargaCents: hargaInput <= 0 ? hargaFinal : hargaInput,
            jasaId: jasaId,
            modalCents: modalJasa,
            intervalBulan: interval,
            hargaTerdaftarCents: reference,
            hargaBebas: bebas,
          ),
        );
      }
    }
    final diskon = estimate.diskonCents;
    final dasar = jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents) +
        parts.fold<int>(0, (sum, part) => sum + part.subtotalCents);
    if (diskon > dasar) {
      throw StateError(
        'Diskon estimasi melebihi harga item. Periksa ulang estimasi.',
      );
    }
    PajakSnapshot? pajakSnapshot;
    if (estimate.totalDitagihCents > 0 ||
        estimate.dppCents > 0 ||
        estimate.ppnCents > 0) {
      pajakSnapshot = PajakSnapshot(
        active: estimate.pajakMode != pajakModeTanpa,
        mode: estimate.pajakMode,
        persenBp: estimate.pajakPersenBp,
        penanggung: estimate.pajakPenanggung,
        dppCents: estimate.dppCents,
        pajakCents: estimate.ppnCents,
        totalCents: estimate.totalDitagihCents,
        diserapCents:
            estimate.pajakPenanggung == pajakPenanggungBengkel
                ? estimate.ppnCents
                : 0,
      );
    }
    int? customerId;
    int? unitId;
    if ((estimate.customerSyncId ?? '').isNotEmpty) {
      final customerRows = await AppDatabase.instance.db.query(
        'customers',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [estimate.customerSyncId],
        limit: 1,
      );
      customerId =
          customerRows.isEmpty ? null : customerRows.first['id'] as int;
    }
    if ((estimate.unitSyncId ?? '').isNotEmpty) {
      final unitRows = await AppDatabase.instance.db.query(
        'vehicle_or_units',
        columns: ['id', 'customer_id'],
        where: 'sync_id = ?',
        whereArgs: [estimate.unitSyncId],
        limit: 1,
      );
      if (unitRows.isNotEmpty) {
        unitId = unitRows.first['id'] as int;
        customerId ??= unitRows.first['customer_id'] as int?;
      }
    }
    return AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      jenisTransaksi: estimate.jenisTransaksi,
      keluhan: 'Konversi estimasi ${estimate.nomorEstimasi}',
      jobs: jobs,
      parts: parts,
      diskonCents: diskon,
      metodeBayar: metodeBayar,
      bayarCents: bayarCents,
      requestId: 'estimasi:$estimateSyncId',
      actor: actor,
      ownerPin: ownerPin,
      approverSecret: approverSecret,
      workOrderSyncId: estimate.workOrderSyncId,
      estimateSyncId: estimateSyncId,
      totalEstimasiTerakhir: estimate.totalCents,
      pajakSnapshot: pajakSnapshot,
      alasanDiskon: 'Konversi estimasi ${estimate.nomorEstimasi}',
      enqueue: enqueueNote,
      enqueueEstimate: enqueueEstimate,
      enqueueOrder: enqueueOrder,
      enqueueCommission: enqueueCommission,
    );
  }

  Future<WorkOrderRecord> createWorkOrder({
    int? customerId,
    int? unitId,
    required String keluhan,
    String? mekanikSyncId,
    String? mekanikNama,
    required Operator actor,
    Map<String, Object?>? modeSaatDibuat,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueueStatus,
  }) async {
    FeatureGate.require(featureOrderKerja);
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor.role;
    if (!settings.typeEnabled(transactionOrderKerja)) {
      throw StateError('Order kerja sedang dimatikan pemilik.');
    }
    if (!actor.isOwner) {
      Permissions.require(actor, 'buat_order');
      if (!settings.roleCanSelect(role, transactionOrderKerja)) {
        throw StateError('Peran $role tidak berhak membuka order kerja.');
      }
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
    FeatureGate.require(featureOrderKerja);
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
          if (status == 'selesai') 'waktu_selesai': now,
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
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
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

  Future<void> cancelEstimate(
    String syncId, {
    required Operator actor,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    FeatureGate.require(featureEstimasi);
    final settings = await StoreSettingsService.instance.ensure();
    if (!actor.isOwner) {
      Permissions.require(actor, 'buat_estimasi');
      if (!settings.roleCanSelect(actor.role, transactionEstimasiSaja)) {
        throw StateError(
          'Peran ${actor.role} tidak berhak membatalkan estimasi.',
        );
      }
    }
    await AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'estimates',
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Estimasi tidak ditemukan.');
      final row = rows.first;
      final nota = (row['converted_nota_sync_id'] as String?)?.trim() ?? '';
      if (nota.isNotEmpty) {
        throw StateError(
          'Estimasi sudah menjadi nota dan tidak dapat dibatalkan.',
        );
      }
      if ((row['status'] as String? ?? '') != 'aktif') {
        throw StateError('Hanya estimasi aktif yang dapat dibatalkan.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await txn.update(
        'estimates',
        {
          'status': 'batal',
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'sync_id = ?',
        whereArgs: [syncId],
      );
      await txn.insert('permission_audits', {
        'sync_id': newSyncId(),
        'actor': actor.label,
        'target_account_id': actor.employeeId,
        'action': 'batal_estimasi',
        'detail_json': jsonEncode({
          'estimate_sync_id': syncId,
          'nomor_estimasi': row['nomor_estimasi'],
          'versi': row['versi'],
        }),
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, syncId);
    });
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
        r.no_nota AS nota_nomor, r.total_efektif AS nota_total
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
    final start = isoStartOfDay(
      from ?? DateTime.now().subtract(const Duration(days: 30)),
    );
    final end = isoEndOfDay(to ?? DateTime.now());
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
