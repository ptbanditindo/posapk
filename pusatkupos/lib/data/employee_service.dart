import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/crypto.dart';
import '../sync/sync_service.dart';
import 'app_database.dart';

const imbalanTypes = ['KOMISI', 'GAJI'];
const komisiModes = ['PERSEN', 'NOMINAL'];
const payrollPeriods = ['MINGGUAN', 'BULANAN'];

class PayrollSummary {
  const PayrollSummary({
    required this.employeeSyncId,
    required this.nama,
    required this.periode,
    required this.cycleStart,
    required this.cycleEnd,
    required this.commissionCents,
    required this.gajiCents,
    required this.bonusCents,
    required this.debtCents,
    required this.deductionCents,
    required this.netCents,
    required this.paid,
  });

  final String employeeSyncId;
  final String nama;
  final String periode;
  final DateTime cycleStart;
  final DateTime cycleEnd;
  final int commissionCents;
  final int gajiCents;
  final int bonusCents;
  final int debtCents;
  final int deductionCents;
  final int netCents;
  final bool paid;

  int get grossCents => netCents + deductionCents;
}

class EmployeeService {
  EmployeeService._();

  static final EmployeeService instance = EmployeeService._();

  Database get _db => AppDatabase.instance.db;

  Future<List<Map<String, Object?>>> listEmployees() {
    return _db.query(
      'employee_accounts',
      orderBy: 'aktif DESC, nama COLLATE NOCASE',
    );
  }

