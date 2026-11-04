import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('migrasi v3 -> v4 menambah kolom dan mengubah waktu ke UTC', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_migrate_');
    final path = p.join(dir.path, 'migrate.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      await db.saveStockItem(
        kode: 'MIG-1',
        nama: 'Barang Lama',
        hargaModalCents: 1000,
        hargaJualCents: 2000,
        jumlah: 5,
        stokMinimum: 1,
      );
      final customerId = await db.addCustomer(
        nama: 'Lama',
        nomorHp: '081200000099',
      );
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 99',
      );
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Lama',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000,
      );
      await db.db.update(
        'service_records',
        {'waktu_service': '2025-01-01T10:00:00.000'},
        where: 'id = ?',
        whereArgs: [recordId],
      );
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('PRAGMA user_version = 3');
      for (final column in const ['satuan', 'desimal', 'jumlah_milli']) {
        await raw.execute('ALTER TABLE stock_items DROP COLUMN $column');
      }
      await raw.execute(
        'ALTER TABLE stock_movements DROP COLUMN jumlah_milli',
      );
      for (final column in const [
        'created_by',
        'created_by_employee_id',
        'mechanic',
        'mechanic_employee_id',
      ]) {
        await raw.execute('ALTER TABLE service_records DROP COLUMN $column');
      }
      await raw.close();

      await db.reopen();
      final stock = (await db.listStock()).first;
      expect(stock.jumlah, 5);
      expect(stock.jumlahMilli, 5000);
      expect(stock.satuan, 'pcs');

      final record = await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      final waktu = record.first['waktu_service'] as String;
      expect(waktu.endsWith('Z'), isTrue);
      expect(
        DateTime.parse(waktu).toLocal(),
        DateTime(2025, 1, 1, 10),
      );
      expect(record.first.keys, contains('created_by'));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('migrasi v7 -> v8 menambah kompensasi dan tabel payroll', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_migrate8_');
    final path = p.join(dir.path, 'migrate8.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      final accountId = await db.db.insert('employee_accounts', {
        'sync_id': 'karyawan-v8',
        'username': 'kasir8',
        'nama': 'Kasir V8',
        'role_base': 'KASIR',
        'password_hash': 'x',
        'password_salt': 'y',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      expect(accountId, greaterThan(0));
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('PRAGMA user_version = 7');
      for (final table in const [
        'service_record_mechanics',
        'service_record_commissions',
        'employee_debts',
        'salary_payments',
      ]) {
        await raw.execute('DROP TABLE IF EXISTS $table');
      }
      for (final column in const [
        'jenis_imbalan',
        'gaji_bulanan',
        'komisi_mode',
        'komisi_barang_nilai',
        'komisi_jasa_nilai',
        'payroll_period',
        'payroll_tanggal',
        'payroll_hari',
        'bank_nama',
        'tanggal_masuk',
      ]) {
        await raw.execute('ALTER TABLE employee_accounts DROP COLUMN $column');
      }
      await raw.execute(
        'ALTER TABLE service_records DROP COLUMN cashier_employee_id',
      );
      await raw.close();

      await db.reopen();
      final columns = await db.db.rawQuery(
        'PRAGMA table_info(employee_accounts)',
      );
      final names = columns.map((row) => row['name']).toSet();
      expect(names, containsAll(['jenis_imbalan', 'payroll_period']));
      final recordColumns = await db.db.rawQuery(
        'PRAGMA table_info(service_records)',
      );
      expect(
        recordColumns.map((row) => row['name']),
        contains('cashier_employee_id'),
      );
      for (final table in const [
        'service_record_mechanics',
        'service_record_commissions',
        'employee_debts',
        'salary_payments',
      ]) {
        final rows = await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        );
        expect(rows, isNotEmpty, reason: table);
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('migrasi v4 -> v5 mengganti id lokal dengan sync_id', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_migrate5_');
    final path = p.join(dir.path, 'migrate5.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      const syncId = 'karyawan-sync-v5';
      final localId = await db.db.insert('employee_accounts', {
        'sync_id': syncId,
        'username': 'kasir5',
        'nama': 'Kasir V5',
        'role_base': 'KASIR',
        'password_hash': 'x',
        'password_salt': 'y',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      final customerId = await db.addCustomer(nama: 'V5', nomorHp: '081200000098');
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 5',
      );
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'V5',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000,
      );
      await db.db.update(
        'service_records',
        {
          'created_by_employee_id': '$localId',
          'mechanic_employee_id': '$localId',
        },
        where: 'id = ?',
        whereArgs: [recordId],
      );
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('PRAGMA user_version = 4');
      await raw.close();

      await db.reopen();
      final row = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      ))
          .first;
      expect(row['created_by_employee_id'], syncId);
      expect(row['mechanic_employee_id'], syncId);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('migrasi v10 -> v11 menjaga data dan menambah antrean sync', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_migrate11_');
    final path = p.join(dir.path, 'migrate11.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      final customerId = await db.addCustomer(
        nama: 'Pelanggan V10',
        nomorHp: '081200000077',
      );
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 10 LAMA',
      );
      await db.saveStockItem(
        kode: 'SP-V10',
        nama: 'Radiator V10',
        hargaModalCents: 1000,
        hargaJualCents: 2000,
        jumlah: 9,
        stokMinimum: 1,
      );
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Servis V10',
        jobs: [
          JobDraft(deskripsi: 'Jasa V10', jumlah: 1, hargaCents: 1000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000,
      );
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('PRAGMA user_version = 10');
      await raw.execute('DROP TABLE IF EXISTS sync_inbox');
      await raw.execute('ALTER TABLE sync_outbox DROP COLUMN next_retry_at');
      for (final column in const [
        'status',
        'retry_count',
        'last_error',
        'inbox_id',
      ]) {
        await raw.execute('ALTER TABLE sync_conflicts DROP COLUMN $column');
      }
      for (final table in const [
        'customers',
        'vehicle_or_units',
        'stock_items',
        'harga_jasa',
        'service_records',
        'suppliers',
        'supplier_followups',
        'service_record_commissions',
        'employee_debts',
        'salary_payments',
      ]) {
        await raw.execute(
          'ALTER TABLE $table DROP COLUMN sync_hlc_wall',
        );
        await raw.execute(
          'ALTER TABLE $table DROP COLUMN sync_hlc_counter',
        );
      }
      for (final table in const [
        'customers',
        'vehicle_or_units',
        'stock_items',
        'harga_jasa',
        'suppliers',
      ]) {
        await raw.execute('ALTER TABLE $table DROP COLUMN deleted_at');
      }
      await raw.close();

      await db.reopen();
      final customer = (await db.db.query(
        'customers',
        where: 'id = ?',
        whereArgs: [customerId],
      ))
          .single;
      expect(customer['nama'], 'Pelanggan V10');
      expect(customer['sync_hlc_wall'], 0);
      expect(customer['sync_hlc_counter'], 0);
      expect(customer['deleted_at'], isNull);

      final stock = (await db.listStock()).single;
      expect(stock.jumlah, 9);
      final record = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      ))
          .single;
      expect(record['keluhan_awal'], 'Servis V10');
      expect(record.keys, contains('sync_hlc_wall'));

      final inboxTable = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_inbox'",
      );
      expect(inboxTable, isNotEmpty);
      final outboxColumns = await db.db.rawQuery('PRAGMA table_info(sync_outbox)');
      expect(
        outboxColumns.map((row) => row['name']),
        contains('next_retry_at'),
      );
      final conflictColumns =
          await db.db.rawQuery('PRAGMA table_info(sync_conflicts)');
      expect(
        conflictColumns.map((row) => row['name']),
        containsAll(['status', 'retry_count', 'last_error', 'inbox_id']),
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
