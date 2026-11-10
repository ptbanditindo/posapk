import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const _base = String.fromEnvironment('RELAY_URL', defaultValue: 'http://127.0.0.1:8787');
const _adminToken = String.fromEnvironment('RELAY_ADMIN_TOKEN');
const _origin = String.fromEnvironment('RELAY_TEST_ORIGIN');

final _run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
final _ownerId = 'e2e_owner_$_run';
final _results = <({String name, bool ok, String detail})>[];
final _log = <Map<String, Object?>>[];

String _canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

class Signer {
  Signer(this.pair, this.pub);
  final KeyPair pair;
  final String pub;

  static Future<Signer> create() async {
    final pair = await Ed25519().newKeyPair();
    final public = await pair.extractPublicKey();
    return Signer(pair, base64Url.encode(public.bytes));
  }

  Future<String> sign(String text) async {
    final signature = await Ed25519().sign(utf8.encode(text), keyPair: pair);
    return base64Url.encode(signature.bytes);
  }
}

String _randomKey() =>
    base64Url.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));

Future<String> _passwordHash(String password, String salt) async {
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: base64Url.decode(salt),
  );
  return base64Url.encode(await key.extractBytes());
}

class Resp {
  Resp(this.status, this.body, this.text, this.headers);
  final int status;
  final Map<String, Object?>? body;
  final String text;
  final Map<String, String> headers;

  String get code => '${body?['code'] ?? body?['detail'] ?? ''}';
}

Future<Resp> _request(
  String method,
  String path, {
  String? token,
  bool admin = false,
  String? enrollment,
  Object? body,
  String? raw,
  String? origin,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse('$_base$path'));
    if (token != null) request.headers.set('x-device-token', token);
    if (origin != null) request.headers.set('origin', origin);
    if (admin) request.headers.set('authorization', 'Bearer $_adminToken');
    if (enrollment != null) request.headers.set('x-relay-enroll-token', enrollment);
    if (raw != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(raw));
    } else if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final started = DateTime.now();
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    Map<String, Object?>? json;
    try {
      final decoded = text.isEmpty ? null : jsonDecode(text);
      if (decoded is Map<String, Object?>) json = decoded;
    } catch (_) {}
    final headerMap = <String, String>{};
    response.headers.forEach((name, values) => headerMap[name] = values.join(','));
    _log.add({
      'method': method,
      'path': path,
      'status': response.statusCode,
      'ms': DateTime.now().difference(started).inMilliseconds,
      'body': json ?? text.substring(0, min(300, text.length)),
    });
    return Resp(response.statusCode, json, text, headerMap);
  } finally {
    client.close(force: true);
  }
}

void _check(String name, bool ok, [String detail = '']) {
  _results.add((name: name, ok: ok, detail: detail));
  print('${ok ? 'PASS' : 'FAIL'} | $name${detail.isEmpty ? '' : ' | $detail'}');
}

void _expect(String name, int got, int want, [String extra = '']) =>
    _check(name, got == want, 'expected $want, got $got${extra.isEmpty ? '' : ' | $extra'}');

