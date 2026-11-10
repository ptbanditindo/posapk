import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';

const featureEstimasi = 'estimasi';
const featureOrderKerja = 'order_kerja';
const featureSupplierHub = 'supplier_hub';
const featurePurchaseDebt = 'purchase_debt';
const featureFollowup = 'followup';
const featureUnitKendaraan = 'unit_kendaraan';
const featureWhatsapp = 'whatsapp';

class StoreFeature {
  const StoreFeature({
    required this.key,
    required this.label,
    required this.description,
    this.defaultEnabled = true,
    this.optional = true,
    this.dependsOn,
  });

  final String key;
  final String label;
  final String description;
  final bool defaultEnabled;
  final bool optional;
  final String? dependsOn;
}

/// Katalog fitur opsional per toko (BD-26). Fitur wajib tidak ditampilkan
/// sebagai saklar.
const storeFeatureCatalog = <StoreFeature>[
  StoreFeature(
    key: featureEstimasi,
    label: 'Estimasi',
    description:
        'Mencatat perkiraan biaya servis sebelum pelanggan menyetujui.',
  ),
  StoreFeature(
    key: featureOrderKerja,
    label: 'Antrean dan order kerja',
    description:
        'Nomor antrean, status pengerjaan, dan riwayat order kerja.',
  ),
  StoreFeature(
    key: featureSupplierHub,
    label: 'Supplier dan reseller',
    description: 'Daftar supplier dan tindak lanjut untuk reseller.',
  ),
  StoreFeature(
    key: featurePurchaseDebt,
    label: 'Pembelian dan utang supplier',
    description:
        'Nota pembelian, stok masuk, dan pembayaran utang ke supplier.',
    dependsOn: featureSupplierHub,
  ),
  StoreFeature(
    key: featureFollowup,
    label: 'Tindak lanjut pelanggan',
    description: 'Jadwal dan catatan tindak lanjut ke pelanggan.',
  ),
  StoreFeature(
    key: featureUnitKendaraan,
    label: 'Unit kendaraan',
    description: 'Menyimpan kendaraan yang diservis pelanggan.',
  ),
  StoreFeature(
    key: featureWhatsapp,
    label: 'WhatsApp',
    description: 'Membuka chat WhatsApp dari aplikasi.',
  ),
];

StoreFeature? featureDefinition(String key) {
  for (final item in storeFeatureCatalog) {
    if (item.key == key) return item;
  }
  return null;
}

/// Satu pintu katalog fitur: key, default, dependensi, dan status wajib.
class FeatureCatalog {
  FeatureCatalog._();

  static const List<StoreFeature> items = storeFeatureCatalog;

  static StoreFeature? definition(String key) => featureDefinition(key);

  static bool isRequired(String key) => definition(key)?.optional == false;

  static List<StoreFeature> childrenOf(String key) => [
        for (final item in storeFeatureCatalog)
          if (item.dependsOn == key) item,
      ];
}

/// Gerbang tunggal untuk service lokal dan penerapan delta remote.
class FeatureGate {
  FeatureGate._();

  static bool enabled(String key) =>
      FeatureFlagsService.instance.isEnabled(key);

  static void require(String key) =>
      FeatureFlagsService.instance.requireEnabled(key);

  static Future<bool> acceptsRemote(
    DatabaseExecutor txn,
    String key,
    String createdAt,
  ) =>
      FeatureFlagsService.instance.acceptsRemoteAt(txn, key, createdAt);
}

/// Flag fitur per toko yang dibaca dari cache agar menu dapat dibangun tanpa
/// menunggu query. [load] dipanggil setiap kali toko aktif berubah.
class FeatureFlagsService {
  FeatureFlagsService._();

  static final FeatureFlagsService instance = FeatureFlagsService._();

  final Map<String, bool> _cache = {};
  String? _storeId;

  String get _activeStoreId => AppDatabase.instance.activeStoreId ?? 'utama';

  bool get supplierHubEnabled => isEnabled(featureSupplierHub);

  /// Pembelian hanya efektif bila saklar induk hub juga aktif.
  bool get purchaseDebtEnabled =>
      supplierHubEnabled && isEnabled(featurePurchaseDebt);

