import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../core/dates.dart';
import 'app_database.dart';
import 'backup_platform_stub.dart'
    if (dart.library.io) 'backup_platform_io.dart'
    as platform;
import 'pajak.dart';

/// Rincian PPN per kombinasi mode, tarif, dan penanggung.
class PajakRincian {
  const PajakRincian({
    required this.mode,
    required this.persenBp,
    required this.penanggung,
    required this.jumlahNota,
    required this.dppCents,
    required this.pajakCents,
    required this.diserapCents,
    required this.returDppCents,
    required this.returPajakCents,
  });

  final String mode;
  final int persenBp;
  final String penanggung;
  final int jumlahNota;
  final int dppCents;
  final int pajakCents;
  final int diserapCents;
  final int returDppCents;
  final int returPajakCents;

  int get dppNetoCents => dppCents - returDppCents;
  int get pajakNetoCents => pajakCents - returPajakCents;

  String get label =>
      '${pajakModeLabel(mode)} · ${formatPersenBp(persenBp)} · '
      '${pajakPenanggungLabel(penanggung)}';
}

/// Rekap PPN satu masa (bulan). Semua nilai dalam sen.
class PajakRekap {
  const PajakRekap({
    required this.masa,
    required this.from,
    required this.to,
    required this.jumlahNota,
    required this.jumlahRetur,
    required this.jumlahPembelian,
    required this.dppKeluaranCents,
    required this.pajakKeluaranCents,
    required this.pajakDiserapCents,
    required this.returDppCents,
    required this.returPajakCents,
    required this.returDiserapCents,
    required this.pajakMasukanCents,
    required this.returMasukanCents,
    required this.pajakDibayarCents,
    required this.rincian,
  });

  final String masa;
  final DateTime from;
  final DateTime to;
  final int jumlahNota;
  final int jumlahRetur;
  final int jumlahPembelian;

  final int dppKeluaranCents;
  final int pajakKeluaranCents;
  final int pajakDiserapCents;
  final int returDppCents;
  final int returPajakCents;
  final int returDiserapCents;
  final int pajakMasukanCents;
  final int returMasukanCents;
  final int pajakDibayarCents;
  final List<PajakRincian> rincian;

  int get dppNetoCents => dppKeluaranCents - returDppCents;

  /// PPN yang harus disetor: keluaran bersih retur dikurangi masukan bersih
  /// retur pembelian. PPN diserap bengkel tetap menjadi kewajiban setor dan
  /// hanya ditampilkan terpisah sebagai biaya.
  int get pajakMasukanNetoCents => pajakMasukanCents - returMasukanCents;

  int get pajakNetoCents =>
      pajakKeluaranCents - returPajakCents - pajakMasukanNetoCents;

  int get diserapNetoCents => pajakDiserapCents - returDiserapCents;

  int get sisaKewajibanCents => pajakNetoCents - pajakDibayarCents;

  bool get adaData =>
      jumlahNota > 0 ||
      jumlahRetur > 0 ||
      jumlahPembelian > 0 ||
      pajakDibayarCents > 0;
}

class PajakReportService {
  PajakReportService._();

  static final PajakReportService instance = PajakReportService._();

  static final RegExp _masaPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');

  static bool validMasa(String masa) => _masaPattern.hasMatch(masa);

  static DateTime startOfMasa(String masa) {
    if (!validMasa(masa)) {
      throw ArgumentError('Masa PPN harus berformat YYYY-MM.');
    }
    final year = int.parse(masa.substring(0, 4));
    final month = int.parse(masa.substring(5, 7));
    return DateTime(year, month, 1);
  }

  static DateTime endOfMasa(String masa) {
    final start = startOfMasa(masa);
    return DateTime(start.year, start.month + 1, 0, 23, 59, 59, 999);
  }

