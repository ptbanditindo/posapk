import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _search = TextEditingController();
  Future<List<ServiceRecordSummary>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      _future = AppDatabase.instance.listRecords(
        query: _search.text,
        limit: 200,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: 'Cari nota atau pelanggan',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => _load(),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Muat ulang',
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ServiceRecordSummary>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return EmptyState(
                  title: 'Riwayat gagal dimuat',
                  subtitle: '${snapshot.error}',
                  icon: Icons.error_outline,
                );
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return const EmptyState(
                  title: 'Belum ada riwayat',
                  subtitle: 'Nota yang tersimpan akan tampil di sini.',
                  icon: Icons.history,
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _load(),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => _openDetail(row.id),
                        leading: CircleAvatar(
                          backgroundColor: row.isVoid
                              ? Theme.of(context)
                                  .colorScheme
                                  .errorContainer
                              : null,
                          child: Icon(
                            row.isVoid
                                ? Icons.block_outlined
                                : Icons.receipt_long_outlined,
                          ),
                        ),
                        title: Text(
                          row.customerNama.isEmpty
                              ? row.noNota
                              : row.customerNama,
                        ),
                        subtitle: Text(
                          '${row.noNota} · ${row.unitLabel}\n'
                          '${dateTimeId.format(row.waktu)}',
                        ),
                        isThreeLine: true,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatRupiah(row.totalCents),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              row.isVoid ? 'VOID' : row.statusBayar,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openDetail(int id) async {
    final detail = await AppDatabase.instance.recordDetail(id);
    if (!mounted) return;
    if (detail == null) {
      showSnack(context, 'Nota tidak ditemukan.', error: true);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RecordDetailSheet(
        detail: detail,
        onVoid: detail.record.isVoid
            ? null
            : () async {
                final reason = await _askVoidReason(context);
                if (reason == null) return;
                try {
                  await AppDatabase.instance.voidRecord(id, reason);
                  await SyncService.instance.enqueueNoteVoid(id);
                  AppState.instance.touch();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Nota ${detail.record.noNota} di-void.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal void: $error', error: true);
                  }
                }
              },
      ),
    );
  }

  Future<String?> _askVoidReason(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void nota'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Alasan',
            hintText: 'Contoh: salah input',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.pop(context, value.length < 3 ? null : value);
            },
            child: const Text('Void'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

class _RecordDetailSheet extends StatelessWidget {
  const _RecordDetailSheet({required this.detail, this.onVoid});

  final RecordDetail detail;
  final Future<void> Function()? onVoid;

  @override
  Widget build(BuildContext context) {
    final record = detail.record;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.noNota,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(record.customerNama),
                      Text(record.unitLabel),
                    ],
                  ),
                ),
                Chip(
                  label: Text(record.isVoid ? 'VOID' : record.statusBayar),
                  backgroundColor: record.isVoid
                      ? Theme.of(context).colorScheme.errorContainer
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(dateTimeId.format(record.waktu)),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Ringkasan',
              child: Column(
                children: [
                  _row(context, 'Jasa', formatRupiah(record.biayaJasaCents)),
                  _row(context, 'Part', formatRupiah(record.totalPartCents)),
                  _row(context, 'Diskon', '-${formatRupiah(record.diskonCents)}'),
                  const Divider(),
                  _row(
                    context,
                    'Total',
                    formatRupiah(record.totalCents),
                    bold: true,
                  ),
                  _row(context, 'Dibayar', formatRupiah(detail.totalDibayarCents)),
                  _row(context, 'Sisa', formatRupiah(detail.sisaCents)),
                  _row(context, 'Metode', record.metodeBayar),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (detail.jobs.isNotEmpty)
              SectionCard(
                title: 'Jasa',
                child: Column(
                  children: detail.jobs
                      .map(
                        (job) => _line(
                          context,
                          '${job.deskripsi} × ${job.jumlah}',
                          formatRupiah(job.subtotalCents),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (detail.parts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SectionCard(
                  title: 'Part',
                  child: Column(
                    children: detail.parts
                        .map(
                          (part) => _line(
                            context,
                            '${part.nama} × ${part.jumlah}',
                            formatRupiah(part.subtotalCents),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            if (record.keluhan.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Keluhan',
                child: Text(record.keluhan),
              ),
            ],
            if (detail.catatan != null && detail.catatan!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Catatan',
                child: Text(detail.catatan!),
              ),
            ],
            if (detail.voidReason != null) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Alasan void',
                child: Text(detail.voidReason!),
              ),
            ],
            const SizedBox(height: 20),
            if (record.isVoid)
              const Center(child: Text('Nota ini sudah di-void.'))
            else
              FilledButton.tonalIcon(
                onPressed: onVoid == null ? null : () => onVoid!(),
                icon: const Icon(Icons.block_outlined),
                label: const Text('Void nota'),
              ),
          ],
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
  }) {
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

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value),
        ],
      ),
    );
  }
}