  Future<Map<String, Object?>?> findEmployee(String syncId) async {
    final rows = await _db.query(
      'employee_accounts',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateCompensation(
    String syncId, {
    required String jenisImbalan,
    required int gajiBulananCents,
    required String komisiMode,
    required int komisiBarangNilai,
    required int komisiJasaNilai,
    required String payrollPeriod,
    required int payrollTanggal,
    required int payrollHari,
    String? bankNama,
    String? bankNomor,
    String? bankPemilik,
    String? tanggalMasuk,
  }) async {
    if (!imbalanTypes.contains(jenisImbalan)) {
      throw ArgumentError('Jenis imbalan tidak dikenal.');
    }
    if (!komisiModes.contains(komisiMode)) {
      throw ArgumentError('Mode komisi tidak dikenal.');
    }
    if (!payrollPeriods.contains(payrollPeriod)) {
      throw ArgumentError('Periode payroll tidak dikenal.');
    }
    if (gajiBulananCents < 0 ||
        komisiBarangNilai < 0 ||
        komisiJasaNilai < 0) {
      throw ArgumentError('Nilai kompensasi tidak boleh negatif.');
    }
    if (komisiMode == 'PERSEN' &&
        (komisiBarangNilai > 100 || komisiJasaNilai > 100)) {
      throw ArgumentError('Persentase komisi maksimal 100.');
    }
    if (payrollTanggal < 1 || payrollTanggal > 31) {
      throw ArgumentError('Tanggal payroll harus 1-31.');
    }
    if (payrollHari < 1 || payrollHari > 7) {
      throw ArgumentError('Hari payroll harus 1-7 (Senin-Minggu).');
    }
    if (await findEmployee(syncId) == null) {
      throw StateError('Karyawan tidak ditemukan.');
    }
    await _db.transaction((txn) async {
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await txn.update(
        'employee_accounts',
        {
          'jenis_imbalan': jenisImbalan,
          'gaji_bulanan': gajiBulananCents,
          'komisi_mode': komisiMode,
          'komisi_barang_nilai': komisiBarangNilai,
          'komisi_jasa_nilai': komisiJasaNilai,
          'payroll_period': payrollPeriod,
          'payroll_tanggal': payrollTanggal,
          'payroll_hari': payrollHari,
          'bank_nama': _clean(bankNama),
          'bank_nomor': _clean(bankNomor),
          'bank_pemilik': _clean(bankPemilik),
          'tanggal_masuk': _clean(tanggalMasuk),
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'updated_at': nowIso(),
        },
        where: 'sync_id = ?',
        whereArgs: [syncId],
      );
      await SyncService.instance.enqueueEmployee(syncId, txn: txn);
    });
  }

  Future<int> totalDebt(String employeeSyncId) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(nominal - terbayar), 0) AS total '
      'FROM employee_debts WHERE employee_sync_id = ?',
      [employeeSyncId],
    );
    return rows.first['total'] as int? ?? 0;
  }

  Future<List<Map<String, Object?>>> listDebts(String employeeSyncId) {
    return _db.query(
      'employee_debts',
      where: 'employee_sync_id = ?',
      whereArgs: [employeeSyncId],
      orderBy: 'created_at, id',
    );
  }

  Future<int> addDebt(
    String employeeSyncId, {
    required int nominalCents,
    String? catatan,
    Future<void> Function(Transaction txn, String syncId)? enqueue,
  }) async {
    if (nominalCents <= 0) {
      throw ArgumentError('Nominal hutang harus lebih dari nol.');
    }
    if (await findEmployee(employeeSyncId) == null) {
      throw StateError('Karyawan tidak ditemukan.');
    }
    return _db.transaction((txn) async {
      final syncId = newSyncId();
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final id = await txn.insert('employee_debts', {
        'sync_id': syncId,
        'employee_sync_id': employeeSyncId,
        'nominal': nominalCents,
        'terbayar': 0,
        'catatan': _clean(catatan),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      if (enqueue != null) await enqueue(txn, syncId);
      return id;
    });
  }

  Future<DateTime> cycleStartFor(
    Map<String, Object?> employee,
    DateTime at,
  ) async {
    final period = '${employee['payroll_period'] ?? 'BULANAN'}';
    final today = DateTime(at.year, at.month, at.day);
    if (period == 'MINGGUAN') {
      final weekday = (employee['payroll_hari'] as num?)?.toInt() ?? 1;
      final diff = (today.weekday - weekday) % 7;
      return today.subtract(Duration(days: diff));
    }
    final day = (employee['payroll_tanggal'] as num?)?.toInt() ?? 1;
    var start = DateTime(today.year, today.month, _safeDay(today.year, today.month, day));
    if (start.isAfter(today)) {
      final previous = DateTime(today.year, today.month - 1);
      start = DateTime(
        previous.year,
        previous.month,
        _safeDay(previous.year, previous.month, day),
      );
    }
    return start;
  }

  Future<PayrollSummary> payrollSummary(
    String employeeSyncId, {
    DateTime? at,
    int bonusCents = 0,
  }) async {
    final employee = await findEmployee(employeeSyncId);
    if (employee == null) throw StateError('Karyawan tidak ditemukan.');
    if (bonusCents < 0) throw ArgumentError('Bonus tidak boleh negatif.');
    final now = at ?? DateTime.now();
    final period = '${employee['payroll_period'] ?? 'BULANAN'}';
    final payrollDay = (employee['payroll_tanggal'] as num?)?.toInt() ?? 1;
    final start = await cycleStartFor(employee, now);
    final end = period == 'MINGGUAN'
        ? start.add(const Duration(days: 7))
        : _nextMonthlyStart(start, payrollDay);

    final commissionRows = await _db.rawQuery(
      '''
      SELECT COALESCE(SUM(COALESCE(c.nominal_override, c.nominal)), 0) AS total
      FROM service_record_commissions c
      JOIN service_records r ON r.id = c.service_record_id
      WHERE c.employee_sync_id = ?
        AND r.status != 'VOID'
        AND r.waktu_service >= ? AND r.waktu_service < ?
      ''',
      [employeeSyncId, isoStartOfDay(start), isoStartOfDay(end)],
    );
    final commission = commissionRows.first['total'] as int? ?? 0;
    final gajiBulanan = (employee['gaji_bulanan'] as num?)?.toInt() ?? 0;
    final days = end.difference(start).inDays;
    final gaji = period == 'BULANAN'
        ? gajiBulanan
        : (gajiBulanan * days / 30).round();
    final base = '${employee['jenis_imbalan'] ?? 'KOMISI'}' == 'GAJI'
        ? gaji
        : commission;
    final debt = await totalDebt(employeeSyncId);
    final gross = base + bonusCents;
    final deduction = min(debt, gross);
    final paidRows = await _db.query(
      'salary_payments',
      columns: ['id'],
      where: 'employee_sync_id = ? AND cycle_start = ?',
      whereArgs: [employeeSyncId, isoStartOfDay(start)],
      limit: 1,
    );
    return PayrollSummary(
      employeeSyncId: employeeSyncId,
      nama: '${employee['nama'] ?? employee['username'] ?? ''}',
      periode: period,
      cycleStart: start,
      cycleEnd: end.subtract(const Duration(days: 1)),
      commissionCents: commission,
      gajiCents: gaji,
      bonusCents: bonusCents,
      debtCents: debt,
      deductionCents: deduction,
      netCents: gross - deduction,
      paid: paidRows.isNotEmpty,
    );
  }

  Future<PayrollSummary> paySalary(
    String employeeSyncId, {
    required Operator actor,
    DateTime? at,
    int bonusCents = 0,
    String metode = 'CASH',
    String? catatan,
    Future<void> Function(Transaction txn, String syncId)? enqueue,
  }) async {
    Permissions.require(actor, permissionPaySalary);
    if (metode != 'CASH' && metode != 'TRANSFER') {
      throw ArgumentError('Metode pembayaran tidak dikenal.');
    }
    final employee = await findEmployee(employeeSyncId);
    if (employee == null) throw StateError('Karyawan tidak ditemukan.');
    final summary = await payrollSummary(
      employeeSyncId,
      at: at,
      bonusCents: bonusCents,
    );
    if (summary.paid) {
      throw StateError('Gaji untuk siklus ini sudah dibayar.');
    }
    if (summary.grossCents <= 0) {
      throw StateError('Tidak ada imbalan yang dapat dibayarkan.');
    }
    final jenisImbalan = '${employee['jenis_imbalan'] ?? 'KOMISI'}';
    final gajiPokok = jenisImbalan == 'GAJI' ? summary.gajiCents : 0;
    final komisiDibayar =
        jenisImbalan == 'GAJI' ? 0 : summary.commissionCents;
    final nominal = gajiPokok + komisiDibayar + summary.bonusCents;
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'salary_payments',
        columns: ['id'],
        where: 'employee_sync_id = ? AND cycle_start = ?',
        whereArgs: [
          employeeSyncId,
          isoStartOfDay(summary.cycleStart),
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError('Gaji untuk siklus ini sudah dibayar.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      await _applyDebtPayment(
        txn,
        employeeSyncId,
        summary.deductionCents,
        hlc: hlc,
      );
      final paidAt = at ?? DateTime.now();
      final syncId = newSyncId();
      final cycleStart = isoStartOfDay(summary.cycleStart);
      final kasKeluar = summary.netCents;
      final sekarang = nowIso();
      final storeId = AppDatabase.instance.activeStoreId ?? 'utama';
      final deviceId = await _deviceId(txn);
      await txn.insert('salary_payments', {
        'sync_id': syncId,
        'store_id': storeId,
        'device_id': deviceId,
        'employee_sync_id': employeeSyncId,
        'employee_nama_snapshot': summary.nama,
        'periode': summary.periode,
        'cycle_start': cycleStart,
        'cycle_end': isoEndOfDay(summary.cycleEnd),
        'cycle_key': '$employeeSyncId|$cycleStart',
        'tanggal': isoStartOfDay(paidAt),
        'nominal': nominal,
        'gaji_pokok': gajiPokok,
        'potongan_hutang': summary.deductionCents,
        'cicilan_hutang': summary.deductionCents,
        'bonus': summary.bonusCents,
        'komisi_total': komisiDibayar,
        'kas_keluar': kasKeluar,
        'metode': metode,
        'status': 'AKTIF',
        'paid_by': actor.label,
        'paid_by_employee_sync_id': actor.employeeSyncId,
        'catatan': _clean(catatan),
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': sekarang,
        'updated_at': sekarang,
      });
      if (kasKeluar > 0) {
        await txn.insert(
          'cash_ledger',
          {
            'sync_id': newSyncId(),
            'store_id': storeId,
            'device_id': deviceId,
            'waktu': sekarang,
            'kategori': 'GAJI',
            'sumber_entity': 'salary_payment',
            'sumber_sync_id': syncId,
            'nominal': -kasKeluar,
            'metode': metode,
            'operator': actor.label,
            'catatan': 'Gaji ${summary.periode} ${summary.nama}',
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
            'created_at': sekarang,
            'updated_at': sekarang,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await txn.insert('business_audits', {
        'sync_id': newSyncId(),
        'store_id': storeId,
        'device_id': deviceId,
        'waktu': sekarang,
        'aktor': actor.label,
        'aktor_employee_sync_id': actor.employeeSyncId,
        'aksi': 'bayar_gaji',
        'entity': 'salary_payment',
        'entity_id': syncId,
        'before_json': '{}',
        'after_json':
            '{"gaji_pokok":$gajiPokok,"komisi":$komisiDibayar,'
                '"bonus":${summary.bonusCents},"kas_keluar":$kasKeluar}',
        'alasan': _clean(catatan),
        'created_at': sekarang,
        'updated_at': sekarang,
      });
      if (enqueue != null) await enqueue(txn, syncId);
    });
    return PayrollSummary(
      employeeSyncId: summary.employeeSyncId,
      nama: summary.nama,
      periode: summary.periode,
      cycleStart: summary.cycleStart,
      cycleEnd: summary.cycleEnd,
      commissionCents: summary.commissionCents,
      gajiCents: summary.gajiCents,
      bonusCents: summary.bonusCents,
      debtCents: summary.debtCents,
      deductionCents: summary.deductionCents,
      netCents: summary.netCents,
      paid: true,
    );
  }

  Future<List<Map<String, Object?>>> listSalaryPayments(
    String employeeSyncId,
  ) {
    return _db.query(
      'salary_payments',
      where: 'employee_sync_id = ?',
      whereArgs: [employeeSyncId],
      orderBy: 'cycle_start DESC',
      limit: 24,
    );
  }

  Future<void> setCommissionOverride(
    int recordId,
    String employeeSyncId,
    int? overrideCents, {
    Operator? actor,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    if (actor == null || !actor.isOwner) {
      throw StateError('Hanya pemilik yang dapat mengubah komisi.');
    }
    if (overrideCents != null && overrideCents < 0) {
      throw ArgumentError('Komisi tidak boleh negatif.');
    }
    await _db.transaction((txn) async {
      final records = await txn.query(
        'service_records',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (records.isEmpty) throw StateError('Nota tidak ditemukan.');
      if (records.first['status'] == 'VOID') {
        throw StateError('Nota void tidak dapat diubah komisinya.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final rows = await txn.query(
        'service_record_commissions',
        columns: ['id'],
        where: 'service_record_id = ? AND employee_sync_id = ?',
        whereArgs: [recordId, employeeSyncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        if (overrideCents == null) return;
        final id = await txn.insert('service_record_commissions', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'employee_sync_id': employeeSyncId,
          'nominal': 0,
          'nominal_override': overrideCents,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
          'created_at': nowIso(),
          'updated_at': nowIso(),
        });
        if (enqueue != null) await enqueue(txn, id);
        return;
      }
      await txn.update(
        'service_record_commissions',
        {
          'nominal_override': overrideCents,
          'sync_hlc_wall': hlc.wall,
          'sync_hlc_counter': hlc.counter,
        },
        where: 'id = ?',
        whereArgs: [rows.first['id']],
      );
      if (enqueue != null) await enqueue(txn, rows.first['id'] as int);
    });
  }

  static int estimateRecordCommissions(
    List<Map<String, Object?>> mechanics, {
    required int jasaCents,
    required int marginCents,
    required bool hasJobs,
    required bool hasParts,
  }) {
    if (mechanics.isEmpty) return 0;
    var total = 0;
    for (var index = 0; index < mechanics.length; index++) {
      final row = mechanics[index];
      final mode = '${row['komisi_mode'] ?? 'PERSEN'}';
      final barangNilai = (row['komisi_barang_nilai'] as num?)?.toInt() ?? 0;
      final jasaNilai = (row['komisi_jasa_nilai'] as num?)?.toInt() ?? 0;
      if (mode == 'NOMINAL') {
        total += (hasParts ? barangNilai : 0) + (hasJobs ? jasaNilai : 0);
        continue;
      }
      final shareJasa = _share(jasaCents, index, mechanics.length);
      final shareMargin = _share(marginCents, index, mechanics.length);
      total += (shareJasa * jasaNilai) ~/ 100 +
          (shareMargin * barangNilai) ~/ 100;
    }
    return total;
  }

  static int _share(int total, int index, int count) {
    if (count <= 0) return 0;
    return total ~/ count + (index < total % count ? 1 : 0);
  }

  static Future<int> _applyDebtPayment(
    DatabaseExecutor txn,
    String employeeSyncId,
    int amount, {
    required Hlc hlc,
  }) async {
    var left = amount;
    if (left > 0) {
      final debts = await txn.query(
        'employee_debts',
        where: 'employee_sync_id = ? AND terbayar < nominal',
        whereArgs: [employeeSyncId],
        orderBy: 'created_at, id',
      );
      for (final debt in debts) {
        if (left <= 0) break;
        final nominal = debt['nominal'] as int;
        final paid = debt['terbayar'] as int? ?? 0;
        final due = nominal - paid;
        final take = min(due, left);
        await txn.update(
          'employee_debts',
          {
            'terbayar': paid + take,
            'sync_hlc_wall': hlc.wall,
            'sync_hlc_counter': hlc.counter,
          },
          where: 'id = ?',
          whereArgs: [debt['id']],
        );
        left -= take;
      }
    }
    final rows = await txn.rawQuery(
      'SELECT COALESCE(SUM(nominal - terbayar), 0) AS total '
      'FROM employee_debts WHERE employee_sync_id = ?',
      [employeeSyncId],
    );
    return rows.first['total'] as int? ?? 0;
  }

  static int _safeDay(int year, int month, int day) {
    final normalized = DateTime(year, month);
    final last = DateTime(normalized.year, normalized.month + 1, 0).day;
    return day.clamp(1, last);
  }

  static DateTime _nextMonthlyStart(DateTime start, int day) {
    final nextMonth = DateTime(start.year, start.month + 1, 1);
    return DateTime(
      nextMonth.year,
      nextMonth.month,
      _safeDay(nextMonth.year, nextMonth.month, day),
    );
  }

  Future<String> _deviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final settings = {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
    return settings['sync.relay_device_id'] ??
        settings['device.current_id'] ??
        '';
  }

  static String? _clean(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }
}
