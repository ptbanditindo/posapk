import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStoreException implements Exception {
  SecureStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (error) {
      throw SecureStoreException(
        'Penyimpanan aman gagal dibaca ($key). Periksa kunci perangkat atau '
        'dukungan keystore. ($error)',
      );
    }
  }

  Future<void> write(String key, String value) async {
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
    try {
      await _storage.delete(key: key);
    } catch (error) {
      throw SecureStoreException(
        'Penyimpanan aman gagal menghapus ($key). ($error)',
      );
    }
  }
}
