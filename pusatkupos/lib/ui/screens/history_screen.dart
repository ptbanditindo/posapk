import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/employee_service.dart';
import '../../data/followup_service.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../receipt_dialog.dart';
import '../widgets.dart';

const _jenisLabels = {
  'jual_sparepart': 'Jual sparepart',
  'servis_langsung': 'Servis langsung',
  'order_kerja': 'Order kerja',
  'pelunasan_order': 'Pelunasan order',
};

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _search = TextEditingController();
  Future<List<ServiceRecordSummary>>? _future;
  bool _onlyReceivable = false;

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
        onlyReceivable: _onlyReceivable,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
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
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Semua'),
                    selected: !_onlyReceivable,
                    onSelected: (_) {
                      setState(() => _onlyReceivable = false);
                      _load();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Piutang'),
                    selected: _onlyReceivable,
                    onSelected: (_) {
                      setState(() => _onlyReceivable = true);
                      _load();
                    },
                  ),
                ],
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
                          '${row.noNota} · '
                          '${_jenisLabels[row.jenisTransaksi] ?? row.jenisTransaksi}'
                          '${row.unitLabel.isEmpty ? '' : ' · ${row.unitLabel}'}\n'
                          '${dateTimeId.format(row.waktu)}'
                          '${row.bergaransi ? ' · Garansi ${row.warrantyStatus}' : ''}',
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
        onVoid: detail.record.isVoid || !AppState.instance.can('void')
            ? null
            : () async {
                final reason = await _askVoidReason(context);
                if (reason == null) return;
                try {
                  await AppDatabase.instance.voidRecord(
                    id,
                    reason,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) =>
                        SyncService.instance.enqueueNoteVoid(
                      recordId,
                      txn: txn,
                    ),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
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
        onSettle: detail.record.isVoid ||
                detail.sisaCents <= 0 ||
                !AppState.instance.canWriteMoney
            ? null
            : () async {
                final input = await _askSettlement(context, detail.sisaCents);
                if (input == null) return;
                try {
                  await AppDatabase.instance.settleReceivable(
                    recordId: id,
                    nominalCents: input.nominalCents,
                    metode: input.metode,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) =>
                        SyncService.instance.enqueueNotePayment(
                      recordId,
                      txn: txn,
                    ),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Pelunasan dicatat.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal pelunasan: $error', error: true);
                  }
                }
              },
        onClaim: !detail.record.warrantyActive
            ? null
            : () async {
                final ok = await confirmAction(
                  context,
                  title: 'Klaim garansi',
                  message:
                      'Klaim garansi nota ${detail.record.noNota}? Klaim hanya '
                      'dapat dilakukan satu kali.',
                  confirmLabel: 'Klaim',
                );
                if (!ok) return;
                try {
                  await AppDatabase.instance.claimWarranty(
                    id,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) =>
                        SyncService.instance.enqueueNoteWarranty(
                      recordId,
                      txn: txn,
                    ),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Klaim garansi dicatat.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal klaim: $error', error: true);
                  }
                }
              },
        onUnitTaken: detail.record.unitDitinggal &&                detail.record.diambilAt == null &&
                !detail.record.isVoid
            ? () async {
                try {
                  await AppDatabase.instance.markUnitTaken(
                    id,
                    diambil: true,
                    enqueue: (txn, recordId) =>
                        SyncService.instance.enqueueNoteTaken(
                      recordId,
                      txn: txn,
                    ),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Unit ditandai sudah diambil.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal menandai unit: $error',
                        error: true);
                  }
                }
              }
            : null,
        onEditCommission: detail.commissions.isEmpty ||
                detail.record.isVoid ||
                !AppState.instance.isOwner
            ? null
            : () async {
                final values = await showDialog<Map<String, int>>(
                  context: context,
                  builder: (context) => _CommissionDialog(
                    rows: detail.commissions,
                  ),
                );
                if (values == null) return;
                try {
                  for (final entry in values.entries) {
                    await EmployeeService.instance.setCommissionOverride(
                      id,
                      entry.key,
                      entry.value,
                      actor: AppState.instance.operator,
                      enqueue: (txn, commissionId) =>
                          SyncService.instance.enqueueCommission(
                        commissionId,
                        txn: txn,
                      ),
                    );
                  }
                  AppState.instance.touch();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _openDetail(id);
                  if (mounted) {
                    showSnack(this.context, 'Komisi diperbarui.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal mengubah komisi: $error',
                        error: true);
                  }
                }
              },
      ),
    );
  }

  Future<_SettlementInput?> _askSettlement(
    BuildContext context,
    int sisaCents,
  ) async {
    final nominal = TextEditingController(
      text: formatRupiahPlain(sisaCents),
    );
    var metode = 'CASH';
    final result = await showDialog<_SettlementInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          String? error;
          return AlertDialog(
            title: const Text('Terima pelunasan'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sisa piutang ${formatRupiah(sisaCents)}'),
                const SizedBox(height: 10),
                TextField(
                  controller: nominal,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Nominal',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: metode,
                  decoration: const InputDecoration(labelText: 'Metode'),
                  items: const [
                    DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                    DropdownMenuItem(
                      value: 'TRANSFER',
                      child: Text('Transfer'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => metode = value ?? 'CASH'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () {
                  final cents = tryParseRupiahToCents(nominal.text);
                  if (cents == null || cents <= 0 || cents > sisaCents) {
                    setDialogState(() => error = 'Nominal tidak valid.');
                    return;
                  }
                  Navigator.pop(context, _SettlementInput(cents, metode));
                },
                child: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );
    nominal.dispose();
    return result;
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
  const _RecordDetailSheet({
    required this.detail,
    this.onVoid,
    this.onSettle,
    this.onClaim,
    this.onUnitTaken,
    this.onEditCommission,
  });

  final RecordDetail detail;
  final Future<void> Function()? onVoid;
  final Future<void> Function()? onSettle;
  final Future<void> Function()? onClaim;
  final Future<void> Function()? onUnitTaken;
  final Future<void> Function()? onEditCommission;

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
            Text(
              '${_jenisLabels[record.jenisTransaksi] ?? record.jenisTransaksi}'
              ' · ${dateTimeId.format(record.waktu)}',
            ),
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
                  if ((detail.createdBy ?? '').isNotEmpty)
                    _row(context, 'Dibuat oleh', detail.createdBy!),
                  if ((detail.mechanic ?? '').isNotEmpty)
                    _row(context, 'Mekanik', detail.mechanic!),
                ],
              ),
            ),
            if (detail.corrections.isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Koreksi',
                subtitle: 'Nota asli tidak diubah; koreksi tercatat terpisah.',
                child: Column(
                  children: [
                    _row(
                      context,
                      'Total nota asli',
                      formatRupiah(record.totalCents),
                    ),
                    const Divider(),
                    ...detail.corrections.map(
                      (correction) => _row(
                        context,
                        '${dateId.format(correction.waktu)} · '
                        '${correction.alasan}',
                        '${correction.nilaiSelisihCents >= 0 ? '+' : ''}'
                        '${formatRupiah(correction.nilaiSelisihCents)}',
                      ),
                    ),
                    const Divider(),
                    _row(
                      context,
                      'Total setelah koreksi',
                      formatRupiah(
                        detail.corrections.last.nilaiBaruCents,
                      ),
                      bold: true,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            SectionCard(
              title: 'Garansi',
              child: Column(
                children: [
                  _row(context, 'Status', record.warrantyStatus),
                  if (record.garansiSampai != null)
                    _row(
                      context,
                      'Berlaku sampai',
                      dateId.format(record.garansiSampai!),
                    ),
                  if (record.tanggalKlaim != null)
                    _row(
                      context,
                      'Tanggal klaim',
                      dateId.format(record.tanggalKlaim!),
                    ),
                  if ((record.catatanGaransi ?? '').trim().isNotEmpty)
                    _row(context, 'Syarat', record.catatanGaransi!.trim()),
                  if (record.unitDitinggal)
                    _row(
                      context,
                      'Unit',
                      record.diambilAt == null
                          ? 'Masih di bengkel'
                          : 'Sudah diambil ${dateId.format(record.diambilAt!)}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
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
            if (detail.commissions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SectionCard(
                  title: 'Komisi mekanik',
                  trailing: onEditCommission == null
                      ? null
                      : TextButton(
                          onPressed: () => onEditCommission!(),
                          child: const Text('Atur'),
                        ),
                  child: Column(
                    children: detail.commissions
                        .map(
                          (commission) => _line(
                            context,
                            commission.nama,
                            formatRupiah(commission.finalCents),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            if (detail.payments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SectionCard(
                  title: 'Pembayaran',
                  child: Column(
                    children: detail.payments
                        .map(
                          (payment) => _line(
                            context,
                            '${payment.jenis} · ${payment.metode} · '
                            '${dateTimeId.format(payment.waktu)}',
                            formatRupiah(payment.nominalCents),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            if (detail.sisaCents > 0 && !record.isVoid) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onSettle == null ? null : () => onSettle!(),
                icon: const Icon(Icons.payments_outlined),
                label: Text(
                  'Terima pelunasan (sisa ${formatRupiah(detail.sisaCents)})',
                ),
              ),
            ],
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
            if (record.warrantyActive) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onClaim == null ? null : () => onClaim!(),
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Klaim garansi'),
              ),
            ],
            if (onUnitTaken != null) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => onUnitTaken!(),
                icon: const Icon(Icons.directions_car_outlined),
                label: const Text('Tandai unit sudah diambil'),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => showReceiptPreview(
                      context,
                      record.id,
                      title: 'Struk ${record.noNota}',
                    ),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Lihat struk'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => printReceiptFor(context, record.id),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Cetak'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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

class _CommissionDialog extends StatefulWidget {
  const _CommissionDialog({required this.rows});

  final List<CommissionRow> rows;

  @override
  State<_CommissionDialog> createState() => _CommissionDialogState();
}

class _CommissionDialogState extends State<_CommissionDialog> {
  late final Map<String, TextEditingController> _controllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final row in widget.rows)
        row.employeeSyncId: TextEditingController(
          text: formatRupiahPlain(row.finalCents),
        ),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final values = <String, int>{};
    for (final entry in _controllers.entries) {
      final cents = tryParseRupiahToCents(entry.value.text);
      if (cents == null || cents < 0) {
        setState(() => _error = 'Nominal komisi tidak valid.');
        return;
      }
      values[entry.key] = cents;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Atur komisi'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in widget.rows) ...[
              TextField(
                controller: _controllers[row.employeeSyncId],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: row.nama),
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _SettlementInput {
  const _SettlementInput(this.nominalCents, this.metode);

  final int nominalCents;
  final String metode;
}
