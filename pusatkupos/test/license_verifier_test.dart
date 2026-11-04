import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/data/license_verifier.dart';
import 'package:pusatkupos/sync/crypto.dart';

Future<String> _token(
  String privateKey, {
  required String ownerId,
  required DateTime periodEnd,
  int deviceLimit = 3,
}) async {
  final payload = {
    'v': 1,
    'owner_id': ownerId,
    'plan': 'premium',
    'period_end': periodEnd.toIso8601String(),
    'device_limit': deviceLimit,
    'issued_at': DateTime.now().toUtc().toIso8601String(),
  };
  final raw = canonicalJson(payload);
  final signature = await signPayload(privateKey, utf8.encode(raw));
  return '${b64e(utf8.encode(raw))}.$signature';
}

void main() {
  test('token server diverifikasi dan masa berlaku ditegakkan', () async {
    final keys = await generateSigningKey();
    final verifier = ServerLicenseVerifier(publicKey: keys.publicKey);
    final token = await _token(
      keys.privateKey,
      ownerId: 'OWNER123',
      periodEnd: DateTime.now().toUtc().add(const Duration(days: 30)),
    );
    final claims = await verifier.verify(token);
    expect(claims.ownerId, 'OWNER123');
    expect(claims.deviceLimit, 3);
    expect(claims.premium, isTrue);

    final expired = await _token(
      keys.privateKey,
      ownerId: 'OWNER123',
      periodEnd: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );
    final expiredClaims = await verifier.verify(expired);
    expect(expiredClaims.aktif, isFalse);
    expect(expiredClaims.premium, isFalse);
  });

  test('token rusak atau kunci lain ditolak', () async {
    final keys = await generateSigningKey();
    final other = await generateSigningKey();
    final token = await _token(
      keys.privateKey,
      ownerId: 'OWNER123',
      periodEnd: DateTime.now().toUtc().add(const Duration(days: 1)),
    );

    await expectLater(
      ServerLicenseVerifier(publicKey: other.publicKey).verify(token),
      throwsA(isA<LicenseVerifyException>()),
    );

    final tampered = '${token.substring(0, token.length - 2)}xx';
    await expectLater(
      ServerLicenseVerifier(publicKey: keys.publicKey).verify(tampered),
      throwsA(isA<LicenseVerifyException>()),
    );

    await expectLater(
      const ServerLicenseVerifier(publicKey: '').verify(token),
      throwsA(isA<LicenseVerifyException>()),
    );
  });
}
