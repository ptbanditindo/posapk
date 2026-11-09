import '../data/app_database.dart';
import '../data/secure_store.dart';

/// Token relay dan kunci toko harus hidup per toko. Satu perangkat dapat
/// membuka beberapa database toko, sehingga kunci global akan membuat toko
/// kedua memakai kunci toko pertama (dan seluruh amplopnya ditolak).
///
/// Kunci privat perangkat tidak perlu di-scope karena namanya sudah memuat
/// `device.<id>` dan id perangkat selalu unik di dalam database tokonya.
class SyncSecrets {
  SyncSecrets._();

  static final SyncSecrets instance = SyncSecrets._();

  static const Set<String> _scopedKeys = {
    'sync.relay_device_token',
    'sync.store_key',
    'device.current_token',
    'recovery.escrow_bundle',
    'recovery.escrow_phrase',
    'recovery.escrow_shares',
  };

  String _scope() {
    final id = AppDatabase.instance.activeStoreId;
    return id == null || id.isEmpty ? 'utama' : id;
  }

  String _scopedKey(String key, String? scope) =>
      '$key@${scope ?? _scope()}';

  Future<String?> read(String key, {String? storeId}) async {
    if (!_scopedKeys.contains(key)) return SecureStore.instance.read(key);
    final scoped = _scopedKey(key, storeId);
    final value = await SecureStore.instance.read(scoped);
    if (value != null && value.isNotEmpty) return value;
    if (storeId != null) return null;
    // Rahasia global lama selalu milik toko yang terakhir aktif, jadi aman
    // dipindahkan ke namespace toko yang sedang aktif saat ini.
    final legacy = await SecureStore.instance.read(key);
    if (legacy == null || legacy.isEmpty) return null;
    await SecureStore.instance.write(scoped, legacy);
    await SecureStore.instance.delete(key);
    return legacy;
  }

  Future<void> write(String key, String value, {String? storeId}) async {
    if (!_scopedKeys.contains(key)) {
      return SecureStore.instance.write(key, value);
    }
    await SecureStore.instance.write(_scopedKey(key, storeId), value);
  }

  Future<void> delete(String key, {String? storeId}) async {
    if (!_scopedKeys.contains(key)) {
      return SecureStore.instance.delete(key);
    }
    // Hapus juga salinan global lama agar tidak ikut termigrasi ke toko lain
    // pada pembukaan berikutnya.
    await SecureStore.instance.delete(_scopedKey(key, storeId));
    if (storeId == null) await SecureStore.instance.delete(key);
  }
}
