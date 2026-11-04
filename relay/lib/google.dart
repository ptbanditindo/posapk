import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

class GoogleAuthException implements Exception {
  GoogleAuthException(this.code, this.message, {this.status = 401});

  final String code;
  final String message;
  final int status;

  @override
  String toString() => message;
}

class GoogleIdentity {
  const GoogleIdentity({required this.subject, required this.email});

  final String subject;
  final String email;
}

typedef JwksLoader = Future<Map<String, Object?>> Function();

const String googleJwksUrl = 'https://www.googleapis.com/oauth2/v3/certs';

const List<String> _issuers = [
  'https://accounts.google.com',
  'accounts.google.com',
];

Future<Map<String, Object?>> fetchGoogleJwks() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(googleJwksUrl));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw GoogleAuthException(
        'jwks_unavailable',
        'Kunci publik Google tidak tersedia (${response.statusCode}).',
        status: 502,
      );
    }
    final raw = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw GoogleAuthException(
        'jwks_invalid',
        'Format kunci publik Google tidak dikenali.',
        status: 502,
      );
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  } on GoogleAuthException {
    rethrow;
  } catch (error) {
    throw GoogleAuthException(
      'jwks_unavailable',
      'Gagal mengambil kunci publik Google: $error',
      status: 502,
    );
  } finally {
    client.close(force: true);
  }
}

class GoogleTokenVerifier {
  GoogleTokenVerifier({
    required this.clientId,
    JwksLoader? jwksLoader,
    DateTime Function()? clock,
    this.cacheTtl = const Duration(hours: 1),
  })  : _jwksLoader = jwksLoader ?? fetchGoogleJwks,
        _clock = clock ?? DateTime.now;

  final String clientId;
  final Duration cacheTtl;
  final JwksLoader _jwksLoader;
  final DateTime Function() _clock;

  Map<String, _RsaKey>? _keys;
  DateTime? _fetchedAt;

  Future<GoogleIdentity> verify(
    String idToken, {
    Duration leeway = const Duration(seconds: 30),
  }) async {
    if (clientId.trim().isEmpty) {
      throw GoogleAuthException(
        'google_login_disabled',
        'Login Google belum diaktifkan di relay.',
        status: 503,
      );
    }
    final parts = idToken.trim().split('.');
    if (parts.length != 3) {
      throw GoogleAuthException('invalid_token', 'Token Google tidak valid.');
    }
    final header = _decodeJson(parts[0], 'header');
    final payload = _decodeJson(parts[1], 'payload');
    if ('${header['alg'] ?? ''}' != 'RS256') {
      throw GoogleAuthException(
        'invalid_algorithm',
        'Algoritma token Google tidak didukung.',
      );
    }
    final kid = '${header['kid'] ?? ''}';
    final signature = _decodeBase64(parts[2]);
    final signingInput = '${parts[0]}.${parts[1]}';

    var keys = await _jwks();
    var key = kid.isEmpty ? _onlyKey(keys) : keys[kid];
    if (key == null) {
      keys = await _jwks(force: true);
      key = kid.isEmpty ? _onlyKey(keys) : keys[kid];
    }
    if (key == null) {
      throw GoogleAuthException(
        'unknown_key',
        'Kunci tanda tangan token Google tidak ditemukan.',
      );
    }
    if (!_verifyRs256(signingInput, signature, key)) {
      throw GoogleAuthException(
        'invalid_signature',
        'Tanda tangan token Google tidak valid.',
      );
    }

    final issuer = '${payload['iss'] ?? ''}';
    if (!_issuers.contains(issuer)) {
      throw GoogleAuthException('invalid_issuer', 'Penerbit token tidak sah.');
    }
    final audience = payload['aud'];
    final audiences = audience is List
        ? audience.map((item) => '$item').toList()
        : ['$audience'];
    if (!audiences.contains(clientId)) {
      throw GoogleAuthException(
        'invalid_audience',
        'Token Google bukan untuk aplikasi ini.',
      );
    }
    final now = _clock().toUtc();
    final exp = _seconds(payload['exp']);
    if (exp == null || now.isAfter(exp.add(leeway))) {
      throw GoogleAuthException(
        'token_expired',
        'Token Google sudah kedaluwarsa.',
      );
    }
    final iat = _seconds(payload['iat']);
    if (iat != null && iat.isAfter(now.add(leeway))) {
      throw GoogleAuthException(
        'invalid_issued_at',
        'Waktu terbit token Google tidak wajar.',
      );
    }
    final subject = '${payload['sub'] ?? ''}'.trim();
    if (subject.isEmpty) {
      throw GoogleAuthException(
        'missing_subject',
        'Token Google tidak memuat identitas akun.',
      );
    }
    final email = '${payload['email'] ?? ''}'.trim().toLowerCase();
    if (email.isEmpty) {
      throw GoogleAuthException(
        'missing_email',
        'Token Google tidak memuat email.',
      );
    }
    if (payload['email_verified'] != true) {
      throw GoogleAuthException(
        'email_unverified',
        'Email akun Google belum diverifikasi.',
      );
    }
    return GoogleIdentity(subject: subject, email: email);
  }

