import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/relay_url.dart';
import '../sync/crypto.dart';
import '../sync/relay_client.dart';
import 'account_service.dart';
import 'app_database.dart';
import 'license_service.dart';
import 'license_verifier.dart';
import 'secure_store.dart';

class PairingService {
  PairingService._();

  static final PairingService instance = PairingService._();

  Future<Map<String, Object?>> claim({
    required String relayUrl,
    required String code,
    required String deviceName,
  }) async {
    final url = normalizeRelayUrl(relayUrl);
    if (code.trim().length < 4) throw ArgumentError('Kode undangan tidak valid.');
    final signing = await generateSigningKey();
    final encryption = await generateEncryptionKey();
    final response = await RelayClient(baseUrl: url).claimInvite(
      code: code,
      nama: deviceName,
      publicKey: signing.publicKey,
      encryptionKey: encryption.publicKey,
    );
    final account = Map<String, Object?>.from(
      response['account'] as Map? ?? const {},
    );
    final permission = Map<String, Object?>.from(
      response['permission'] as Map? ?? const {},
    );
    final relayDevice = Map<String, Object?>.from(
      response['device'] as Map? ?? const {},
    );
    final payload = Map<String, Object?>.from(
      permission['payload'] as Map? ?? const {},
    );
    final signer = permission['signer_public_key'] as String? ?? '';
    final signature = permission['signature'] as String? ?? '';
    final ownerPublic = response['owner_public_key'] as String? ?? '';
    if (ownerPublic.isEmpty) {
      throw StateError(
        'Kode undangan tidak membawa kunci publik owner. '
        'Perubahan relay diperlukan untuk pairing aman.',
      );
    }
    final pinnedRows = await AppDatabase.instance.db.query(
      'owner_identity',
      limit: 1,
    );
    if (pinnedRows.isNotEmpty) {
      final pinned = pinnedRows.first['public_key'] as String? ?? '';
      if (pinned.isNotEmpty && pinned != ownerPublic) {
        throw StateError(
          'Kunci owner dari undangan berbeda dengan kunci yang sudah dipin. '
          'Pairing dibatalkan.',
        );
      }
    }
    if (!isTrustedPermissionSigner(signer, ownerPublic)) {
      throw StateError(
        'Tanda tangan izin bukan dari kunci owner yang dipin.',
      );
    }
    if (!await verifyPayload(
      signer,
      utf8.encode(canonicalJson(payload)),
      signature,
    )) {
      throw StateError('Tanda tangan izin karyawan tidak valid.');
    }
    final accountId = await AccountService.instance.installRemoteAccount(account);
    // Kode pairing menggantikan password saat pemasangan; jangan memaksa
    // karyawan mengganti password yang tidak pernah ia masukkan.
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {'must_change_password': 0},
      where: 'id = ?',
      whereArgs: [accountId],
    );
    final ownerId = account['owner_id'] as String? ?? '';
    final storeId = response['store_id'] as String? ?? 'utama';
    final token = response['token'] as String? ?? '';
    final relayId = relayDevice['id'] as String? ?? '';
    final localId = newSyncId();
    final name = deviceName.trim().isEmpty
        ? 'Perangkat karyawan'
        : deviceName.trim();
    final now = nowIso();
    await AppDatabase.instance.db.insert('devices', {
      'id': localId,
      'owner_id': ownerId,
      'nama': name,
      'kind': 'employee',
      'employee_account_id': accountId,
      'public_key': signing.publicKey,
      'encryption_key': encryption.publicKey,
      'token_hash': crypto.sha256.convert(utf8.encode(token)).toString(),
      'created_at': now,
    });
    await SecureStore.instance.write('device.$localId.sign', signing.privateKey);
    await SecureStore.instance
        .write('device.$localId.encrypt', encryption.privateKey);
    await SecureStore.instance.write('device.$localId.token', token);
    await SecureStore.instance.write('device.current_token', token);
    await SecureStore.instance.write('sync.relay_device_token', token);
    await AppDatabase.instance.setSetting('device.current_id', localId);
    await AppDatabase.instance.setSetting('sync.local_device_id', localId);
    await AppDatabase.instance.setSetting('sync.relay_device_id', relayId);
    await AppDatabase.instance.setSetting('sync.store_id', storeId);
    await AppDatabase.instance.setSetting('sync.relay_url', url);
    await AppDatabase.instance.setSetting('app.role', 'employee');
    await AppDatabase.instance.setSetting(
      'employee.permission.${account['sync_id']}',
      jsonEncode({
        'payload': payload,
        'signature': signature,
        'signer_public_key': signer,
      }),
    );
    final owner = await AppDatabase.instance.db.query('owner_identity', limit: 1);
    if (owner.isEmpty) {
      await AppDatabase.instance.db.insert('owner_identity', {
        'id': 1,
        'owner_id': ownerId,
        'public_key': ownerPublic,
        'created_at': now,
      });
    } else if ((owner.first['public_key'] as String? ?? '').isEmpty) {
      await AppDatabase.instance.db.update(
        'owner_identity',
        {'public_key': ownerPublic},
        where: 'id = ?',
        whereArgs: [owner.first['id']],
      );
    }
    final licenseToken = response['license_token'] as String? ?? '';
    if (licenseToken.isNotEmpty) {
      await LicenseService.instance.installToken(
        licenseToken,
        expectedOwnerId: ownerId,
      );
    }
    final claims = await LicenseService.instance.verifiedClaims(force: true);
    if (claims == null || !claims.premium) {
      throw StateError(
        'Relay tidak mengirim token lisensi server yang valid. '
        'Pairing ditolak; perubahan relay diperlukan.',
      );
    }
    return {
      'owner_id': ownerId,
      'account_id': accountId,
      'username': account['username'],
      'nama': account['nama'],
      'store_id': storeId,
      'relay_device_id': relayId,
      'encryption_key': encryption.publicKey,
      'permission_version': account['permission_version'],
    };
  }
}
