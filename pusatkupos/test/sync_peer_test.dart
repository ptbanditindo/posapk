import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/account_service.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/device_service.dart';
import 'package:pusatkupos/data/license_service.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/pairing_service.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';
import 'package:pusatkupos/sync/sync_service.dart';

const _configPath = String.fromEnvironment('PEER_CONFIG');
const _phase = String.fromEnvironment('PEER_PHASE');

Future<Map<String, dynamic>> _readJson(String path) async {
  final raw = await File(path).readAsString();
  return jsonDecode(raw) as Map<String, dynamic>;
}

Future<void> _writeJson(String path, Map<String, Object?> data) async {
  await File(path).writeAsString(jsonEncode(data), flush: true);
}

Future<Map<String, dynamic>> _session() => _readJson(_configPath);

Future<void> _openAndSeed(Map<String, dynamic> config, String dbPath) async {
  final db = AppDatabase.instance;
  await db.initForTest(dbPath);
  await SecureStore.instance.write(
    'owner.signing.private',
    config['owner_private'] as String,
  );
  final owner = await db.db.query('owner_identity', limit: 1);
  if (owner.isEmpty) {
    await db.db.insert('owner_identity', {
      'id': 1,
      'owner_id': config['owner_id'],
      'public_key': config['owner_public'],
      'created_at': nowIso(),
    });
  }
  if (await LicenseService.instance.license() == null) {
    await LicenseService.instance.activate(days: 3650, deviceLimit: 10);
  }
  await SyncService.instance.configure(
    relayUrl: config['relay_url'] as String,
    enrollToken: config['relay_token'] as String,
    storeId: config['store_id'] as String,
  );
}

Future<String> _hashPassword(String value, String salt) async {
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(value)),
    nonce: base64Url.decode(salt),
  );
  return base64UrlEncode(await key.extractBytes());
}

String _newSalt() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)));
}

