import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pusatkupos/auth/operator.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/employee_service.dart';
import 'package:pusatkupos/data/models.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  var sequence = 0;

  Future<String> addEmployee({
    String role = 'MEKANIK',
    String mode = 'PERSEN',
    int barangNilai = 10,
    int jasaNilai = 10,
    String jenis = 'KOMISI',
    int gajiBulanan = 0,
    String period = 'BULANAN',
    int tanggal = 1,
    int hari = 1,
  }) async {
    sequence++;
    final syncId = 'karyawan-uji-$sequence';
    await db.db.insert('employee_accounts', {
      'sync_id': syncId,
      'username': 'uji$sequence',
      'nama': 'Karyawan $sequence',
      'role_base': role,
      'password_hash': 'x',
      'password_salt': 'y',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-01T00:00:00.000Z',
      'jenis_imbalan': jenis,
      'gaji_bulanan': gajiBulanan,
      'komisi_mode': mode,
      'komisi_barang_nilai': barangNilai,
      'komisi_jasa_nilai': jasaNilai,
      'payroll_period': period,
      'payroll_tanggal': tanggal,
      'payroll_hari': hari,
      'tanggal_masuk': '2026-01-01',
    });
    return syncId;
  }

  Future<(int, int)> addNote(
    List<String> mechanicSyncIds, {
    int hargaJual = 75000,
    int modal = 50000,
    int qty = 2,
    int jasa = 100000,
    Operator? actor,
  }) async {
    sequence++;
    final customerId = await db.addCustomer(
      nama: 'Pelanggan $sequence',
      nomorHp: '08120000${sequence.toString().padLeft(4, '0')}',
    );
    final unitId = await db.addUnit(
      customerId: customerId,
      unitType: 'MOBIL',
      nopol: 'B $sequence',
    );
    final stockId = await db.saveStockItem(
      kode: 'PART-$sequence',
      nama: 'Part $sequence',
      hargaModalCents: modal,
      hargaJualCents: hargaJual,
      jumlah: 20,
      stokMinimum: 1,
    );
    final recordId = await db.createTransaction(
      unitId: unitId,
      keluhan: 'Uji komisi',
      jobs: [JobDraft(deskripsi: 'Jasa', jumlah: 1, hargaCents: jasa)],
      parts: [
        PartDraft(
          stockItemId: stockId,
          nama: 'Part $sequence',
          jumlah: qty,
          hargaCents: hargaJual,
          modalCents: modal,
        ),
      ],
      diskonCents: 0,
      metodeBayar: 'CASH',
      bayarCents: jasa + hargaJual * qty,
      mechanicEmployeeSyncIds: mechanicSyncIds,
      actor: actor,
    );
    return (recordId, stockId);
  }

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pusatkupos_employee_');
    db = AppDatabase.instance;
    await db.initForTest(p.join(dir.path, 'employee.db'));
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('komisi dibagi rata untuk dua mekanik', () async {
    final first = await addEmployee();
    final second = await addEmployee();
    final (recordId, _) = await addNote([first, second]);

    final mechanics = await db.db.query(
      'service_record_mechanics',
      where: 'service_record_id = ?',
      whereArgs: [recordId],
    );
    expect(mechanics.length, 2);

    final detail = await db.recordDetail(recordId);
    expect(detail!.commissions.length, 2);
    for (final commission in detail.commissions) {
      expect(commission.nominalCents, 7500);
    }
    final employeeRows = await db.db.query(
      'employee_accounts',
      where: 'sync_id IN (?, ?)',
      whereArgs: [first, second],
    );
    expect(
      detail.commissions.map((row) => row.nama).toSet(),
      employeeRows.map((row) => row['nama']).toSet(),
    );
  });

  test('komisi nominal tetap dan override pemilik', () async {
    final first = await addEmployee(mode: 'NOMINAL', barangNilai: 2000, jasaNilai: 3000);
    final second = await addEmployee(mode: 'NOMINAL', barangNilai: 2000, jasaNilai: 3000);
    final (recordId, _) = await addNote([first, second]);

    var detail = await db.recordDetail(recordId);
    expect(detail!.commissions.map((row) => row.finalCents), [5000, 5000]);

    await EmployeeService.instance.setCommissionOverride(
      recordId,
      first,
      8000,
      actor: Operator.owner,
    );
    detail = await db.recordDetail(recordId);
    final changed = detail!.commissions.firstWhere(
      (row) => row.employeeSyncId == first,
    );
    expect(changed.finalCents, 8000);

    expect(
      () => EmployeeService.instance.setCommissionOverride(
        recordId,
        first,
        9000,
        actor: const Operator(
          kind: 'employee',
          role: 'KASIR',
          label: 'Kasir',
        ),
      ),
      throwsStateError,
    );
  });

  test('gaji bulanan memotong hutang FIFO dan hanya sekali per siklus', () async {
    final employee = await addEmployee(
      role: 'KASIR',
      jenis: 'GAJI',
      gajiBulanan: 3000000,
      period: 'BULANAN',
      tanggal: 1,
    );
    await EmployeeService.instance.addDebt(
      employee,
      nominalCents: 200000,
      catatan: 'Kasbon lama',
    );
    await EmployeeService.instance.addDebt(
      employee,
      nominalCents: 400000,
      catatan: 'Kasbon baru',
    );
    final at = DateTime(2026, 5, 15, 10);
    final summary = await EmployeeService.instance.payrollSummary(
      employee,
      at: at,
    );
    expect(summary.cycleStart, DateTime(2026, 5, 1));
    expect(summary.cycleEnd, DateTime(2026, 5, 31));
    expect(summary.debtCents, 600000);
    expect(summary.deductionCents, 600000);
    expect(summary.netCents, 2400000);

    final paid = await EmployeeService.instance.paySalary(
      employee,
      at: at,
      bonusCents: 100000,
    );
    expect(paid.paid, isTrue);
    expect(paid.netCents, 2500000);

    final debts = await EmployeeService.instance.listDebts(employee);
    expect(debts.every((row) => row['terbayar'] == row['nominal']), isTrue);
    final payments =
        await EmployeeService.instance.listSalaryPayments(employee);
    expect(payments.length, 1);
    expect(payments.first['nominal'], 3100000);
    expect(payments.first['potongan_hutang'], 600000);
    expect(payments.first['cicilan_hutang'], 0);

    expect(
      () => EmployeeService.instance.paySalary(employee, at: at),
      throwsStateError,
    );
  });

  test('siklus mingguan memakai hari payroll dan prorata gaji', () async {
    final employee = await addEmployee(
      role: 'KASIR',
      jenis: 'GAJI',
      gajiBulanan: 3000000,
      period: 'MINGGUAN',
      hari: 1,
    );
    final at = DateTime(2026, 5, 14, 9);
    final summary = await EmployeeService.instance.payrollSummary(
      employee,
      at: at,
    );
    expect(summary.cycleStart, DateTime(2026, 5, 11));
    expect(summary.cycleEnd, DateTime(2026, 5, 17));
    expect(summary.gajiCents, 700000);
    expect(summary.netCents, 700000);
  });

  test('nota void tidak dihitung dalam komisi dan gaji', () async {
    final employee = await addEmployee();
    final (recordId, _) = await addNote([employee]);
    final before = await EmployeeService.instance.payrollSummary(employee);
    expect(before.commissionCents, 15000);

    await db.voidRecord(recordId, 'Salah input');
    final after = await EmployeeService.instance.payrollSummary(employee);
    expect(after.commissionCents, 0);
  });

  test('kasir dan kompensasi divalidasi', () async {
    final kasir = await addEmployee(role: 'KASIR');
    final (recordId, _) = await addNote(
      [],
      jasa: 50000,
      qty: 1,
      actor: Operator(
        kind: 'employee',
        role: 'KASIR',
        label: 'Kasir Uji',
        employeeSyncId: kasir,
      ),
    );
    final row = (await db.db.query(
      'service_records',
      where: 'id = ?',
      whereArgs: [recordId],
    ))
        .first;
    expect(row['cashier_employee_id'], kasir);

    expect(
      () => EmployeeService.instance.updateCompensation(
        kasir,
        jenisImbalan: 'KOMISI',
        gajiBulananCents: 0,
        komisiMode: 'PERSEN',
        komisiBarangNilai: 101,
        komisiJasaNilai: 0,
        payrollPeriod: 'BULANAN',
        payrollTanggal: 1,
        payrollHari: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => EmployeeService.instance.addDebt(kasir, nominalCents: 0),
      throwsArgumentError,
    );
  });
}