  bool isEnabled(String key) {
    // Fail-closed: sebelum cache dimuat untuk toko aktif, fitur opsional
    // dianggap mati agar tidak ada penulisan selama status belum diketahui.
    if (featureDefinition(key) == null) return false;
    if (_storeId != _activeStoreId) return false;
    return _cache[key] ?? false;
  }

  Future<void> load({DatabaseExecutor? executor}) async {
    final target = executor ?? AppDatabase.instance.db;
    final storeId = _activeStoreId;
    final rows = await target.query(
      'store_features',
      columns: ['feature_key', 'enabled'],
      where: 'store_id = ? AND deleted_at IS NULL',
      whereArgs: [storeId],
    );
    _cache.clear();
    for (final item in storeFeatureCatalog) {
      _cache[item.key] = item.defaultEnabled;
    }
    for (final row in rows) {
      _cache['${row['feature_key']}'] =
          (row['enabled'] as num?)?.toInt() == 1;
    }
    _storeId = storeId;
  }

  void resetForStore() {
    _cache.clear();
    _storeId = null;
  }

  void requireEnabled(String key) {
    final definition = featureDefinition(key);
    if (definition == null) return;
    if (!isEnabled(key)) {
      throw StateError('Fitur "${definition.label}" dinonaktifkan pemilik.');
    }
  }

  void requirePurchaseDebt() {
    requireEnabled(featureSupplierHub);
    if (!isEnabled(featurePurchaseDebt)) {
      throw StateError(
        'Fitur "Pembelian dan utang supplier" dinonaktifkan pemilik.',
      );
    }
  }

  /// Data historis tetap diterima saat fitur dimatikan; hanya data yang
  /// dibuat setelah waktu penonaktifan yang ditolak.
  Future<bool> acceptsRemoteAt(
    DatabaseExecutor txn,
    String key,
    String createdAt,
  ) async {
    final rows = await txn.query(
      'store_features',
      columns: ['enabled', 'updated_at'],
      where: 'store_id = ? AND feature_key = ?',
      whereArgs: [_activeStoreId, key],
      limit: 1,
    );
    if (rows.isEmpty || (rows.first['enabled'] as num?)?.toInt() == 1) {
      return true;
    }
    final changedAt = DateTime.tryParse('${rows.first['updated_at'] ?? ''}');
    final created = DateTime.tryParse(createdAt);
    if (changedAt == null || created == null) return false;
    return created.isBefore(changedAt);
  }

  /// Hanya pemilik penuh yang boleh mengubah. Karyawan dan viewer ditolak
  /// oleh service, bukan hanya oleh UI.
  Future<void> setEnabled({
    required String key,
    required bool enabled,
    required Operator actor,
    String? reason,
    Future<void> Function(Transaction txn, String syncId)? enqueue,
  }) async {
    if (!actor.isOwner) {
      throw StateError('Hanya pemilik yang boleh mengubah fitur toko.');
    }
    final definition = featureDefinition(key);
    if (definition == null) {
      throw ArgumentError('Fitur "$key" tidak dikenal.');
    }
    if (!definition.optional) {
      throw StateError('Fitur "${definition.label}" bersifat wajib.');
    }
    if (enabled &&
        definition.dependsOn != null &&
        !isEnabled(definition.dependsOn!)) {
      final parent = featureDefinition(definition.dependsOn!);
      throw StateError(
        'Aktifkan "${parent?.label ?? definition.dependsOn}" lebih dahulu.',
      );
    }
    final storeId = _activeStoreId;
    await AppDatabase.instance.db.transaction((txn) async {
      final rows = await txn.query(
        'store_features',
        where: 'store_id = ? AND feature_key = ?',
        whereArgs: [storeId, key],
        limit: 1,
      );
      final current =
          rows.isEmpty ? definition.defaultEnabled : rows.first['enabled'] == 1;
      if (current == enabled && rows.isNotEmpty) return;
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final now = nowIso();
      final syncId =
          rows.isEmpty ? newSyncId() : '${rows.first['sync_id'] ?? newSyncId()}';
      final deviceRows = await txn.query(
        'app_meta',
        columns: ['key', 'value'],
        where: "key IN ('sync.relay_device_id', 'device.current_id')",
      );
      final deviceSettings = {
        for (final row in deviceRows) '${row['key']}': '${row['value']}',
      };
      final deviceId = deviceSettings['sync.relay_device_id'] ??
          deviceSettings['device.current_id'] ??
          '';
      final version =
          ((rows.isEmpty ? 0 : rows.first['version'] as num?)?.toInt() ?? 0) + 1;
      final values = {
        'store_id': storeId,
        'feature_key': key,
        'sync_id': syncId,
        'device_id': deviceId,
        'enabled': enabled ? 1 : 0,
        'version': version,
        'updated_by': actor.label,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'updated_at': now,
        'deleted_at': null,
      };
      if (rows.isEmpty) {
        await txn.insert('store_features', {
          ...values,
          'created_at': now,
        });
      } else {
        await txn.update(
          'store_features',
          values,
          where: 'store_id = ? AND feature_key = ?',
          whereArgs: [storeId, key],
        );
      }
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': storeId,
        'device_id': deviceId,
        'waktu': now,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': enabled ? 'fitur_aktif' : 'fitur_nonaktif',
        'entity': 'store_feature',
        'entity_id': key,
        'before_json': jsonEncode({'enabled': current}),
        'after_json': jsonEncode({'enabled': enabled}),
        'alasan': reason,
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('feature_audits', {
        'store_id': storeId,
        'feature_key': key,
        'before_enabled': current ? 1 : 0,
        'after_enabled': enabled ? 1 : 0,
        'actor': actor.label,
        'actor_employee_sync_id': actor.employeeSyncId,
        'reason': reason,
        'created_at': now,
      });
      if (enqueue != null) await enqueue(txn, syncId);
    });
    _cache[key] = enabled;
  }

