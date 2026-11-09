import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../core/app_log.dart';
import 'app_database.dart';
import 'login_guard.dart';
import 'session_service.dart';

const int ownerPinMinLength = 6;
const int pinIterations = 600000;
const String ownerGuardScope = 'owner';

enum PinVerification { ok, weakLegacyPin, wrong, locked }

class PinService {
  PinService._();

  static final PinService instance = PinService._();

  Future<bool> verify(String pin) async {
    final result = await verifyDetailed(pin);
    return result == PinVerification.ok ||
        result == PinVerification.weakLegacyPin;
  }

  Future<bool> isConfigured() async {
    final session = await SessionService.instance.readPin();
    if (session != null) return true;
    final hash = await AppDatabase.instance.getSetting('auth.pin_hash');
    return hash != null && hash.isNotEmpty;
  }

  /// [executor] dipakai saat verifikasi berjalan di dalam transaksi agar
  /// pembacaan lockout memakai koneksi transaksi yang sama.
  Future<PinVerification> verifyDetailed(
    String pin, {
    DatabaseExecutor? executor,
  }) async {
    final result = await _verifyDetailed(pin, executor: executor);
    AppLog.instance.event(
      LogCategory.auth,
      'pin.verify',
      data: {'result': result.name},
    );
    return result;
  }

  Future<PinVerification> _verifyDetailed(
    String pin, {
    DatabaseExecutor? executor,
  }) async {
    if (pin.trim().isEmpty) return PinVerification.wrong;
    try {
      await LoginGuard.check(ownerGuardScope, executor: executor);
    } on LoginLockedException {
      return PinVerification.locked;
    }
    final session = await SessionService.instance.readPin();
    if (session != null) {
      final valid =
          await _derive(
            pin,
            session.salt,
            session.iterations <= 0 ? pinIterations : session.iterations,
          ) ==
          session.hash;
      if (!valid) {
        await LoginGuard.fail(ownerGuardScope, executor: executor);
        return PinVerification.wrong;
      }
      await LoginGuard.clear(ownerGuardScope, executor: executor);
      return pin.trim().length < ownerPinMinLength
          ? PinVerification.weakLegacyPin
          : PinVerification.ok;
    }
    final salt = await _setting('auth.pin_salt', executor);
    final hash = await _setting('auth.pin_hash', executor);
    if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) {
      return PinVerification.wrong;
    }
    final storedIterations = int.tryParse(
      await _setting('auth.pin_iterations', executor) ?? '',
    );
    final legacy = storedIterations == null;
    final valid = legacy
        ? _legacyHash(salt, pin) == hash
        : await _derive(pin, salt, storedIterations) == hash;
    if (!valid) {
      await LoginGuard.fail(ownerGuardScope, executor: executor);
      return PinVerification.wrong;
    }
    await LoginGuard.clear(ownerGuardScope, executor: executor);
    if (legacy || storedIterations < pinIterations) {
      await _store(pin, executor: executor);
    }
    return pin.trim().length < ownerPinMinLength
        ? PinVerification.weakLegacyPin
        : PinVerification.ok;
  }

  Future<String?> _setting(String key, DatabaseExecutor? executor) async {
    if (executor == null) return AppDatabase.instance.getSetting(key);
    final rows = await executor.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setup(String pin, {SessionProfile? profile}) async {
    final clean = pin.trim();
    if (!RegExp(r'^\d+$').hasMatch(clean)) {
      throw ArgumentError('PIN hanya boleh berisi angka.');
    }
    if (clean.length < ownerPinMinLength) {
      throw ArgumentError('PIN baru minimal $ownerPinMinLength digit.');
    }
    await _store(clean);
    if (profile != null) {
      await SessionService.instance.savePinIdentity(profile);
    }
    await LoginGuard.clear(ownerGuardScope);
  }

  Future<bool> change({required String oldPin, required String newPin}) async {
    if (!await verify(oldPin)) return false;
    await setup(newPin);
    return true;
  }

  Future<void> clear() async {
    await SessionService.instance.clearPin();
    final db = AppDatabase.instance;
    await db.deleteSetting('auth.pin_salt');
    await db.deleteSetting('auth.pin_hash');
    await db.deleteSetting('auth.pin_iterations');
  }

  Future<void> _store(String pin, {DatabaseExecutor? executor}) async {
    final salt = _newSalt();
    final hash = await _derive(pin, salt, pinIterations);
    await SessionService.instance.savePin(hash, salt, pinIterations);
    await _writeSetting('auth.pin_salt', salt, executor);
    await _writeSetting('auth.pin_hash', hash, executor);
    await _writeSetting('auth.pin_iterations', '$pinIterations', executor);
  }

  Future<void> _writeSetting(
    String key,
    String value,
    DatabaseExecutor? executor,
  ) async {
    if (executor == null) {
      await AppDatabase.instance.setSetting(key, value);
      return;
    }
    await executor.insert('app_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  String _newSalt() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(values);
  }

  String _legacyHash(String salt, String pin) {
    return crypto.sha256.convert(utf8.encode('$salt:$pin')).toString();
  }

  Future<String> _derive(String value, String salt, int iterations) async {
    final key =
        await Pbkdf2(
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
