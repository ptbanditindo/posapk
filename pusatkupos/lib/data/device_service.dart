import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/crypto.dart';
import 'app_database.dart';
import 'license_service.dart';
import 'secure_store.dart';

class DeviceService {
  DeviceService._();

  static final DeviceService instance = DeviceService._();

  Future<List<Map<String, Object?>>> listDevices() {
    return AppDatabase.instance.db.query(
      'devices',
      orderBy: 'created_at',
    );
  }

  Future<Map<String, Object?>?> currentDevice() async {
    final id = await AppDatabase.instance.getSetting('device.current_id');
    if (id == null || id.isEmpty) return null;
    final rows = await AppDatabase.instance.db.query(
      'devices',
      where: 'id = ? AND revoked_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> currentToken() =>
      SecureStore.instance.read('device.current_token');

  Future<Map<String, Object?>> registerDevice({
    required String nama,
    required String kind,
    int? employeeAccountId,
    bool makeCurrent = false,
  }) async {
    final ownerId = await LicenseService.instance.ownerId();
    if (ownerId == null) {
      throw StateError('Aktifkan lisensi premium terlebih dahulu.');
    }
    final license = await LicenseService.instance.license();
    final limit = (license?['device_limit'] as int?) ?? 1;
    if (kind == 'owner') {
      final rows = await AppDatabase.instance.db.rawQuery(
        "SELECT COUNT(*) AS total FROM devices WHERE kind = 'owner' "
        'AND revoked_at IS NULL',
      );
      final count = rows.first['total'] as int? ?? 0;
      if (count >= limit) {
        throw StateError(
          'Batas $limit perangkat owner sudah terpakai. Cabut perangkat lama.',
        );
      }
    }
    final signing = await generateSigningKey();
    final encryption = await generateEncryptionKey();
    final token = newToken();
    final id = newSyncId();
    await AppDatabase.instance.db.insert('devices', {
      'id': id,
      'owner_id': ownerId,
      'nama': nama.trim().isEmpty ? 'Perangkat' : nama.trim(),
      'kind': kind,
      'employee_account_id': employeeAccountId,
      'public_key': signing.publicKey,
      'encryption_key': encryption.publicKey,
      'token_hash': crypto.sha256.convert(utf8.encode(token)).toString(),
      'created_at': nowIso(),
    });
    await SecureStore.instance.write('device.$id.sign', signing.privateKey);
    await SecureStore.instance
        .write('device.$id.encrypt', encryption.privateKey);
    await SecureStore.instance.write('device.$id.token', token);
    if (makeCurrent) {
      await AppDatabase.instance.setSetting('device.current_id', id);
      await SecureStore.instance.write('device.current_token', token);
    }
    return {
      'id': id,
      'nama': nama,
      'kind': kind,
      'public_key': signing.publicKey,
      'encryption_key': encryption.publicKey,
      'token': makeCurrent ? null : token,
      'limit': limit,
    };
  }

  Future<void> revokeDevice(String id, {String reason = 'dicabut pemilik'}) async {
    await AppDatabase.instance.db.update(
      'devices',
      {'revoked_at': nowIso(), 'revoked_reason': reason},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (await AppDatabase.instance.getSetting('device.current_id') == id) {
      await AppDatabase.instance.deleteSetting('device.current_id');
      await SecureStore.instance.delete('device.current_token');
    }
  }

  Future<Map<String, Object?>?> authenticateToken(String token) async {
    final hash = crypto.sha256.convert(utf8.encode(token)).toString();
    final rows = await AppDatabase.instance.db.query(
      'devices',
      where: 'token_hash = ? AND revoked_at IS NULL',
      whereArgs: [hash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    await AppDatabase.instance.db.update(
      'devices',
      {'last_seen_at': nowIso()},
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
    return rows.first;
  }

  Future<String?> privateKey(String deviceId) =>
      SecureStore.instance.read('device.$deviceId.sign');

  Future<String?> encryptionPrivateKey(String deviceId) =>
      SecureStore.instance.read('device.$deviceId.encrypt');
}

