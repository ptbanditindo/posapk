import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/data/nota_adjustment_service.dart';
import 'package:pusatkupos/data/order_service.dart';
import 'package:pusatkupos/data/pin_service.dart';
import 'package:pusatkupos/data/price_rules.dart';
import 'package:pusatkupos/data/secure_store.dart';
import 'package:pusatkupos/data/store_settings.dart';
import 'package:pusatkupos/sync/crypto.dart';
import 'package:pusatkupos/sync/protocol.dart';
import 'package:pusatkupos/sync/sync_service.dart';

const _kasir = Operator(
  kind: 'employee',
  role: 'KASIR',
  label: 'Kasir Uji',
  permissions: {'diskon'},
);

const _mekanik = Operator(
  kind: 'employee',
  role: 'MEKANIK',
  label: 'Mekanik Uji',
  permissions: {},
);

Matcher _violation(String code) =>
    isA<PriceRuleViolation>().having((error) => error.code, 'kode', code);

void main() {
  SecureStore.useMemoryForTests = true;

  final db = AppDatabase.instance;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_stage3_');
    await db.initForTest(p.join(dir.path, 'stage3.db'));
  });

  tearDown(() async {
    await PinService.instance.clear();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<int> seedUnit({String phone = '081300000001'}) async {
    final customerId = await db.addCustomer(
      nama: 'Pelanggan Uji',
      nomorHp: phone,
    );
    return db.addUnit(
      customerId: customerId,
      unitType: 'MOBIL',
      nopol: 'B 3 UJI',
    );
  }

  Future<StoreSettings> saveSettings({
    bool? approvalDiscount,
    String? approverMode,
    String? approverEmployeeSyncId,
    bool? simpanEstimasiLepas,
    Map<String, Map<String, bool>>? rolePermissions,
  }) async {
    final current = await StoreSettingsService.instance.ensure();
    return StoreSettingsService.instance.save(
      settings: StoreSettings(
        storeId: current.storeId,
        syncId: current.syncId,
        types: current.types,
        stages: current.stages,
        simpanEstimasiLepas: simpanEstimasiLepas ?? current.simpanEstimasiLepas,
        approvalDiscount: approvalDiscount ?? current.approvalDiscount,
        vehicleRequired: current.vehicleRequired,
        approverMode: approverMode ?? current.approverMode,
        approverEmployeeSyncId:
            approverEmployeeSyncId ?? current.approverEmployeeSyncId,
        rolePermissions: rolePermissions ?? current.rolePermissions,
        preset: current.preset,
        syncHlcWall: current.syncHlcWall,
        syncHlcCounter: current.syncHlcCounter,
      ),
      actor: Operator.owner,
    );
  }

  Future<void> enableFullPreset() async {
    final current = await StoreSettingsService.instance.ensure();
    await StoreSettingsService.instance.save(
      settings: presetSettings(
        storeId: current.storeId,
        syncId: current.syncId,
        preset: presetOrderLengkap,
      ),
      actor: Operator.owner,
    );
  }

  test(
    'diskon dialokasikan proporsional dan sisa pembulatan ke baris akhir',
    () {
      final lines = [
        PriceLine(
          jenis: 'jasa',
          label: 'A',
          jumlah: 1,
          hargaTerdaftar: 3333,
          hargaModal: 1000,
        ),
        PriceLine(
          jenis: 'jasa',
          label: 'B',
          jumlah: 1,
          hargaTerdaftar: 6667,
          hargaModal: 1000,
        ),
      ];
      final result = PriceRules.allocate(lines, diskonCents: 1000);
      expect(result.bruto, 10000);
      expect(result.diskon, 1000);
      expect(result.total, 9000);
      expect(
        result.lines.fold<int>(0, (sum, line) => sum + line.diskonAlokasi),
        1000,
      );
      expect(result.belowMinimum, isFalse);
    },
  );

  test('batas modal mutlak dan diskon maksimal selisih modal', () {
    PriceLine line({int harga = 7000000, int modal = 5000000}) => PriceLine(
      jenis: 'jasa',
      label: 'Jasa',
      jumlah: 1,
      hargaTerdaftar: harga,
      hargaModal: modal,
    );

    final fullMargin = PriceRules.allocate(
      [line()],
      diskonCents: 2000000,
    );
    expect(fullMargin.total, 5000000);
    expect(fullMargin.lines.single.hargaFinal, 5000000);
    expect(fullMargin.belowMinimum, isFalse);

    expect(
      () => PriceRules.allocate([line()], diskonCents: 2000001),
      throwsA(_violation('diskon_melebihi_margin')),
    );
    expect(
      () => PriceRules.allocate([line()], diskonCents: 3000000),
      throwsA(_violation('diskon_melebihi_margin')),
    );
    expect(
      () => PriceRules.allocate(
        [line(harga: 4999999)],
        diskonCents: 0,
      ),
      throwsA(_violation('di_bawah_batas_minimal')),
    );

    final owner = PriceRules.allocate(
      [line()],
      diskonCents: 3000000,
      allowBelowMinimum: true,
      disetujuiOleh: 'Pemilik (PIN)',
    );
    expect(owner.belowMinimum, isTrue);
    expect(owner.total, 4000000);
    expect(owner.lines.single.disetujuiOleh, 'Pemilik (PIN)');

    expect(
      () => PriceRules.validateCorrection(
        modalTotal: 10000,
        nilaiBaru: 9000,
        ownerApproved: false,
      ),
      throwsA(_violation('di_bawah_batas_minimal')),
    );
    PriceRules.validateCorrection(
      modalTotal: 10000,
      nilaiBaru: 9000,
      ownerApproved: true,
    );
    expect(
      () => PriceRules.validateCorrection(
        modalTotal: 10000,
        nilaiBaru: -1,
        ownerApproved: true,
      ),
      throwsA(_violation('nilai_koreksi_negatif')),
    );
  });

  test(
    'kasir tidak dapat melewati modal dan diskon maksimal selisih modal',
    () async {
      final unitId = await seedUnit();
      final settings = await StoreSettingsService.instance.ensure();
      expect(settings.approvalDiscount, isFalse);

      Future<int> create({
        int harga = 7000000,
        int modal = 5000000,
        int diskon = 0,
        String? ownerPin,
      }) => db.createTransaction(
        unitId: unitId,
        keluhan: 'Aturan modal',
        jobs: [
          JobDraft(
            deskripsi: 'Jasa',
            jumlah: 1,
            hargaCents: harga,
            modalCents: modal,
          ),
        ],
        parts: const [],
        diskonCents: diskon,
        metodeBayar: 'CASH',
        bayarCents: harga - diskon,
        actor: _kasir,
        ownerPin: ownerPin,
      );

      await expectLater(
        create(harga: 4999999),
        throwsA(_violation('di_bawah_batas_minimal')),
      );
      await expectLater(
        create(diskon: 2000001),
        throwsA(_violation('diskon_melebihi_margin')),
      );

      final recordId = await create(diskon: 2000000);
      final job = (await db.db.query('service_jobs')).single;
      expect(job['harga_jual_terdaftar'], 7000000);
      expect(job['harga_batas_saat_transaksi'], 5000000);
      expect(job['harga_final'], 5000000);
      expect(job['diskon_alokasi'], 2000000);
      final record = await db.recordDetail(recordId);
      expect(record!.record.totalCents, 5000000);

      final audits = await db.db.query(
        'permission_audits',
        where: 'action = ?',
        whereArgs: ['diskon'],
      );
      expect(audits, hasLength(1));
      final detail = jsonDecode(audits.single['detail_json']! as String) as Map;
      expect(detail['diskon'], 2000000);
      expect(detail['di_bawah_modal'], isFalse);

      await saveSettings(approvalDiscount: true);
      await PinService.instance.setup('123456');
      await expectLater(
        create(diskon: 2000001, ownerPin: '123456'),
        throwsA(_violation('diskon_melebihi_margin')),
      );
      await expectLater(
        create(harga: 4500000, ownerPin: '123456'),
        throwsA(_violation('di_bawah_batas_minimal')),
      );
    },
  );

  test(
    'saklar persetujuan hidup: PIN pemilik wajib untuk setiap diskon kasir',
    () async {
      await saveSettings(approvalDiscount: true);
      await PinService.instance.setup('123456');
      final unitId = await seedUnit();

      Future<int> create({
        String? ownerPin,
        int diskon = 2000000,
        int harga = 7000000,
      }) => db.createTransaction(
        unitId: unitId,
        keluhan: 'Butuh persetujuan',
        jobs: [
          JobDraft(
            deskripsi: 'Jasa mahal',
            jumlah: 1,
            hargaCents: harga,
            modalCents: 5000000,
          ),
        ],
        parts: const [],
        diskonCents: diskon,
        metodeBayar: 'CASH',
        bayarCents: harga - diskon,
        actor: _kasir,
        ownerPin: ownerPin,
      );

      await expectLater(create(), throwsA(isA<StateError>()));
      await expectLater(
        create(ownerPin: '000000'),
        throwsA(_violation('persetujuan_gagal')),
      );
      final recordId = await create(ownerPin: '123456');
      final job = (await db.db.query('service_jobs')).single;
      expect(job['harga_final'], 5000000);
      final audit = await db.db.query(
        'permission_audits',
        where: 'action = ?',
        whereArgs: ['diskon'],
      );
      expect(audit, hasLength(1));
      final detail = jsonDecode(audit.single['detail_json']! as String) as Map;
      expect(detail['disetujui_oleh'], 'Pemilik (PIN)');
      expect(recordId, isPositive);
    },
  );

  test(
    'penanggung jawab yang ditunjuk dapat menyetujui diskon dalam batas modal',
    () async {
      const approverSyncId = 'akun-penanggung-jawab-1';
      const pin = '246810';
      const salt = 'c2FsdC1wZW5hbmdndW5nLWphd2FiLTE=';
      final key =
          await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: 1000,
            bits: 256,
          ).deriveKey(
            secretKey: SecretKey(utf8.encode(pin)),
            nonce: base64Url.decode(salt),
          );
      final now = nowIso();
      await db.db.insert('employee_accounts', {
        'sync_id': approverSyncId,
        'username': 'siti.pj',
        'nama': 'Siti',
        'role_base': 'KASIR',
        'password_hash': 'x',
        'password_salt': 'y',
        'password_iterations': 1000,
        'pin_hash': base64UrlEncode(await key.extractBytes()),
        'pin_salt': salt,
        'pin_iterations': 1000,
        'must_change_password': 0,
        'aktif': 1,
        'created_at': now,
        'updated_at': now,
      });
      final base = await StoreSettingsService.instance.ensure();
      final rolePermissions = {
        ...base.rolePermissions,
        'KASIR': {
          ...(base.rolePermissions['KASIR'] ?? const <String, bool>{}),
          'setujui': true,
        },
      };
      final saved = await saveSettings(
        approvalDiscount: true,
        approverMode: approverEmployee,
        approverEmployeeSyncId: approverSyncId,
        rolePermissions: rolePermissions,
      );
      expect(saved.roleAllows('KASIR', 'setujui'), isTrue);

      final unitId = await seedUnit();
      Future<int> create({
        required String secret,
        int harga = 7000000,
        int diskon = 2000000,
      }) => db.createTransaction(
        unitId: unitId,
        keluhan: 'Persetujuan penanggung jawab',
        jobs: [
          JobDraft(
            deskripsi: 'Jasa khusus',
            jumlah: 1,
            hargaCents: harga,
            modalCents: 5000000,
          ),
        ],
        parts: const [],
        diskonCents: diskon,
        metodeBayar: 'CASH',
        bayarCents: harga - diskon,
        actor: _kasir,
        approverSecret: secret,
      );

      final recordId = await create(secret: pin);
      final job = (await db.db.query('service_jobs')).single;
      expect(job['harga_final'], 5000000);
      final audit = await db.db.query(
        'permission_audits',
        where: 'action = ?',
        whereArgs: ['diskon'],
      );
      final detail = jsonDecode(audit.single['detail_json']! as String) as Map;
      expect(detail['disetujui_oleh'], 'Siti (Penanggung jawab)');
      expect(recordId, isPositive);

      await expectLater(
        create(secret: '999999'),
        throwsA(_violation('persetujuan_gagal')),
      );
      await expectLater(
        create(secret: pin, harga: 4500000, diskon: 0),
        throwsA(_violation('di_bawah_batas_minimal')),
      );
      await expectLater(
        create(secret: pin, diskon: 2000001),
        throwsA(_violation('diskon_melebihi_margin')),
      );
    },
  );

  test(
    'snapshot harga baris tetap dan koreksi nota bersifat append-only',
    () async {
      final stockId = await db.saveStockItem(
        kode: 'SP-SNAP',
        nama: 'Radiator',
        hargaModalCents: 6000000,
        hargaJualCents: 10000000,
        jumlah: 5,
        stokMinimum: 0,
      );
      final item = (await db.listStock()).single;
      final unitId = await seedUnit();
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Snapshot harga',
        jobs: const [],
        parts: [
          PartDraft(
            stockItemId: stockId,
            nama: item.nama,
            jumlah: 2,
            hargaCents: item.hargaJualCents,
            modalCents: item.hargaModalCents,
          ),
        ],
        diskonCents: 9000000,
        metodeBayar: 'CASH',
        bayarCents: 11000000,
        actor: Operator.owner,
      );
      final part = (await db.db.query('service_parts')).single;
      expect(part['harga_jual_terdaftar'], 10000000);
      expect(part['harga_batas_saat_transaksi'], 6000000);
      expect(part['harga_final'], 5500000);
      expect(part['diskon_alokasi'], 9000000);
      expect(part['subtotal'], 20000000);

      await db.saveStockItem(
        id: stockId,
        kode: 'SP-SNAP',
        nama: 'Radiator',
        hargaModalCents: 8000000,
        hargaJualCents: 12000000,
        jumlah: 3,
        stokMinimum: 0,
      );
      final after = (await db.db.query('service_parts')).single;
      expect(after['harga_jual_terdaftar'], 10000000);
      expect(after['harga_batas_saat_transaksi'], 6000000);
      expect(after['harga_final'], 5500000);

      final record = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      )).single;
      final notaSyncId = record['sync_id'] as String;
      expect(record['total_servis'], 11000000);

      await NotaAdjustmentService.instance.create(
        notaSyncId: notaSyncId,
        nilaiBaru: 8000000,
        alasan: 'Potongan pelanggan',
        actor: Operator.owner,
      );
      await NotaAdjustmentService.instance.create(
        notaSyncId: notaSyncId,
        nilaiBaru: 7000000,
        alasan: 'Koreksi kedua',
        actor: Operator.owner,
      );
      final adjustments = await NotaAdjustmentService.instance.listForNota(
        notaSyncId,
      );
      expect(adjustments, hasLength(2));
      expect(adjustments.map((row) => row.nilaiSelisih).toList(), [
        -3000000,
        -1000000,
      ]);
      expect(
        await NotaAdjustmentService.instance.adjustedTotal(recordId),
        7000000,
      );
      final unchanged = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      )).single;
      expect(unchanged['total_servis'], 11000000);
      final audits = await db.db.query(
        'permission_audits',
        where: 'action = ?',
        whereArgs: ['koreksi_nota'],
      );
      expect(audits, hasLength(2));

      await expectLater(
        NotaAdjustmentService.instance.create(
          notaSyncId: notaSyncId,
          nilaiBaru: 6500000,
          alasan: 'Coba kasir',
          actor: _kasir,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('estimasi berversi, konversi ke nota, dan laporan selisih', () async {
    await enableFullPreset();
    final unitId = await seedUnit();

    final first = await OrderService.instance.createEstimate(
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Servis berkala',
          jumlah: 1,
          hargaCents: 10000000,
          modalCents: 5000000,
        ),
      ],
      actor: _kasir,
    );
    expect(first, isNotNull);
    expect(first!.nomorEstimasi, contains('-E'));
    expect(first.versi, 1);
    expect(first.totalCents, 10000000);
    expect(first.status, 'aktif');
    expect(first.dibuatOleh, 'Kasir Uji');

    final revision = await OrderService.instance.createEstimate(
      unitId: unitId,
      revisiDariSyncId: first.syncId,
      alasanRevisi: 'Harga disesuaikan',
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Servis berkala',
          jumlah: 1,
          hargaCents: 8000000,
          modalCents: 5000000,
        ),
      ],
      actor: _kasir,
    );
    expect(revision, isNotNull);
    expect(revision!.nomorEstimasi, first.nomorEstimasi);
    expect(revision.versi, 2);
    expect(revision.revisiDariSyncId, first.syncId);
    expect(revision.totalCents, 8000000);
    final revisedBase = (await db.db.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [first.syncId],
      limit: 1,
    )).single;
    expect(revisedBase['status'], 'direvisi');

    final pending = await OrderService.instance.unconvertedByCashier();
    expect(pending, hasLength(1));
    expect(pending.single['kasir'], 'Kasir Uji');
    expect(pending.single['jumlah'], 1);
    expect((pending.single['nilai'] as num).toInt(), 8000000);

    final recordId = await OrderService.instance.convertEstimateToNote(
      estimateSyncId: revision.syncId,
      metodeBayar: 'CASH',
      bayarCents: 8000000,
      actor: _kasir,
    );
    final nota = (await db.db.query(
      'service_records',
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    )).single;
    expect(nota['jenis_transaksi'], transactionOrderKerja);
    expect(nota['estimate_sync_id'], revision.syncId);
    expect(nota['total_estimasi_terakhir'], 8000000);
    expect(nota['total_servis'], 8000000);
    expect(nota['created_by'], 'Kasir Uji');

    final converted = (await db.db.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [revision.syncId],
      limit: 1,
    )).single;
    expect(converted['status'], 'dikonversi');
    expect(converted['converted_nota_sync_id'], nota['sync_id']);
    expect(converted['total_estimasi_terakhir'], 8000000);

    final rows = await OrderService.instance.listEstimateRows();
    final revisionRow = rows.firstWhere(
      (row) => row['sync_id'] == revision.syncId,
    );
    expect(revisionRow['nota_total'], 8000000);
    expect(revisionRow['nota_nomor'], isNotEmpty);

    final variance = await OrderService.instance.varianceReport(
      from: DateTime.now().subtract(const Duration(days: 1)),
      to: DateTime.now().add(const Duration(days: 1)),
    );
    expect(variance, hasLength(1));
    expect(variance.single['total_estimasi_terakhir'], 8000000);
    expect(variance.single['selisih'], 0);

    expect(await OrderService.instance.unconvertedByCashier(), isEmpty);
    await expectLater(
      OrderService.instance.convertEstimateToNote(
        estimateSyncId: revision.syncId,
        metodeBayar: 'CASH',
        bayarCents: 8000000,
        actor: _kasir,
      ),
      throwsA(isA<StateError>()),
    );

    await saveSettings(simpanEstimasiLepas: false);
    final unsaved = await OrderService.instance.createEstimate(
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Baru dicetak',
          jumlah: 1,
          hargaCents: 1000000,
          modalCents: 500000,
        ),
      ],
      actor: _kasir,
    );
    expect(unsaved, isNull);
  });

  test('estimasi memakai batas modal dan margin yang sama', () async {
    await enableFullPreset();
    final unitId = await seedUnit();

    Future<EstimateRecord?> create({
      int harga = 7000000,
      int diskon = 0,
      String? ownerPin,
    }) => OrderService.instance.createEstimate(
      unitId: unitId,
      items: [
        EstimateItemInput(
          jenis: 'jasa',
          deskripsi: 'Servis',
          jumlah: 1,
          hargaCents: harga,
          modalCents: 5000000,
        ),
      ],
      diskonCents: diskon,
      actor: _kasir,
      ownerPin: ownerPin,
    );

    await expectLater(
      create(harga: 4500000),
      throwsA(_violation('di_bawah_batas_minimal')),
    );
    await expectLater(
      create(diskon: 2000001),
      throwsA(_violation('diskon_melebihi_margin')),
    );
    final estimate = await create(diskon: 2000000);
    expect(estimate!.totalCents, 5000000);

    await saveSettings(approvalDiscount: true);
    await PinService.instance.setup('123456');
    await expectLater(create(diskon: 2000000), throwsA(isA<StateError>()));
    final approved = await create(diskon: 2000000, ownerPin: '123456');
    expect(approved!.totalCents, 5000000);
  });

  test(
    'order kerja memakai nomor, antrean, dan log status append-only',
    () async {
      await enableFullPreset();
      final unitId = await seedUnit();
      final order = await OrderService.instance.createWorkOrder(
        unitId: unitId,
        keluhan: 'Servis besar',
        enqueueStatus: (txn, syncId) async {},
      );
      expect(order.status, 'antri');
      expect(order.nomorOrder, contains('-WK'));
      expect(order.nomorAntrian, isNotNull);
      expect(order.nomorAntrian, isNotEmpty);
      expect(order.modeSaatDibuat['jenis_transaksi'], transactionOrderKerja);
      var log = await OrderService.instance.statusLog(order.syncId);
      expect(log.map((row) => row.status).toList(), ['antri']);
      final initialSyncId = log.single.syncId;

      await expectLater(
        OrderService.instance.changeStatus(
          workOrderSyncId: order.syncId,
          status: 'diagnosa',
          actor: _kasir,
        ),
        throwsA(isA<StateError>()),
      );

      await OrderService.instance.changeStatus(
        workOrderSyncId: order.syncId,
        status: 'diagnosa',
        actor: _mekanik,
      );
      log = await OrderService.instance.statusLog(order.syncId);
      expect(log.map((row) => row.status).toList(), ['antri', 'diagnosa']);

      await expectLater(
        OrderService.instance.changeStatus(
          workOrderSyncId: order.syncId,
          status: 'diambil',
          actor: _mekanik,
        ),
        throwsA(isA<StateError>()),
      );

      final finished = await OrderService.instance.changeStatus(
        workOrderSyncId: order.syncId,
        status: 'diambil',
        actor: Operator.owner,
      );
      expect(finished.status, 'diambil');
      log = await OrderService.instance.statusLog(order.syncId);
      expect(log.map((row) => row.status).toList(), [
        'antri',
        'diagnosa',
        'diambil',
      ]);
      expect(log.first.syncId, initialSyncId);
      final conflicts = await db.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['transisi_status_dilarang'],
      );
      expect(conflicts, hasLength(1));
      final detail =
          jsonDecode(conflicts.single['detail_json']! as String) as Map;
      expect(detail['dari'], 'diagnosa');
      expect(detail['ke'], 'diambil');
    },
  );

  test(
    'ringkasan harian berbeda dicatat sebagai konflik rekonsiliasi',
    () async {
      final now = DateTime.now();
      final tanggal =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await db.setSetting('sync.relay_device_id', 'device-local');
      final stamp = nowIso();
      await db.db.insert('day_digests', {
        'sync_id': 'digest-local',
        'store_id': 'utama',
        'device_id': 'device-local',
        'source_device_id': 'device-local',
        'tanggal': tanggal,
        'data_type': 'nota',
        'jumlah': 1,
        'hash': 'hash-lokal',
        'created_at': stamp,
        'updated_at': stamp,
      });

      final signing = await generateSigningKey();
      final storeKey = List<int>.generate(32, (index) => index + 5);
      final envelope = await buildEnvelope(
        devicePrivateKey: signing.privateKey,
        storeKey: storeKey,
        storeId: 'utama',
        senderDeviceId: 'device-remote',
        recipientDeviceId: '',
        seq: 2,
        hlcWall: 500,
        hlcCounter: 0,
        idempotencyKey: 'digest-remote-1',
        entity: 'day_digest',
        action: 'upsert',
        entityId: 'digest-remote',
        payload: {
          'sync_id': 'digest-remote',
          'source_device_id': 'device-remote',
          'tanggal': tanggal,
          'data_type': 'nota',
          'jumlah': 1,
          'hash': 'hash-remote',
          'created_at': stamp,
        },
      );
      final applied = await SyncService.instance.applyOnceForTest(
        envelope: envelope,
        senderKey: signing.publicKey,
        senderKind: 'owner',
        storeKey: storeKey,
        storeId: 'utama',
      );
      expect(applied, isTrue);
      final digest = (await db.db.query(
        'day_digests',
        where: 'sync_id = ?',
        whereArgs: ['digest-remote'],
        limit: 1,
      )).single;
      expect(digest['hash'], 'hash-remote');
      final conflicts = await db.db.query(
        'sync_conflicts',
        where: 'reason = ?',
        whereArgs: ['rekonsiliasi_beda'],
      );
      expect(conflicts, hasLength(1));
      final detail =
          jsonDecode(conflicts.single['detail_json']! as String) as Map;
      expect(detail['tanggal'], tanggal);
      expect(detail['lokal'], 'hash-lokal');
      expect(detail['remote'], 'hash-remote');
      final requests = await db.db.query(
        'reconciliation_requests',
        where: 'target_device_id = ?',
        whereArgs: ['device-remote'],
      );
      expect(requests, hasLength(1));
      expect(requests.single['tanggal'], tanggal);
    },
  );
}