  Future<Map<String, _RsaKey>> _jwks({bool force = false}) async {
    final now = _clock();
    final fetchedAt = _fetchedAt;
    final cached = _keys;
    if (!force &&
        cached != null &&
        fetchedAt != null &&
        now.difference(fetchedAt) < cacheTtl) {
      return cached;
    }
    final raw = await _jwksLoader();
    final list = raw['keys'];
    final keys = <String, _RsaKey>{};
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final key = _RsaKey.fromJson(item.map((k, v) => MapEntry('$k', v)));
        if (key != null) keys[key.kid] = key;
      }
    }
    if (keys.isEmpty) {
      throw GoogleAuthException(
        'jwks_empty',
        'Kunci publik Google tidak berisi kunci RSA.',
        status: 502,
      );
    }
    _keys = keys;
    _fetchedAt = now;
    return keys;
  }

  _RsaKey? _onlyKey(Map<String, _RsaKey> keys) =>
      keys.length == 1 ? keys.values.first : keys[''];

  Map<String, Object?> _decodeJson(String part, String label) {
    try {
      final decoded = jsonDecode(utf8.decode(_decodeBase64(part)));
      if (decoded is! Map) throw const FormatException('bukan objek');
      return decoded.map((key, value) => MapEntry('$key', value));
    } catch (_) {
      throw GoogleAuthException(
        'invalid_token',
        'Bagian $label token Google tidak valid.',
      );
    }
  }
}

class _RsaKey {
  _RsaKey({
    required this.kid,
    required this.modulus,
    required this.exponent,
    required this.size,
  });

  final String kid;
  final BigInt modulus;
  final BigInt exponent;
  final int size;

  static _RsaKey? fromJson(Map<String, Object?> json) {
    if ('${json['kty'] ?? 'RSA'}' != 'RSA') return null;
    final alg = '${json['alg'] ?? 'RS256'}';
    if (alg != 'RS256') return null;
    final n = '${json['n'] ?? ''}';
    final e = '${json['e'] ?? ''}';
    if (n.isEmpty || e.isEmpty) return null;
    final modulus = _bytesToBigInt(_decodeBase64(n));
    final exponent = _bytesToBigInt(_decodeBase64(e));
    if (modulus <= BigInt.zero || exponent <= BigInt.zero) return null;
    return _RsaKey(
      kid: '${json['kid'] ?? ''}',
      modulus: modulus,
      exponent: exponent,
      size: (modulus.bitLength + 7) >> 3,
    );
  }
}

bool _verifyRs256(String signingInput, List<int> signature, _RsaKey key) {
  if (signature.length != key.size) return false;
  final value = _bytesToBigInt(signature);
  if (value >= key.modulus) return false;
  final encoded = _bigIntToBytes(value.modPow(key.exponent, key.modulus), key.size);
  if (encoded.length != key.size || encoded[0] != 0 || encoded[1] != 1) {
    return false;
  }
  final separator = encoded.indexOf(0, 2);
  if (separator < 10) return false;
  for (var i = 2; i < separator; i++) {
    if (encoded[i] != 0xff) return false;
  }
  final digest = crypto.sha256.convert(utf8.encode(signingInput)).bytes;
  final digestInfo = <int>[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65,
    0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ...digest,
  ];
  final tail = encoded.sublist(separator + 1);
  if (tail.length != digestInfo.length) return false;
  var diff = 0;
  for (var i = 0; i < tail.length; i++) {
    diff |= tail[i] ^ digestInfo[i];
  }
  return diff == 0;
}

DateTime? _seconds(Object? value) {
  if (value is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (value * 1000).round(),
    isUtc: true,
  );
}

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

List<int> _bigIntToBytes(BigInt value, int length) {
  final result = Uint8List(length);
  var current = value;
  final mask = BigInt.from(0xff);
  for (var i = length - 1; i >= 0; i--) {
    result[i] = (current & mask).toInt();
    current >>= 8;
  }
  return result;
}

List<int> _decodeBase64(String input) {
  final normalized = input.padRight(
    input.length + (4 - input.length % 4) % 4,
    '=',
  );
  try {
    return base64Url.decode(normalized);
  } catch (_) {
    throw GoogleAuthException('invalid_token', 'Token Google tidak dapat dibaca.');
  }
}

class RateLimiter {
  RateLimiter({
    this.max = 20,
    this.window = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int max;
  final Duration window;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _hits = {};

  bool allow(String key) {
    final now = _clock();
    if (_hits.length > 1000) {
      _hits.removeWhere(
        (_, values) => values.isEmpty || now.difference(values.last) > window,
      );
    }
    final values = _hits.putIfAbsent(key, () => <DateTime>[])
      ..removeWhere((hit) => now.difference(hit) > window);
    if (values.length >= max) return false;
    values.add(now);
    return true;
  }

  void reset() => _hits.clear();
}
