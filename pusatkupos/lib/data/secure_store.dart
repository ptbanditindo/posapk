import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_database.dart';

class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const _forceDatabase = bool.fromEnvironment('PUSATKU_SECURE_DB');

  Future<String?> read(String key) async {
    if (_forceDatabase) {
      return AppDatabase.instance.getSetting('secure.$key');
    }
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return AppDatabase.instance.getSetting('secure.$key');
    }
  }

  Future<void> write(String key, String value) async {
    if (_forceDatabase) {
      await AppDatabase.instance.setSetting('secure.$key', value);
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      await AppDatabase.instance.setSetting('secure.$key', value);
    }
  }

  Future<void> delete(String key) async {
    if (_forceDatabase) {
      await AppDatabase.instance.deleteSetting('secure.$key');
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (_) {
      await AppDatabase.instance.deleteSetting('secure.$key');
    }
  }
}
