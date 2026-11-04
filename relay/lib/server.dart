import 'dart:convert';
import 'dart:io' show HttpConnectionInfo;
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'canonical.dart';
import 'config.dart';
import 'db.dart';
import 'google.dart';
import 'license.dart';

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
  final Router _router;

  Handler get handler {
    _router.get('/relay/health', _health);
    _router.post('/relay/devices', _enroll);
    _router.post('/relay/keys', _putKeyWrap);
    _router.post('/relay/envelopes', _submitEnvelope);
    _router.get('/relay/feed', _feed);
    _router.post('/relay/feed/ack', _ack);
    _router.get('/relay/devices', _devices);
    _router.get('/relay/bootstrap', _bootstrap);
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
    return const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_errors)
        .addHandler(_router.call);
  }

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
       o.license_plan, o.license_period_end, o.license_device_limit
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
       o.license_device_limit
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

  Future<int> _activeDevices(String ownerId) async {
    final row = await db.one(
      'SELECT COUNT(*) AS total FROM devices WHERE owner_id = @owner AND revoked_at IS NULL',
      {'owner': ownerId},
    );
    return (row?['total'] as num?)?.toInt() ?? 0;
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
      deviceLimit: (owner['license_device_limit'] as num?)?.toInt() ?? 5,
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
    final limit = (owner['license_device_limit'] as num?)?.toInt() ?? 5;
    if (await _activeDevices(ownerId) >= limit) {
      return _error(409, 'Batas $limit perangkat aktif sudah terpakai.');
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
    final sender = '${body['sender_device_id'] ?? ''}';
    if (sender.isEmpty || sender != device['id']) {
      return _error(403, 'Pengirim amplop bukan perangkat ini.');
    }
    final store = '${body['store_id'] ?? ''}';
    final stores = stringList(device['store_ids']);
    if (!stores.contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
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
    if (store.isEmpty ||
        fields['idempotency_key'] == '' ||
        fields['ciphertext'] == '' ||
        fields['nonce'] == '' ||
        (fields['seq'] as int) <= 0 ||
        signature.isEmpty) {
      return _error(400, 'Amplop tidak lengkap.');
    }
    final valid = await license.verifyPayload(
      publicKey: device['public_key'] as String,
      payload: canonicalJson(fields),
      signature: signature,
    );
    if (!valid) return _error(400, 'Tanda tangan amplop tidak valid.');

    final existing = await db.one(
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
      return _json(200, {
        'id': existing['id'],
        'relay_seq': existing['relay_seq'],
        'duplicate': true,
      });
    }
    final id = _id('env');
    await db.execute(
      '''
INSERT INTO envelopes (id, owner_id, store_id, sender_device_id,
  recipient_device_id, seq, hlc_wall, hlc_counter, idempotency_key,
  ciphertext, nonce, signature)
VALUES (@id, @owner, @store, @sender, @recipient, @seq, @wall, @counter, @key,
  @ciphertext, @nonce, @signature)
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
      },
    );
    final saved = await db.one(
      'SELECT id, relay_seq FROM envelopes WHERE idempotency_key = @key',
      {'key': fields['idempotency_key']},
    );
    return _json(200, saved ?? {'id': id});
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
SELECT id, owner_id, nama, kind, public_key, encryption_key, store_ids,
       created_at, revoked_at
FROM devices WHERE owner_id = @owner ORDER BY created_at
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
        'public_key': row['public_key'],
        'encryption_key': row['encryption_key'],
        'store_ids': stringList(row['store_ids']),
        'created_at': _iso(row['created_at']),
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
      };

  Future<Response> _createSnapshot(Request request) async {
    final device = await _deviceAuth(request);
    if (device == null) return _error(401, 'Token perangkat tidak valid.');
    final body = await _body(request);
    final store = '${body['store_id'] ?? ''}';
    if (!stringList(device['store_ids']).contains(store)) {
      return _error(403, 'Perangkat tidak terdaftar pada toko $store.');
    }
    final id = _id('snap');
    await db.execute(
      '''
INSERT INTO snapshots (owner_id, store_id, id, device_id, store_seq, ciphertext,
  nonce, signature, checksum, hlc_wall, hlc_counter)
VALUES (@owner, @store, @id, @device, @seq, @ciphertext, @nonce, @signature,
  @checksum, @wall, @counter)
ON CONFLICT (owner_id, store_id) DO UPDATE SET
  id = EXCLUDED.id, device_id = EXCLUDED.device_id, store_seq = EXCLUDED.store_seq,
  ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce,
  signature = EXCLUDED.signature, checksum = EXCLUDED.checksum,
  hlc_wall = EXCLUDED.hlc_wall, hlc_counter = EXCLUDED.hlc_counter,
  created_at = now()
''',
      {
        'owner': device['owner_id'],
        'store': store,
        'id': id,
        'device': device['id'],
        'seq': (body['store_seq'] as num?)?.toInt() ?? 0,
        'ciphertext': '${body['ciphertext'] ?? ''}',
        'nonce': '${body['nonce'] ?? ''}',
        'signature': '${body['signature'] ?? ''}',
        'checksum': '${body['checksum'] ?? ''}',
        'wall': (body['hlc_wall'] as num?)?.toInt() ?? 0,
        'counter': (body['hlc_counter'] as num?)?.toInt() ?? 0,
      },
    );
    return _json(200, {
      'id': id,
      'store_id': store,
      'device_id': device['id'],
      'store_seq': (body['store_seq'] as num?)?.toInt() ?? 0,
      'checksum': body['checksum'],
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
    final limit = (owner['license_device_limit'] as num?)?.toInt() ?? 5;
    if (await _activeDevices(ownerId) >= limit) {
      return _error(409, 'Batas $limit perangkat aktif sudah terpakai.');
    }
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
        'must_change_password': 1,
        'aktif': row['aktif'] == true ? 1 : 0,
        'permission_version': (row['permission_version'] as num?)?.toInt() ?? 1,
      };

  Map<String, Object?> _permissionJson(Map<String, Object?> row) => {
        'payload': jsonMap(row['permission_payload']) ?? const {},
        'signature': row['permission_signature'] ?? '',
        'signer_public_key': row['permission_signer_public_key'] ?? '',
      };

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
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
    final rows = await db.query(
      'SELECT * FROM accounts WHERE owner_id = @owner ORDER BY username',
      {'owner': ownerId},
    );
    return _json(200, rows.map(_accountJson).toList());
  }

  Future<Response> _saveAccount(Request request) async {
    final body = await _body(request);
    final ownerId = '${body['owner_id'] ?? ''}';
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
    final owner = await _owner(ownerId);
    if (owner == null) return _error(404, 'Owner tidak ditemukan.');
    final syncId = '${body['sync_id'] ?? ''}';
    final username = '${body['username'] ?? ''}'.trim().toLowerCase();
    if (syncId.isEmpty || username.isEmpty) {
      return _error(400, 'sync_id dan username wajib.');
    }
    final payload = jsonMap(body['permission_payload']);
    final signature = '${body['permission_signature'] ?? ''}';
    final signer = '${body['permission_signer_public_key'] ?? ''}';
    final ownerPublic = owner['owner_public_key'] as String? ?? '';
    if (payload == null || signature.isEmpty) {
      return _error(400, 'Izin akun harus membawa payload dan tanda tangan.');
    }
    if (signer.isEmpty || signer != ownerPublic) {
      return _error(
        409,
        'Penandatangan izin bukan kunci owner yang terdaftar. '
        'Owner app harus menandatangani dengan kunci identitas owner.',
        code: 'owner_signer_required',
      );
    }
    final valid = await license.verifyPayload(
      publicKey: ownerPublic,
      payload: canonicalJson(payload),
      signature: signature,
    );
    if (!valid) return _error(400, 'Tanda tangan izin tidak valid.');
    final existing = await db.one(
      'SELECT password_hash, password_salt, password_iterations FROM accounts WHERE owner_id = @owner AND sync_id = @sync',
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
      'version': (body['permission_version'] as num?)?.toInt() ?? 1,
      'payload': jsonEncode(payload),
      'signature': signature,
      'signer': signer,
    };
    await db.execute(
      '''
INSERT INTO accounts (owner_id, sync_id, username, nama, role_base,
  extra_permissions, store_ids, password_hash, password_salt,
  password_iterations, aktif, permission_version, permission_payload,
  permission_signature, permission_signer_public_key)
VALUES (@owner, @sync, @username, @nama, @role, CAST(@permissions AS jsonb),
  CAST(@stores AS jsonb), @hash, @salt, @iterations, @aktif, @version,
  CAST(@payload AS jsonb), @signature, @signer)
ON CONFLICT (owner_id, sync_id) DO UPDATE SET
  username = EXCLUDED.username, nama = EXCLUDED.nama,
  role_base = EXCLUDED.role_base,
  extra_permissions = EXCLUDED.extra_permissions,
  store_ids = EXCLUDED.store_ids,
  password_hash = EXCLUDED.password_hash,
  password_salt = EXCLUDED.password_salt,
  password_iterations = EXCLUDED.password_iterations,
  aktif = EXCLUDED.aktif, permission_version = EXCLUDED.permission_version,
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
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
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
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
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
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
    final rows = await db.query(
      'SELECT * FROM devices WHERE owner_id = @owner ORDER BY created_at',
      {'owner': ownerId},
    );
    return _json(200, rows.map(_deviceJson).toList());
  }

  Future<Response> _revokeDevice(Request request, String id) async {
    final ownerId = request.url.queryParameters['owner_id'] ?? '';
    final auth = await _ownerAuth(request, ownerId);
    if (auth == null) return _error(401, 'Token owner tidak valid.');
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
    final devices = (body['device_limit'] as num?)?.toInt() ?? 5;
    final publicKey = '${body['owner_public_key'] ?? ''}';
    final end = DateTime.now().toUtc().add(Duration(days: days));
    await db.execute(
      '''
INSERT INTO owners (owner_id, owner_public_key, license_plan, license_period_end,
  license_device_limit)
VALUES (@id, @public, 'premium', @end, @devices)
ON CONFLICT (owner_id) DO UPDATE SET
  owner_public_key = CASE WHEN EXCLUDED.owner_public_key = '' THEN owners.owner_public_key ELSE EXCLUDED.owner_public_key END,
  license_plan = 'premium', license_period_end = EXCLUDED.license_period_end,
  license_device_limit = EXCLUDED.license_device_limit
''',
      {'id': ownerId, 'public': publicKey, 'end': end, 'devices': devices},
    );
    final owner = (await _owner(ownerId))!;
    final enroll = _token();
    await db.execute(
      'INSERT INTO enroll_tokens (token, owner_id, expires_at) VALUES (@token, @owner, @expires)',
      {
        'token': enroll,
        'owner': ownerId,
        'expires': DateTime.now().toUtc().add(const Duration(days: 365)),
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
    return _json(200, {
      'owner_id': owner['owner_id'],
      'email': identity.email,
      'plan': plan,
      'period_end': _iso(end),
      'device_limit': (owner['license_device_limit'] as num?)?.toInt() ?? 5,
      'license_token': await _licenseFor(owner),
      'license_public_key': await license.publicKey(),
      'owner_public_key': owner['owner_public_key'] ?? '',
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
