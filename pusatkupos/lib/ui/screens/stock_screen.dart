import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
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
    });
  }

  Future<void> _openForm([StockItem? item]) async {
    final input = await showDialog<StockInput>(
      context: context,
      builder: (_) => _StockDialog(item: item),
    );
    if (input == null) return;
    try {
      final id = await AppDatabase.instance.saveStockItem(
        id: item?.id,
        kode: input.kode,
        nama: input.nama,
        hargaModalCents: input.hargaModalCents,
        hargaJualCents: input.hargaJualCents,
        jumlah: input.jumlah,
        stokMinimum: input.stokMinimum,
      );
      await SyncService.instance.enqueueStock(id);
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _stockIn(StockItem item) async {
    final input = await showDialog<StockInInput>(
      context: context,
      builder: (_) => _StockInDialog(item: item),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.stockIn(
        item: item,
        qty: input.qty,
        alasan: input.alasan,
      );
      await SyncService.instance.enqueueStock(item.id);
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menambah stok: $error', error: true);
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
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: const Text('Barang'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<StockItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  title: 'Belum ada sparepart',
                  subtitle: 'Tambahkan barang agar bisa dipakai di kasir.',
                  icon: Icons.inventory_2_outlined,
                  action: FilledButton(
                    onPressed: () => _openForm(),
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
                          backgroundColor: item.lowStock
                              ? Theme.of(context).colorScheme.errorContainer
                              : null,
                          child: Icon(
                            item.lowStock
                                ? Icons.warning_amber_outlined
                                : Icons.inventory_2_outlined,
                          ),
                        ),
                        title: Text(item.nama),
                        subtitle: Text(
                          '${item.kode} · ${formatRupiah(item.hargaJualCents)}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${item.jumlah}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              item.lowStock ? 'menipis' : 'stok',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        onLongPress: () => _stockIn(item),
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
                  'Ketuk barang untuk ubah; tekan lama untuk stok masuk.',
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
    required this.jumlah,
    required this.stokMinimum,
  });

  final String kode;
  final String nama;
  final int hargaModalCents;
  final int hargaJualCents;
  final int jumlah;
  final int stokMinimum;
}

class _StockDialog extends StatefulWidget {
  const _StockDialog({this.item});

  final StockItem? item;

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
  String? _error;

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
    _jumlah = TextEditingController(text: item?.jumlah.toString() ?? '0');
    _minimum = TextEditingController(text: item?.stokMinimum.toString() ?? '0');
  }

  @override
  void dispose() {
    _kode.dispose();
    _nama.dispose();
    _modal.dispose();
    _jual.dispose();
    _jumlah.dispose();
    _minimum.dispose();
    super.dispose();
  }

  void _save() {
    if (_kode.text.trim().isEmpty || _nama.text.trim().isEmpty) {
      setState(() => _error = 'Kode dan nama wajib diisi.');
      return;
    }
    Navigator.pop(
      context,
      StockInput(
        kode: _kode.text.trim(),
        nama: _nama.text.trim(),
        hargaModalCents: parseRupiahToCents(_modal.text),
        hargaJualCents: parseRupiahToCents(_jual.text),
        jumlah: int.tryParse(_jumlah.text.trim()) ?? 0,
        stokMinimum: int.tryParse(_minimum.text.trim()) ?? 0,
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _modal,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Harga modal'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _jual,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Harga jual'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _jumlah,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Stok'),
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
  const StockInInput(this.qty, this.alasan);

  final int qty;
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
            final qty = int.tryParse(_qty.text.trim()) ?? 0;
            if (qty < 1) {
              setState(() => _error = 'Jumlah minimal 1.');
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
