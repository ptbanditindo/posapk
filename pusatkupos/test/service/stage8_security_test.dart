import 'package:flutter_test/flutter_test.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/auth/permissions.dart';
import 'package:pusatkupos/data/account_service.dart';
import 'package:pusatkupos/data/owner_summary_service.dart';
import 'package:pusatkupos/data/supplier_service.dart';
import 'package:pusatkupos/sync/sync_conflict_rules.dart';

import '../support/test_harness.dart';

const _employee = Operator(
  kind: 'employee',
  role: 'KASIR',
  label: 'Kasir Budi',
  permissions: {'buat_nota'},
);

const _supplierEmployee = Operator(
  kind: 'employee',
  role: 'SUPERVISOR',
  label: 'Supervisor Sari',
  permissions: {'buat_nota', permissionSupplier},
);

const _viewer = Operator(
  kind: 'viewer',
  role: 'viewer',
  label: 'Ringkasan',
  permissions: {permissionSupplier, permissionManageAccounts},
);

void main() {
  group('Permissions menolak aktor tanpa hak', () {
    test('aktor null tidak memiliki izin', () {
      expect(Permissions.can(null, permissionSupplier), isFalse);
    });

    test('viewer selalu ditolak walau izin tercatat', () {
      expect(Permissions.can(_viewer, permissionSupplier), isFalse);
      expect(Permissions.can(_viewer, permissionManageAccounts), isFalse);
      expect(() => Permissions.require(_viewer, permissionSupplier),
          throwsStateError);
    });

    test('karyawan hanya memiliki izin yang diberikan', () {
      expect(Permissions.can(_employee, 'buat_nota'), isTrue);
      expect(Permissions.can(_employee, permissionSupplier), isFalse);
    });

    test('pemilik memiliki semua izin', () {
      expect(Permissions.can(Operator.owner, permissionSupplier), isTrue);
      expect(Permissions.can(Operator.owner, permissionManageAccounts), isTrue);
    });
  });

  final harness = ServiceTestHarness();

  setUp(harness.setUp);
  tearDown(harness.tearDown);

  group('SupplierService memeriksa aktor', () {
    test('karyawan tanpa ubah_supplier ditolak, dengan izin diterima', () async {
      await expectLater(
        SupplierService.instance
            .saveSupplier(nama: 'Toko A', actor: _employee),
        throwsA(isA<StateError>()),
      );
      final id = await SupplierService.instance
          .saveSupplier(nama: 'Toko A', actor: _supplierEmployee);
      expect(id, greaterThan(0));
      final rows = await harness.db.query('suppliers');
      expect(rows.single['nama'], 'Toko A');
    });

    test('viewer tidak dapat menyimpan maupun menghapus supplier', () async {
      await expectLater(
        SupplierService.instance
            .saveSupplier(nama: 'Toko B', actor: _viewer),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        SupplierService.instance.deleteSupplier(1, actor: _viewer),
        throwsA(isA<StateError>()),
      );
    });

    test('penghapusan dan relasi barang memakai izin yang sama', () async {
      final id = await SupplierService.instance
          .saveSupplier(nama: 'Toko C', actor: Operator.owner);
      await expectLater(
        SupplierService.instance.deleteSupplier(id, actor: _employee),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        SupplierService.instance
            .syncItemSuppliers(1, {id}, actor: _employee),
        throwsA(isA<StateError>()),
      );
      await SupplierService.instance.deleteSupplier(id, actor: Operator.owner);
      final rows = await harness.db.query('suppliers');
      expect(rows.single['deleted_at'], isNotNull);
      expect(rows.single['aktif'], 0);
    });
  });

  group('AccountService hanya untuk pemilik', () {
    Future<int> seedAccount() {
      return harness.db.insert('employee_accounts', {
        'sync_id': 'emp-stage8',
        'username': 'budi',
        'nama': 'Budi',
        'role_base': 'KASIR',
        'password_hash': 'hash',
        'password_salt': 'salt',
        'created_at': '2024-01-01T00:00:00.000Z',
        'updated_at': '2024-01-01T00:00:00.000Z',
      });
    }

    test('karyawan dan viewer tidak dapat mengubah akun', () async {
      final id = await seedAccount();
      await expectLater(
        AccountService.instance.updateAccount(
          id,
          nama: 'Budi',
          role: 'KASIR',
          aktif: true,
          actor: _employee,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        AccountService.instance.updateAccount(
          id,
          nama: 'Budi',
          role: 'KASIR',
          aktif: true,
          actor: _viewer,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('reset PIN oleh karyawan ditolak', () async {
      final id = await seedAccount();
      await expectLater(
        AccountService.instance.resetPin(id, actor: _employee),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        AccountService.instance.resetPin(id, actor: _viewer),
        throwsA(isA<StateError>()),
      );
      await AccountService.instance.resetPin(id, actor: Operator.owner);
      final rows = await harness.db.query('employee_accounts');
      expect(rows.single['pin_hash'], isNull);
    });
  });

  group('SyncConflictRules allow-list supplier', () {
    test('karyawan perlu izin ubah_supplier untuk delta supplier', () {
      const sender = SenderProfile(
        kind: 'employee',
        roleBase: 'KASIR',
        permissionsExplicit: true,
        extraPermissions: {'buat_nota'},
      );
      expect(
        SyncConflictRules.senderViolation(
          sender: sender,
          entity: 'supplier',
          action: 'upsert',
        ),
        'peran_tidak_berhak_$permissionSupplier',
      );

      const allowed = SenderProfile(
        kind: 'employee',
        roleBase: 'SUPERVISOR',
        permissionsExplicit: true,
        extraPermissions: {permissionSupplier},
      );
      expect(
        SyncConflictRules.senderViolation(
          sender: allowed,
          entity: 'supplier',
          action: 'upsert',
        ),
        isNull,
      );
    });

    test('viewer dan perangkat dicabut ditolak sebelum isi payload', () {
      const viewer = SenderProfile(kind: 'viewer');
      expect(
        SyncConflictRules.senderViolation(
          sender: viewer,
          entity: 'supplier',
          action: 'upsert',
        ),
        'peran_viewer_hanya_baca',
      );
      const revoked = SenderProfile(
        kind: 'employee',
        extraPermissions: {permissionSupplier},
        revoked: true,
      );
      expect(
        SyncConflictRules.senderViolation(
          sender: revoked,
          entity: 'supplier',
          action: 'upsert',
        ),
        'pengirim_dicabut',
      );
      expect(
        SyncConflictRules.senderViolation(
          sender: SenderProfile.legacy('owner'),
          entity: 'supplier',
          action: 'upsert',
        ),
        isNull,
      );
    });
  });

  group('OwnerSummaryService khusus pemilik', () {
    test('karyawan tidak dapat membuat atau mengekspor ringkasan', () async {
      await expectLater(
        OwnerSummaryService.instance.buildSignedSummary(actor: _employee),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        OwnerSummaryService.instance.export(actor: _employee, pin: '123456'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        OwnerSummaryService.instance.export(actor: _viewer, pin: '123456'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
