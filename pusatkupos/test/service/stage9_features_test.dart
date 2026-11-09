import 'package:flutter_test/flutter_test.dart';

import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/feature_flags.dart';
import 'package:pusatkupos/data/order_service.dart';
import 'package:pusatkupos/data/supplier_service.dart';
import 'package:pusatkupos/sync/snapshot_sync.dart';

import '../support/test_harness.dart';

const _employee = Operator(
  kind: 'employee',
  role: 'SUPERVISOR',
  label: 'Supervisor Sari',
  permissions: {'buat_estimasi', 'buat_order', 'ubah_supplier'},
);

void main() {
  final harness = ServiceTestHarness();

  setUp(harness.setUp);
  tearDown(harness.tearDown);

  group('katalog dan cache fitur', () {
    test('fail-closed sebelum load dan mengenal fitur wajib', () {
      FeatureFlagsService.instance.resetForStore();
      expect(FeatureFlagsService.instance.isEnabled(featureEstimasi), isFalse);
      expect(FeatureFlagsService.instance.isEnabled('tidak_ada'), isFalse);
      expect(FeatureCatalog.definition(featureEstimasi)?.label, 'Estimasi');
      expect(FeatureCatalog.isRequired(featureEstimasi), isFalse);
      expect(FeatureCatalog.childrenOf(featureSupplierHub).single.key,
          featurePurchaseDebt);
    });

    test('load memakai default katalog bila belum ada baris', () async {
      await FeatureFlagsService.instance.load();
      for (final feature in FeatureCatalog.items) {
        expect(
          FeatureFlagsService.instance.isEnabled(feature.key),
          feature.defaultEnabled,
          reason: feature.key,
        );
      }
    });

    test('setEnabled hanya pemilik dan tercatat di feature_audits', () async {
      await expectLater(
        FeatureFlagsService.instance.setEnabled(
          key: featureEstimasi,
          enabled: false,
          actor: _employee,
        ),
        throwsA(isA<StateError>()),
      );
      await FeatureFlagsService.instance.setEnabled(
        key: featureEstimasi,
        enabled: false,
        actor: Operator.owner,
        reason: 'uji',
      );
      expect(FeatureFlagsService.instance.isEnabled(featureEstimasi), isFalse);
      final audit = await harness.db.query('feature_audits');
      expect(audit, hasLength(1));
      expect(audit.single['feature_key'], featureEstimasi);
      expect(audit.single['before_enabled'], 1);
      expect(audit.single['after_enabled'], 0);
      expect(audit.single['actor'], 'Pemilik');
      expect(audit.single['reason'], 'uji');
      final history = await FeatureFlagsService.instance.history();
      expect(history, hasLength(1));
      // Data lain tidak dihapus saat fitur dimatikan.
      final rows = await harness.db.query('store_features');
      expect(rows.single['enabled'], 0);
    });
  });

  group('dependensi fitur', () {
    test('anak tidak dapat dinyalakan tanpa induk', () async {
      await FeatureFlagsService.instance.setEnabled(
        key: featureSupplierHub,
        enabled: false,
        actor: Operator.owner,
      );
      await expectLater(
        FeatureFlagsService.instance.setEnabled(
          key: featurePurchaseDebt,
          enabled: true,
          actor: Operator.owner,
        ),
        throwsStateError,
      );
    });
  });

  group('service menegakkan gate fitur', () {
    test('estimasi, order kerja, unit, dan supplier ditolak saat OFF',
        () async {
      await FeatureFlagsService.instance.setEnabled(
        key: featureEstimasi,
        enabled: false,
        actor: Operator.owner,
      );
      await FeatureFlagsService.instance.setEnabled(
        key: featureOrderKerja,
        enabled: false,
        actor: Operator.owner,
      );
      await FeatureFlagsService.instance.setEnabled(
        key: featureUnitKendaraan,
        enabled: false,
        actor: Operator.owner,
      );
      await FeatureFlagsService.instance.setEnabled(
        key: featureSupplierHub,
        enabled: false,
        actor: Operator.owner,
      );

      await expectLater(
        OrderService.instance.createEstimate(
          items: const [],
          actor: Operator.owner,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        OrderService.instance.createWorkOrder(
          keluhan: 'Servis',
          actor: Operator.owner,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => AppDatabase.instance.addUnit(customerId: null),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        SupplierService.instance
            .saveSupplier(nama: 'Toko A', actor: Operator.owner),
        throwsA(isA<StateError>()),
      );
    });

    test('service kembali berjalan setelah fitur diaktifkan', () async {
      await FeatureFlagsService.instance.setEnabled(
        key: featureSupplierHub,
        enabled: false,
        actor: Operator.owner,
      );
      await FeatureFlagsService.instance.setEnabled(
        key: featureSupplierHub,
        enabled: true,
        actor: Operator.owner,
      );
      final id = await SupplierService.instance
          .saveSupplier(nama: 'Toko B', actor: Operator.owner);
      expect(id, greaterThan(0));
    });
  });

  group('delta remote', () {
    test('histori diterima, dokumen baru ditahan saat fitur OFF', () async {
      await FeatureFlagsService.instance.setEnabled(
        key: featureEstimasi,
        enabled: false,
        actor: Operator.owner,
      );
      final txn = harness.db;
      expect(
        await FeatureGate.acceptsRemote(
          txn,
          featureEstimasi,
          '2020-01-01T00:00:00.000Z',
        ),
        isTrue,
      );
      expect(
        await FeatureGate.acceptsRemote(
          txn,
          featureEstimasi,
          '2999-01-01T00:00:00.000Z',
        ),
        isFalse,
      );
    });
  });

  test('snapshot membawa status fitur', () async {
    await FeatureFlagsService.instance.setEnabled(
      key: featureEstimasi,
      enabled: false,
      actor: Operator.owner,
    );
    final tables = await snapshotSharedTableOrder(harness.db);
    expect(tables, contains('store_features'));
    expect(tables, contains('feature_audits'));
    expect(snapshotLocalTables, isNot(contains('store_features')));
  });

  test('applyRemote memperbarui baris fitur yang sudah ada', () async {
    await FeatureFlagsService.instance.setEnabled(
      key: featureEstimasi,
      enabled: false,
      actor: Operator.owner,
    );
    await FeatureFlagsService.instance.applyRemote(
      harness.db,
      {
        'store_id': 'utama',
        'feature_key': featureEstimasi,
        'sync_id': 'feature-remote',
        'device_id': 'dev-remote',
        'enabled': true,
        'version': 2,
        'updated_by': 'Pemilik',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
      wall: 9999999999999,
      counter: 0,
    );
    expect(FeatureFlagsService.instance.isEnabled(featureEstimasi), isTrue);
    final rows = await harness.db.query('store_features');
    expect(rows, hasLength(1));
    expect(rows.single['enabled'], 1);
    expect(rows.single['sync_id'], 'feature-remote');
  });
}
