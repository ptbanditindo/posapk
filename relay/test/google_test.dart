import 'dart:convert';
import 'dart:io';

import 'package:pusatkupos_relay/google.dart';
import 'package:test/test.dart';

const clientId = 'test-client.apps.googleusercontent.com';
final clock = DateTime.utc(2026, 1, 1);

late Map<String, Object?> fixtures;
late Map<String, Object?> jwks;

Map<String, String> tokens() =>
    (fixtures['tokens'] as Map).map((key, value) => MapEntry('$key', '$value'));

Future<Map<String, Object?>> _loadJwks() async => jwks;

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _withPayload(String token, Map<String, Object?> payload) {
  final parts = token.split('.');
  return '${parts[0]}.${_b64url(utf8.encode(jsonEncode(payload)))}.${parts[2]}';
}

void main() {
  setUpAll(() {
    final raw = File('test/fixtures/google_fixtures.json').readAsStringSync();
    fixtures = jsonDecode(raw) as Map<String, Object?>;
    jwks = {
      'keys': [
        {
          'kid': 'test-kid',
          'kty': 'RSA',
          'alg': 'RS256',
          'use': 'sig',
          'n': fixtures['n'],
          'e': fixtures['e'],
        },
      ],
    };
  });

  GoogleTokenVerifier verifier({JwksLoader? loader}) => GoogleTokenVerifier(
        clientId: clientId,
        jwksLoader: loader ?? _loadJwks,
        clock: () => clock,
      );

  test('token Google valid diterima', () async {
    final identity = await verifier().verify(tokens()['valid']!);
    expect(identity.subject, 'google-sub-123');
    expect(identity.email, 'owner@example.com');
  });

  test('audience salah ditolak', () async {
    await expectLater(
      verifier().verify(tokens()['wrongAud']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'invalid_audience'),
      ),
    );
  });

  test('token kedaluwarsa ditolak', () async {
    await expectLater(
      verifier().verify(tokens()['expired']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'token_expired'),
      ),
    );
  });

  test('issuer salah ditolak', () async {
    await expectLater(
      verifier().verify(tokens()['wrongIss']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'invalid_issuer'),
      ),
    );
  });

  test('email belum terverifikasi ditolak', () async {
    await expectLater(
      verifier().verify(tokens()['unverified']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'email_unverified'),
      ),
    );
  });

  test('subject kosong ditolak', () async {
    await expectLater(
      verifier().verify(tokens()['noSub']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'missing_subject'),
      ),
    );
  });

  test('payload yang diubah membuat tanda tangan tidak valid', () async {
    final original = tokens()['valid']!;
    final parts = original.split('.');
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    ) as Map<String, Object?>;
    final tampered = _withPayload(original, {
      ...payload,
      'email': 'attacker@example.com',
    });
    await expectLater(
      verifier().verify(tampered),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'invalid_signature'),
      ),
    );
  });

  test('algoritma selain RS256 ditolak', () async {
    final parts = tokens()['valid']!.split('.');
    final header = _b64url(utf8.encode(jsonEncode({'alg': 'none', 'kid': 'test-kid'})));
    await expectLater(
      verifier().verify('$header.${parts[1]}.${parts[2]}'),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'invalid_algorithm'),
      ),
    );
  });

  test('kid baru memicu ambil ulang JWKS', () async {
    var calls = 0;
    final rotating = verifier(
      loader: () async {
        calls++;
        if (calls == 1) {
          return {
            'keys': [
              {
                'kid': 'key-lama',
                'kty': 'RSA',
                'alg': 'RS256',
                'n': fixtures['n'],
                'e': fixtures['e'],
              },
            ],
          };
        }
        return jwks;
      },
    );
    final identity = await rotating.verify(tokens()['valid']!);
    expect(identity.email, 'owner@example.com');
    expect(calls, 2);
  });

  test('JWKS di-cache untuk token berikutnya', () async {
    var calls = 0;
    final cached = verifier(
      loader: () async {
        calls++;
        return jwks;
      },
    );
    await cached.verify(tokens()['valid']!);
    await cached.verify(tokens()['valid']!);
    expect(calls, 1);
  });

  test('client ID kosong menonaktifkan login Google', () async {
    final disabled = GoogleTokenVerifier(
      clientId: '',
      jwksLoader: _loadJwks,
      clock: () => clock,
    );
    await expectLater(
      disabled.verify(tokens()['valid']!),
      throwsA(
        isA<GoogleAuthException>()
            .having((error) => error.code, 'code', 'google_login_disabled'),
      ),
    );
  });

  test('rate limiter membatasi percobaan per jendela waktu', () {
    var now = clock;
    final limiter = RateLimiter(
      max: 3,
      window: const Duration(minutes: 5),
      clock: () => now,
    );
    expect(limiter.allow('1.2.3.4'), isTrue);
    expect(limiter.allow('1.2.3.4'), isTrue);
    expect(limiter.allow('1.2.3.4'), isTrue);
    expect(limiter.allow('1.2.3.4'), isFalse);
    expect(limiter.allow('5.6.7.8'), isTrue);
    now = now.add(const Duration(minutes: 6));
    expect(limiter.allow('1.2.3.4'), isTrue);
  });
}