  static String masaOf(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  static String masaLabel(String masa) {
    final start = startOfMasa(masa);
    const months = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    return '${months[start.month - 1]} ${start.year}';
  }

  Future<PajakRekap> rekap(String masa) async {
    final db = AppDatabase.instance.db;
    final from = startOfMasa(masa);
    final to = endOfMasa(masa);
    final startIso = isoStartOfDay(from);
    final endIso = isoEndOfDay(to);

    final output = await db.rawQuery(
      '''
      SELECT COUNT(*) AS jumlah,
        COALESCE(SUM(pajak_dpp), 0) AS dpp,
        COALESCE(SUM(pajak), 0) AS pajak,
        COALESCE(SUM(pajak_diserap), 0) AS diserap
      FROM service_records
      WHERE waktu_service BETWEEN ? AND ? AND status != 'VOID'
      ''',
      [startIso, endIso],
    );
    final outputRow = output.first;

    final retur = await db.rawQuery(
      '''
      SELECT COUNT(*) AS jumlah,
        COALESCE(SUM(dpp), 0) AS dpp,
        COALESCE(SUM(pajak), 0) AS pajak,
        COALESCE(SUM(pajak_diserap), 0) AS diserap
      FROM sale_returns
      WHERE created_at BETWEEN ? AND ? AND status = 'AKTIF'
        AND deleted_at IS NULL
      ''',
      [startIso, endIso],
    );
    final returRow = retur.first;

    final purchase = await db.rawQuery(
      '''
      SELECT COUNT(*) AS jumlah,
        COALESCE(SUM(ppn), 0) AS ppn
      FROM supplier_purchases
      WHERE substr(tanggal, 1, 7) = ? AND status = 'AKTIF'
        AND deleted_at IS NULL
      ''',
      [masa],
    );
    final purchaseRow = purchase.first;

    final returMasukan = await _returMasukanCents(
      db,
      startIso: startIso,
      endIso: endIso,
    );

    final paid = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(nominal), 0) AS total
      FROM pajak_pembayaran
      WHERE masa = ? AND status = 'AKTIF' AND deleted_at IS NULL
      ''',
      [masa],
    );

    return PajakRekap(
      masa: masa,
      from: from,
      to: to,
      jumlahNota: _int(outputRow['jumlah']),
      jumlahRetur: _int(returRow['jumlah']),
      jumlahPembelian: _int(purchaseRow['jumlah']),
      dppKeluaranCents: _int(outputRow['dpp']),
      pajakKeluaranCents: _int(outputRow['pajak']),
      pajakDiserapCents: _int(outputRow['diserap']),
      returDppCents: _int(returRow['dpp']),
      returPajakCents: _int(returRow['pajak']),
      returDiserapCents: _int(returRow['diserap']),
      pajakMasukanCents: _int(purchaseRow['ppn']),
      returMasukanCents: returMasukan,
      pajakDibayarCents: _int(paid.first['total']),
      rincian: await _rincian(db, startIso: startIso, endIso: endIso),
    );
  }

  Future<int> _returMasukanCents(
    DatabaseExecutor db, {
    required String startIso,
    required String endIso,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT pr.purchase_id,
        p.ppn, p.subtotal, p.diskon, p.ongkir,
        COALESCE(SUM(CASE WHEN pr.created_at < ?
          THEN pr.total ELSE 0 END), 0) AS total_sebelum,
        COALESCE(SUM(CASE WHEN pr.created_at BETWEEN ? AND ?
          THEN pr.total ELSE 0 END), 0) AS total_bulan
      FROM supplier_purchase_returns pr
      JOIN supplier_purchases p ON p.id = pr.purchase_id
      WHERE pr.status = 'AKTIF' AND pr.deleted_at IS NULL
        AND p.status = 'AKTIF' AND p.deleted_at IS NULL
      GROUP BY pr.purchase_id
      ''',
      [startIso, startIso, endIso],
    );
    var total = 0;
    for (final row in rows) {
      final ppn = _int(row['ppn']);
      if (ppn <= 0) continue;
      final base = _int(row['subtotal']) -
          _int(row['diskon']) +
          _int(row['ongkir']);
      if (base <= 0) continue;
      final sebelum = _int(row['total_sebelum']);
      final bulan = _int(row['total_bulan']);
      if (bulan <= 0) continue;
      final pajakSebelum = _ppnProporsional(ppn, base, sebelum);
      final pajakSesudah = _ppnProporsional(ppn, base, sebelum + bulan);
      total += pajakSesudah - pajakSebelum;
    }
    return total < 0 ? 0 : total;
  }

  int _ppnProporsional(int ppn, int base, int nilai) {
    if (ppn <= 0 || base <= 0 || nilai <= 0) return 0;
    final capped = nilai > base ? base : nilai;
    return ((ppn * capped) + base ~/ 2) ~/ base;
  }

  Future<List<PajakRincian>> _rincian(
    DatabaseExecutor db, {
    required String startIso,
    required String endIso,
  }) async {
    final output = await db.rawQuery(
      '''
      SELECT pajak_mode, pajak_persen_bp, pajak_penanggung,
        COUNT(*) AS jumlah,
        COALESCE(SUM(pajak_dpp), 0) AS dpp,
        COALESCE(SUM(pajak), 0) AS pajak,
        COALESCE(SUM(pajak_diserap), 0) AS diserap
      FROM service_records
      WHERE waktu_service BETWEEN ? AND ? AND status != 'VOID'
        AND pajak_mode <> 'TANPA' AND pajak_persen_bp > 0
      GROUP BY pajak_mode, pajak_persen_bp, pajak_penanggung
      ''',
      [startIso, endIso],
    );
    final retur = await db.rawQuery(
      '''
      SELECT r.pajak_mode, r.pajak_persen_bp, r.pajak_penanggung,
        COALESCE(SUM(sr.dpp), 0) AS dpp,
        COALESCE(SUM(sr.pajak), 0) AS pajak
      FROM sale_returns sr
      JOIN service_records r ON r.id = sr.service_record_id
      WHERE sr.created_at BETWEEN ? AND ? AND sr.status = 'AKTIF'
        AND sr.deleted_at IS NULL
        AND r.pajak_mode <> 'TANPA' AND r.pajak_persen_bp > 0
      GROUP BY r.pajak_mode, r.pajak_persen_bp, r.pajak_penanggung
      ''',
      [startIso, endIso],
    );

    final rows = <String, Map<String, Object?>>{};
    for (final row in output) {
      rows[_key(row)] = {
        'mode': row['pajak_mode'],
        'persen_bp': row['pajak_persen_bp'],
        'penanggung': row['pajak_penanggung'],
        'jumlah': row['jumlah'],
        'dpp': row['dpp'],
        'pajak': row['pajak'],
        'diserap': row['diserap'],
        'retur_dpp': 0,
        'retur_pajak': 0,
      };
    }
    for (final row in retur) {
      final key = _key(row);
      final target = rows.putIfAbsent(
        key,
        () => {
          'mode': row['pajak_mode'],
          'persen_bp': row['pajak_persen_bp'],
          'penanggung': row['pajak_penanggung'],
          'jumlah': 0,
          'dpp': 0,
          'pajak': 0,
          'diserap': 0,
          'retur_dpp': 0,
          'retur_pajak': 0,
        },
      );
      target['retur_dpp'] = row['dpp'];
      target['retur_pajak'] = row['pajak'];
    }

    final result = rows.values
        .map(
          (row) => PajakRincian(
            mode: '${row['mode']}',
            persenBp: _int(row['persen_bp']),
            penanggung: '${row['penanggung']}',
            jumlahNota: _int(row['jumlah']),
            dppCents: _int(row['dpp']),
            pajakCents: _int(row['pajak']),
            diserapCents: _int(row['diserap']),
            returDppCents: _int(row['retur_dpp']),
            returPajakCents: _int(row['retur_pajak']),
          ),
        )
        .toList();
    result.sort((a, b) {
      final mode = a.mode.compareTo(b.mode);
      if (mode != 0) return mode;
      final rate = a.persenBp.compareTo(b.persenBp);
      if (rate != 0) return rate;
      return a.penanggung.compareTo(b.penanggung);
    });
    return result;
  }

  String _key(Map<String, Object?> row) =>
      '${row['pajak_mode']}|${row['pajak_persen_bp']}|'
      '${row['pajak_penanggung']}';

  /// Ekspor CSV memakai pemisah titik koma agar langsung terbaca Excel
  /// Indonesia. Nilai uang memakai koma desimal.
  String rekapCsv(PajakRekap rekap) {
    final lines = <String>[
      'Rekap PPN;${rekap.masa}',
      'Catatan;Rekap internal, bukan e-Faktur resmi',
      '',
      'Keterangan;Nilai',
      'PPN keluaran (Rp);${_money(rekap.pajakKeluaranCents)}',
      'DPP keluaran (Rp);${_money(rekap.dppKeluaranCents)}',
      'Retur PPN keluaran (Rp);${_money(rekap.returPajakCents)}',
      'Retur DPP (Rp);${_money(rekap.returDppCents)}',
      'PPN masukan pembelian (Rp);${_money(rekap.pajakMasukanCents)}',
      'Retur PPN masukan (Rp);${_money(rekap.returMasukanCents)}',
      'PPN diserap bengkel (Rp);${_money(rekap.diserapNetoCents)}',
      'PPN neto (Rp);${_money(rekap.pajakNetoCents)}',
      'PPN sudah dibayar (Rp);${_money(rekap.pajakDibayarCents)}',
      'Sisa kewajiban (Rp);${_money(rekap.sisaKewajibanCents)}',
      '',
      'Mode;Tarif;Penanggung;Jumlah nota;DPP;PPN;PPN diserap;'
          'Retur DPP;Retur PPN',
    ];
    for (final row in rekap.rincian) {
      lines.add(
        '${row.mode};${formatPersenBp(row.persenBp)};${row.penanggung};'
        '${row.jumlahNota};${_money(row.dppCents)};'
        '${_money(row.pajakCents)};${_money(row.diserapCents)};'
        '${_money(row.returDppCents)};${_money(row.returPajakCents)}',
      );
    }
    return '\uFEFF${lines.join('\r\n')}\r\n';
  }

  /// Menyimpan CSV ke folder aplikasi agar dapat dilampirkan manual.
  Future<String> exportCsv(PajakRekap rekap) async {
    final folder = await platform.autoBackupFolder();
    final target = p.join(p.dirname(folder), 'pajak');
    final name = 'rekap-ppn-${rekap.masa}.csv';
    return platform.writeBackupFile(target, name, utf8.encode(rekapCsv(rekap)));
  }

  String _money(int cents) {
    final sign = cents < 0 ? '-' : '';
    final value = cents.abs();
    final whole = value ~/ 100;
    final fraction = (value % 100).toString().padLeft(2, '0');
    return '$sign$whole,$fraction';
  }

  static int _int(Object? value) => (value as num?)?.toInt() ?? 0;

  Future<List<Map<String, Object?>>> listPayments(String masa) async {
    return AppDatabase.instance.db.query(
      'pajak_pembayaran',
      where: 'masa = ? AND deleted_at IS NULL',
      whereArgs: [masa],
      orderBy: 'dibayar_at DESC, id DESC',
    );
  }

  Future<int> totalPaid(String masa) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT COALESCE(SUM(nominal), 0) AS total
      FROM pajak_pembayaran
      WHERE masa = ? AND status = 'AKTIF' AND deleted_at IS NULL
      ''',
      [masa],
    );
    return _int(rows.first['total']);
  }
}
