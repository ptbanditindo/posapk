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
    await _migrateLegacy();
    return await SessionService.instance.readPin() != null;
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
      final valid = session.iterations <= 0
          ? _legacyHash(session.salt, pin) == session.hash
          : await _derive(pin, session.salt, session.iterations) ==
              session.hash;
      if (!valid) {
        await LoginGuard.fail(ownerGuardScope, executor: executor);
        return PinVerification.wrong;
      }
      await LoginGuard.clear(ownerGuardScope, executor: executor);
      if (session.iterations <= 0 || session.iterations < pinIterations) {
        await _store(pin);
      }
      return pin.trim().length < ownerPinMinLength
          ? PinVerification.weakLegacyPin
          : PinVerification.ok;
    }
    await _migrateLegacy();
    final migrated = await SessionService.instance.readPin();
    if (migrated == null) return PinVerification.wrong;
    return _verifyDetailed(pin, executor: executor);
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
    await _deleteLegacySettings();
  }

  Future<void> _store(String pin) async {
    final salt = _newSalt();
    final hash = await _derive(pin, salt, pinIterations);
    await SessionService.instance.savePin(hash, salt, pinIterations);
    await _deleteLegacySettings();
  }

  /// Versi lama menyimpan hash PIN di `app_meta`, yang ikut backup dan
  /// terbaca pada database desktop tanpa enkripsi. Pindahkan ke secure
  /// storage lalu hapus salinannya.
  Future<void> _migrateLegacy() async {
    final db = AppDatabase.instance;
    final salt = await db.getSetting('auth.pin_salt');
    final hash = await db.getSetting('auth.pin_hash');
    if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) return;
    final iterations = int.tryParse(
          await db.getSetting('auth.pin_iterations') ?? '',
        ) ??
        0;
    await SessionService.instance.savePin(hash, salt, iterations);
    await _deleteLegacySettings();
  }

  Future<void> _deleteLegacySettings() async {
    final db = AppDatabase.instance;
    await db.deleteSetting('auth.pin_salt');
    await db.deleteSetting('auth.pin_hash');
    await db.deleteSetting('auth.pin_iterations');
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
