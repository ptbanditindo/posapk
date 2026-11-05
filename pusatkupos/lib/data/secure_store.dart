import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pengganti penyimpanan untuk harness E2E yang berjalan sebagai beberapa
/// proses. Hanya diisi oleh test; `null` di produksi sehingga rahasia selalu
/// memakai secure storage platform.
abstract class SecureStoreBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureStoreException implements Exception {
  SecureStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  /// Hanya untuk unit test tanpa plugin platform. Nilai disimpan di memori
  /// proses, bukan di database, sehingga rahasia tetap tidak pernah tertulis
  /// sebagai teks biasa ke `app_settings`.
  static bool useMemoryForTests = false;

  /// Backend pengganti untuk test; hanya diisi oleh kode test.
  static SecureStoreBackend? testBackend;

  static final Map<String, String> _memory = {};

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool get _memoryMode => useMemoryForTests;

  Future<String?> read(String key) async {
    if (_memoryMode) return _memory[key];
    final backend = testBackend;
    if (backend != null) return backend.read(key);
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
    if (_memoryMode) {
      _memory[key] = value;
      return;
    }
    final backend = testBackend;
    if (backend != null) {
      await backend.write(key, value);
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
    if (_memoryMode) {
      _memory.remove(key);
      return;
    }
    final backend = testBackend;
    if (backend != null) {
      await backend.delete(key);
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

  /// Membersihkan penyimpanan memori antar-tes.
  static void clearMemory() => _memory.clear();
}
