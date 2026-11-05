import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('skema bersih v1 memuat tabel dan kolom sinkronisasi', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_schema1_');
    final db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'v1.db'));
    try {
      final version = await db.db.rawQuery('PRAGMA user_version');
      expect(version.single['user_version'], AppDatabase.schemaVersion);

      final tables = (await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
          .map((row) => row['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'customers',
          'vehicle_or_units',
          'stock_items',
          'stock_movements',
          'harga_jasa',
          'service_records',
          'service_jobs',
          'service_parts',
          'service_payments',
          'nota_adjustments',
          'employee_accounts',
          'service_record_commissions',
          'employee_debts',
          'salary_payments',
          'suppliers',
          'supplier_followups',
          'followup_items',
          'followup_events',
          'wa_message_logs',
          'store_settings',
          'estimates',
          'estimate_items',
          'work_orders',
          'work_order_status_log',
          'day_digests',
          'reconciliation_requests',
          'sync_outbox',
          'sync_inbox',
          'sync_conflicts',
        ]),
      );

      final customerColumns = (await db.db.rawQuery(
        'PRAGMA table_info(customers)',
      ))
          .map((row) => row['name'])
          .toSet();
      expect(
        customerColumns,
        containsAll([
          'sync_id',
          'store_id',
          'device_id',
          'sync_hlc_wall',
          'sync_hlc_counter',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );

      final stockColumns = (await db.db.rawQuery(
        'PRAGMA table_info(stock_items)',
      ))
          .map((row) => row['name'])
          .toSet();
      expect(
        stockColumns,
        containsAll(['jumlah', 'jumlah_milli', 'harga_modal', 'harga_jual']),
      );

      final paymentColumns = (await db.db.rawQuery(
        'PRAGMA table_info(service_payments)',
      ))
          .map((row) => row['name'])
          .toSet();
      expect(paymentColumns, containsAll(['created_at', 'updated_at']));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('reopen mempertahankan seluruh data pada skema bersih v1', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_reopen_');
    final path = p.join(dir.path, 'reopen.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      await db.saveStockItem(
        kode: 'REOPEN-1',
        nama: 'Radiator Reopen',
        hargaModalCents: 1000,
        hargaJualCents: 2000,
        jumlah: 5,
        stokMinimum: 1,
      );
      final customerId = await db.addCustomer(
        nama: 'Pelanggan Reopen',
        nomorHp: '081200000091',
      );
      final unitId = await db.addUnit(
        customerId: customerId,
        unitType: 'MOBIL',
        nopol: 'B 91',
      );
      final recordId = await db.createTransaction(
        unitId: unitId,
        keluhan: 'Servis reopen',
        jobs: [
          JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: 1000),
        ],
        parts: const [],
        diskonCents: 0,
        metodeBayar: 'CASH',
        bayarCents: 1000,
      );
      final before = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      ))
          .single;
      await db.close();

      await db.reopen();
      final stock = (await db.listStock()).single;
      expect(stock.jumlahMilli, 5000);
      final after = (await db.db.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [recordId],
      ))
          .single;
      expect(after['no_nota'], before['no_nota']);
      expect(after['keluhan_awal'], 'Servis reopen');
      expect(
        (await db.db.query('store_settings')).length,
        1,
        reason: 'pengaturan toko tidak boleh terduplikasi saat reopen',
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('versi skema lama ditolak tanpa mengubah data', () async {
    final dir = await Directory.systemTemp.createTemp('pusatkupos_legacy_');
    final path = p.join(dir.path, 'legacy.db');
    final db = AppDatabase.instance;
    await db.initForTest(path);
    try {
      await db.addCustomer(nama: 'Data Lama', nomorHp: '081200000092');
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('PRAGMA user_version = 3');
      await raw.close();

      await expectLater(
        db.reopen(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'pesan',
            contains('tidak didukung'),
          ),
        ),
      );

      final check = await databaseFactory.openDatabase(path);
      final version = (await check.rawQuery('PRAGMA user_version')).single;
      final customers = await check.query('customers');
      await check.close();
      expect(version['user_version'], 3);
      expect(customers.length, 1);
      expect(customers.single['nama'], 'Data Lama');
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
