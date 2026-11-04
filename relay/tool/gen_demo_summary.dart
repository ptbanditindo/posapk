import 'dart:convert';
import 'dart:io';

import 'package:pusatkupos_relay/config.dart';
import 'package:pusatkupos_relay/db.dart';
import 'package:pusatkupos_relay/license.dart';

Future<void> main() async {
  final config = RelayConfig.fromEnv();
  final db = await Database.open(config.databaseUrl);
  final license = LicenseService(db);
  final owner = await db.one(
    'SELECT * FROM owners WHERE owner_id = @id',
    {'id': 'owner_demo'},
  );
  if (owner == null) {
    stderr.writeln('owner_demo belum ada; jalankan seed-demo.');
    exit(1);
  }
  final end = owner['license_period_end'] is DateTime
      ? (owner['license_period_end'] as DateTime).toUtc()
      : DateTime.now().toUtc().add(const Duration(days: 3650));
  final plan = owner['license_plan'] as String? ?? 'premium';
  final limit = (owner['license_store_limit'] as num?)?.toInt() ?? 1;
  final token = await license.issueToken(
    ownerId: 'owner_demo',
    periodEnd: end,
    plan: plan,
    storeLimit: limit,
  );
  final summary = await license.signSummary({
    'v': 1,
    'owner_id': 'owner_demo',
    'plan': plan,
    'period_end': end.toIso8601String(),
    'store_limit': limit,
    'license_token': token,
    'owner_public_key': owner['owner_public_key'] ?? '',
    'stores': [
      {'store_id': 'utama', 'nama': 'Toko Demo'},
    ],
    'generated_at': DateTime.now().toUtc().toIso8601String(),
  });
  final out = File('../build_web/dummy_owner_summary.json');
  out.writeAsStringSync(jsonEncode(summary));
  stdout.writeln('wrote ${out.path}');
  await db.close();
}
