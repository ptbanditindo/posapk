import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

String b64e(List<int> raw) => base64Url.encode(raw);
List<int> b64d(String value) => base64Url.decode(value);
String sha256Hex(List<int> raw) => crypto.sha256.convert(raw).toString();

String canonicalJson(Object? value) => jsonEncode(_sorted(value));
Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

class KeyMaterial {
  const KeyMaterial({required this.privateKey, required this.publicKey});
  final String privateKey;
  final String publicKey;
}

Future<KeyMaterial> generateSigningKey() async {
  final pair = await Ed25519().newKeyPair();
  final private = await pair.extractPrivateKeyBytes();
  final public = await pair.extractPublicKey();
  return KeyMaterial(
    privateKey: b64e(private),
    publicKey: b64e(public.bytes),
  );
}

Future<KeyMaterial> generateEncryptionKey() async {
  final pair = await X25519().newKeyPair();
  final private = await pair.extractPrivateKeyBytes();
  final public = await pair.extractPublicKey();
  return KeyMaterial(
    privateKey: b64e(private),
    publicKey: b64e(public.bytes),
  );
}

Future<String> signPayload(String privateKey, List<int> payload) async {
  final pair = await Ed25519().newKeyPairFromSeed(b64d(privateKey));
  final signature = await Ed25519().sign(payload, keyPair: pair);
  return b64e(signature.bytes);
}

Future<bool> verifyPayload(
  String publicKey,
  List<int> payload,
  String signature,
) async {
  try {
    return await Ed25519().verify(
      payload,
      signature: Signature(
        b64d(signature),
        publicKey: SimplePublicKey(
          b64d(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } catch (_) {
    return false;
  }
}

Future<String> wrapStoreKey(String recipientPublicKey, List<int> storeKey) async {
  final ephemeral = await X25519().newKeyPair();
  final ephemeralPrivate = await ephemeral.extractPrivateKeyBytes();
  final shared = await X25519().sharedSecretKey(
    keyPair: await X25519().newKeyPairFromSeed(ephemeralPrivate),
    remotePublicKey: SimplePublicKey(
      b64d(recipientPublicKey),
      type: KeyPairType.x25519,
    ),
  );
  final key = await _deriveKey(await shared.extractBytes());
  final nonce = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    storeKey,
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  final ephemeralPublic = await ephemeral.extractPublicKey();
  return jsonEncode({
    'v': 1,
    'epk': b64e(ephemeralPublic.bytes),
    'nonce': b64e(box.nonce),
    'ct': b64e([...box.cipherText, ...box.mac.bytes]),
  });
}

Future<List<int>> unwrapStoreKey(
  String recipientPrivateKey,
  String wrapped,
) async {
  final blob = jsonDecode(wrapped) as Map<String, dynamic>;
  final private = await X25519().newKeyPairFromSeed(b64d(recipientPrivateKey));
  final shared = await X25519().sharedSecretKey(
    keyPair: private,
    remotePublicKey: SimplePublicKey(
      b64d(blob['epk'] as String),
      type: KeyPairType.x25519,
    ),
  );
  final key = await _deriveKey(await shared.extractBytes());
  final raw = b64d(blob['ct'] as String);
  final box = SecretBox(
    raw.sublist(0, raw.length - _tagLength),
    nonce: b64d(blob['nonce'] as String),
    mac: Mac(raw.sublist(raw.length - _tagLength)),
  );
  final clear = await AesGcm.with256bits().decrypt(
    box,
    secretKey: SecretKey(key),
  );
  return clear;
}

Future<List<int>> _deriveKey(List<int> shared) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: const <int>[],
    info: utf8.encode('pusatkupos-store-key-v1'),
  );
  return key.extractBytes();
}

Future<(String, String)> encryptPayload(
  List<int> key,
  List<int> plaintext,
) async {
  final nonce = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  return (b64e([...box.cipherText, ...box.mac.bytes]), b64e(box.nonce));
}

Future<List<int>> decryptPayload(
  List<int> key,
  String ciphertext,
  String nonce,
) async {
  final raw = b64d(ciphertext);
  final box = SecretBox(
    raw.sublist(0, raw.length - _tagLength),
    nonce: b64d(nonce),
    mac: Mac(raw.sublist(raw.length - _tagLength)),
  );
  return AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key));
}

const _tagLength = 16;

String newToken() {
  final random = Random.secure();
  return b64e(List<int>.generate(32, (_) => random.nextInt(256)));
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

class Hlc {
  const Hlc(this.wall, this.counter);
  final int wall;
  final int counter;
}

Hlc nextHlc(Hlc previous) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now > previous.wall) return Hlc(now, 0);
  return Hlc(previous.wall, previous.counter + 1);
}
