import 'dart:convert';

import '../core/app_config.dart';
import 'crypto.dart';
import 'sync_conflict_rules.dart';

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
  required String keyId,
  required int keyVersion,
  required String entity,
  required String action,
  required String entityId,
}) {
  return {
    'v': 1,
    'protocol_version': protocolVersion,
    'store_id': storeId,
    'sender_device_id': senderDeviceId,
    'recipient_device_id': recipientDeviceId,
    'seq': seq,
    'hlc_wall': hlcWall,
    'hlc_counter': hlcCounter,
    'idempotency_key': idempotencyKey,
    'ciphertext': ciphertext,
    'nonce': nonce,
    'key_id': keyId,
    'key_version': keyVersion,
    'entity': entity,
    'action': action,
    'entity_id': entityId,
  };
}

Map<String, Object?> envelopeHints({
  required String storeId,
  required String senderDeviceId,
  required String entity,
  required String action,
  required String entityId,
  required String idempotencyKey,
}) {
  return {
    'store_id': storeId,
    'sender_device_id': senderDeviceId,
    'entity': entity,
    'action': action,
    'entity_id': entityId,
    'idempotency_key': idempotencyKey,
  };
}

Future<Map<String, Object?>> buildEnvelope({
  required String devicePrivateKey,
  required List<int> storeKey,
  required int keyVersion,
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
  final keyId = keyIdFor(storeKey);
  final plaintext = canonicalJson({
    'entity': entity,
    'action': action,
    'entity_id': entityId,
    'payload': payload,
    'seq': seq,
    'hlc_wall': hlcWall,
    'hlc_counter': hlcCounter,
    'idempotency_key': idempotencyKey,
    'key_id': keyId,
    'key_version': keyVersion,
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
    keyId: keyId,
    keyVersion: keyVersion,
    entity: entity,
    action: action,
    entityId: entityId,
  );
  final signature = await signPayload(
    devicePrivateKey,
    utf8.encode(canonicalJson(fields)),
  );
  final hintsSignature = await signPayload(
    devicePrivateKey,
    utf8.encode(
      canonicalJson(
        envelopeHints(
          storeId: storeId,
          senderDeviceId: senderDeviceId,
          entity: entity,
          action: action,
          entityId: entityId,
          idempotencyKey: idempotencyKey,
        ),
      ),
    ),
  );
  // Petunjuk terang dipakai relay untuk membatasi perangkat karyawan. Tanda
  // tangan terpisah membuat petunjuk itu tidak dapat diubah di perjalanan.
  // Sejak skema bersih v1 tanda tangan ini wajib; tidak ada toleransi amplop
  // lama.
  return {
    ...fields,
    'entity': entity,
    'action': action,
    'entity_id': entityId,
    'hints_signature': hintsSignature,
    'signature': signature,
  };
}

Future<Map<String, Object?>> verifyEnvelope({
  required Map<String, Object?> envelope,
  required String senderPublicKey,
  required Map<String, List<int>> storeKeys,
}) async {
  final keyId = envelope['key_id'] as String? ?? '';
  if (keyId.isEmpty) {
    throw StateError('Amplop tanpa penanda kunci toko.');
  }
  final rawKeyVersion = (envelope['key_version'] as num?)?.toInt();
  final keyVersion = rawKeyVersion ?? 1;
  final storeKey = storeKeys[keyId];
  if (storeKey == null) {
    // Kunci versi ini belum dimiliki perangkat. Jangan ack: perangkat harus
    // menyegarkan kunci atau meminta rotasi kunci dari owner.
    throw StateError(
      'Kunci toko untuk amplop ini (key_id $keyId, versi $keyVersion) belum '
      'tersedia. Muat ulang kunci toko sebelum melanjutkan sinkronisasi.',
    );
  }
  final rawVersion = (envelope['protocol_version'] as num?)?.toInt();
  final version = rawVersion ?? 1;
  if (version > protocolVersion) {
    throw ProtocolVersionException(protocolVersion, received: version);
  }
  if (version < 1) {
    throw StateError('Versi protokol amplop tidak valid.');
  }
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
    keyId: keyId,
    keyVersion: keyVersion,
    entity: envelope['entity'] as String? ?? '',
    action: envelope['action'] as String? ?? '',
    entityId: envelope['entity_id'] as String? ?? '',
  );
  var valid = await verifyPayload(
    senderPublicKey,
    utf8.encode(canonicalJson(fields)),
    envelope['signature'] as String? ?? '',
  );
  if (!valid && version < 2) {
    // Amplop v1 ditandatangani tanpa field protokol dan key_version.
    final legacy = Map<String, Object?>.from(fields)
      ..remove('protocol_version')
      ..remove('key_version');
    valid = await verifyPayload(
      senderPublicKey,
      utf8.encode(canonicalJson(legacy)),
      envelope['signature'] as String? ?? '',
    );
  }
  if (!valid) throw StateError('Tanda tangan delta tidak valid.');
  final outerEntity = envelope['entity'] as String? ?? '';
  final outerAction = envelope['action'] as String? ?? '';
  final outerEntityId = envelope['entity_id'] as String? ?? '';
  final hintsSignature = envelope['hints_signature'] as String? ?? '';
  if (hintsSignature.isEmpty) {
    throw StateError('Amplop tanpa tanda tangan petunjuk delta.');
  }
  final hintsValid = await verifyPayload(
    senderPublicKey,
    utf8.encode(
      canonicalJson(
        envelopeHints(
          storeId: envelope['store_id'] as String? ?? '',
          senderDeviceId: envelope['sender_device_id'] as String? ?? '',
          entity: outerEntity,
          action: outerAction,
          entityId: outerEntityId,
          idempotencyKey: envelope['idempotency_key'] as String? ?? '',
        ),
      ),
    ),
    hintsSignature,
  );
  if (!hintsValid) {
    throw StateError('Tanda tangan petunjuk delta tidak valid.');
  }
  final clear = await decryptPayload(
    storeKey,
    envelope['ciphertext'] as String,
    envelope['nonce'] as String,
  );
  final data = jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
  if (keyId.isNotEmpty && keyId != '${data['key_id'] ?? ''}') {
    throw StateError('Penanda kunci di dalam amplop tidak cocok.');
  }
  final innerVersion = (data['key_version'] as num?)?.toInt();
  if (version >= 2 && innerVersion == null) {
    throw StateError('Amplop protokol v2 tanpa versi kunci.');
  }
  if (innerVersion != null && innerVersion != keyVersion) {
    throw StateError('Versi kunci di dalam amplop tidak cocok.');
  }
  if (outerEntity.isNotEmpty && outerEntity != '${data['entity'] ?? ''}') {
    throw StateError('Petunjuk entity tidak cocok dengan isi amplop.');
  }
  if (outerAction.isNotEmpty && outerAction != '${data['action'] ?? ''}') {
    throw StateError('Petunjuk action tidak cocok dengan isi amplop.');
  }
  if (outerEntityId.isNotEmpty &&
      outerEntityId != '${data['entity_id'] ?? ''}') {
    throw StateError('Petunjuk entity_id tidak cocok dengan isi amplop.');
  }
  return data;
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
