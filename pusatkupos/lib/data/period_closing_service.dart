import 'dart:convert';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../sync/crypto.dart';
import '../sync/sync_service.dart';
import 'app_database.dart';
import 'audit_service.dart';
import 'secure_store.dart';
import 'store_settings.dart';

class PeriodClosingResult {
  const PeriodClosingResult({
    required this.periode,
    required this.rev,
    required this.hash,
    required this.changed,
  });

  final String periode;
  final int rev;
  final String hash;
  final bool changed;

  String get message => changed
      ? 'Tutup buku $periode revisi $rev tersimpan.'
      : 'Periode $periode sudah tertutup dengan isi yang sama.';
}

/// Tutup buku bulanan (D24). Snapshot agregat tidak ikut dipurge sehingga
/// laporan periode lama tetap terbaca setelah nota lama dihapus lokal.
class PeriodClosingService {
  PeriodClosingService._();

  static final PeriodClosingService instance = PeriodClosingService._();

  Future<bool> _isOwnerDevice() async =>
      await SecureStore.instance.read('owner.signing.private') != null;

  Future<String> _zona(String? zona) async {
    if (zona != null && zona.isNotEmpty) return zona;
    final settings = await StoreSettingsService.instance.read();
    return settings?.zonaWaktu ?? zonaWaktuDefault;
  }

  /// Menutup otomatis bulan sebelumnya bila sudah lewat 7 hari dari akhir
  /// bulan. Hanya perangkat owner yang menjalankan; perangkat lain menerima
  /// dokumen lewat sinkronisasi.
  Future<PeriodClosingResult?> maybeAutoClose() async {
    if (!await _isOwnerDevice()) return null;
    final nowWall = storeWallTime(DateTime.now());
    if (nowWall.day < 8) return null;
    final previous = DateTime.utc(nowWall.year, nowWall.month - 1, 1);
    final periode =
        '${previous.year.toString().padLeft(4, '0')}-'
        '${previous.month.toString().padLeft(2, '0')}';
    final storeId = await SyncService.instance.storeId();
    final existing = await AppDatabase.instance.db.query(
      'period_closings',
      columns: ['sync_id'],
      where: 'store_id = ? AND periode = ? AND status = ? '
          'AND deleted_at IS NULL',
      whereArgs: [storeId, periode, 'FINAL'],
      limit: 1,
    );
    if (existing.isNotEmpty) return null;
    return close(periode);
  }

