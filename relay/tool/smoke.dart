// Uji asap manual terhadap relay yang sedang berjalan:
//   dart run tool/smoke.dart http://127.0.0.1:8787 dev-admin
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'package:pusatkupos_relay/canonical.dart';

late String base;
late String admin;

Future<void> main(List<String> args) async {
  base = args.isNotEmpty ? args.first : 'http://127.0.0.1:8787';
  admin = args.length > 1 ? args[1] : 'dev-admin';
  final owner = await _keyPair('owner');
  final ownerId = 'uji${DateTime.now().millisecondsSinceEpoch % 1000000}';

  final created = await _post(
    '/relay/admin/owners',
    {
      'owner_id': ownerId,
      'owner_public_key': owner.publicKey,
      'days': 30,
      'store_limit': 3,
    },
    headers: {'Authorization': 'Bearer $admin'},
  );
  _check(created['enroll_token'] != null, 'enroll token');
  final license = await _verifyLicense(
    created['license_token'] as String,
    created['license_public_key'] as String,
    ownerId,
  );
  _log('owner $ownerId, lisensi ${license['plan']} s/d ${license['period_end']}');

  final device = await _keyPair('device1');
  final enroll = await _post(
    '/relay/devices',
    {
      'owner_id': ownerId,
      'nama': 'Perangkat Uji',
      'kind': 'owner',
      'public_key': device.publicKey,
      'encryption_key': device.publicKey,
      'owner_public_key': owner.publicKey,
      'store_ids': ['utama'],
    },
    headers: {'X-Relay-Enroll-Token': created['enroll_token'] as String},
  );
  final token = enroll['token'] as String;
  final relayId = (enroll['device'] as Map)['id'] as String;
  _log('perangkat $relayId terdaftar');

  final storeKey = base64Url.encode(_randomBytes(32));
  final wrapSignature = await _sign(
    owner.seed,
    canonicalJson({
      'store_id': 'utama',
      'device_id': relayId,
      'wrapped_key': storeKey,
    }),
  );
  await _post(
    '/relay/keys',
    {
      'store_id': 'utama',
      'device_id': relayId,
      'wrapped_key': storeKey,
      'signature': wrapSignature,
    },
    headers: {'X-Device-Token': token},
  );

  final fields = {
    'v': 1,
    'store_id': 'utama',
    'sender_device_id': relayId,
    'recipient_device_id': '',
    'seq': 1,
    'hlc_wall': DateTime.now().millisecondsSinceEpoch,
    'hlc_counter': 0,
    'idempotency_key': 'idem-uji-1',
    'ciphertext': base64Url.encode(_randomBytes(48)),
    'nonce': base64Url.encode(_randomBytes(12)),
  };
  final envelope = {
    ...fields,
    'signature': await _sign(device.seed, canonicalJson(fields)),
  };
  await _post(
    '/relay/envelopes',
    envelope,
    headers: {'X-Device-Token': token},
  );
  final feed = await _get(
    '/relay/feed?store_id=utama&since_seq=0&limit=50',
    headers: {'X-Device-Token': token},
  );
  final envelopes = feed['envelopes'] as List? ?? const [];
  _check(envelopes.length == 1, 'feed berisi satu amplop');
  _check(
    (envelopes.first as Map)['idempotency_key'] == 'idem-uji-1',
    'idempotency feed',
  );
  _log('amplop diterima di urutan ${feed['next_seq']}');

  final boot = await _get(
    '/relay/bootstrap?store_id=utama',
    headers: {'X-Device-Token': token},
  );
  _check(boot['wrapped_key'] == storeKey, 'key-wrap tersimpan');

  final round = await _post(
    '/relay/sync/rounds',
    {'store_id': 'utama'},
    headers: {'X-Device-Token': token},
  );
  _check(round['complete'] == false, 'putaran menunggu ack perangkat');
  final seq = feed['next_seq'] as int;
  final checksum = base64Url.encode(_randomBytes(32));
  final wall = DateTime.now().millisecondsSinceEpoch;
  final snapshotBody = {
    'store_id': 'utama',
    'store_seq': seq,
    'round_id': round['id'],
    'ciphertext': base64Url.encode(_randomBytes(64)),
    'nonce': base64Url.encode(_randomBytes(12)),
    'signature': await _sign(
      device.seed,
      canonicalJson({
        'store_id': 'utama',
        'device_id': relayId,
        'checksum': checksum,
        'store_seq': seq,
        'hlc_wall': wall,
        'hlc_counter': 0,
      }),
    ),
    'checksum': checksum,
    'hlc_wall': wall,
    'hlc_counter': 0,
  };
  final rejected = await _postStatus(
    '/relay/snapshots',
    snapshotBody,
    headers: {'X-Device-Token': token},
  );
  _check(rejected == 409, 'snapshot ditolak sebelum semua perangkat ack');
  final acked = await _post(
    '/relay/sync/rounds/${round['id']}/ack',
    {'store_id': 'utama', 'last_seq': seq, 'pending_count': 0},
    headers: {'X-Device-Token': token},
  );
  _check(acked['complete'] == true, 'putaran lengkap setelah ack');
  await _post(
    '/relay/snapshots',
    snapshotBody,
    headers: {'X-Device-Token': token},
  );

  final device2 = await _keyPair('device2');
  final enroll2 = await _post(
    '/relay/devices',
    {
      'owner_id': ownerId,
      'nama': 'Perangkat Baru',
      'kind': 'owner',
      'public_key': device2.publicKey,
      'encryption_key': device2.publicKey,
      'owner_public_key': owner.publicKey,
      'store_ids': ['utama'],
    },
    headers: {'X-Relay-Enroll-Token': created['enroll_token'] as String},
  );
  final token2 = enroll2['token'] as String;
  final feed2 = await _get(
    '/relay/feed?store_id=utama&since_seq=0',
    headers: {'X-Device-Token': token2},
  );
  _check(feed2['snapshot_required'] == true, 'perangkat baru butuh snapshot');
  final boot2 = await _get(
    '/relay/bootstrap?store_id=utama',
    headers: {'X-Device-Token': token2},
  );
  _check(boot2['snapshot'] != null, 'bootstrap membawa snapshot');
  _log('snapshot wajib untuk perangkat baru');

  final accountPayload = {
    'v': 1,
    'owner_id': ownerId,
    'account_sync_id': 'akun-uji-1',
    'permission_version': 1,
    'username': 'kasiruji',
    'nama': 'Kasir Uji',
    'role_base': 'KASIR',
    'extra_permissions': ['diskon'],
    'store_ids': ['utama'],
    'issued_at': DateTime.now().toUtc().toIso8601String(),
  };
  final accountSignature = await _sign(owner.seed, canonicalJson(accountPayload));
  await _post(
    '/relay/manage/accounts',
    {
      'owner_id': ownerId,
      'sync_id': 'akun-uji-1',
      'username': 'kasiruji',
      'nama': 'Kasir Uji',
      'role_base': 'KASIR',
      'extra_permissions': ['diskon'],
      'store_ids': ['utama'],
      'password_hash': 'hash',
      'password_salt': 'salt',
      'password_iterations': 600000,
      'aktif': true,
      'permission_version': 1,
      'permission_payload': accountPayload,
      'permission_signature': accountSignature,
      'permission_signer_public_key': owner.publicKey,
    },
    headers: {'X-Device-Token': token},
  );
  final invite = await _post(
    '/relay/manage/invites',
    {
      'owner_id': ownerId,
      'account_sync_id': 'akun-uji-1',
      'store_id': 'utama',
      'ttl_minutes': 10,
    },
    headers: {'X-Device-Token': token},
  );
  final employee = await _keyPair('employee');
  final claim = await _post('/relay/invites/claim', {
    'code': invite['code'],
    'nama': 'HP Karyawan',
    'public_key': employee.publicKey,
    'encryption_key': employee.publicKey,
  });
  final permission = claim['permission'] as Map;
  _check(
    permission['signer_public_key'] == owner.publicKey,
    'signer izin = owner',
  );
  final permissionOk = await _verify(
    owner.publicKey,
    canonicalJson(permission['payload']),
    permission['signature'] as String,
  );
  _check(permissionOk, 'tanda tangan izin valid');
  final employeeLicense = claim['license_token'] as String;
  await _verifyLicense(employeeLicense, created['license_public_key'] as String, ownerId);
  _log('pairing karyawan + izin + lisensi berhasil');

  final me = await _get(
    '/relay/permissions/me',
    headers: {'X-Device-Token': claim['token'] as String},
  );
  _check((me['account'] as Map)['username'] == 'kasiruji', 'permissions/me');

  final round2 = await _post(
    '/relay/sync/rounds',
    {'store_id': 'utama'},
    headers: {'X-Device-Token': token},
  );
  _check((round2['total'] as num) >= 3, 'putaran memuat owner dan karyawan');
  final roundPath = '/relay/sync/rounds/${round2['id']}/ack';
  await _post(
    roundPath,
    {'store_id': 'utama', 'last_seq': seq, 'pending_count': 0},
    headers: {'X-Device-Token': token},
  );
  await _post(
    roundPath,
    {'store_id': 'utama', 'last_seq': seq, 'pending_count': 0},
    headers: {'X-Device-Token': token2},
  );
  final offline = await _get(
    '/relay/sync/rounds/${round2['id']}',
    headers: {'X-Device-Token': token},
  );
  _check(offline['complete'] == false, 'karyawan offline menahan cadangan');
  final blocked = await _postStatus(
    '/relay/snapshots',
    {...snapshotBody, 'round_id': round2['id']},
    headers: {'X-Device-Token': token},
  );
  _check(blocked == 409, 'snapshot ditolak saat karyawan belum sync');
  final partial = await _post(
    roundPath,
    {'store_id': 'utama', 'last_seq': seq, 'pending_count': 1},
    headers: {'X-Device-Token': claim['token'] as String},
  );
  _check(partial['complete'] == false, 'antrean lokal karyawan menahan cadangan');
  final done = await _post(
    roundPath,
    {'store_id': 'utama', 'last_seq': seq, 'pending_count': 0},
    headers: {'X-Device-Token': claim['token'] as String},
  );
  _check(done['complete'] == true, 'cadangan lengkap setelah semua perangkat ack');
  await _post(
    '/relay/snapshots',
    {...snapshotBody, 'round_id': round2['id']},
    headers: {'X-Device-Token': token},
  );

  final other = await _post(
    '/relay/admin/owners',
    {
      'owner_id': '${ownerId}b',
      'days': 30,
      'store_limit': 3,
    },
    headers: {'Authorization': 'Bearer $admin'},
  );
  final otherDevice = await _keyPair('pemilik-lain');
  final otherEnroll = await _post(
    '/relay/devices',
    {
      'owner_id': '${ownerId}b',
      'nama': 'Perangkat Pemilik Lain',
      'kind': 'owner',
      'public_key': otherDevice.publicKey,
      'encryption_key': otherDevice.publicKey,
      'store_ids': ['utama'],
    },
    headers: {'X-Relay-Enroll-Token': other['enroll_token'] as String},
  );
  final otherFeed = await _get(
    '/relay/feed?store_id=utama&since_seq=0',
    headers: {'X-Device-Token': otherEnroll['token'] as String},
  );
  _check(
    (otherFeed['envelopes'] as List).isEmpty,
    'toko utama milik owner lain tidak berbagi data',
  );
  _log('isolasi antar-owner lulus');

  print('\nSemua uji asap relay lulus.');
}

