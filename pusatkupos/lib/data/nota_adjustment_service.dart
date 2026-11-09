import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/sync_conflict_rules.dart';
import 'app_database.dart';
import 'approval_service.dart';
import 'pajak.dart';
import 'price_rules.dart';
import 'store_settings.dart';

class NotaAdjustment {
  const NotaAdjustment({
    required this.id,
    required this.syncId,
    required this.notaSyncId,
    required this.nilaiSelisih,
    required this.nilaiBaru,
    required this.alasan,
    this.nominalJasa = 0,
    this.nominalPart = 0,
    this.diskon = 0,
    this.dibuatOleh,
    this.disetujuiOleh,
    required this.createdAt,
  });

  final int id;
  final String syncId;
  final String notaSyncId;
  final int nilaiSelisih;
  final int nilaiBaru;

  /// Alokasi koreksi terhadap komponen nota asli. Ketiganya dihitung dari
  /// `nilai_baru - total_servis` sehingga Jasa + Part - Diskon = Total.
  final int nominalJasa;
  final int nominalPart;
  final int diskon;
  final String alasan;
  final String? dibuatOleh;
  final String? disetujuiOleh;
  final DateTime createdAt;

  factory NotaAdjustment.fromRow(Map<String, Object?> row) => NotaAdjustment(
    id: row['id'] as int,
    syncId: row['sync_id'] as String,
    notaSyncId: row['nota_sync_id'] as String,
    nilaiSelisih: (row['nilai_selisih'] as num?)?.toInt() ?? 0,
    nilaiBaru: (row['nilai_baru'] as num?)?.toInt() ?? 0,
    nominalJasa: (row['nominal_jasa'] as num?)?.toInt() ?? 0,
    nominalPart: (row['nominal_part'] as num?)?.toInt() ?? 0,
    diskon: (row['diskon'] as num?)?.toInt() ?? 0,
    alasan: row['alasan'] as String? ?? '',
    dibuatOleh: row['dibuat_oleh'] as String?,
    disetujuiOleh: row['disetujui_oleh'] as String?,
    createdAt:
        DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
  );
}

/// Koreksi append-only. Nota asli tidak pernah diubah; setiap koreksi adalah
/// baris baru yang merujuk `sync_id` nota asal.
class NotaAdjustmentService {
  NotaAdjustmentService._();

  static final NotaAdjustmentService instance = NotaAdjustmentService._();

