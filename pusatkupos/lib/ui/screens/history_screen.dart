import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/employee_service.dart';
import '../../data/followup_service.dart';
import '../../data/models.dart';
import '../../data/nota_adjustment_service.dart';
import '../../data/price_rules.dart';
import '../../data/sale_return_service.dart';
import '../../data/store_settings.dart';
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
                          '${row.bergaransi ? ' · Garansi ${row.warrantyStatus}' : ''}'
                          '${row.jatuhTempoLewat ? ' · JATUH TEMPO' : ''}',
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
                    enqueuePayment: (txn, recordId) =>
                        SyncService.instance.enqueueNotePayment(
                      recordId,
                      txn: txn,
                    ),
                    enqueueEstimate: (txn, syncId) =>
                        SyncService.instance.enqueueEstimate(
                      syncId,
                      txn: txn,
                    ),
                    enqueueOrder: (txn, syncId) =>
                        SyncService.instance.enqueueWorkOrder(
                      syncId,
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
        onReturn: detail.record.isVoid || !AppState.instance.can('retur')
            ? null
            : () async {
                final request = await showDialog<_ReturnRequest>(
                  context: context,
                  builder: (context) => _ReturnDialog(detail: detail),
                );
                if (request == null || request.items.isEmpty) return;
                try {
                  await SaleReturnService.instance.createReturn(
                    recordId: id,
                    items: request.items,
                    alasan: request.alasan,
                    actor: AppState.instance.operator,
                    enqueue: (txn, _) => SyncService.instance.enqueueNote(
                      id,
                      txn: txn,
                    ),
                    enqueueCommission: (txn, commissionId) =>
                        SyncService.instance.enqueueCommission(
                          commissionId,
                          txn: txn,
                        ),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Retur dicatat.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Gagal retur: $error', error: true);
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
                    requestId:
                        'settle-${detail.record.id}-'
                        '${DateTime.now().microsecondsSinceEpoch}',
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
        onCorrect: detail.record.isVoid || !AppState.instance.can('koreksi')
            ? null
            : () async {
                final current = detail.corrections.isEmpty
                    ? detail.record.totalCents
                    : detail.corrections.last.nilaiBaruCents;
                final input = await _askCorrection(context, current);
                if (input == null) return;
                final settings = await StoreSettingsService.instance.ensure();
                String? ownerPin;
                String? approverSecret;
                var asked = false;
                while (true) {
                  try {
                    await NotaAdjustmentService.instance.createForRecord(
                      recordId: id,
                      nilaiBaru: input.nilaiBaruCents,
                      alasan: input.alasan,
                      actor: AppState.instance.operator,
                      ownerPin: ownerPin,
                      approverSecret: approverSecret,
                      enqueue: (txn, adjustmentId) =>
                          SyncService.instance.enqueueNotaAdjustment(
                        adjustmentId,
                        txn: txn,
                      ),
                    );
                    AppState.instance.touch();
                    FollowupService.instance.scheduleSync();
                    if (context.mounted) Navigator.pop(context);
                    if (mounted) _load();
                    if (mounted) {
                      showSnack(this.context, 'Koreksi nota dicatat.');
                    }
                    if (mounted) await _openDetail(id);
                    return;
                  } on PriceRuleViolation catch (error) {
                    if (asked || error.code != 'di_bawah_batas_minimal') {
                      if (mounted) {
                        showSnack(
                          this.context,
                          'Gagal koreksi: $error',
                          error: true,
                        );
                      }
                      return;
                    }
                    final secret = await _askApprovalSecret(context, settings);
                    if (secret == null) return;
                    asked = true;
                    if (settings.approverMode == approverEmployee) {
                      approverSecret = secret;
                    } else {
                      ownerPin = secret;
                    }
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

  Future<_CorrectionInput?> _askCorrection(
    BuildContext context,
    int currentCents,
  ) async {
    final nominal = TextEditingController(
      text: formatRupiahPlain(currentCents),
    );
    final reason = TextEditingController();
    String? error;
    final result = await showDialog<_CorrectionInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Koreksi total nota'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Total saat ini ${formatRupiah(currentCents)}'),
              const SizedBox(height: 10),
              TextField(
                controller: nominal,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Total baru',
                  errorText: error,
                ),
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'Alasan koreksi',
                  hintText: 'Contoh: salah input harga jasa',
                ),
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
                final note = reason.text.trim();
                if (cents == null || cents < 0) {
                  setDialogState(() => error = 'Total baru tidak valid.');
                  return;
                }
                if (cents == currentCents) {
                  setDialogState(
                    () => error = 'Total baru sama dengan total saat ini.',
                  );
                  return;
                }
                if (note.length < 3) {
                  setDialogState(
                    () => error = 'Alasan minimal 3 karakter.',
                  );
                  return;
                }
                Navigator.pop(context, _CorrectionInput(cents, note));
              },
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    nominal.dispose();
    reason.dispose();
    return result;
  }

  Future<String?> _askApprovalSecret(
    BuildContext context,
    StoreSettings settings,
  ) async {
    final delegated = settings.approverMode == approverEmployee;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(delegated ? 'PIN penanggung jawab' : 'PIN pemilik'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(context, value);
            },
            child: const Text('Setujui'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askVoidReason(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Void nota'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Alasan',
              hintText: 'Contoh: salah input',
              errorText: error,
            ),
            onChanged: (_) {
              if (error != null) setDialogState(() => error = null);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.length < 3) {
                  setDialogState(
                    () => error = 'Alasan minimal 3 karakter.',
                  );
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Void'),
            ),
          ],
        ),
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
    this.onReturn,
    this.onSettle,
    this.onCorrect,
    this.onClaim,
    this.onUnitTaken,
    this.onEditCommission,
  });

  final RecordDetail detail;
  final Future<void> Function()? onVoid;
  final Future<void> Function()? onReturn;
  final Future<void> Function()? onSettle;
  final Future<void> Function()? onCorrect;
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
                  if (record.jatuhTempo != null)
                    _row(
                      context,
                      'Jatuh tempo',
                      '${dateId.format(record.jatuhTempo!)}'
                      '${record.jatuhTempoLewat ? ' (lewat)' : ''}',
                    ),
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
                          '${job.deskripsi} × ${job.jumlah}'
                          '${job.diskonAlokasiCents > 0 ? ' · diskon ${formatRupiah(job.diskonAlokasiCents)}' : ''}',
                          formatRupiah(job.lineTotalCents),
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
                            '${part.nama} × ${part.qtyLabel}'
                            '${part.diskonAlokasiCents > 0 ? ' · diskon ${formatRupiah(part.diskonAlokasiCents)}' : ''}',
                            formatRupiah(part.lineTotalCents),
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
            if (detail.returns.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SectionCard(
                  title: 'Retur',
                  subtitle: 'Total retur dikurangkan dari penjualan neto.',
                  child: Column(
                    children: [
                      for (final retur in detail.returns) ...[
                        _row(
                          context,
                          '${retur.noRetur} · ${dateId.format(retur.waktu)}',
                          '-${formatRupiah(retur.totalCents)}',
                          bold: true,
                        ),
                        for (final item in retur.items)
                          _line(
                            context,
                            '  ${item.deskripsi} × ${item.qtyLabel}',
                            formatRupiah(item.subtotalCents),
                          ),
                        if (retur.alasan.trim().isNotEmpty)
                          _line(context, '  Alasan', retur.alasan),
                        const Divider(),
                      ],
                    ],
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
            else ...[
              FilledButton.tonalIcon(
                onPressed: onReturn == null ? null : () => onReturn!(),
                icon: const Icon(Icons.assignment_return_outlined),
                label: const Text('Retur penjualan'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: onCorrect == null ? null : () => onCorrect!(),
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Koreksi total nota'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: onVoid == null ? null : () => onVoid!(),
                icon: const Icon(Icons.block_outlined),
                label: const Text('Void nota'),
              ),
            ],
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

class _CorrectionInput {
  const _CorrectionInput(this.nilaiBaruCents, this.alasan);

  final int nilaiBaruCents;
  final String alasan;
}

class _ReturnRequest {
  const _ReturnRequest(this.items, this.alasan);

  final List<ReturnLineInput> items;
  final String alasan;
}

class _ReturnLineState {
  _ReturnLineState({
    required this.lineType,
    required this.lineSyncId,
    required this.label,
    required this.remainingMilli,
    required this.unitNetCents,
  });

  final String lineType;
  final String lineSyncId;
  final String label;
  final int remainingMilli;
  final int unitNetCents;
  bool selected = false;
  final qty = TextEditingController(text: '1');

  String get remainingLabel => formatQuantity(remainingMilli, 3);

  void dispose() => qty.dispose();
}

class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog({required this.detail});

  final RecordDetail detail;

  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  late final List<_ReturnLineState> _lines;
  final _alasan = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final returned = <String, int>{};
    for (final retur in widget.detail.returns) {
      for (final item in retur.items) {
        final key = '${item.lineType}:${item.lineSyncId}';
        returned[key] = (returned[key] ?? 0) + item.milli;
      }
    }
    _lines = [];
    for (final job in widget.detail.jobs) {
      final syncId = job.syncId ?? '';
      if (syncId.isEmpty) continue;
      final totalMilli = job.jumlah * 1000;
      final sisa = totalMilli - (returned['jasa:$syncId'] ?? 0);
      if (sisa <= 0) continue;
      _lines.add(
        _ReturnLineState(
          lineType: 'jasa',
          lineSyncId: syncId,
          label: job.deskripsi,
          remainingMilli: sisa,
          unitNetCents:
              totalMilli == 0 ? 0 : (job.lineTotalCents * 1000 / totalMilli).round(),
        ),
      );
    }
    for (final part in widget.detail.parts) {
      final syncId = part.syncId ?? '';
      if (syncId.isEmpty) continue;
      final sisa = part.qtyMilli - (returned['part:$syncId'] ?? 0);
      if (sisa <= 0) continue;
      _lines.add(
        _ReturnLineState(
          lineType: 'part',
          lineSyncId: syncId,
          label: part.nama,
          remainingMilli: sisa,
          unitNetCents: part.qtyMilli == 0
              ? 0
              : (part.lineTotalCents * 1000 / part.qtyMilli).round(),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    _alasan.dispose();
    super.dispose();
  }

  void _save() {
    final items = <ReturnLineInput>[];
    for (final line in _lines) {
      if (!line.selected) continue;
      final qtyMilli = parseQuantityToMilli(line.qty.text.trim(), desimal: 3);
      if (qtyMilli == null || qtyMilli <= 0) {
        setState(() => _error = 'Jumlah retur ${line.label} tidak valid.');
        return;
      }
      if (qtyMilli > line.remainingMilli) {
        setState(
          () => _error = 'Jumlah retur ${line.label} melebihi sisa '
              '${line.remainingLabel}.',
        );
        return;
      }
      items.add(
        ReturnLineInput(
          lineType: line.lineType,
          lineSyncId: line.lineSyncId,
          jumlah: qtyMilli ~/ 1000,
          qtyMilli: qtyMilli,
        ),
      );
    }
    if (items.isEmpty) {
      setState(() => _error = 'Pilih minimal satu baris yang diretur.');
      return;
    }
    final alasan = _alasan.text.trim();
    if (alasan.length < 3) {
      setState(() => _error = 'Alasan retur minimal 3 karakter.');
      return;
    }
    Navigator.pop(context, _ReturnRequest(items, alasan));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Retur penjualan'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_lines.isEmpty)
                const Text('Semua baris nota sudah diretur.')
              else
                for (final line in _lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Checkbox(
                          value: line.selected,
                          onChanged: (value) =>
                              setState(() => line.selected = value ?? false),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${line.lineType == 'jasa' ? 'Jasa' : 'Part'}'
                                ' · ${line.label}',
                              ),
                              Text(
                                'Sisa ${line.remainingLabel} · '
                                '${formatRupiah(line.unitNetCents)}/unit',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 72,
                          child: TextField(
                            controller: line.qty,
                            enabled: line.selected,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                              labelText: 'Qty',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 8),
              TextField(
                controller: _alasan,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Alasan retur',
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _lines.isEmpty ? null : _save,
          child: const Text('Simpan retur'),
        ),
      ],
    );
  }
}

