import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

const transactionJualSparepart = 'jual_sparepart';
const transactionServisLangsung = 'servis_langsung';
const transactionOrderKerja = 'order_kerja';
const transactionEstimasiSaja = 'estimasi_saja';
const transactionPelunasanOrder = 'pelunasan_order';

const transactionTypes = [
  transactionJualSparepart,
  transactionServisLangsung,
  transactionOrderKerja,
  transactionEstimasiSaja,
  transactionPelunasanOrder,
];

const stageNomorOrder = 'nomor_order';
const stageNomorAntrian = 'nomor_antrian';
const stageStatusPengerjaan = 'status_pengerjaan';
const stageEstimasi = 'estimasi';
const stagePersetujuanPelanggan = 'persetujuan_pelanggan';

const orderStages = [
  stageNomorOrder,
  stageNomorAntrian,
  stageStatusPengerjaan,
  stageEstimasi,
  stagePersetujuanPelanggan,
];

const presetLayananLangsung = 'layanan_langsung';
const presetOrderLengkap = 'order_lengkap';
const presetManual = 'manual';

/// Siapa yang boleh menyetujui pengecualian (harga di bawah modal, diskon
/// melebihi batas, koreksi): pemilik atau penanggung jawab yang ditunjuk.
const approverOwner = 'owner';
const approverEmployee = 'penanggung_jawab';

const workOrderStatuses = [
  'antri',
  'diagnosa',
  'menunggu_persetujuan',
  'menunggu_sparepart',
  'dikerjakan',
  'selesai',
  'diambil',
  'batal',
];

/// Status minimal saat saklar pengerjaan dimatikan.
const workOrderStatusesMinimal = ['dibuka', 'selesai', 'diambil', 'batal'];

/// Transisi status yang sah. Transisi di luar peta ini hanya boleh dilakukan
/// pemilik dan dicatat sebagai konflik.
Set<String> allowedWorkOrderTransitions(String from) {
  switch (from) {
    case 'dibuka':
      return const {'selesai', 'batal'};
    case 'antri':
      return const {
        'diagnosa',
        'menunggu_persetujuan',
        'menunggu_sparepart',
        'dikerjakan',
        'batal',
      };
    case 'diagnosa':
      return const {
        'menunggu_persetujuan',
        'menunggu_sparepart',
        'dikerjakan',
        'batal',
      };
    case 'menunggu_persetujuan':
      return const {'menunggu_sparepart', 'dikerjakan', 'batal'};
    case 'menunggu_sparepart':
      return const {'dikerjakan', 'batal'};
    case 'dikerjakan':
      return const {'selesai', 'batal'};
    case 'selesai':
      return const {'diambil'};
    default:
      return const {};
  }
}

class StoreSettings {
  StoreSettings({
    required this.storeId,
    required this.syncId,
    this.types = const {},
    this.stages = const {},
    this.simpanEstimasiLepas = true,
    this.approvalBelowCost = false,
    this.vehicleRequired = true,
    this.approverMode = approverOwner,
    this.approverEmployeeSyncId,
    this.rolePermissions = const {},
    this.preset = presetLayananLangsung,
    this.syncHlcWall = 0,
    this.syncHlcCounter = 0,
  });

  final String storeId;
  final String syncId;
  final Map<String, bool> types;
  final Map<String, bool> stages;
  final bool simpanEstimasiLepas;

  /// Bila aktif, kasir wajib persetujuan PIN pemilik untuk nota dengan harga
  /// di bawah modal. Bila mati (default), kasir bebas mengeluarkan nota dan
  /// selisihnya hanya dicatat sebagai anomali untuk ditinjau pemilik.
  final bool approvalBelowCost;

  /// `owner` atau `penanggung_jawab`. Penanggung jawab harus akun karyawan
  /// aktif yang ditunjuk dan punya izin `setujui`.
  final String approverMode;

  /// Kosong berarti pemilik. Diisi `sync_id` akun karyawan penanggung jawab.
  final String? approverEmployeeSyncId;

