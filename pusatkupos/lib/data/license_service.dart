import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../sync/crypto.dart';
import 'app_database.dart';
import 'secure_store.dart';

const _ownerAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

class LicenseService {
  LicenseService._();

  static final LicenseService instance = LicenseService._();

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
    final recoveryHash = sha256Hex(utf8.encode('$salt:$recoveryCode'));
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

  Future<Map<String, Object?>> activate({
    required int days,
    required int deviceLimit,
    String provider = 'manual',
  }) async {
    final ownerIdValue = await ensureOwner();
    final privateKey = await SecureStore.instance
        .read('owner.signing.private');
    if (privateKey == null) {
      throw StateError('Kunci owner tidak tersedia.');
    }
    final now = DateTime.now();
    final periodEnd = now.add(Duration(days: days));
    final payload = {
      'v': 1,
      'owner_id': ownerIdValue,
      'plan': 'premium',
      'period_end': periodEnd.toIso8601String(),
      'device_limit': deviceLimit,
      'provider': provider,
      'issued_at': now.toIso8601String(),
    };
    final raw = canonicalJson(payload).codeUnits;
    final signature = await signPayload(privateKey, raw);
    final token = '${b64e(raw)}.$signature';
    await AppDatabase.instance.db.insert(
      'license',
      {
        'id': 1,
        'plan': 'premium',
        'period_end': periodEnd.toIso8601String(),
        'device_limit': deviceLimit,
        'provider': provider,
        'token': token,
        'activated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return {
      'owner_id': ownerIdValue,
      'period_end': periodEnd.toIso8601String(),
      'device_limit': deviceLimit,
      'provider': provider,
    };
  }

  Future<void> renew({required int days}) async {
    final row = await license();
    if (row == null) throw StateError('Lisensi belum aktif.');
    final current = DateTime.tryParse(row['period_end'] as String? ?? '');
    final base = current != null && current.isAfter(DateTime.now())
        ? current
        : DateTime.now();
    final periodEnd = base.add(Duration(days: days));
    final ownerIdValue = await ownerId();
    final privateKey = await SecureStore.instance
        .read('owner.signing.private');
    if (ownerIdValue == null || privateKey == null) {
      throw StateError('Identitas owner tidak lengkap.');
    }
    final payload = {
      'v': 1,
      'owner_id': ownerIdValue,
      'plan': 'premium',
      'period_end': periodEnd.toIso8601String(),
      'device_limit': row['device_limit'],
      'provider': row['provider'],
      'issued_at': nowIso(),
    };
    final raw = canonicalJson(payload).codeUnits;
    final signature = await signPayload(privateKey, raw);
    await AppDatabase.instance.db.update(
      'license',
      {
        'period_end': periodEnd.toIso8601String(),
        'token': '${b64e(raw)}.$signature',
      },
      where: 'id = 1',
    );
  }

  Future<Map<String, Object?>> status() async {
    final ownerRow = await owner();
    final licenseRow = await license();
    final periodEnd = DateTime.tryParse(
      licenseRow?['period_end'] as String? ?? '',
    );
    final expired = periodEnd != null && periodEnd.isBefore(DateTime.now());
    return {
      'owner_id': ownerRow?['owner_id'] ?? '',
      'owner_public_key': ownerRow?['public_key'] ?? '',
      'plan': licenseRow == null ? 'free' : 'premium',
      'period_end': licenseRow?['period_end'],
      'device_limit': licenseRow?['device_limit'] ?? 1,
      'provider': licenseRow?['provider'] ?? '',
      'expired': expired,
      'premium': licenseRow != null,
    };
  }

  Future<bool> isPremium() async => (await license()) != null;
}
