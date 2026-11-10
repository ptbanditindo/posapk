import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class JasaScreen extends StatefulWidget {
  const JasaScreen({super.key});

  @override
  State<JasaScreen> createState() => _JasaScreenState();
}

class _JasaScreenState extends State<JasaScreen> {
  Future<List<ServiceCatalog>>? _future;

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
      _future = AppDatabase.instance.listCatalog();
    });
  }

  Future<void> _openForm([ServiceCatalog? item]) async {
    if (!AppState.instance.can('ubah_harga_jasa')) {
      showSnack(context, 'Izin ubah harga jasa tidak tersedia.', error: true);
      return;
    }
    final input = await showDialog<CatalogInput>(
      context: context,
      builder: (_) => _CatalogDialog(item: item),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.saveCatalog(
        id: item?.id,
        nama: input.nama,
        hargaCents: input.hargaCents,
        hargaModalCents: input.hargaModalCents,
        intervalBulan: input.intervalBulan,
        actor: AppState.instance.operator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueueCatalog(id, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Daftar tarif jasa',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (AppState.instance.isOwner ||
                  AppState.instance.can('ubah_harga_jasa'))
                FilledButton.icon(
                  onPressed: () => _openForm(),
                  icon: const Icon(Icons.add),
                  label: const Text('Tambah jasa'),
                ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ServiceCatalog>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  title: 'Belum ada tarif jasa',
                  subtitle: 'Tambahkan jasa agar cepat dipilih di kasir.',
                  icon: Icons.build_outlined,
                  action: AppState.instance.isOwner ||
                          AppState.instance.can('ubah_harga_jasa')
                      ? FilledButton(
                          onPressed: () => _openForm(),
                          child: const Text('Tambah jasa'),
                        )
                      : null,
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
                        onTap: AppState.instance.isOwner ||
                                AppState.instance.can('ubah_harga_jasa')
                            ? () => _openForm(item)
                            : null,
                        leading: const CircleAvatar(
                          child: Icon(Icons.build_outlined),
                        ),
                        title: Text(item.nama),
                        subtitle: AppState.instance.isOwner
                            ? Text(
                                'Modal ${formatRupiah(item.hargaModalCents)}'
                                '${item.intervalBulan > 0 ? ' · tiap ${item.intervalBulan} bulan' : ''}',
                              )
                            : item.intervalBulan > 0
                                ? Text('${item.intervalBulan} bulan')
                                : null,
                        trailing: Text(
                          formatRupiah(item.hargaCents),
                          style: const TextStyle(fontWeight: FontWeight.w700),
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
}

class CatalogInput {
  const CatalogInput(
    this.nama,
    this.hargaCents, {
    this.hargaModalCents = 0,
    this.intervalBulan = 0,
  });

  final String nama;
  final int hargaCents;
  final int hargaModalCents;
  final int intervalBulan;
}

class _CatalogDialog extends StatefulWidget {
  const _CatalogDialog({this.item});

  final ServiceCatalog? item;

  @override
  State<_CatalogDialog> createState() => _CatalogDialogState();
}

class _CatalogDialogState extends State<_CatalogDialog> {
  late final TextEditingController _nama;
  late final TextEditingController _harga;
  late final TextEditingController _modal;
  late final TextEditingController _interval;
  String? _error;

  bool get _isOwner => AppState.instance.isOwner;

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: widget.item?.nama ?? '');
    _harga = TextEditingController(
      text: widget.item == null
          ? ''
          : formatRupiahPlain(widget.item!.hargaCents),
    );
    _modal = TextEditingController(
      text: widget.item == null || widget.item!.hargaModalCents == 0
          ? ''
          : formatRupiahPlain(widget.item!.hargaModalCents),
    );
    _interval = TextEditingController(
      text: widget.item == null || widget.item!.intervalBulan == 0
          ? ''
          : '${widget.item!.intervalBulan}',
    );
  }

  @override
  void dispose() {
    _nama.dispose();
    _harga.dispose();
    _modal.dispose();
    _interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'Jasa baru' : 'Ubah jasa'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nama,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nama jasa',
              hintText: 'Contoh: Ganti oli mesin',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _harga,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Tarif jual (Rp)',
              hintText: 'Contoh: 50000',
              helperText: 'Harga yang ditagih ke pelanggan.',
            ),
          ),
          if (_isOwner) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _modal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Modal (opsional)',
                hintText: 'Contoh: 30000',
                helperText: 'Batas bawah harga saat kasir menjual.',
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Interval servis (bulan)',
              hintText: 'Contoh: 3',
              helperText: 'Kosongkan bila jasa ini tidak berkala.',
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
            if (_nama.text.trim().length < 2) {
              setState(() => _error = 'Nama jasa minimal 2 karakter.');
              return;
            }
            final harga = tryParseRupiahToCents(_harga.text);
            if (harga == null || harga <= 0) {
              setState(() => _error = 'Tarif jual wajib diisi lebih dari 0.');
              return;
            }
            final modalText = _modal.text.trim();
            final modal = _isOwner
                ? (modalText.isEmpty ? 0 : tryParseRupiahToCents(modalText))
                : (widget.item?.hargaModalCents ?? 0);
            if (modal == null || modal < 0) {
              setState(() => _error = 'Modal harus berupa angka tanpa titik atau huruf.');
              return;
            }
            if (modal > harga) {
              setState(() => _error = 'Modal tidak boleh melebihi tarif jual.');
              return;
            }
            final intervalText = _interval.text.trim();
            final interval =
                intervalText.isEmpty ? 0 : int.tryParse(intervalText);
            if (interval == null || interval < 0) {
              setState(() => _error = 'Interval servis harus berupa angka bulan.');
              return;
            }
            Navigator.pop(
              context,
              CatalogInput(
                _nama.text.trim(),
                harga,
                hargaModalCents: modal,
                intervalBulan: interval,
              ),
            );
          },
          child: const Text('Simpan jasa'),
        ),
      ],
    );
  }
}
