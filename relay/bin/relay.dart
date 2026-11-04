import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
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
    ..addCommand(
      'owner',
      ArgParser()
        ..addOption('owner-id', mandatory: true)
        ..addOption('public-key', defaultsTo: '')
        ..addOption('days', defaultsTo: '30')
        ..addOption('devices', defaultsTo: '5')
        ..addFlag('force', negatable: false),
    )
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
        ..addOption('devices'),
    )
    ..addCommand(
      'token',
      ArgParser()..addOption('owner-id', mandatory: true),
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
          'SELECT owner_id, owner_public_key, license_plan, license_period_end, license_device_limit FROM owners ORDER BY created_at',
        );
        print(jsonEncode(rows));
        break;
      case 'owner':
        await _createOwner(db, command);
        break;
      case 'identity':
        await _bindIdentity(db, command);
        break;      case 'license':
        await _printLicense(db, command);
        break;
      case 'token':
        await _printToken(db, command);
        break;
      case 'serve':
        await _serve(db, config);
        break;
    }
  } finally {
    if (command.name != 'serve') await db.close();
  }
}

Future<void> _createOwner(Database db, ArgResults args) async {
  final ownerId = args['owner-id'] as String;
  final publicKey = args['public-key'] as String;
  final days = int.tryParse(args['days'] as String) ?? 30;
  final devices = int.tryParse(args['devices'] as String) ?? 5;
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
  license_device_limit)
VALUES (@id, @public, 'premium', @end, @devices)
ON CONFLICT (owner_id) DO UPDATE SET
  owner_public_key = CASE WHEN EXCLUDED.owner_public_key = '' THEN owners.owner_public_key ELSE EXCLUDED.owner_public_key END,
  license_plan = 'premium', license_period_end = EXCLUDED.license_period_end,
  license_device_limit = EXCLUDED.license_device_limit
''',
    {'id': ownerId, 'public': publicKey, 'end': end, 'devices': devices},
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
    'device_limit': owner['license_device_limit'],
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
  final devices = int.tryParse(args['devices'] as String? ?? '');
  if (days != null) {
    await db.execute(
      'UPDATE owners SET license_period_end = @end WHERE owner_id = @id',
      {
        'end': DateTime.now().toUtc().add(Duration(days: days)),
        'id': ownerId,
      },
    );
  }
  if (devices != null) {
    await db.execute(
      'UPDATE owners SET license_device_limit = @devices WHERE owner_id = @id',
      {'devices': devices, 'id': ownerId},
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

Future<String> _licenseToken(Database db, Map<String, Object?> owner) {
  final end = owner['license_period_end'];
  return LicenseService(db).issueToken(
    ownerId: owner['owner_id'] as String,
    periodEnd: end is DateTime
        ? end.toUtc()
        : DateTime.now().toUtc().add(const Duration(days: 30)),
    plan: owner['license_plan'] as String? ?? 'premium',
    deviceLimit: (owner['license_device_limit'] as num?)?.toInt() ?? 5,
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
