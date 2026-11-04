import 'dart:convert';

import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/license_verifier.dart';
import 'package:pusatkupos/sync/crypto.dart';

/// Menerbitkan token lisensi uji dengan kunci uji (bukan kunci server asli).
Future<LicenseClaims> installTestLicense({
  required String ownerId,
  int days = 30,
  int deviceLimit = 10,
  DateTime? periodEnd,
}) async {
  final keys = await generateSigningKey();
  LicenseService.verifier = ServerLicenseVerifier(publicKey: keys.publicKey);
  final now = DateTime.now().toUtc();
  final payload = {
    'v': 1,
    'owner_id': ownerId,
    'plan': 'premium',
    'period_end':
        (periodEnd ?? now.add(Duration(days: days))).toIso8601String(),
    'device_limit': deviceLimit,
    'issued_at': now.toIso8601String(),
  };
  final raw = canonicalJson(payload);
  final signature = await signPayload(keys.privateKey, utf8.encode(raw));
  final token = '${b64e(utf8.encode(raw))}.$signature';
  return LicenseService.instance.installToken(token, expectedOwnerId: ownerId);
}
