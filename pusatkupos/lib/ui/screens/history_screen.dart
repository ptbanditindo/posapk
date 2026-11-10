import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/ids.dart';
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
import '../../sync/archive_service.dart';
import '../../sync/sync_service.dart';
import '../receipt_dialog.dart';
import '../widgets.dart';
import 'archive_search_screen.dart';

const _jenisLabels = {
  'jual_sparepart': 'Jual sparepart',
  'servis_langsung': 'Servis langsung',
  'order_kerja': 'Order kerja',
  'pelunasan_order': 'Pelunasan order',
};

String _statusBayarLabel(String value) => switch (value.toUpperCase()) {
      'LUNAS' => 'Lunas',
      'KREDIT' => 'Belum lunas',
      'ARSIP' => 'Di arsip',
      _ => value,
    };

String _warrantyLabel(String value) => switch (value.toUpperCase()) {
      'AKTIF' => 'aktif',
      'KEDALUWARSA' => 'kedaluwarsa',
      _ => value,
    };

String _metodeLabel(String value) => switch (value.toUpperCase()) {
      'CASH' => 'Tunai',
      'TRANSFER' => 'Transfer',
      _ => value,
    };

String _paymentJenisLabel(String value) => switch (value.toUpperCase()) {
      'DP' => 'Uang muka',
      'PELUNASAN' => 'Pelunasan',
      'REFUND' => 'Uang kembali',
      _ => value,
    };

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _pageSize = 50;

  final _search = TextEditingController();
  final List<ServiceRecordSummary> _rows = [];
  DateTimeRange? _range;
  bool _onlyReceivable = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    AppState.instance.addListener(_reload);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_reload);
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load({bool append = false}) async {
    final token = ++_loadToken;
    if (append) {
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await AppDatabase.instance.listRecords(
        from: _range?.start,
        to: _range?.end,
        query: _search.text,
        limit: _pageSize,
        offset: append ? _rows.length : 0,
        onlyReceivable: _onlyReceivable,
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        if (!append) _rows.clear();
        _rows.addAll(rows);
        _hasMore = rows.length == _pageSize;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$error';
      });
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
    _reload();
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
                        hintText: 'Cari no. nota atau nama pelanggan',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => _load(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Muat ulang daftar',
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ArchiveSearchScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.manage_search),
                    tooltip: 'Cari di server',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Semua nota'),
                    selected: !_onlyReceivable,
                    onSelected: (_) {
                      setState(() => _onlyReceivable = false);
                      _reload();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Belum lunas'),
                    selected: _onlyReceivable,
                    onSelected: (_) {
                      setState(() => _onlyReceivable = true);
                      _reload();
                    },
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.date_range_outlined, size: 18),
                    label: Text(
                      _range == null
                          ? 'Pilih rentang tanggal'
                          : '${dateId.format(_range!.start)} - '
                              '${dateId.format(_range!.end)}',
                    ),
                    selected: _range != null,
                    onSelected: (_) => _pickRange(),
                    onDeleted: _range == null
                        ? null
                        : () {
                            setState(() => _range = null);
                            _reload();
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows.isEmpty) {
      return EmptyState(
        title: 'Riwayat belum bisa dimuat',
        subtitle: 'Data riwayat tidak bisa dibaca: $_error. '
            'Coba muat ulang daftar.',
        icon: Icons.error_outline,
      );
    }
    if (_rows.isEmpty) {
      return const EmptyState(
        title: 'Belum ada riwayat',
        subtitle: 'Nota yang tersimpan akan tampil di sini. Ubah kata kunci '
            'atau pilih rentang tanggal lain.',
        icon: Icons.history,
      );
    }
    final itemCount = _rows.length + (_hasMore || _loadingMore ? 1 : 0);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index >= _rows.length) {
            return Center(
              child: _loadingMore
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => _load(append: true),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Muat 50 nota lagi'),
                    ),
            );
          }
          final row = _rows[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              onTap: () => _openRow(row),
              leading: CircleAvatar(
                backgroundColor: row.isVoid
                    ? Theme.of(context).colorScheme.errorContainer
                    : row.purged
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                child: Icon(
                  row.isVoid
                      ? Icons.block_outlined
                      : row.purged
                          ? Icons.inventory_2_outlined
                          : Icons.receipt_long_outlined,
                ),
              ),
              title: Text(
                row.customerNama.isEmpty ? row.noNota : row.customerNama,
              ),
              subtitle: Text(
                row.purged
                    ? '${row.noNota} · Ada di arsip\n'
                        '${dateTimeId.format(row.waktu)}'
                    : '${row.noNota} · '
                        '${_jenisLabels[row.jenisTransaksi] ?? row.jenisTransaksi}'
                        '${row.unitLabel.isEmpty ? '' : ' · ${row.unitLabel}'}\n'
                        '${dateTimeId.format(row.waktu)}'
                        '${row.bergaransi ? ' · Garansi ${_warrantyLabel(row.warrantyStatus)}' : ''}'
                        '${row.jatuhTempoLewat ? ' · Jatuh tempo' : ''}',
              ),
              isThreeLine: true,
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatRupiah(row.totalCents),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (row.purged)
                    Text(
                      'Arsip',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    )
                  else if (row.isVoid)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Dibatalkan',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context)
                              .colorScheme
                              .onErrorContainer,
                        ),
                      ),
                    )
                  else
                    Text(
                      _statusBayarLabel(row.statusBayar),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (row.syncStatus.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    _SyncStatusBadge(status: row.syncStatus),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRow(ServiceRecordSummary row) async {
    if (row.purged) {
      await _openArchived(row);
      return;
    }
    await _openDetail(row.id);
  }

  Future<void> _openArchived(ServiceRecordSummary row) async {
    if (row.archiveDocId.isEmpty) {
      showSnack(context, 'Nota ini tidak punya salinan arsip di server.',
          error: true);
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final payload = await ArchiveService.instance.open(
        docId: row.archiveDocId,
      );
      if (!mounted) return;
      Navigator.pop(context);
      await showArchivedDocument(
        context,
        payload: payload,
        metadata: {
          'doc_id': row.archiveDocId,
          'doc_type': 'nota',
          'no_nota': row.noNota,
          'tanggal': row.waktu.toIso8601String(),
        },
      );
    } catch (error) {
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Arsip tidak bisa dibuka: $error', error: true);
    }
  }

  Future<void> _openDetail(int id) async {
    final detail = await AppDatabase.instance.recordDetail(id);
    if (!mounted) return;
    if (detail == null) {
      showSnack(context, 'Nota tidak ditemukan. Muat ulang daftar lalu '
          'coba lagi.', error: true);
      return;
    }
    final settings = await StoreSettingsService.instance.ensure();
    if (!mounted) return;
    final role = AppState.instance.operator?.role ?? 'owner';
    final canChangeStatus =
        role == 'owner' || settings.roleAllows(role, 'ubah_status');
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
                    enqueue: (txn, recordId) => SyncService.instance
                        .enqueueNoteVoid(recordId, txn: txn),
                    enqueuePayment: (txn, recordId) => SyncService.instance
                        .enqueueNotePayment(recordId, txn: txn),
                    enqueueEstimate: (txn, syncId) =>
                        SyncService.instance.enqueueEstimate(syncId, txn: txn),
                    enqueueOrder: (txn, syncId) =>
                        SyncService.instance.enqueueWorkOrder(syncId, txn: txn),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(
                      this.context,
                      'Nota ${detail.record.noNota} dibatalkan.',
                    );
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Nota gagal dibatalkan: $error',
                        error: true);
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
                    metodeRefund: request.metodeRefund,
                    actor: AppState.instance.requireOperator,
                    requestId: request.requestId,
                    enqueue: (txn, _) =>
                        SyncService.instance.enqueueNoteReturn(id, txn: txn),
                    enqueueCommission: (txn, commissionId) => SyncService
                        .instance
                        .enqueueCommission(commissionId, txn: txn),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(
                      this.context,
                      'Retur tersimpan. Stok dan kas sudah diperbarui.',
                    );
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Retur gagal disimpan: $error',
                        error: true);
                  }
                }
              },
        onReverseReturn:
            !AppState.instance.isOwner || !AppState.instance.can('retur')
            ? null
            : (retur) async {
                final reason = await _askReverseReason(context, retur.noRetur);
                if (reason == null || !context.mounted) return;
                try {
                  await SaleReturnService.instance.reverseReturn(
                    returnId: retur.id,
                    alasan: reason,
                    actor: AppState.instance.requireOperator,
                    enqueueNote: (txn, recordId) => SyncService.instance
                        .enqueueNoteReturn(recordId, txn: txn),
                    enqueueCommission: (txn, commissionId) => SyncService
                        .instance
                        .enqueueCommission(commissionId, txn: txn),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) _openDetail(id);
                  if (mounted) {
                    showSnack(
                      this.context,
                      'Retur ${retur.noRetur} dibatalkan.',
                    );
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(
                      context,
                      'Pembatalan retur gagal: $error',
                      error: true,
                    );
                  }
                }
              },
        onSettle:
            detail.record.isVoid ||
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
                    requestId: input.requestId,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) => SyncService.instance
                        .enqueueNotePayment(recordId, txn: txn),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Pelunasan tersimpan.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Pelunasan gagal disimpan: $error',
                        error: true);
                  }
                }
              },
        onCorrect: detail.record.isVoid || !AppState.instance.can('koreksi')
            ? null
            : () async {
                final current =
                    (detail.record.totalAsliCents ?? detail.record.totalCents) +
                    detail.record.totalKoreksiCents;
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
                      enqueue: (txn, adjustmentId) => SyncService.instance
                          .enqueueNotaAdjustment(adjustmentId, txn: txn),
                    );
                    AppState.instance.touch();
                    FollowupService.instance.scheduleSync();
                    if (context.mounted) Navigator.pop(context);
                    if (mounted) _load();
                    if (mounted) {
                      showSnack(this.context, 'Koreksi nota tersimpan.');
                    }
                    if (mounted) await _openDetail(id);
                    return;
                  } on PriceRuleViolation catch (error) {
                    if (asked || error.code != 'di_bawah_batas_minimal') {
                      if (mounted) {
                        showSnack(
                          this.context,
                          'Koreksi gagal disimpan: $error',
                          error: true,
                        );
                      }
                      return;
                    }
                    if (!context.mounted) return;
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
        onClaim: !detail.record.warrantyActive || !canChangeStatus
            ? null
            : () async {
                final ok = await confirmAction(
                  context,
                  title: 'Klaim garansi',
                  message:
                      'Klaim garansi untuk nota ${detail.record.noNota}? '
                      'Garansi hanya bisa diklaim satu kali.',
                  confirmLabel: 'Klaim garansi',
                );
                if (!ok) return;
                try {
                  await AppDatabase.instance.claimWarranty(
                    id,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) => SyncService.instance
                        .enqueueNoteWarranty(recordId, txn: txn),
                  );
                  AppState.instance.touch();
                  FollowupService.instance.scheduleSync();
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _load();
                  if (mounted) {
                    showSnack(this.context, 'Klaim garansi tersimpan.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    showSnack(context, 'Klaim garansi gagal disimpan: '
                        '$error', error: true);
                  }
                }
              },
        onUnitTaken:
            detail.record.unitDitinggal &&
                detail.record.diambilAt == null &&
                !detail.record.isVoid &&
                canChangeStatus
            ? () async {
                try {
                  await AppDatabase.instance.markUnitTaken(
                    id,
                    diambil: true,
                    actor: AppState.instance.operator,
                    enqueue: (txn, recordId) => SyncService.instance
                        .enqueueNoteTaken(recordId, txn: txn),
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
                    showSnack(
                      context,
                      'Status unit gagal disimpan: $error',
                      error: true,
                    );
                  }
                }
              }
            : null,
        onEditCommission:
            detail.commissions.isEmpty ||
                detail.record.isVoid ||
                !AppState.instance.isOwner
            ? null
            : () async {
                final values = await showDialog<Map<String, int>>(
                  context: context,
                  builder: (context) =>
                      _CommissionDialog(rows: detail.commissions),
                );
                if (values == null) return;
                try {
                  for (final entry in values.entries) {
                    await EmployeeService.instance.setCommissionOverride(
                      id,
                      entry.key,
                      entry.value,
                      actor: AppState.instance.operator,
                      enqueue: (txn, commissionId) => SyncService.instance
                          .enqueueCommission(commissionId, txn: txn),
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
                    showSnack(
                      context,
                      'Komisi gagal disimpan: $error',
                      error: true,
                    );
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
    final nominal = TextEditingController(text: formatRupiahPlain(sisaCents));
    // Kunci dibuat sekali per percobaan agar pengiriman ulang tidak
    // menggandakan pembayaran.
    final requestId = 'settle-${newSyncId()}';
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
                    labelText: 'Jumlah dibayar',
                    helperText: 'Contoh: 150000 atau 150.000.',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: metode,
                  decoration: const InputDecoration(labelText: 'Cara bayar'),
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
                    setDialogState(
                      () => error = 'Isi jumlah antara 1 dan sisa piutang '
                          '${formatRupiah(sisaCents)}.',
                    );
                    return;
                  }
                  Navigator.pop(
                    context,
                    _SettlementInput(cents, metode, requestId),
                  );
                },
                child: const Text('Simpan pelunasan'),
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
                  helperText: 'Contoh: 250000. Isi total akhir nota setelah '
                      'koreksi.',
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
                  setDialogState(
                    () => error = 'Isi total baru dengan angka, misalnya '
                        '250000.',
                  );
                  return;
                }
                if (cents == currentCents) {
                  setDialogState(
                    () => error = 'Total baru masih sama. Ubah angkanya '
                        'dulu.',
                  );
                  return;
                }
                if (note.length < 3) {
                  setDialogState(
                    () => error = 'Isi alasan minimal 3 huruf.',
                  );
                  return;
                }
                Navigator.pop(context, _CorrectionInput(cents, note));
              },
              child: const Text('Simpan koreksi'),
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
          decoration: const InputDecoration(
            labelText: 'PIN',
            helperText: 'PIN dari pemilik atau penanggung jawab.',
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
              if (value.isEmpty) return;
              Navigator.pop(context, value);
            },
            child: const Text('Setujui koreksi'),
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
          title: const Text('Batalkan nota'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Alasan pembatalan',
              hintText: 'Contoh: salah input pelanggan.',
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
                    () => error = 'Isi alasan minimal 3 huruf.',
                  );
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Batalkan nota'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askReverseReason(BuildContext context, String noRetur) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Batalkan retur $noRetur'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Alasan pembatalan',
              hintText: 'Contoh: salah pilih barang.',
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
                    () => error = 'Isi alasan minimal 3 huruf.',
                  );
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Batalkan retur'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }
}

