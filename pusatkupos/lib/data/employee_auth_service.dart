import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/app_config.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../dev/dummy_seed.dart';
import '../sync/crypto.dart';
import '../sync/relay_client.dart';
import '../sync/sync_secrets.dart';
import 'account_service.dart';
import 'app_database.dart';
import 'license_service.dart';
import 'secure_store.dart';
import 'session_service.dart';
import 'store_settings.dart';

class EmployeeAuthException implements Exception {
  EmployeeAuthException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class EmployeeLoginResult {
  const EmployeeLoginResult({
    required this.profile,
    required this.password,
    required this.deviceToken,
    required this.deviceId,
  });

  final SessionProfile profile;
  final String password;
  final String? deviceToken;
  final String? deviceId;
}

class EmployeeAuthService {
  EmployeeAuthService._();

  static final EmployeeAuthService instance = EmployeeAuthService._();

  Map<String, Object?> _map(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const {};
  }

  List<String> _list(Object? value) =>
      value is List ? value.map((item) => '$item').toList() : const [];

  Future<EmployeeLoginResult> login({
    required String ownerId,
    required String username,
    required String password,
    String deviceName = 'Perangkat karyawan',
  }) async {
    if (!serviceConfigured) {
      if (!dummySeedEnabled) {
        throw EmployeeAuthException(
          'Layanan akun belum siap. Hubungi penjual.',
          code: 'service_unavailable',
        );
      }
      final localOwner = await LicenseService.instance.ensureOwner();
      final entered = ownerId.trim();
      if (entered.isNotEmpty && entered != localOwner) {
        throw EmployeeAuthException(
          'ID owner untuk build uji ini: $localOwner.',
          code: 'local_owner',
        );
      }
      final operator = await AccountService.instance.loginLocal(
        username: username,
        password: password,
      );
      if (operator == null) {
        throw EmployeeAuthException(
          'Nama pengguna atau password salah.',
          code: 'invalid_credentials',
        );
      }
      return EmployeeLoginResult(
        profile: SessionProfile(
          mode: 'employee',
          ownerId: localOwner,
          nama: operator.label,
          role: operator.role,
          employeeSyncId: operator.employeeSyncId,
          username: operator.username,
          permissions: operator.permissions.toList(),
          extraPermissions: operator.extraPermissions,
          storeIds: operator.storeIds,
          plan: 'free',
        ),
        password: password,
        deviceToken: null,
        deviceId: null,
      );
    }
    var reuseLocalId = '';
    KeyMaterial? reuseSigning;
    KeyMaterial? reuseEncryption;
    final storedId = await AppDatabase.instance.getSetting('sync.local_device_id');
    if (storedId != null && storedId.isNotEmpty) {
      final rows = await AppDatabase.instance.db.query(
        'devices',
        where: 'id = ? AND kind = ? AND revoked_at IS NULL',
        whereArgs: [storedId, 'employee'],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final privateSign =
            await SecureStore.instance.read('device.$storedId.sign');
        final privateEncrypt =
            await SecureStore.instance.read('device.$storedId.encrypt');
        final publicSign = '${rows.first['public_key'] ?? ''}';
        final publicEncrypt = '${rows.first['encryption_key'] ?? ''}';
        if (privateSign != null &&
            privateEncrypt != null &&
            publicSign.isNotEmpty &&
            publicEncrypt.isNotEmpty) {
          reuseLocalId = storedId;
          reuseSigning = KeyMaterial(
            privateKey: privateSign,
            publicKey: publicSign,
          );
          reuseEncryption = KeyMaterial(
            privateKey: privateEncrypt,
            publicKey: publicEncrypt,
          );
        }
      }
    }
    final signing = reuseSigning ?? await generateSigningKey();
    final encryption = reuseEncryption ?? await generateEncryptionKey();
    Map<String, Object?> result;
    try {
      result = await RelayClient(baseUrl: normalizedServiceUrl).employeeLogin(
        ownerId: ownerId.trim(),
        username: username.trim().toLowerCase(),
        password: password,
        deviceName: deviceName,
        publicKey: signing.publicKey,
        encryptionKey: encryption.publicKey,
      );
    } on RelayException catch (error) {
      throw EmployeeAuthException(
        error.statusCode == 401
            ? 'ID owner, nama pengguna, atau password salah.'
            : 'Tidak dapat masuk saat ini. Coba lagi.',
        code: 'relay_${error.statusCode}',
      );
    } catch (_) {
      throw EmployeeAuthException(
        'Tidak dapat terhubung ke layanan akun. Periksa internet Anda.',
        code: 'network',
      );
    }

    final owner = '${result['owner_id'] ?? ownerId}';
    final account = _map(result['account']);
    final device = _map(result['device']);
    final licenseToken = '${result['license_token'] ?? ''}';
    if (owner.isEmpty || account.isEmpty) {
      throw EmployeeAuthException('Akun karyawan tidak ditemukan.');
    }
    final storeIds = _list(account['store_ids']).isEmpty
        ? const ['utama']
        : _list(account['store_ids']);
    try {
      await LicenseService.instance.installRemoteOwner(
        ownerId: owner,
        publicKey: '${result['owner_public_key'] ?? ''}',
      );
      if (licenseToken.isNotEmpty) {
        await LicenseService.instance.installToken(
          licenseToken,
          expectedOwnerId: owner,
        );
      }
    } catch (error) {
      throw EmployeeAuthException('$error');
    }

    await AppDatabase.instance.setSetting('sync.relay_url', normalizedServiceUrl);
    await AppDatabase.instance.setSetting('sync.store_id', storeIds.first);

    final localId = reuseLocalId.isEmpty ? newSyncId() : reuseLocalId;
    final token = result['token'] as String? ?? '';
    final tokenHash = token.isEmpty
        ? crypto.sha256.convert(utf8.encode(localId)).toString()
        : crypto.sha256.convert(utf8.encode(token)).toString();
    if (reuseLocalId.isEmpty) {
      await AppDatabase.instance.db.insert('devices', {
        'id': localId,
        'owner_id': owner,
        'nama': deviceName,
        'kind': 'employee',
        'employee_account_id': null,
        'public_key': signing.publicKey,
        'encryption_key': encryption.publicKey,
        'token_hash': tokenHash,
        'created_at': nowIso(),
      });
    } else {
      await AppDatabase.instance.db.update(
        'devices',
        {
          'owner_id': owner,
          'nama': deviceName,
          'public_key': signing.publicKey,
          'encryption_key': encryption.publicKey,
          'token_hash': tokenHash,
        },
        where: 'id = ?',
        whereArgs: [localId],
      );
    }
    await SecureStore.instance
        .write('device.$localId.sign', signing.privateKey);
    await SecureStore.instance
        .write('device.$localId.encrypt', encryption.privateKey);
    if (token.isNotEmpty) {
      await SecureStore.instance.write('device.$localId.token', token);
      await SyncSecrets.instance.write('sync.relay_device_token', token);
    }
    await AppDatabase.instance.setSetting('sync.local_device_id', localId);
    final relayDeviceId = '${device['id'] ?? ''}';
    if (relayDeviceId.isNotEmpty) {
      await AppDatabase.instance
          .setSetting('sync.relay_device_id', relayDeviceId);
    }
    await SessionService.instance.saveDeviceToken(token, relayDeviceId);

    final role = '${account['role_base'] ?? 'KASIR'}';
    final grants = account['permission_grants'];
    final extras = _list(
      account['permissions_explicit'] == true && grants is List
          ? grants
          : account['extra_permissions'],
    );
    final settings = await StoreSettingsService.instance.ensure();
    final profile = SessionProfile(
      mode: 'employee',
      ownerId: owner,
      nama: '${account['nama'] ?? username}',
      role: role,
      employeeSyncId: account['sync_id'] as String?,
      username: '${account['username'] ?? username}',
      permissions: settings.accessFor(role, extras: extras).toList(),
      extraPermissions: extras,
      storeIds: storeIds,
      mustChangePassword: account['must_change_password'] == true,
      plan: '${result['plan'] ?? 'premium'}',
      periodEnd: result['period_end'] as String?,
    );
    return EmployeeLoginResult(
      profile: profile,
      password: password,
      deviceToken: token,
      deviceId: relayDeviceId,
    );
  }

  Future<void> changePassword({
    required String ownerId,
    required String username,
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      await RelayClient(baseUrl: normalizedServiceUrl).changeEmployeePassword(
        ownerId: ownerId,
        username: username,
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
    } on RelayException catch (error) {
      throw EmployeeAuthException(
        error.statusCode == 401
            ? 'Password lama salah.'
            : 'Gagal mengganti password. Coba lagi.',
      );
    } catch (_) {
      throw EmployeeAuthException(
        'Tidak dapat terhubung ke layanan akun. Periksa internet Anda.',
      );
    }
  }
}
