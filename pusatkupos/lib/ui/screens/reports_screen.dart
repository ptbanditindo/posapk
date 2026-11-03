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
  _ReportPreset _preset = _ReportPreset.today;
  Future<_ReportData>? _future;

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
      _future = _loadData(range.$1, range.$2);
    });
  }

  Future<_ReportData> _loadData(DateTime from, DateTime to) async {
    final summary = await AppDatabase.instance.reportSummary(from, to);
    final rows = await AppDatabase.instance.listRecords(
      from: from,
      to: to,
      limit: 200,
    );
    return _ReportData(summary: summary, rows: rows);
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
        FutureBuilder<_ReportData>(
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
            final data = snapshot.data!;
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
                            value: '${data.summary.transaksi}',
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Omzet',
                            value: formatRupiah(data.summary.totalCents),
                            icon: Icons.payments_outlined,
                            tone: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Dibayar',
                            value: formatRupiah(data.summary.dibayarCents),
                            icon: Icons.account_balance_wallet_outlined,
                            tone: Colors.green,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: StatCard(
                            label: 'Piutang',
                            value: formatRupiah(data.summary.piutangCents),
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
                      _line('Jasa', formatRupiah(data.summary.totalJasaCents)),
                      _line('Part', formatRupiah(data.summary.totalPartCents)),
                      _line('Diskon', '-${formatRupiah(data.summary.diskonCents)}'),
                      const Divider(),
                      _line(
                        'Total',
                        formatRupiah(data.summary.totalCents),
                        bold: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Transaksi periode ini',
                  subtitle: '${data.rows.length} nota',
                  child: data.rows.isEmpty
                      ? const EmptyState(
                          title: 'Tidak ada transaksi',
                          icon: Icons.inbox_outlined,
                        )
                      : Column(
                          children: data.rows
                              .map(
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
                              )
                              .toList(),
                        ),
                ),
              ],
            );
          },
        ),
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

class _ReportData {
  const _ReportData({required this.summary, required this.rows});

  final ReportSummary summary;
  final List<ServiceRecordSummary> rows;
}
