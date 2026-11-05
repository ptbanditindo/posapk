import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
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
  Future<ReportSummary>? _future;
  ReportSummary? _summary;
  List<ServiceRecordSummary> _rows = [];
  List<BelowPriceSale> _below = [];
  List<CorrectionEntry> _corrections = [];
  List<EstimateAgingRow> _estimates = [];
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

  (DateTime, DateTime) get _range {
    final now = DateTime.now();
    return switch (_preset) {
      _ReportPreset.today => (now, now),
      _ReportPreset.week => (now.subtract(const Duration(days: 6)), now),
      _ReportPreset.month => (DateTime(now.year, now.month, 1), now),
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
    final results = await Future.wait<Object>([
      db.reportSummary(from, to),
      db.listRecords(from: from, to: to, limit: _pageSize),
      if (AppState.instance.isOwner) db.belowPriceSales(from, to),
      if (AppState.instance.isOwner) db.correctionsInRange(from, to),
      if (AppState.instance.isOwner) db.estimateAging(from, to),
    ]);
    final summary = results[0] as ReportSummary;
    final rows = results[1] as List<ServiceRecordSummary>;
    final owner = AppState.instance.isOwner;
    if (mounted) {
      setState(() {
        _summary = summary;
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
        _hasMore = rows.length == _pageSize;
      });
    }
    return summary;
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
        Text(
          'Laporan',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _chip('Hari ini', _ReportPreset.today),
            _chip('7 hari', _ReportPreset.week),
            _chip('Bulan ini', _ReportPreset.month),
            _chip('Semua', _ReportPreset.all),
          ],
        ),
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
                title: 'Laporan gagal dimuat',
                subtitle: '${snapshot.error}',
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
                            label: 'Total transaksi',
                            value: '${summary.transaksi}',
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Omzet',
                            value: formatRupiah(summary.totalCents),
                            icon: Icons.payments_outlined,
                            tone: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Dibayar',
                            value: formatRupiah(summary.dibayarCents),
                            icon: Icons.account_balance_wallet_outlined,
                            tone: Colors.green,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Piutang',
                            value: formatRupiah(summary.piutangCents),
                            icon: Icons.schedule_outlined,
                            tone: Colors.orange,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Rincian',
                  child: Column(
                    children: [
                      _line('Jasa', formatRupiah(summary.totalJasaCents)),
                      _line('Part', formatRupiah(summary.totalPartCents)),
                      _line('Diskon', '-${formatRupiah(summary.diskonCents)}'),
                      const Divider(),
                      _line(
                        'Total',
                        formatRupiah(summary.totalCents),
                        bold: true,
                      ),
                      const SizedBox(height: 8),
                      _line(
                        'Modal part',
                        formatRupiah(summary.totalModalPartCents),
                      ),
                      _line(
                        'Laba kotor part (sebelum diskon)',
                        formatRupiah(summary.labaKotorPartCents),
                      ),
                      const Divider(),
                      _line('Komisi', formatRupiah(summary.komisiCents)),
                      _line('Gaji dibayar', formatRupiah(summary.gajiCents)),
                      _line(
                        'Laba setelah komisi & gaji',
                        formatRupiah(
                          summary.totalCents -
                              summary.totalModalPartCents -
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
                if (AppState.instance.isOwner) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Penjualan di bawah harga terdaftar',
                    subtitle: _below.isEmpty
                        ? 'Tidak ada selisih harga pada periode ini.'
                        : '${_below.length} baris perlu ditinjau',
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
                ],
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Kas per metode',
                  subtitle: 'Berdasarkan tanggal pembayaran, termasuk refund',
                  child: summary.cashByMethod.isEmpty
                      ? const Text('Belum ada pembayaran pada periode ini.')
                      : Column(
                          children: summary.cashByMethod.entries
                              .map(
                                (entry) => _line(
                                  entry.key,
                                  formatRupiah(entry.value),
                                ),
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
                          title: 'Tidak ada transaksi',
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
                                        : 'Muat lebih banyak',
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
        _line('Belum dikonversi', '${unconverted.length}'),
        _line('Sudah kedaluwarsa', '$expired'),
        _line('Selisih estimasi vs nota', formatRupiah(variance)),
        if (perCashier.isNotEmpty) ...[
          const Divider(),
          ...perCashier.entries.map(
            (entry) => _line(
              'Belum konversi · ${entry.key}',
              '${entry.value}',
            ),
          ),
        ],
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
