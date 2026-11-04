import 'dart:convert';

import '../sync/crypto.dart';

/// Kunci publik server lisensi. Isi lewat
/// `--dart-define=PUSATKU_LICENSE_PUBLIC_KEY=<base64url>`.
const String serverLicensePublicKey = String.fromEnvironment(
  'PUSATKU_LICENSE_PUBLIC_KEY',
  defaultValue: '',
);

class LicenseClaims {
  const LicenseClaims({
    required this.ownerId,
    required this.plan,
    required this.periodEnd,
    required this.deviceLimit,
    required this.issuedAt,
    required this.raw,
  });

  final String ownerId;
  final String plan;
  final DateTime periodEnd;
  final int deviceLimit;
  final DateTime issuedAt;
  final Map<String, Object?> raw;

  bool get aktif => periodEnd.isAfter(DateTime.now().toUtc());

  bool get premium => plan == 'premium' && aktif;
}

abstract class LicenseVerifier {
  Future<LicenseClaims> verify(String token);
}

class LicenseVerifyException implements Exception {
  LicenseVerifyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Memverifikasi token yang diterbitkan server: `payload.signature`,
/// payload base64url dari JSON kanonik, signature Ed25519 base64url.
class ServerLicenseVerifier implements LicenseVerifier {
  const ServerLicenseVerifier({this.publicKey = serverLicensePublicKey});

  final String publicKey;

  @override
  Future<LicenseClaims> verify(String token) async {
    if (publicKey.isEmpty) {
      throw LicenseVerifyException(
        'Kunci publik server lisensi belum ditanam di aplikasi. '
        'Bangun ulang dengan PUSATKU_LICENSE_PUBLIC_KEY.',
      );
    }
    final parts = token.split('.');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw LicenseVerifyException('Format token lisensi tidak valid.');
    }
    final payloadBytes = b64d(parts[0]);
    final valid = await verifyPayload(
      publicKey,
      payloadBytes,
      parts[1],
    );
    if (!valid) {
      throw LicenseVerifyException('Tanda tangan lisensi tidak valid.');
    }
    final decoded = jsonDecode(utf8.decode(payloadBytes));
    if (decoded is! Map) {
      throw LicenseVerifyException('Payload lisensi tidak valid.');
    }
    final payload = decoded.map((key, value) => MapEntry('$key', value));
    final ownerId = payload['owner_id'] as String? ?? '';
    final periodEnd = DateTime.tryParse(
      payload['period_end'] as String? ?? '',
    )?.toUtc();
    if (ownerId.isEmpty || periodEnd == null) {
      throw LicenseVerifyException('Lisensi tidak memuat owner/masa berlaku.');
    }
    return LicenseClaims(
      ownerId: ownerId,
      plan: payload['plan'] as String? ?? 'premium',
      periodEnd: periodEnd,
      deviceLimit: (payload['device_limit'] as num?)?.toInt() ?? 1,
      issuedAt: DateTime.tryParse(
            payload['issued_at'] as String? ?? '',
          )?.toUtc() ??
          DateTime.now().toUtc(),
      raw: payload,
    );
  }
}
