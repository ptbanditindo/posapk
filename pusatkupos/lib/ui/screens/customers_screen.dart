import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _search = TextEditingController();
  Future<List<Customer>>? _future;

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
      _future = AppDatabase.instance.listCustomers(query: _search.text);
    });
  }

  Future<void> _addCustomer() async {
    final input = await showDialog<CustomerInput>(
      context: context,
      builder: (_) => const _CustomerDialog(),
    );
    if (input == null) return;
    try {
      final id = await AppDatabase.instance.addCustomer(
        nama: input.nama,
        nomorHp: input.nomorHp,
        alamat: input.alamat,
      );
      await SyncService.instance.enqueueCustomer(id);
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: 'Cari nama atau nomor HP',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => _load(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _addCustomer,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Tambah'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Customer>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  title: 'Belum ada pelanggan',
                  subtitle: 'Tambahkan pelanggan untuk mulai membuat nota.',
                  icon: Icons.people_outline,
                  action: FilledButton(
                    onPressed: _addCustomer,
                    child: const Text('Tambah pelanggan'),
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
                    final customer = rows[index];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => _openUnits(customer),
                        leading: CircleAvatar(
                          child: Text(
                            customer.nama.isEmpty
                                ? '?'
                                : customer.nama[0].toUpperCase(),
                          ),
                        ),
                        title: Text(customer.nama),
                        subtitle: Text(
                          [
                            if (customer.nomorHp.isNotEmpty) customer.nomorHp,
                            if ((customer.alamat ?? '').trim().isNotEmpty)
                              customer.alamat!,
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
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

  Future<void> _openUnits(Customer customer) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _UnitsSheet(customer: customer),
    );
  }
}

class CustomerInput {
  const CustomerInput(this.nama, this.nomorHp, this.alamat);

  final String nama;
  final String nomorHp;
  final String? alamat;
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog();

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  final _nama = TextEditingController();
  final _hp = TextEditingController();
  final _alamat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    super.dispose();
  }

  void _save() {
    if (_nama.text.trim().length < 2) {
      setState(() => _error = 'Nama minimal 2 karakter.');
      return;
    }
    if (_hp.text.trim().isEmpty) {
      setState(() => _error = 'Nomor HP wajib diisi.');
      return;
    }
    Navigator.pop(
      context,
      CustomerInput(
        _nama.text.trim(),
        _hp.text.trim(),
        _alamat.text.trim().isEmpty ? null : _alamat.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pelanggan baru'),
      content: SingleChildScrollView(
        child: Column(
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

class _UnitsSheet extends StatefulWidget {
  const _UnitsSheet({required this.customer});

  final Customer customer;

  @override
  State<_UnitsSheet> createState() => _UnitsSheetState();
}

class _UnitsSheetState extends State<_UnitsSheet> {
  Future<List<VehicleUnit>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _future = AppDatabase.instance.listUnits(widget.customer.id);
    });
  }

  Future<void> _addUnit() async {
    final input = await showDialog<UnitInput>(
      context: context,
      builder: (_) => const _UnitDialog(),
    );
    if (input == null) return;
    final id = await AppDatabase.instance.addUnit(
      customerId: widget.customer.id,
      unitType: input.unitType,
      nopol: input.nopol,
      jenisMobil: input.jenisMobil,
      tahunMobil: input.tahunMobil,
      tipeRadiator: input.tipeRadiator,
    );
    await SyncService.instance.enqueueUnit(id);
    AppState.instance.touch();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(
            widget.customer.nama,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(widget.customer.nomorHp),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Unit terdaftar',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _addUnit,
                icon: const Icon(Icons.add),
                label: const Text('Unit'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FutureBuilder<List<VehicleUnit>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return const EmptyState(
                  title: 'Belum ada unit',
                  subtitle: 'Tambahkan kendaraan atau barang pelanggan.',
                  icon: Icons.directions_car_outlined,
                );
              }
              return Column(
                children: rows
                    .map(
                      (unit) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.directions_car_outlined),
                          title: Text(unit.displayLabel),
                          subtitle: Text(unitTypeLabel(unit.unitType)),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class UnitInput {
  const UnitInput({
    required this.unitType,
    this.nopol,
    this.jenisMobil,
    this.tahunMobil,
    this.tipeRadiator,
  });

  final String unitType;
  final String? nopol;
  final String? jenisMobil;
  final int? tahunMobil;
  final String? tipeRadiator;
}

class _UnitDialog extends StatefulWidget {
  const _UnitDialog();

  @override
  State<_UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<_UnitDialog> {
  final _nopol = TextEditingController();
  final _jenis = TextEditingController();
  final _tahun = TextEditingController();
  final _radiator = TextEditingController();
  String _type = 'MOBIL';

  @override
  void dispose() {
    _nopol.dispose();
    _jenis.dispose();
    _tahun.dispose();
    _radiator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unit baru'),
      content: SingleChildScrollView(
        child: Column(
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
                  value: 'PART_MOBIL',
                  child: Text('Part mobil'),
                ),
                DropdownMenuItem(
                  value: 'PART_MOTOR',
                  child: Text('Part motor'),
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
              decoration: const InputDecoration(
                labelText: 'Jenis kendaraan/barang',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tahun,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Tahun'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _radiator,
              decoration: const InputDecoration(labelText: 'Tipe radiator'),
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
          onPressed: () => Navigator.pop(
            context,
            UnitInput(
              unitType: _type,
              nopol: _nopol.text.trim().isEmpty ? null : _nopol.text.trim(),
              jenisMobil:
                  _jenis.text.trim().isEmpty ? null : _jenis.text.trim(),
              tahunMobil:
                  int.tryParse(_tahun.text.trim()),
              tipeRadiator:
                  _radiator.text.trim().isEmpty ? null : _radiator.text.trim(),
            ),
          ),
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