  /// Riwayat perubahan fitur untuk layar pengaturan. Pembacaan tidak
  /// dipengaruhi status ON/OFF agar histori tetap terlihat.
  Future<List<Map<String, Object?>>> history({
    String? key,
    int limit = 20,
  }) async {
    final storeId = _activeStoreId;
    return AppDatabase.instance.db.query(
      'feature_audits',
      where: key == null ? 'store_id = ?' : 'store_id = ? AND feature_key = ?',
      whereArgs: key == null ? [storeId] : [storeId, key],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
  }

  Future<void> applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final storeId = '${payload['store_id'] ?? ''}';
    final key = '${payload['feature_key'] ?? ''}';
    if (storeId.isEmpty || key.isEmpty) return;
    if (featureDefinition(key) == null) return;
    final rows = await txn.query(
      'store_features',
      where: 'store_id = ? AND feature_key = ?',
      whereArgs: [storeId, key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final localWall = (rows.first['sync_hlc_wall'] as num?)?.toInt() ?? 0;
      final localCounter =
          (rows.first['sync_hlc_counter'] as num?)?.toInt() ?? 0;
      final localDevice = '${rows.first['device_id'] ?? ''}';
      final remoteDevice = '${payload['device_id'] ?? ''}';
      // HLC terbaru menang; HLC sama diputus device_id terkecil (Lampiran C).
      final localWins = localWall > wall ||
          (localWall == wall &&
              (localCounter > counter ||
                  (localCounter == counter &&
                      (localDevice.isEmpty ||
                          localDevice.compareTo(remoteDevice) <= 0))));
      if (localWins) return;
    }
    final enabled = payload['enabled'] == true ? 1 : 0;
    final values = {
      'sync_id': payload['sync_id'] ?? newSyncId(),
      'device_id': payload['device_id'] ?? '',
      'enabled': enabled,
      'version': (payload['version'] as num?)?.toInt() ?? 1,
      'updated_by': payload['updated_by'],
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'updated_at': payload['updated_at'] ?? nowIso(),
      'deleted_at': null,
    };
    if (rows.isEmpty) {
      await txn.insert('store_features', {
        'store_id': storeId,
        'feature_key': key,
        ...values,
        'created_at': nowIso(),
      });
    } else {
      await txn.update(
        'store_features',
        values,
        where: 'store_id = ? AND feature_key = ?',
        whereArgs: [storeId, key],
      );
    }
    // Pilihan sub-fitur tetap disimpan walau induk dimatikan; efeknya dihitung
    // oleh getter purchaseDebtEnabled.
    if (storeId == _activeStoreId) {
      _cache[key] = enabled == 1;
      _storeId = storeId;
    }
  }
}
