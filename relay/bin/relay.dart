import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:pusatkupos_relay/config.dart';
import 'package:pusatkupos_relay/db.dart';
import 'package:pusatkupos_relay/license.dart';
import 'package:pusatkupos_relay/server.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand('serve')
    ..addCommand('migrate')
    ..addCommand('key')
    ..addCommand('list-owners')
    ..addCommand('owner',
      ArgParser()
        ..addOption('owner-id', mandatory: true)
        ..addOption('public-key', defaultsTo: '')
        ..addOption('days', defaultsTo: '30')
        ..addOption('stores', defaultsTo: '1')
        ..addFlag('force', negatable: false),
    )
    ..addCommand('seed-demo')
    ..addCommand(
      'identity',
      ArgParser()
        ..addOption('email', mandatory: true)
        ..addOption('owner-id', mandatory: true)
        ..addOption('subject', defaultsTo: ''),
    )
    ..addCommand(
      'license',
      ArgParser()
        ..addOption('owner-id', mandatory: true)
        ..addOption('days')
        ..addOption('stores'),
    )
    ..addCommand(
      'token',
      ArgParser()..addOption('owner-id', mandatory: true),
    )
    ..addCommand(
      'maintenance',
      ArgParser()
        ..addOption('days', defaultsTo: '90')
        ..addFlag('dry-run', defaultsTo: false)
        ..addFlag('vacuum', defaultsTo: false),
    );
  final result = parser.parse(arguments);
  final command = result.command;
  if (command == null) {
    print(parser.usage);
    exit(64);
  }
  final config = RelayConfig.fromEnv();
  final db = await Database.open(config.databaseUrl);
  try {
    switch (command.name) {
      case 'migrate':
        print(jsonEncode({'ok': true, 'database': config.databaseUrl}));
        break;
      case 'key':
        final license = LicenseService(db);
        print(jsonEncode({
          'license_public_key': await license.publicKey(),
          'dart_define':
              '--dart-define=PUSATKU_LICENSE_PUBLIC_KEY=${await license.publicKey()}',
          'dart_define_from_file': '--dart-define-from-file=.env',
        }));
        break;
      case 'list-owners':
        final rows = await db.query(
          'SELECT owner_id, owner_public_key, license_plan, license_period_end, license_store_limit FROM owners ORDER BY created_at',
        );
        print(jsonEncode([
          for (final row in rows)
            {
              ...row,
              'license_period_end': row['license_period_end'] is DateTime
                  ? (row['license_period_end'] as DateTime)
                      .toUtc()
                      .toIso8601String()
                  : row['license_period_end'],
            },
        ]));
        break;
      case 'owner':
        await _createOwner(db, command);
        break;
      case 'seed-demo':
        await _seedDemo(db);
        break;
      case 'identity':
        await _bindIdentity(db, command);
        break;
      case 'license':
        await _printLicense(db, command);
        break;
      case 'token':
        await _printToken(db, command);
        break;
      case 'maintenance':
        await _maintenance(db, command);
        break;
      case 'serve':
        await _serve(db, config);
        break;
    }
  } finally {
    if (command.name != 'serve') await db.close();
  }
}