  /// Kendaraan wajib untuk servis langsung dan order kerja.
  final bool vehicleRequired;

  final Map<String, Map<String, bool>> rolePermissions;
  final String preset;
  final int syncHlcWall;
  final int syncHlcCounter;

  bool typeEnabled(String type) => types[type] ?? false;

  bool stageEnabled(String stage) => stages[stage] ?? false;

  bool roleAllows(String role, String capability) {
    if (role == 'owner') return true;
    if (role == 'KEDUANYA') {
      return _roleMap('KASIR')[capability] == true ||
          _roleMap('MEKANIK')[capability] == true;
    }
    return _roleMap(role)[capability] ?? false;
  }

  bool roleCanSelect(String role, String type) {
    if (!typeEnabled(type)) return false;
    if (role == 'owner') return true;
    if (!roleAllows(role, 'buat_nota')) return false;
    final perType = _roleMap(role)['jenis_$type'];
    if (perType != null) return perType;
    final allowed = _roleMap(role)['jenis_transaksi'];
    if (allowed == null) return true;
    return allowed;
  }

  Map<String, bool> _roleMap(String role) {
    final raw = rolePermissions[role] ?? const <String, bool>{};
    return raw;
  }

  Map<String, Object?> modeSnapshot({required String jenisTransaksi}) => {
        'versi': '$syncHlcWall.$syncHlcCounter',
        'preset': preset,
        'jenis_transaksi': jenisTransaksi,
        'types': types,
        'stages': stages,
        'simpan_estimasi_lepas': simpanEstimasiLepas,
        'approval_below_cost': approvalBelowCost,
        'vehicle_required': vehicleRequired,
        'approver_mode': approverMode,
        'approver_employee_sync_id': approverEmployeeSyncId,
        'role_permissions': rolePermissions,
        'diambil_at': nowIso(),
      };

  Map<String, Object?> toPayload() => {
        'sync_id': syncId,
        'store_id': storeId,
        'types': types,
        'stages': stages,
        'simpan_estimasi_lepas': simpanEstimasiLepas,
        'approval_below_cost': approvalBelowCost,
        'vehicle_required': vehicleRequired,
        'approver_mode': approverMode,
        'approver_employee_sync_id': approverEmployeeSyncId,
        'role_permissions': rolePermissions,
        'preset': preset,
        'updated_at': nowIso(),
      };

  static StoreSettings fromRow(Map<String, Object?> row) => StoreSettings(
        storeId: row['store_id'] as String,
        syncId: row['sync_id'] as String,
        types: _decodeBoolMap(row['transaction_types_json']),
        stages: _decodeBoolMap(row['order_stages_json']),
        simpanEstimasiLepas:
            ((row['simpan_estimasi_lepas'] as num?)?.toInt() ?? 1) == 1,
        approvalBelowCost:
            ((row['approval_below_cost'] as num?)?.toInt() ?? 0) == 1,
        vehicleRequired:
            ((row['vehicle_required'] as num?)?.toInt() ?? 1) == 1,
        approverMode: row['approver_mode'] as String? ?? approverOwner,
        approverEmployeeSyncId: row['approver_employee_sync_id'] as String?,
        rolePermissions: _decodeRoleMap(row['role_permissions_json']),
        preset: row['preset'] as String? ?? presetLayananLangsung,
        syncHlcWall: (row['sync_hlc_wall'] as num?)?.toInt() ?? 0,
        syncHlcCounter: (row['sync_hlc_counter'] as num?)?.toInt() ?? 0,
      );
}

Map<String, bool> defaultTransactionTypes() => {
      transactionJualSparepart: true,
      transactionServisLangsung: true,
      transactionOrderKerja: true,
      transactionEstimasiSaja: true,
      transactionPelunasanOrder: true,
    };

Map<String, bool> defaultOrderStages() => {
      stageNomorOrder: true,
      stageNomorAntrian: true,
      stageStatusPengerjaan: true,
      stageEstimasi: true,
      stagePersetujuanPelanggan: true,
    };

