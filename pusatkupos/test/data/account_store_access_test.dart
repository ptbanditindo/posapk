import 'package:flutter_test/flutter_test.dart';

import 'package:pusatkupos/data/account_service.dart';

import '../support/test_harness.dart';

void main() {
  final harness = ServiceTestHarness();

  setUp(harness.setUp);
  tearDown(harness.tearDown);

  test('keanggotaan toko hanya dibaca dari employee_store_access', () async {
    final db = harness.db;
    await db.insert('employee_accounts', {
      'sync_id': 'emp-1',
      'username': 'budi',
      'nama': 'Budi',
      'password_hash': 'hash',
      'password_salt': 'salt',
      'created_at': '2024-01-01T00:00:00.000Z',
      'updated_at': '2024-01-01T00:00:00.000Z',
    });
    await db.insert('employee_accounts', {
      'sync_id': 'emp-2',
      'username': 'sari',
      'nama': 'Sari',
      'password_hash': 'hash',
      'password_salt': 'salt',
      'created_at': '2024-01-01T00:00:00.000Z',
      'updated_at': '2024-01-01T00:00:00.000Z',
    });
    Future<void> access(String syncId, String storeId, {int aktif = 1}) {
      return db.insert('employee_store_access', {
        'sync_id': 'access-$syncId-$storeId',
        'store_id': storeId,
        'employee_sync_id': syncId,
        'aktif': aktif,
        'created_at': '2024-01-01T00:00:00.000Z',
        'updated_at': '2024-01-01T00:00:00.000Z',
      });
    }

    await access('emp-1', 'toko-a');
    await access('emp-1', 'toko-b');
    await access('emp-1', 'toko-c', aktif: 0);

    expect(await AccountService.instance.storeIdsFor('emp-1'), [
      'toko-a',
      'toko-b',
    ]);
    expect(await AccountService.instance.storeIdsFor('emp-2'), isEmpty);
    expect(await AccountService.instance.storeIdsFor(''), isEmpty);

    final accounts = await AccountService.instance.listAccounts();
    final bySync = {for (final row in accounts) '${row['sync_id']}': row};
    expect(bySync['emp-1']!['store_ids'], ['toko-a', 'toko-b']);
    expect(bySync['emp-2']!['store_ids'], isEmpty);
  });
}