Future<void> main() async {
  final owner = await Signer.create();
  final dev1 = await Signer.create();
  final dev2 = await Signer.create();
  final empDev = await Signer.create();

  print('Relay E2E run $_run -> $_base');

  // 1. Health.
  var r = await _request('GET', '/relay/health');
  _expect('health 200', r.status, 200);
  _check(
    'health melaporkan kunci lisensi',
    (r.body?['license_public_key'] as String? ?? '').length > 20,
  );
  _check('health melaporkan google_login=false', r.body?['google_login'] == false);

  // 2. Admin auth.
  r = await _request('GET', '/relay/admin/license-public-key');
  _expect('endpoint admin menolak tanpa token', r.status, 401);
  r = await _request('GET', '/relay/admin/license-public-key', admin: true);
  _expect('endpoint admin menerima bearer token', r.status, 200);

  // 3. Create owner.
  r = await _request('POST', '/relay/admin/owners', admin: true, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'days': 30,
    'store_limit': 2,
  });
  _expect('admin membuat owner 200', r.status, 200);
  final enrollToken = r.body?['enroll_token'] as String?;
  _check('owner baru menerima enroll_token', (enrollToken ?? '').length > 20);

  // 4. Enrollment.
  r = await _request('POST', '/relay/devices', enrollment: 'invalid-token', body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'public_key': dev1.pub,
    'encryption_key': _randomKey(),
    'kind': 'owner',
    'store_ids': ['utama'],
  });
  _expect('enroll menolak token tidak valid', r.status, 401);

  r = await _request('POST', '/relay/devices', enrollment: enrollToken, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'nama': 'PC Owner',
    'public_key': dev1.pub,
    'encryption_key': _randomKey(),
    'kind': 'owner',
    'store_ids': ['utama', 'cabang', 'ketiga'],
  });
  _expect('enroll menegakkan store_limit', r.status, 403, r.code);

  r = await _request('POST', '/relay/devices', enrollment: enrollToken, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'nama': 'PC Owner',
    'public_key': dev1.pub,
    'encryption_key': _randomKey(),
    'kind': 'owner',
    'store_ids': ['utama', 'cabang'],
  });
  _expect('enroll perangkat owner 200', r.status, 200, r.code);
  final dev1Token = r.body?['token'] as String?;
  final dev1Id = (r.body?['device'] as Map?)?['id'] as String?;
  _check('enroll mengembalikan token dan id perangkat', dev1Token != null && dev1Id != null);
  _check(
    'enroll mengembalikan license_token',
    (r.body?['license_token'] as String? ?? '').contains('.'),
  );

  r = await _request('POST', '/relay/devices', enrollment: enrollToken, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'public_key': dev1.pub,
    'kind': 'owner',
    'store_ids': ['utama'],
  });
  _expect('enroll_token hanya sekali pakai', r.status, 401);

  r = await _request('POST', '/relay/devices', enrollment: 'x', body: {
    'owner_id': _ownerId,
    'owner_public_key': 'wrong-key',
    'public_key': dev1.pub,
    'kind': 'owner',
    'store_ids': ['utama'],
  });
  _expect('enroll menolak kunci owner berbeda', r.status, 401);

  r = await _request('GET', '/relay/devices', token: dev1Token);
  _expect('daftar perangkat 200', r.status, 200);
  final deviceRows = r.body?['rows'];
  _check(
    'daftar perangkat berisi perangkat baru',
    (r.text.contains(dev1Id ?? '~')),
    deviceRows == null ? '' : '$deviceRows',
  );

  // 5. Pairing.
  r = await _request('POST', '/relay/pairing', token: dev1Token, body: {
    'owner_id': _ownerId,
    'ttl_minutes': 15,
  });
  _expect('membuat kode pairing 200', r.status, 200, r.code);
  final pairingCode = r.body?['code'] as String?;
  r = await _request('POST', '/relay/devices', enrollment: pairingCode, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'nama': 'Laptop Kedua',
    'public_key': dev2.pub,
    'encryption_key': _randomKey(),
    'kind': 'owner',
    'store_ids': ['utama', 'cabang'],
  });
  _expect('pairing mendaftarkan perangkat kedua 200', r.status, 200, r.code);
  final dev2Token = r.body?['token'] as String?;
  final dev2Id = (r.body?['device'] as Map?)?['id'] as String?;
  r = await _request('POST', '/relay/devices', enrollment: pairingCode, body: {
    'owner_id': _ownerId,
    'owner_public_key': owner.pub,
    'public_key': dev1.pub,
    'kind': 'owner',
    'store_ids': ['utama'],
  });
  _expect('kode pairing hanya sekali pakai', r.status, 401);

  // 6. Key-wrap.
  const wrappedKey = '{"v":1,"epk":"ephemeral","nonce":"n","ct":"c"}';
  var signature = await owner.sign(_canonical({
    'store_id': 'utama',
    'device_id': dev2Id,
    'wrapped_key': wrappedKey,
  }));
  r = await _request('POST', '/relay/keys', token: dev1Token, body: {
    'store_id': 'utama',
    'device_id': dev2Id,
    'wrapped_key': wrappedKey,
    'signature': signature,
  });
  _expect('key-wrap bertanda tangan owner diterima', r.status, 200, r.code);
  r = await _request('POST', '/relay/keys', token: dev1Token, body: {
    'store_id': 'utama',
    'device_id': dev2Id,
    'wrapped_key': wrappedKey,
    'signature': await owner.sign('tampered'),
  });
  _expect('key-wrap dengan tanda tangan salah ditolak', r.status, 400);
  signature = await owner.sign(_canonical({
    'store_id': 'cabang',
    'device_id': dev2Id,
    'wrapped_key': wrappedKey,
  }));
  r = await _request('POST', '/relay/keys', token: dev1Token, body: {
    'store_id': 'cabang',
    'device_id': dev2Id,
    'wrapped_key': wrappedKey,
    'signature': signature,
  });
  _expect('key-wrap toko kedua diterima', r.status, 200, r.code);

  // 7. Envelope.
  Future<Map<String, Object?>> envelope(
    Signer device,
    String deviceId, {
    int seq = 1,
    String idem = 'idem-1',
    String entity = 'nota',
    String action = 'create',
    String entityId = 'nota-1',
    Signer? signer,
    String store = 'utama',
    bool withHints = true,
  }) async {
    final fields = <String, Object?>{
      'v': 1,
      'store_id': store,
      'sender_device_id': deviceId,
      'recipient_device_id': '',
      'seq': seq,
      'hlc_wall': DateTime.now().millisecondsSinceEpoch,
      'hlc_counter': 0,
      'idempotency_key': idem,
      'ciphertext': 'cipher-$idem',
      'nonce': 'nonce-123',
      'key_id': 'keyid-1',
      'entity': entity,
      'action': action,
      'entity_id': entityId,
    };
    final hintFields = <String, Object?>{
      'store_id': store,
      'sender_device_id': deviceId,
      'entity': entity,
      'action': action,
      'entity_id': entityId,
      'idempotency_key': idem,
    };
    return {
      ...fields,
      'signature': await (signer ?? device).sign(_canonical(fields)),
      if (withHints) 'hints_signature': await device.sign(_canonical(hintFields)),
    };
  }

  var env1 = await envelope(dev1, dev1Id!);
  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: env1);
  _expect('amplop bertanda tangan diterima 200', r.status, 200, r.code);
  final env1RelaySeq = r.body?['relay_seq'];
  _check('amplop mendapat relay_seq', env1RelaySeq is int && env1RelaySeq > 0);

  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: env1);
  _expect('kirim ulang amplop idempoten', r.status, 200);
  _check('kirim ulang ditandai duplicate', r.body?['duplicate'] == true);

  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: {
    ...env1,
    'signature': 'tampered',
  });
  _expect('tanda tangan amplop salah ditolak', r.status, 400);

  final noHints = await envelope(dev1, dev1Id, seq: 2, idem: 'idem-nohints', withHints: false);
  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: noHints);
  _expect('hints_signature wajib', r.status, 400, r.code);

  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: {
    ...await envelope(dev1, dev1Id, seq: 3, idem: 'idem-badsender', signer: dev2),
  });
  _expect('amplop ditandatangani perangkat lain ditolak', r.status, 400);

  r = await _request('POST', '/relay/envelopes', token: dev1Token, body: {
    ...await envelope(dev1, dev1Id, seq: 4, idem: 'idem-seq'),
    'seq': 0,
  });
  _expect('seq 0 ditolak', r.status, 400);

  r = await _request(
    'POST',
    '/relay/envelopes',
    token: dev1Token,
    body: await envelope(dev1, dev1Id, seq: 5, idem: 'idem-cabang', store: 'cabang'),
  );
  _expect('amplop ke toko kedua diterima', r.status, 200, r.code);

  // 8. Feed/ack.
  r = await _request('GET', '/relay/feed?store_id=utama&since_seq=0', token: dev2Token);
  _expect('feed 200', r.status, 200, r.code);
  final envelopes = (r.body?['envelopes'] as List?) ?? const [];
  _check(
    'perangkat 2 melihat amplop perangkat 1',
    envelopes.any((item) => item is Map && item['idempotency_key'] == 'idem-1'),
  );
  _check(
    'feed pemilik baru melaporkan pruned_through=0',
    r.body?['pruned_through'] == 0,
    '${r.body?['pruned_through']}',
  );
  r = await _request('GET', '/relay/feed?store_id=lain&since_seq=0', token: dev2Token);
  _expect('feed menolak toko tidak terdaftar', r.status, 403);

  r = await _request('POST', '/relay/feed/ack', token: dev2Token, body: {
    'store_id': 'utama',
    'last_seq': env1RelaySeq,
  });
  _expect('ack perangkat 2 200', r.status, 200);
  r = await _request('POST', '/relay/feed/ack', token: dev1Token, body: {
    'store_id': 'utama',
    'last_seq': env1RelaySeq,
  });
  _expect('ack perangkat 1 200', r.status, 200);

  // 8b. Retensi: amplop yang diakui semua perangkat dipangkas dan relay
  // mencatat batasnya untuk membedakan pemangkasan nyata dari nomor global.
  r = await _request(
    'POST',
    '/relay/envelopes',
    token: dev1Token,
    body: await envelope(
      dev1,
      dev1Id,
      seq: 6,
      idem: 'idem-prune',
      entityId: 'nota-prune',
    ),
  );
  _expect('amplop pemicu retensi 200', r.status, 200, r.code);
  r = await _request('GET', '/relay/feed?store_id=utama&since_seq=0', token: dev2Token);
  _expect('feed setelah retensi 200', r.status, 200, r.code);
  final prunedThrough = (r.body?['pruned_through'] as num?)?.toInt() ?? 0;
  final latestAfterPrune = (r.body?['latest_seq'] as num?)?.toInt() ?? 0;
  _check('retensi mencatat pruned_through', prunedThrough > 0, '$prunedThrough');
  _check(
    'pruned_through tidak melewati amplop terakhir',
    prunedThrough <= latestAfterPrune,
    'pruned=$prunedThrough latest=$latestAfterPrune',
  );

  // 9. Sync round + snapshot.
  r = await _request('POST', '/relay/sync/rounds', token: dev1Token, body: {'store_id': 'utama'});
  _expect('membuat putaran sinkron 200', r.status, 200, r.code);
  final round = (r.body?['round'] as Map?) ?? r.body ?? const {};
  final roundId = round['id'] as String?;
  final roundDevices = (round['devices'] as List?) ?? const [];
  _check(
    'putaran sinkron memuat dua perangkat owner',
    roundDevices.where((item) => item is Map && item['kind'] == 'owner').length == 2,
    '$roundDevices',
  );
  final latestSeq = (round['latest_seq'] as num?)?.toInt() ?? 0;
  r = await _request('POST', '/relay/sync/rounds/$roundId/ack', token: dev2Token, body: {
    'store_id': 'utama',
    'last_seq': latestSeq,
    'pending_count': 0,
  });
  _expect('perangkat 2 mengakui putaran', r.status, 200);
  r = await _request('POST', '/relay/sync/rounds/$roundId/ack', token: dev1Token, body: {
    'store_id': 'utama',
    'last_seq': latestSeq,
    'pending_count': 0,
  });
  _expect('perangkat 1 mengakui putaran', r.status, 200);
  final roundAfter = (r.body?['round'] as Map?) ?? r.body ?? const {};
  _check('putaran menjadi complete', roundAfter['complete'] == true, '$roundAfter');

  const checksum = 'sha256-checksum-demo';
  final snapWall = DateTime.now().millisecondsSinceEpoch;
  final snapSignature = await dev1.sign(_canonical({
    'store_id': 'utama',
    'device_id': dev1Id,
    'checksum': checksum,
    'store_seq': latestSeq,
    'hlc_wall': snapWall,
    'hlc_counter': 0,
  }));
  r = await _request('POST', '/relay/snapshots', token: dev1Token, body: {
    'store_id': 'utama',
    'round_id': roundId,
    'store_seq': latestSeq,
    'checksum': checksum,
    'signature': snapSignature,
    'ciphertext': 'snapshot-cipher',
    'nonce': 'snap-nonce',
    'hlc_wall': snapWall,
    'hlc_counter': 0,
  });
  _expect('unggah snapshot setelah putaran complete 200', r.status, 200, r.code);
  r = await _request('POST', '/relay/snapshots', token: dev1Token, body: {
    'store_id': 'utama',
    'store_seq': latestSeq,
    'checksum': checksum,
    'signature': snapSignature,
    'ciphertext': 'snapshot-cipher',
    'nonce': 'snap-nonce',
    'hlc_wall': snapWall,
    'hlc_counter': 0,
  });
  _expect('snapshot tanpa putaran ditolak', r.status, 409, r.code);
  r = await _request('POST', '/relay/snapshots', token: dev1Token, body: {
    'store_id': 'utama',
    'round_id': roundId,
    'store_seq': latestSeq,
    'checksum': checksum,
    'signature': 'bad',
    'ciphertext': 'snapshot-cipher',
    'nonce': 'snap-nonce',
    'hlc_wall': snapWall,
    'hlc_counter': 0,
  });
  _expect('snapshot dengan tanda tangan salah ditolak', r.status, 400);

  // 9b. Unggah ulang snapshot harus memperbarui data yang tersimpan.
  const checksum2 = 'sha256-checksum-demo-2';
  final snapWall2 = snapWall + 1000;
  final snapSignature2 = await dev1.sign(_canonical({
    'store_id': 'utama',
    'device_id': dev1Id,
    'checksum': checksum2,
    'store_seq': latestSeq,
    'hlc_wall': snapWall2,
    'hlc_counter': 0,
  }));
  r = await _request('POST', '/relay/snapshots', token: dev1Token, body: {
    'store_id': 'utama',
    'round_id': roundId,
    'store_seq': latestSeq,
    'checksum': checksum2,
    'signature': snapSignature2,
    'ciphertext': 'snapshot-cipher-2',
    'nonce': 'snap-nonce-2',
    'hlc_wall': snapWall2,
    'hlc_counter': 0,
  });
  _expect('unggah ulang snapshot 200', r.status, 200, r.code);
  r = await _request(
    'GET',
    '/relay/bootstrap?store_id=utama',
    token: dev1Token,
  );
  final refreshed = (r.body?['snapshot'] as Map?) ?? const {};
  _check(
    'snapshot diperbarui ke unggahan terbaru',
    refreshed['checksum'] == checksum2 && refreshed['ciphertext'] == 'snapshot-cipher-2',
    '$refreshed',
  );

  // 10. Employee management.
  final accountSync = 'acc_e2e_$_run';
  final accountPayload = <String, Object?>{
    'owner_id': _ownerId,
    'account_sync_id': accountSync,
    'username': 'budi',
    'nama': 'Budi E2E',
    'role_base': 'KASIR',
    'extra_permissions': ['lihat_laporan'],
    'store_ids': ['utama'],
    'permission_version': 1,
  };
  final salt = _randomKey();
  final passwordHash = await _passwordHash('budi123456', salt);
  r = await _request('POST', '/relay/manage/accounts', token: dev1Token, body: {
    'owner_id': _ownerId,
    'sync_id': accountSync,
    'username': 'budi',
    'permission_payload': accountPayload,
    'permission_signature': await owner.sign(_canonical(accountPayload)),
    'permission_signer_public_key': owner.pub,
    'password_hash': passwordHash,
    'password_salt': salt,
    'password_iterations': 120000,
  });
  _expect('owner membuat akun bertanda tangan 200', r.status, 200, r.code);
  r = await _request('POST', '/relay/manage/accounts', token: dev1Token, body: {
    'owner_id': _ownerId,
    'sync_id': accountSync,
    'username': 'budi',
    'permission_payload': accountPayload,
    'permission_signature': await dev1.sign(_canonical(accountPayload)),
    'permission_signer_public_key': owner.pub,
    'password_hash': passwordHash,
    'password_salt': salt,
    'password_iterations': 120000,
  });
  _expect('akun dengan tanda tangan bukan owner ditolak', r.status, 400, r.code);

  r = await _request('POST', '/relay/manage/invites', token: dev1Token, body: {
    'owner_id': _ownerId,
    'account_sync_id': accountSync,
    'store_id': 'utama',
    'ttl_minutes': 10,
  });
  _expect('membuat undangan 200', r.status, 200, r.code);
  final inviteCode = r.body?['code'] as String?;
  r = await _request('POST', '/relay/invites/claim', body: {
    'code': inviteCode,
    'public_key': empDev.pub,
    'encryption_key': _randomKey(),
    'nama': 'HP Budi',
  });
  _expect('klaim undangan 200', r.status, 200, r.code);
  _check('klaim mengembalikan kunci owner', r.body?['owner_public_key'] == owner.pub);
  r = await _request('POST', '/relay/invites/claim', body: {
    'code': inviteCode,
    'public_key': empDev.pub,
    'encryption_key': _randomKey(),
  });
  _expect('undangan hanya sekali pakai', r.status, 409);

  r = await _request('POST', '/relay/auth/employee', body: {
    'owner_id': _ownerId,
    'username': 'budi',
    'password': 'budi123456',
    'device': {
      'public_key': empDev.pub,
      'encryption_key': _randomKey(),
      'nama': 'HP Budi',
    },
  });
  _expect('login karyawan 200', r.status, 200, r.code);
  final empToken = r.body?['token'] as String?;
  final empId = (r.body?['device'] as Map?)?['id'] as String?;
  _check('login karyawan mengembalikan role KASIR', (r.body?['account'] as Map?)?['role_base'] == 'KASIR');
  _check('login karyawan mengembalikan token perangkat', empToken != null && empId != null);
  r = await _request('POST', '/relay/auth/employee', body: {
    'owner_id': _ownerId,
    'username': 'budi',
    'password': 'salah-password',
  });
  _expect('login karyawan password salah 401', r.status, 401);

  r = await _request('GET', '/relay/permissions/me', token: empToken);
  _expect('permissions/me 200', r.status, 200);
  _check('permissions/me mengembalikan akun', (r.body?['account'] as Map?)?['username'] == 'budi');

  r = await _request('POST', '/relay/envelopes', token: empToken, body: {
    ...await envelope(empDev, empId!, seq: 1, idem: 'emp-idem-1', entity: 'nota'),
  });
  _expect('karyawan KASIR boleh membuat nota', r.status, 200, r.code);
  r = await _request('POST', '/relay/envelopes', token: empToken, body: {
    ...await envelope(empDev, empId, seq: 2, idem: 'emp-idem-2', entity: 'harga_jasa', action: 'update'),
  });
  _expect('karyawan tidak boleh mengubah harga jasa', r.status, 403, r.code);
  r = await _request('POST', '/relay/envelopes', token: empToken, body: {
    ...await envelope(empDev, empId, seq: 3, idem: 'emp-idem-3', entity: 'stock_movement'),
  });
  _expect('karyawan KASIR boleh memindah stok', r.status, 200, r.code);

  // 11. Revocation.
  r = await _request('POST', '/relay/manage/devices/$dev2Id/revoke?owner_id=$_ownerId', token: dev1Token);
  _expect('cabut perangkat 200', r.status, 200);
  r = await _request('GET', '/relay/feed?store_id=utama&since_seq=0', token: dev2Token);
  _expect('token perangkat dicabut ditolak', r.status, 403, r.code);
  _check('alasan perangkat dicabut', r.code == 'device_revoked', r.code);
  r = await _request('POST', '/relay/manage/devices/$dev2Id/revoke?owner_id=$_ownerId', token: dev1Token);
  _expect('cabut perangkat tidak ada 404', r.status, 404);
  r = await _request('POST', '/relay/manage/devices/$dev1Id/revoke?owner_id=$_ownerId', token: empToken);
  _expect('karyawan tidak boleh mencabut perangkat', r.status, 401);

  // 12. Google login flag.
  r = await _request('POST', '/relay/auth/google', body: {'id_token': 'dummy'});
  _expect('login Google nonaktif 503', r.status, 503, r.code);

  // 13. Follow-up quota.
  Resp? last;
  for (var i = 0; i < 21; i++) {
    last = await _request('POST', '/relay/followup/quota', token: dev1Token, body: {
      'code': 'E2E-$_run-QUOTA',
      'used': 0,
      'consume': true,
    });
    if (i == 0) {
      _check(
        'kuota konsumsi pertama diizinkan',
        last.body?['allowed'] == true && last.body?['consumed'] == true,
        jsonEncode(last.body),
      );
    }
  }
  _check(
    'kuota berhenti di 20',
    last?.body?['allowed'] == false && last?.body?['used'] == 20,
    '${last?.body}',
  );

  // 14. Transport. CORS hanya mengizinkan origin yang terdaftar (F8-5).
  r = await _request(
    'OPTIONS',
    '/relay/devices',
    origin: _origin.isEmpty ? 'https://tidak-terdaftar.test' : _origin,
  );
  if (_origin.isEmpty) {
    _expect('preflight origin asing ditolak', r.status, 403, r.code);
  } else {
    _expect('preflight CORS 200', r.status, 200);
    _check(
      'header allow-origin berisi origin terdaftar',
      r.headers['access-control-allow-origin'] == _origin,
      '${r.headers['access-control-allow-origin']}',
    );
  }
  r = await _request('GET', '/relay/tidak-ada');
  _expect('rute tidak dikenal 404', r.status, 404);
  r = await _request('POST', '/relay/devices', raw: '{bad json', enrollment: 'x');
  _expect('JSON rusak 400', r.status, 400, r.code);
  final huge = 'x' * (17 * 1024 * 1024);
  try {
    r = await _request('POST', '/relay/envelopes', token: dev1Token, raw: jsonEncode({'padding': huge}));
    _expect('body terlalu besar 413', r.status, 413, r.code);
  } on SocketException catch (error) {
    _check(
      'body terlalu besar 413 terkirim ke client',
      false,
      'relay mencatat 413 tetapi koneksi ditutup saat unggah: ${error.message}',
    );
  }

  // 15. Admin identities.
  r = await _request('POST', '/relay/admin/identities', admin: true, body: {
    'email': 'e2e-$_run@example.com',
    'subject': 'sub-$_run',
    'owner_id': _ownerId,
  });
  _expect('admin mengaitkan identitas 200', r.status, 200);
  r = await _request('GET', '/relay/admin/identities', admin: true);
  _expect('admin daftar identitas 200', r.status, 200);
  _check('daftar identitas berisi email baru', r.text.contains('e2e-$_run@example.com'));

  // 16. Isolation.
  r = await _request('GET', '/relay/manage/accounts?owner_id=owner_demo', token: empToken);
  _expect('karyawan owner lain tidak bisa baca akun', r.status, 401);

  final passed = _results.where((item) => item.ok).length;
  final failed = _results.length - passed;
  print('\nSUMMARY $passed/${_results.length} passed, $failed failed');

  final report = {
    'run': _run,
    'base': _base,
    'owner_id': _ownerId,
    'finished_at': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'failed': failed,
    'results': [
      for (final item in _results)
        {'name': item.name, 'ok': item.ok, 'detail': item.detail},
    ],
    'http_log': _log,
  };
  File('relay_e2e_result.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  if (failed > 0) exitCode = 1;
}
