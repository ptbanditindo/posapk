import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Future<DashboardData>? _future;

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

  void _load() {
    if (!mounted) return;
    setState(() {
      _future = AppDatabase.instance.dashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: FutureBuilder<DashboardData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ListView(
              children: [
                EmptyState(
                  title: 'Ringkasan gagal dimuat',
                  subtitle: '${snapshot.error}',
                  icon: Icons.error_outline,
                  action: FilledButton(
                    onPressed: _load,
                    child: const Text('Coba lagi'),
                  ),
                ),
              ],
            );
          }
          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Ringkasan',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                dateId.format(DateTime.now()),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
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
                          label: 'Pendapatan hari ini',
                          value: formatRupiah(data.todayRevenueCents),
                          icon: Icons.payments_outlined,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: StatCard(
                          label: 'Transaksi hari ini',
                          value: '${data.todayCount}',
                          icon: Icons.receipt_long_outlined,
                          tone: Theme.of(context).colorScheme.tertiary,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: StatCard(
                          label: 'Stok menipis',
                          value: '${data.lowStockCount}',
                          icon: Icons.inventory_2_outlined,
                          tone: Theme.of(context).colorScheme.error,
                          onTap: () => widget.onNavigate(4),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: StatCard(
                          label: 'Piutang',
                          value: formatRupiah(data.receivableCents),
                          icon: Icons.account_balance_wallet_outlined,
                          tone: Colors.orange,
                          onTap: () => widget.onNavigate(2),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Aksi cepat',
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.point_of_sale_outlined, size: 18),
                      label: const Text('Kasir'),
                      onPressed: () => widget.onNavigate(1),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.people_outline, size: 18),
                      label: const Text('Pelanggan'),
                      onPressed: () => widget.onNavigate(3),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                      label: const Text('Stok'),
                      onPressed: () => widget.onNavigate(4),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.bar_chart_outlined, size: 18),
                      label: const Text('Laporan'),
                      onPressed: () => widget.onNavigate(6),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Nota terbaru',
                subtitle: '8 transaksi terakhir',
                child: data.recent.isEmpty
                    ? const EmptyState(
                        title: 'Belum ada nota',
                        subtitle: 'Mulai dari menu Kasir.',
                        icon: Icons.receipt_outlined,
                      )
                    : Column(
                        children: data.recent
                            .map(
                              (row) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  child: Text(
                                    row.customerNama.isEmpty
                                        ? '?'
                                        : row.customerNama[0].toUpperCase(),
                                  ),
                                ),
                                title: Text(row.customerNama),
                                subtitle: Text(
                                  '${row.noNota} · ${row.unitLabel}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      formatRupiah(row.totalCents),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      row.isVoid ? 'VOID' : row.statusBayar,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
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
    );
  }
}
