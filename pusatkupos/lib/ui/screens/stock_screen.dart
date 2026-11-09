import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/app_database.dart';
import '../../data/feature_flags.dart';
import '../../data/models.dart';
import '../../data/opname_service.dart';
import '../../data/supplier_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class StockScreen extends StatefulWidget {
  const StockScreen({super.key});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  final _search = TextEditingController();
  Future<List<StockItem>>? _future;
  Future<List<OpnameHoldView>>? _holds;

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
      _future = AppDatabase.instance.listStock(query: _search.text);
      _holds = OpnameService.instance.pendingHolds();
    });
  }

  Future<void> _openForm([StockItem? item]) async {
    if (!AppState.instance.can('ubah_stok')) {
      showSnack(context, 'Izin ubah stok tidak tersedia.', error: true);
      return;
    }
    if (item == null && !AppState.instance.isOwner) {
      showSnack(
        context,
        'Hanya pemilik yang dapat menambah barang beserta harganya.',
        error: true,
      );
      return;
    }
    final supplierEnabled = FeatureFlagsService.instance.supplierHubEnabled;
    final suppliers = supplierEnabled
        ? await SupplierService.instance.listSuppliers(activeOnly: true)
        : <Map<String, Object?>>[];
    final selected = item == null
        ? <int>{}
        : await SupplierService.instance.supplierIdsForItem(item.id);
    if (!mounted) return;
    final input = await showDialog<StockInput>(
      context: context,
      builder: (_) => _StockDialog(
        item: item,
        suppliers: suppliers,
        selectedSupplierIds: selected,
      ),
    );
    if (input == null) return;
    try {
      final id = await AppDatabase.instance.saveStockItem(
        id: item?.id,
        kode: input.kode,
        nama: input.nama,
        hargaModalCents: input.hargaModalCents,
        hargaJualCents: input.hargaJualCents,
        jumlah: input.jumlahMilli ~/ 1000,
        jumlahMilli: input.jumlahMilli,
        stokAwalMilli: item?.jumlahMilli,
        stokMinimum: input.stokMinimum,
        satuan: input.satuan,
        desimal: input.desimal,
        actor: AppState.instance.operator,
        enqueue: (txn, id) => SyncService.instance.enqueueStock(id, txn: txn),
        enqueueMovement: (txn, movementId) =>
            SyncService.instance.enqueueStockMovement(movementId, txn: txn),
      );
      await SupplierService.instance.syncItemSuppliers(
        id,
        input.supplierIds,
        enqueue: (txn, supplierId) =>
            SyncService.instance.enqueueSupplier(supplierId, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _stockIn(StockItem item) async {
    if (!AppState.instance.can('stok_masuk')) {
      showSnack(context, 'Izin stok masuk tidak tersedia.', error: true);
      return;
    }
    final input = await showDialog<StockInInput>(
      context: context,
      builder: (_) => _StockInDialog(item: item),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.stockIn(
        item: item,
        qty: input.qtyMilli ~/ 1000,
        qtyMilli: input.qtyMilli,
        alasan: input.alasan,
        actor: AppState.instance.operator,
        enqueueMovement: (txn, movementId) =>
            SyncService.instance.enqueueStockMovement(movementId, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menambah stok: $error', error: true);
    }
  }

  Future<void> _stockOut(StockItem item) async {
    if (!AppState.instance.can('stok_keluar')) {
      showSnack(context, 'Izin stok keluar tidak tersedia.', error: true);
      return;
    }
    final input = await showDialog<_QtyReason>(
      context: context,
      builder: (_) => _StockOutDialog(item: item),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.stockOut(
        item: item,
        qty: input.qtyMilli ~/ 1000,
        qtyMilli: input.qtyMilli,
        alasan: input.alasan,
        actor: AppState.instance.operator,
        enqueueMovement: (txn, movementId) =>
            SyncService.instance.enqueueStockMovement(movementId, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal stok keluar: $error', error: true);
    }
  }

  Future<void> _opname(StockItem item) async {
    if (!AppState.instance.can('opname')) {
      showSnack(context, 'Izin opname tidak tersedia.', error: true);
      return;
    }
    final input = await showDialog<_QtyReason>(
      context: context,
      builder: (_) => _OpnameDialog(item: item),
    );
    if (input == null) return;
    try {
      final gate = await OpnameService.instance.record(
        itemId: item.id,
        namaItem: item.nama,
        jumlahFisikMilli: input.qtyMilli,
        alasan: input.alasan,
        actor: AppState.instance.requireOperator,
        enqueueMovement: (txn, movementId) =>
            SyncService.instance.enqueueStockMovement(movementId, txn: txn),
      );
      AppState.instance.touch();
      _load();
      if (!mounted) return;
      if (gate.held) {
        showSnack(
          context,
          'Opname ditahan sampai perangkat sinkron: '
          '${gate.missing.join(', ')}.',
        );
      } else {
        showSnack(context, 'Opname tersimpan.');
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal opname: $error', error: true);
    }
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
                    hintText: 'Cari nama atau kode',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => _load(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed:
                    AppState.instance.can('ubah_stok') &&
                        AppState.instance.isOwner
                    ? () => _openForm()
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Barang'),
              ),
            ],
          ),
        ),
        FutureBuilder<List<OpnameHoldView>>(
          future: _holds,
          builder: (context, snapshot) {
            final holds = snapshot.data ?? const [];
            if (holds.isEmpty) return const SizedBox.shrink();
            final warning = holds.any((hold) => hold.warnOffline);
            return Card(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              color: warning
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      warning
                          ? Icons.warning_amber_outlined
                          : Icons.hourglass_top,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Opname menunggu sinkron (${holds.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            warning
                                ? 'Ada perangkat yang belum sinkron lebih dari '
                                      '24 jam. Opname diterapkan sementara '
                                      'setelah 7 hari bila belum kembali.'
                                : 'Hasil opname akan diterapkan setelah semua '
                                      'perangkat menyelesaikan sinkronisasi.',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            holds
                                .map(
                                  (hold) =>
                                      '${hold.namaItem} → '
                                      '${(hold.jumlahFisikMilli / 1000).toStringAsFixed(hold.jumlahFisikMilli % 1000 == 0 ? 0 : 3)}'
                                      '${hold.provisional ? ' (sementara)' : ''}',
                                )
                                .join(' · '),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        Expanded(
          child: FutureBuilder<List<StockItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return EmptyState(
                  title: 'Gagal memuat stok',
                  subtitle: '${snapshot.error}',
                  icon: Icons.error_outline,
                  action: FilledButton(
                    onPressed: _load,
                    child: const Text('Coba lagi'),
                  ),
                );
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  title: 'Belum ada sparepart',
                  subtitle: 'Tambahkan barang agar bisa dipakai di kasir.',
                  icon: Icons.inventory_2_outlined,
                  action: FilledButton(
                    onPressed: AppState.instance.isOwner
                        ? () => _openForm()
                        : null,
                    child: const Text('Tambah barang'),
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _load(),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = rows[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _openForm(item),
                        leading: CircleAvatar(
                          backgroundColor: item.negatif
                              ? Theme.of(context).colorScheme.errorContainer
                              : item.lowStock
                                  ? Theme.of(context).colorScheme.errorContainer
                                  : null,
                          child: Icon(
                            item.negatif
                                ? Icons.error_outline
                                : item.lowStock
                                    ? Icons.warning_amber_outlined
                                    : Icons.inventory_2_outlined,
                          ),
                        ),
                        title: Text(item.nama),
                        subtitle: Text(
                          '${item.kode} · ${formatRupiah(item.hargaJualCents)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  item.jumlahLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  item.negatif
                                      ? 'negatif'
                                      : item.lowStock
                                          ? 'menipis'
                                          : 'stok',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'in') _stockIn(item);
                                if (value == 'out') _stockOut(item);
                                if (value == 'opname') _opname(item);
                              },
                              itemBuilder: (context) => [
                                if (AppState.instance.can('stok_masuk'))
                                  const PopupMenuItem(
                                    value: 'in',
                                    child: Text('Stok masuk'),
                                  ),
                                if (AppState.instance.can('stok_keluar'))
                                  const PopupMenuItem(
                                    value: 'out',
                                    child: Text('Stok keluar'),
                                  ),
                                if (AppState.instance.can('opname'))
                                  const PopupMenuItem(
                                    value: 'opname',
                                    child: Text('Opname'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        onLongPress: AppState.instance.can('stok_masuk')
                            ? () => _stockIn(item)
                            : null,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Ketuk barang untuk ubah; menu di kanan untuk stok masuk, '
                  'keluar, atau opname.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class StockInput {
  const StockInput({
    required this.kode,
    required this.nama,
    required this.hargaModalCents,
    required this.hargaJualCents,
    required this.jumlahMilli,
    required this.stokMinimum,
    required this.satuan,
    required this.desimal,
    this.supplierIds = const {},
  });

  final String kode;
  final String nama;
  final int hargaModalCents;
  final int hargaJualCents;
  final int jumlahMilli;
  final int stokMinimum;
  final String satuan;
  final int desimal;
  final Set<int> supplierIds;
}

class _StockDialog extends StatefulWidget {
  const _StockDialog({
    this.item,
    this.suppliers = const [],
    this.selectedSupplierIds = const {},
  });

  final StockItem? item;
  final List<Map<String, Object?>> suppliers;
  final Set<int> selectedSupplierIds;

  @override
  State<_StockDialog> createState() => _StockDialogState();
}

class _StockDialogState extends State<_StockDialog> {
  late final TextEditingController _kode;
  late final TextEditingController _nama;
  late final TextEditingController _modal;
  late final TextEditingController _jual;
  late final TextEditingController _jumlah;
  late final TextEditingController _minimum;
  late final TextEditingController _satuan;
  int _desimal = 0;
  late final Set<int> _supplierIds = {...widget.selectedSupplierIds};
  String? _error;

  bool get _isOwner => AppState.instance.isOwner;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _kode = TextEditingController(text: item?.kode ?? '');
    _nama = TextEditingController(text: item?.nama ?? '');
    _modal = TextEditingController(
      text: item == null ? '' : formatRupiahPlain(item.hargaModalCents),
    );
    _jual = TextEditingController(
      text: item == null ? '' : formatRupiahPlain(item.hargaJualCents),
    );
    _desimal = item?.desimal ?? 0;
    _jumlah = TextEditingController(
      text: item == null
          ? '0'
          : formatQuantity(item.jumlahMilli, item.desimal),
    );
    _minimum = TextEditingController(text: item?.stokMinimum.toString() ?? '0');
    _satuan = TextEditingController(text: item?.satuan ?? 'pcs');
  }

  @override
  void dispose() {
    _kode.dispose();
    _nama.dispose();
    _modal.dispose();
    _jual.dispose();
    _jumlah.dispose();
    _minimum.dispose();
    _satuan.dispose();
    super.dispose();
  }

  void _save() {
    if (_kode.text.trim().isEmpty || _nama.text.trim().isEmpty) {
      setState(() => _error = 'Kode dan nama wajib diisi.');
      return;
    }
    final qtyMilli = parseQuantityToMilli(_jumlah.text, desimal: _desimal);
    if (qtyMilli == null || qtyMilli < 0) {
      setState(() => _error = 'Jumlah stok tidak valid.');
      return;
    }
    final modal = _isOwner
        ? tryParseRupiahToCents(_modal.text)
        : (widget.item?.hargaModalCents ?? 0);
    final jual = _isOwner
        ? tryParseRupiahToCents(_jual.text)
        : (widget.item?.hargaJualCents ?? 0);
    if (modal == null || jual == null) {
      setState(() => _error = 'Format harga tidak valid.');
      return;
    }
    Navigator.pop(
      context,
      StockInput(
        kode: _kode.text.trim(),
        nama: _nama.text.trim(),
        hargaModalCents: modal,
        hargaJualCents: jual,
        jumlahMilli: qtyMilli,
        stokMinimum: int.tryParse(_minimum.text.trim()) ?? 0,
        satuan: _satuan.text.trim().isEmpty ? 'pcs' : _satuan.text.trim(),
        desimal: _desimal,
        supplierIds: _supplierIds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'Barang baru' : 'Ubah barang'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _kode,
              autofocus: widget.item == null,
              decoration: const InputDecoration(labelText: 'Kode'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nama,
              decoration: const InputDecoration(labelText: 'Nama barang'),
            ),
            const SizedBox(height: 10),
            if (_isOwner)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _modal,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Harga modal'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _jual,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Harga jual'),
                    ),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Harga hanya dapat diubah pemilik.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _jumlah,
                    enabled: AppState.instance.isOwner,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Stok',
                      helperText: AppState.instance.isOwner
                          ? null
                          : 'Gunakan opname stok untuk mengubah stok.',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _minimum,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Stok minimum'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _satuan,
                    decoration: const InputDecoration(
                      labelText: 'Satuan',
                      hintText: 'pcs / liter / meter',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _desimal,
                    decoration: const InputDecoration(
                      labelText: 'Desimal kuantitas',
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('0')),
                      DropdownMenuItem(value: 1, child: Text('1')),
                      DropdownMenuItem(value: 2, child: Text('2')),
                      DropdownMenuItem(value: 3, child: Text('3')),
                    ],
                    onChanged: (value) =>
                        setState(() => _desimal = value ?? 0),
                  ),
                ),
              ],
            ),
            if (widget.suppliers.isNotEmpty) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Supplier',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: widget.suppliers.map((supplier) {
                    final id = supplier['id'] as int;
                    return FilterChip(
                      label: Text('${supplier['nama']}'),
                      selected: _supplierIds.contains(id),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _supplierIds.add(id);
                          } else {
                            _supplierIds.remove(id);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
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

class StockInInput {
  const StockInInput(this.qtyMilli, this.alasan);

  final int qtyMilli;
  final String? alasan;
}

class _StockInDialog extends StatefulWidget {
  const _StockInDialog({required this.item});

  final StockItem item;

  @override
  State<_StockInDialog> createState() => _StockInDialogState();
}

class _StockInDialogState extends State<_StockInDialog> {
  final _qty = TextEditingController();
  final _alasan = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _alasan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Stok masuk · ${widget.item.nama}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Jumlah masuk'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alasan,
            decoration: const InputDecoration(labelText: 'Keterangan'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
          FilledButton(
          onPressed: () {
            final qty = parseQuantityToMilli(
              _qty.text,
              desimal: widget.item.desimal,
            );
            if (qty == null || qty <= 0) {
              setState(() => _error = 'Jumlah masuk tidak valid.');
              return;
            }
            Navigator.pop(
              context,
              StockInInput(
                qty,
                _alasan.text.trim().isEmpty ? null : _alasan.text.trim(),
              ),
            );
          },
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}

class _QtyReason {
  const _QtyReason(this.qtyMilli, this.alasan);

  final int qtyMilli;
  final String alasan;
}

class _StockOutDialog extends StatefulWidget {
  const _StockOutDialog({required this.item});

  final StockItem item;

  @override
  State<_StockOutDialog> createState() => _StockOutDialogState();
}

class _StockOutDialogState extends State<_StockOutDialog> {
  final _qty = TextEditingController();
  final _alasan = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _alasan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Stok keluar · ${widget.item.nama}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Jumlah keluar',
              helperText: 'Stok ${widget.item.jumlahLabel}',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alasan,
            decoration: const InputDecoration(
              labelText: 'Alasan (wajib)',
              hintText: 'Rusak / dipakai sendiri',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            final qty = parseQuantityToMilli(
              _qty.text,
              desimal: widget.item.desimal,
            );
            if (qty == null || qty <= 0) {
              setState(() => _error = 'Jumlah keluar tidak valid.');
              return;
            }
            if (_alasan.text.trim().isEmpty) {
              setState(() => _error = 'Alasan wajib diisi.');
              return;
            }
            Navigator.pop(context, _QtyReason(qty, _alasan.text.trim()));
          },
          child: const Text('Keluarkan'),
        ),
      ],
    );
  }
}

class _OpnameDialog extends StatefulWidget {
  const _OpnameDialog({required this.item});

  final StockItem item;

  @override
  State<_OpnameDialog> createState() => _OpnameDialogState();
}

class _OpnameDialogState extends State<_OpnameDialog> {
  late final TextEditingController _fisik;
  final _alasan = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _fisik = TextEditingController(
      text: formatQuantity(widget.item.jumlahMilli, widget.item.desimal),
    );
  }

  @override
  void dispose() {
    _fisik.dispose();
    _alasan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Opname · ${widget.item.nama}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Stok sistem: ${widget.item.jumlahLabel}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _fisik,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Jumlah fisik'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alasan,
            decoration: const InputDecoration(labelText: 'Catatan (opsional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            final qty = parseQuantityToMilli(
              _fisik.text,
              desimal: widget.item.desimal,
            );
            if (qty == null || qty < 0) {
              setState(() => _error = 'Jumlah fisik tidak valid.');
              return;
            }
            Navigator.pop(context, _QtyReason(qty, _alasan.text.trim()));
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
