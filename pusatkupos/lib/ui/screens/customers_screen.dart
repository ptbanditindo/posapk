import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/feature_flags.dart';
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

  bool get _canEdit =>
      AppState.instance.isOwner || AppState.instance.can('ubah_pelanggan');

  Future<void> _addCustomer() async {
    if (!_canEdit) {
      showSnack(context, 'Peran ini tidak boleh menambah pelanggan.', error: true);
      return;
    }
    final input = await showDialog<CustomerInput>(
      context: context,
      builder: (_) => _CustomerDialog(
        canSetLimit: AppState.instance.isOwner,
      ),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.addCustomer(
        nama: input.nama,
        nomorHp: input.nomorHp,
        alamat: input.alamat,
        waConsent: input.waConsent,
        doNotContact: input.doNotContact,
        limitKreditCents: input.limitKreditCents,
        enqueue: (txn, id) =>
            SyncService.instance.enqueueCustomer(id, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } on DuplicateCustomerException catch (duplicate) {
      if (!mounted) return;
      final useExisting = await confirmAction(
        context,
        title: 'Pelanggan sudah ada',
        message: '$duplicate. Pakai pelanggan "${duplicate.existingName}"?',
        confirmLabel: 'Pakai yang ada',
      );
      if (!useExisting) return;
      await _openUnits(
        Customer(
          id: duplicate.existingId,
          syncId: '',
          nama: duplicate.existingName,
          nomorHp: '',
        ),
      );
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _editCustomer(Customer customer) async {
    if (!_canEdit) {
      showSnack(context, 'Peran ini tidak boleh mengubah pelanggan.', error: true);
      return;
    }
    final row = await AppDatabase.instance.customerRow(customer.id);
    if (row == null || !mounted) return;
    final input = await showDialog<_CustomerEdit>(
      context: context,
      builder: (_) => _CustomerEditDialog(
        customer: customer,
        row: row,
        canSetLimit: AppState.instance.isOwner,
      ),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.updateCustomer(
        id: customer.id,
        nama: input.nama,
        nomorHp: input.nomorHp,
        alamat: input.alamat,
        waConsent: input.waConsent,
        doNotContact: input.doNotContact,
        limitKreditCents:
            AppState.instance.isOwner ? input.limitKreditCents : null,
        enqueue: (txn, id) =>
            SyncService.instance.enqueueCustomer(id, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _mergeCustomer(Customer source, List<Customer> all) async {
    if (!_canEdit) {
      showSnack(context, 'Peran ini tidak boleh menggabung pelanggan.', error: true);
      return;
    }
    final targets =
        all.where((customer) => customer.id != source.id).toList();
    if (targets.isEmpty) {
      showSnack(context, 'Belum ada pelanggan lain untuk digabung.', error: true);
      return;
    }
    int? targetId = targets.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gabung pelanggan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Unit dan nota milik "${source.nama}" akan dipindahkan ke '
                'pelanggan tujuan, lalu pelanggan asal dihapus.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: targetId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tujuan'),
                items: targets
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
                onChanged: (value) => setDialogState(() => targetId = value),
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
              child: const Text('Gabungkan'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final target = targetId;
    if (target == null) return;
    try {
      await AppDatabase.instance.mergeCustomers(
        sourceId: source.id,
        targetId: target,
        enqueueCustomer: (txn, id) =>
            SyncService.instance.enqueueCustomer(id, txn: txn),
        enqueueUnit: (txn, id) => SyncService.instance.enqueueUnit(id, txn: txn),
        enqueueNote: (txn, id) => SyncService.instance.enqueueNote(id, txn: txn),
      );
      AppState.instance.touch();
      _load();
      if (mounted) showSnack(context, 'Pelanggan digabungkan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menggabung: $error', error: true);
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
              if (_canEdit)
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
              if (snapshot.hasError) {
                return EmptyState(
                  title: 'Gagal memuat pelanggan',
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
                  title: 'Belum ada pelanggan',
                  subtitle: 'Tambahkan pelanggan untuk mulai membuat nota.',
                  icon: Icons.people_outline,
                  action: _canEdit
                      ? FilledButton(
                          onPressed: _addCustomer,
                          child: const Text('Tambah pelanggan'),
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.chevron_right),
                            if (_canEdit)
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') _editCustomer(customer);
                                  if (value == 'merge') {
                                    _mergeCustomer(customer, rows);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Ubah pelanggan'),
                                  ),
                                  PopupMenuItem(
                                    value: 'merge',
                                    child: Text('Gabung pelanggan'),
                                  ),
                                ],
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

  Future<void> _openUnits(Customer customer) async {
    if (!FeatureFlagsService.instance.isEnabled(featureUnitKendaraan)) {
      showSnack(
        context,
        'Fitur unit/kendaraan dinonaktifkan pemilik.',
        error: true,
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _UnitsSheet(customer: customer),
    );
  }
}

class CustomerInput {
  const CustomerInput(
    this.nama,
    this.nomorHp,
    this.alamat, {
    this.waConsent = true,
    this.doNotContact = false,
    this.limitKreditCents = 0,
  });

  final String nama;
  final String nomorHp;
  final String? alamat;
  final bool waConsent;
  final bool doNotContact;
  final int limitKreditCents;
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.canSetLimit = false});

  final bool canSetLimit;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  final _nama = TextEditingController();
  final _hp = TextEditingController();
  final _alamat = TextEditingController();
  final _limit = TextEditingController();
  bool _waConsent = true;
  bool _doNotContact = false;
  String? _error;

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    _limit.dispose();
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
    final limitText = _limit.text.trim();
    final limit = limitText.isEmpty ? 0 : tryParseRupiahToCents(limitText);
    if (limit == null || limit < 0) {
      setState(() => _error = 'Limit kredit tidak valid.');
      return;
    }
    Navigator.pop(
      context,
      CustomerInput(
        _nama.text.trim(),
        _hp.text.trim(),
        _alamat.text.trim().isEmpty ? null : _alamat.text.trim(),
        waConsent: _waConsent,
        doNotContact: _doNotContact,
        limitKreditCents: widget.canSetLimit ? limit : 0,
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
              decoration: const InputDecoration(
                labelText: 'Nama pelanggan',
                hintText: 'Contoh: Budi Santoso',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _hp,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Nomor HP',
                hintText: 'Contoh: 081234567890',
                helperText: 'Dipakai untuk WhatsApp dan follow up.',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _alamat,
              decoration: const InputDecoration(
                labelText: 'Alamat (opsional)',
                hintText: 'Contoh: Jl. Merdeka No. 10, Bandung',
              ),
            ),
            if (widget.canSetLimit) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Limit kredit (Rp)',
                  hintText: 'Contoh: 500000',
                  helperText: 'Batas utang yang boleh berjalan. Isi 0 untuk '
                      'tanpa limit.',
                ),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Setuju dihubungi lewat WhatsApp'),
              value: _waConsent,
              onChanged: (value) => setState(() => _waConsent = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jangan kirim promo atau follow up'),
              value: _doNotContact,
              onChanged: (value) => setState(() => _doNotContact = value),
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
        FilledButton(onPressed: _save, child: const Text('Simpan pelanggan')),
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
    if (!mounted) return;
    setState(() {
      _future = AppDatabase.instance.listUnits(widget.customer.id);
    });
  }

  Future<void> _addUnit() async {
    if (!AppState.instance.isOwner &&
        !AppState.instance.can('ubah_pelanggan')) {
      showSnack(context, 'Peran ini tidak boleh menambah unit.', error: true);
      return;
    }
    final input = await showDialog<UnitInput>(
      context: context,
      builder: (_) => const _UnitDialog(),
    );
    if (input == null) return;
    try {
      await AppDatabase.instance.addUnit(
        customerId: widget.customer.id,
        unitType: input.unitType,
        nopol: input.nopol,
        jenisMobil: input.jenisMobil,
        tahunMobil: input.tahunMobil,
        tipeRadiator: input.tipeRadiator,
        labelRadiator: input.labelRadiator,
        enqueue: (txn, id) => SyncService.instance.enqueueUnit(id, txn: txn),
      );
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyimpan unit: $error', error: true);
      }
    }
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
              if (AppState.instance.isOwner ||
                  AppState.instance.can('ubah_pelanggan'))
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
              if (snapshot.hasError) {
                return EmptyState(
                  title: 'Gagal memuat unit',
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
    this.labelRadiator,
  });

  final String unitType;
  final String? nopol;
  final String? jenisMobil;
  final int? tahunMobil;
  final String? tipeRadiator;
  final String? labelRadiator;
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
  final _labelRadiator = TextEditingController();
  String _type = 'MOBIL';

  @override
  void dispose() {
    _nopol.dispose();
    _jenis.dispose();
    _tahun.dispose();
    _radiator.dispose();
    _labelRadiator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah unit'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Jenis unit',
                helperText: 'Pilih kendaraan atau barang yang diservis.',
              ),
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
              decoration: const InputDecoration(
                labelText: 'Nomor polisi',
                hintText: 'Contoh: B 1234 XYZ',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _jenis,
              decoration: const InputDecoration(
                labelText: 'Jenis kendaraan/barang',
                hintText: 'Contoh: Honda Beat 2020',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tahun,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Tahun',
                hintText: 'Contoh: 2020',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _radiator,
              decoration: const InputDecoration(
                labelText: 'Tipe radiator',
                hintText: 'Contoh: Denso',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _labelRadiator,
              decoration: const InputDecoration(
                labelText: 'Label radiator (opsional)',
                hintText: 'Contoh: Radiator depan',
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
              labelRadiator: _labelRadiator.text.trim().isEmpty
                  ? null
                  : _labelRadiator.text.trim(),
            ),
          ),
          child: const Text('Simpan unit'),
        ),
      ],
    );
  }
}

class _CustomerEdit {
  const _CustomerEdit({
    required this.nama,
    required this.nomorHp,
    required this.alamat,
    required this.waConsent,
    required this.doNotContact,
    required this.limitKreditCents,
  });

  final String nama;
  final String nomorHp;
  final String? alamat;
  final bool waConsent;
  final bool doNotContact;
  final int limitKreditCents;
}

class _CustomerEditDialog extends StatefulWidget {
  const _CustomerEditDialog({
    required this.customer,
    required this.row,
    this.canSetLimit = false,
  });

  final Customer customer;
  final Map<String, Object?> row;
  final bool canSetLimit;

  @override
  State<_CustomerEditDialog> createState() => _CustomerEditDialogState();
}

class _CustomerEditDialogState extends State<_CustomerEditDialog> {
  late final TextEditingController _nama;
  late final TextEditingController _hp;
  late final TextEditingController _alamat;
  late final TextEditingController _limit;
  late bool _waConsent;
  late bool _doNotContact;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: widget.customer.nama);
    _hp = TextEditingController(text: widget.customer.nomorHp);
    _alamat = TextEditingController(text: widget.customer.alamat ?? '');
    final limit = (widget.row['limit_kredit_cents'] as num?)?.toInt() ?? 0;
    _limit = TextEditingController(
      text: limit > 0 ? formatRupiahPlain(limit) : '',
    );
    _waConsent = widget.row['wa_consent'] != 0;
    _doNotContact = widget.row['do_not_contact'] == 1;
  }

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ubah pelanggan'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nama,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nama pelanggan',
                hintText: 'Contoh: Budi Santoso',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _hp,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Nomor HP',
                hintText: 'Contoh: 081234567890',
                helperText: 'Dipakai untuk WhatsApp dan follow up.',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _alamat,
              decoration: const InputDecoration(
                labelText: 'Alamat (opsional)',
                hintText: 'Contoh: Jl. Merdeka No. 10, Bandung',
              ),
            ),
            if (widget.canSetLimit) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Limit kredit (Rp)',
                  hintText: 'Contoh: 500000',
                  helperText: 'Batas utang yang boleh berjalan. Isi 0 untuk '
                      'tanpa limit.',
                ),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Setuju dihubungi lewat WhatsApp'),
              value: _waConsent,
              onChanged: (value) => setState(() => _waConsent = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jangan kirim promo atau follow up'),
              value: _doNotContact,
              onChanged: (value) => setState(() => _doNotContact = value),
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
        FilledButton(
          onPressed: () {
            if (_nama.text.trim().length < 2 || _hp.text.trim().isEmpty) {
              setState(() => _error = 'Nama dan nomor HP wajib diisi.');
              return;
            }
            final limitText = _limit.text.trim();
            final limit =
                limitText.isEmpty ? 0 : tryParseRupiahToCents(limitText);
            if (limit == null || limit < 0) {
              setState(() => _error = 'Limit kredit tidak valid.');
              return;
            }
            Navigator.pop(
              context,
              _CustomerEdit(
                nama: _nama.text.trim(),
                nomorHp: _hp.text.trim(),
                alamat:
                    _alamat.text.trim().isEmpty ? null : _alamat.text.trim(),
                waConsent: _waConsent,
                doNotContact: _doNotContact,
                limitKreditCents: limit,
              ),
            );
          },
          child: const Text('Simpan pelanggan'),
        ),
      ],
    );
  }
}
