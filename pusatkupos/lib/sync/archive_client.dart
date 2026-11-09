import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../core/relay_url.dart';
import 'relay_client.dart';

/// Klien arsip. Base URL boleh berbeda dari relay (VPS arsip terpisah); bila
/// kosong, relay yang sama dipakai. Server arsip tidak punya endpoint hapus.
class ArchiveClient {
  ArchiveClient({required String baseUrl, this.deviceToken})
      : baseUrl = normalizeRelayUrl(baseUrl.trim().isEmpty
            ? serviceBaseUrl
            : baseUrl);

  final String baseUrl;
  final String? deviceToken;

  static const Duration _timeout = Duration(seconds: 60);

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$root$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Protocol-Version': '$protocolVersion',
        if ((deviceToken ?? '').isNotEmpty)
          'X-Device-Token': deviceToken!,
      };

  Future<Map<String, Object?>> _send(Future<http.Response> request) async {
    final response = await request.timeout(
      _timeout,
      onTimeout: () => throw RelayException(
        408,
        'Waktu permintaan arsip habis.',
        code: 'timeout',
      ),
    );
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
        '${body['detail'] ?? response.reasonPhrase ?? 'Permintaan arsip gagal'}',
        code: '${body['code'] ?? ''}',
      );
    }
    return body;
  }

  Future<Map<String, Object?>> putDocument(Map<String, Object?> payload) {
    return _send(
      http.post(
        _uri('/archive/documents'),
        headers: _headers,
        body: jsonEncode(payload),
      ),
    );
  }

  Future<Map<String, Object?>> getDocument({
    required String storeId,
    required String docType,
    required String docId,
    String contentHash = '',
  }) {
    return _send(
      http.get(
        _uri('/archive/documents', {
          'store_id': storeId,
          'doc_type': docType,
          'doc_id': docId,
          'content_hash': contentHash,
        }),
        headers: _headers,
      ),
    );
  }

  Future<Map<String, Object?>> search({
    required String storeId,
    String token = '',
    String dari = '',
    String sampai = '',
    int limit = 50,
    int offset = 0,
  }) {
    return _send(
      http.get(
        _uri('/archive/search', {
          'store_id': storeId,
          'token': token,
          'dari': dari,
          'sampai': sampai,
          'limit': '$limit',
          'offset': '$offset',
        }),
        headers: _headers,
      ),
    );
  }

  Future<Map<String, Object?>> export({
    required String storeId,
    String since = '',
    int limit = 100,
    int offset = 0,
  }) {
    return _send(
      http.get(
        _uri('/archive/export', {
          'store_id': storeId,
          'since': since,
          'limit': '$limit',
          'offset': '$offset',
        }),
        headers: _headers,
      ),
    );
  }
}