  Future<int> create({
    required String notaSyncId,
    int? nilaiBaru,
    int? selisih,
    required String alasan,
    Operator? actor,
    String? ownerPin,
    String? approverSecret,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    if ((nilaiBaru == null) == (selisih == null)) {
      throw ArgumentError('Isi salah satu: nilai baru atau selisih koreksi.');
    }
    final cleanReason = alasan.trim();
    if (cleanReason.isEmpty) {
      throw ArgumentError('Alasan koreksi wajib diisi.');
    }
    if (actor == null) {
      throw StateError('Operator wajib diisi untuk koreksi nota.');
    }
    final settings = await StoreSettingsService.instance.ensure();
    final role = actor.role;
    if (!actor.isOwner && !settings.roleAllows(role, 'koreksi')) {
      throw StateError('Peran $role tidak berhak membuat koreksi nota.');
    }
    final db = AppDatabase.instance.db;
    final records = await db.query(
      'service_records',
      where: 'sync_id = ?',
      whereArgs: [notaSyncId],
      limit: 1,
    );
    if (records.isEmpty) {
      throw StateError('Nota asal tidak ditemukan.');
    }
    final record = records.first;
    if (record['voided_at'] != null || record['status'] == 'VOID') {
      throw StateError('Nota yang sudah dibatalkan tidak dapat dikoreksi.');
    }
    final recordId = record['id'] as int;
    final modalTotal = await _modalTotal(db, recordId);
    final previewTarget =
        nilaiBaru ?? (await _currentTotal(db, recordId)) + selisih!;
    // Verifikasi PIN di luar transaksi agar hitungan percobaan gagal tetap
    // tersimpan walau transaksi koreksi dibatalkan.
    var ownerApproved = actor.isOwner;
    String? approver = ownerApproved ? actor.label : null;
    try {
      PriceRules.validateCorrection(
        modalTotal: modalTotal,
        nilaiBaru: previewTarget,
        ownerApproved: ownerApproved,
      );
    } on PriceRuleViolation catch (error) {
      if (error.code != 'di_bawah_batas_minimal') rethrow;
      final hasInput =
          (ownerPin ?? '').trim().isNotEmpty ||
          (approverSecret ?? '').trim().isNotEmpty;
      if (!hasInput) rethrow;
      try {
        final approval = await ApprovalService.instance.verify(
          settings: settings,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
        );
        ownerApproved = true;
        approver = approval.isOwner ? 'Pemilik (PIN)' : approval.label;
      } on ApprovalException catch (failure) {
        throw PriceRuleViolation('persetujuan_gagal', failure.message);
      }
    }
    return db.transaction((txn) async {
      final current = await txn.query(
        'service_records',
        columns: [
          'voided_at',
          'status',
          'total_servis',
          'biaya_jasa',
          'total_part',
          'pajak_mode',
          'pajak_dpp',
          'pajak',
          'pajak_diserap',
        ],
        where: 'id = ?',
        whereArgs: [recordId],
        limit: 1,
      );
      if (current.isEmpty ||
          current.first['voided_at'] != null ||
          '${current.first['status']}' == 'VOID') {
        throw StateError('Nota yang sudah dibatalkan tidak dapat dikoreksi.');
      }
      final hlc = await AppDatabase.instance.nextSyncHlc(txn);
      final previous = await _currentTotal(txn, recordId);
      final target = nilaiBaru ?? previous + selisih!;
      final delta = target - previous;
      if (!ownerApproved) {
        PriceRules.validateCorrection(
          modalTotal: modalTotal,
          nilaiBaru: target,
          ownerApproved: false,
        );
      }
      final now = nowIso();
      final totalServis =
          (current.first['total_servis'] as num?)?.toInt() ?? 0;
      final allocation = _splitAdjustment(
        target: target,
        totalServis: totalServis,
        biayaJasa: (current.first['biaya_jasa'] as num?)?.toInt() ?? 0,
        totalPart: (current.first['total_part'] as num?)?.toInt() ?? 0,
      );
      final tax = _scaledTaxSnapshot(
        target: target,
        totalServis: totalServis,
        mode: '${current.first['pajak_mode'] ?? pajakModeTanpa}',
        dpp: (current.first['pajak_dpp'] as num?)?.toInt() ?? 0,
        pajak: (current.first['pajak'] as num?)?.toInt() ?? 0,
        diserap: (current.first['pajak_diserap'] as num?)?.toInt() ?? 0,
      );
      final id = await txn.insert('nota_adjustments', {
        'sync_id': newSyncId(),
        'nota_sync_id': notaSyncId,
        'nilai_selisih': delta,
        'nilai_baru': target,
        'nominal_jasa': allocation.$1,
        'nominal_part': allocation.$2,
        'diskon': 0,
        'dpp_cents': tax.$1,
        'ppn_cents': tax.$2,
        'pajak_diserap_cents': tax.$3,
        'alasan': cleanReason,
        'dibuat_oleh': actor.label,
        'disetujui_oleh': ownerApproved ? approver : null,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'created_at': now,
        'updated_at': now,
      });
      await AppDatabase.instance.recalculateRecordTotals(txn, recordId);
      await txn.insert('permission_audits', {
        'sync_id': newSyncId(),
        'actor': actor.label,
        'target_account_id': actor.employeeId,
        'action': 'koreksi_nota',
        'detail_json': jsonEncode({
          'nota_sync_id': notaSyncId,
          'nilai_lama': previous,
          'nilai_baru': target,
          'selisih': delta,
          'disetujui_oleh': approver,
        }),
        'created_at': now,
        'updated_at': now,
      });
      if (enqueue != null) await enqueue(txn, id);
      return id;
    });
  }

  Future<int> _modalTotal(DatabaseExecutor executor, int recordId) async {
    final rows = await executor.rawQuery(
      'SELECT ${AppDatabase.recordModalSql} AS modal',
      [recordId, recordId],
    );
    return (rows.first['modal'] as num?)?.toInt() ?? 0;
  }

  /// Alokasi koreksi disimpan terhadap komponen nota asli (bukan selisih
  /// antarkoreksi) agar baris koreksi terakhir selalu memenuhi
  /// Jasa + Part - Diskon = Total.
  static (int, int) _splitAdjustment({
    required int target,
    required int totalServis,
    required int biayaJasa,
    required int totalPart,
  }) {
    final adjustment = target - totalServis;
    final bruto = biayaJasa + totalPart;
    if (bruto <= 0) return (adjustment, 0);
    final jasa = (adjustment * biayaJasa) ~/ bruto;
    return (jasa, adjustment - jasa);
  }

  /// Pajak efektif setelah koreksi: DPP/PPN/diserap nota asli diskalakan
  /// terhadap total efektif. Snapshot disimpan agar rekap tidak berubah bila
  /// tarif atau mode pajak toko diubah kemudian.
  static (int, int, int) _scaledTaxSnapshot({
    required int target,
    required int totalServis,
    required String mode,
    required int dpp,
    required int pajak,
    required int diserap,
  }) {
    if (mode == pajakModeTanpa || totalServis <= 0) return (0, 0, 0);
    int scale(int value) =>
        value <= 0 || target <= 0
        ? 0
        : (value * target + totalServis ~/ 2) ~/ totalServis;
    final dppSkala = scale(dpp);
    final pajakSkala = scale(pajak);
    final diserapSkala = scale(diserap);
    return (
      dppSkala,
      pajakSkala,
      diserapSkala > pajakSkala ? pajakSkala : diserapSkala,
    );
  }

  /// Koreksi cepat memakai selisih (boleh negatif untuk retur).
  Future<int> createSelisih({
    required String notaSyncId,
    required int selisih,
    required String alasan,
    Operator? actor,
    String? ownerPin,
    String? approverSecret,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    return create(
      notaSyncId: notaSyncId,
      selisih: selisih,
      alasan: alasan,
      actor: actor,
      ownerPin: ownerPin,
      approverSecret: approverSecret,
      enqueue: enqueue,
    );
  }

  /// Koreksi dari layar riwayat yang hanya memegang id lokal.
  Future<int> createForRecord({
    required int recordId,
    required int nilaiBaru,
    required String alasan,
    Operator? actor,
    String? ownerPin,
    String? approverSecret,
    Future<void> Function(Transaction txn, int id)? enqueue,
  }) async {
    final rows = await AppDatabase.instance.db.query(
      'service_records',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Nota asal tidak ditemukan.');
    return create(
      notaSyncId: rows.first['sync_id'] as String,
      nilaiBaru: nilaiBaru,
      alasan: alasan,
      actor: actor,
      ownerPin: ownerPin,
      approverSecret: approverSecret,
      enqueue: enqueue,
    );
  }

  Future<List<NotaAdjustment>> listForNota(String notaSyncId) async {
    final rows = await AppDatabase.instance.db.query(
      'nota_adjustments',
      where: 'nota_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [notaSyncId],
      orderBy: 'created_at',
    );
    return rows.map(NotaAdjustment.fromRow).toList();
  }

  Future<int> adjustedTotal(int recordId) async {
    return _currentTotal(AppDatabase.instance.db, recordId);
  }

  Future<int> adjustedTotalBySync(String notaSyncId) async {
    final rows = await AppDatabase.instance.db.query(
      'service_records',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [notaSyncId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Nota asal tidak ditemukan.');
    return adjustedTotal(rows.first['id'] as int);
  }

  Future<int> _currentTotal(DatabaseExecutor txn, int recordId) async {
    // Koreksi terakhir menurut HLC menentukan total; SUM selisih akan
    // menghitung ganda koreksi yang dibuat bersamaan di dua perangkat.
    final rows = await txn.rawQuery(
      '''
      SELECT ${AppDatabase.latestAdjustmentTotalSql(
        notaSyncIdExpr: 'r.sync_id',
        fallbackExpr: 'r.total_servis',
      )} AS total
      FROM service_records r WHERE r.id = ? LIMIT 1
      ''',
      [recordId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<void> applyRemote(
    DatabaseExecutor txn,
    Map<String, Object?> payload, {
    required int wall,
    required int counter,
  }) async {
    final syncId = payload['sync_id'] as String? ?? '';
    final notaSync = payload['nota_sync_id'] as String? ?? '';
    if (syncId.isEmpty || notaSync.isEmpty) return;
    final existing = await txn.query(
      'nota_adjustments',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final record = await txn.query(
      'service_records',
      where: 'sync_id = ?',
      whereArgs: [notaSync],
      limit: 1,
    );
    if (record.isEmpty) {
      // Koreksi bisa tiba sebelum nota induknya; amplop harus dicoba lagi,
      // bukan dianggap selesai sehingga koreksi hilang permanen.
      throw RetryableSyncException(
        'Koreksi menunggu nota asal ($notaSync).',
        code: 'koreksi_tanpa_nota',
      );
    }
    if (record.first['voided_at'] != null ||
        '${record.first['status']}' == 'VOID') {
      // Nota VOID bersifat terminal dan tidak lagi memiliki nilai efektif.
      // Pemanggil mencatat konflik agar koreksi yang tidak dapat diterapkan
      // tetap terlihat oleh pemilik.
      return;
    }
    final nilaiBaru = (payload['nilai_baru'] as num?)?.toInt() ?? 0;
    final hasAllocation =
        payload.containsKey('nominal_jasa') ||
        payload.containsKey('nominal_part');
    final allocation = hasAllocation
        ? (
            (payload['nominal_jasa'] as num?)?.toInt() ?? 0,
            (payload['nominal_part'] as num?)?.toInt() ?? 0,
          )
        : _splitAdjustment(
            target: nilaiBaru,
            totalServis:
                (record.first['total_servis'] as num?)?.toInt() ?? 0,
            biayaJasa: (record.first['biaya_jasa'] as num?)?.toInt() ?? 0,
            totalPart: (record.first['total_part'] as num?)?.toInt() ?? 0,
          );
    final tax = payload.containsKey('dpp_cents')
        ? (
            (payload['dpp_cents'] as num?)?.toInt() ?? 0,
            (payload['ppn_cents'] as num?)?.toInt() ?? 0,
            (payload['pajak_diserap_cents'] as num?)?.toInt() ?? 0,
          )
        : _scaledTaxSnapshot(
            target: nilaiBaru,
            totalServis:
                (record.first['total_servis'] as num?)?.toInt() ?? 0,
            mode: '${record.first['pajak_mode'] ?? pajakModeTanpa}',
            dpp: (record.first['pajak_dpp'] as num?)?.toInt() ?? 0,
            pajak: (record.first['pajak'] as num?)?.toInt() ?? 0,
            diserap: (record.first['pajak_diserap'] as num?)?.toInt() ?? 0,
          );
    await txn.insert('nota_adjustments', {
      'sync_id': syncId,
      'nota_sync_id': notaSync,
      'nilai_selisih': payload['nilai_selisih'] ?? 0,
      'nilai_baru': nilaiBaru,
      'nominal_jasa': allocation.$1,
      'nominal_part': allocation.$2,
      'diskon': (payload['diskon'] as num?)?.toInt() ?? 0,
      'dpp_cents': tax.$1,
      'ppn_cents': tax.$2,
      'pajak_diserap_cents': tax.$3,
      'alasan': payload['alasan'] ?? 'Koreksi dari perangkat lain',
      'dibuat_oleh': payload['dibuat_oleh'],
      'disetujui_oleh': payload['disetujui_oleh'],
      'sync_hlc_wall': wall,
      'sync_hlc_counter': counter,
      'created_at': payload['created_at'] ?? nowIso(),
      'updated_at': nowIso(),
    });
    await AppDatabase.instance.recalculateRecordTotals(
      txn,
      record.first['id'] as int,
    );
  }
}
