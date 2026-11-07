import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/relay_url.dart';
import '../data/license_service.dart';

class RelayException implements Exception {
  RelayException(
    this.statusCode,
    this.message, {
    this.code = '',
    this.retryAfterSeconds,
  });
  final int statusCode;
  final String message;
  final String code;
  final int? retryAfterSeconds;

  bool get busy => statusCode == 429 || statusCode == 503;

  @override
  String toString() => 'Relay $statusCode: $message';
}

class RelayClient {
  RelayClient({required String baseUrl, this.deviceToken})
      : baseUrl = normalizeRelayUrl(baseUrl);

  final String baseUrl;
  final String? deviceToken;

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$root$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if ((deviceToken ?? '').isNotEmpty)
          'X-Device-Token': deviceToken!,
      };

  /// Batas waktu per permintaan agar socket yang menggantung tidak
  /// memblokir sinkronisasi sampai aplikasi di-restart.
  static const Duration _timeout = Duration(seconds: 30);

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String>? headers,
  }) {
    return http.get(uri, headers: headers).timeout(
          _timeout,
          onTimeout: () => throw RelayException(
            408,
            'Waktu permintaan relay habis.',
            code: 'timeout',
          ),
        );
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return http.post(uri, headers: headers, body: body).timeout(
          _timeout,
          onTimeout: () => throw RelayException(
            408,
            'Waktu permintaan relay habis.',
            code: 'timeout',
          ),
        );
  }

  Future<Map<String, Object?>> _json(http.Response response) async {
    Map<String, Object?> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        body = decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    final serverTime = '${body['server_time'] ?? ''}'.trim();
    if (serverTime.isNotEmpty) {
      try {
        await LicenseService.instance.noteServerTime(serverTime);
      } catch (_) {
        // Acuan waktu tidak boleh menggagalkan permintaan relay.
      }
    }
    if (response.statusCode >= 400) {
      throw RelayException(
        response.statusCode,
        (body['detail'] ?? response.reasonPhrase ?? 'Permintaan gagal')
            as String,
        code: '${body['code'] ?? ''}',
        retryAfterSeconds: _retryAfterSeconds(response, body),
      );
    }
    return body;
  }

  int? _retryAfterSeconds(http.Response response, Map<String, Object?> body) {
    final header = int.tryParse(response.headers['retry-after'] ?? '');
    if (header != null) return header;
    return (body['retry_after'] as num?)?.toInt();
  }

  Future<Map<String, Object?>> health() async {
    return _json(await _get(_uri('/relay/health')));
  }

  Future<Map<String, Object?>> followupQuota({
    required String code,
    required int used,
    bool consume = false,
  }) async {
    final response = await _post(
      _uri('/relay/followup/quota'),
      headers: _headers,
      body: jsonEncode({'code': code, 'used': used, 'consume': consume}),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> googleLogin({required String idToken}) async {
    final response = await _post(
      _uri('/relay/auth/google'),
      headers: _headers,
      body: jsonEncode({'id_token': idToken}),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> employeeLogin({
    required String ownerId,
    required String username,
    required String password,
    required String deviceName,
    required String publicKey,
    required String encryptionKey,
    List<String> storeIds = const [],
  }) async {
    final response = await _post(
      _uri('/relay/auth/employee'),
      headers: _headers,
      body: jsonEncode({
        'owner_id': ownerId,
        'username': username,
        'password': password,
        'store_id': storeIds.isEmpty ? '' : storeIds.first,
        'device': {
          'nama': deviceName,
          'public_key': publicKey,
          'encryption_key': encryptionKey,
        },
      }),
    );
    return _json(response);
  }

  Future<void> changeEmployeePassword({
    required String ownerId,
    required String username,
    required String oldPassword,
    required String newPassword,
  }) async {
    final response = await _post(
      _uri('/relay/auth/employee/password'),
      headers: _headers,
      body: jsonEncode({
        'owner_id': ownerId,
        'username': username,
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    );
    await _json(response);
  }

  Future<Map<String, Object?>> enroll({
    required String enrollToken,
    required String ownerId,
    required String nama,
    required String publicKey,
    required String encryptionKey,
    required String ownerPublicKey,
    required List<String> storeIds,
    String kind = 'owner',
    int? employeeAccountId,
  }) async {
    final response = await _post(
      _uri('/relay/devices'),
      headers: {..._headers, 'X-Relay-Enroll-Token': enrollToken},
      body: jsonEncode({
        'owner_id': ownerId,
        'nama': nama,
        'kind': kind,
        'public_key': publicKey,
        'encryption_key': encryptionKey,
        'owner_public_key': ownerPublicKey,
        'store_ids': storeIds,
        'employee_account_id': ?employeeAccountId,
      }),
    );
    return _json(response);
  }

  Future<void> putKeyWrap({
    required String storeId,
    required String deviceId,
    required String wrappedKey,
    required String signature,
  }) async {
    final response = await _post(
      _uri('/relay/keys'),
      headers: _headers,
      body: jsonEncode({
        'store_id': storeId,
        'device_id': deviceId,
        'wrapped_key': wrappedKey,
        'signature': signature,
      }),
    );
    await _json(response);
  }

  Future<Map<String, Object?>> submitEnvelope(
    Map<String, Object?> envelope,
  ) async {
    final response = await _post(
      _uri('/relay/envelopes'),
      headers: _headers,
      body: jsonEncode(envelope),
    );
    return _json(response);
  }

  /// Mengirim banyak amplop dalam satu permintaan. Relay menyimpannya dalam
  /// satu transaksi; setiap amplop tetap idempoten sendiri-sendiri.
  Future<Map<String, Object?>> submitEnvelopes({
    required String storeId,
    required List<Map<String, Object?>> envelopes,
  }) async {
    final response = await _post(
      _uri('/relay/envelopes/batch'),
      headers: _headers,
      body: jsonEncode({'store_id': storeId, 'envelopes': envelopes}),
    );
    return _json(response);
  }

  /// Membuat kode pairing berumur pendek (default 15 menit) yang hanya dapat
  /// dipakai sekali untuk mendaftarkan satu perangkat owner.
  Future<Map<String, Object?>> createPairing({
    required String ownerId,
    int ttlMinutes = 15,
  }) async {
    final response = await _post(
      _uri('/relay/pairing'),
      headers: _headers,
      body: jsonEncode({'owner_id': ownerId, 'ttl_minutes': ttlMinutes}),
    );
    return _json(response);
  }

  /// Membuat kode undangan karyawan enam karakter yang berlaku singkat
  /// (default 10 menit) dan hanya dapat diklaim satu perangkat.
  Future<Map<String, Object?>> createInvite({
    required String ownerId,
    required String accountSyncId,
    required String storeId,
    int ttlMinutes = 10,
  }) async {
    final response = await _post(
      _uri('/relay/manage/invites'),
      headers: _headers,
      body: jsonEncode({
        'owner_id': ownerId,
        'account_sync_id': accountSyncId,
        'store_id': storeId,
        'ttl_minutes': ttlMinutes,
      }),
    );
    return _json(response);
  }

  Future<void> revokeManagedDevice({
    required String ownerId,
    required String deviceId,
  }) async {
    final response = await _post(
      _uri('/relay/manage/devices/$deviceId/revoke', {'owner_id': ownerId}),
      headers: _headers,
      body: jsonEncode({'reason': 'dicabut owner'}),
    );
    await _json(response);
  }

  Future<Map<String, Object?>> feed({
    required String storeId,
    required int sinceSeq,
    int limit = 200,
  }) async {
    final response = await _get(
      _uri('/relay/feed', {
        'store_id': storeId,
        'since_seq': '$sinceSeq',
        'limit': '$limit',
      }),
      headers: _headers,
    );
    return _json(response);
  }

  Future<Map<String, Object?>> ack({
    required String storeId,
    required int lastSeq,
  }) async {
    final response = await _post(
      _uri('/relay/feed/ack'),
      headers: _headers,
      body: jsonEncode({'store_id': storeId, 'last_seq': lastSeq}),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> createSyncRound(String storeId) async {
    final response = await _post(
      _uri('/relay/sync/rounds'),
      headers: _headers,
      body: jsonEncode({'store_id': storeId}),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> syncRound(String roundId) async {
    final response = await _get(
      _uri('/relay/sync/rounds/$roundId'),
      headers: _headers,
    );
    return _json(response);
  }

  Future<Map<String, Object?>> openSyncRound(String storeId) async {
    final response = await _get(
      _uri('/relay/sync/rounds/open', {'store_id': storeId}),
      headers: _headers,
    );
    return _json(response);
  }

  Future<Map<String, Object?>> ackSyncRound({
    required String roundId,
    required String storeId,
    required int lastSeq,
    required int pending,
  }) async {
    final response = await _post(
      _uri('/relay/sync/rounds/$roundId/ack'),
      headers: _headers,
      body: jsonEncode({
        'store_id': storeId,
        'last_seq': lastSeq,
        'pending_count': pending,
      }),
    );
    return _json(response);
  }

  Future<List<Map<String, Object?>>> devices() async {
    final response = await _get(_uri('/relay/devices'), headers: _headers);
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      final detail = decoded is Map ? decoded['detail'] : null;
      throw RelayException(response.statusCode, '$detail');
    }
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList();
  }

  Future<Map<String, Object?>> bootstrap(String storeId) async {
    final response = await _get(
      _uri('/relay/bootstrap', {'store_id': storeId}),
      headers: _headers,
    );
    return _json(response);
  }

  Future<Map<String, Object?>> createSnapshot(
    Map<String, Object?> payload,
  ) async {
    final response = await _post(
      _uri('/relay/snapshots'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> claimInvite({
    required String code,
    required String nama,
    required String publicKey,
    required String encryptionKey,
  }) async {
    final response = await _post(
      _uri('/relay/invites/claim'),
      headers: _headers,
      body: jsonEncode({
        'code': code.trim().toUpperCase(),
        'nama': nama,
        'public_key': publicKey,
        'encryption_key': encryptionKey,
      }),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> permissionsMe() async {
    final response = await _get(
      _uri('/relay/permissions/me'),
      headers: _headers,
    );
    return _json(response);
  }
}
