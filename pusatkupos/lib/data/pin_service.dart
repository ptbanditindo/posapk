import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'app_database.dart';

class PinService {
  PinService._();

  static final PinService instance = PinService._();

  Future<bool> verify(String pin) async {
    final db = AppDatabase.instance;
    final salt = await db.getSetting('auth.pin_salt');
    final hash = await db.getSetting('auth.pin_hash');
    if (salt == null || hash == null) return false;
    return _hash(salt, pin) == hash;
  }

  Future<void> setup(String pin) async {
    final salt = _newSalt();
    await AppDatabase.instance.setSetting('auth.pin_salt', salt);
    await AppDatabase.instance.setSetting('auth.pin_hash', _hash(salt, pin));
  }

  Future<bool> change({required String oldPin, required String newPin}) async {
    if (!await verify(oldPin)) return false;
    await setup(newPin);
    return true;
  }

  String _newSalt() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(values);
  }

  String _hash(String salt, String pin) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }
}
