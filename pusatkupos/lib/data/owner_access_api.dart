import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/relay_url.dart';
import '../sync/crypto.dart';
import 'license_service.dart';
import 'secure_store.dart';

class OwnerApiException implements Exception {
  OwnerApiException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Kelola akun dan perangkat karyawan dari mode ringkasan laporan.
///
/// Endpoint pengelolaan memakai token perangkat pemilik (kind `owner` atau
/// `viewer`), bukan token pendaftaran yang hanya dipakai saat pairing.
class OwnerApi {
  OwnerApi({
    required String baseUrl,
    required this.deviceToken,
    required this.ownerId,
  }) : baseUrl = normalizeRelayUrl(baseUrl);

  final String baseUrl;
  final String deviceToken;
  final String ownerId;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Device-Token': deviceToken,
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Object?> _json(http.Response response) async {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      body = null;
    }
    if (response.statusCode >= 400) {
      final decoded = body is Map ? body : const <String, Object?>{};
      throw OwnerApiException(
        '${decoded['detail'] ?? response.reasonPhrase ?? 'Permintaan gagal'}',
        code: '${decoded['code'] ?? ''}',
      );
    }
    return body;
  }

  List<Map<String, Object?>> _rows(Object? body) {
    if (body is! List) return const [];
    return body
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList();
  }

  Future<List<Map<String, Object?>>> accounts() async {
    final response = await http.get(
      _uri('/relay/manage/accounts', {'owner_id': ownerId}),
      headers: _headers,
    );
    return _rows(await _json(response));
  }

  Future<List<Map<String, Object?>>> invites() async {
    final response = await http.get(
      _uri('/relay/manage/invites', {'owner_id': ownerId}),
      headers: _headers,
    );
    return _rows(await _json(response));
  }

  Future<List<Map<String, Object?>>> devices() async {
    final response = await http.get(
      _uri('/relay/manage/devices', {'owner_id': ownerId}),
      headers: _headers,
    );
    return _rows(await _json(response));
  }

  Future<void> revokeDevice(String deviceId) async {
    final response = await http.post(
      _uri('/relay/manage/devices/$deviceId/revoke', {'owner_id': ownerId}),
      headers: _headers,
      body: jsonEncode({'reason': 'dicabut owner'}),
    );
    await _json(response);
  }

  Future<Map<String, Object?>> saveAccount({
    String? syncId,
    required String username,
    required String nama,
    required String role,
    required List<String> permissions,
    required List<String> stores,
    String? password,
    String? passwordHash,
    String? passwordSalt,
    int passwordIterations = 600000,
    bool aktif = true,
    int permissionVersion = 0,
  }) async {
    final id = syncId == null || syncId.isEmpty ? newSyncId() : syncId;
    final version = permissionVersion <= 0 ? 1 : permissionVersion + 1;
    var hash = passwordHash ?? '';
    var salt = passwordSalt ?? '';
    if ((password ?? '').isNotEmpty) {
      salt = _newSalt();
      hash = await _derive(password!, salt, 600000);
    }
    final keys = await _accessKeys();
    final payload = {
      'v': 1,
      'owner_id': ownerId,
      'account_sync_id': id,
      'permission_version': version,
      'username': username.trim().toLowerCase(),
      'nama': nama.trim(),
      'role_base': role,
      'extra_permissions': permissions,
      'store_ids': stores,
      'issued_at': nowIso(),
    };
    final signature = await signPayload(
      keys.privateKey,
      utf8.encode(canonicalJson(payload)),
    );
    final response = await http.post(
      _uri('/relay/manage/accounts'),
      headers: _headers,
      body: jsonEncode({
        'owner_id': ownerId,
        'sync_id': id,
        'username': username.trim().toLowerCase(),
        'nama': nama.trim(),
        'role_base': role,
        'extra_permissions': permissions,
        'store_ids': stores,
        'password_hash': hash,
        'password_salt': salt,
        'password_iterations': passwordIterations,
        'aktif': aktif,
        'permission_version': version,
        'permission_payload': payload,
        'permission_signature': signature,
        'permission_signer_public_key': keys.publicKey,
      }),
    );
    final body = await _json(response);
    return body is Map
        ? body.map((key, value) => MapEntry('$key', value))
        : <String, Object?>{};
  }

  Future<Map<String, Object?>> createInvite({
    required String accountSyncId,
    required String storeId,
  }) async {
    final response = await http.post(
      _uri('/relay/manage/invites'),
      headers: _headers,
      body: jsonEncode({
        'owner_id': ownerId,
        'account_sync_id': accountSyncId,
        'store_id': storeId,
        'ttl_minutes': 10,
      }),
    );
    final body = await _json(response);
    return body is Map
        ? body.map((key, value) => MapEntry('$key', value))
        : <String, Object?>{};
  }

  /// Izin akun wajib ditandatangani kunci owner yang terdaftar di relay.
  /// Perangkat ringkasan hanya memegang kunci publik sehingga tidak dapat
  /// mengubah akun.
  Future<KeyMaterial> _accessKeys() async {
    final private = await SecureStore.instance.read('owner.signing.private');
    final public = await LicenseService.instance.ownerPublicKey();
    if (private == null ||
        private.isEmpty ||
        public == null ||
        public.isEmpty) {
      throw OwnerApiException(
        'Perubahan akun hanya dapat dilakukan dari perangkat pemilik.',
        code: 'owner_device_required',
      );
    }
    return KeyMaterial(privateKey: private, publicKey: public);
  }

  String _newSalt() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  Future<String> _derive(String value, String salt, int iterations) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(value)),
      nonce: base64Url.decode(salt),
    );
    return base64UrlEncode(await key.extractBytes());
  }
}
