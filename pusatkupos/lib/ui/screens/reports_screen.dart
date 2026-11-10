import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../data/opening_balance_service.dart';
import '../../data/period_closing_service.dart';
import '../../data/purchase_service.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

enum _ReportPreset { today, week, month, all }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _pageSize = 50;

  _ReportPreset _preset = _ReportPreset.today;
  int _monthOffset = 0;
  Future<ReportSummary>? _future;
  ReportSummary? _summary;
  List<ServiceRecordSummary> _rows = [];
  List<BelowPriceSale> _below = [];
  List<CorrectionEntry> _corrections = [];
  List<EstimateAgingRow> _estimates = [];
  List<Map<String, Object?>> _margin = const [];
  List<Map<String, Object?>> _valuation = const [];
  Map<String, Object?>? _opening;
  Map<String, Object?>? _closing;
  bool _fromSnapshot = false;
  bool _hasMore = false;
  bool _loadingMore = false;

  static const _typeLabels = {
    'jual_sparepart': 'Jual sparepart',
    'servis_langsung': 'Servis langsung',
    'order_kerja': 'Order kerja',
    'pelunasan_order': 'Pelunasan order',
  };

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    super.dispose();
  }

  DateTime get _monthAnchor {
    final now = DateTime.now();
    return DateTime(now.year, now.month - _monthOffset, 1);
  }

  String get _periode {
    final anchor = _monthAnchor;
    return '${anchor.year}-${anchor.month.toString().padLeft(2, '0')}';
  }

  (DateTime, DateTime) get _range {
    final now = DateTime.now();
    return switch (_preset) {
      _ReportPreset.today => (now, now),
      _ReportPreset.week => (now.subtract(const Duration(days: 6)), now),
      _ReportPreset.month => _monthOffset == 0
          ? (_monthAnchor, now)
          : (_monthAnchor, DateTime(_monthAnchor.year, _monthAnchor.month + 1, 0)),
      _ReportPreset.all => (DateTime(2000), now),
    };
  }

  void _load() {
    if (!mounted) return;
    final range = _range;
    setState(() {
      _rows = [];
      _summary = null;
      _hasMore = false;
      _future = _loadFirst(range.$1, range.$2);
    });
  }

  Future<ReportSummary> _loadFirst(DateTime from, DateTime to) async {
    final db = AppDatabase.instance;
    final owner = AppState.instance.isOwner;
    final closing = _preset == _ReportPreset.month
        ? await PeriodClosingService.instance.latest(_periode)
        : null;
    final snapshot = _monthOffset > 0 &&
            closing != null &&
            '${closing['status']}' == 'FINAL'
        ? _summaryFromClosing(closing)
        : null;
    final includeArchived = _preset == _ReportPreset.month && _monthOffset > 0;
    final results = await Future.wait<Object?>([
      snapshot != null ? Future.value(snapshot) : db.reportSummary(from, to),
      db.listRecords(
        from: from,
        to: to,
        limit: _pageSize,
        includeArchived: includeArchived,
      ),
      if (owner) db.belowPriceSales(from, to),
      if (owner) db.correctionsInRange(from, to),
      if (owner) db.estimateAging(from, to),
    ]);
    final summary = results[0] as ReportSummary;
    final rows = results[1] as List<ServiceRecordSummary>;
    final margin = owner
        ? await PurchaseService.instance.marginReport(from: from, to: to)
        : const <Map<String, Object?>>[];
    final valuation = owner
        ? await PurchaseService.instance.stockValuation()
        : const <Map<String, Object?>>[];
    final opening =
        owner ? await OpeningBalanceService.instance.active() : null;
    if (mounted) {
      setState(() {
        _summary = summary;
        _closing = closing;
        _fromSnapshot = snapshot != null;
        _rows = rows;
        _below = owner
            ? results[2] as List<BelowPriceSale>
            : const <BelowPriceSale>[];
        _corrections = owner
            ? results[3] as List<CorrectionEntry>
            : const <CorrectionEntry>[];
        _estimates = owner
            ? results[4] as List<EstimateAgingRow>
            : const <EstimateAgingRow>[];
        _margin = margin;
        _valuation = valuation;
        _opening = opening;
        _hasMore = rows.length == _pageSize;
      });
    }
    return summary;
  }

  /// Angka periode tertutup dibaca dari snapshot tutup buku. Nota periode itu
  /// boleh saja sudah dipurge, tetapi snapshot tidak ikut terhapus.
  ReportSummary _summaryFromClosing(Map<String, Object?> closing) {
    int value(String key) => (closing[key] as num?)?.toInt() ?? 0;
    Map<String, int> intMap(Object? raw) {
      final decoded = _decodeMap(raw);
      return {
        for (final entry in decoded.entries)
          entry.key: (entry.value as num?)?.toInt() ?? 0,
      };
    }

    final jenis = _decodeMap(closing['jenis_json']);
    final countByType = <String, int>{};
    final totalByType = <String, int>{};
    for (final entry in jenis.entries) {
      final row = entry.value;
      if (row is! Map) continue;
      countByType[entry.key] = (row['jumlah'] as num?)?.toInt() ?? 0;
      totalByType[entry.key] = (row['total'] as num?)?.toInt() ?? 0;
    }
    final totalModalPart = value('modal_part_cents');
    final totalModalJasa = value('modal_jasa_cents');
    return ReportSummary(
      transaksi: value('transaksi'),
      totalJasaCents: value('jasa_cents'),
      totalPartCents: value('part_cents'),
      diskonCents: value('diskon_cents'),
      totalCents: value('omzet_cents'),
      dibayarCents: value('dibayar_cents'),
      piutangCents: value('piutang_cents'),
      totalModalPartCents: totalModalPart,
      labaKotorPartCents: value('laba_part_cents') != 0
          ? value('laba_part_cents')
          : value('part_cents') - totalModalPart,
      totalModalJasaCents: totalModalJasa,
      labaKotorJasaCents: value('laba_jasa_cents') != 0
          ? value('laba_jasa_cents')
          : value('jasa_cents') - totalModalJasa,
      komisiCents: value('komisi_cents'),
      gajiCents: value('gaji_cents'),
      cashByMethod: intMap(closing['kas_metode_json']),
      countByType: countByType,
      totalByType: totalByType,
      returJasaCents: value('retur_jasa_cents'),
      returPartCents: value('retur_part_cents'),
      returModalCents: value('retur_hpp_cents'),
      returDitagihCents: value('retur_nilai_cents'),
      totalDppCents: value('dpp_cents'),
      pajakCents: value('ppn_cents'),
      pajakDiserapCents: value('ppn_diserap_cents'),
    );
  }

  Map<String, Object?> _decodeMap(Object? raw) {
    try {
      final decoded = jsonDecode('${raw ?? '{}'}');
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    return const {};
  }

  void _shiftMonth(int delta) {
    _monthOffset = (_monthOffset + delta).clamp(0, 240);
    _load();
  }

  Future<void> _tutupBuku() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    final periode =
        '${picked.year}-${picked.month.toString().padLeft(2, '0')}';
    try {
      final result = await PeriodClosingService.instance.close(periode);
      if (!mounted) return;
      showSnack(context, result.message);
      _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Tutup buku gagal: $error', error: true);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final range = _range;
    final rows = await AppDatabase.instance.listRecords(
      from: range.$1,
      to: range.$2,
      limit: _pageSize,
      offset: _rows.length,
      includeArchived: _preset == _ReportPreset.month && _monthOffset > 0,
    );
    if (!mounted) return;
    setState(() {
      _rows = [..._rows, ...rows];
      _hasMore = rows.length == _pageSize;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Laporan',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (AppState.instance.isOwner)
              OutlinedButton.icon(
                onPressed: _tutupBuku,
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Tutup buku bulanan'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _chip('Hari ini', _ReportPreset.today),
            _chip('7 hari terakhir', _ReportPreset.week),
            _chip('Per bulan', _ReportPreset.month),
            _chip('Semua waktu', _ReportPreset.all),
          ],
        ),
        if (_preset == _ReportPreset.month) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                tooltip: 'Bulan sebelumnya',
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  monthId.format(_monthAnchor),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Bulan berikutnya',
                onPressed: _monthOffset == 0
                    ? null
                    : () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        FutureBuilder<ReportSummary>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return EmptyState(
                title: 'Laporan belum bisa dimuat',
                subtitle: 'Data laporan tidak bisa dibaca: ${snapshot.error}. '
                    'Coba pilih ulang periode atau buka halaman ini lagi.',
                icon: Icons.error_outline,
              );
            }
            final summary = snapshot.data ?? _summary;
            if (summary == null) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth >= 760
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Jumlah nota',
                            value: '${summary.transaksi}',
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Omzet sebelum retur',
                            value: formatRupiah(summary.totalCents),
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Omzet setelah retur',
                            value: formatRupiah(summary.totalNetCents),
                            icon: Icons.payments_outlined,
                            tone: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Uang masuk dari nota periode ini',
                            value: formatRupiah(summary.dibayarCents),
                            icon: Icons.account_balance_wallet_outlined,
                            tone: Colors.green,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Sisa piutang nota periode ini',
                            value: formatRupiah(summary.piutangCents),
                            icon: Icons.schedule_outlined,
                            tone: Colors.orange,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Uang diterima periode ini',
                            value: formatRupiah(
                              summary.cashByMethod.values.fold<int>(
                                0,
                                (sum, value) => sum + value,
                              ),
                            ),
                            icon: Icons.savings_outlined,
                            tone: Colors.teal,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Penjualan, pembayaran, dan piutang dihitung dari tanggal '
                  'nota. Retur dihitung dari tanggal retur. Uang diterima '
                  'dihitung dari tanggal pembayaran.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_closing != null) ...[
                  const SizedBox(height: 16),
                  _ClosingCard(closing: _closing!),
                ],
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Rincian omzet dan laba',
                  child: Column(
                    children: [
                      _line(
                        'Penjualan jasa',
                        formatRupiah(summary.totalJasaCents),
                      ),
                      _line(
                        'Penjualan part',
                        formatRupiah(summary.totalPartCents),
                      ),
                      _line('Diskon', '-${formatRupiah(summary.diskonCents)}'),
                      const Divider(),
                      _line(
                        'Total',
                        formatRupiah(summary.totalCents),
                        bold: true,
                      ),
                      if (summary.returCents > 0) ...[
                        _line(
                          'Retur jasa (dikurangi)',
                          '-${formatRupiah(summary.returJasaCents)}',
                        ),
                        _line(
                          'Retur part (dikurangi)',
                          '-${formatRupiah(summary.returPartCents)}',
                        ),
                        _line(
                          'Penjualan setelah retur',
                          formatRupiah(summary.totalNetCents),
                          bold: true,
                        ),
                      ],
                      const SizedBox(height: 8),
                      _line(
                        'Modal part (HPP)',
                        formatRupiah(summary.totalModalPartCents),
                      ),
                      _line(
                        'Laba kotor part setelah diskon',
                        formatRupiah(summary.labaKotorPartCents),
                      ),
                      _line(
                        'Modal jasa (HPP)',
                        formatRupiah(summary.totalModalJasaCents),
                      ),
                      _line(
                        'Laba kotor jasa setelah diskon',
                        formatRupiah(summary.labaKotorJasaCents),
                      ),
                      const Divider(),
                      _line('Komisi', formatRupiah(summary.komisiCents)),
                      _line('Gaji dibayar', formatRupiah(summary.gajiCents)),
                      _line(
                        'Laba bersih setelah komisi dan gaji',
                        formatRupiah(
                          summary.labaKotorNetCents -
                              summary.komisiCents -
                              summary.gajiCents,
                        ),
                        bold: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Per jenis transaksi',
                  subtitle: 'Sudah termasuk koreksi nota, belum dikurangi retur',
                  child: summary.countByType.isEmpty
                      ? const Text('Belum ada transaksi pada periode ini.')
                      : Column(
                          children: summary.countByType.entries
                              .map(
                                (entry) => _line(
                                  '${_typeLabels[entry.key] ?? entry.key} '
                                  '(${entry.value}x)',
                                  formatRupiah(
                                    summary.totalByType[entry.key] ?? 0,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
                if (AppState.instance.isOwner && !_fromSnapshot) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Penjualan di bawah harga patokan',
                    subtitle: _below.isEmpty
                        ? 'Tidak ada selisih harga pada periode ini.'
                        : '${_below.length} baris perlu diperiksa',
                    child: _below.isEmpty
                        ? const SizedBox.shrink()
                        : Column(
                            children: _below
                                .map(
                                  (row) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: Text(
                                      '${row.noNota} · ${row.deskripsi}',
                                    ),
                                    subtitle: Text(
                                      '${row.labelHarga} · '
                                      '${dateId.format(row.waktu)} · '
                                      'Kasir: ${row.kasir ?? '-'}'
                                      '${row.disetujuiOleh == null ? '' : ' · '
                                                'Disetujui: ${row.disetujuiOleh}'}',
                                    ),
                                    trailing: Text(
                                      formatRupiah(row.selisihCents),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Koreksi nota',
                    subtitle: _corrections.isEmpty
                        ? 'Belum ada koreksi pada periode ini.'
                        : '${_corrections.length} koreksi',
                    child: _corrections.isEmpty
                        ? const SizedBox.shrink()
                        : Column(
                            children: _corrections
                                .map(
                                  (row) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: Text(row.noNota),
                                    subtitle: Text(
                                      '${row.alasan} · '
                                      '${row.dibuatOleh ?? '-'}'
                                      '${row.disetujuiOleh == null ? '' : ' · '
                                                'Disetujui: ${row.disetujuiOleh}'}',
                                    ),
                                    trailing: Text(
                                      formatRupiah(row.nilaiSelisihCents),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: row.nilaiSelisihCents < 0
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                            : Colors.green,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Estimasi',
                    subtitle: 'Tidak dihitung sebagai penjualan.',
                    child: _estimateSummary(context),
                  ),
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Margin per barang',
                    subtitle:
                        'Memakai modal (HPP) yang tersimpan di baris nota.',
                    child: _margin.isEmpty
                        ? const Text('Belum ada penjualan part pada periode ini.')
                        : Column(
                            children: _margin
                                .map(
                                  (row) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: Text('${row['nama_part']}'),
                                    subtitle: Text(
                                      'Jumlah ${formatQuantity((row['qty_milli'] as num).toInt(), 0)} · '
                                      'Modal ${formatRupiah((row['hpp'] as num).toInt())}',
                                    ),
                                    trailing: Text(
                                      formatRupiah((row['margin'] as num).toInt()),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ],
                if (AppState.instance.isOwner) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Nilai persediaan',
                    subtitle: 'Modal rata-rata per barang',
                    child: _valuation.isEmpty
                        ? const Text('Belum ada barang.')
                        : Column(
                            children: [
                              for (final row in _valuation.take(50))
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  title: Text('${row['nama']}'),
                                  subtitle: Text(
                                    '${formatQuantity((row['jumlah_milli'] as num).toInt(), 0, satuan: '${row['satuan'] ?? ''}')} · '
                                    'Modal per satuan ${formatRupiah((row['hpp_satuan'] as num).toInt())}',
                                  ),
                                  trailing: Text(
                                    formatRupiah(
                                      (row['nilai_persediaan'] as num).toInt(),
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              _line(
                                'Total nilai persediaan',
                                formatRupiah(
                                  _valuation.fold<int>(
                                    0,
                                    (sum, row) =>
                                        sum +
                                        (row['nilai_persediaan'] as num)
                                            .toInt(),
                                  ),
                                ),
                                bold: true,
                              ),
                            ],
                          ),
                  ),
                  if (_opening != null) ...[
                    const SizedBox(height: 16),
                    SectionCard(
                      title: 'Saldo awal toko',
                      subtitle: 'Dicatat sebelum transaksi berjalan dimulai',
                      child: _openingSummary(context),
                    ),
                  ],
                ],
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Uang diterima per metode',
                  subtitle: 'Dihitung dari tanggal pembayaran, termasuk '
                      'uang kembali (refund).',
                  child: summary.cashByMethod.isEmpty
                      ? const Text('Belum ada pembayaran pada periode ini.')
                      : Column(
                          children: summary.cashByMethod.entries
                              .map(
                                (entry) =>
                                    _line(entry.key, formatRupiah(entry.value)),
                              )
                              .toList(),
                        ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Transaksi periode ini',
                  subtitle: '${_rows.length} nota ditampilkan',
                  child: _rows.isEmpty
                      ? const EmptyState(
                          title: 'Belum ada nota',
                          subtitle: 'Nota yang tercatat pada periode ini akan '
                              'tampil di sini.',
                          icon: Icons.inbox_outlined,
                        )
                      : Column(
                          children: [
                            ..._rows.map(
                              (row) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(row.noNota),
                                subtitle: Text(
                                  '${row.customerNama} · '
                                  '${dateId.format(row.waktu)}',
                                ),
                                trailing: Text(
                                  formatRupiah(row.totalCents),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            if (_hasMore)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: OutlinedButton.icon(
                                  onPressed: _loadingMore ? null : _loadMore,
                                  icon: const Icon(Icons.expand_more),
                                  label: Text(
                                    _loadingMore
                                        ? 'Memuat...'
                                        : 'Muat 50 nota lagi',
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _estimateSummary(BuildContext context) {
    if (_estimates.isEmpty) {
      return const Text('Belum ada estimasi pada periode ini.');
    }
    final unconverted = _estimates
        .where((row) => !row.converted && row.status == 'aktif')
        .toList();
    final expired = _estimates.where((row) => row.kedaluwarsa).length;
    final variance = _estimates
        .where((row) => row.converted)
        .fold<int>(0, (sum, row) => sum + row.varianceCents);
    final perCashier = <String, int>{};
    for (final row in unconverted) {
      final name = row.dibuatOleh ?? 'Tanpa nama';
      perCashier.update(name, (value) => value + 1, ifAbsent: () => 1);
    }
    return Column(
      children: [
        _line('Estimasi belum jadi nota', '${unconverted.length}'),
        _line('Sudah kedaluwarsa', '$expired'),
        _line('Selisih estimasi dengan nota', formatRupiah(variance)),
        if (perCashier.isNotEmpty) ...[
          const Divider(),
          ...perCashier.entries.map(
            (entry) =>
                _line('Belum jadi nota · ${entry.key}', '${entry.value}'),
          ),
        ],
      ],
    );
  }

  Widget _openingSummary(BuildContext context) {
    final items =
        _opening?['items'] as List<Map<String, Object?>>? ?? const [];
    var stockQty = 0;
    var debt = 0;
    var receivable = 0;
    for (final item in items) {
      if (item['jenis'] == 'STOK') {
        stockQty += (item['jumlah_milli'] as num?)?.toInt() ?? 0;
      } else if (item['jenis'] == 'UTANG_SUPPLIER') {
        debt += (item['nominal'] as num?)?.toInt() ?? 0;
      } else if (item['jenis'] == 'PIUTANG_PELANGGAN') {
        receivable += (item['nominal'] as num?)?.toInt() ?? 0;
      }
    }
    return Column(
      children: [
        _line('Stok awal', formatQuantity(stockQty, 0)),
        _line('Utang supplier awal', formatRupiah(debt)),
        _line('Piutang pelanggan awal', formatRupiah(receivable)),
        _line('Banyak baris saldo awal', '${items.length}'),
      ],
    );
  }

  Widget _chip(String label, _ReportPreset preset) {
    return ChoiceChip(
      label: Text(label),
      selected: _preset == preset,
      onSelected: (_) {
        setState(() {
          _preset = preset;
          _load();
        });
      },
    );
  }

  Widget _line(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
        ],
      ),
    );
  }
}

/// Ringkasan tutup buku bulanan. Angka berasal dari snapshot yang tidak ikut
/// dipurge, sehingga laporan periode lama tetap terbaca setelah purge.
class _ClosingCard extends StatelessWidget {
  const _ClosingCard({required this.closing});

  final Map<String, Object?> closing;

  int _value(String key) => (closing[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    Map<String, Object?> kas = const {};
    try {
      final decoded = jsonDecode('${closing['kas_metode_json'] ?? '{}'}');
      if (decoded is Map) {
        kas = decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    final periode = '${closing['periode'] ?? ''}';
    final rev = (closing['rev'] as num?)?.toInt() ?? 1;
    return SectionCard(
      title: 'Tutup buku $periode (revisi $rev)',
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Angka final · ${closing['zona'] ?? ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Omzet ${formatRupiah(_value('omzet_cents'))}'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'DPP (dasar pajak) ${formatRupiah(_value('dpp_cents'))} · '
              'PPN ${formatRupiah(_value('ppn_cents'))}',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Modal (HPP) ${formatRupiah(_value('hpp_cents'))} · '
              'Komisi ${formatRupiah(_value('komisi_cents'))}',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Retur ${formatRupiah(_value('retur_nilai_cents'))} '
              '(HPP ${formatRupiah(_value('retur_hpp_cents'))})',
            ),
          ),
          if (kas.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Kas: ${kas.entries.map((entry) => '${entry.key} '
                    '${formatRupiah((entry.value as num?)?.toInt() ?? 0)}').join(' · ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
