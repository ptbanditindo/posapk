import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'canonical.dart';
import 'db.dart';

class LicenseService {
  LicenseService(this.db);

  final Database db;

  Future<Map<String, Object?>> ensureKey() async {
    final existing = await db.one(
      "SELECT private_key, public_key FROM server_keys WHERE name = 'license'",
    );
    if (existing != null) return existing;
    final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final public = await pair.extractPublicKey();
    final values = {
      'private_key': base64Url.encode(seed),
      'public_key': base64Url.encode(public.bytes),
    };
    await db.execute(
      "INSERT INTO server_keys (name, private_key, public_key) VALUES ('license', @private, @public) "
      'ON CONFLICT (name) DO NOTHING',
      {'private': values['private_key'], 'public': values['public_key']},
    );
    return await db.one(
          "SELECT private_key, public_key FROM server_keys WHERE name = 'license'",
        ) ??
        values;
  }

  Future<String> publicKey() async => (await ensureKey())['public_key'] as String;

  Future<String> issueToken({
    required String ownerId,
    required DateTime periodEnd,
    String plan = 'premium',
    int deviceLimit = 5,
  }) async {
    final key = await ensureKey();
    final payload = {
      'v': 1,
      'owner_id': ownerId,
      'plan': plan,
      'period_end': periodEnd.toUtc().toIso8601String(),
      'device_limit': deviceLimit,
      'issued_at': DateTime.now().toUtc().toIso8601String(),
    };
    final raw = utf8.encode(canonicalJson(payload));
    final signature = await _sign(key['private_key'] as String, raw);
    return '${base64Url.encode(raw)}.$signature';
  }

  Future<bool> verifyPayload({
    required String publicKey,
    required String payload,
    required String signature,
  }) async {
    try {
      return await Ed25519().verify(
        utf8.encode(payload),
        signature: Signature(
          base64Url.decode(signature),
          publicKey: SimplePublicKey(
            base64Url.decode(publicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<String> _sign(String privateSeed, List<int> payload) async {
    final pair = await Ed25519().newKeyPairFromSeed(base64Url.decode(privateSeed));
    final signature = await Ed25519().sign(payload, keyPair: pair);
    return base64Url.encode(signature.bytes);
  }
}
