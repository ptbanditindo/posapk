import 'package:flutter/material.dart';

import '../../auth/permissions.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../data/opening_balance_service.dart';
import '../../data/supplier_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

const _jenisStok = 'STOK';
const _jenisUtang = 'UTANG_SUPPLIER';
const _jenisPiutang = 'PIUTANG_PELANGGAN';

class OpeningBalanceScreen extends StatefulWidget {
  const OpeningBalanceScreen({super.key});

  @override
  State<OpeningBalanceScreen> createState() => _OpeningBalanceScreenState();
}

class _OpeningBalanceScreenState extends State<OpeningBalanceScreen> {
  bool _loading = true;
  bool _busy = false;
  Map<String, Object?>? _active;
  Map<String, int> _summary = const {};
  List<StockItem> _stocks = const [];
  List<Map<String, Object?>> _suppliers = const [];
  List<Customer> _customers = const [];
  List<Map<String, Object?>> _payables = const [];
  List<Map<String, Object?>> _receivables = const [];
  final List<_DraftItem> _items = [];
  final _catatan = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _catatan.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final active = await OpeningBalanceService.instance.active();
    final summary = await OpeningBalanceService.instance.summary();
    final stocks = await AppDatabase.instance.listStock();
    final suppliers = await SupplierService.instance.listSuppliers();
    final customers = await AppDatabase.instance.listCustomers();
    final payables = await OpeningBalanceService.instance.openPayables();
    final receivables = await OpeningBalanceService.instance.openReceivables();
    if (!mounted) return;
    setState(() {
      _active = active;
      _summary = summary;
      _stocks = stocks;
      _suppliers = suppliers;
      _customers = customers;
      _payables = payables;
      _receivables = receivables;
      _loading = false;
    });
  }

  bool get _isOwner => AppState.instance.operator?.isOwner ?? false;

  Future<void> _addStock() async {
    if (_stocks.isEmpty) return;
    final stock = await showDialog<StockItem>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Pilih barang'),
        children: [
          for (final item in _stocks)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Text('${item.nama} (${item.satuan})'),
            ),
        ],
      ),
    );
    if (stock == null || !mounted) return;
    final qty = TextEditingController();
    final modal = TextEditingController(
      text: formatRupiahPlain(stock.hargaModalCents),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stok awal ${stock.nama}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qty,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Jumlah',
                hintText: 'Contoh: 10',
                helperText:
                    'Satuan ${stock.satuan}. Desimal ${stock.desimal}.',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: modal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Modal per satuan',
                hintText: 'Contoh: 45000',
                helperText: 'Boleh berbeda dari modal barang yang tersimpan.',
              ),
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
            child: const Text('Tambah ke daftar'),
          ),
        ],
      ),
    );
    final milli = parseQuantityToMilli(qty.text, desimal: stock.desimal);
    final modalCents = tryParseRupiahToCents(modal.text);
    qty.dispose();
    modal.dispose();
    if (ok != true || milli == null || milli <= 0) return;
    if (modalCents == null || modalCents < 0) {
      if (mounted) {
        showSnack(
          context,
          'Modal per satuan harus berupa angka tanpa titik atau huruf.',
          error: true,
        );
      }
      return;
    }
    setState(() {
      _items.add(
        _DraftItem(
          jenis: _jenisStok,
          refId: stock.id,
          label: stock.nama,
          jumlahMilli: milli,
          unitCostCents: modalCents,
        ),
      );
    });
  }

  Future<void> _addNamed(String jenis) async {
    final isDebt = jenis == _jenisUtang;
    final options = isDebt
        ? [
            for (final supplier in _suppliers)
              (
                id: supplier['id'] as int,
                label: '${supplier['nama']}',
              ),
          ]
        : [
            for (final customer in _customers)
              (id: customer.id, label: customer.nama),
          ];
    if (options.isEmpty) {
      showSnack(
        context,
        isDebt ? 'Belum ada supplier.' : 'Belum ada pelanggan.',
        error: true,
      );
      return;
    }
    final picked = await showDialog<(int, String)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(isDebt ? 'Pilih supplier' : 'Pilih pelanggan'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, (option.id, option.label)),
              child: Text(option.label),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final nominal = TextEditingController();
    final due = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isDebt ? 'Utang awal ${picked.$2}' : 'Piutang awal ${picked.$2}',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nominal,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Nominal',
                hintText: 'Contoh: 500000',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: due,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                labelText: 'Jatuh tempo (opsional)',
                hintText: 'Contoh: 2026-12-31',
                helperText: 'Format tahun-bulan-tanggal.',
              ),
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
            child: const Text('Tambah ke daftar'),
          ),
        ],
      ),
    );
    final cents = tryParseRupiahToCents(nominal.text);
    final dueDate = DateTime.tryParse(due.text.trim());
    nominal.dispose();
    due.dispose();
    if (ok != true || cents == null || cents <= 0) return;
    setState(() {
      _items.add(
        _DraftItem(
          jenis: jenis,
          refId: picked.$1,
          label: picked.$2,
          nominal: cents,
          jatuhTempo: dueDate == null ? null : dateOnly.format(dueDate),
        ),
      );
    });
  }

  Future<void> _payOpening({
    required Map<String, Object?> row,
    required bool payable,
  }) async {
    final sisa = ((row['nominal_cents'] as num?)?.toInt() ?? 0) -
        ((row['terbayar_cents'] as num?)?.toInt() ?? 0);
    final nominal = TextEditingController(text: formatRupiahPlain(sisa));
    var metode = 'CASH';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            payable
                ? 'Bayar utang ${row['supplier_nama_snapshot'] ?? ''}'
                : 'Tagih piutang ${row['customer_nama_snapshot'] ?? ''}',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nominal,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Nominal',
                  hintText: 'Contoh: 250000',
                  helperText: 'Sisa ${formatRupiah(sisa)}',
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: metode,
                decoration: const InputDecoration(
                  labelText: 'Metode pembayaran',
                ),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                  DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => metode = value);
                },
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
              child: Text(payable ? 'Bayar' : 'Tagih'),
            ),
          ],
        ),
      ),
    );
    final cents = tryParseRupiahToCents(nominal.text);
    nominal.dispose();
    if (ok != true || cents == null || cents <= 0) return;
    setState(() => _busy = true);
    try {
      final actor = AppState.instance.requireOperator;
      if (payable) {
        await OpeningBalanceService.instance.payPayable(
          payableSyncId: '${row['sync_id']}',
          nominal: cents,
          metode: metode,
          actor: actor,
          enqueue: (txn, syncId) =>
              SyncService.instance.enqueueOpeningBalance(syncId, txn: txn),
        );
      } else {
        await OpeningBalanceService.instance.collectReceivable(
          receivableSyncId: '${row['sync_id']}',
          nominal: cents,
          metode: metode,
          actor: actor,
          enqueue: (txn, syncId) =>
              SyncService.instance.enqueueOpeningBalance(syncId, txn: txn),
        );
      }
      await _load();
      if (mounted) {
        showSnack(context, payable ? 'Utang awal dibayar.' : 'Piutang awal ditagih.');
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membayar: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post() async {
    if (!_isOwner) {
      showSnack(context, 'Saldo awal hanya dicatat pemilik.', error: true);
      return;
    }
    if (_items.isEmpty) {
      showSnack(context, 'Tambahkan minimal satu baris saldo awal.',
          error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await OpeningBalanceService.instance.post(
        items: [
          for (final item in _items)
            OpeningItemInput(
              jenis: item.jenis,
              refId: item.refId,
              jumlahMilli: item.jumlahMilli,
              nominal: item.nominal,
              unitCostCents: item.unitCostCents,
              jatuhTempo: item.jatuhTempo,
            ),
        ],
        actor: AppState.instance.requireOperator,
        catatan: _catatan.text,
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueOpeningBalance(syncId, txn: txn),
      );
      _items.clear();
      _catatan.clear();
      await _load();
      if (mounted) showSnack(context, 'Saldo awal disimpan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan saldo awal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _void() async {
    if (!_isOwner) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Koreksi saldo awal'),
        content: TextField(
          controller: reason,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Alasan koreksi',
            hintText: 'Contoh: salah hitung stok awal',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Koreksi'),
          ),
        ],
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (ok != true || text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await OpeningBalanceService.instance.voidActive(
        reason: text,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueOpeningBalance(syncId, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Saldo awal dikoreksi.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal mengoreksi saldo awal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saldo awal toko')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SectionCard(
                  title: 'Sekali per toko',
                  child: Text(
                    'Saldo awal mencatat stok, utang supplier, dan piutang '
                    'pelanggan yang sudah ada sebelum aplikasi dipakai. '
                    'Mekanisme ini tidak membuat nota atau pembelian palsu. '
                    'Koreksi dilakukan dengan membatalkan saldo awal lalu '
                    'mencatat ulang.',
                  ),
                ),
                const SizedBox(height: 12),
                if (_active == null)
                  ..._buildForm()
                else ...[
                  ..._buildActive(),
                  ..._buildFinance(),
                ],
                if (_busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
    );
  }

  List<Widget> _buildActive() {
    final items = _active?['items'] as List<Map<String, Object?>>? ?? const [];
    return [
      SectionCard(
        title: 'Saldo awal aktif',
        subtitle:
            'Dicatat ${_active?['posted_at']} oleh ${_active?['posted_by'] ?? '-'}',
        child: Column(
          children: [
            _line('Stok', formatQuantity(_summary['stok_milli'] ?? 0, 0)),
            _line('Utang supplier', formatRupiah(_summary['utang'] ?? 0)),
            _line('Piutang pelanggan', formatRupiah(_summary['piutang'] ?? 0)),
            const Divider(),
            for (final item in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('${item['ref_nama_snapshot']}'),
                subtitle: Text(
                  item['jenis'] == _jenisStok
                      ? '${formatQuantity((item['jumlah_milli'] as num).toInt(), 0)} unit'
                      : item['jenis'] == _jenisUtang
                          ? 'Utang supplier'
                          : 'Piutang pelanggan',
                ),
                trailing: Text(
                  item['jenis'] == _jenisStok
                      ? ''
                      : formatRupiah((item['nominal'] as num).toInt()),
                ),
              ),
            if (_isOwner) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _void,
                  icon: const Icon(Icons.undo_outlined),
                  label: const Text('Koreksi saldo awal'),
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildFinance() {
    final canPay = _isOwner || AppState.instance.can(permissionPayDebt);
    final canCollect = AppState.instance.canWriteMoney;
    final sections = <Widget>[];
    if (_payables.isNotEmpty) {
      sections.add(
        SectionCard(
          title: 'Utang awal belum lunas',
          child: Column(
            children: [
              for (final row in _payables)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${row['supplier_nama_snapshot'] ?? ''}'),
                  subtitle: Text(
                    row['jatuh_tempo'] == null
                        ? 'Tanpa jatuh tempo'
                        : 'Jatuh tempo ${row['jatuh_tempo']}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatRupiah(
                          ((row['nominal_cents'] as num?)?.toInt() ?? 0) -
                              ((row['terbayar_cents'] as num?)?.toInt() ?? 0),
                        ),
                      ),
                      if (canPay)
                        IconButton(
                          icon: const Icon(Icons.payments_outlined),
                          tooltip: 'Bayar utang',
                          onPressed: _busy
                              ? null
                              : () => _payOpening(row: row, payable: true),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (_receivables.isNotEmpty) {
      sections.add(
        SectionCard(
          title: 'Piutang awal belum lunas',
          child: Column(
            children: [
              for (final row in _receivables)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${row['customer_nama_snapshot'] ?? ''}'),
                  subtitle: Text(
                    row['jatuh_tempo'] == null
                        ? 'Tanpa jatuh tempo'
                        : 'Jatuh tempo ${row['jatuh_tempo']}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatRupiah(
                          ((row['nominal_cents'] as num?)?.toInt() ?? 0) -
                              ((row['terbayar_cents'] as num?)?.toInt() ?? 0),
                        ),
                      ),
                      if (canCollect)
                        IconButton(
                          icon: const Icon(Icons.receipt_long_outlined),
                          tooltip: 'Tagih piutang',
                          onPressed: _busy
                              ? null
                              : () => _payOpening(row: row, payable: false),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (sections.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      for (final section in sections) ...[
        section,
        const SizedBox(height: 12),
      ],
    ];
  }

  List<Widget> _buildForm() {
    if (!_isOwner) {
      return [
        const EmptyState(
          icon: Icons.lock_outline,
          title: 'Belum ada saldo awal',
          subtitle: 'Hanya pemilik yang dapat mencatat saldo awal toko.',
        ),
      ];
    }
    return [
      SectionCard(
        title: 'Baris saldo awal',
        subtitle: 'Tambahkan stok, utang supplier, dan piutang pelanggan.',
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addStock,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('Stok awal'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addNamed(_jenisUtang),
                  icon: const Icon(Icons.local_shipping_outlined),
                  label: const Text('Utang supplier'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addNamed(_jenisPiutang),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Piutang pelanggan'),
                ),
              ],
            ),
            if (_items.isEmpty) ...[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Belum ada baris saldo awal.'),
              ),
            ] else
              for (final item in _items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.label),
                  subtitle: Text(
                    item.jenis == _jenisStok
                        ? 'Stok ${formatQuantity(item.jumlahMilli, 0)} · '
                            'modal ${formatRupiah(item.unitCostCents ?? 0)}'
                        : item.jenis == _jenisUtang
                            ? 'Utang supplier'
                            : 'Piutang pelanggan',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.nominal > 0) Text(formatRupiah(item.nominal)),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => setState(() => _items.remove(item)),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 8),
            TextField(
              controller: _catatan,
              decoration: const InputDecoration(
                labelText: 'Catatan',
                hintText: 'Contoh: saldo per 1 November 2026',
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _post,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Simpan saldo awal'),
              ),
            ),
          ],
        ),
      ),
    ];
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

class _DraftItem {
  const _DraftItem({
    required this.jenis,
    required this.refId,
    required this.label,
    this.jumlahMilli = 0,
    this.nominal = 0,
    this.unitCostCents,
    this.jatuhTempo,
  });

  final String jenis;
  final int refId;
  final String label;
  final int jumlahMilli;
  final int nominal;
  final int? unitCostCents;
  final String? jatuhTempo;
}