Future<void> _seedDemo(Database db) async {
  final end = DateTime.now().toUtc().add(const Duration(days: 3650));
  await db.execute(
    '''
INSERT INTO owners (owner_id, owner_public_key, license_plan,
  license_period_end, license_store_limit)
VALUES ('owner_demo', '', 'premium', @end, 3)
ON CONFLICT (owner_id) DO UPDATE SET
  license_plan = 'premium', license_period_end = EXCLUDED.license_period_end,
  license_store_limit = 3
''',
    {'end': end},
  );
  final accounts = [
    (
      sync: 'acc_kasir_demo',
      username: 'kasir',
      nama: 'Kasir Demo',
      role: 'KASIR',
      password: 'kasir123456',
      permissions: const ['lihat_laporan', 'cetak_laporan'],
    ),
    (
      sync: 'acc_mekanik_demo',
      username: 'mekanik',
      nama: 'Mekanik Demo',
      role: 'MEKANIK',
      password: 'mekanik123456',
      permissions: const <String>[],
    ),
  ];
  for (final account in accounts) {
    final (hash, salt) = await _hashDemoPassword(account.password);
    await db.execute(
      '''
INSERT INTO accounts (owner_id, sync_id, username, nama, role_base,
  extra_permissions, store_ids, password_hash, password_salt,
  password_iterations, aktif, must_change_password)
VALUES ('owner_demo', @sync, @username, @nama, @role,
  CAST(@permissions AS jsonb), CAST(@stores AS jsonb), @hash, @salt,
  10000, true, false)
ON CONFLICT (owner_id, sync_id) DO UPDATE SET
  username = EXCLUDED.username, nama = EXCLUDED.nama,
  role_base = EXCLUDED.role_base,
  extra_permissions = EXCLUDED.extra_permissions,
  store_ids = EXCLUDED.store_ids,
  password_hash = EXCLUDED.password_hash,
  password_salt = EXCLUDED.password_salt,
  password_iterations = EXCLUDED.password_iterations,
  aktif = true, must_change_password = false, updated_at = now()
''',
      {
        'sync': account.sync,
        'username': account.username,
        'nama': account.nama,
        'role': account.role,
        'permissions': jsonEncode(account.permissions),
        'stores': jsonEncode(const ['utama']),
        'hash': hash,
        'salt': salt,
      },
    );
  }
  final owner = await db.one(
    'SELECT * FROM owners WHERE owner_id = @id',
    {'id': 'owner_demo'},
  );
  print(jsonEncode({
    'ok': true,
    'owner_id': 'owner_demo',
    'accounts': ['kasir', 'mekanik'],
    'period_end': owner?['license_period_end'] is DateTime
        ? (owner!['license_period_end'] as DateTime).toUtc().toIso8601String()
        : null,
    'license_token': await _licenseToken(db, owner!),
  }));
}

Future<(String, String)> _hashDemoPassword(String value) async {
  final saltBytes =
      List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final salt = base64Url.encode(saltBytes);
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 10000,
    bits: 256,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(value)),
    nonce: saltBytes,
  );
  return (base64Url.encode(await key.extractBytes()), salt);
}

Future<void> _createOwner(Database db, ArgResults args) async {
  final ownerId = args['owner-id'] as String;
  final publicKey = args['public-key'] as String;
  final days = int.tryParse(args['days'] as String) ?? 30;
  final stores = int.tryParse(args['stores'] as String) ?? 1;
  final existing = await db.one(
    'SELECT owner_id, owner_public_key FROM owners WHERE owner_id = @id',
    {'id': ownerId},
  );
  if (existing != null &&
      (existing['owner_public_key'] as String? ?? '').isNotEmpty &&
      publicKey.isNotEmpty &&
      existing['owner_public_key'] != publicKey &&
      args['force'] != true) {
    stderr.writeln(
      'Owner sudah ada dengan kunci publik berbeda. Pakai --force untuk mengganti.',
    );
    exitCode = 65;
    return;
  }
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
  final token = _randomToken();
  await db.execute(
    'INSERT INTO enroll_tokens (token, owner_id, expires_at) VALUES (@token, @owner, @expires)',
    {
      'token': token,
      'owner': ownerId,
      'expires': DateTime.now().toUtc().add(const Duration(days: 365)),
    },
  );
  final owner = (await db.one(
    'SELECT * FROM owners WHERE owner_id = @id',
    {'id': ownerId},
  ))!;
  final license = await _licenseToken(db, owner);
  print(jsonEncode({
    'owner_id': ownerId,
    'owner_public_key': owner['owner_public_key'],
    'enroll_token': token,
    'license_token': license,
    'license_public_key': await LicenseService(db).publicKey(),
    'period_end': (owner['license_period_end'] as DateTime).toUtc().toIso8601String(),
    'store_limit': owner['license_store_limit'],
  }));
}

