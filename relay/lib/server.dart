import 'dart:convert';
import 'dart:io' show HttpConnectionInfo;
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth_rules.dart';
import 'canonical.dart';
import 'config.dart';
import 'db.dart';
import 'google.dart';
import 'license.dart';
import 'sync_round.dart';

const _followupQuotaLimit = 20;

class RelayServer {
  RelayServer(this.db, this.config, {GoogleTokenVerifier? google})
      : license = LicenseService(db),
        google = google ??
            (config.googleClientId.trim().isEmpty
                ? null
                : GoogleTokenVerifier(clientId: config.googleClientId)),
        _router = Router();

  final Database db;
  final RelayConfig config;
  final LicenseService license;
  final GoogleTokenVerifier? google;
  final RateLimiter _googleRateLimit = RateLimiter(
    max: 20,
    window: const Duration(minutes: 5),
  );
  final RateLimiter _employeeRateLimit = RateLimiter(
    max: 15,
    window: const Duration(minutes: 5),
  );
  final RateLimiter _passwordRateLimit = RateLimiter(
    max: 10,
    window: const Duration(minutes: 10),
  );
  final Router _router;
  int _activeRequests = 0;
  int _writeQueue = 0;
  int _lastLatencyMs = 0;

  Handler get handler {
    _router.get('/relay/health', _health);
    _router.post('/relay/devices', _enroll);
    _router.post('/relay/pairing', _createPairing);
    _router.post('/relay/keys', _putKeyWrap);
    _router.post('/relay/envelopes', _submitEnvelope);
    _router.post('/relay/envelopes/batch', _submitEnvelopeBatch);
    _router.get('/relay/feed', _feed);
    _router.post('/relay/feed/ack', _ack);
    _router.get('/relay/devices', _devices);
    _router.get('/relay/bootstrap', _bootstrap);
    _router.post('/relay/sync/rounds', _createSyncRound);
    _router.get('/relay/sync/rounds/open', _openSyncRound);
    _router.get('/relay/sync/rounds/<id>', _syncRound);
    _router.post('/relay/sync/rounds/<id>/ack', _ackSyncRound);
    _router.post('/relay/snapshots', _createSnapshot);
    _router.post('/relay/invites/claim', _claimInvite);
    _router.get('/relay/permissions/me', _permissionsMe);
    _router.get('/relay/manage/accounts', _manageAccounts);
    _router.post('/relay/manage/accounts', _saveAccount);
    _router.get('/relay/manage/invites', _manageInvites);
    _router.post('/relay/manage/invites', _createInvite);
    _router.get('/relay/manage/devices', _manageDevices);
    _router.post('/relay/manage/devices/<id>/revoke', _revokeDevice);
    _router.get('/relay/admin/license-public-key', _licensePublicKey);
    _router.post('/relay/admin/owners', _adminCreateOwner);
    _router.get('/relay/admin/identities', _adminIdentities);
    _router.post('/relay/admin/identities', _adminBindIdentity);
    _router.post('/relay/auth/google', _googleLogin);
    _router.post('/relay/auth/employee', _employeeLogin);
    _router.post('/relay/auth/employee/password', _employeeChangePassword);
    _router.post('/relay/followup/quota', _followupQuota);
    return const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_cors)
        .addMiddleware(_errors)
        .addMiddleware(_load)
        .addHandler(_router.call);
  }

  Middleware get _load => (inner) {
        return (request) async {
          _activeRequests++;
          final watch = Stopwatch()..start();
          try {
            return await inner(request);
          } finally {
            _activeRequests--;
            watch.stop();
            _lastLatencyMs = watch.elapsedMilliseconds;
          }
        };
      };

  Middleware get _cors => (inner) {
        const headers = {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers':
              'content-type, x-device-token, x-relay-enroll-token, authorization',
          'Access-Control-Max-Age': '600',
        };
        return (request) async {
          if (request.method == 'OPTIONS') {
            return Response.ok('', headers: headers);
          }
          final response = await inner(request);
          return response.change(headers: headers);
        };
      };

  Middleware get _errors => (inner) {
        return (request) async {
          try {
            return await inner(request);
          } catch (error, stack) {
            print('relay error: $error\n$stack');
            return _json(500, {'detail': '$error'});
          }
        };
      };

  Response _json(int status, Object? body) => Response(
        status,
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );

  Response _error(int status, String detail, {String code = ''}) =>
      _json(status, {'detail': detail, 'code': code});

  Future<Map<String, Object?>> _body(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw FormatException('Body harus objek JSON.');
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  String _token() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  String _id(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return '${prefix}_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  String _hash(String token) => crypto.sha256.convert(utf8.encode(token)).toString();

  String? _iso(Object? value) =>
      value is DateTime ? value.toUtc().toIso8601String() : value?.toString();

  Future<Map<String, Object?>?> _deviceAuth(Request request) async {
    final token = request.headers['x-device-token'] ?? '';
    if (token.isEmpty) return null;
    final row = await db.one(
      '''
SELECT d.*, o.owner_public_key AS owner_public_key_registered,
       o.license_plan, o.license_period_end, o.license_store_limit
FROM devices d JOIN owners o ON o.owner_id = d.owner_id
WHERE d.token_hash = @hash AND d.revoked_at IS NULL
''',
      {'hash': _hash(token)},
    );
    if (row == null) return null;
    await db.execute(
      'UPDATE devices SET last_seen_at = now() WHERE id = @id',
      {'id': row['id']},
    );
    return row;
  }

  Future<Map<String, Object?>?> _ownerAuth(
    Request request,
    String ownerId,
  ) async {
    final token = request.headers['x-relay-enroll-token'] ?? '';
    if (token.isEmpty || ownerId.isEmpty) return null;
    return db.one(
      '''
SELECT t.*, o.owner_public_key, o.license_plan, o.license_period_end,
       o.license_store_limit
FROM enroll_tokens t JOIN owners o ON o.owner_id = t.owner_id
WHERE t.token = @token AND t.owner_id = @owner AND t.revoked = false
  AND t.expires_at > now()
''',
      {'token': token, 'owner': ownerId},
    );
  }

  bool _admin(Request request) {
    final header = request.headers['authorization'] ?? '';
    return header == 'Bearer ${config.adminToken}';
  }

  /// Kelola akun/perangkat memakai token perangkat pemilik, bukan token
  /// pendaftaran yang hanya dipakai sekali saat pairing. Perangkat ringkasan
  /// milik pemilik memakai kind `viewer`, jadi keduanya diterima di sini.
  Future<Map<String, Object?>?> _manageAuth(
    Request request,
    String ownerId,
  ) async {
    if (ownerId.isEmpty) return null;
    if (_admin(request)) {
      return {'kind': 'admin', 'owner_id': ownerId};
    }
    final device = await _deviceAuth(request);
    if (device == null) return null;
    if (device['owner_id'] != ownerId) return null;
    final kind = '${device['kind'] ?? ''}';
    if (kind != 'owner' && kind != 'viewer') return null;
    return device;
  }

  /// Batas kasar untuk amplop dari perangkat karyawan. Isi amplop tetap
  /// terenkripsi, jadi pemeriksaan ini memakai petunjuk `entity`/`action`
  /// yang dikirim client; aturan konflik tetap ditegakkan saat apply.
  Future<bool> _employeeCanSend(
    DatabaseSession tx,
    Map<String, Object?> device,
    String entity,
    String action,
  ) async {
    if (entity.isEmpty || action.isEmpty) return false;
    const direct = {'nota', 'customer', 'unit', 'stock_movement'};
    if (direct.contains(entity)) return true;
    final accountId = device['employee_account_id'] as String? ?? '';
    final account = accountId.isEmpty
        ? null
        : await tx.one(
            'SELECT role_base, extra_permissions FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
            {'owner': device['owner_id'], 'sync': accountId},
          );
    if (account == null) return false;
    return employeeEntityAllowed(
      entity: entity,
      action: action,
      roleBase: '${account['role_base'] ?? ''}',
      extras: stringList(account['extra_permissions']).toSet(),
    );
  }

  Future<Map<String, Object?>?> _owner(String ownerId) =>
      db.one('SELECT * FROM owners WHERE owner_id = @id', {'id': ownerId});

  Future<String> _licenseFor(Map<String, Object?> owner) {
    final end = owner['license_period_end'];
    final periodEnd = end is DateTime
        ? end.toUtc()
        : DateTime.now().toUtc().add(const Duration(days: 30));
    return license.issueToken(
      ownerId: owner['owner_id'] as String,
      periodEnd: periodEnd,
      plan: owner['license_plan'] as String? ?? 'premium',
      storeLimit: (owner['license_store_limit'] as num?)?.toInt() ?? 1,
    );
  }

  Future<Response> _health(Request request) async {
    return _json(200, {
      'ok': true,
      'license_public_key': await license.publicKey(),
      'google_login': google != null,
      'server_time': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<Response> _followupQuota(Request request) async {
    final body = await _body(request);
    final code = '${body['code'] ?? ''}'.trim();
    if (code.length < 8 || code.length > 96) {
      return _error(400, 'Kode tidak valid.', code: 'invalid_code');
    }
    final reported =
        ((body['used'] as num?)?.toInt() ?? 0).clamp(0, _followupQuotaLimit);
    final consume = body['consume'] == true;
    final result = await db.tx((tx) async {
      await tx.execute(
        '''
INSERT INTO followup_quota (user_code, used, updated_at)
VALUES (@code, @used, now())
ON CONFLICT (user_code) DO UPDATE
SET used = GREATEST(followup_quota.used, EXCLUDED.used), updated_at = now()
''',
        {'code': code, 'used': reported},
      );
      var consumed = false;
      if (consume) {
        final rows = await tx.query(
          '''
UPDATE followup_quota SET used = used + 1, updated_at = now()
WHERE user_code = @code AND used < @limit
RETURNING used
''',
          {'code': code, 'limit': _followupQuotaLimit},
        );
        consumed = rows.isNotEmpty;
      }
      final row = await tx.one(
        'SELECT used FROM followup_quota WHERE user_code = @code',
        {'code': code},
      );
      final used = (row?['used'] as num?)?.toInt() ?? reported;
      return (used: used, consumed: consumed);
    });
    return _json(200, {
      'used': result.used,
      'limit': _followupQuotaLimit,
      'allowed': consume ? result.consumed : result.used < _followupQuotaLimit,
      'consumed': result.consumed,
    });
  }

  Future<Response> _enroll(Request request) async {
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) {
      return _error(401, 'Token pendaftaran tidak valid atau kedaluwarsa.');
    }
    final owner = await _owner(ownerId);
    if (owner == null) return _error(404, 'Owner belum terdaftar.');
    final ownerPublic = '${body['owner_public_key'] ?? ''}';
    final registered = owner['owner_public_key'] as String? ?? '';
    if (registered.isEmpty && ownerPublic.isNotEmpty) {
      await db.execute(
        'UPDATE owners SET owner_public_key = @key WHERE owner_id = @id',
        {'key': ownerPublic, 'id': ownerId},
      );
    } else if (registered.isNotEmpty && ownerPublic.isNotEmpty &&
        registered != ownerPublic) {
      return _error(409, 'Kunci owner tidak cocok dengan yang terdaftar.');
    }
    final deviceId = _id('dev');
    final token = _token();
    final storeIds = (body['store_ids'] as List? ?? const ['utama'])
        .map((item) => '$item')
        .toList();
    final kind = '${body['kind'] ?? 'owner'}';
    final employeeAccountId = body['employee_account_id']?.toString();
    await db.execute(
      '''
INSERT INTO devices (id, owner_id, nama, kind, employee_account_id, public_key,
  encryption_key, owner_public_key, store_ids, token_hash)
VALUES (@id, @owner, @nama, @kind, @account, @public, @encrypt, @ownerPublic,
  CAST(@stores AS jsonb), @hash)
''',
      {
        'id': deviceId,
        'owner': ownerId,
        'nama': '${body['nama'] ?? 'Perangkat'}',
        'kind': kind,
        'account': employeeAccountId,
        'public': '${body['public_key'] ?? ''}',
        'encrypt': '${body['encryption_key'] ?? ''}',
        'ownerPublic': ownerPublic.isEmpty ? registered : ownerPublic,
        'stores': jsonEncode(storeIds),
        'hash': _hash(token),
      },
    );
    if (auth['token'] != null) {
      await db.execute(
        'UPDATE enroll_tokens SET revoked = true WHERE token = @token',
        {'token': auth['token']},
      );
    }
    return _json(200, {
      'device': {
        'id': deviceId,
        'owner_id': ownerId,
        'nama': body['nama'] ?? 'Perangkat',
        'kind': kind,
        'store_ids': storeIds,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      'token': token,
      'license_token': await _licenseFor(owner),
    });
  }

  /// Membuat kode pairing berumur pendek (10-15 menit) untuk satu perangkat.
  /// Kode hanya dapat dipakai sekali dan token perangkat hasil pairing dapat
  /// dicabut kapan saja.
  Future<Response> _createPairing(Request request) async {
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final ttl = ((body['ttl_minutes'] as num?)?.toInt() ?? 15).clamp(5, 20);
    final code = _token();
    final expires = DateTime.now().toUtc().add(Duration(minutes: ttl));
    await db.execute(
      '''
INSERT INTO enroll_tokens (token, owner_id, expires_at)
VALUES (@token, @owner, @expires)
''',
      {'token': code, 'owner': ownerId, 'expires': expires},
    );
    return _json(200, {
      'code': code,
      'owner_id': ownerId,
      'expires_at': expires.toIso8601String(),
      'ttl_minutes': ttl,
    });
  }

  Future<Response> _putKeyWrap(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    final target = '${body['device_id'] ?? ''}';
    final wrapped = '${body['wrapped_key'] ?? ''}';
    final signature = '${body['signature'] ?? ''}';
    if (store.isEmpty || target.isEmpty || wrapped.isEmpty || signature.isEmpty) {
      return _error(400, 'Data key-wrap tidak lengkap.');
    }
    final targetRow = await db.one(
      'SELECT id, owner_id FROM devices WHERE id = @id',
      {'id': target},
    );
    if (targetRow == null || targetRow['owner_id'] != device['owner_id']) {
      return _error(404, 'Perangkat tujuan tidak ditemukan.');
    }
    final ownerPublic =
        device['owner_public_key_registered'] as String? ?? '';
    if (ownerPublic.isEmpty) {
      return _error(409, 'Kunci owner belum terdaftar.');
    }
    final valid = await license.verifyPayload(
      publicKey: ownerPublic,
      payload: canonicalJson({
        'store_id': store,
        'device_id': target,
        'wrapped_key': wrapped,
      }),
      signature: signature,
    );
    if (!valid) return _error(400, 'Tanda tangan key-wrap tidak valid.');
    await db.execute(
      '''
INSERT INTO store_keys (owner_id, store_id, device_id, wrapped_key, signature)
VALUES (@owner, @store, @device, @wrapped, @signature)
ON CONFLICT (owner_id, store_id, device_id) DO UPDATE SET
  wrapped_key = EXCLUDED.wrapped_key,
  signature = EXCLUDED.signature,
  created_at = now()
''',
      {
        'owner': device['owner_id'],
        'store': store,
        'device': target,
        'wrapped': wrapped,
        'signature': signature,
      },
    );
    return _json(200, {'ok': true});
  }

  Future<Response> _submitEnvelope(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    try {
      _guardOverload();
      final saved = await db.tx(
        (tx) => _ingestEnvelope(tx, device, body),
      );
      await _pruneAcknowledged(device['owner_id'] as String, store);
      return _json(200, {
        ...saved,
        ..._batchLimits(),
        'storage': await _storageStatus(device['owner_id'] as String, store),
      });
    } on _BusyRejection catch (error) {
      return _busy(error);
    } on _EnvelopeRejection catch (error) {
      return _error(error.status, error.detail, code: error.code);
    }
  }

  Future<Response> _submitEnvelopeBatch(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    final raw = body['envelopes'];
    if (raw is! List || raw.isEmpty) {
      return _error(400, 'Batch amplop kosong.');
    }
    try {
      _guardOverload();
      _writeQueue++;
      final results = await db.tx((tx) async {
        final output = <Map<String, Object?>>[];
        for (final item in raw) {
          if (item is! Map) {
            throw _EnvelopeRejection(400, 'Amplop tidak valid.');
          }
          output.add(
            await _ingestEnvelope(
              tx,
              device,
              item.map((key, value) => MapEntry('$key', value)),
            ),
          );
        }
        return output;
      });
      await _pruneAcknowledged(device['owner_id'] as String, store);
      return _json(200, {
        'results': results,
        'accepted': results.length,
        ..._batchLimits(),
        'storage': await _storageStatus(device['owner_id'] as String, store),
      });
    } on _BusyRejection catch (error) {
      return _busy(error);
    } on _EnvelopeRejection catch (error) {
      return _error(error.status, error.detail, code: error.code);
    } finally {
      if (_writeQueue > 0) _writeQueue--;
    }
  }

  /// Validasi dan simpan satu amplop. Dipakai baik oleh endpoint tunggal
  /// maupun batch sehingga aturan tanda tangan dan peran tidak berbeda.
  Future<Map<String, Object?>> _ingestEnvelope(
    DatabaseSession tx,
    Map<String, Object?> device,
    Map<String, Object?> body,
  ) async {
    final sender = '${body['sender_device_id'] ?? ''}';
    if (sender.isEmpty || sender != device['id']) {
      throw _EnvelopeRejection(403, 'Pengirim amplop bukan perangkat ini.');
    }
    final store = '${body['store_id'] ?? ''}';
    final stores = stringList(device['store_ids']);
    if (!stores.contains(store)) {
      throw _EnvelopeRejection(
        403,
        'Perangkat tidak terdaftar pada toko $store.',
      );
    }
    final fields = {
      'v': 1,
      'store_id': store,
      'sender_device_id': sender,
      'recipient_device_id': '${body['recipient_device_id'] ?? ''}',
      'seq': (body['seq'] as num?)?.toInt() ?? 0,
      'hlc_wall': (body['hlc_wall'] as num?)?.toInt() ?? 0,
      'hlc_counter': (body['hlc_counter'] as num?)?.toInt() ?? 0,
      'idempotency_key': '${body['idempotency_key'] ?? ''}',
      'ciphertext': '${body['ciphertext'] ?? ''}',
      'nonce': '${body['nonce'] ?? ''}',
    };
    final signature = '${body['signature'] ?? ''}';
    final entity = '${body['entity'] ?? ''}';
    final action = '${body['action'] ?? ''}';
    final entityId = '${body['entity_id'] ?? ''}';
    final hintsSignature = '${body['hints_signature'] ?? ''}';
    if (store.isEmpty ||
        fields['idempotency_key'] == '' ||
        fields['ciphertext'] == '' ||
        fields['nonce'] == '' ||
        (fields['seq'] as int) <= 0 ||
        signature.isEmpty) {
      throw _EnvelopeRejection(400, 'Amplop tidak lengkap.');
    }
    final valid = await license.verifyPayload(
      publicKey: device['public_key'] as String,
      payload: canonicalJson(fields),
      signature: signature,
    );
    if (!valid) {
      throw _EnvelopeRejection(400, 'Tanda tangan amplop tidak valid.');
    }
    if (hintsSignature.isEmpty) {
      throw _EnvelopeRejection(
        400,
        'Tanda tangan petunjuk amplop wajib ada.',
        code: 'hints_required',
      );
    }
    final hintsValid = await license.verifyPayload(
      publicKey: device['public_key'] as String,
      payload: canonicalJson(
        envelopeHintFields(
          storeId: store,
          senderDeviceId: sender,
          entity: entity,
          action: action,
          entityId: entityId,
          idempotencyKey: fields['idempotency_key'] as String,
        ),
      ),
      signature: hintsSignature,
    );
    if (!hintsValid) {
      throw _EnvelopeRejection(
        400,
        'Tanda tangan petunjuk amplop tidak valid.',
        code: 'hints_invalid',
      );
    }
    final kind = '${device['kind'] ?? ''}';
    if (!canDeviceSubmitEnvelope(kind)) {
      throw _EnvelopeRejection(
        403,
        'Perangkat ringkasan hanya dapat membaca data.',
      );
    }
    if (kind == 'employee') {
      if (!await _employeeCanSend(tx, device, entity, action)) {
        throw _EnvelopeRejection(
          403,
          'Perangkat ini tidak berwenang mengirim perubahan tersebut.',
          code: 'permission_denied',
        );
      }
    }

    final existing = await tx.one(
      '''
SELECT id, relay_seq FROM envelopes
WHERE owner_id = @owner
  AND (idempotency_key = @key
       OR (store_id = @store AND sender_device_id = @sender AND seq = @seq))
''',
      {
        'owner': device['owner_id'],
        'key': fields['idempotency_key'],
        'store': store,
        'sender': sender,
        'seq': fields['seq'],
      },
    );
    if (existing != null) {
      return {
        'id': existing['id'],
        'relay_seq': existing['relay_seq'],
        'duplicate': true,
      };
    }
    final id = _id('env');
    await tx.execute(
      '''
INSERT INTO envelopes (id, owner_id, store_id, sender_device_id,
  recipient_device_id, seq, hlc_wall, hlc_counter, idempotency_key,
  ciphertext, nonce, signature, entity, action, entity_id, hints_signature)
VALUES (@id, @owner, @store, @sender, @recipient, @seq, @wall, @counter, @key,
  @ciphertext, @nonce, @signature, @entity, @action, @entityId, @hints)
ON CONFLICT DO NOTHING
''',
      {
        'id': id,
        'owner': device['owner_id'],
        'store': store,
        'sender': sender,
        'recipient': fields['recipient_device_id'],
        'seq': fields['seq'],
        'wall': fields['hlc_wall'],
        'counter': fields['hlc_counter'],
        'key': fields['idempotency_key'],
        'ciphertext': fields['ciphertext'],
        'nonce': fields['nonce'],
        'signature': signature,
        'entity': entity,
        'action': action,
        'entityId': entityId,
        'hints': hintsSignature,
      },
    );
    final saved = await tx.one(
      'SELECT id, relay_seq FROM envelopes WHERE idempotency_key = @key',
      {'key': fields['idempotency_key']},
    );
    return saved ?? {'id': id};
  }

  void _guardOverload() {
    if (_activeRequests > 40 ||
        _writeQueue > 20 ||
        _lastLatencyMs > 1500) {
      final seconds = (_lastLatencyMs / 500).ceil().clamp(2, 30);
      throw _BusyRejection(seconds);
    }
  }

  Response _busy(_BusyRejection error) {
    return Response(
      429,
      body: jsonEncode({
        'detail': 'Relay sedang sibuk. Coba lagi sebentar.',
        'code': 'relay_sibuk',
        'retry_after': error.seconds,
      }),
      headers: {
        'content-type': 'application/json',
        'retry-after': '${error.seconds}',
      },
    );
  }

  Map<String, Object?> _batchLimits() {
    final count = (100 - _activeRequests * 5 - _writeQueue * 2).clamp(5, 100);
    final bytes = (4 * 1024 * 1024 -
            _writeQueue * 65536 -
            _lastLatencyMs * 512)
        .clamp(128 * 1024, 4 * 1024 * 1024);
    return {
      'max_batch': {'count': count, 'bytes': bytes},
      'retry_after': null,
    };
  }

  Future<Map<String, Object?>> _storageStatus(
    String ownerId,
    String store,
  ) async {
    final row = await db.one(
      '''
SELECT COALESCE(SUM(octet_length(ciphertext) + octet_length(nonce)), 0) AS bytes
FROM envelopes WHERE owner_id = @owner AND store_id = @store
''',
      {'owner': ownerId, 'store': store},
    );
    final used = (row?['bytes'] as num?)?.toInt() ?? 0;
    final limit = config.storageLimitBytes;
    return {
      'used_bytes': used,
      'limit_bytes': limit,
      'warning': used >= limit,
    };
  }

  /// Hapus amplop yang sudah diakui SEMUA perangkat aktif pada toko.
  /// Perangkat yang dicabut tidak lagi masuk daftar ack.
  Future<void> _pruneAcknowledged(String ownerId, String store) async {
    if (store.isEmpty) return;
    final activeRow = await db.one(
      '''
SELECT COUNT(*) AS total FROM devices
WHERE owner_id = @owner AND revoked_at IS NULL
  AND store_ids @> CAST(@stores AS jsonb)
''',
      {'owner': ownerId, 'stores': jsonEncode([store])},
    );
    final active = (activeRow?['total'] as num?)?.toInt() ?? 0;
    if (active <= 0) return;
    final floorRow = await db.one(
      '''
SELECT MIN(c.last_seq) AS seq, COUNT(*) AS total
FROM cursors c
JOIN devices d ON d.id = c.device_id AND d.owner_id = c.owner_id
WHERE c.owner_id = @owner AND c.store_id = @store
  AND d.revoked_at IS NULL AND d.store_ids @> CAST(@stores AS jsonb)
''',
      {
        'owner': ownerId,
        'store': store,
        'stores': jsonEncode([store]),
      },
    );
    final acked = (floorRow?['total'] as num?)?.toInt() ?? 0;
    final seq = (floorRow?['seq'] as num?)?.toInt() ?? 0;
    if (acked < active || seq <= 0) return;
    await db.execute(
      '''
DELETE FROM envelopes
WHERE owner_id = @owner AND store_id = @store AND relay_seq <= @seq
''',
      {'owner': ownerId, 'store': store, 'seq': seq},
    );
  }

  Future<Response> _feed(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final store = request.url.queryParameters['store_id'] ?? '';
    final since = int.tryParse(request.url.queryParameters['since_seq'] ?? '') ?? 0;
    final limit = (int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 200)
        .clamp(1, 500);
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    final snapshot = await db.one(
      'SELECT * FROM snapshots WHERE owner_id = @owner AND store_id = @store',
      {'owner': device['owner_id'], 'store': store},
    );
    final maxRow = await db.one(
      'SELECT COALESCE(MAX(relay_seq), 0) AS latest FROM envelopes WHERE owner_id = @owner AND store_id = @store',
      {'owner': device['owner_id'], 'store': store},
    );
    var latest = (maxRow?['latest'] as num?)?.toInt() ?? 0;
    final snapSeq = (snapshot?['store_seq'] as num?)?.toInt() ?? 0;
    if (snapSeq > latest) latest = snapSeq;
    final cursorRow = await db.one(
      'SELECT last_seq FROM cursors WHERE owner_id = @owner AND device_id = @device AND store_id = @store',
      {'owner': device['owner_id'], 'device': device['id'], 'store': store},
    );
    final cursor = (cursorRow?['last_seq'] as num?)?.toInt() ?? since;
    if (snapshot != null && cursor < snapSeq) {
      return _json(200, {
        'envelopes': [],
        'next_seq': cursor,
        'latest_seq': latest,
        'snapshot_required': true,
      });
    }
    final rows = await db.query(
      '''
SELECT * FROM envelopes
WHERE owner_id = @owner AND store_id = @store AND relay_seq > @since
  AND (recipient_device_id = '' OR recipient_device_id = @device)
ORDER BY relay_seq ASC LIMIT @limit
''',
      {
        'owner': device['owner_id'],
        'store': store,
        'since': since,
        'device': device['id'],
        'limit': limit,
      },
    );
    final envelopes = rows
        .map(
          (row) => {
            'v': 1,
            'id': row['id'],
            'store_id': row['store_id'],
            'sender_device_id': row['sender_device_id'],
            'recipient_device_id': row['recipient_device_id'],
            'seq': (row['seq'] as num?)?.toInt() ?? 0,
            'hlc_wall': (row['hlc_wall'] as num?)?.toInt() ?? 0,
            'hlc_counter': (row['hlc_counter'] as num?)?.toInt() ?? 0,
            'idempotency_key': row['idempotency_key'],
            'ciphertext': row['ciphertext'],
            'nonce': row['nonce'],
            'signature': row['signature'],
            'entity': row['entity'],
            'action': row['action'],
            'entity_id': row['entity_id'],
            'hints_signature': row['hints_signature'],
            'relay_seq': (row['relay_seq'] as num?)?.toInt() ?? 0,
          },
        )
        .toList();
    final next = envelopes.isEmpty
        ? (latest > since ? latest : since)
        : (envelopes.last['relay_seq'] as int);
    return _json(200, {
      'envelopes': envelopes,
      'next_seq': next,
      'latest_seq': latest,
      'snapshot_required': false,
    });
  }

  Future<Response> _ack(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    final lastSeq = (body['last_seq'] as num?)?.toInt() ?? 0;
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    await db.execute(
      '''
INSERT INTO cursors (owner_id, device_id, store_id, last_seq, updated_at)
VALUES (@owner, @device, @store, @seq, now())
ON CONFLICT (owner_id, device_id, store_id) DO UPDATE SET
  last_seq = GREATEST(cursors.last_seq, EXCLUDED.last_seq),
  updated_at = now()
''',
      {
        'owner': device['owner_id'],
        'device': device['id'],
        'store': store,
        'seq': lastSeq,
      },
    );
    return _json(200, {'ok': true, 'cursor': lastSeq});
  }

  Future<Response> _devices(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final rows = await db.query(
      '''
SELECT d.id, d.owner_id, d.nama, d.kind, d.public_key, d.encryption_key,
       d.store_ids, d.created_at, d.revoked_at, d.last_seen_at,
       a.role_base, a.extra_permissions
FROM devices d
LEFT JOIN accounts a ON a.owner_id = d.owner_id
  AND a.sync_id = d.employee_account_id
WHERE d.owner_id = @owner ORDER BY d.created_at
''',
      {'owner': device['owner_id']},
    );
    return _json(200, rows.map(_deviceJson).toList());
  }

  Map<String, Object?> _deviceJson(Map<String, Object?> row) => {
        'id': row['id'],
        'owner_id': row['owner_id'],
        'nama': row['nama'],
        'kind': row['kind'],
        'role_base': row['role_base'] ?? '',
        'extra_permissions': stringList(row['extra_permissions']),
        'public_key': row['public_key'],
        'encryption_key': row['encryption_key'],
        'store_ids': stringList(row['store_ids']),
        'created_at': _iso(row['created_at']),
        'last_seen_at': _iso(row['last_seen_at']),
        'revoked_at': _iso(row['revoked_at']),
      };

  Future<Response> _bootstrap(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final store = request.url.queryParameters['store_id'] ?? '';
    final wrap = await db.one(
      'SELECT wrapped_key, signature FROM store_keys WHERE owner_id = @owner AND store_id = @store AND device_id = @device',
      {'owner': device['owner_id'], 'store': store, 'device': device['id']},
    );
    final exists = await db.one(
      'SELECT 1 AS ok FROM store_keys WHERE owner_id = @owner AND store_id = @store LIMIT 1',
      {'owner': device['owner_id'], 'store': store},
    );
    final snapshot = await db.one(
      'SELECT * FROM snapshots WHERE owner_id = @owner AND store_id = @store',
      {'owner': device['owner_id'], 'store': store},
    );
    final maxRow = await db.one(
      'SELECT COALESCE(MAX(relay_seq), 0) AS latest FROM envelopes WHERE owner_id = @owner AND store_id = @store',
      {'owner': device['owner_id'], 'store': store},
    );
    var latest = (maxRow?['latest'] as num?)?.toInt() ?? 0;
    final snapSeq = (snapshot?['store_seq'] as num?)?.toInt() ?? 0;
    if (snapSeq > latest) latest = snapSeq;
    final cursorRow = await db.one(
      'SELECT last_seq FROM cursors WHERE owner_id = @owner AND device_id = @device AND store_id = @store',
      {'owner': device['owner_id'], 'device': device['id'], 'store': store},
    );
    final cursor = (cursorRow?['last_seq'] as num?)?.toInt() ?? 0;
    final body = {
      'store_id': store,
      'store_key_exists': exists != null,
      'wrapped_key': wrap?['wrapped_key'] ?? '',
      'wrapped_key_signature': wrap?['signature'] ?? '',
      'latest_seq': latest,
      'cursor': cursor,
      'snapshot_required': snapshot != null && cursor < snapSeq,
      'snapshot': snapshot == null ? null : _snapshotJson(snapshot),
    };
    return _json(200, body);
  }

  Map<String, Object?> _snapshotJson(Map<String, Object?> row) => {
        'id': row['id'],
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'store_seq': (row['store_seq'] as num?)?.toInt() ?? 0,
        'ciphertext': row['ciphertext'],
        'nonce': row['nonce'],
        'signature': row['signature'],
        'checksum': row['checksum'],
        'hlc_wall': (row['hlc_wall'] as num?)?.toInt() ?? 0,
        'hlc_counter': (row['hlc_counter'] as num?)?.toInt() ?? 0,
        'round_id': '${row['round_id'] ?? ''}',
        'complete': row['complete'] != false,
        'device_manifest': jsonList(row['device_manifest']),
      };

  Future<int> _storeLatestSeq(String owner, String store) async {
    final maxRow = await db.one(
      'SELECT COALESCE(MAX(relay_seq), 0) AS latest FROM envelopes '
      'WHERE owner_id = @owner AND store_id = @store',
      {'owner': owner, 'store': store},
    );
    var latest = (maxRow?['latest'] as num?)?.toInt() ?? 0;
    final snapshot = await db.one(
      'SELECT store_seq FROM snapshots WHERE owner_id = @owner AND store_id = @store',
      {'owner': owner, 'store': store},
    );
    final snapSeq = (snapshot?['store_seq'] as num?)?.toInt() ?? 0;
    if (snapSeq > latest) latest = snapSeq;
    return latest;
  }

  /// Perangkat yang wajib ikut dalam putaran: semua perangkat owner yang
  /// menulis, ditambah satu perangkat terbaru per akun karyawan. Perangkat
  /// ringkasan dan perangkat yang sudah dicabut tidak dihitung.
  Future<List<Map<String, Object?>>> _roundDevices(
    String owner,
    String store,
    Map<String, Object?> requester,
  ) async {
    final rows = await db.query(
      '''
SELECT id, nama, kind, employee_account_id, created_at
FROM devices
WHERE owner_id = @owner AND revoked_at IS NULL
  AND store_ids @> jsonb_build_array(CAST(@store AS text))
ORDER BY created_at DESC
''',
      {'owner': owner, 'store': store},
    );
    final ownerDevices = <Map<String, Object?>>[];
    final employeeDevices = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final kind = '${row['kind']}';
      if (kind == 'viewer') continue;
      final entry = {
        'id': '${row['id']}',
        'nama': '${row['nama']}',
        'kind': kind,
      };
      if (kind == 'employee') {
        final account = '${row['employee_account_id'] ?? ''}';
        final key = account.isEmpty ? 'device:${row['id']}' : account;
        employeeDevices.putIfAbsent(key, () => entry);
      } else {
        ownerDevices.add(entry);
      }
    }
    final devices = [...ownerDevices, ...employeeDevices.values];
    if ('${requester['kind']}' != 'viewer' &&
        !devices.any((item) => item['id'] == requester['id'])) {
      devices.add({
        'id': '${requester['id']}',
        'nama': '${requester['nama']}',
        'kind': '${requester['kind']}',
      });
    }
    return devices;
  }

  Future<Map<String, Object?>> _roundPayload(Map<String, Object?> round) async {
    final owner = '${round['owner_id']}';
    final store = '${round['store_id']}';
    final ackRows = await db.query(
      'SELECT device_id, last_seq, pending_count, acked_at '
      'FROM sync_round_acks WHERE round_id = @id',
      {'id': round['id']},
    );
    final acks = ackRows
        .map(
          (row) => {
            'device_id': row['device_id'],
            'last_seq': row['last_seq'],
            'pending_count': row['pending_count'],
            'acked_at': _iso(row['acked_at']),
          },
        )
        .toList();
    final revokedRows = await db.query(
      'SELECT id FROM devices WHERE owner_id = @owner AND revoked_at IS NOT NULL',
      {'owner': owner},
    );
    final revoked = revokedRows.map((row) => '${row['id']}').toSet();
    final evaluation = evaluateSyncRound(
      latestSeq: (round['latest_seq'] as num?)?.toInt() ?? 0,
      currentLatestSeq: await _storeLatestSeq(owner, store),
      devices: jsonList(round['devices']),
      acks: acks,
      revokedDeviceIds: revoked,
    );
    return {
      'id': '${round['id']}',
      'store_id': store,
      'status': '${round['status']}',
      'created_at': _iso(round['created_at']),
      'completed_at': _iso(round['completed_at']),
      ...evaluation,
    };
  }

  Future<Response> _createSyncRound(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    if ('${device['kind']}' != 'owner') {
      return _error(
        403,
        'Hanya perangkat owner yang dapat memeriksa kelengkapan cadangan.',
        code: 'owner_device_required',
      );
    }
    final owner = '${device['owner_id']}';
    final latest = await _storeLatestSeq(owner, store);
    final devices = await _roundDevices(owner, store, device);
    await db.execute(
      "UPDATE sync_rounds SET status = 'superseded' "
      "WHERE owner_id = @owner AND store_id = @store AND status = 'open'",
      {'owner': owner, 'store': store},
    );
    final id = _id('rnd');
    await db.execute(
      '''
INSERT INTO sync_rounds (id, owner_id, store_id, requested_by, latest_seq, devices)
VALUES (@id, @owner, @store, @device, @latest, CAST(@devices AS jsonb))
''',
      {
        'id': id,
        'owner': owner,
        'store': store,
        'device': device['id'],
        'latest': latest,
        'devices': jsonEncode(devices),
      },
    );
    final round = await db.one('SELECT * FROM sync_rounds WHERE id = @id', {
      'id': id,
    });
    if (round == null) return _error(500, 'Putaran sinkron gagal dibuat.');
    return _json(200, await _roundPayload(round));
  }

  Future<Response> _openSyncRound(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final store = request.url.queryParameters['store_id'] ?? '';
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    final round = await db.one(
      '''
SELECT * FROM sync_rounds
WHERE owner_id = @owner AND store_id = @store AND status = 'open'
ORDER BY created_at DESC LIMIT 1
''',
      {'owner': device['owner_id'], 'store': store},
    );
    if (round == null) return _json(200, {'round': null});
    final listed = jsonList(round['devices']).any(
      (item) => '${item['id']}' == '${device['id']}',
    );
    if (!listed) return _json(200, {'round': null});
    return _json(200, {'round': await _roundPayload(round)});
  }

  Future<Response> _syncRound(Request request, String id) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final round = await db.one('SELECT * FROM sync_rounds WHERE id = @id', {
      'id': id,
    });
    if (round == null || round['owner_id'] != device['owner_id']) {
      return _error(404, 'Putaran sinkron tidak ditemukan.');
    }
    return _json(200, await _roundPayload(round));
  }

  Future<Response> _ackSyncRound(Request request, String id) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    final round = await db.one('SELECT * FROM sync_rounds WHERE id = @id', {
      'id': id,
    });
    if (round == null ||
        round['owner_id'] != device['owner_id'] ||
        '${round['store_id']}' != store) {
      return _error(404, 'Putaran sinkron tidak ditemukan.');
    }
    final listed = jsonList(round['devices']).any(
      (item) => '${item['id']}' == '${device['id']}',
    );
    if (!listed) {
      return _error(403, 'Perangkat ini tidak termasuk dalam putaran sinkron.');
    }
    final lastSeq = (body['last_seq'] as num?)?.toInt() ?? 0;
    final pending = ((body['pending_count'] as num?)?.toInt() ?? 0)
        .clamp(0, 1000000);
    await db.execute(
      '''
INSERT INTO sync_round_acks (round_id, device_id, last_seq, pending_count)
VALUES (@round, @device, @seq, @pending)
ON CONFLICT (round_id, device_id) DO UPDATE SET
  last_seq = GREATEST(sync_round_acks.last_seq, EXCLUDED.last_seq),
  pending_count = EXCLUDED.pending_count,
  acked_at = now()
''',
      {
        'round': id,
        'device': device['id'],
        'seq': lastSeq,
        'pending': pending,
      },
    );
    var payload = await _roundPayload(round);
    if (payload['complete'] == true && '${round['status']}' != 'complete') {
      await db.execute(
        "UPDATE sync_rounds SET status = 'complete', "
        'completed_at = COALESCE(completed_at, now()) WHERE id = @id',
        {'id': id},
      );
      final refreshed = await db.one(
        'SELECT * FROM sync_rounds WHERE id = @id',
        {'id': id},
      );
      if (refreshed != null) payload = await _roundPayload(refreshed);
    }
    return _json(200, payload);
  }

  Future<Response> _createSnapshot(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    if ('${device['kind']}' == 'viewer') {
      return _error(
        403,
        'Mode ringkasan tidak dapat mengunggah cadangan toko.',
        code: 'read_only',
      );
    }
    final roundId = '${body['round_id'] ?? ''}';
    final round = roundId.isEmpty
        ? null
        : await db.one('SELECT * FROM sync_rounds WHERE id = @id', {
            'id': roundId,
          });
    if (round == null ||
        round['owner_id'] != device['owner_id'] ||
        '${round['store_id']}' != store) {
      return _error(
        409,
        'Periksa kelengkapan perangkat sebelum mengunggah cadangan.',
        code: 'sync_round_required',
      );
    }
    final roundStatus = await _roundPayload(round);
    if (roundStatus['complete'] != true) {
      return _json(409, {
        'detail': 'Cadangan belum lengkap: masih ada perangkat yang belum '
            'sinkron atau ada data baru sejak pemeriksaan.',
        'code': 'incomplete_store',
        'round': roundStatus,
      });
    }
    final seq = (body['store_seq'] as num?)?.toInt() ?? 0;
    if (seq != ((roundStatus['latest_seq'] as num?)?.toInt() ?? 0)) {
      return _error(
        409,
        'Urutan cadangan tidak cocok dengan putaran sinkron.',
        code: 'stale_round',
      );
    }
    final checksum = '${body['checksum'] ?? ''}';
    final signature = '${body['signature'] ?? ''}';
    final wall = (body['hlc_wall'] as num?)?.toInt() ?? 0;
    final counter = (body['hlc_counter'] as num?)?.toInt() ?? 0;
    if (checksum.isEmpty ||
        signature.isEmpty ||
        '${body['ciphertext'] ?? ''}'.isEmpty ||
        '${body['nonce'] ?? ''}'.isEmpty) {
      return _error(400, 'Isi snapshot tidak lengkap.');
    }
    final valid = await license.verifyPayload(
      publicKey: '${device['public_key']}',
      payload: canonicalJson({
        'store_id': store,
        'device_id': '${device['id']}',
        'checksum': checksum,
        'store_seq': seq,
        'hlc_wall': wall,
        'hlc_counter': counter,
      }),
      signature: signature,
    );
    if (!valid) {
      return _error(400, 'Tanda tangan snapshot tidak valid.');
    }
    final id = _id('snap');
    await db.execute(
      '''
INSERT INTO snapshots (owner_id, store_id, id, device_id, store_seq, ciphertext,
  nonce, signature, checksum, hlc_wall, hlc_counter, round_id, complete,
  device_manifest)
VALUES (@owner, @store, @id, @device, @seq, @ciphertext, @nonce, @signature,
  @checksum, @wall, @counter, @round, true, CAST(@manifest AS jsonb))
ON CONFLICT (owner_id, store_id) DO UPDATE SET
  id = EXCLUDED.id, device_id = EXCLUDED.device_id, store_seq = EXCLUDED.store_seq,
  ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce,
  signature = EXCLUDED.signature, checksum = EXCLUDED.checksum,
  hlc_wall = EXCLUDED.hlc_wall, hlc_counter = EXCLUDED.hlc_counter,
  round_id = EXCLUDED.round_id, complete = EXCLUDED.complete,
  device_manifest = EXCLUDED.device_manifest,
  created_at = now()
''',
      {
        'owner': device['owner_id'],
        'store': store,
        'id': id,
        'device': device['id'],
        'seq': seq,
        'ciphertext': '${body['ciphertext'] ?? ''}',
        'nonce': '${body['nonce'] ?? ''}',
        'signature': signature,
        'checksum': checksum,
        'wall': wall,
        'counter': counter,
        'round': roundId,
        'manifest': jsonEncode(roundStatus['devices'] ?? const []),
      },
    );
    return _json(200, {
      'id': id,
      'store_id': store,
      'device_id': device['id'],
      'store_seq': seq,
      'checksum': checksum,
      'round_id': roundId,
      'complete': true,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<Response> _claimInvite(Request request) async {
    final body = await _body(request);
    final code = '${body['code'] ?? ''}'.trim().toUpperCase();
    final invite = await db.one(
      'SELECT * FROM invites WHERE code = @code',
      {'code': code},
    );
    if (invite == null) return _error(404, 'Kode undangan tidak ditemukan.');
    final expires = invite['expires_at'];
    if (invite['claimed_at'] != null) {
      return _error(409, 'Kode undangan sudah dipakai.');
    }
    if (expires is DateTime && expires.isBefore(DateTime.now())) {
      return _error(410, 'Kode undangan sudah kedaluwarsa.');
    }
    final ownerId = invite['owner_id'] as String;
    final owner = await _owner(ownerId);
    if (owner == null) return _error(404, 'Owner tidak ditemukan.');
    final account = await db.one(
      'SELECT * FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
      {'owner': ownerId, 'sync': invite['account_sync_id']},
    );
    if (account == null) return _error(404, 'Akun undangan tidak ditemukan.');
    final deviceId = _id('dev');
    final token = _token();
    final storeId = invite['store_id'] as String;
    await db.tx((tx) async {
      await tx.execute(
        '''
INSERT INTO devices (id, owner_id, nama, kind, employee_account_id, public_key,
  encryption_key, owner_public_key, store_ids, token_hash)
VALUES (@id, @owner, @nama, 'employee', @account, @public, @encrypt,
  @ownerPublic, CAST(@stores AS jsonb), @hash)
''',
        {
          'id': deviceId,
          'owner': ownerId,
          'nama': '${body['nama'] ?? 'Perangkat karyawan'}',
          'account': account['sync_id'],
          'public': '${body['public_key'] ?? ''}',
          'encrypt': '${body['encryption_key'] ?? ''}',
          'ownerPublic': owner['owner_public_key'],
          'stores': jsonEncode([storeId]),
          'hash': _hash(token),
        },
      );
      await tx.execute(
        'UPDATE invites SET claimed_at = now(), claimed_device_id = @device WHERE code = @code',
        {'device': deviceId, 'code': code},
      );
    });
    return _json(200, {
      'device': {
        'id': deviceId,
        'owner_id': ownerId,
        'nama': body['nama'] ?? 'Perangkat karyawan',
        'kind': 'employee',
        'store_ids': [storeId],
      },
      'token': token,
      'store_id': storeId,
      'account': _accountJson(account),
      'permission': _permissionJson(account),
      'owner_public_key': owner['owner_public_key'],
      'license_token': await _licenseFor(owner),
    });
  }

  Map<String, Object?> _accountJson(Map<String, Object?> row) => {
        'owner_id': row['owner_id'],
        'sync_id': row['sync_id'],
        'username': row['username'],
        'nama': row['nama'],
        'role_base': row['role_base'],
        'extra_permissions': stringList(row['extra_permissions']),
        'store_ids': stringList(row['store_ids']),
        'password_hash': row['password_hash'],
        'password_salt': row['password_salt'],
        'password_iterations': (row['password_iterations'] as num?)?.toInt() ?? 600000,
        'must_change_password': row['must_change_password'] == true ? 1 : 0,
        'aktif': row['aktif'] == true ? 1 : 0,
        'permission_version': (row['permission_version'] as num?)?.toInt() ?? 1,
      };

  Map<String, Object?> _permissionJson(Map<String, Object?> row) => {
        'payload': jsonMap(row['permission_payload']) ?? const {},
        'signature': row['permission_signature'] ?? '',
        'signer_public_key': row['permission_signer_public_key'] ?? '',
      };

  String _pad64(String value) =>
      value + '=' * ((4 - value.length % 4) % 4);

  Future<String> _derivePassword(
    String password,
    String salt,
    int iterations,
  ) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations <= 0 ? 600000 : iterations,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: base64Url.decode(_pad64(salt)),
    );
    return base64Url.encode(await key.extractBytes());
  }

  Future<bool> _verifyPassword(
    String password,
    Map<String, Object?> account,
  ) async {
    final hash = account['password_hash'] as String? ?? '';
    final salt = account['password_salt'] as String? ?? '';
    if (hash.isEmpty || salt.isEmpty || password.isEmpty) return false;
    try {
      final derived = await _derivePassword(
        password,
        salt,
        (account['password_iterations'] as num?)?.toInt() ?? 600000,
      );
      return derived.replaceAll('=', '') == hash.replaceAll('=', '');
    } catch (_) {
      return false;
    }
  }

  Map<String, Object?> _publicAccountJson(Map<String, Object?> row) => {
        'owner_id': row['owner_id'],
        'sync_id': row['sync_id'],
        'username': row['username'],
        'nama': row['nama'],
        'role_base': row['role_base'],
        'extra_permissions': stringList(row['extra_permissions']),
        'store_ids': stringList(row['store_ids']),
        'aktif': row['aktif'] == true,
        'must_change_password': row['must_change_password'] == true,
        'permission_version':
            (row['permission_version'] as num?)?.toInt() ?? 1,
      };

  Future<List<Map<String, Object?>>> _ownerStores(String ownerId) async {
    final rows = await db.query(
      'SELECT DISTINCT store_id FROM store_keys WHERE owner_id = @owner ORDER BY store_id',
      {'owner': ownerId},
    );
    final ids = rows
        .map((row) => '${row['store_id'] ?? ''}')
        .where((value) => value.isNotEmpty)
        .toList();
    if (ids.isEmpty) ids.add('utama');
    return ids
        .map(
          (id) => {
            'store_id': id,
            'nama': id == 'utama' ? 'Toko Utama' : id,
          },
        )
        .toList();
  }

  Future<Response> _employeeLogin(Request request) async {
    if (!_employeeRateLimit.allow(_clientIp(request))) {
      return _error(
        429,
        'Terlalu banyak percobaan masuk. Coba lagi beberapa menit lagi.',
        code: 'rate_limited',
      );
    }
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}'.trim();
    final username = '${body['username'] ?? ''}'.trim().toLowerCase();
    final password = '${body['password'] ?? ''}';
    final device = jsonMap(body['device']);
    if (ownerId.isEmpty || username.isEmpty || password.isEmpty) {
      return _error(
        400,
        'ID owner, nama pengguna, dan password wajib diisi.',
        code: 'missing_fields',
      );
    }
    final owner = await _owner(ownerId);
    final account = owner == null
        ? null
        : await db.one(
            'SELECT * FROM accounts WHERE owner_id = @owner AND username = @username',
            {'owner': ownerId, 'username': username},
          );
    if (owner == null ||
        account == null ||
        account['aktif'] != true ||
        !await _verifyPassword(password, account)) {
      return _error(
        401,
        'ID owner, nama pengguna, atau password salah.',
        code: 'invalid_credentials',
      );
    }

    final accountSyncId = '${account['sync_id']}';
    var storeIds = stringList(account['store_ids']);
    if (storeIds.isEmpty) storeIds = const ['utama'];
    final requestedStore = '${body['store_id'] ?? ''}'.trim();
    if (requestedStore.isNotEmpty && storeIds.contains(requestedStore)) {
      storeIds = [requestedStore];
    }

    String? token;
    String? deviceId;
    if (device != null && '${device['public_key'] ?? ''}'.isNotEmpty) {
      deviceId = _id('dev');
      token = _token();
      await db.execute(
        '''
INSERT INTO devices (id, owner_id, nama, kind, employee_account_id, public_key,
  encryption_key, owner_public_key, store_ids, token_hash)
VALUES (@id, @owner, @nama, 'employee', @account, @public, @encrypt,
  @ownerPublic, CAST(@stores AS jsonb), @hash)
''',
        {
          'id': deviceId,
          'owner': ownerId,
          'nama': '${device['nama'] ?? 'Perangkat karyawan'}',
          'account': accountSyncId,
          'public': '${device['public_key']}',
          'encrypt': '${device['encryption_key'] ?? ''}',
          'ownerPublic': owner['owner_public_key'] ?? '',
          'stores': jsonEncode(storeIds),
          'hash': _hash(token),
        },
      );
    } else {
      final existing = await db.one(
        '''
SELECT * FROM devices
WHERE owner_id = @owner AND employee_account_id = @account
  AND revoked_at IS NULL
ORDER BY created_at DESC LIMIT 1
''',
        {'owner': ownerId, 'account': accountSyncId},
      );
      deviceId = existing?['id'] as String?;
      final existingStores = stringList(existing?['store_ids']);
      if (existingStores.isNotEmpty) storeIds = existingStores;
    }

    return _json(200, {
      'owner_id': ownerId,
      'owner_public_key': owner['owner_public_key'] ?? '',
      'plan': owner['license_plan'] ?? 'free',
      'period_end': _iso(owner['license_period_end']),
      'store_limit': (owner['license_store_limit'] as num?)?.toInt() ?? 1,
      'license_token': await _licenseFor(owner),
      'server_time': DateTime.now().toUtc().toIso8601String(),
      'account': _publicAccountJson(account),
      'permission': _permissionJson(account),
      'stores': await _ownerStores(ownerId),
      'device': {'id': deviceId, 'store_ids': storeIds},
      'token': token,
    });
  }

  Future<Response> _employeeChangePassword(Request request) async {
    if (!_passwordRateLimit.allow(_clientIp(request))) {
      return _error(
        429,
        'Terlalu banyak percobaan. Coba lagi beberapa menit lagi.',
        code: 'rate_limited',
      );
    }
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}'.trim();
    final username = '${body['username'] ?? ''}'.trim().toLowerCase();
    final oldPassword = '${body['old_password'] ?? ''}';
    final newPassword = '${body['new_password'] ?? ''}';
    if (ownerId.isEmpty || username.isEmpty || oldPassword.isEmpty) {
      return _error(400, 'Data akun tidak lengkap.', code: 'missing_fields');
    }
    if (newPassword.length < 8) {
      return _error(
        400,
        'Password baru minimal 8 karakter.',
        code: 'weak_password',
      );
    }
    final account = await db.one(
      'SELECT * FROM accounts WHERE owner_id = @owner AND username = @username',
      {'owner': ownerId, 'username': username},
    );
    if (account == null ||
        account['aktif'] != true ||
        !await _verifyPassword(oldPassword, account)) {
      return _error(401, 'Password lama salah.', code: 'invalid_credentials');
    }
    final saltBytes =
        List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final salt = base64Url.encode(saltBytes);
    final hash = await _derivePassword(newPassword, salt, 600000);
    await db.execute(
      '''
UPDATE accounts SET password_hash = @hash, password_salt = @salt,
  password_iterations = 600000, must_change_password = false,
  password_updated_at = now(), updated_at = now()
WHERE owner_id = @owner AND sync_id = @sync
''',
      {
        'hash': hash,
        'salt': salt,
        'owner': ownerId,
        'sync': '${account['sync_id']}',
      },
    );
    return _json(200, {'ok': true});
  }

  Future<Response> _permissionsMe(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final accountId = device['employee_account_id'] as String? ?? '';
    if (accountId.isEmpty) {
      return _json(200, {'account': const {}, 'permission': const {}});
    }
    final account = await db.one(
      'SELECT * FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
      {'owner': device['owner_id'], 'sync': accountId},
    );
    if (account == null) return _error(404, 'Akun perangkat tidak ditemukan.');
    return _json(200, {
      'account': _accountJson(account),
      'permission': _permissionJson(account),
    });
  }

  Future<Response> _manageAccounts(Request request) async {
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final rows = await db.query(
      'SELECT * FROM accounts WHERE owner_id = @owner ORDER BY username',
      {'owner': ownerId},
    );
    return _json(200, rows.map(_accountJson).toList());
  }

  Future<Response> _saveAccount(Request request) async {
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final owner = await _owner(ownerId);
    if (owner == null) return _error(404, 'Owner tidak ditemukan.');
    final syncId = '${body['sync_id'] ?? ''}';
    final username = '${body['username'] ?? ''}'.trim().toLowerCase();
    if (syncId.isEmpty || username.isEmpty) {
      return _error(400, 'sync_id dan username wajib.');
    }
    final payload = jsonMap(body['permission_payload']);
    var signature = '${body['permission_signature'] ?? ''}';
    var signer = '${body['permission_signer_public_key'] ?? ''}';
    final ownerPublic = owner['owner_public_key'] as String? ?? '';
    if (payload == null) {
      return _error(400, 'Izin akun harus membawa payload.');
    }
    if (signer.isNotEmpty && signer == ownerPublic) {
      if (signature.isEmpty) {
        return _error(400, 'Tanda tangan izin owner tidak ada.');
      }
      final valid = await license.verifyPayload(
        publicKey: ownerPublic,
        payload: canonicalJson(payload),
        signature: signature,
      );
      if (!valid) return _error(400, 'Tanda tangan izin tidak valid.');
    } else {
      // Perangkat ringkasan tidak memegang kunci privat owner. Permintaan
      // sudah lolos token owner, jadi layanan menandatangani izin dengan
      // kunci lisensi yang juga dipercaya perangkat.
      final signed = await license.signSummary(payload);
      signer = '${signed['public_key']}';
      signature = '${signed['signature']}';
    }
    final existing = await db.one(
      'SELECT password_hash, password_salt, password_iterations, must_change_password FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
      {'owner': ownerId, 'sync': syncId},
    );
    final hash = '${body['password_hash'] ?? ''}';
    final values = {
      'owner': ownerId,
      'sync': syncId,
      'username': username,
      'nama': '${body['nama'] ?? username}',
      'role': '${body['role_base'] ?? 'KASIR'}',
      'permissions': jsonEncode(body['extra_permissions'] ?? const []),
      'stores': jsonEncode(body['store_ids'] ?? const []),
      'hash': hash.isEmpty
          ? (existing?['password_hash'] as String? ?? '')
          : hash,
      'salt': '${body['password_salt'] ?? existing?['password_salt'] ?? ''}',
      'iterations': (body['password_iterations'] as num?)?.toInt() ??
          (existing?['password_iterations'] as num?)?.toInt() ??
          600000,
      'aktif': body['aktif'] != false,
      'must_change': hash.isEmpty
          ? (existing?['must_change_password'] == true)
          : true,
      'version': (body['permission_version'] as num?)?.toInt() ?? 1,
      'payload': jsonEncode(payload),
      'signature': signature,
      'signer': signer,
    };
    await db.execute(
      '''
INSERT INTO accounts (owner_id, sync_id, username, nama, role_base,
  extra_permissions, store_ids, password_hash, password_salt,
  password_iterations, aktif, must_change_password, permission_version,
  permission_payload, permission_signature, permission_signer_public_key)
VALUES (@owner, @sync, @username, @nama, @role, CAST(@permissions AS jsonb),
  CAST(@stores AS jsonb), @hash, @salt, @iterations, @aktif, @must_change,
  @version, CAST(@payload AS jsonb), @signature, @signer)
ON CONFLICT (owner_id, sync_id) DO UPDATE SET
  username = EXCLUDED.username, nama = EXCLUDED.nama,
  role_base = EXCLUDED.role_base,
  extra_permissions = EXCLUDED.extra_permissions,
  store_ids = EXCLUDED.store_ids,
  password_hash = EXCLUDED.password_hash,
  password_salt = EXCLUDED.password_salt,
  password_iterations = EXCLUDED.password_iterations,
  aktif = EXCLUDED.aktif,
  must_change_password = EXCLUDED.must_change_password,
  permission_version = EXCLUDED.permission_version,
  permission_payload = EXCLUDED.permission_payload,
  permission_signature = EXCLUDED.permission_signature,
  permission_signer_public_key = EXCLUDED.permission_signer_public_key,
  updated_at = now()
''',
      values,
    );
    final row = await db.one(
      'SELECT * FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
      {'owner': ownerId, 'sync': syncId},
    );
    return _json(200, _accountJson(row!));
  }

  Future<Response> _manageInvites(Request request) async {
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final rows = await db.query(
      '''
SELECT i.*, a.username FROM invites i
LEFT JOIN accounts a ON a.owner_id = i.owner_id AND a.sync_id = i.account_sync_id
WHERE i.owner_id = @owner ORDER BY i.created_at DESC LIMIT 50
''',
      {'owner': ownerId},
    );
    return _json(
      200,
      rows
          .map(
            (row) => {
              'code': row['code'],
              'owner_id': row['owner_id'],
              'account_sync_id': row['account_sync_id'],
              'username': row['username'],
              'store_id': row['store_id'],
              'expires_at': _iso(row['expires_at']),
              'claimed_at': _iso(row['claimed_at']),
            },
          )
          .toList(),
    );
  }

  Future<Response> _createInvite(Request request) async {
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final accountSync = '${body['account_sync_id'] ?? ''}';
    final store = '${body['store_id'] ?? 'utama'}';
    final ttl = (body['ttl_minutes'] as num?)?.toInt() ?? 10;
    final account = await db.one(
      'SELECT sync_id FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
      {'owner': ownerId, 'sync': accountSync},
    );
    if (account == null) return _error(404, 'Akun tidak ditemukan.');
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    var code = '';
    for (var attempt = 0; attempt < 10; attempt++) {
      code = List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
      final clash = await db.one('SELECT 1 AS ok FROM invites WHERE code = @code', {'code': code});
      if (clash == null) break;
      code = '';
    }
    if (code.isEmpty) return _error(500, 'Gagal membuat kode undangan.');
    final expires = DateTime.now().toUtc().add(Duration(minutes: ttl));
    await db.execute(
      'INSERT INTO invites (code, owner_id, account_sync_id, store_id, expires_at) VALUES (@code, @owner, @sync, @store, @expires)',
      {
        'code': code,
        'owner': ownerId,
        'sync': accountSync,
        'store': store,
        'expires': expires,
      },
    );
    return _json(200, {
      'code': code,
      'owner_id': ownerId,
      'account_sync_id': accountSync,
      'store_id': store,
      'expires_at': expires.toIso8601String(),
    });
  }

  Future<Response> _manageDevices(Request request) async {
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final rows = await db.query(
      '''
SELECT d.*, a.role_base, a.extra_permissions
FROM devices d
LEFT JOIN accounts a ON a.owner_id = d.owner_id
  AND a.sync_id = d.employee_account_id
WHERE d.owner_id = @owner ORDER BY d.created_at
''',
      {'owner': ownerId},
    );
    return _json(200, rows.map(_deviceJson).toList());
  }

  Future<Response> _revokeDevice(Request request, String id) async {
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final auth = await _manageAuth(request, ownerId);
    if (auth == null) return _error(401, 'Sesi perangkat tidak valid.');
    final count = await db.execute(
      'UPDATE devices SET revoked_at = now() WHERE id = @id AND owner_id = @owner AND revoked_at IS NULL',
      {'id': id, 'owner': ownerId},
    );
    if (count == 0) return _error(404, 'Perangkat tidak ditemukan.');
    await db.execute(
      'DELETE FROM store_keys WHERE owner_id = @owner AND device_id = @id',
      {'owner': ownerId, 'id': id},
    );
    return _json(200, {'ok': true});
  }

  Future<Response> _licensePublicKey(Request request) async {
    if (!_admin(request)) return _error(401, 'Admin token diperlukan.');
    return _json(200, {'license_public_key': await license.publicKey()});
  }

  Future<Response> _adminCreateOwner(Request request) async {
    if (!_admin(request)) return _error(401, 'Admin token diperlukan.');
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    if (ownerId.isEmpty) return _error(400, 'owner_id wajib.');
    final days = (body['days'] as num?)?.toInt() ?? 30;
    final stores = (body['store_limit'] as num?)?.toInt() ?? 1;
    final publicKey = '${body['owner_public_key'] ?? ''}';
    final end = DateTime.now().toUtc().add(Duration(days: days));
    await db.execute(
      '''
INSERT INTO owners (owner_id, owner_public_key, license_plan, license_period_end,
  license_store_limit)
VALUES (@id, @public, 'premium', @end, @stores)
ON CONFLICT (owner_id) DO UPDATE SET
  owner_public_key = CASE WHEN EXCLUDED.owner_public_key = '' THEN owners.owner_public_key ELSE EXCLUDED.owner_public_key END,
  license_plan = 'premium', license_period_end = EXCLUDED.license_period_end,
  license_store_limit = EXCLUDED.license_store_limit
''',
      {'id': ownerId, 'public': publicKey, 'end': end, 'stores': stores},
    );
    final owner = (await _owner(ownerId))!;
    final enroll = _token();
    await db.execute(
      'INSERT INTO enroll_tokens (token, owner_id, expires_at) VALUES (@token, @owner, @expires)',
      {
        'token': enroll,
        'owner': ownerId,
        'expires': DateTime.now().toUtc().add(const Duration(minutes: 15)),
      },
    );
    return _json(200, {
      'owner_id': ownerId,
      'enroll_token': enroll,
      'license_token': await _licenseFor(owner),
      'license_public_key': await license.publicKey(),
    });
  }

  String _clientIp(Request request) {
    final forwarded = request.headers['x-forwarded-for'] ?? '';
    final first = forwarded.split(',').first.trim();
    if (first.isNotEmpty) return first;
    final info = request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : 'unknown';
  }

  bool _looksLikeEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);

  Map<String, Object?> _identityJson(Map<String, Object?> row) => {
        'email': row['email'],
        'subject': row['subject'],
        'owner_id': row['owner_id'],
        'created_at': _iso(row['created_at']),
        'updated_at': _iso(row['updated_at']),
        'last_login_at': _iso(row['last_login_at']),
      };

  Future<Response> _googleLogin(Request request) async {
    final verifier = google;
    if (verifier == null) {
      return _error(
        503,
        'Login Google belum diaktifkan di relay ini.',
        code: 'google_login_disabled',
      );
    }
    if (!_googleRateLimit.allow(_clientIp(request))) {
      return _error(
        429,
        'Terlalu banyak percobaan masuk. Coba lagi beberapa menit lagi.',
        code: 'rate_limited',
      );
    }
    final body = await _body(request);
    final idToken = '${body['id_token'] ?? ''}'.trim();
    if (idToken.isEmpty) {
      return _error(400, 'id_token wajib diisi.', code: 'missing_token');
    }
    GoogleIdentity identity;
    try {
      identity = await verifier.verify(idToken);
    } on GoogleAuthException catch (error) {
      return _error(error.status, error.message, code: error.code);
    }
    var row = await db.one(
      'SELECT * FROM owner_identities WHERE subject = @subject',
      {'subject': identity.subject},
    );
    row ??= await db.one(
      'SELECT * FROM owner_identities WHERE email = @email',
      {'email': identity.email},
    );
    if (row == null) {
      return _error(
        403,
        'Akun Google ini belum terhubung ke langganan premium. Hubungi '
        'penjual untuk mengaitkan email Anda.',
        code: 'identity_not_linked',
      );
    }
    final boundEmail = '${row['email']}'.trim().toLowerCase();
    if (boundEmail != identity.email) {
      return _error(
        409,
        'Email akun Google berbeda dari yang terdaftar. Hubungi penjual.',
        code: 'identity_email_mismatch',
      );
    }
    final boundSubject = row['subject'] as String? ?? '';
    if (boundSubject.isEmpty) {
      await db.execute(
        'UPDATE owner_identities SET subject = @subject, updated_at = now() WHERE email = @email',
        {'subject': identity.subject, 'email': identity.email},
      );
    } else if (boundSubject != identity.subject) {
      return _error(
        409,
        'Akun Google ini sudah terhubung ke identitas lain.',
        code: 'identity_subject_mismatch',
      );
    }
    final owner = await _owner(row['owner_id'] as String);
    if (owner == null) {
      return _error(404, 'Owner tidak ditemukan.', code: 'owner_not_found');
    }
    final plan = owner['license_plan'] as String? ?? 'free';
    final end = owner['license_period_end'];
    final active = plan == 'premium' &&
        end is DateTime &&
        end.isAfter(DateTime.now().toUtc());
    if (!active) {
      return _json(402, {
        'detail': 'Langganan premium belum aktif atau sudah berakhir.',
        'code': 'license_inactive',
        'owner_id': owner['owner_id'],
        'email': identity.email,
        'plan': plan,
        'period_end': _iso(end),
      });
    }
    await db.execute(
      'UPDATE owner_identities SET last_login_at = now() WHERE email = @email',
      {'email': identity.email},
    );
    final licenseToken = await _licenseFor(owner);
    final stores = await _ownerStores(owner['owner_id'] as String);
    final summary = await license.signSummary({
      'v': 1,
      'owner_id': owner['owner_id'],
      'plan': plan,
      'period_end': _iso(end),
      'store_limit': (owner['license_store_limit'] as num?)?.toInt() ?? 1,
      'license_token': licenseToken,
      'owner_public_key': owner['owner_public_key'] ?? '',
      'stores': stores,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
    });
    final enroll = _token();
    await db.execute(
      'INSERT INTO enroll_tokens (token, owner_id, expires_at) VALUES (@token, @owner, @expires)',
      {
        'token': enroll,
        'owner': owner['owner_id'],
        'expires': DateTime.now().toUtc().add(const Duration(minutes: 15)),
      },
    );
    return _json(200, {
      'owner_id': owner['owner_id'],
      'email': identity.email,
      'enroll_token': enroll,
      'plan': plan,
      'period_end': _iso(end),
      'store_limit': (owner['license_store_limit'] as num?)?.toInt() ?? 1,
      'license_token': licenseToken,
      'license_public_key': await license.publicKey(),
      'owner_public_key': owner['owner_public_key'] ?? '',
      'stores': stores,
      'summary': summary,
    });
  }

  Future<Response> _adminIdentities(Request request) async {
    if (!_admin(request)) return _error(401, 'Admin token diperlukan.');
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final rows = await db.query(
      ownerId.isEmpty
          ? 'SELECT * FROM owner_identities ORDER BY created_at'
          : 'SELECT * FROM owner_identities WHERE owner_id = @owner ORDER BY created_at',
      {'owner': ownerId},
    );
    return _json(200, rows.map(_identityJson).toList());
  }

  Future<Response> _adminBindIdentity(Request request) async {
    if (!_admin(request)) return _error(401, 'Admin token diperlukan.');
    final body = await _body(request);
    final email = '${body['email'] ?? ''}'.trim().toLowerCase();
    final ownerId = '${body['owner_id'] ?? ''}'.trim();
    final subject = '${body['subject'] ?? ''}'.trim();
    if (!_looksLikeEmail(email)) {
      return _error(400, 'Email tidak valid.', code: 'invalid_email');
    }
    if (ownerId.isEmpty) {
      return _error(400, 'owner_id wajib.', code: 'missing_owner');
    }
    final owner = await _owner(ownerId);
    if (owner == null) {
      return _error(
        404,
        'Owner belum terdaftar. Buat owner terlebih dahulu.',
        code: 'owner_not_found',
      );
    }
    if (subject.isNotEmpty) {
      final clash = await db.one(
        'SELECT email FROM owner_identities WHERE subject = @subject',
        {'subject': subject},
      );
      if (clash != null && '${clash['email']}' != email) {
        return _error(
          409,
          'Identitas Google itu sudah terhubung ke email lain.',
          code: 'subject_taken',
        );
      }
    }
    await db.execute(
      '''
INSERT INTO owner_identities (email, subject, owner_id)
VALUES (@email, @subject, @owner)
ON CONFLICT (email) DO UPDATE SET
  owner_id = EXCLUDED.owner_id,
  subject = CASE WHEN EXCLUDED.subject IS NULL THEN owner_identities.subject
                 ELSE EXCLUDED.subject END,
  updated_at = now()
''',
      {
        'email': email,
        'subject': subject.isEmpty ? null : subject,
        'owner': ownerId,
      },
    );
    final row = await db.one(
      'SELECT * FROM owner_identities WHERE email = @email',
      {'email': email},
    );
    return _json(200, _identityJson(row!));
  }
}

class _EnvelopeRejection implements Exception {
  _EnvelopeRejection(this.status, this.detail, {this.code = ''});

  final int status;
  final String detail;
  final String code;
}

class _BusyRejection implements Exception {
  _BusyRejection(this.seconds);

  final int seconds;
}
