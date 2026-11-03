import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _keluhan = TextEditingController();
  final _diskon = TextEditingController();
  final _bayar = TextEditingController();
  final List<JobDraft> _jobs = [];
  final List<PartDraft> _parts = [];

  List<Customer> _customers = [];
  List<VehicleUnit> _units = [];
  List<StockItem> _stock = [];
  List<ServiceCatalog> _catalog = [];
  int? _customerId;
  int? _unitId;
  String _metode = 'CASH';
  String _requestId = newSyncId();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    _keluhan.dispose();
    _diskon.dispose();
    _bayar.dispose();
    super.dispose();
  }

  int get _biayaJasa =>
      _jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents);
  int get _totalPart =>
      _parts.fold<int>(0, (sum, part) => sum + part.subtotalCents);
  int get _bruto => _biayaJasa + _totalPart;
  int get _diskonCents => parseRupiahToCents(_diskon.text);
  int get _total => (_bruto - _diskonCents).clamp(0, _bruto).toInt();
  int get _bayarCents => parseRupiahToCents(_bayar.text);

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final customers = await db.listCustomers();
    final stock = await db.listStock();
    final catalog = await db.listCatalog();
    var units = <VehicleUnit>[];
    var customerId = _customerId;
    if (customerId != null &&
        !customers.any((customer) => customer.id == customerId)) {
      customerId = null;
    }
    if (customerId != null) {
      units = await db.listUnits(customerId);
    }
    if (!mounted) return;
    setState(() {
      _customers = customers;
      _stock = stock;
      _catalog = catalog;
      _customerId = customerId;
      _units = units;
      final unitId = _unitId;
      if (unitId == null || !units.any((unit) => unit.id == unitId)) {
        _unitId = null;
      }
      _loading = false;
    });
  }

  Future<void> _addCustomer() async {
    final input = await showDialog<_QuickCustomer>(
      context: context,
      builder: (_) => const _QuickCustomerDialog(),
    );
    if (input == null) return;
    final id = await AppDatabase.instance.addCustomer(
      nama: input.nama,
      nomorHp: input.nomorHp,
      alamat: input.alamat,
    );
    _customerId = id;
    _unitId = null;
    AppState.instance.touch();
    await _load();
  }

  Future<void> _addUnit() async {
    final customerId = _customerId;
    if (customerId == null) {
      showSnack(context, 'Pilih pelanggan terlebih dahulu.', error: true);
      return;
    }
    final input = await showDialog<_QuickUnit>(
      context: context,
      builder: (_) => const _QuickUnitDialog(),
    );
    if (input == null) return;
    final id = await AppDatabase.instance.addUnit(
      customerId: customerId,
      unitType: input.unitType,
      nopol: input.nopol,
      jenisMobil: input.jenisMobil,
      tahunMobil: input.tahunMobil,
    );
    _unitId = id;
    AppState.instance.touch();
    await _load();
  }

  Future<void> _addJob() async {
    final job = await showDialog<JobDraft>(
      context: context,
      builder: (_) => _JobDialog(catalog: _catalog),
    );
    if (job == null) return;
    setState(() => _jobs.add(job));
  }

  Future<void> _addPart() async {
    if (_stock.isEmpty) {
      showSnack(context, 'Belum ada sparepart. Tambahkan di menu Stok.',
          error: true);
      return;
    }
    final part = await showDialog<PartDraft>(
      context: context,
      builder: (_) => _PartDialog(stock: _stock),
    );
    if (part == null) return;
    setState(() => _parts.add(part));
  }

  Future<void> _save() async {
    if (_customerId == null || _unitId == null) {
      showSnack(context, 'Pilih pelanggan dan unit.', error: true);
      return;
    }
    if (_jobs.isEmpty && _parts.isEmpty) {
      showSnack(context, 'Tambahkan minimal satu jasa atau part.', error: true);
      return;
    }
    if (_bayarCents <= 0) {
      showSnack(context, 'Isi nominal pembayaran.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await AppDatabase.instance.createTransaction(
        unitId: _unitId!,
        keluhan: _keluhan.text.trim().isEmpty
            ? 'Servis di kasir'
            : _keluhan.text.trim(),
        jobs: List.of(_jobs),
        parts: List.of(_parts),
        diskonCents: _diskonCents,
        metodeBayar: _metode,
        bayarCents: _bayarCents,
        requestId: _requestId,
      );
      final detail = await AppDatabase.instance.recordDetail(id);
      await SyncService.instance.enqueueNote(id);
      AppState.instance.touch();
      await _load();
      if (!mounted) return;
      setState(() {
        _jobs.clear();
        _parts.clear();
        _keluhan.clear();
        _diskon.clear();
        _bayar.clear();
        _unitId = null;
        _requestId = newSyncId();
      });
      if (detail != null) await _showReceipt(detail);
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyimpan: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showReceipt(RecordDetail detail) async {
    final record = detail.record;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nota tersimpan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _receiptRow('No. nota', record.noNota),
            _receiptRow('Pelanggan', record.customerNama),
            _receiptRow('Unit', record.unitLabel),
            const Divider(),
            _receiptRow('Total', formatRupiah(record.totalCents)),
            _receiptRow('Dibayar', formatRupiah(detail.totalDibayarCents)),
            _receiptRow('Sisa', formatRupiah(detail.sisaCents)),
            _receiptRow('Status', record.statusBayar),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  Widget _receiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Kasir',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              'Total ${formatRupiah(_total)}',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Pelanggan dan unit',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _customerId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Pelanggan'),
                      items: _customers
                          .map(
                            (customer) => DropdownMenuItem(
                              value: customer.id,
                              child: Text(
                                '${customer.nama} · ${customer.nomorHp}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) async {
                        setState(() {
                          _customerId = value;
                          _unitId = null;
                          _units = [];
                        });
                        if (value != null) {
                          final units =
                              await AppDatabase.instance.listUnits(value);
                          if (mounted) setState(() => _units = units);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _addCustomer,
                    icon: const Icon(Icons.person_add_alt_1),
                    tooltip: 'Pelanggan baru',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _unitId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: _units
                          .map(
                            (unit) => DropdownMenuItem(
                              value: unit.id,
                              child: Text(
                                unit.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => _unitId = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _addUnit,
                    icon: const Icon(Icons.add_road_outlined),
                    tooltip: 'Unit baru',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _keluhan,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Keluhan / keterangan',
                  hintText: 'Contoh: radiator bocor',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Jasa',
          trailing: TextButton.icon(
            onPressed: _addJob,
            icon: const Icon(Icons.add),
            label: const Text('Tambah'),
          ),
          child: _jobs.isEmpty
              ? const Text('Belum ada jasa.')
              : Column(
                  children: [
                    for (var i = 0; i < _jobs.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_jobs[i].deskripsi),
                        subtitle: Text(
                          '${_jobs[i].jumlah} × ${formatRupiah(_jobs[i].hargaCents)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatRupiah(_jobs[i].subtotalCents)),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _jobs.removeAt(i)),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Sparepart',
          trailing: TextButton.icon(
            onPressed: _addPart,
            icon: const Icon(Icons.add),
            label: const Text('Tambah'),
          ),
          child: _parts.isEmpty
              ? const Text('Belum ada part.')
              : Column(
                  children: [
                    for (var i = 0; i < _parts.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_parts[i].nama),
                        subtitle: Text(
                          '${_parts[i].jumlah} × ${formatRupiah(_parts[i].hargaCents)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatRupiah(_parts[i].subtotalCents)),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _parts.removeAt(i)),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Pembayaran',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _diskon,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Diskon (Rp)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _metode,
                      decoration: const InputDecoration(labelText: 'Metode'),
                      items: const [
                        DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
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
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _bayar,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Dibayar (Rp)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () {
                      _bayar.text = formatRupiahPlain(_total);
                      setState(() {});
                    },
                    child: const Text('Bayar penuh'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _summaryRow('Jasa', _biayaJasa),
              _summaryRow('Part', _totalPart),
              _summaryRow('Diskon', -_diskonCents),
              const Divider(),
              _summaryRow('Total', _total, bold: true),
              _summaryRow('Kembalian', _bayarCents > _total
                  ? _bayarCents - _total
                  : 0),
              _summaryRow('Sisa', (_total - _bayarCents).clamp(0, _total).toInt()),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Menyimpan...' : 'Simpan nota'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _summaryRow(String label, int cents, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            formatRupiah(cents),
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
        ],
      ),
    );
  }
}

class _QuickCustomer {
  const _QuickCustomer(this.nama, this.nomorHp, this.alamat);

  final String nama;
  final String nomorHp;
  final String alamat;
}

class _QuickCustomerDialog extends StatefulWidget {
  const _QuickCustomerDialog();

  @override
  State<_QuickCustomerDialog> createState() => _QuickCustomerDialogState();
}

class _QuickCustomerDialogState extends State<_QuickCustomerDialog> {
  final _nama = TextEditingController();
  final _hp = TextEditingController();
  final _alamat = TextEditingController();

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pelanggan baru'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nama,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nama'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _hp,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Nomor HP'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alamat,
            decoration: const InputDecoration(labelText: 'Alamat (opsional)'),
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
            if (_nama.text.trim().isEmpty || _hp.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              _QuickCustomer(
                _nama.text.trim(),
                _hp.text.trim(),
                _alamat.text.trim(),
              ),
            );
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _QuickUnit {
  const _QuickUnit({
    required this.unitType,
    this.nopol,
    this.jenisMobil,
    this.tahunMobil,
  });

  final String unitType;
  final String? nopol;
  final String? jenisMobil;
  final int? tahunMobil;
}

class _QuickUnitDialog extends StatefulWidget {
  const _QuickUnitDialog();

  @override
  State<_QuickUnitDialog> createState() => _QuickUnitDialogState();
}

class _QuickUnitDialogState extends State<_QuickUnitDialog> {
  final _nopol = TextEditingController();
  final _jenis = TextEditingController();
  final _tahun = TextEditingController();
  String _type = 'MOBIL';

  @override
  void dispose() {
    _nopol.dispose();
    _jenis.dispose();
    _tahun.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unit baru'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Jenis unit'),
            items: const [
              DropdownMenuItem(value: 'MOBIL', child: Text('Mobil')),
              DropdownMenuItem(
                value: 'MOTOR_LENGKAP',
                child: Text('Motor lengkap'),
              ),
              DropdownMenuItem(
                value: 'RADIATOR_ONLY',
                child: Text('Radiator saja'),
              ),
              DropdownMenuItem(
                value: 'SPAREPART',
                child: Text('Sparepart'),
              ),
            ],
            onChanged: (value) => setState(() => _type = value ?? 'MOBIL'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nopol,
            decoration: const InputDecoration(labelText: 'Nomor polisi'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _jenis,
            decoration: const InputDecoration(labelText: 'Jenis kendaraan'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tahun,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Tahun'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _QuickUnit(
              unitType: _type,
              nopol: _nopol.text.trim().isEmpty ? null : _nopol.text.trim(),
              jenisMobil:
                  _jenis.text.trim().isEmpty ? null : _jenis.text.trim(),
              tahunMobil: int.tryParse(_tahun.text.trim()),
            ),
          ),
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _JobDialog extends StatefulWidget {
  const _JobDialog({required this.catalog});

  final List<ServiceCatalog> catalog;

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _harga = TextEditingController();
  int? _catalogId;

  @override
  void dispose() {
    _desc.dispose();
    _qty.dispose();
    _harga.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah jasa'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.catalog.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              initialValue: _catalogId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Pilih tarif'),
              items: widget.catalog
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(
                        '${item.nama} · ${formatRupiah(item.hargaCents)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                final item = widget.catalog
                    .where((row) => row.id == value)
                    .firstOrNull;
                setState(() {
                  _catalogId = value;
                  if (item != null) {
                    _desc.text = item.nama;
                    _harga.text = formatRupiahPlain(item.hargaCents);
                  }
                });
              },
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _desc,
            decoration: const InputDecoration(labelText: 'Deskripsi'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Qty'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _harga,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Harga'),
                ),
              ),
            ],
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
            final desc = _desc.text.trim();
            final qty = int.tryParse(_qty.text.trim()) ?? 0;
            if (desc.isEmpty || qty < 1) return;
            Navigator.pop(
              context,
              JobDraft(
                deskripsi: desc,
                jumlah: qty,
                hargaCents: parseRupiahToCents(_harga.text),
              ),
            );
          },
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}

class _PartDialog extends StatefulWidget {
  const _PartDialog({required this.stock});

  final List<StockItem> stock;

  @override
  State<_PartDialog> createState() => _PartDialogState();
}

class _PartDialogState extends State<_PartDialog> {
  final _qty = TextEditingController(text: '1');
  int? _stockId;

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.stock
        .where((item) => item.id == _stockId)
        .firstOrNull;
    return AlertDialog(
      title: const Text('Tambah sparepart'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _stockId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Barang'),
            items: widget.stock
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(
                      '${item.nama} · stok ${item.jumlah}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => _stockId = value),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _qty,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Qty'),
          ),
          if (selected != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Harga jual ${formatRupiah(selected.hargaJualCents)} · '
                'stok ${selected.jumlah}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
            final item = selected;
            final qty = int.tryParse(_qty.text.trim()) ?? 0;
            if (item == null || qty < 1) return;
            if (qty > item.jumlah) return;
            Navigator.pop(
              context,
              PartDraft(
                stockItemId: item.id,
                nama: item.nama,
                jumlah: qty,
                hargaCents: item.hargaJualCents,
                modalCents: item.hargaModalCents,
              ),
            );
          },
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