class _Keys {
  _Keys(this.seed, this.publicKey);
  final List<int> seed;
  final String publicKey;
}

Future<_Keys> _keyPair(String label) async {
  final seed = _randomBytes(32);
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final public = await pair.extractPublicKey();
  _log('kunci $label dibuat');
  return _Keys(seed, base64Url.encode(public.bytes));
}

Future<String> _sign(List<int> seed, String payload) async {
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final signature = await Ed25519().sign(utf8.encode(payload), keyPair: pair);
  return base64Url.encode(signature.bytes);
}

Future<bool> _verify(String publicKey, String payload, String signature) async {
  return Ed25519().verify(
    utf8.encode(payload),
    signature: Signature(
      base64Url.decode(signature),
      publicKey: SimplePublicKey(
        base64Url.decode(publicKey),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}

Future<Map<String, Object?>> _verifyLicense(
  String token,
  String publicKey,
  String ownerId,
) async {
  final parts = token.split('.');
  _check(parts.length == 2, 'format token lisensi');
  final ok = await _verify(publicKey, utf8.decode(base64Url.decode(parts[0])), parts[1]);
  _check(ok, 'tanda tangan lisensi');
  final payload = jsonDecode(utf8.decode(base64Url.decode(parts[0]))) as Map;
  _check(payload['owner_id'] == ownerId, 'owner lisensi');
  _check(
    DateTime.parse(payload['period_end'] as String).isAfter(DateTime.now().toUtc()),
    'masa berlaku lisensi',
  );
  return payload.map((key, value) => MapEntry('$key', value));
}

Future<Map<String, Object?>> _get(
  String path, {
  Map<String, String> headers = const {},
}) async {
  final response = await http.get(Uri.parse('$base$path'), headers: headers);
  return _decode(response);
}

Future<Map<String, Object?>> _post(
  String path,
  Map<String, Object?> body, {
  Map<String, String> headers = const {},
}) async {
  final response = await http.post(
    Uri.parse('$base$path'),
    headers: {'content-type': 'application/json', ...headers},
    body: jsonEncode(body),
  );
  return _decode(response);
}

Future<int> _postStatus(
  String path,
  Map<String, Object?> body, {
  Map<String, String> headers = const {},
}) async {
  final response = await http.post(
    Uri.parse('$base$path'),
    headers: {'content-type': 'application/json', ...headers},
    body: jsonEncode(body),
  );
  return response.statusCode;
}

Map<String, Object?> _decode(http.Response response) {
  final decoded = jsonDecode(response.body);
  if (response.statusCode >= 400) {
    throw StateError('HTTP ${response.statusCode}: $decoded');
  }
  return (decoded as Map).map((key, value) => MapEntry('$key', value));
}

void _check(bool condition, String label) {
  if (!condition) throw StateError('GAGAL: $label');
  _log('OK: $label');
}

void _log(String message) => print('• $message');

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}