class _RecordDetailSheet extends StatefulWidget {
  const _RecordDetailSheet({
    required this.detail,
    this.onVoid,
    this.onReturn,
    this.onReverseReturn,
    this.onSettle,
    this.onCorrect,
    this.onClaim,
    this.onUnitTaken,
    this.onEditCommission,
  });

  final RecordDetail detail;
  final Future<void> Function()? onVoid;
  final Future<void> Function()? onReturn;
  final Future<void> Function(SaleReturnRow retur)? onReverseReturn;
  final Future<void> Function()? onSettle;
  final Future<void> Function()? onCorrect;
  final Future<void> Function()? onClaim;
  final Future<void> Function()? onUnitTaken;
  final Future<void> Function()? onEditCommission;

  @override
  State<_RecordDetailSheet> createState() => _RecordDetailSheetState();
}

class _RecordDetailSheetState extends State<_RecordDetailSheet> {
  String? _running;

  Future<void> _run(String action, Future<void> Function() callback) async {
    if (_running != null) return;
    setState(() => _running = action);
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  bool _available(String action, Future<void> Function()? callback) =>
      callback != null && (_running == null || _running == action);

  Widget _actionIcon(String action, IconData icon) {
    if (_running != action) return Icon(icon);
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final record = detail.record;
    final onVoid = widget.onVoid;
    final onReturn = widget.onReturn;
    final onSettle = widget.onSettle;
    final onCorrect = widget.onCorrect;
    final onClaim = widget.onClaim;
    final onUnitTaken = widget.onUnitTaken;
    final onEditCommission = widget.onEditCommission;
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
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(record.customerNama),
                      Text(record.unitLabel),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    record.isVoid ? 'Dibatalkan' : _statusBayarLabel(
                      record.statusBayar,
                    ),
                  ),
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
                  _row(context, 'Jasa', formatRupiah(record.jasaEfektifCents)),
                  _row(context, 'Part', formatRupiah(record.partEfektifCents)),
                  _row(
                    context,
                    'Diskon',
                    '-${formatRupiah(record.diskonEfektifCents)}',
                  ),
                  if (record.totalReturCents > 0)
                    _row(
                      context,
                      'Retur',
                      '-${formatRupiah(record.totalReturCents)}',
                    ),
                  const Divider(),
                  _row(
                    context,
                    'Total',
                    formatRupiah(record.totalCents),
                    bold: true,
                  ),
                  _row(
                    context,
                    'Sudah dibayar',
                    formatRupiah(detail.totalDibayarCents),
                  ),
                  _row(
                    context,
                    'Sisa tagihan',
                    formatRupiah(detail.sisaCents),
                  ),
                  if (record.jatuhTempo != null)
                    _row(
                      context,
                      'Jatuh tempo',
                      '${dateId.format(record.jatuhTempo!)}'
                          '${record.jatuhTempoLewat ? ' (lewat)' : ''}',
                    ),
                  _row(context, 'Cara bayar', _metodeLabel(record.metodeBayar)),
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
                subtitle: 'Nota asli tidak diubah. Setiap koreksi tercatat '
                    'terpisah.',
                child: Column(
                  children: [
                    _row(
                      context,
                      'Total nota asli',
                      formatRupiah(
                        record.totalAsliCents ?? record.totalCents,
                      ),
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
                        (record.totalAsliCents ?? record.totalCents) +
                            record.totalKoreksiCents,
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
                  _row(
                    context,
                    'Status garansi',
                    _warrantyLabel(record.warrantyStatus),
                  ),
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
                  trailing: _available('commission', onEditCommission)
                      ? TextButton(
                          onPressed: () =>
                              _run('commission', onEditCommission!),
                          child: const Text('Ubah nominal'),
                        )
                      : null,
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
                            '${_paymentJenisLabel(payment.jenis)} · '
                            '${_metodeLabel(payment.metode)} · '
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
                  subtitle: 'Total retur mengurangi penjualan setelah retur.',
                  child: Column(
                    children: [
                      for (final retur in detail.returns) ...[
                        _row(
                          context,
                          '${retur.noRetur}${retur.isVoid ? ' · Dibatalkan' : ''}'
                          ' · ${dateId.format(retur.waktu)}',
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
                        if (!retur.isVoid &&
                            widget.onReverseReturn != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _running == null
                                  ? () => _run(
                                      'reversal-${retur.id}',
                                      () => widget.onReverseReturn!(retur),
                                    )
                                  : null,
                              child: const Text('Batalkan retur'),
                            ),
                          ),
                        const Divider(),
                      ],
                    ],
                  ),
                ),
              ),
            if (detail.sisaCents > 0 && !record.isVoid) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _available('settle', onSettle)
                    ? () => _run('settle', onSettle!)
                    : null,
                icon: _actionIcon('settle', Icons.payments_outlined),
                label: Text(
                  'Terima pelunasan (sisa ${formatRupiah(detail.sisaCents)})',
                ),
              ),
            ],
            if (record.keluhan.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(title: 'Keluhan', child: Text(record.keluhan)),
            ],
            if (detail.catatan != null &&
                detail.catatan!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(title: 'Catatan', child: Text(detail.catatan!)),
            ],
            if (detail.voidReason != null) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Alasan pembatalan',
                child: Text(detail.voidReason!),
              ),
            ],
            if (record.warrantyActive) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _available('claim', onClaim)
                    ? () => _run('claim', onClaim!)
                    : null,
                icon: _actionIcon('claim', Icons.verified_outlined),
                label: const Text('Klaim garansi'),
              ),
            ],
            if (onUnitTaken != null) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _available('taken', onUnitTaken)
                    ? () => _run('taken', onUnitTaken)
                    : null,
                icon: _actionIcon('taken', Icons.directions_car_outlined),
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
              const Center(child: Text('Nota ini sudah dibatalkan.'))
            else ...[
              FilledButton.tonalIcon(
                onPressed: _available('return', onReturn)
                    ? () => _run('return', onReturn!)
                    : null,
                icon: _actionIcon('return', Icons.assignment_return_outlined),
                label: const Text('Retur penjualan'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _available('correct', onCorrect)
                    ? () => _run('correct', onCorrect!)
                    : null,
                icon: _actionIcon('correct', Icons.edit_note_outlined),
                label: const Text('Koreksi total nota'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _available('void', onVoid)
                    ? () => _run('void', onVoid!)
                    : null,
                icon: _actionIcon('void', Icons.block_outlined),
                label: const Text('Batalkan nota'),
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
        setState(
          () => _error =
              'Isi nominal komisi dengan angka, misalnya 25000.',
        );
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        FilledButton(onPressed: _save, child: const Text('Simpan komisi')),
      ],
    );
  }
}

