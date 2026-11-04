import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/followup_service.dart';
import 'package:pusatkupos/data/models.dart';

void main() {
  late Directory dir;
  late String dbPath;
  late AppDatabase db;
  final service = FollowupService.instance;
  var sequence = 0;
  final now = DateTime(2026, 11, 4, 10, 0);

  Future<void> clearData() async {
    for (final table in const [
      'wa_message_logs',
      'followup_events',
      'followup_items',
      'service_record_mechanics',
      'service_record_commissions',
      'service_payments',
      'service_jobs',
      'service_parts',
      'service_records',
      'vehicle_or_units',
      'customers',
    ]) {
      await db.db.delete(table);
    }
    await db.db.delete(
      'app_settings',
      where: "key LIKE 'ops.%' OR key LIKE 'followup.%'",
    );
  }

  Future<int> addNote({
    int? customerId,
    DateTime? day,
    int intervalBulan = 0,
    bool bergaransi = false,
    DateTime? garansiSampai,
    int total = 100000,
    int bayar = 100000,
    bool unitDitinggal = false,
    bool dnc = false,
    bool consent = true,
  }) async {
    sequence++;
    customerId ??= await db.addCustomer(
      nama: 'Pelanggan $sequence',
      nomorHp: '0812${sequence.toString().padLeft(8, '0')}',
      waConsent: consent,
      doNotContact: dnc,
    );
    final unitId = await db.addUnit(
      customerId: customerId,
      unitType: 'MOBIL',
      nopol: 'B $sequence',
      jenisMobil: 'Avanza',
    );
    final recordId = await db.createTransaction(
      unitId: unitId,
      keluhan: 'Uji follow up',
      jobs: [
        JobDraft(
          deskripsi: 'Servis radiator',
          jumlah: 1,
          hargaCents: total,
          intervalBulan: intervalBulan,
        ),
      ],
      parts: const [],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: bayar,
      bergaransi: bergaransi || garansiSampai != null,
      garansiSampai: garansiSampai,
      unitDitinggal: unitDitinggal,
    );
    if (day != null) {
      await db.db.update(
        'service_records',
        {
          'waktu_service': DateTime(
            day.year,
            day.month,
            day.day,
            9,
          ).toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [recordId],
      );
    }
    return recordId;
  }

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_followup_');
    dbPath = p.join(dir.path, 'followup.db');
    db = AppDatabase.instance;
    await db.initForTest(dbPath);
  });

  setUp(clearData);

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('prospek pasca servis muncul setelah 30 hari', () async {
    await addNote(day: now.subtract(const Duration(days: 40)));
    await service.syncItems(now: now);
    final items = await service.listItems(now: now);
    expect(items.length, 1);
    expect(items.single.jenis, 'prospek');
    expect(items.single.status, 'BARU');
    expect(items.single.sisaHari, -10);
    expect(items.single.terlambat, isTrue);
    expect(items.single.judul, contains('B $sequence'));
  });

  test('unit belum diambil jadi pengingat, arsip setelah diambil', () async {
    final recordId = await addNote(
      day: now.subtract(const Duration(days: 2)),
      unitDitinggal: true,
    );
    await service.syncItems(now: now);
    var items = await service.listItems(now: now);
    expect(items.single.jenis, 'unit_selesai');
    expect(items.single.bisaFollowup, isTrue);

    await db.db.update(
      'service_records',
      {'diambil_at': now.toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [recordId],
    );
    await service.syncItems(now: now);
    items = await service.listItems(now: now);
    expect(items, isEmpty);
    final archived =
        await service.listItems(filter: 'arsip', now: now);
    expect(archived.single.jenis, 'unit_selesai');
    expect(archived.single.alasanArsip, autoArchiveReason);
  });

  test('nota void tidak menghasilkan item dan mengarsipkan item aktif',
      () async {
    final recordId = await addNote(
      day: now.subtract(const Duration(days: 2)),
      unitDitinggal: true,
    );
    await service.syncItems(now: now);
    expect(await service.listItems(now: now), hasLength(1));

    await db.db.update(
      'service_records',
      {'status': 'VOID'},
      where: 'id = ?',
      whereArgs: [recordId],
    );
    await service.syncItems(now: now);
    expect(await service.listItems(now: now), isEmpty);
    final archived =
        await service.listItems(filter: 'arsip', now: now);
    expect(archived.single.alasanArsip, autoArchiveReason);
  });

  test('garansi mendekati habis memakai jatuh tempo H-7', () async {
    await addNote(
      day: now.subtract(const Duration(days: 10)),
      garansiSampai: now.add(const Duration(days: 5)),
    );
    await service.syncItems(now: now);
    final items = await service.listItems(now: now);
    expect(items.single.jenis, 'garansi');
    expect(items.single.sisaHari, -2);
    expect(items.single.judul, contains('Garansi'));
  });

  test('servis berkala dan piutang memakai interval serta jeda', () async {
    await addNote(
      day: now.subtract(const Duration(days: 200)),
      intervalBulan: 6,
    );
    await addNote(
      day: now.subtract(const Duration(days: 20)),
      bayar: 50000,
    );
    await service.syncItems(now: now);
    final items = await service.listItems(now: now);
    expect(
      items.map((row) => row.jenis).toSet(),
      containsAll(<String>['servis_berkala', 'piutang']),
    );
    final piutang = items.firstWhere((row) => row.jenis == 'piutang');
    expect(piutang.sisaBayar, 50000);
    expect(piutang.sisaHari, -6);
  });

  test('cooldown menahan follow up berulang', () async {
    await addNote(
      day: now.subtract(const Duration(days: 20)),
      bayar: 50000,
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;
    final attempt = await service.followUp(item.id, now: now);
    expect(attempt.link, contains('https://wa.me/62812'));
    expect(attempt.message, contains('sisa pembayaran nota'));
    expect(attempt.quota.used, 1);

    final updated = (await service.listItems(now: now)).single;
    expect(updated.status, 'SUDAH_FOLLOWUP');
    expect(updated.noResponseCount, 1);

    await expectLater(
      service.followUp(item.id, now: now.add(const Duration(days: 1))),
      throwsA(
        predicate(
          (error) => '$error'.contains('Jeda follow up'),
          'pesan cooldown',
        ),
      ),
    );
  });

  test('DNC memblokir pengingat non-piutang', () async {
    await addNote(
      day: now.subtract(const Duration(days: 40)),
      dnc: true,
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;
    expect(item.dnc, isTrue);
    expect(item.bisaFollowup, isFalse);
    expect(item.bisaAlasan, contains('DNC'));
    await expectLater(
      service.followUp(item.id, now: now),
      throwsA(
        predicate(
          (error) => '$error'.contains('DNC'),
          'pesan DNC',
        ),
      ),
    );
  });

  test('jam follow up membatasi tautan', () async {
    await addNote(day: now.subtract(const Duration(days: 40)));
    final settings = await service.loadSettings();
    await service.saveSettings(
      settings.copyWith(jamMulai: '08:00', jamSelesai: '20:00'),
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;
    final late = DateTime(2026, 11, 4, 21, 0);
    final rows = await service.listItems(now: late);
    expect(rows.single.bisaFollowup, isFalse);
    expect(rows.single.bisaAlasan, contains('08:00 - 20:00'));
    await expectLater(
      service.followUp(item.id, now: late),
      throwsA(
        predicate(
          (error) => '$error'.contains('08:00 - 20:00'),
          'pesan jam',
        ),
      ),
    );
  });

  test('kuota gratis 20 kredit bertahan setelah buka ulang database',
      () async {
    await addNote(
      day: now.subtract(const Duration(days: 20)),
      bayar: 50000,
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;

    await db.setSetting('followup.wa_used', '20');
    expect((await service.quotaStatus()).locked, isTrue);
    await expectLater(
      service.followUp(item.id, now: now),
      throwsA(
        predicate(
          (error) => '$error'.contains('Kuota Follow up'),
          'pesan kuota',
        ),
      ),
    );

    await db.setSetting('followup.wa_used', '19');
    final attempt = await service.followUp(item.id, now: now);
    expect(attempt.quota.used, 20);
    expect((await service.quotaStatus()).locked, isTrue);

    await db.initForTest(dbPath);
    final quota = await service.quotaStatus();
    expect(quota.used, 20);
    expect(quota.locked, isTrue);
  });

  test('pesan piutang digabung untuk pelanggan yang sama', () async {
    final customerId = await db.addCustomer(
      nama: 'Pelanggan Gabung',
      nomorHp: '081299990001',
    );
    await addNote(
      customerId: customerId,
      day: now.subtract(const Duration(days: 20)),
      bayar: 50000,
    );
    await addNote(
      customerId: customerId,
      day: now.subtract(const Duration(days: 25)),
      bayar: 25000,
      total: 75000,
    );
    await service.syncItems(now: now);
    final items = await service.listItems(now: now);
    expect(items, hasLength(2));
    final records = await db.db.query(
      'service_records',
      columns: ['no_nota'],
      where: 'id IN (?, ?)',
      whereArgs: [items[0].recordId, items[1].recordId],
    );
    final attempt = await service.followUp(items[0].id, now: now);
    expect(attempt.itemIds.length, 2);
    for (final row in records) {
      expect(attempt.message, contains(row['no_nota'] as String));
    }
    final logs = await db.db.query('wa_message_logs');
    expect(logs.length, 2);
  });

  test('transisi status wajib follow up dan tanggal', () async {
    await addNote(day: now.subtract(const Duration(days: 40)));
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;

    await expectLater(
      service.changeStatus(item.id, status: 'SELESAI', now: now),
      throwsA(
        predicate(
          (error) => '$error'.contains('Lakukan follow up'),
          'wajib follow up',
        ),
      ),
    );
    await service.followUp(item.id, now: now);
    await expectLater(
      service.changeStatus(item.id, status: 'AKAN_DATANG', now: now),
      throwsArgumentError,
    );
    await service.changeStatus(
      item.id,
      status: 'AKAN_DATANG',
      tanggalService: now.add(const Duration(days: 3)),
      now: now,
    );
    var updated = (await service.listItems(now: now)).single;
    expect(updated.status, 'AKAN_DATANG');
    expect(updated.tanggalService?.day, now.add(const Duration(days: 3)).day);

    await expectLater(
      service.changeStatus(item.id, status: 'ARSIP', now: now),
      throwsArgumentError,
    );
    await service.changeStatus(
      item.id,
      status: 'ARSIP',
      alasan: 'Sudah datang',
      now: now,
    );
    updated = (await service.listItems(filter: 'arsip', now: now)).single;
    expect(updated.status, 'ARSIP');
    expect(updated.alasanArsip, 'Sudah datang');
  });

  test('piutang tidak bisa ditandai lunas saat masih ada sisa', () async {
    await addNote(
      day: now.subtract(const Duration(days: 20)),
      bayar: 50000,
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;
    await expectLater(
      service.changeStatus(item.id, status: 'SUDAH_BAYAR', now: now),
      throwsA(
        predicate(
          (error) => '$error'.contains('Sisa pembayaran belum lunas'),
          'piutang belum lunas',
        ),
      ),
    );
  });

  test('tidak merespons beberapa kali otomatis diarsipkan', () async {
    await addNote(day: now.subtract(const Duration(days: 40)));
    final settings = await service.loadSettings();
    await service.saveSettings(
      settings.copyWith(
        cooldownHari: 0,
        maksPesanHari: 5,
        maksPesanBulan: 20,
        maksTidakMerespons: 2,
      ),
    );
    await service.syncItems(now: now);
    final item = (await service.listItems(now: now)).single;
    await service.followUp(item.id, now: now);
    final second = await service.listItems(now: now);
    expect(second.single.noResponseCount, 1);

    await service.followUp(item.id, now: now.add(const Duration(minutes: 1)));
    final archived =
        await service.listItems(filter: 'arsip', now: now);
    expect(archived.single.status, 'ARSIP');
    expect(archived.single.alasanArsip, contains('Tidak merespons 2'));
    expect(await service.listItems(now: now), isEmpty);
  });

  test('filter hari ini dan terlambat memakai tanggal jatuh tempo', () async {
    await addNote(day: now.subtract(const Duration(days: 40)));
    await service.syncItems(now: now);
    expect(
      await service.listItems(filter: 'terlambat', now: now),
      hasLength(1),
    );
    expect(
      await service.listItems(filter: 'hari_ini', now: now),
      isEmpty,
    );
    await db.db.update(
      'followup_items',
      {'jatuh_tempo': dateOnly.format(now)},
      where: '1 = 1',
    );
    expect(
      await service.listItems(filter: 'hari_ini', now: now),
      hasLength(1),
    );
  });
}