Map<String, Map<String, bool>> defaultRolePermissions() => {
      'KASIR': {
        'buat_nota': true,
        'ubah_status': false,
        'void': false,
        'koreksi': false,
        'diskon': true,
        'setujui': false,
        'ubah_pengaturan': false,
        'jenis_jual_sparepart': true,
        'jenis_servis_langsung': true,
        'jenis_order_kerja': true,
        'jenis_estimasi_saja': true,
        'jenis_pelunasan_order': false,
      },
      'MEKANIK': {
        'buat_nota': false,
        'ubah_status': true,
        'void': false,
        'koreksi': false,
        'diskon': false,
        'setujui': false,
        'ubah_pengaturan': false,
        'jenis_jual_sparepart': true,
        'jenis_servis_langsung': true,
        'jenis_order_kerja': true,
        'jenis_estimasi_saja': true,
        'jenis_pelunasan_order': false,
      },
    };

StoreSettings presetSettings({
  required String storeId,
  required String syncId,
  required String preset,
  int wall = 0,
  int counter = 0,
}) {
  final types = defaultTransactionTypes();
  final stages = defaultOrderStages();
  if (preset == presetLayananLangsung) {
    types[transactionOrderKerja] = false;
    stages[stageStatusPengerjaan] = false;
  } else if (preset == presetOrderLengkap) {
    for (final type in transactionTypes) {
      types[type] = true;
    }
    for (final stage in orderStages) {
      stages[stage] = true;
    }
  }
  return StoreSettings(
    storeId: storeId,
    syncId: syncId,
    types: Map.unmodifiable(types),
    stages: Map.unmodifiable(stages),
    rolePermissions: Map.unmodifiable(defaultRolePermissions()),
    preset: preset,
    syncHlcWall: wall,
    syncHlcCounter: counter,
  );
}

Map<String, bool> _decodeBoolMap(Object? raw) {
  if (raw is Map) {
    return {
      for (final entry in raw.entries) '${entry.key}': entry.value == true,
    };
  }
  try {
    final decoded = jsonDecode('${raw ?? '{}'}');
    if (decoded is Map) {
      return {
        for (final entry in decoded.entries) '${entry.key}': entry.value == true,
      };
    }
  } catch (_) {}
  return {};
}

Map<String, Map<String, bool>> _decodeRoleMap(Object? raw) {
  if (raw is Map) {
    return {
      for (final entry in raw.entries)
        '${entry.key}': _decodeBoolMap(entry.value),
    };
  }
  try {
    final decoded = jsonDecode('${raw ?? '{}'}');
    if (decoded is Map) {
      return {
        for (final entry in decoded.entries)
          '${entry.key}': _decodeBoolMap(entry.value),
      };
    }
  } catch (_) {}
  return {};
}

class StoreSettingsService {
  StoreSettingsService._();

  static final StoreSettingsService instance = StoreSettingsService._();

  Future<StoreSettings?> read([DatabaseExecutor? executor]) async {
    final target = executor ?? AppDatabase.instance.db;
    final rows = await target.query('store_settings', limit: 1);
    if (rows.isEmpty) return null;
    return StoreSettings.fromRow(rows.first);
  }

