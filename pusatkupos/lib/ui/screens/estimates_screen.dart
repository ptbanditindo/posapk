import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../data/order_service.dart';
import '../../data/pajak.dart';
import '../../data/store_settings.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../receipt_dialog.dart';
import '../widgets.dart';

class EstimatesScreen extends StatefulWidget {
  const EstimatesScreen({super.key});

  @override
  State<EstimatesScreen> createState() => _EstimatesScreenState();
}

enum _EstimateAction { convert, revise, cancel }

class _EstimatesScreenState extends State<EstimatesScreen> {
  Future<_EstimatesData>? _future;
  bool _aktifSaja = true;

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
      _future = _loadData();
    });
  }

  void _setFilter(bool aktifSaja) {
    if (_aktifSaja == aktifSaja) return;
    _aktifSaja = aktifSaja;
    _load();
  }

  Future<_EstimatesData> _loadData() async {
    final settings = await StoreSettingsService.instance.ensure();
    final rows = await OrderService.instance.listEstimateRows(
      unconvertedOnly: _aktifSaja,
    );
    final variance = await OrderService.instance.varianceReport();
    return _EstimatesData(settings: settings, rows: rows, variance: variance);
  }

  Future<void> _openDetail(
    _EstimatesData data,
    Map<String, Object?> row,
  ) async {
    final role = AppState.instance.operator?.role ?? '';
    final isOwner = AppState.instance.isOwner;
    final canConvert = data.settings.roleAllows(role, 'buat_nota');
    final canManage = isOwner ||
        (AppState.instance.can('buat_estimasi') &&
            data.settings.roleCanSelect(role, transactionEstimasiSaja));
    final action = await showDialog<_EstimateAction>(
      context: context,
      builder: (_) => _EstimateDetailDialog(
        row: row,
        canConvert: canConvert,
        canManage: canManage,
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _EstimateAction.convert:
        await _convert(data, row);
      case _EstimateAction.revise:
        await _revise(data, row);
      case _EstimateAction.cancel:
        await _cancel(row);
    }
  }

  Future<void> _cancel(Map<String, Object?> row) async {
    final syncId = row['sync_id'] as String? ?? '';
    if (syncId.isEmpty) {
      showSnack(context, 'Estimasi tidak valid.', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Batalkan estimasi?'),
        content: Text(
          'Estimasi ${row['nomor_estimasi'] ?? ''} akan ditandai batal '
          'dan tidak dapat dikonversi menjadi nota.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Tidak'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Batalkan estimasi'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await OrderService.instance.cancelEstimate(
        syncId,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, estimateSyncId) =>
            SyncService.instance.enqueueEstimate(estimateSyncId, txn: txn),
      );
      if (!mounted) return;
      _load();
      showSnack(context, 'Estimasi dibatalkan.');
    } catch (error) {
      if (mounted) showSnack(context, '$error', error: true);
    }
  }

  Future<void> _revise(_EstimatesData data, Map<String, Object?> row) async {
    final syncId = row['sync_id'] as String? ?? '';
    if (syncId.isEmpty) {
      showSnack(context, 'Estimasi tidak valid.', error: true);
      return;
    }
    final items = await AppDatabase.instance.db.query(
      'estimate_items',
      where: 'estimate_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [syncId],
      orderBy: 'id',
    );
    if (!mounted) return;
    if (items.isEmpty) {
      showSnack(context, 'Estimasi tidak memiliki rincian.', error: true);
      return;
    }
    final lines = <_RevisionLine>[];
    for (final item in items) {
      final jenis = item['jenis'] as String? ?? 'jasa';
      final reference =
          (item['harga_jual_terdaftar'] as num?)?.toInt() ?? 0;
      var harga = (item['harga_input'] as num?)?.toInt() ?? 0;
      if (harga == 0) harga = reference;
      var modal = (item['harga_modal'] as num?)?.toInt() ?? 0;
      int? stockItemId;
      int? jasaId;
      var hargaTerdaftar = reference;
      final stockSync = (item['stock_sync_id'] as String?)?.trim() ?? '';
      if (jenis == 'part' && stockSync.isNotEmpty) {
        final stockRows = await AppDatabase.instance.db.query(
          'stock_items',
          where: 'sync_id = ? AND deleted_at IS NULL',
          whereArgs: [stockSync],
          limit: 1,
        );
        if (stockRows.isNotEmpty) {
          final stock = StockItem.fromRow(stockRows.first);
          stockItemId = stock.id;
          harga = stock.hargaJualCents;
          hargaTerdaftar = stock.hargaJualCents;
          modal = stock.hargaModalCents;
        }
      } else if (jenis == 'jasa') {
        final jasaSync = (item['jasa_sync_id'] as String?)?.trim() ?? '';
        if (jasaSync.isNotEmpty) {
          final catalog = await AppDatabase.instance.db.query(
            'harga_jasa',
            where: 'sync_id = ? AND deleted_at IS NULL',
            whereArgs: [jasaSync],
            limit: 1,
          );
          if (catalog.isNotEmpty) {
            jasaId = catalog.first['id'] as int?;
            hargaTerdaftar =
                (catalog.first['harga_jual'] as num?)?.toInt() ?? reference;
            harga = hargaTerdaftar;
            modal = (catalog.first['harga_modal'] as num?)?.toInt() ?? 0;
          }
        }
      }
      final jumlah = (item['jumlah'] as num?)?.toInt() ?? 1;
      final qtyMilli =
          (item['jumlah_milli'] as num?)?.toInt() ?? jumlah * 1000;
      lines.add(
        _RevisionLine(
          jenis: jenis,
          deskripsi: item['deskripsi'] as String? ?? '-',
          jumlah: jumlah,
          qtyMilli: qtyMilli,
          hargaCents: harga,
          modalCents: modal,
          stockItemId: stockItemId,
          jasaId: jasaId,
          hargaTerdaftarCents: hargaTerdaftar,
          intervalBulan:
              (item['interval_servis_bulan'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final oldTotal = items.fold<int>(
      0,
      (sum, item) => sum + ((item['subtotal'] as num?)?.toInt() ?? 0),
    );
    final baseTotal = lines.fold<int>(0, (sum, line) => sum + line.subtotal);
    final defaultDiskon = baseTotal > oldTotal ? baseTotal - oldTotal : 0;
    if (!mounted) return;
    final draft = await showDialog<_RevisionDraft>(
      context: context,
      builder: (_) => _RevisionDialog(lines: lines, defaultDiskon: defaultDiskon),
    );
    if (draft == null || !mounted) return;
    final customerId = await _localId('customers', row['customer_sync_id']);
    final unitId = await _localId('vehicle_or_units', row['unit_sync_id']);
    if (!mounted) return;
    String? ownerPin;
    String? approverSecret;
    var asked = false;
    while (true) {
      try {
        final created = await OrderService.instance.createEstimate(
          customerId: customerId,
          unitId: unitId,
          workOrderSyncId: row['work_order_sync_id'] as String?,
          revisiDariSyncId: syncId,
          alasanRevisi: draft.alasan,
          jenisTransaksi:
              row['jenis_transaksi'] as String? ?? transactionServisLangsung,
          items: draft.items,
          diskonCents: draft.diskonCents,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
          actor: AppState.instance.requireOperator,
          enqueue: (txn, estimateSyncId) =>
              SyncService.instance.enqueueEstimate(estimateSyncId, txn: txn),
        );
        if (!mounted) return;
        _load();
        showSnack(
          context,
          created == null
              ? 'Penyimpanan estimasi dimatikan pemilik.'
              : 'Revisi ${created.nomorEstimasi} v${created.versi} disimpan.',
        );
        return;
      } on StateError catch (error) {
        final needsApproval = error.message.contains('persetujuan');
        if (asked || !needsApproval) {
          if (mounted) showSnack(context, '$error', error: true);
          return;
        }
        final secret = await _askApproval(data.settings);
        if (secret == null) return;
        asked = true;
        if (data.settings.approverMode == approverEmployee) {
          approverSecret = secret;
        } else {
          ownerPin = secret;
        }
      } catch (error) {
        if (mounted) showSnack(context, '$error', error: true);
        return;
      }
    }
  }

  Future<int?> _localId(String table, Object? syncId) async {
    final id = '${syncId ?? ''}'.trim();
    if (id.isEmpty) return null;
    final rows = await AppDatabase.instance.db.query(
      table,
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  Future<void> _convert(_EstimatesData data, Map<String, Object?> row) async {
    final total = (row['total'] as num?)?.toInt() ?? 0;
    final draft = await showDialog<_PaymentDraft>(
      context: context,
      builder: (_) => _PaymentDialog(totalCents: total),
    );
    if (draft == null || !mounted) return;
    final settings = data.settings;
    final syncId = row['sync_id'] as String? ?? '';
    if (syncId.isEmpty) {
      showSnack(context, 'Estimasi tidak valid.', error: true);
      return;
    }
    String? ownerPin;
    String? approverSecret;
    var asked = false;
    while (true) {
      try {
        final recordId = await OrderService.instance.convertEstimateToNote(
          estimateSyncId: syncId,
          metodeBayar: draft.metode,
          bayarCents: draft.bayarCents,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
          actor: AppState.instance.requireOperator,
          enqueueNote: (txn, id) =>
              SyncService.instance.enqueueNote(id, txn: txn),
          enqueueEstimate: (txn, estimateSyncId) =>
              SyncService.instance.enqueueEstimate(estimateSyncId, txn: txn),
          enqueueOrder: (txn, orderSyncId) =>
              SyncService.instance.enqueueWorkOrder(orderSyncId, txn: txn),
          enqueueCommission: (txn, commissionId) =>
              SyncService.instance.enqueueCommission(commissionId, txn: txn),
        );
        if (!mounted) return;
        _load();
        showSnack(
          context,
          'Estimasi ${row['nomor_estimasi'] ?? ''} menjadi nota.',
        );
        await showReceiptPreview(context, recordId, title: 'Nota konversi');
        return;
      } on StateError catch (error) {
        if (asked || !error.message.contains('persetujuan')) {
          if (mounted) showSnack(context, '$error', error: true);
          return;
        }
        final secret = await _askApproval(settings);
        if (secret == null) return;
        asked = true;
        if (settings.approverMode == approverEmployee) {
          approverSecret = secret;
        } else {
          ownerPin = secret;
        }
      } catch (error) {
        if (mounted) showSnack(context, '$error', error: true);
        return;
      }
    }
  }

  Future<String?> _askApproval(StoreSettings settings) => showDialog<String>(
    context: context,
    builder: (_) =>
        _ApprovalDialog(delegated: settings.approverMode == approverEmployee),
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EstimatesData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data;
        if (data == null) {
          return const EmptyState(
            title: 'Estimasi belum dapat dimuat',
            subtitle: 'Coba buka kembali halaman ini.',
            icon: Icons.request_quote_outlined,
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Estimasi',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _aktifSaja
                              ? 'Estimasi aktif yang belum menjadi nota.'
                              : 'Semua estimasi, termasuk yang sudah '
                                    'dikonversi.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Aktif')),
                      ButtonSegment(value: false, label: Text('Semua')),
                    ],
                    selected: {_aktifSaja},
                    onSelectionChanged: (value) => _setFilter(value.first),
                  ),
                ],
              ),
            ),
            if (data.variance.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _VarianceCard(rows: data.variance),
              ),
            Expanded(
              child: data.rows.isEmpty
                  ? EmptyState(
                      title: _aktifSaja
                          ? 'Tidak ada estimasi aktif'
                          : 'Belum ada estimasi',
                      subtitle: _aktifSaja
                          ? 'Estimasi yang sudah menjadi nota tampil di '
                                'filter Semua.'
                          : 'Buat estimasi dari kasir untuk mulai.',
                      icon: Icons.request_quote_outlined,
                    )
                  : RefreshIndicator(
                      onRefresh: () async => _load(),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: data.rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final row = data.rows[index];
                          return _EstimateCard(
                            row: row,
                            onTap: () => _openDetail(data, row),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EstimatesData {
  const _EstimatesData({
    required this.settings,
    required this.rows,
    required this.variance,
  });

  final StoreSettings settings;
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> variance;
}

String _estimateState(Map<String, Object?> row) {
  final nota = (row['converted_nota_sync_id'] as String?)?.trim() ?? '';
  if (nota.isNotEmpty) return 'dikonversi';
  final status = row['status'] as String? ?? 'aktif';
  if (status != 'aktif') return status;
  final expiry = DateTime.tryParse('${row['masa_berlaku'] ?? ''}');
  if (expiry == null) return 'aktif';
  final today = DateTime.now();
  final expired = DateTime(
    today.year,
    today.month,
    today.day,
  ).isAfter(DateTime(expiry.year, expiry.month, expiry.day));
  return expired ? 'kedaluwarsa' : 'aktif';
}

String _stateLabel(String state) => switch (state) {
  'aktif' => 'Aktif',
  'dikonversi' => 'Sudah jadi nota',
  'kedaluwarsa' => 'Kedaluwarsa',
  'direvisi' => 'Direvisi',
  'batal' => 'Dibatalkan',
  _ => state,
};

Color _stateColor(BuildContext context, String state) {
  final scheme = Theme.of(context).colorScheme;
  return switch (state) {
    'aktif' => scheme.primary,
    'dikonversi' => Colors.green.shade700,
    'kedaluwarsa' => scheme.tertiary,
    'direvisi' => scheme.secondary,
    'batal' => scheme.error,
    _ => scheme.outline,
  };
}

String _unitLabel(Map<String, Object?> row) {
  final parts = [row['nopol'], row['merek'], row['tipe']]
      .map((value) => '${value ?? ''}'.trim())
      .where((value) => value.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '${row['unit_type'] ?? 'Unit'}';
  return parts.join(' · ');
}

class _VarianceCard extends StatelessWidget {
  const _VarianceCard({required this.rows});

  final List<Map<String, Object?>> rows;

  @override
  Widget build(BuildContext context) {
    var total = 0;
    for (final row in rows) {
      total += (row['selisih'] as num?)?.toInt() ?? 0;
    }
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      child: Row(
        children: [
          Icon(Icons.trending_up, color: scheme.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${rows.length} konversi estimasi 30 hari terakhir '
              'dengan selisih total ${formatRupiah(total)}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _EstimateCard extends StatelessWidget {
  const _EstimateCard({required this.row, required this.onTap});

  final Map<String, Object?> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = _estimateState(row);
    final color = _stateColor(context, state);
    final nomor = row['nomor_estimasi'] as String? ?? 'Tanpa nomor';
    final versi = (row['versi'] as num?)?.toInt() ?? 1;
    final total = (row['total'] as num?)?.toInt() ?? 0;
    final customer = row['customer_nama'] as String? ?? 'Tanpa pelanggan';
    final unit = _unitLabel(row);
    final expiry = _dateLabel(row['masa_berlaku']);
    final nota = row['nota_nomor'] as String?;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      versi > 1 ? '$nomor v$versi' : nomor,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _stateLabel(state),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$customer · $unit',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    formatRupiah(total),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (expiry != null)
                    Text(
                      's.d. $expiry',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
              if (nota != null && nota.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Nota $nota',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _dateLabel(Object? raw) {
    final value = DateTime.tryParse('$raw');
    return value == null ? null : dateId.format(value.toLocal());
  }
}

class _EstimateDetailDialog extends StatefulWidget {
  const _EstimateDetailDialog({
    required this.row,
    required this.canConvert,
    required this.canManage,
  });

  final Map<String, Object?> row;
  final bool canConvert;
  final bool canManage;

  @override
  State<_EstimateDetailDialog> createState() => _EstimateDetailDialogState();
}

class _EstimateDetailDialogState extends State<_EstimateDetailDialog> {
  late Future<List<Map<String, Object?>>> _items;

  @override
  void initState() {
    super.initState();
    _items = _loadItems();
  }

  Future<List<Map<String, Object?>>> _loadItems() {
    final syncId = widget.row['sync_id'] as String? ?? '';
    return AppDatabase.instance.db.query(
      'estimate_items',
      where: 'estimate_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [syncId],
      orderBy: 'id',
    );
  }

  PajakSnapshot? _pajakEstimasi(Map<String, Object?> row) {
    final raw = row['mode_saat_dibuat_json'];
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final pajak = decoded['pajak_estimasi'];
      if (pajak is! Map) return null;
      return PajakSnapshot.fromJson(Map<String, Object?>.from(pajak));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final state = _estimateState(row);
    final total = (row['total'] as num?)?.toInt() ?? 0;
    final notaTotal = (row['nota_total'] as num?)?.toInt();
    final pajak = _pajakEstimasi(row);
    final color = _stateColor(context, state);
    final convertible = widget.canConvert && state == 'aktif';
    return AlertDialog(
      title: Text('${row['nomor_estimasi'] ?? 'Estimasi'}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _stateLabel(state),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatRupiah(total),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _line('Pelanggan', row['customer_nama'] as String? ?? '-'),
              _line('Unit', _unitLabel(row)),
              _line(
                'Berlaku sampai',
                _dateLabel(row['masa_berlaku']) ?? 'Tanpa batas',
              ),
              if (pajak != null && pajak.active) ...[
                _line('DPP', formatRupiah(pajak.dppCents)),
                _line(
                  'PPN ${formatPersenBp(pajak.persenBp)}',
                  formatRupiah(pajak.pajakCents),
                ),
                if (pajak.diserapCents > 0)
                  _line(
                    'PPN diserap bengkel',
                    formatRupiah(pajak.diserapCents),
                  ),
              ],
              _line('Dibuat oleh', row['dibuat_oleh'] as String? ?? '-'),
              if (row['disetujui_oleh'] != null)
                _line('Disetujui', '${row['disetujui_oleh']}'),
              if (notaTotal != null) ...[
                _line('Total nota', formatRupiah(notaTotal)),
                _line('Selisih', formatRupiah(notaTotal - total)),
              ],
              const Divider(height: 24),
              Text(
                'Rincian',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              FutureBuilder<List<Map<String, Object?>>>(
                future: _items,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final rows = snapshot.data ?? const [];
                  if (rows.isEmpty) {
                    return Text(
                      'Rincian estimasi tidak tersedia.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  return Column(
                    children: [
                      for (final item in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '${item['deskripsi'] ?? '-'} '
                                  '· ${formatQuantity((item['jumlah_milli'] as num?)?.toInt() ?? ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000, 3)}x '
                                  '${formatRupiah((item['harga_final'] as num?)?.toInt() ?? 0)}',
                                ),
                              ),
                              Text(
                                formatRupiah(
                                  (item['subtotal'] as num?)?.toInt() ?? 0,
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
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Tutup'),
        ),
        if (state == 'aktif' && widget.canManage)
          TextButton(
            onPressed: () => Navigator.pop(context, _EstimateAction.cancel),
            child: const Text('Batalkan'),
          ),
        if (state == 'aktif' && widget.canManage)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, _EstimateAction.revise),
            icon: const Icon(Icons.edit_note_outlined),
            label: const Text('Revisi'),
          ),
        if (convertible)
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _EstimateAction.convert),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Jadikan nota'),
          ),
      ],
    );
  }

  String? _dateLabel(Object? raw) {
    final value = DateTime.tryParse('$raw');
    return value == null ? null : dateId.format(value.toLocal());
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _RevisionLine {
  const _RevisionLine({
    required this.jenis,
    required this.deskripsi,
    required this.jumlah,
    required this.hargaCents,
    required this.modalCents,
    this.qtyMilli,
    this.stockItemId,
    this.jasaId,
    this.hargaTerdaftarCents = 0,
    this.intervalBulan = 0,
  });

  final String jenis;
  final String deskripsi;
  final int jumlah;
  final int hargaCents;
  final int modalCents;
  final int? qtyMilli;
  final int? stockItemId;
  final int? jasaId;
  final int hargaTerdaftarCents;
  final int intervalBulan;

  int get milli => qtyMilli ?? jumlah * 1000;
  String get qtyLabel => formatQuantity(milli, 3);
  int get subtotal => (hargaCents * milli / 1000).round();
}

class _RevisionDraft {
  const _RevisionDraft({
    required this.items,
    required this.diskonCents,
    this.alasan,
  });

  final List<EstimateItemInput> items;
  final int diskonCents;
  final String? alasan;
}

class _RevisionDialog extends StatefulWidget {
  const _RevisionDialog({required this.lines, required this.defaultDiskon});

  final List<_RevisionLine> lines;
  final int defaultDiskon;

  @override
  State<_RevisionDialog> createState() => _RevisionDialogState();
}

class _RevisionDialogState extends State<_RevisionDialog> {
  late final List<TextEditingController> _qty;
  late final TextEditingController _diskon;
  final _alasan = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _qty = widget.lines
        .map((line) => TextEditingController(text: line.qtyLabel))
        .toList();
    _diskon = TextEditingController(
      text: formatRupiahPlain(widget.defaultDiskon),
    );
  }

  @override
  void dispose() {
    for (final controller in _qty) {
      controller.dispose();
    }
    _diskon.dispose();
    _alasan.dispose();
    super.dispose();
  }

  int get _baseTotal {
    var total = 0;
    for (var index = 0; index < widget.lines.length; index++) {
      final qtyMilli =
          parseQuantityToMilli(_qty[index].text.trim(), desimal: 3) ?? 0;
      total += (widget.lines[index].hargaCents * qtyMilli / 1000).round();
    }
    return total;
  }

  void _submit() {
    final items = <EstimateItemInput>[];
    for (var index = 0; index < widget.lines.length; index++) {
      final line = widget.lines[index];
      final qtyMilli = parseQuantityToMilli(
        _qty[index].text.trim(),
        desimal: 3,
      );
      if (qtyMilli == null || qtyMilli <= 0) {
        setState(() => _error = 'Jumlah ${line.deskripsi} harus lebih dari 0.');
        return;
      }
      items.add(
        EstimateItemInput(
          jenis: line.jenis,
          deskripsi: line.deskripsi,
          jumlah: qtyMilli ~/ 1000,
          qtyMilli: qtyMilli,
          hargaCents: line.hargaCents,
          modalCents: line.modalCents,
          stockItemId: line.stockItemId,
          jasaId: line.jasaId,
          intervalBulan: line.intervalBulan,
          hargaTerdaftarCents: line.hargaTerdaftarCents,
        ),
      );
    }
    final diskon = tryParseRupiahToCents(_diskon.text) ?? 0;
    if (diskon < 0 || diskon > _baseTotal) {
      setState(() => _error = 'Diskon tidak valid.');
      return;
    }
    final alasan = _alasan.text.trim();
    Navigator.pop(
      context,
      _RevisionDraft(
        items: items,
        diskonCents: diskon,
        alasan: alasan.isEmpty ? null : alasan,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _baseTotal - (tryParseRupiahToCents(_diskon.text) ?? 0);
    return AlertDialog(
      title: const Text('Revisi estimasi'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < widget.lines.length; index++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.lines[index].deskripsi),
                            Text(
                              formatRupiah(widget.lines[index].hargaCents),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: TextField(
                          controller: _qty[index],
                          keyboardType:
                              const TextInputType.numberWithOptions(
                                  decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Qty',
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() => _error = null),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 20),
              TextField(
                controller: _diskon,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Diskon total',
                  prefixText: 'Rp ',
                  errorText: _error,
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 8),
              Text(
                'Total revisi ${formatRupiah(total < 0 ? 0 : total)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _alasan,
                decoration: const InputDecoration(
                  labelText: 'Alasan revisi (opsional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Simpan revisi')),
      ],
    );
  }
}

class _PaymentDraft {
  const _PaymentDraft({required this.metode, required this.bayarCents});

  final String metode;
  final int bayarCents;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.totalCents});

  final int totalCents;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _metode = 'CASH';
  late final TextEditingController _bayar = TextEditingController(
    text: formatRupiahPlain(widget.totalCents),
  );
  String? _error;

  @override
  void dispose() {
    _bayar.dispose();
    super.dispose();
  }

  int? get _bayarCents => tryParseRupiahToCents(_bayar.text);

  void _submit() {
    final cents = _bayarCents;
    if (cents == null) {
      setState(() => _error = 'Nominal tidak valid.');
      return;
    }
    if (_metode == 'TRANSFER' && cents > widget.totalCents) {
      setState(() => _error = 'Transfer tidak boleh melebihi total.');
      return;
    }
    Navigator.pop(context, _PaymentDraft(metode: _metode, bayarCents: cents));
  }

  @override
  Widget build(BuildContext context) {
    final cents = _bayarCents;
    final sisa = cents == null ? null : widget.totalCents - cents;
    return AlertDialog(
      title: const Text('Jadikan nota'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Total estimasi ${formatRupiah(widget.totalCents)}'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _metode,
            decoration: const InputDecoration(labelText: 'Metode bayar'),
            items: const [
              DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
              DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
            ],
            onChanged: (value) => setState(() {
              _metode = value ?? 'CASH';
              _error = null;
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bayar,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Dibayar',
              prefixText: 'Rp ',
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 8),
          Text(
            sisa == null
                ? 'Masukkan nominal yang valid.'
                : sisa > 0
                ? 'Sisa ${formatRupiah(sisa)}'
                : sisa < 0
                ? 'Kembalian ${formatRupiah(-sisa)}'
                : 'Lunas',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Buat nota')),
      ],
    );
  }
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.delegated});

  final bool delegated;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _secret = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _secret.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Masukkan PIN.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Persetujuan diperlukan'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.delegated
                ? 'Konversi ini memerlukan persetujuan penanggung jawab.'
                : 'Konversi ini memerlukan persetujuan pemilik.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secret,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: widget.delegated
                  ? 'PIN penanggung jawab'
                  : 'PIN pemilik',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Setujui')),
      ],
    );
  }
}
