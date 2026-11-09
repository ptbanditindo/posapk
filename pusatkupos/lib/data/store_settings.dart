import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'access_control.dart';
import 'app_database.dart';
import 'pajak.dart';

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
    this.approvalDiscount = false,
    this.vehicleRequired = true,
    this.approverMode = approverOwner,
    this.approverEmployeeSyncId,
    this.rolePermissions = const {},
    this.preset = presetLayananLangsung,
    this.pajakAktif = false,
    this.pajakMode = pajakModeEksklusif,
    this.pajakPersenBp = pajakPersenBpDefault,
    this.pajakPenanggung = pajakPenanggungPembeli,
    this.syncHlcWall = 0,
    this.syncHlcCounter = 0,
  });

  final String storeId;
  final String syncId;
  final Map<String, bool> types;
  final Map<String, bool> stages;
  final bool simpanEstimasiLepas;

  /// Bila aktif, setiap diskon kasir wajib persetujuan pemilik atau
  /// penanggung jawab. Diskon tetap dibatasi selisih harga jual dan modal.
  /// Kolom database tetap bernama `approval_below_cost` untuk kompatibilitas.
  final bool approvalDiscount;

  /// `owner` atau `penanggung_jawab`. Penanggung jawab harus akun karyawan
  /// aktif yang ditunjuk dan punya izin `setujui`.
  final String approverMode;

  /// Kosong berarti pemilik. Diisi `sync_id` akun karyawan penanggung jawab.
  final String? approverEmployeeSyncId;

  /// Kendaraan wajib untuk servis langsung dan order kerja.
  final bool vehicleRequired;

  final Map<String, Map<String, bool>> rolePermissions;
  final String preset;

  /// PPN aktif untuk nota baru. Nota lama memakai snapshot masing-masing.
  final bool pajakAktif;
  final String pajakMode;
  final int pajakPersenBp;
  final String pajakPenanggung;

  final int syncHlcWall;
  final int syncHlcCounter;

  PajakConfig get pajakConfig => PajakConfig(
        aktif: pajakAktif,
        mode: pajakMode,
        persenBp: pajakPersenBp,
        penanggung: pajakPenanggung,
      );

  bool get pajakEnabled => pajakConfig.enabled;

  bool typeEnabled(String type) => types[type] ?? false;

  bool stageEnabled(String stage) => stages[stage] ?? false;

  bool roleAllows(String role, String capability) {
    if (role == 'owner') return true;
    final canonical = canonicalRole(role);
    final map = rolePermissions[canonical] ?? rolePermissions[role];
    final stored = map?[capability];
    if (stored != null) return stored;
    if (isBuiltinRole(canonical)) {
      return defaultRoleAccess()[canonical]?[capability] ?? false;
    }
    return false;
  }

  /// Daftar peran yang dapat dipakai. Peran bawaan selalu tersedia; peran
  /// kustom muncul dari peta akses yang disimpan pemilik.
  List<String> get roleNames {
    final result = <String>[];
    void add(String role) {
      final canonical = canonicalRole(role);
      if (canonical.isEmpty || result.contains(canonical)) return;
      result.add(canonical);
    }

    for (final role in builtinRoles) {
      add(role);
    }
    for (final role in rolePermissions.keys) {
      add(role);
    }
    return result;
  }

  /// Izin efektif seorang karyawan: akses peran ditambah izin tambahan akun.
  Set<String> accessFor(
    String role, {
    Iterable<String> extras = const [],
  }) {
    final canonical = canonicalRole(role);
    final result = <String>{};
    if (canonical == 'owner') {
      result.addAll(allAccessKeys());
    } else {
      for (final key in allAccessKeys()) {
        if (roleAllows(canonical, key)) result.add(key);
      }
    }
    result.addAll(extras.where((item) => item.trim().isNotEmpty));
    return result;
  }

  bool roleCanSelect(String role, String type) {
    if (!typeEnabled(type)) return false;
    if (role == 'owner') return true;
    if (!roleAllows(role, 'buat_nota')) return false;
    final perType = _roleMap(role)['jenis_$type'];
    if (perType != null) return perType;
    if (isBuiltinRole(role)) {
      final fallback = defaultRoleAccess()[canonicalRole(role)]?['jenis_$type'];
      if (fallback != null) return fallback;
    }
    final allowed = _roleMap(role)['jenis_transaksi'];
    if (allowed == null) return true;
    return allowed;
  }

  Map<String, bool> _roleMap(String role) {
    final canonical = canonicalRole(role);
    final raw = rolePermissions[canonical] ?? const <String, bool>{};
    return raw;
  }

  Map<String, Object?> modeSnapshot({required String jenisTransaksi}) => {
        'versi': '$syncHlcWall.$syncHlcCounter',
        'preset': preset,
        'jenis_transaksi': jenisTransaksi,
        'types': types,
        'stages': stages,
        'simpan_estimasi_lepas': simpanEstimasiLepas,
        'approval_below_cost': approvalDiscount,
        'vehicle_required': vehicleRequired,
        'approver_mode': approverMode,
        'approver_employee_sync_id': approverEmployeeSyncId,
        'role_permissions': rolePermissions,
        'pajak': pajakConfig.toSnapshot(),
        'diambil_at': nowIso(),
      };

  Map<String, Object?> toPayload() => {
        'sync_id': syncId,
        'store_id': storeId,
        'types': types,
        'stages': stages,
        'simpan_estimasi_lepas': simpanEstimasiLepas,
        'approval_below_cost': approvalDiscount,
        'vehicle_required': vehicleRequired,
        'approver_mode': approverMode,
        'approver_employee_sync_id': approverEmployeeSyncId,
        'role_permissions': rolePermissions,
        'preset': preset,
        'pajak_aktif': pajakAktif,
        'pajak_mode': pajakMode,
        'pajak_persen_bp': pajakPersenBp,
        'pajak_penanggung': pajakPenanggung,
        'updated_at': nowIso(),
      };

  static StoreSettings fromRow(Map<String, Object?> row) => StoreSettings(
        storeId: row['store_id'] as String,
        syncId: row['sync_id'] as String,
        types: _decodeBoolMap(row['transaction_types_json']),
        stages: _decodeBoolMap(row['order_stages_json']),
        simpanEstimasiLepas:
            ((row['simpan_estimasi_lepas'] as num?)?.toInt() ?? 1) == 1,
        approvalDiscount:
            ((row['approval_below_cost'] as num?)?.toInt() ?? 0) == 1,
        vehicleRequired:
            ((row['vehicle_required'] as num?)?.toInt() ?? 1) == 1,
        approverMode: row['approver_mode'] as String? ?? approverOwner,
        approverEmployeeSyncId: row['approver_employee_sync_id'] as String?,
        rolePermissions: _decodeRoleMap(row['role_permissions_json']),
        preset: row['preset'] as String? ?? presetLayananLangsung,
        pajakAktif: ((row['pajak_aktif'] as num?)?.toInt() ?? 0) == 1,
        pajakMode: row['pajak_mode'] as String? ?? pajakModeEksklusif,
        pajakPersenBp:
            (row['pajak_persen_bp'] as num?)?.toInt() ?? pajakPersenBpDefault,
        pajakPenanggung:
            row['pajak_penanggung'] as String? ?? pajakPenanggungPembeli,
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

Map<String, Map<String, bool>> defaultRolePermissions() => defaultRoleAccess();

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
        'approval_below_cost': settings.approvalDiscount ? 1 : 0,
        'vehicle_required': settings.vehicleRequired ? 1 : 0,
        'approver_mode': settings.approverMode,
        'approver_employee_sync_id': settings.approverEmployeeSyncId,
        'role_permissions_json': jsonEncode(settings.rolePermissions),
        'preset': settings.preset,
        'pajak_aktif': settings.pajakAktif ? 1 : 0,
        'pajak_mode': settings.pajakMode,
        'pajak_persen_bp': settings.pajakPersenBp,
        'pajak_penanggung': settings.pajakPenanggung,
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
    if (actor == null || !actor.isOwner) {
      throw StateError('Hanya pemilik yang boleh mengubah pengaturan toko.');
    }
    final pajakError = settings.pajakConfig.validationError();
    if (pajakError != null) throw ArgumentError(pajakError);
    final target = executor ?? AppDatabase.instance.db;
    Future<void> write(DatabaseExecutor txn) async {
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final existing = await txn.query(
        'store_settings',
        columns: [
          'pajak_aktif',
          'pajak_mode',
          'pajak_persen_bp',
          'pajak_penanggung',
        ],
        where: 'store_id = ?',
        whereArgs: [settings.storeId],
        limit: 1,
      );
      await txn.update(
        'store_settings',
        {
          'transaction_types_json': jsonEncode(settings.types),
          'order_stages_json': jsonEncode(settings.stages),
          'simpan_estimasi_lepas': settings.simpanEstimasiLepas ? 1 : 0,
          'approval_below_cost': settings.approvalDiscount ? 1 : 0,
          'vehicle_required': settings.vehicleRequired ? 1 : 0,
          'approver_mode': settings.approverMode,
          'approver_employee_sync_id': settings.approverEmployeeSyncId,
          'role_permissions_json': jsonEncode(settings.rolePermissions),
          'preset': settings.preset,
          'pajak_aktif': settings.pajakAktif ? 1 : 0,
          'pajak_mode': settings.pajakMode,
          'pajak_persen_bp': settings.pajakPersenBp,
          'pajak_penanggung': settings.pajakPenanggung,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'store_id = ?',
        whereArgs: [settings.storeId],
      );
      final now = nowIso();
      final before = existing.isEmpty
          ? const <String, Object?>{}
          : {
              'pajak_aktif':
                  ((existing.first['pajak_aktif'] as num?)?.toInt() ?? 0) == 1,
              'pajak_mode': existing.first['pajak_mode'],
              'pajak_persen_bp': existing.first['pajak_persen_bp'],
              'pajak_penanggung': existing.first['pajak_penanggung'],
            };
      final after = {
        'pajak_aktif': settings.pajakAktif,
        'pajak_mode': settings.pajakMode,
        'pajak_persen_bp': settings.pajakPersenBp,
        'pajak_penanggung': settings.pajakPenanggung,
      };
      final changed = existing.isEmpty ||
          before['pajak_aktif'] != after['pajak_aktif'] ||
          before['pajak_mode'] != after['pajak_mode'] ||
          before['pajak_persen_bp'] != after['pajak_persen_bp'] ||
          before['pajak_penanggung'] != after['pajak_penanggung'];
      if (changed) {
        await txn.insert('business_audits', {
          'sync_id': newSyncId(),
          'store_id': settings.storeId,
          'device_id': '',
          'waktu': now,
          'aktor': actor.label,
          'aktor_employee_sync_id': actor.employeeSyncId,
          'aksi': 'pengaturan_ppn',
          'entity': 'store_settings',
          'entity_id': settings.storeId,
          'before_json': jsonEncode(before),
          'after_json': jsonEncode(after),
          'alasan': null,
          'created_at': now,
          'updated_at': now,
        });
      }
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
    final activeRaw = payload['pajak_aktif'];
    final incomingPajak = PajakConfig(
      aktif: activeRaw == true || activeRaw == 1,
      mode: '${payload['pajak_mode'] ?? pajakModeEksklusif}',
      persenBp: (payload['pajak_persen_bp'] as num?)?.toInt() ??
          pajakPersenBpDefault,
      penanggung: '${payload['pajak_penanggung'] ?? pajakPenanggungPembeli}',
    );
    // Tarif tidak sah dari perangkat lain tidak diterapkan; nilai lokal
    // dipertahankan karena tarif memengaruhi nilai nota berikutnya.
    if (incomingPajak.validationError() != null) return;
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
      'pajak_aktif': incomingPajak.aktif ? 1 : 0,
      'pajak_mode': incomingPajak.mode,
      'pajak_persen_bp': incomingPajak.persenBp,
      'pajak_penanggung': incomingPajak.penanggung,
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
