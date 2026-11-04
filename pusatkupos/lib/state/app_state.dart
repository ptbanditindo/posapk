import 'package:flutter/material.dart';

import '../auth/operator.dart';
import '../data/app_database.dart';

class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  String storeName = 'PUSATKU POS';
  String storeAddress = '';
  ThemeMode themeMode = ThemeMode.system;
  String? _pinHash;
  int revision = 0;
  int storeRevision = 0;
  Operator? operator;

  bool get pinConfigured => _pinHash != null;
  bool get isOwner => operator?.isOwner ?? false;
  bool can(String permission) => operator?.can(permission) ?? false;
  bool get canWriteMoney => operator?.canWriteMoney ?? false;

  Future<void> load() async {
    final db = AppDatabase.instance;
    storeName = await db.getSetting('bengkel.nama') ?? 'PUSATKU POS';
    storeAddress = await db.getSetting('bengkel.alamat') ?? '';
    _pinHash = await db.getSetting('auth.pin_hash');
    final theme = await db.getSetting('app.theme') ?? 'system';
    themeMode = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> reloadStore() async {
    storeRevision++;
    await load();
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

  Future<void> refreshPinState() async {
    _pinHash = await AppDatabase.instance.getSetting('auth.pin_hash');
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
