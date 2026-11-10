import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/auth/permissions.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/ids.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/pin_service.dart';
import 'package:pusatkupos/data/store_settings.dart';
import 'package:pusatkupos/sync/sync_conflict_rules.dart';

import '../support/test_harness.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

final _secureValues = <String, String>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    _secureValues.clear();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = '${args['key'] ?? ''}';
      switch (call.method) {
        case 'write':
          _secureValues[key] = '${args['value']}';
          return null;
        case 'read':
          return _secureValues[key];
        case 'delete':
          _secureValues.remove(key);
          return null;
        case 'containsKey':
          return _secureValues.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(_secureValues);
        case 'deleteAll':
          _secureValues.clear();
          return null;
      }
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  late ServiceTestHarness harness;
  late Database db;

  setUp(() async {
    harness = ServiceTestHarness();
    await harness.setUp();
    db = harness.db;
    await StoreSettingsService.instance.ensure();
    // Pemilik memberi kasir akses kredit lewat pengaturan peran.
    await db.update('store_settings', {
      'role_permissions_json': jsonEncode({
        'KASIR': {'beri_kredit': true},
      }),
    });
  });

  tearDown(() async {
    await harness.tearDown();
  });

  Operator cashier({bool credit = true}) => Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir',
        permissions: {'buat_nota', if (credit) permissionCredit},
      );

  Future<({int customerId, int unitId})> seedCustomer({
    int limitCents = 0,
    String nama = 'Budi',
    String hp = '08123456789',
  }) async {
    final now = nowIso();
    final customerId = await db.insert('customers', {
      'sync_id': newSyncId(),
      'nama': nama,
      'nomor_hp': hp,
      'limit_kredit_cents': limitCents,
      'created_at': now,
      'updated_at': now,
    });
    final unitId = await db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'nopol': 'B 1234 XY',
      'created_at': now,
      'updated_at': now,
    });
    return (customerId: customerId, unitId: unitId);
  }

  Future<int> createCredit({
    required int customerId,
    required int unitId,
    required Operator actor,
    DateTime? jatuhTempo,
    String? ownerPin,
  }) {
    return AppDatabase.instance.createTransaction(
      unitId: unitId,
      customerId: customerId,
      keluhan: 'Servis kredit',
      jobs: [
        JobDraft(deskripsi: 'Jasa servis', jumlah: 1, hargaCents: 100000),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: 0,
      jatuhTempo: jatuhTempo,
      actor: actor,
      ownerPin: ownerPin,
    );
  }

  DateTime due() => DateTime.now().add(const Duration(days: 14));

  Future<Map<String, Object?>> record(int id) async {
    return (await db.query(
      'service_records',
      where: 'id = ?',
      whereArgs: [id],
    ))
        .single;
  }

  test('pemilik bebas memberi kredit dan jatuh tempo tersimpan', () async {
    final ids = await seedCustomer();
    final id = await createCredit(
      customerId: ids.customerId,
      unitId: ids.unitId,
      actor: Operator.owner,
      jatuhTempo: due(),
    );

    final row = await record(id);
    expect(row['sisa_bayar'], 100000);
    expect(row['jatuh_tempo'], isNotNull);
    expect(row['kredit_disetujui_oleh'], isNull);
  });

  test('kasir tanpa izin kredit ditolak', () async {
    final ids = await seedCustomer();

    await expectLater(
      createCredit(
        customerId: ids.customerId,
        unitId: ids.unitId,
        actor: cashier(credit: false),
        jatuhTempo: due(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'pesan',
          contains('tidak berhak memberi kredit'),
        ),
      ),
    );
    expect(await db.query('service_records'), isEmpty);
  });

  test('kasir dengan izin wajib mengisi jatuh tempo', () async {
    final ids = await seedCustomer();

    await expectLater(
      createCredit(
        customerId: ids.customerId,
        unitId: ids.unitId,
        actor: cashier(),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await db.query('service_records'), isEmpty);
  });

  test('kasir dengan izin di bawah limit dapat membuat kredit', () async {
    final ids = await seedCustomer(limitCents: 150000);
    final id = await createCredit(
      customerId: ids.customerId,
      unitId: ids.unitId,
      actor: cashier(),
      jatuhTempo: due(),
    );

    final row = await record(id);
    expect(row['sisa_bayar'], 100000);
    expect(row['kredit_disetujui_oleh'], isNull);
  });

  test('piutang berjalan ikut dihitung terhadap limit', () async {
    final ids = await seedCustomer(limitCents: 150000);
    await createCredit(
      customerId: ids.customerId,
      unitId: ids.unitId,
      actor: cashier(),
      jatuhTempo: due(),
    );

    await expectLater(
      createCredit(
        customerId: ids.customerId,
        unitId: ids.unitId,
        actor: cashier(),
        jatuhTempo: due(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'pesan',
          contains('persetujuan'),
        ),
      ),
    );
    expect(await db.query('service_records'), hasLength(1));
  });

  test('melebihi limit dengan PIN pemilik disetujui dan dicatat', () async {
    await PinService.instance.setup('123456');
    final ids = await seedCustomer(limitCents: 50000);

    final id = await createCredit(
      customerId: ids.customerId,
      unitId: ids.unitId,
      actor: cashier(),
      jatuhTempo: due(),
      ownerPin: '123456',
    );

    final row = await record(id);
    expect(row['sisa_bayar'], 100000);
    expect(row['kredit_disetujui_oleh'], 'Pemilik (PIN)');
    final audits = await db.query(
      'permission_audits',
      where: 'action = ?',
      whereArgs: ['kredit'],
    );
    expect(audits, hasLength(1));
    final detail = jsonDecode(audits.single['detail_json'] as String)
        as Map<String, Object?>;
    expect(detail['disetujui_oleh'], 'Pemilik (PIN)');
    expect(detail['limit_kredit_cents'], 50000);
  });

  test('nota kredit remote dari kasir tanpa izin ditolak', () {
    const sender = SenderProfile(
      kind: 'employee',
      roleBase: 'KASIR',
      employeeSyncId: 'emp-1',
    );

    final violation = SyncConflictRules.senderViolation(
      sender: sender,
      entity: 'nota',
      action: 'upsert',
      payload: const {
        'record': {'sync_id': 'nota-1', 'sisa_bayar': 50000},
      },
    );
    expect(violation, 'peran_tidak_berhak_$permissionCredit');
  });

  test('nota kredit remote yang disetujui atau lunas diterima', () {
    const sender = SenderProfile(
      kind: 'employee',
      roleBase: 'KASIR',
      employeeSyncId: 'emp-1',
    );

    expect(
      SyncConflictRules.senderViolation(
        sender: sender,
        entity: 'nota',
        action: 'upsert',
        payload: const {
          'record': {
            'sync_id': 'nota-1',
            'sisa_bayar': 50000,
            'kredit_disetujui_oleh': 'Pemilik (PIN)',
          },
        },
      ),
      isNull,
    );
    expect(
      SyncConflictRules.senderViolation(
        sender: sender,
        entity: 'nota',
        action: 'upsert',
        payload: const {
          'record': {'sync_id': 'nota-2', 'sisa_bayar': 0},
        },
      ),
      isNull,
    );
    const granted = SenderProfile(
      kind: 'employee',
      roleBase: 'KASIR',
      employeeSyncId: 'emp-2',
      extraPermissions: {permissionCredit},
    );
    expect(
      SyncConflictRules.senderViolation(
        sender: granted,
        entity: 'nota',
        action: 'upsert',
        payload: const {
          'record': {'sync_id': 'nota-3', 'sisa_bayar': 50000},
        },
      ),
      isNull,
    );
  });
}
