import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../sync/crypto.dart';
import 'app_database.dart';
import 'license_verifier.dart';
import 'secure_store.dart';

const _ownerAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
const _recoveryIterations = 600000;
const _serverTimeKey = 'license.server_time';
const _serverTimeLocalKey = 'license.server_time_local';

class LicenseService {
  LicenseService._();

  static final LicenseService instance = LicenseService._();

  /// Bisa diganti di tes dengan kunci uji.
  static LicenseVerifier verifier = const ServerLicenseVerifier();

  LicenseClaims? _cachedClaims;
  String? _cachedToken;
  DateTime? _anchorServer;
  DateTime? _anchorLocal;
  bool _anchorLoaded = false;

  /// Waktu acuan pemeriksaan lisensi. Bila relay pernah memberi `server_time`,
  /// waktu server dipakai sebagai titik awal dan jam perangkat hanya dihitung
  /// maju; memundurkan jam perangkat tidak memperpanjang lisensi.
  Future<DateTime> effectiveNowUtc() async {
    await _loadAnchor();
    final local = DateTime.now().toUtc();
    final server = _anchorServer;
    if (server == null) return local;
    final anchorLocal = _anchorLocal;
    if (anchorLocal == null) return server.isAfter(local) ? server : local;
    final elapsed = local.difference(anchorLocal);
    if (elapsed.isNegative) return server;
    final projected = server.add(elapsed);
    return projected.isAfter(server) ? projected : server;
  }

  Future<void> _loadAnchor() async {
    if (_anchorLoaded) return;
    _anchorLoaded = true;
    _anchorServer = DateTime.tryParse(
      await AppDatabase.instance.getSetting(_serverTimeKey) ?? '',
    )?.toUtc();
    _anchorLocal = DateTime.tryParse(
      await AppDatabase.instance.getSetting(_serverTimeLocalKey) ?? '',
    )?.toUtc();
  }

  /// Simpan waktu server terakhir yang diterima. Waktu tidak pernah mundur
  /// agar respons relay lama atau jam yang dimundurkan tidak melemahkan
  /// pengecekan masa berlaku.
  Future<void> noteServerTime(Object? value) async {
    final server = DateTime.tryParse('$value')?.toUtc();
    if (server == null) return;
    await _loadAnchor();
    final current = _anchorServer;
    if (current != null && current.isAfter(server)) return;
    final local = DateTime.now().toUtc();
    _anchorServer = server;
    _anchorLocal = local;
    await AppDatabase.instance.setSetting(
      _serverTimeKey,
      server.toIso8601String(),
    );
    await AppDatabase.instance.setSetting(
      _serverTimeLocalKey,
      local.toIso8601String(),
    );
  }