  Future<StoreSettings> ensure({DatabaseExecutor? executor}) async {
    final existing = await read(executor);
    if (existing != null) return existing;
    final storeId = AppDatabase.instance.activeStoreId ?? 'utama';
    final settings = presetSettings(
      storeId: storeId,
      syncId: newSyncId(),
      preset: presetLayananLangsung,
    );
    final target = executor ?? AppDatabase.instance.db;
    final now = nowIso();
    await target.insert(
      'store_settings',
      {
        'store_id': settings.storeId,
        'sync_id': settings.syncId,
        'transaction_types_json': jsonEncode(settings.types),
        'order_stages_json': jsonEncode(settings.stages),
        'simpan_estimasi_lepas': settings.simpanEstimasiLepas ? 1 : 0,
        'approval_below_cost': settings.approvalBelowCost ? 1 : 0,
        'vehicle_required': settings.vehicleRequired ? 1 : 0,
        'approver_mode': settings.approverMode,
        'approver_employee_sync_id': settings.approverEmployeeSyncId,
        'role_permissions_json': jsonEncode(settings.rolePermissions),
        'preset': settings.preset,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return (await read(executor)) ?? settings;
  }

  /// Hanya pemilik yang boleh mengubah pengaturan toko. Saat diterapkan dari
  /// sinkronisasi, pelanggaran dicatat sebagai konflik dan nilai lama menang.
  Future<StoreSettings> save({
    required StoreSettings settings,
    required Operator? actor,
    DatabaseExecutor? executor,
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    if (actor != null && !actor.isOwner) {
      throw StateError('Hanya pemilik yang boleh mengubah pengaturan toko.');
    }
    final target = executor ?? AppDatabase.instance.db;
    Future<void> write(DatabaseExecutor txn) async {
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await txn.update(
        'store_settings',
        {
          'transaction_types_json': jsonEncode(settings.types),
          'order_stages_json': jsonEncode(settings.stages),
          'simpan_estimasi_lepas': settings.simpanEstimasiLepas ? 1 : 0,
          'approval_below_cost': settings.approvalBelowCost ? 1 : 0,
          'vehicle_required': settings.vehicleRequired ? 1 : 0,
          'approver_mode': settings.approverMode,
          'approver_employee_sync_id': settings.approverEmployeeSyncId,
          'role_permissions_json': jsonEncode(settings.rolePermissions),
          'preset': settings.preset,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'store_id = ?',
        whereArgs: [settings.storeId],
      );
      if (enqueue != null) await enqueue(txn, settings.syncId);
    }

    if (target is Transaction) {
      await write(target);
    } else {
      await AppDatabase.instance.db.transaction(write);
    }
    return (await read(executor)) ?? settings;
  }

  Future<void> applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final storeId = payload['store_id'] as String? ?? '';
    if (storeId.isEmpty) return;
    final rows = await txn.query(
      'store_settings',
      where: 'store_id = ?',
      whereArgs: [storeId],
      limit: 1,
    );
    final incomingWall = wall;
    final incomingCounter = counter;
    if (rows.isNotEmpty) {
      final localWall = (rows.first['sync_hlc_wall'] as num?)?.toInt() ?? 0;
      final localCounter =
          (rows.first['sync_hlc_counter'] as num?)?.toInt() ?? 0;
      if (localWall > incomingWall ||
          (localWall == incomingWall && localCounter >= incomingCounter)) {
        return;
      }
    }
    final values = {
      'transaction_types_json':
          jsonEncode(payload['types'] ?? const <String, bool>{}),
      'order_stages_json':
          jsonEncode(payload['stages'] ?? const <String, bool>{}),
      'simpan_estimasi_lepas':
          (payload['simpan_estimasi_lepas'] == false) ? 0 : 1,
      'approval_below_cost':
          (payload['approval_below_cost'] == true) ? 1 : 0,
      'vehicle_required': (payload['vehicle_required'] == false) ? 0 : 1,
      'approver_mode': payload['approver_mode'] ?? approverOwner,
      'approver_employee_sync_id': payload['approver_employee_sync_id'],
      'role_permissions_json':
          jsonEncode(payload['role_permissions'] ?? const {}),
      'preset': payload['preset'] ?? presetLayananLangsung,
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'updated_at': payload['updated_at'] ?? nowIso(),
    };
    if (rows.isEmpty) {
      await txn.insert('store_settings', {
        'store_id': storeId,
        'sync_id': payload['sync_id'] ?? newSyncId(),
        ...values,
        'created_at': nowIso(),
      });
    } else {
      await txn.update(
        'store_settings',
        values,
        where: 'store_id = ?',
        whereArgs: [storeId],
      );
    }
  }
}
