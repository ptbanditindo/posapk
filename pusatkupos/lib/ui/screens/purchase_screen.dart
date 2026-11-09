import 'package:flutter/material.dart';

import '../../auth/permissions.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/feature_flags.dart';
import '../../data/models.dart';
import '../../data/purchase_service.dart';
import '../../data/supplier_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

/// Tab "Pembelian & Utang" di hub Supplier & Reseller (BD-27).
class PurchaseDebtTab extends StatefulWidget {
  const PurchaseDebtTab({super.key});

  @override
  State<PurchaseDebtTab> createState() => _PurchaseDebtTabState();
}

class _PurchaseDebtTabState extends State<PurchaseDebtTab> {
  List<Map<String, Object?>> _purchases = const [];
  List<Map<String, Object?>> _debts = const [];
  List<Map<String, Object?>> _aging = const [];
  Map<String, int> _totals = const {};
  bool _loading = true;

  bool get _canCreate =>
      AppState.instance.isOwner ||
      AppState.instance.can(permissionCreatePurchase);
  bool get _canPay =>
      AppState.instance.isOwner || AppState.instance.can(permissionPayDebt);
  bool get _enabled => FeatureFlagsService.instance.purchaseDebtEnabled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_enabled) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final purchases = await PurchaseService.instance.listPurchases();
    final debts = await PurchaseService.instance.listDebts();
    final aging = await PurchaseService.instance.agingBySupplier();
    final totals = await PurchaseService.instance.purchaseTotals();
    if (!mounted) return;
    setState(() {
      _purchases = purchases;
      _debts = debts;
      _aging = aging;
      _totals = totals;
      _loading = false;
    });
  }

  Future<void> _openForm() async {
    final suppliers = await SupplierService.instance.listSuppliers();
    if (!mounted) return;
    if (suppliers.isEmpty) {
      showSnack(
        context,
        'Tambahkan supplier pada tab Supplier terlebih dahulu.',
        error: true,
      );
      return;
    }
    final stocks = await AppDatabase.instance.listStock();
    if (!mounted) return;
    if (stocks.isEmpty) {
      showSnack(context, 'Belum ada barang pada layar Stok.', error: true);
      return;
    }
    final input = await showDialog<_PurchaseFormResult>(
      context: context,
      builder: (_) => _PurchaseFormDialog(suppliers: suppliers, stocks: stocks),
    );
    if (input == null || !mounted) return;
    try {
      await PurchaseService.instance.createPurchase(
        input: PurchaseInput(
          supplierId: input.supplierId,
          lines: input.lines,
          tanggal: input.tanggal,
          terminHari: input.terminHari,
          jenisBayar: input.jenisBayar,
          diskon: input.diskon,
          ongkir: input.ongkir,
          ppn: input.ppn,
          bayarAwal: input.bayarAwal,
          metode: input.metode,
          catatan: input.catatan,
        ),
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePurchase(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Pembelian disimpan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _openDetail(Map<String, Object?> row) async {
    final detail = await PurchaseService.instance.purchaseDetail(row['id'] as int);
    if (!mounted) return;
    if (detail == null) {
      showSnack(context, 'Pembelian tidak ditemukan.', error: true);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${detail['no_pembelian']}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: _PurchaseDetailBody(
              detail: detail,
              canPay: _canPay,
              canCreate: _canCreate,
              canReverse: AppState.instance.isOwner && _canCreate,
              onPay: () {
                Navigator.pop(context);
                _payRow(detail);
              },
              onReturn: () {
                Navigator.pop(context);
                _returnRow(detail);
              },
              onReverseReturn: (retur) {
                Navigator.pop(context);
                _reverseReturn(retur);
              },
              onVoid: () {
                Navigator.pop(context);
                _voidRow(detail);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  Future<void> _payRow(Map<String, Object?> purchase) async {
    if (!_canPay) {
      showSnack(context, 'Peran ini tidak boleh membayar utang.', error: true);
      return;
    }
    final sisa = (purchase['sisa_utang'] as num?)?.toInt() ?? 0;
    if (sisa <= 0) return;
    final nominal = TextEditingController(
      text: formatRupiahPlain(sisa).replaceAll('.', ''),
    );
    final catatan = TextEditingController();
    var metode = 'CASH';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Bayar ${purchase['no_pembelian']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sisa utang: ${formatRupiah(sisa)}'),
              const SizedBox(height: 10),
              TextField(
                controller: nominal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Nominal'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: metode,
                decoration: const InputDecoration(labelText: 'Metode'),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                  DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
                ],
                onChanged: (value) =>
                    setLocal(() => metode = value ?? 'CASH'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: catatan,
                decoration: const InputDecoration(labelText: 'Catatan'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Bayar'),
            ),
          ],
        ),
      ),
    );
    final amount = tryParseRupiahToCents(nominal.text);
    final note = catatan.text;
    nominal.dispose();
    catatan.dispose();
    if (ok != true || amount == null || amount <= 0) return;
    try {
      await PurchaseService.instance.addPayment(
        input: PurchasePaymentInput(
          purchaseId: purchase['id'] as int,
          nominal: amount,
          metode: metode,
          catatan: note,
        ),
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePurchasePayment(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Pembayaran disimpan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membayar: $error', error: true);
    }
  }

  Future<void> _returnRow(Map<String, Object?> purchase) async {
    if (!_canCreate) {
      showSnack(context, 'Peran ini tidak boleh membuat retur.', error: true);
      return;
    }
    final detail =
        await PurchaseService.instance.purchaseDetail(purchase['id'] as int);
    if (!mounted || detail == null) return;
    final items = (detail['items'] as List<Map<String, Object?>>);
    final payments = (detail['payments'] as List<Map<String, Object?>>);
    var metodeRefund = 'CASH';
    if (payments.isNotEmpty &&
        '${payments.last['metode']}'.toUpperCase() == 'TRANSFER') {
      metodeRefund = 'TRANSFER';
    }
    final controllers = <int, TextEditingController>{};
    for (final item in items) {
      controllers[item['id'] as int] = TextEditingController();
    }
    final alasan = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Retur ${purchase['no_pembelian']}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item['nama_snapshot']} · sisa '
                              '${formatQuantity((item['jumlah_milli'] as num).toInt() - (item['qty_retur_milli'] as num).toInt(), 0)}',
                            ),
                          ),
                          SizedBox(
                            width: 90,
                            child: TextField(
                              controller: controllers[item['id'] as int],
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Qty',
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: alasan,
                    decoration:
                        const InputDecoration(labelText: 'Alasan retur'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: metodeRefund,
                    decoration:
                        const InputDecoration(labelText: 'Metode refund'),
                    items: const [
                      DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                      DropdownMenuItem(
                        value: 'TRANSFER',
                        child: Text('Transfer'),
                      ),
                    ],
                    onChanged: (value) =>
                        setLocal(() => metodeRefund = value ?? 'CASH'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Retur'),
            ),
          ],
        ),
      ),
    );
    final lines = <PurchaseReturnLineInput>[];
    for (final item in items) {
      final qty = parseQuantityToMilli(
        controllers[item['id'] as int]?.text ?? '',
      );
      if (qty != null && qty > 0) {
        lines.add(
          PurchaseReturnLineInput(
            purchaseItemId: item['id'] as int,
            qtyMilli: qty,
          ),
        );
      }
    }
    for (final controller in controllers.values) {
      controller.dispose();
    }
    final reason = alasan.text;
    alasan.dispose();
    if (ok != true || lines.isEmpty) return;
    try {
      await PurchaseService.instance.createReturn(
        purchaseId: purchase['id'] as int,
        lines: lines,
        alasan: reason,
        metodeRefund: metodeRefund,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePurchaseReturn(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Retur pembelian disimpan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal retur: $error', error: true);
    }
  }

  Future<void> _reverseReturn(Map<String, Object?> retur) async {
    if (!AppState.instance.isOwner) {
      showSnack(context, 'Reversal retur hanya untuk pemilik.', error: true);
      return;
    }
    final reason = TextEditingController();
    String? error;
    final ok = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Batalkan retur ${retur['no_retur']}'),
          content: TextField(
            controller: reason,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Alasan reversal',
              errorText: error,
            ),
            onChanged: (_) {
              if (error != null) setLocal(() => error = null);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final value = reason.text.trim();
                if (value.length < 3) {
                  setLocal(() => error = 'Alasan minimal 3 karakter.');
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
    final text = reason.text;
    reason.dispose();
    if (ok == null) return;
    try {
      await PurchaseService.instance.reverseReturn(
        returnId: retur['id'] as int,
        alasan: text,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePurchaseReturn(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Retur pembelian dibatalkan.');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal reversal: $error', error: true);
      }
    }
  }

  Future<void> _voidRow(Map<String, Object?> purchase) async {
    if (!_canCreate) {
      showSnack(context, 'Peran ini tidak boleh membatalkan pembelian.',
          error: true);
      return;
    }
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Batalkan ${purchase['no_pembelian']}'),
        content: TextField(
          controller: reason,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Alasan pembatalan'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Batalkan nota'),
          ),
        ],
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (ok != true || text.trim().isEmpty) return;
    try {
      await PurchaseService.instance.voidPurchase(
        purchaseId: purchase['id'] as int,
        reason: text,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePurchase(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Pembelian dibatalkan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membatalkan: $error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.inventory_outlined,
            title: 'Pembelian & Utang dimatikan',
            subtitle: 'Aktifkan melalui Pengaturan › Fitur Toko.',
          ),
        ],
      );
    }
    if (!_canCreate && !_canPay && !AppState.instance.can(permissionViewPurchase)) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.lock_outline,
            title: 'Akses pembelian terbatas',
            subtitle: 'Hubungi pemilik untuk izin lihat_pembelian.',
          ),
        ],
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_purchases.length} nota pembelian',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_canCreate)
                FilledButton.icon(
                  onPressed: _openForm,
                  icon: const Icon(Icons.add),
                  label: const Text('Pembelian'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Ringkasan',
            child: Column(
              children: [
                _line('Total pembelian', formatRupiah(_totals['total_pembelian'] ?? 0)),
                _line('Utang pembelian', formatRupiah(_totals['total_utang'] ?? 0)),
                _line('Utang awal', formatRupiah(_totals['total_utang_awal'] ?? 0)),
                _line('Total utang', formatRupiah(_totals['total_utang_semua'] ?? 0)),
                _line('Sudah dibayar', formatRupiah(_totals['total_dibayar'] ?? 0)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Utang supplier',
            subtitle: _debts.isEmpty
                ? 'Tidak ada utang berjalan.'
                : '${_debts.length} nota memiliki sisa utang',
            child: _debts.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    children: _debts
                        .map(
                          (row) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${row['no_pembelian']}'),
                            subtitle: Text(
                              '${row['supplier_nama_snapshot']} · '
                              '${row['jatuh_tempo'] == null ? 'tanpa jatuh tempo' : 'jatuh tempo ${row['jatuh_tempo']}'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  formatRupiah(
                                    (row['sisa_utang'] as num).toInt(),
                                  ),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (_canPay)
                                  IconButton(
                                    tooltip: 'Bayar utang',
                                    icon: const Icon(Icons.payments_outlined),
                                    onPressed: () => _payRow(row),
                                  ),
                              ],
                            ),
                            onTap: () => _openDetail(row),
                          ),
                        )
                        .toList(),
                  ),
          ),
          if (_aging.isNotEmpty) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Aging utang per supplier',
              subtitle: 'Berdasarkan umur nota pembelian',
              child: Column(
                children: _aging
                    .map(
                      (row) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('${row['supplier_nama']}'),
                        subtitle: Text(
                          '0-30: ${formatRupiah(row['b0_30'] as int)} · '
                          '31-60: ${formatRupiah(row['b31_60'] as int)} · '
                          '61-90: ${formatRupiah(row['b61_90'] as int)} · '
                          '>90: ${formatRupiah(row['b90'] as int)}',
                        ),
                        trailing: Text(
                          formatRupiah(row['total'] as int),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SectionCard(
            title: 'Nota pembelian',
            subtitle: _purchases.isEmpty
                ? 'Belum ada pembelian.'
                : '${_purchases.length} nota terakhir',
            child: _purchases.isEmpty
                ? const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'Belum ada pembelian',
                    subtitle:
                        'Catat pembelian agar stok masuk dan utang supplier '
                        'tercatat.',
                  )
                : Column(
                    children: _purchases
                        .map(
                          (row) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${row['no_pembelian']}'
                              '${row['status'] == 'VOID' ? ' · VOID' : ''}',
                            ),
                            subtitle: Text(
                              '${row['supplier_nama_snapshot']} · '
                              '${row['tanggal']} · ${row['jenis_bayar']}',
                            ),
                            trailing: Text(
                              formatRupiah((row['total'] as num).toInt()),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onTap: () => _openDetail(row),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
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

class _PurchaseDetailBody extends StatelessWidget {
  const _PurchaseDetailBody({
    required this.detail,
    required this.canPay,
    required this.canCreate,
    required this.canReverse,
    required this.onPay,
    required this.onReturn,
    required this.onReverseReturn,
    required this.onVoid,
  });

  final Map<String, Object?> detail;
  final bool canPay;
  final bool canCreate;
  final bool canReverse;
  final VoidCallback onPay;
  final VoidCallback onReturn;
  final void Function(Map<String, Object?> retur) onReverseReturn;
  final VoidCallback onVoid;

  @override
  Widget build(BuildContext context) {
    final items = detail['items'] as List<Map<String, Object?>>;
    final payments = detail['payments'] as List<Map<String, Object?>>;
    final returns = detail['returns'] as List<Map<String, Object?>>;
    final status = '${detail['status']}';
    final sisa = (detail['sisa_utang'] as num?)?.toInt() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${detail['supplier_nama_snapshot']}'),
        const SizedBox(height: 4),
        Text(
          '${detail['tanggal']} · ${detail['jenis_bayar']}'
          '${status == 'VOID' ? ' · VOID' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if ('${detail['void_reason'] ?? ''}'.isNotEmpty)
          Text(
            'Alasan void: ${detail['void_reason']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const Divider(height: 24),
        for (final item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('${item['nama_snapshot']}'),
            subtitle: Text(
              '${formatQuantity((item['jumlah_milli'] as num).toInt(), 0, satuan: '${item['satuan'] ?? ''}')} × '
              '${formatRupiah((item['harga_satuan'] as num).toInt())}'
              '${(item['qty_retur_milli'] as num).toInt() > 0 ? ' · retur ${formatQuantity((item['qty_retur_milli'] as num).toInt(), 0)}' : ''}',
            ),
            trailing: Text(
              formatRupiah((item['subtotal'] as num).toInt()),
            ),
          ),
        const Divider(height: 24),
        _line(context, 'Subtotal', formatRupiah((detail['subtotal'] as num).toInt())),
        if ((detail['diskon'] as num).toInt() > 0)
          _line(
            context,
            'Diskon',
            '-${formatRupiah((detail['diskon'] as num).toInt())}',
          ),
        if ((detail['ongkir'] as num).toInt() > 0)
          _line(context, 'Ongkir', formatRupiah((detail['ongkir'] as num).toInt())),
        if ((detail['ppn'] as num).toInt() > 0)
          _line(context, 'PPN', formatRupiah((detail['ppn'] as num).toInt())),
        _line(
          context,
          'Total',
          formatRupiah((detail['total'] as num).toInt()),
          bold: true,
        ),
        _line(
          context,
          'Dibayar',
          formatRupiah((detail['total_dibayar'] as num).toInt()),
        ),
        _line(context, 'Sisa utang', formatRupiah(sisa), bold: true),
        if (payments.isNotEmpty) ...[
          const Divider(height: 24),
          const Text('Pembayaran'),
          for (final payment in payments)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(formatRupiah((payment['nominal'] as num).toInt())),
              subtitle: Text(
                '${payment['waktu']} · ${payment['metode']}'
                '${payment['jenis'] == 'DP' ? ' · DP' : ''}',
              ),
            ),
        ],
        if (returns.isNotEmpty) ...[
          const Divider(height: 24),
          const Text('Retur'),
          for (final entry in returns)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${entry['no_retur']}'),
              subtitle: Text(
                '${entry['alasan']} · ${formatRupiah((entry['total'] as num).toInt())}'
                '${entry['status'] == 'VOID' ? ' · VOID' : ''}'
                '${'${entry['metode_refund'] ?? 'CASH'}' == 'TRANSFER' ? ' · transfer' : ''}',
              ),
              trailing: entry['status'] == 'AKTIF' && canReverse
                  ? TextButton(
                      onPressed: () => onReverseReturn(entry),
                      child: const Text('Batalkan'),
                    )
                  : null,
            ),
        ],
        const SizedBox(height: 12),
        if (status == 'AKTIF')
          Wrap(
            spacing: 8,
            children: [
              if (canPay && sisa > 0)
                OutlinedButton.icon(
                  onPressed: onPay,
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Bayar'),
                ),
              if (canCreate)
                OutlinedButton.icon(
                  onPressed: onReturn,
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: const Text('Retur'),
                ),
              if (canCreate &&
                  (detail['total_dibayar'] as num).toInt() == 0 &&
                  returns.every((entry) => '${entry['status']}' == 'VOID'))
                OutlinedButton.icon(
                  onPressed: onVoid,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Batalkan'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _line(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
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

class _PurchaseFormResult {
  const _PurchaseFormResult({
    required this.supplierId,
    required this.lines,
    required this.tanggal,
    required this.terminHari,
    required this.jenisBayar,
    required this.diskon,
    required this.ongkir,
    required this.ppn,
    required this.bayarAwal,
    required this.metode,
    required this.catatan,
  });

  final int supplierId;
  final List<PurchaseLineInput> lines;
  final DateTime tanggal;
  final int terminHari;
  final String jenisBayar;
  final int diskon;
  final int ongkir;
  final int ppn;
  final int bayarAwal;
  final String metode;
  final String? catatan;
}

class _PurchaseFormDialog extends StatefulWidget {
  const _PurchaseFormDialog({required this.suppliers, required this.stocks});

  final List<Map<String, Object?>> suppliers;
  final List<StockItem> stocks;

  @override
  State<_PurchaseFormDialog> createState() => _PurchaseFormDialogState();
}

class _PurchaseFormDialogState extends State<_PurchaseFormDialog> {
  late int _supplierId = widget.suppliers.first['id'] as int;
  DateTime _tanggal = DateTime.now();
  int _terminHari = 0;
  String _jenisBayar = 'KREDIT';
  String _metode = 'CASH';
  final _diskon = TextEditingController();
  final _ongkir = TextEditingController();
  final _ppn = TextEditingController();
  final _bayarAwal = TextEditingController();
  final _catatan = TextEditingController();
  final _qty = TextEditingController();
  final _harga = TextEditingController();
  final List<_PurchaseLineDraft> _lines = [];
  int? _stockId;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _diskon,
      _ongkir,
      _ppn,
      _bayarAwal,
      _catatan,
      _qty,
      _harga,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  StockItem? get _selectedStock {
    for (final stock in widget.stocks) {
      if (stock.id == _stockId) return stock;
    }
    return null;
  }

  void _addLine() {
    final stock = _selectedStock;
    if (stock == null) {
      setState(() => _error = 'Pilih barang terlebih dahulu.');
      return;
    }
    final qty = parseQuantityToMilli(_qty.text, desimal: stock.desimal);
    final harga = tryParseRupiahToCents(_harga.text);
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Qty harus lebih dari nol.');
      return;
    }
    if (harga == null || harga < 0) {
      setState(() => _error = 'Harga tidak valid.');
      return;
    }
    setState(() {
      _lines.removeWhere((line) => line.stock.id == stock.id);
      _lines.add(_PurchaseLineDraft(stock: stock, qtyMilli: qty, harga: harga));
      _qty.clear();
      _harga.clear();
      _stockId = null;
      _error = null;
    });
  }

  void _save() {
    if (_lines.isEmpty) {
      setState(() => _error = 'Tambahkan minimal satu barang.');
      return;
    }
    final diskon = tryParseRupiahToCents(_diskon.text) ?? 0;
    final ongkir = tryParseRupiahToCents(_ongkir.text) ?? 0;
    final ppn = tryParseRupiahToCents(_ppn.text) ?? 0;
    final bayarAwal = tryParseRupiahToCents(_bayarAwal.text) ?? 0;
    Navigator.pop(
      context,
      _PurchaseFormResult(
        supplierId: _supplierId,
        lines: [
          for (final line in _lines)
            PurchaseLineInput(
              stockItemId: line.stock.id,
              qtyMilli: line.qtyMilli,
              hargaSatuan: line.harga,
            ),
        ],
        tanggal: _tanggal,
        terminHari: _jenisBayar == 'KREDIT' ? _terminHari : 0,
        jenisBayar: _jenisBayar,
        diskon: diskon,
        ongkir: ongkir,
        ppn: ppn,
        bayarAwal: bayarAwal,
        metode: _metode,
        catatan: _catatan.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pembelian baru'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _supplierId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Supplier'),
                items: [
                  for (final supplier in widget.suppliers)
                    if (supplier['aktif'] == 1 || supplier['id'] == _supplierId)
                      DropdownMenuItem(
                        value: supplier['id'] as int,
                        child: Text('${supplier['nama']}'),
                      ),
                ],
                onChanged: (value) =>
                    setState(() => _supplierId = value ?? _supplierId),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _tanggal,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => _tanggal = picked);
                        }
                      },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(dateId.format(_tanggal)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _jenisBayar,
                      decoration: const InputDecoration(labelText: 'Bayar'),
                      items: const [
                        DropdownMenuItem(value: 'KREDIT', child: Text('Kredit')),
                        DropdownMenuItem(value: 'TUNAI', child: Text('Tunai')),
                      ],
                      onChanged: (value) => setState(
                        () => _jenisBayar = value ?? 'KREDIT',
                      ),
                    ),
                  ),
                ],
              ),
              if (_jenisBayar == 'KREDIT') ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: _terminHari,
                  decoration: const InputDecoration(
                    labelText: 'Termin jatuh tempo',
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('0 hari')),
                    DropdownMenuItem(value: 7, child: Text('7 hari')),
                    DropdownMenuItem(value: 14, child: Text('14 hari')),
                    DropdownMenuItem(value: 30, child: Text('30 hari')),
                    DropdownMenuItem(value: 60, child: Text('60 hari')),
                  ],
                  onChanged: (value) =>
                      setState(() => _terminHari = value ?? 0),
                ),
              ],
              const Divider(height: 24),
              DropdownButtonFormField<int>(
                initialValue: _stockId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Barang'),
                items: [
                  for (final stock in widget.stocks)
                    DropdownMenuItem(
                      value: stock.id,
                      child: Text('${stock.nama} (${stock.satuan})'),
                    ),
                ],
                onChanged: (value) => setState(() => _stockId = value),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qty,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Qty',
                        helperText: _selectedStock == null
                            ? null
                            : 'Desimal ${_selectedStock?.desimal ?? 0}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _harga,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Harga satuan',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: 'Tambah barang',
                    onPressed: _addLine,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              if (_lines.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final line in _lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(line.stock.nama),
                    subtitle: Text(
                      '${formatQuantity(line.qtyMilli, line.stock.desimal, satuan: line.stock.satuan)} × '
                      '${formatRupiah(line.harga)}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => setState(() => _lines.remove(line)),
                    ),
                  ),
                const Divider(height: 24),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _diskon,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Diskon'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _ongkir,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Ongkir'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _ppn,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'PPN'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _bayarAwal,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Dibayar sekarang',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _metode,
                      decoration: const InputDecoration(labelText: 'Sumber dana'),
                      items: const [
                        DropdownMenuItem(value: 'CASH', child: Text('Kas tunai')),
                        DropdownMenuItem(
                          value: 'TRANSFER',
                          child: Text('Transfer'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _metode = value ?? 'CASH'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _catatan,
                decoration: const InputDecoration(labelText: 'Catatan'),
              ),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _save, child: const Text('Simpan')),
      ],
    );
  }
}

class _PurchaseLineDraft {
  const _PurchaseLineDraft({
    required this.stock,
    required this.qtyMilli,
    required this.harga,
  });

  final StockItem stock;
  final int qtyMilli;
  final int harga;
}