void main() {
  test(
    'peer sync fase $_phase',
    () async {
      final config = await _session();
      final db = AppDatabase.instance;
      switch (_phase) {
        case 'init':
          final keys = await generateSigningKey();
          config['owner_id'] = 'E2E${newNotaPrefix(length: 5)}';
          config['store_id'] = 'e2e-${(config['owner_id'] as String).toLowerCase()}';
          config['owner_public'] = keys.publicKey;
          config['owner_private'] = keys.privateKey;
          config['a_db'] = p.join(config['base_dir'] as String, 'a.db');
          config['b_db'] = p.join(config['base_dir'] as String, 'b.db');
          config['a1_result'] =
              p.join(config['base_dir'] as String, 'a1.json');
          config['b1_result'] =
              p.join(config['base_dir'] as String, 'b1.json');
          config['a2_result'] =
              p.join(config['base_dir'] as String, 'a2.json');
          config['b2_result'] =
              p.join(config['base_dir'] as String, 'b2.json');
          config['a3_result'] =
              p.join(config['base_dir'] as String, 'a3.json');
          config['a4_result'] =
              p.join(config['base_dir'] as String, 'a4.json');
          config['b3_result'] =
              p.join(config['base_dir'] as String, 'b3.json');
          config['e1_db'] = p.join(config['base_dir'] as String, 'e1.db');
          config['m1_result'] =
              p.join(config['base_dir'] as String, 'm1.json');
          config['e1_result'] =
              p.join(config['base_dir'] as String, 'e1.json');
          config['a6_result'] =
              p.join(config['base_dir'] as String, 'a6.json');
          config['e2_result'] =
              p.join(config['base_dir'] as String, 'e2.json');
          config['v_db'] = p.join(config['base_dir'] as String, 'v.db');
          config['r1_result'] =
              p.join(config['base_dir'] as String, 'r1.json');
          config['v1_result'] =
              p.join(config['base_dir'] as String, 'v1.json');
          config['a7_result'] =
              p.join(config['base_dir'] as String, 'a7.json');
          config['v2_result'] =
              p.join(config['base_dir'] as String, 'v2.json');
          await _writeJson(_configPath, config);
          break;
        case 'A1':
          await _openAndSeed(config, config['a_db'] as String);
          final reg = await SyncService.instance.registerRelayDevice(
            nama: 'HP Owner A',
          );
          expect(reg['key_pending'], isFalse);
          final customerId = await db.addCustomer(
            nama: 'Pelanggan E2E',
            nomorHp: '081200000010',
          );
          final unitId = await db.addUnit(
            customerId: customerId,
            unitType: 'MOBIL',
            nopol: 'B 10 E2E',
            jenisMobil: 'Avanza',
          );
          await db.saveStockItem(
            kode: 'SP-E2E',
            nama: 'Radiator E2E',
            hargaModalCents: 20000000,
            hargaJualCents: 30000000,
            jumlah: 10,
            stokMinimum: 2,
          );
          final stock = (await db.listStock()).first;
          final recordId = await db.createTransaction(
            unitId: unitId,
            keluhan: 'Radiator bocor E2E',
            jobs: [
              JobDraft(
                deskripsi: 'Bongkar pasang',
                jumlah: 1,
                hargaCents: 10000000,
              ),
            ],
            parts: [
              PartDraft(
                stockItemId: stock.id,
                nama: stock.nama,
                jumlah: 3,
                hargaCents: stock.hargaJualCents,
                modalCents: stock.hargaModalCents,
              ),
            ],
            diskonCents: 0,
            metodeBayar: 'CASH',
            bayarCents: 100000000,
            requestId: 'e2e-note-1',
          );
          await SyncService.instance.enqueueNote(recordId);
          final detail = await db.recordDetail(recordId);
          final syncRows = await db.db.query(
            'service_records',
            columns: ['sync_id'],
            where: 'id = ?',
            whereArgs: [recordId],
            limit: 1,
          );
          await _writeJson(config['a1_result'] as String, {
            'relay_device_id': reg['relay_device_id'],
            'local_device_id': reg['local_device_id'],
            'record_sync_id': syncRows.first['sync_id'],
            'no_nota': detail!.record.noNota,
            'stock': (await db.listStock()).first.jumlah,
            'payments': detail.payments.length,
          });
          break;
        case 'B1':
          await _openAndSeed(config, config['b_db'] as String);
          final reg = await SyncService.instance.registerRelayDevice(
            nama: 'HP Kasir B',
          );
          expect(reg['key_pending'], isTrue);
          final device = await DeviceService.instance.currentDevice();
          await _writeJson(config['b1_result'] as String, {
            'relay_device_id': reg['relay_device_id'],
            'local_device_id': reg['local_device_id'],
            'encryption_key': device!['encryption_key'],
            'has_key_before_wrap':
                await SyncService.instance.existingStoreKey() != null,
          });
          break;
        case 'A2':
          await _openAndSeed(config, config['a_db'] as String);
          expect(await SyncService.instance.refreshStoreKey(), isTrue);
          final b1 = await _readJson(config['b1_result'] as String);
          await SyncService.instance.wrapStoreKeyForDevice(
            targetRelayDeviceId: b1['relay_device_id'] as String,
            targetEncryptionKey: b1['encryption_key'] as String,
          );
          final sent = await SyncService.instance.syncNow();
          expect(sent['sent'], 1);
          await _writeJson(config['a2_result'] as String, {
            'wrapped': true,
            'cursor': sent['cursor'],
          });
          break;
        case 'B2':
          await _openAndSeed(config, config['b_db'] as String);
          expect(await SyncService.instance.refreshStoreKey(), isTrue);
          final sync1 = await SyncService.instance.syncNow();
          expect(sync1['applied'], 1);
          final a1 = await _readJson(config['a1_result'] as String);
          final rows = await db.db.query(
            'service_records',
            where: 'sync_id = ?',
            whereArgs: [a1['record_sync_id']],
            limit: 1,
          );
          expect(rows, isNotEmpty);
          final recordId = rows.first['id'] as int;
          final detail = await db.recordDetail(recordId);
          expect(detail!.payments.single.nominalCents, 100000000);
          expect((await db.listStock()).single.jumlah, 7);
          await db.voidRecord(recordId, 'Salah input E2E');
          await SyncService.instance.enqueueNoteVoid(recordId);
          final sync2 = await SyncService.instance.syncNow();
          expect(sync2['sent'], greaterThanOrEqualTo(1));
          await _writeJson(config['b2_result'] as String, {
            'record_sync_id': a1['record_sync_id'],
            'stock_after_void': (await db.listStock()).single.jumlah,
            'cursor': sync2['cursor'],
          });
          break;
        case 'A3':
          await _openAndSeed(config, config['a_db'] as String);
          final sync = await SyncService.instance.syncNow();
          expect(sync['applied'], 1);
          final a1 = await _readJson(config['a1_result'] as String);
          final rows = await db.db.query(
            'service_records',
            where: 'sync_id = ?',
            whereArgs: [a1['record_sync_id']],
            limit: 1,
          );
          final detail = await db.recordDetail(rows.first['id'] as int);
          expect(detail!.record.isVoid, isTrue);
          expect(detail.voidReason, 'Salah input E2E');
          expect((await db.listStock()).single.jumlah, 10);
          expect(detail.payments.length, 1);
          final again = await SyncService.instance.syncNow();
          expect(again['applied'], 0);
          await _writeJson(config['a3_result'] as String, {
            'void': true,
            'stock': (await db.listStock()).single.jumlah,
          });
          break;
        case 'A4':
          await _openAndSeed(config, config['a_db'] as String);
          final customers = await db.listCustomers();
          final units = await db.listUnits(customers.first.id);
          final stock = (await db.listStock()).single;
          final recordId = await db.createTransaction(
            unitId: units.first.id,
            keluhan: 'Servis kedua E2E',
            jobs: [
              JobDraft(
                deskripsi: 'Servis kedua',
                jumlah: 1,
                hargaCents: 10000000,
              ),
            ],
            parts: [
              PartDraft(
                stockItemId: stock.id,
                nama: stock.nama,
                jumlah: 1,
                hargaCents: stock.hargaJualCents,
                modalCents: stock.hargaModalCents,
              ),
            ],
            diskonCents: 0,
            metodeBayar: 'CASH',
            bayarCents: 40000000,
            requestId: 'e2e-note-2',
          );
          await SyncService.instance.enqueueNote(recordId);
          final sync = await SyncService.instance.syncNow();
          expect(sync['sent'], 1);
          final snapshot = await SyncService.instance.uploadSnapshot();
          expect(snapshot['store_seq'], 3);
          await _writeJson(config['a4_result'] as String, {
            'snapshot_id': snapshot['id'],
            'store_seq': snapshot['store_seq'],
            'stock': (await db.listStock()).single.jumlah,
          });
          break;
        case 'B3':
          await _openAndSeed(config, config['b_db'] as String);
          for (final table in snapshotDeleteOrder) {
            await db.db.delete(table);
          }
          await db.db.delete('sync_cursor');
          final result = await SyncService.instance.bootstrapNow();
          expect(result['applied'], isTrue);
          expect(result['cursor'], 3);
          final records = await db.listRecords(limit: 10);
          expect(records.length, 2);
          expect(records.where((row) => row.isVoid).length, 1);
          expect((await db.listStock()).single.jumlah, 9);
          expect((await db.db.query('service_payments')).length, 2);
          await _writeJson(config['b3_result'] as String, {
            'records': records.length,
            'void': records.where((row) => row.isVoid).length,
            'stock': (await db.listStock()).single.jumlah,
            'payments': (await db.db.query('service_payments')).length,
            'cursor': result['cursor'],
          });
          break;
        case 'M1':
          final relay = config['relay_url'] as String;
          final headers = {
            'Content-Type': 'application/json',
            'X-Relay-Enroll-Token': config['relay_token'] as String,
          };
          final store = config['store_id'] as String;
          final username = 'kasir_${newNotaPrefix(length: 4).toLowerCase()}';
          final password = 'Rahasia123';
          final salt = _newSalt();
          final syncId = newSyncId();
          final access = await generateSigningKey();
          final payload = {
            'v': 1,
            'owner_id': config['owner_id'],
            'account_sync_id': syncId,
            'permission_version': 1,
            'username': username,
            'nama': 'Kasir E2E',
            'role_base': 'KASIR',
            'extra_permissions': ['opname'],
            'store_ids': [store],
            'issued_at': nowIso(),
          };
          final signature = await signPayload(
            access.privateKey,
            utf8.encode(canonicalJson(payload)),
          );
          final accountResponse = await http.post(
            Uri.parse('$relay/relay/manage/accounts'),
            headers: headers,
            body: jsonEncode({
              'owner_id': config['owner_id'],
              'sync_id': syncId,
              'username': username,
              'nama': 'Kasir E2E',
              'role_base': 'KASIR',
              'extra_permissions': ['opname'],
              'store_ids': [store],
              'password_hash': await _hashPassword(password, salt),
              'password_salt': salt,
              'password_iterations': 120000,
              'aktif': true,
              'permission_version': 1,
              'permission_payload': payload,
              'permission_signature': signature,
              'permission_signer_public_key': access.publicKey,
            }),
          );
          expect(accountResponse.statusCode, 200, reason: accountResponse.body);
          final inviteResponse = await http.post(
            Uri.parse('$relay/relay/manage/invites'),
            headers: headers,
            body: jsonEncode({
              'owner_id': config['owner_id'],
              'account_sync_id': syncId,
              'store_id': store,
              'ttl_minutes': 10,
            }),
          );
          expect(inviteResponse.statusCode, 201, reason: inviteResponse.body);
          final invite = jsonDecode(inviteResponse.body) as Map<String, dynamic>;
          await _writeJson(config['m1_result'] as String, {
            'code': invite['code'],
            'username': username,
            'password': password,
            'sync_id': syncId,
            'store_id': store,
          });
          break;
        case 'E1':
          final m1 = await _readJson(config['m1_result'] as String);
          await db.initForTest(config['e1_db'] as String);
          final paired = await PairingService.instance.claim(
            relayUrl: config['relay_url'] as String,
            code: m1['code'] as String,
            deviceName: 'HP Kasir E2E',
          );
          expect(await db.getSetting('app.role'), 'employee');
          final firstLogin = await AccountService.instance.loginHub(
            username: m1['username'] as String,
            password: m1['password'] as String,
            pin: '123456',
          );
          expect(firstLogin, isNotNull);
          expect(firstLogin!.mustChangePassword, isTrue);
          const newPassword = 'Rahasia456';
          await AccountService.instance.changePassword(
            firstLogin.employeeId!,
            oldPassword: m1['password'] as String,
            newPassword: newPassword,
          );
          final secondLogin = await AccountService.instance.loginHub(
            username: m1['username'] as String,
            password: newPassword,
            pin: '123456',
          );
          expect(secondLogin?.mustChangePassword, isFalse);
          expect(await SyncService.instance.existingStoreKey(), isNull);
          await _writeJson(config['e1_result'] as String, {
            'relay_device_id': paired['relay_device_id'],
            'encryption_key': paired['encryption_key'],
            'username': m1['username'],
            'password': newPassword,
            'sync_id': m1['sync_id'],
          });
          break;
        case 'A6':
          await _openAndSeed(config, config['a_db'] as String);
          final e1 = await _readJson(config['e1_result'] as String);
          expect(await SyncService.instance.existingStoreKey(), isNotNull);
          await SyncService.instance.wrapStoreKeyForDevice(
            targetRelayDeviceId: e1['relay_device_id'] as String,
            targetEncryptionKey: e1['encryption_key'] as String,
          );
          await _writeJson(config['a6_result'] as String, {'wrapped': true});
          break;
        case 'E2':
          await db.initForTest(config['e1_db'] as String);
          expect(await SyncService.instance.refreshStoreKey(), isTrue);
          final sync = await SyncService.instance.syncNow();
          final records = await db.listRecords(limit: 10);
          expect(records.length, 2);
          expect(records.where((row) => row.isVoid).length, 1);
          expect((await db.listStock()).single.jumlah, 9);
          final e1 = await _readJson(config['e1_result'] as String);
          final operator = await AccountService.instance.loginHub(
            username: e1['username'] as String,
            password: e1['password'] as String,
            pin: '123456',
          );
          expect(operator, isNotNull);
          await _writeJson(config['e2_result'] as String, {
            'records': records.length,
            'void': records.where((row) => row.isVoid).length,
            'stock': (await db.listStock()).single.jumlah,
            'cursor': sync['cursor'],
            'snapshot': sync['snapshot_applied'] ?? false,
          });
          break;
        case 'R1':
          final b1 = await _readJson(config['b1_result'] as String);
          final response = await http.post(
            Uri.parse(
              '${config['relay_url']}/relay/manage/devices/'
              '${b1['relay_device_id']}/revoke'
              '?owner_id=${config['owner_id']}',
            ),
            headers: {
              'Content-Type': 'application/json',
              'X-Relay-Enroll-Token': config['relay_token'] as String,
            },
            body: jsonEncode({'reason': 'uji ganti perangkat owner'}),
          );
          expect(response.statusCode, 200, reason: response.body);
          await _writeJson(config['r1_result'] as String, {
            'revoked': b1['relay_device_id'],
          });
          break;
        case 'V1':
          await db.initForTest(config['v_db'] as String);
          await db.db.insert('owner_identity', {
            'id': 1,
            'owner_id': config['owner_id'],
            'public_key': config['owner_public'],
            'created_at': nowIso(),
          });
          await db.db.insert('license', {
            'id': 1,
            'plan': 'premium',
            'period_end': '2027-11-03T00:00:00',
            'device_limit': 2,
            'provider': 'summary',
            'token': null,
            'activated_at': nowIso(),
          });
          await SyncService.instance.configure(
            relayUrl: config['relay_url'] as String,
            enrollToken: config['relay_token'] as String,
            storeId: config['store_id'] as String,
          );
          final registered = await SyncService.instance.registerRelayDevice(
            nama: 'Owner Viewer E2E',
            viewer: true,
          );
          expect(registered['key_pending'], isTrue);
          final viewerDevice = await DeviceService.instance.currentDevice();
          await _writeJson(config['v1_result'] as String, {
            'relay_device_id': registered['relay_device_id'],
            'encryption_key': viewerDevice!['encryption_key'],
          });
          break;
        case 'A7':
          await _openAndSeed(config, config['a_db'] as String);
          final v1 = await _readJson(config['v1_result'] as String);
          await SyncService.instance.wrapStoreKeyForDevice(
            targetRelayDeviceId: v1['relay_device_id'] as String,
            targetEncryptionKey: v1['encryption_key'] as String,
          );
          await _writeJson(config['a7_result'] as String, {'wrapped': true});
          break;
        case 'V2':
          await db.initForTest(config['v_db'] as String);
          expect(await SyncService.instance.refreshStoreKey(), isTrue);
          final sync = await SyncService.instance.syncNow();
          final records = await db.listRecords(limit: 10);
          expect(records.length, 2);
          expect(records.where((row) => row.isVoid).length, 1);
          expect((await db.listStock()).single.jumlah, 9);
          await _writeJson(config['v2_result'] as String, {
            'records': records.length,
            'void': records.where((row) => row.isVoid).length,
            'stock': (await db.listStock()).single.jumlah,
            'cursor': sync['cursor'],
            'snapshot': sync['snapshot_applied'] ?? false,
          });
          break;
        default:
          fail('Fase tidak dikenal: $_phase');
      }
    },
    skip: _phase.isEmpty ? 'Butuh PEER_PHASE dan PEER_CONFIG.' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