Future<void> _bindIdentity(Database db, ArgResults args) async {
  final email = (args['email'] as String).trim().toLowerCase();
  final ownerId = (args['owner-id'] as String).trim();
  final subject = (args['subject'] as String).trim();
  final owner = await db.one(
    'SELECT owner_id FROM owners WHERE owner_id = @id',
    {'id': ownerId},
  );
  if (owner == null) {
    stderr.writeln('Owner tidak ditemukan.');
    exitCode = 66;
    return;
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
  print(jsonEncode({
    'email': row?['email'],
    'subject': row?['subject'],
    'owner_id': row?['owner_id'],
  }));
}

Future<void> _printLicense(Database db, ArgResults args) async {
  final ownerId = args['owner-id'] as String;
  final days = int.tryParse(args['days'] as String? ?? '');
  final stores = int.tryParse(args['stores'] as String? ?? '');
  if (days != null) {
    await db.execute(
      'UPDATE owners SET license_period_end = @end WHERE owner_id = @id',
      {
        'end': DateTime.now().toUtc().add(Duration(days: days)),
        'id': ownerId,
      },
    );
  }
  if (stores != null) {
    await db.execute(
      'UPDATE owners SET license_store_limit = @stores WHERE owner_id = @id',
      {'stores': stores, 'id': ownerId},
    );
  }
  final owner = await db.one(
    'SELECT * FROM owners WHERE owner_id = @id',
    {'id': ownerId},
  );
  if (owner == null) {
    stderr.writeln('Owner tidak ditemukan.');
    exitCode = 66;
    return;
  }
  print(jsonEncode({
    'owner_id': ownerId,
    'license_token': await _licenseToken(db, owner),
    'license_public_key': await LicenseService(db).publicKey(),
  }));
}

Future<void> _printToken(Database db, ArgResults args) async {
  final ownerId = args['owner-id'] as String;
  final owner = await db.one(
    'SELECT owner_id FROM owners WHERE owner_id = @id',
    {'id': ownerId},
  );
  if (owner == null) {
    stderr.writeln('Owner tidak ditemukan.');
    exitCode = 66;
    return;
  }
  final token = _randomToken();
  await db.execute(
    'INSERT INTO enroll_tokens (token, owner_id, expires_at) VALUES (@token, @owner, @expires)',
    {
      'token': token,
      'owner': ownerId,
      'expires': DateTime.now().toUtc().add(const Duration(days: 365)),
    },
  );
  print(jsonEncode({'owner_id': ownerId, 'enroll_token': token}));
}

Future<void> _maintenance(Database db, ArgResults args) async {
  final days = int.tryParse(args['days'] as String) ?? 90;
  final dryRun = args['dry-run'] == true;
  final vacuum = args['vacuum'] == true;
  final cutoff = "now() - make_interval(days => @days)";
  final report = <String, Object?>{'days': days, 'dry_run': dryRun};

  Future<void> prune(String name, String table, String where) async {
    final count = await db.one(
      'SELECT COUNT(*) AS total FROM $table WHERE $where',
      {'days': days},
    );
    final total = (count?['total'] as num?)?.toInt() ?? 0;
    report[name] = total;
    if (dryRun || total == 0) return;
    await db.execute('DELETE FROM $table WHERE $where', {'days': days});
  }

  await prune(
    'expired_enroll_tokens',
    'enroll_tokens',
    'expires_at < $cutoff',
  );
  await prune(
    'expired_invites',
    'invites',
    'expires_at < $cutoff OR (claimed_at IS NOT NULL AND claimed_at < $cutoff)',
  );
  await prune(
    'completed_sync_rounds',
    'sync_rounds',
    "status <> 'open' AND COALESCE(completed_at, created_at) < $cutoff",
  );

  final backlog = await db.one('SELECT COUNT(*) AS total FROM envelopes');
  report['envelope_backlog'] = (backlog?['total'] as num?)?.toInt() ?? 0;
  report['retention_note'] =
      'Amplop hanya dipangkas otomatis saat semua perangkat mengakui antrean.';

  if (vacuum && !dryRun) {
    await db.execute('VACUUM ANALYZE');
    report['vacuum'] = true;
  }
  print(jsonEncode({'ok': true, ...report}));
}

Future<String> _licenseToken(Database db, Map<String, Object?> owner) {
  final end = owner['license_period_end'];
  return LicenseService(db).issueToken(
    ownerId: owner['owner_id'] as String,
    periodEnd: end is DateTime
        ? end.toUtc()
        : DateTime.now().toUtc().add(const Duration(days: 30)),
    plan: owner['license_plan'] as String? ?? 'premium',
    storeLimit: (owner['license_store_limit'] as num?)?.toInt() ?? 1,
  );
}

String _randomToken() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
}

Future<void> _serve(Database db, RelayConfig config) async {
  final server = RelayServer(db, config);
  final http = await shelf_io.serve(server.handler, config.host, config.port);
  print(jsonEncode({
    'ok': true,
    'listen': 'http://${config.host}:${http.port}',
    'database': config.databaseUrl,
    'google_login': config.googleClientId.isNotEmpty,
    'license_public_key': await server.license.publicKey(),
  }));
  await ProcessSignal.sigint.watch().first;
  await http.close();
  await db.close();
}