  Future<Map<String, Object?>?> owner() async {
    final rows = await AppDatabase.instance.db.query(
      'owner_identity',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> license() async {
    final rows = await AppDatabase.instance.db.query('license', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> ownerId() async => (await owner())?['owner_id'] as String?;

  Future<String?> ownerPublicKey() async =>
      (await owner())?['public_key'] as String?;

  Future<String> ensureOwner() async {
    final existing = await owner();
    if (existing != null) return existing['owner_id'] as String;
    final random = Random.secure();
    final ownerId = List.generate(
      8,
      (_) => _ownerAlphabet[random.nextInt(_ownerAlphabet.length)],
    ).join();
    final keys = await generateSigningKey();
    final recoveryCode = List.generate(
      12,
      (_) => _ownerAlphabet[random.nextInt(_ownerAlphabet.length)],
    ).join();
    final salt = b64e(List<int>.generate(16, (_) => random.nextInt(256)));
    final recoveryHash = await _derive(recoveryCode, salt, _recoveryIterations);
    await SecureStore.instance
        .write('owner.signing.private', keys.privateKey);
    await SecureStore.instance.write('owner.recovery.code', recoveryCode);
    await AppDatabase.instance.db.insert('owner_identity', {
      'id': 1,
      'owner_id': ownerId,
      'public_key': keys.publicKey,
      'recovery_hash': recoveryHash,
      'recovery_salt': salt,
      'created_at': nowIso(),
    });
    return ownerId;
  }

  Future<String?> recoveryCodeOnce() {
    return SecureStore.instance.read('owner.recovery.code');
  }

  Future<void> clearRecoveryCode() async {
    await SecureStore.instance.delete('owner.recovery.code');
  }

  Future<bool> verifyRecoveryCode(String code) async {
    final row = await owner();
    final hash = row?['recovery_hash'] as String? ?? '';
    final salt = row?['recovery_salt'] as String? ?? '';
    if (hash.isEmpty || salt.isEmpty) return false;
    final legacy = hash.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(hash);
    final derived = legacy
        ? sha256Hex(utf8.encode('$salt:$code'))
        : await _derive(code, salt, _recoveryIterations);
    return derived == hash;
  }

  Future<void> installRemoteOwner({
    required String ownerId,
    required String publicKey,
  }) async {
    final existing = await owner();
    if (existing != null) {
      final localId = existing['owner_id'] as String? ?? '';
      if (localId.isNotEmpty && localId != ownerId) {
        throw StateError(
          'Perangkat ini memakai ID owner $localId, bukan $ownerId. '
          'Gunakan instalasi yang sama atau minta bantuan penjual.',
        );
      }
      final localKey = existing['public_key'] as String? ?? '';
      if (publicKey.isNotEmpty && localKey.isNotEmpty && localKey != publicKey) {
        throw StateError(
          'Kunci publik owner di perangkat ini berbeda dengan yang terdaftar '
          'di server. Minta bantuan penjual.',
        );
      }
      return;
    }
    await AppDatabase.instance.db.insert('owner_identity', {
      'id': 1,
      'owner_id': ownerId,
      'public_key': publicKey,
      'recovery_hash': '',
      'recovery_salt': '',
      'created_at': nowIso(),
    });
  }

  Future<LicenseClaims> installToken(
    String token, {
    String? expectedOwnerId,
  }) async {
    final claims = await verifier.verify(token.trim());
    final localOwner = await ownerId();
    final expected = expectedOwnerId ?? localOwner;
    if ((expected ?? '').isNotEmpty && claims.ownerId != expected) {
      throw LicenseVerifyException('Lisensi milik owner lain.');
    }
    await AppDatabase.instance.db.insert(
      'license',
      {
        'id': 1,
        'plan': claims.plan,
        'period_end': claims.periodEnd.toIso8601String(),
        'store_limit': claims.storeLimit,
        'provider': 'server',
        'token': token.trim(),
        'activated_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _cachedToken = token.trim();
    _cachedClaims = claims;
    return claims.at(await effectiveNowUtc());
  }

  Future<LicenseClaims?> verifiedClaims({bool force = false}) async {
    final row = await license();
    final token = row?['token'] as String? ?? '';
    if (token.isEmpty) return null;
    if (!force && token == _cachedToken) {
      return _cachedClaims?.at(await effectiveNowUtc());
    }
    try {
      final claims = await verifier.verify(token);
      final localOwner = await ownerId();
      if (localOwner != null && localOwner.isNotEmpty &&
          claims.ownerId != localOwner) {
        return null;
      }
      _cachedToken = token;
      _cachedClaims = claims;
      return claims.at(await effectiveNowUtc());
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> status() async {
    final ownerRow = await owner();
    final licenseRow = await license();
    final claims = await verifiedClaims();
    final now = await effectiveNowUtc();
    final storedEnd = DateTime.tryParse(
      licenseRow?['period_end'] as String? ?? '',
    );
    final expired = claims != null
        ? !claims.aktif
        : storedEnd != null && storedEnd.isBefore(now);
    return {
      'owner_id': ownerRow?['owner_id'] ?? '',
      'owner_public_key': ownerRow?['public_key'] ?? '',
      'plan': claims?.plan ?? (licenseRow == null ? 'free' : 'free'),
      'period_end': claims?.periodEnd.toIso8601String() ??
          licenseRow?['period_end'],
      'store_limit': claims?.storeLimit ?? licenseRow?['store_limit'] ?? 1,
      'provider': licenseRow?['provider'] ?? '',
      'expired': expired,
      'premium': claims?.premium ?? false,
      'token': licenseRow?['token'] ?? '',
      'recovery_available': (ownerRow?['recovery_hash'] as String? ?? '').isNotEmpty,
    };
  }

  Future<bool> isPremium() async =>
      (await verifiedClaims())?.premium ?? false;

  void clearCache() {
    _cachedToken = null;
    _cachedClaims = null;
  }

  Future<String?> licenseToken() async =>
      (await license())?['token'] as String?;

  Future<String> _derive(String value, String salt, int iterations) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(value)),
      nonce: base64Url.decode(salt),
    );
    return base64UrlEncode(await key.extractBytes());
  }
}
