import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/protocol.dart';

void main() {
  test('wrapped key, envelope, dan HLC', () async {
    final signing = await generateSigningKey();
    final encryption = await generateEncryptionKey();
    final storeKey = List<int>.generate(32, (index) => index + 1);
    final wrapped = await wrapStoreKey(encryption.publicKey, storeKey);
    final unwrapped =
        await unwrapStoreKey(encryption.privateKey, wrapped);
    expect(unwrapped, storeKey);

    final envelope = await buildEnvelope(
      devicePrivateKey: signing.privateKey,
      storeKey: storeKey,
      storeId: 'utama',
      senderDeviceId: 'device-1',
      recipientDeviceId: '',
      seq: 1,
      hlcWall: 1000,
      hlcCounter: 0,
      idempotencyKey: 'idem-1',
      entity: 'customer',
      action: 'upsert',
      entityId: 'cust-1',
      payload: {'nama': 'Tes'},
    );
    final data = await verifyEnvelope(
      envelope: envelope,
      senderPublicKey: signing.publicKey,
      storeKey: storeKey,
    );
    expect(data['entity'], 'customer');
    expect(jsonEncode(data['payload']), contains('Tes'));

    final futureWall = DateTime.now().millisecondsSinceEpoch + 10000;
    final next = nextHlc(Hlc(futureWall, 2));
    expect(next.wall, futureWall);
    expect(next.counter, 3);
  });

  test('petunjuk entity/action ditandatangani dan tidak dapat diubah',
      () async {
    final signing = await generateSigningKey();
    final storeKey = List<int>.generate(32, (index) => index + 1);
    final envelope = await buildEnvelope(
      devicePrivateKey: signing.privateKey,
      storeKey: storeKey,
      storeId: 'utama',
      senderDeviceId: 'device-1',
      recipientDeviceId: '',
      seq: 1,
      hlcWall: 1000,
      hlcCounter: 0,
      idempotencyKey: 'idem-petunjuk',
      entity: 'customer',
      action: 'upsert',
      entityId: 'cust-1',
      payload: {'nama': 'Tes'},
    );
    expect(envelope['hints_signature'], isNotEmpty);

    final tampered = Map<String, Object?>.from(envelope)
      ..['action'] = 'delete';
    await expectLater(
      verifyEnvelope(
        envelope: tampered,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
      ),
      throwsA(isA<StateError>()),
    );

    final legacy = Map<String, Object?>.from(envelope)
      ..remove('hints_signature');
    await expectLater(
      verifyEnvelope(
        envelope: legacy,
        senderPublicKey: signing.publicKey,
        storeKey: storeKey,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'pesan',
          contains('tanda tangan petunjuk'),
        ),
      ),
    );
  });
}
