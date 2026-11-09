import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth/operator.dart';
import '../data/app_database.dart';
import '../data/feature_flags.dart';
import '../data/pin_service.dart';
import '../data/restore_lock.dart';
import '../data/store_settings.dart';

/// Tahap UI yang boleh ditampilkan. Aksi tulis hanya dibuka pada `ready`.
enum AppScene {
  starting,
  unauthenticated,
  ready,
  recovering,
  restoring,
  switchingStore,
}

class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  String storeName = 'PUSATKU POS';
  String storeAddress = '';
  ThemeMode themeMode = ThemeMode.system;
  int autoLockMinutes = 5;
  String? _pinHash;
  int revision = 0;
  int storeRevision = 0;
  Operator? operator;
  bool _booted = false;
  bool _switchingStore = false;

  bool get pinConfigured => _pinHash != null;
  bool get isOwner => operator?.isOwner ?? false;

  AppScene get scene {
    if (RestoreLock.instance.isRestoring) return AppScene.restoring;
    if (_switchingStore) return AppScene.switchingStore;
    if (!_booted) return AppScene.starting;
    if (operator != null) return AppScene.ready;
    if (pinConfigured) return AppScene.recovering;
    return AppScene.unauthenticated;
  }

  void beginStoreSwitch() {
    if (_switchingStore) return;
    _switchingStore = true;
    notifyListeners();
  }

  void endStoreSwitch() {
    if (!_switchingStore) return;
    _switchingStore = false;
    notifyListeners();
  }

  /// Dipakai operasi tulis: tidak boleh ada fallback identitas "owner".
  Operator get requireOperator {
    final current = operator;
    if (current == null) {
      throw StateError('Sesi operator tidak aktif. Silakan login ulang.');
    }
    return current;
  }

  bool can(String permission) => operator?.can(permission) ?? false;
  bool get canWriteMoney => operator?.canWriteMoney ?? false;

  Future<void> load() async {
    final db = AppDatabase.instance;
    storeName = await db.getSetting('bengkel.nama') ?? 'PUSATKU POS';
    storeAddress = await db.getSetting('bengkel.alamat') ?? '';
    _pinHash = await PinService.instance.isConfigured() ? 'set' : null;
    autoLockMinutes =
        int.tryParse(await db.getSetting('security.auto_lock_minutes') ?? '') ??
            5;
    final theme = await db.getSetting('app.theme') ?? 'system';
    themeMode = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    await FeatureFlagsService.instance.load();
    _booted = true;
    notifyListeners();
  }

  Future<void> reloadStore() async {
    storeRevision++;
    await load();
    await refreshOperatorAccess();
    notifyListeners();
  }

  /// Menghitung ulang izin karyawan untuk toko yang sedang aktif.
  ///
  /// Setiap toko memiliki peta peran sendiri, sehingga izin dari toko lama
  /// tidak boleh terbawa setelah berpindah toko.
  Future<void> refreshOperatorAccess() async {
    final current = operator;
    if (current == null || current.isOwner) return;
    final storeId = AppDatabase.instance.activeStoreId ?? 'utama';
    final employeeSync = current.employeeSyncId;
    if (employeeSync == null || employeeSync.isEmpty) return;
    final account = await AppDatabase.instance.db.query(
      'employee_accounts',
      columns: ['role_base', 'extra_permissions_json', 'aktif'],
      where: 'sync_id = ?',
      whereArgs: [employeeSync],
      limit: 1,
    );
    if (account.isNotEmpty && (account.first['aktif'] as int? ?? 1) == 0) {
      operator = null;
      notifyListeners();
      throw StateError('Akun karyawan ini sudah dinonaktifkan pemilik.');
    }
    final accessRows = await AppDatabase.instance.db.query(
      'employee_store_access',
      columns: ['store_id', 'role_base', 'extra_permissions_json', 'aktif'],
      where: 'employee_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [employeeSync],
    );
    final activeStores = accessRows
        .where((row) => (row['aktif'] as int? ?? 1) == 1)
        .map((row) => '${row['store_id']}')
        .toSet();
    if (activeStores.isNotEmpty && !activeStores.contains(storeId)) {
      throw StateError('Akun ini tidak memiliki akses ke toko tersebut.');
    }
    final access = accessRows
        .where((row) => '${row['store_id']}' == storeId)
        .toList();
    if (access.isEmpty && !current.storeIds.contains(storeId)) {
      throw StateError('Akun ini tidak memiliki akses ke toko tersebut.');
    }
    if (access.isNotEmpty && (access.first['aktif'] as int? ?? 1) == 0) {
      throw StateError('Akses akun ke toko ini sudah dicabut.');
    }
    final role = access.isNotEmpty
        ? '${access.first['role_base'] ?? current.role}'
        : (account.isNotEmpty
              ? '${account.first['role_base'] ?? current.role}'
              : current.role);
    final rawExtras = access.isNotEmpty
        ? access.first['extra_permissions_json']
        : account.isNotEmpty
        ? account.first['extra_permissions_json']
        : null;
    final extras = <String>[];
    if (rawExtras is String && rawExtras.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawExtras);
        if (decoded is List) {
          extras.addAll(decoded.map((item) => '$item'));
        }
      } on FormatException {
        // Peta izin rusak diperlakukan sebagai tanpa izin tambahan.
      }
    }
    final settings = await StoreSettingsService.instance.ensure();
    operator = current.withAccess(
      role: role,
      permissions: settings.accessFor(role, extras: extras),
      extraPermissions: extras,
      storeIds: activeStores.isEmpty ? current.storeIds : activeStores.toList(),
    );
    notifyListeners();
  }

  Future<void> saveStoreInfo(String nama, String alamat) async {
    storeName = nama.trim().isEmpty ? 'PUSATKU POS' : nama.trim();
    storeAddress = alamat.trim();
    await AppDatabase.instance
        .setSetting('bengkel.nama', storeName);
    await AppDatabase.instance
        .setSetting('bengkel.alamat', storeAddress);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await AppDatabase.instance.setSetting(
      'app.theme',
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      },
    );
    notifyListeners();
  }

  Future<void> setAutoLockMinutes(int minutes) async {
    autoLockMinutes = minutes < 0 ? 0 : minutes;
    await AppDatabase.instance.setSetting(
      'security.auto_lock_minutes',
      '$autoLockMinutes',
    );
    notifyListeners();
  }

  Future<void> refreshPinState() async {
    _pinHash = await PinService.instance.isConfigured() ? 'set' : null;
    notifyListeners();
  }

  void setOperator(Operator? value) {
    operator = value;
    notifyListeners();
  }

  void touch() {
    revision++;
    notifyListeners();
  }
}
