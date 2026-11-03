import 'dart:convert';

import 'package:http/http.dart' as http;

class RelayException implements Exception {
  RelayException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'Relay $statusCode: $message';
}

class RelayClient {
  RelayClient({required this.baseUrl, this.deviceToken});

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

  Future<Map<String, Object?>> _json(http.Response response) async {
    Map<String, Object?> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        body = decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    if (response.statusCode >= 400) {
      throw RelayException(
        response.statusCode,
        (body['detail'] ?? response.reasonPhrase ?? 'Permintaan gagal') as String,
      );
    }
    return body;
  }

  Future<Map<String, Object?>> health() async {
    return _json(await http.get(_uri('/relay/health')));
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
    final response = await http.post(
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
        if (employeeAccountId != null)
          'employee_account_id': employeeAccountId,
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
    final response = await http.post(
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
    final response = await http.post(
      _uri('/relay/envelopes'),
      headers: _headers,
      body: jsonEncode(envelope),
    );
    return _json(response);
  }

  Future<Map<String, Object?>> feed({
    required String storeId,
    required int sinceSeq,
    int limit = 200,
  }) async {
    final response = await http.get(
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
    final response = await http.post(
      _uri('/relay/feed/ack'),
      headers: _headers,
      body: jsonEncode({'store_id': storeId, 'last_seq': lastSeq}),
    );
    return _json(response);
  }

  Future<List<Map<String, Object?>>> devices() async {
    final response = await http.get(_uri('/relay/devices'), headers: _headers);
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
    final response = await http.get(
      _uri('/relay/bootstrap', {'store_id': storeId}),
      headers: _headers,
    );
    return _json(response);
  }

  Future<Map<String, Object?>> createSnapshot(
    Map<String, Object?> payload,
  ) async {
    final response = await http.post(
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
    final response = await http.post(
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
    final response = await http.get(
      _uri('/relay/permissions/me'),
      headers: _headers,
    );
    return _json(response);
  }
}
