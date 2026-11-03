import 'dart:convert';

import 'crypto.dart';

Map<String, Object?> envelopeFields({
  required String storeId,
  required String senderDeviceId,
  required String recipientDeviceId,
  required int seq,
  required int hlcWall,
  required int hlcCounter,
  required String idempotencyKey,
  required String ciphertext,
  required String nonce,
}) {
  return {
    'v': 1,
    'store_id': storeId,
    'sender_device_id': senderDeviceId,
    'recipient_device_id': recipientDeviceId,
    'seq': seq,
    'hlc_wall': hlcWall,
    'hlc_counter': hlcCounter,
    'idempotency_key': idempotencyKey,
    'ciphertext': ciphertext,
    'nonce': nonce,
  };
}

Future<Map<String, Object?>> buildEnvelope({
  required String devicePrivateKey,
  required List<int> storeKey,
  required String storeId,
  required String senderDeviceId,
  required String recipientDeviceId,
  required int seq,
  required int hlcWall,
  required int hlcCounter,
  required String idempotencyKey,
  required String entity,
  required String action,
  required String entityId,
  required Map<String, Object?> payload,
}) async {
  final plaintext = canonicalJson({
    'entity': entity,
    'action': action,
    'entity_id': entityId,
    'payload': payload,
    'seq': seq,
    'hlc_wall': hlcWall,
    'hlc_counter': hlcCounter,
    'idempotency_key': idempotencyKey,
  });
  final encrypted = await encryptPayload(storeKey, utf8.encode(plaintext));
  final fields = envelopeFields(
    storeId: storeId,
    senderDeviceId: senderDeviceId,
    recipientDeviceId: recipientDeviceId,
    seq: seq,
    hlcWall: hlcWall,
    hlcCounter: hlcCounter,
    idempotencyKey: idempotencyKey,
    ciphertext: encrypted.$1,
    nonce: encrypted.$2,
  );
  final signature = await signPayload(
    devicePrivateKey,
    utf8.encode(canonicalJson(fields)),
  );
  return {...fields, 'signature': signature};
}

Future<Map<String, Object?>> verifyEnvelope({
  required Map<String, Object?> envelope,
  required String senderPublicKey,
  required List<int> storeKey,
}) async {
  final fields = envelopeFields(
    storeId: envelope['store_id'] as String? ?? '',
    senderDeviceId: envelope['sender_device_id'] as String? ?? '',
    recipientDeviceId: envelope['recipient_device_id'] as String? ?? '',
    seq: (envelope['seq'] as num?)?.toInt() ?? 0,
    hlcWall: (envelope['hlc_wall'] as num?)?.toInt() ?? 0,
    hlcCounter: (envelope['hlc_counter'] as num?)?.toInt() ?? 0,
    idempotencyKey: envelope['idempotency_key'] as String? ?? '',
    ciphertext: envelope['ciphertext'] as String? ?? '',
    nonce: envelope['nonce'] as String? ?? '',
  );
  final valid = await verifyPayload(
    senderPublicKey,
    utf8.encode(canonicalJson(fields)),
    envelope['signature'] as String? ?? '',
  );
  if (!valid) throw StateError('Tanda tangan delta tidak valid.');
  final clear = await decryptPayload(
    storeKey,
    envelope['ciphertext'] as String,
    envelope['nonce'] as String,
  );
  return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
}

Map<String, Object?> snapshotFields({
  required String storeId,
  required String deviceId,
  required String checksum,
  required int storeSeq,
  required int hlcWall,
  required int hlcCounter,
}) {
  return {
    'store_id': storeId,
    'device_id': deviceId,
    'checksum': checksum,
    'store_seq': storeSeq,
    'hlc_wall': hlcWall,
    'hlc_counter': hlcCounter,
  };
}
