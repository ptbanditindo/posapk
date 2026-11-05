import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/protocol.dart';
import 'package:pusatkupos/sync/sync_conflict_rules.dart';
import 'package:pusatkupos/sync/sync_service.dart';

void main() {
  late Directory dir;
  late KeyMaterial signing;
  final db = AppDatabase.instance;
  final storeKey = List<int>.generate(32, (index) => index + 1);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_sync_apply_');
    await db.initForTest(p.join(dir.path, 'apply.db'));
    signing = await generateSigningKey();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, Object?>> makeEnvelope({
    required String entity,
    required String action,
    required String entityId,
    required Map<String, Object?> payload,
    int wall = 100,
    int counter = 0,
    String idempotencyKey = 'idem-1',
    int seq = 1,
  }) {
    return buildEnvelope(
      devicePrivateKey: signing.privateKey,
      storeKey: storeKey,
      storeId: 'utama',
      senderDeviceId: 'device-a',
      recipientDeviceId: '',
      seq: seq,
      hlcWall: wall,
      hlcCounter: counter,
      idempotencyKey: idempotencyKey,
      entity: entity,
      action: action,
      entityId: entityId,
      payload: payload,
    );
  }

  test('stock movement diterapkan sekali walau dipanggil paralel', () async {
    await db.saveStockItem(
      kode: 'BRG-1',
      nama: 'Radiator',
      hargaModalCents: 1000,
      hargaJualCents: 2000,
      jumlah: 5,
      stokMinimum: 1,
    );
    final stockRow = (await db.db.query('stock_items')).single;
    final stockSyncId = stockRow['sync_id'] as String;
    final envelope = await makeEnvelope(
      entity: 'stock_movement',
      action: 'upsert',
      entityId: 'mv-remote-1',
      payload: {
        'sync_id': 'mv-remote-1',
        'stock_sync_id': stockSyncId,
        'nama_item': 'Radiator',
        'jenis': 'KELUAR',
        'jumlah_milli': 2000,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );

    final results = await Future.wait([
      SyncService.instance.applyOnceForTest(
        envelope: envelope,
        senderKey: signing.publicKey,
        senderKind: 'owner',
        storeKey: storeKey,
        storeId: 'utama',
      ),
      SyncService.instance.applyOnceForTest(
        envelope: envelope,
        senderKey: signing.publicKey,
        senderKind: 'owner',
        storeKey: storeKey,
        storeId: 'utama',
      ),
    ]);
    expect(results.where((applied) => applied).length, 1);
    expect((await db.listStock()).single.jumlahMilli, 7000);

    final movement = await db.db.query(
      'stock_movements',
      where: 'sync_id = ?',
      whereArgs: ['mv-remote-1'],
    );
    expect(movement.length, 1);

    final again = await SyncService.instance.applyOnceForTest(
      envelope: envelope,
      senderKey: signing.publicKey,
      senderKind: 'owner',
      storeKey: storeKey,
      storeId: 'utama',
    );
    expect(again, isFalse);
    expect((await db.listStock()).single.jumlahMilli, 7000);
  });

  test('penghapusan pelanggan memakai tombstone dan menolak versi lama',
      () async {
    final customerId = await db.addCustomer(
      nama: 'Budi',
      nomorHp: '081200000011',
    );
    final local = (await db.db.query(
      'customers',
      where: 'id = ?',
      whereArgs: [customerId],
    ))
        .single;
    final syncId = local['sync_id'] as String;
    final localWall = local['sync_hlc_wall'] as int;

    final deleteEnvelope = await makeEnvelope(
      entity: 'customer',
      action: 'delete',
      entityId: syncId,
      wall: localWall + 10,
      idempotencyKey: 'idem-delete',
      payload: {
        'sync_id': syncId,
        'nama': 'Budi',
        'nomor_hp': '081200000011',
        'created_at': local['created_at'],
        'deleted_at': '2026-02-01T00:00:00.000Z',
      },
    );
    expect(
      await SyncService.instance.applyOnceForTest(
        envelope: deleteEnvelope,
        senderKey: signing.publicKey,
        senderKind: 'owner',
        storeKey: storeKey,
        storeId: 'utama',
      ),
      isTrue,
    );
    var row = (await db.db.query(
      'customers',
      where: 'sync_id = ?',
      whereArgs: [syncId],
    ))
        .single;
    expect(row['deleted_at'], '2026-02-01T00:00:00.000Z');

    final staleEnvelope = await makeEnvelope(
      entity: 'customer',
      action: 'upsert',
      entityId: syncId,
      wall: 1,
      idempotencyKey: 'idem-stale',
      payload: {
        'sync_id': syncId,
        'nama': 'Nama Lama',
        'nomor_hp': '081200000011',
        'created_at': local['created_at'],
      },
    );
    await SyncService.instance.applyOnceForTest(
      envelope: staleEnvelope,
      senderKey: signing.publicKey,
      senderKind: 'owner',
      storeKey: storeKey,
      storeId: 'utama',
    );
    row = (await db.db.query(
      'customers',
      where: 'sync_id = ?',
      whereArgs: [syncId],
    ))
        .single;
    expect(row['nama'], 'Budi');
    expect(row['deleted_at'], '2026-02-01T00:00:00.000Z');

    final conflicts = await db.db.query(
      'sync_conflicts',
      where: 'reason = ?',
      whereArgs: ['versi_lokal_lebih_baru'],
    );
    expect(conflicts, isNotEmpty);
  });

  test('harga jasa hanya diterima dari owner dan HLC terbesar menang',
      () async {
    final employeeEnvelope = await makeEnvelope(
      entity: 'harga_jasa',
      action: 'upsert',
      entityId: 'hj-1',
      idempotencyKey: 'idem-employee',
      payload: {
        'sync_id': 'hj-1',
        'nama': 'Cuci radiator',
        'harga_jual': 1000,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    expect(
      await SyncService.instance.applyOnceForTest(
        envelope: employeeEnvelope,
        senderKey: signing.publicKey,
        senderKind: 'employee',
        storeKey: storeKey,
        storeId: 'utama',
      ),
      isTrue,
    );
    expect(
      await db.db.query(
        'harga_jasa',
        where: 'sync_id = ?',
        whereArgs: ['hj-1'],
      ),
      isEmpty,
    );
    expect(
      await db.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['harga_dikunci_owner'],
      ),
      isNotEmpty,
    );

    final ownerEnvelope = await makeEnvelope(
      entity: 'harga_jasa',
      action: 'upsert',
      entityId: 'hj-1',
      wall: 200,
      idempotencyKey: 'idem-owner',
      payload: {
        'sync_id': 'hj-1',
        'nama': 'Cuci radiator',
        'harga_jual': 5000,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    expect(
      await SyncService.instance.applyOnceForTest(
        envelope: ownerEnvelope,
        senderKey: signing.publicKey,
        senderKind: 'owner',
        storeKey: storeKey,
        storeId: 'utama',
      ),
      isTrue,
    );
    var row = (await db.db.query(
      'harga_jasa',
      where: 'sync_id = ?',
      whereArgs: ['hj-1'],
    ))
        .single;
    expect(row['harga_jual'], 5000);

    final staleEnvelope = await makeEnvelope(
      entity: 'harga_jasa',
      action: 'upsert',
      entityId: 'hj-1',
      wall: 50,
      idempotencyKey: 'idem-owner-lama',
      payload: {
        'sync_id': 'hj-1',
        'nama': 'Cuci radiator',
        'harga_jual': 1000,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    await SyncService.instance.applyOnceForTest(
      envelope: staleEnvelope,
      senderKey: signing.publicKey,
      senderKind: 'owner',
      storeKey: storeKey,
      storeId: 'utama',
    );
    row = (await db.db.query(
      'harga_jasa',
      where: 'sync_id = ?',
      whereArgs: ['hj-1'],
    ))
        .single;
    expect(row['harga_jual'], 5000);
  });

  test('viewer dan karyawan tidak dapat menerapkan entity terlarang',
      () async {
    Future<bool> apply(Map<String, Object?> envelope, String kind) {
      return SyncService.instance.applyOnceForTest(
        envelope: envelope,
        senderKey: signing.publicKey,
        senderKind: kind,
        storeKey: storeKey,
        storeId: 'utama',
      );
    }

    final viewer = await makeEnvelope(
      entity: 'customer',
      action: 'upsert',
      entityId: 'cust-viewer',
      idempotencyKey: 'idem-viewer',
      payload: {
        'sync_id': 'cust-viewer',
        'nama': 'Viewer',
        'nomor_hp': '0812',
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    expect(await apply(viewer, 'viewer'), isTrue);
    expect(
      await db.db.query(
        'customers',
        where: 'sync_id = ?',
        whereArgs: ['cust-viewer'],
      ),
      isEmpty,
    );
    expect(
      await db.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['peran_viewer_hanya_baca'],
      ),
      isNotEmpty,
    );

    final salary = await makeEnvelope(
      entity: 'salary',
      action: 'upsert',
      entityId: 'sal-1',
      idempotencyKey: 'idem-salary',
      payload: {'sync_id': 'sal-1'},
    );
    expect(await apply(salary, 'employee'), isTrue);
    expect(await db.db.query('salary_payments'), isEmpty);
    expect(
      await db.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['peran_tidak_berhak'],
      ),
      isNotEmpty,
    );

    final customer = await makeEnvelope(
      entity: 'customer',
      action: 'upsert',
      entityId: 'cust-employee',
      idempotencyKey: 'idem-customer-employee',
      payload: {
        'sync_id': 'cust-employee',
        'nama': 'Karyawan',
        'nomor_hp': '0813',
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    expect(await apply(customer, 'employee'), isTrue);
    expect(
      await db.db.query(
        'customers',
        where: 'sync_id = ?',
        whereArgs: ['cust-employee'],
      ),
      hasLength(1),
    );
  });

  test('kegagalan apply masuk inbox dengan backoff dan menahan cursor',
      () async {
    final envelope = await makeEnvelope(
      entity: 'unit',
      action: 'upsert',
      entityId: 'unit-tanpa-pelanggan',
      payload: {
        'sync_id': 'unit-tanpa-pelanggan',
        'customer_sync_id': 'pelanggan-belum-ada',
        'unit_type': 'MOBIL',
        'nopol': 'B 1 X',
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    );
    final stamp = DateTime.now().toIso8601String();
    final inboxId = await db.db.insert('sync_inbox', {
      'store_id': 'utama',
      'device_id': 'device-b',
      'relay_seq': 7,
      'envelope_id': envelope['id'] as String? ?? 'env-uji-1',
      'idempotency_key': envelope['idempotency_key'],
      'entity': 'unit',
      'entity_id': 'unit-tanpa-pelanggan',
      'envelope_json': jsonEncode(envelope),
      'last_error': '',
      'retry_count': 0,
      'next_retry_at': null,
      'status': 'pending',
      'created_at': stamp,
      'updated_at': stamp,
    });

    final first = await SyncService.instance.retryInboxForTest(
      store: 'utama',
      deviceId: 'device-b',
      storeKey: storeKey,
      keys: {'device-a': signing.publicKey},
      kinds: {'device-a': 'owner'},
    );
    expect(first.blockedSeq, 7);
    expect(first.failed, 0);
    expect(first.lastError, contains('pelanggan'));

    var inbox = (await db.db.query(
      'sync_inbox',
      where: 'id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(inbox['status'], 'pending');
    expect(inbox['retry_count'], 1);
    final firstDue = DateTime.parse(inbox['next_retry_at'] as String);
    expect(firstDue.isAfter(DateTime.now()), isTrue);

    final conflict = (await db.db.query(
      'sync_conflicts',
      where: 'inbox_id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(conflict['reason'], 'unit_butuh_customer');
    expect(conflict['status'], 'retrying');

    final notDueYet = await SyncService.instance.retryInboxForTest(
      store: 'utama',
      deviceId: 'device-b',
      storeKey: storeKey,
      keys: {'device-a': signing.publicKey},
      kinds: {'device-a': 'owner'},
    );
    expect(notDueYet.blockedSeq, 7);
    inbox = (await db.db.query(
      'sync_inbox',
      where: 'id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(inbox['retry_count'], 1);

    await db.db.update(
      'sync_inbox',
      {'next_retry_at': DateTime.now().subtract(const Duration(minutes: 1))
          .toIso8601String()},
      where: 'id = ?',
      whereArgs: [inboxId],
    );
    final second = await SyncService.instance.retryInboxForTest(
      store: 'utama',
      deviceId: 'device-b',
      storeKey: storeKey,
      keys: {'device-a': signing.publicKey},
      kinds: {'device-a': 'owner'},
    );
    expect(second.blockedSeq, 7);
    inbox = (await db.db.query(
      'sync_inbox',
      where: 'id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(inbox['retry_count'], 2);
    final secondDue = DateTime.parse(inbox['next_retry_at'] as String);
    expect(
      secondDue.difference(DateTime.now()),
      greaterThan(const Duration(minutes: 3)),
    );

    await db.db.update(
      'sync_inbox',
      {
        'retry_count': 7,
        'next_retry_at': DateTime.now().subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [inboxId],
    );
    final exhausted = await SyncService.instance.retryInboxForTest(
      store: 'utama',
      deviceId: 'device-b',
      storeKey: storeKey,
      keys: {'device-a': signing.publicKey},
      kinds: {'device-a': 'owner'},
    );
    expect(exhausted.failed, 1);
    inbox = (await db.db.query(
      'sync_inbox',
      where: 'id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(inbox['status'], 'failed');
    final failedConflict = (await db.db.query(
      'sync_conflicts',
      where: 'inbox_id = ?',
      whereArgs: [inboxId],
    ))
        .single;
    expect(failedConflict['status'], 'failed');
  });

  test('data dan outbox ditulis atomik saat enqueue gagal', () async {
    await expectLater(
      db.db.transaction((txn) async {
        await txn.insert('customers', {
          'sync_id': 'cust-rollback',
          'nama': 'Rollback',
          'nomor_hp': '081200000022',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
        await SyncService.instance.enqueue(
          txn: txn,
          entity: 'customer',
          action: 'upsert',
          entityId: 'cust-rollback',
          payload: {'tidak_bisa': Object()},
        );
      }),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(
      await db.db.query(
        'customers',
        where: 'sync_id = ?',
        whereArgs: ['cust-rollback'],
      ),
      isEmpty,
    );
    expect(await db.db.query('sync_outbox'), isEmpty);
  });

  test('outbox tetap ada setelah database dibuka ulang', () async {
    await db.db.transaction((txn) async {
      await txn.insert('customers', {
        'sync_id': 'cust-persist',
        'nama': 'Persist',
        'nomor_hp': '081200000033',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await SyncService.instance.enqueue(
        txn: txn,
        entity: 'customer',
        action: 'upsert',
        entityId: 'cust-persist',
        payload: {'sync_id': 'cust-persist'},
      );
    });
    await db.reopen();
    final outbox = await db.db.query('sync_outbox');
    expect(outbox.length, 1);
    expect(outbox.single['entity'], 'customer');
    expect(outbox.single['status'], 'pending');
  });

  test('dua syncNow paralel berbagi satu putaran', () async {
    final first = SyncService.instance.syncNow();
    final second = SyncService.instance.syncNow();
    expect(identical(first, second), isTrue);
    await first.then((_) {}, onError: (_) {});
  });

  test('backoff tumbuh eksponensial dan dibatasi', () {
    expect(SyncConflictRules.backoffFor(1), const Duration(minutes: 2));
    expect(SyncConflictRules.backoffFor(2), const Duration(minutes: 4));
    expect(SyncConflictRules.backoffFor(3), const Duration(minutes: 8));
    expect(SyncConflictRules.backoffFor(8), const Duration(minutes: 240));
    expect(SyncConflictRules.backoffFor(20), const Duration(minutes: 240));
  });
}
