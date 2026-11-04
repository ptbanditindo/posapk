import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/dates.dart';
import '../core/ids.dart';
import 'app_database.dart';
import 'license_service.dart';
import 'store_platform_stub.dart'
    if (dart.library.io) 'store_platform_io.dart' as platform;
import 'store_registry.dart';

class StoreService {
  StoreService._();

  static final StoreService instance = StoreService._();

  Future<void> _ensureRegistry() async {
    if (StoreRegistry.instance.isOpen) return;
    final db = AppDatabase.instance;
    if (!db.isOpen) {
      throw StateError('Database belum dibuka.');
    }
    final root = p.dirname(db.databasePath);
    await StoreRegistry.instance.open(root);
    await StoreRegistry.instance.ensureDefault(
      db.databasePath,
      nama: await db.getSetting('bengkel.nama') ?? 'Toko utama',
      alamat: await db.getSetting('bengkel.alamat') ?? '',
    );
  }

  Future<StoreRecord> _syntheticStore() async {
    final db = AppDatabase.instance;
    return StoreRecord(
      storeId: 'utama',
      databaseId: 'utama',
      nama: await db.getSetting('bengkel.nama') ?? 'PUSATKU POS',
      alamat: await db.getSetting('bengkel.alamat') ?? '',
      databasePath: db.databasePath,
      createdAt: nowIso(),
    );
  }

  Future<List<StoreRecord>> listStores() async {
    if (kIsWeb) return [await _syntheticStore()];
    await _ensureRegistry();
    final records = await StoreRegistry.instance.stores();
    await _syncActiveLabel(records);
    return records;
  }

  Future<StoreRecord> activeStore() async {
    if (kIsWeb) return _syntheticStore();
    await _ensureRegistry();
    final activeId =
        AppDatabase.instance.activeStoreId ??
            await StoreRegistry.instance.activeId() ??
            'utama';
    final record = await StoreRegistry.instance.byId(activeId);
    if (record != null) return record;
    return StoreRegistry.instance.ensureDefault(
      AppDatabase.instance.databasePath,
      nama: await AppDatabase.instance.getSetting('bengkel.nama') ??
          'Toko utama',
      alamat:
          await AppDatabase.instance.getSetting('bengkel.alamat') ?? '',
    );
  }

  Future<StoreRecord> createStore({
    required String nama,
    String alamat = '',
  }) async {
    if (kIsWeb) {
      throw StateError('Multi-toko tersedia di Android/desktop.');
    }
    await _ensureRegistry();
    if (!await LicenseService.instance.isPremium()) {
      throw StateError(
        'Menambah toko hanya untuk pelanggan Premium.',
      );
    }
    final cleaned = nama.trim();
    if (cleaned.length < 2) {
      throw ArgumentError('Nama toko minimal 2 karakter.');
    }
    if (await StoreRegistry.instance.byName(cleaned) != null) {
      throw ArgumentError('Nama toko sudah dipakai.');
    }
    final databaseId = newSyncId();
    final storeId = 'toko_$databaseId';
    final path = StoreRegistry.instance.newDatabasePath(databaseId);
    await platform.ensureStoreDirectory(path);
    await AppDatabase.instance.createDatabaseAt(
      path,
      settings: {
        'bengkel.nama': cleaned,
        'bengkel.alamat': alamat.trim(),
        'sync.store_id': storeId,
      },
      copyOwner: true,
      copyLicense: true,
    );
    final record = StoreRecord(
      storeId: storeId,
      databaseId: databaseId,
      nama: cleaned,
      alamat: alamat.trim(),
      databasePath: path,
      createdAt: nowIso(),
    );
    await StoreRegistry.instance.insert(record);
    return record;
  }

  Future<StoreRecord> switchStore(
    String storeId, {
    Set<String>? allowedStoreIds,
  }) async {
    if (kIsWeb) {
      throw StateError('Multi-toko tersedia di Android/desktop.');
    }
    await _ensureRegistry();
    if (allowedStoreIds != null && !allowedStoreIds.contains(storeId)) {
      throw StateError('Toko ini tidak ditugaskan untuk akun Anda.');
    }
    final record = await StoreRegistry.instance.byId(storeId);
    if (record == null) {
      throw StateError('Toko tidak ditemukan.');
    }
    if (AppDatabase.instance.activeStoreId == storeId &&
        AppDatabase.instance.isOpen) {
      return record;
    }
    if (!await platform.storeFileExists(record.databasePath)) {
      throw StateError('Berkas toko tidak ditemukan: ${record.nama}.');
    }
    await AppDatabase.instance.switchStore(record);
    await StoreRegistry.instance.setActive(storeId);
    LicenseService.instance.clearCache();
    return record;
  }

  Future<void> _syncActiveLabel(List<StoreRecord> records) async {
    final activeId = AppDatabase.instance.activeStoreId;
    if (activeId == null) return;
    final index = records.indexWhere((row) => row.storeId == activeId);
    if (index < 0) return;
    final nama = await AppDatabase.instance.getSetting('bengkel.nama');
    if (nama == null || nama.trim().isEmpty) return;
    final alamat =
        await AppDatabase.instance.getSetting('bengkel.alamat') ?? '';
    final current = records[index];
    if (current.nama == nama && current.alamat == alamat) return;
    await StoreRegistry.instance.updateName(
      activeId,
      nama: nama,
      alamat: alamat,
    );
    records[index] = StoreRecord(
      storeId: current.storeId,
      databaseId: current.databaseId,
      nama: nama,
      alamat: alamat,
      databasePath: current.databasePath,
      createdAt: current.createdAt,
    );
  }
}
