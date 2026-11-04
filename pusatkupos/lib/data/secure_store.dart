import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_database.dart';

class SecureStoreException implements Exception {
  SecureStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  /// Fallback database hanya untuk tes/desktop eksplisit.
  static const bool forceDatabase = bool.fromEnvironment('PUSATKU_SECURE_DB');

  /// Dipakai oleh unit test (tanpa plugin platform). Jangan dipakai di UI.
  static bool useDatabaseForTests = false;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool get _databaseMode => forceDatabase || useDatabaseForTests;

  Future<String?> read(String key) async {
    if (_databaseMode) {
      return AppDatabase.instance.getSetting('secure.$key');
    }
    try {
      return await _storage.read(key: key);
    } catch (error) {
      throw SecureStoreException(
        'Penyimpanan aman gagal dibaca ($key). Periksa kunci perangkat '
        'atau setel PUSATKU_SECURE_DB=true untuk mode desktop/tes. ($error)',
      );
    }
  }

  Future<void> write(String key, String value) async {
    if (_databaseMode) {
      await AppDatabase.instance.setSetting('secure.$key', value);
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      throw SecureStoreException(
        'Penyimpanan aman gagal menulis ($key). Data rahasia tidak '
        'disimpan ke database biasa. ($error)',
      );
    }
  }

  Future<void> delete(String key) async {
    if (_databaseMode) {
      await AppDatabase.instance.deleteSetting('secure.$key');
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (error) {
      throw SecureStoreException(
        'Penyimpanan aman gagal menghapus ($key). ($error)',
      );
    }
  }
}