  Future<PeriodClosingResult> close(
    String periode, {
    String? zona,
    bool manual = true,
  }) async {
    if (!await _isOwnerDevice()) {
      throw StateError('Tutup buku hanya dapat dilakukan perangkat owner.');
    }
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(periode)) {
      throw ArgumentError('Periode tutup buku harus berformat YYYY-MM.');
    }
    final storeId = await SyncService.instance.storeId();
    final zonaResolved = await _zona(zona);
    final aggregate = await _aggregate(periode);
    final hashPayload = {
      'periode': periode,
      'zona': zonaResolved,
      ...aggregate,
    };
    final hash = sha256Hex(
      utf8.encode(canonicalJson(hashPayload)),
    );
    final db = AppDatabase.instance.db;
    final latest = await db.query(
      'period_closings',
      where: 'store_id = ? AND periode = ? AND deleted_at IS NULL',
      whereArgs: [storeId, periode],
      orderBy: 'rev DESC',
      limit: 1,
    );
    if (latest.isNotEmpty && '${latest.first['hash'] ?? ''}' == hash) {
      return PeriodClosingResult(
        periode: periode,
        rev: (latest.first['rev'] as num?)?.toInt() ?? 1,
        hash: hash,
        changed: false,
      );
    }
    final rev =
        latest.isEmpty ? 1 : ((latest.first['rev'] as num?)?.toInt() ?? 0) + 1;
    final syncId = newSyncId();
    final now = nowIso();
    await db.transaction((txn) async {
      await txn.insert('period_closings', {
        'sync_id': syncId,
        'store_id': storeId,
        'device_id': await AppDatabase.instance.deviceCode(txn),
        'periode': periode,
        'rev': rev,
        'zona': zonaResolved,
        'omzet_cents': aggregate['omzet_cents'],
        'dpp_cents': aggregate['dpp_cents'],
        'ppn_cents': aggregate['ppn_cents'],
        'hpp_cents': aggregate['hpp_cents'],
        'retur_nilai_cents': aggregate['retur_nilai_cents'],
        'retur_hpp_cents': aggregate['retur_hpp_cents'],
        'kas_metode_json': aggregate['kas_metode_json'],
        'komisi_cents': aggregate['komisi_cents'],
        'transaksi': aggregate['transaksi'],
        'jasa_cents': aggregate['jasa_cents'],
        'part_cents': aggregate['part_cents'],
        'diskon_cents': aggregate['diskon_cents'],
        'dibayar_cents': aggregate['dibayar_cents'],
        'piutang_cents': aggregate['piutang_cents'],
        'modal_part_cents': aggregate['modal_part_cents'],
        'modal_jasa_cents': aggregate['modal_jasa_cents'],
        'laba_part_cents': aggregate['laba_part_cents'],
        'laba_jasa_cents': aggregate['laba_jasa_cents'],
        'ppn_diserap_cents': aggregate['ppn_diserap_cents'],
        'retur_jasa_cents': aggregate['retur_jasa_cents'],
        'retur_part_cents': aggregate['retur_part_cents'],
        'gaji_cents': aggregate['gaji_cents'],
        'jenis_json': aggregate['jenis_json'],
        'hash': hash,
        'closed_at': now,
        'status': 'FINAL',
        'created_at': now,
        'updated_at': now,
      });
      await AuditService.instance.record(
        txn,
        aksi: manual ? 'tutup_buku_manual' : 'tutup_buku_otomatis',
        entity: 'period_closing',
        entityId: syncId,
        aktor: Operator.owner.label,
        after: {
          'periode': periode,
          'rev': rev,
          'hash': hash,
          'omzet_cents': aggregate['omzet_cents'],
        },
      );
    });
    await SyncService.instance.enqueuePeriodClosing(syncId);
    return PeriodClosingResult(
      periode: periode,
      rev: rev,
      hash: hash,
      changed: true,
    );
  }

  Future<Map<String, Object?>?> latest(String periode) async {
    final storeId = await SyncService.instance.storeId();
    final rows = await AppDatabase.instance.db.query(
      'period_closings',
      where: 'store_id = ? AND periode = ? AND deleted_at IS NULL',
      whereArgs: [storeId, periode],
      orderBy: 'rev DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Snapshot diambil dari sumber yang sama dengan layar Laporan sehingga
  /// laporan periode lama tetap identik setelah nota lama dipurge.
  Future<Map<String, Object?>> _aggregate(String periode) async {
    final parts = periode.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final from = DateTime(year, month, 1);
    final to = DateTime(year, month + 1, 0);
    final summary = await AppDatabase.instance.reportSummary(from, to);
    return {
      'omzet_cents': summary.totalCents,
      'dpp_cents': summary.totalDppCents,
      'ppn_cents': summary.pajakCents,
      'hpp_cents': summary.totalModalCents,
      'retur_nilai_cents': summary.returDitagihCents,
      'retur_hpp_cents': summary.returModalCents,
      'retur_jasa_cents': summary.returJasaCents,
      'retur_part_cents': summary.returPartCents,
      'komisi_cents': summary.komisiCents,
      'kas_metode_json': jsonEncode(summary.cashByMethod),
      'transaksi': summary.transaksi,
      'jasa_cents': summary.totalJasaCents,
      'part_cents': summary.totalPartCents,
      'diskon_cents': summary.diskonCents,
      'dibayar_cents': summary.dibayarCents,
      'piutang_cents': summary.piutangCents,
      'modal_part_cents': summary.totalModalPartCents,
      'modal_jasa_cents': summary.totalModalJasaCents,
      'laba_part_cents': summary.labaKotorPartCents,
      'laba_jasa_cents': summary.labaKotorJasaCents,
      'ppn_diserap_cents': summary.pajakDiserapCents,
      'gaji_cents': summary.gajiCents,
      'jenis_json': jsonEncode({
        for (final entry in summary.countByType.entries)
          entry.key: {
            'jumlah': entry.value,
            'total': summary.totalByType[entry.key] ?? 0,
          },
      }),
    };
  }
}