class _SettlementInput {
  const _SettlementInput(this.nominalCents, this.metode, this.requestId);

  final int nominalCents;
  final String metode;
  final String requestId;
}

class _CorrectionInput {
  const _CorrectionInput(this.nilaiBaruCents, this.alasan);

  final int nilaiBaruCents;
  final String alasan;
}

class _ReturnRequest {
  const _ReturnRequest(
    this.items,
    this.alasan,
    this.requestId,
    this.metodeRefund,
  );

  final List<ReturnLineInput> items;
  final String alasan;
  final String requestId;
  final String metodeRefund;
}

class _SyncStatusBadge extends StatelessWidget {
  const _SyncStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (status) {
      'pending' => ('Menunggu', scheme.secondaryContainer, scheme.onSecondaryContainer),
      'sent' => ('Tersinkron', scheme.primaryContainer, scheme.onPrimaryContainer),
      'failed' => ('Gagal', scheme.errorContainer, scheme.onErrorContainer),
      'dead_letter' => (
        'Gagal permanen',
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      _ => (status, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
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
  // Satu kunci untuk seluruh isi dialog: menekan Simpan dua kali tidak
  // menghasilkan dua retur.
  final _requestId = newSyncId();
  late String _metodeRefund;
  String? _error;

  @override
  void initState() {
    super.initState();
    _metodeRefund =
        widget.detail.record.metodeBayar == 'TRANSFER' ? 'TRANSFER' : 'CASH';
    final returned = <String, int>{};
    for (final retur in widget.detail.returns) {
      if (retur.isVoid) continue;
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
          unitNetCents: totalMilli == 0
              ? 0
              : (job.lineTotalCents * 1000 / totalMilli).round(),
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
        setState(
          () => _error = 'Jumlah retur ${line.label} tidak valid. Isi '
              'angka lebih dari 0.',
        );
        return;
      }
      if (qtyMilli > line.remainingMilli) {
        setState(
          () => _error =
              'Jumlah retur ${line.label} melebihi sisa yang bisa diretur '
              '(${line.remainingLabel}).',
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
      setState(
        () => _error = 'Centang minimal satu barang yang akan diretur.',
      );
      return;
    }
    final alasan = _alasan.text.trim();
    if (alasan.length < 3) {
      setState(
        () => _error =
            'Isi alasan retur minimal 3 huruf, misalnya "barang rusak".',
      );
      return;
    }
    Navigator.pop(
      context,
      _ReturnRequest(items, alasan, _requestId, _metodeRefund),
    );
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
                const Text('Semua barang di nota ini sudah diretur.')
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
                                'Sisa yang bisa diretur ${line.remainingLabel} '
                                '· ${formatRupiah(line.unitNetCents)} per unit',
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
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                              labelText: 'Jumlah',
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
                  hintText: 'Contoh: barang rusak saat dipasang.',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _metodeRefund,
                decoration: const InputDecoration(
                  labelText: 'Uang dikembalikan lewat',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                  DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
                ],
                onChanged: (value) => setState(
                  () => _metodeRefund = value ?? 'CASH',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
