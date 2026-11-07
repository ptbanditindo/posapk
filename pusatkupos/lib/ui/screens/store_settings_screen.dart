import 'package:flutter/material.dart';

import '../../data/access_control.dart';
import '../../data/account_service.dart';
import '../../data/store_settings.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

const _transactionLabels = {
  transactionJualSparepart: 'Jual sparepart',
  transactionServisLangsung: 'Servis langsung',
  transactionOrderKerja: 'Order kerja',
  transactionEstimasiSaja: 'Estimasi saja',
  transactionPelunasanOrder: 'Pelunasan order',
};

const _stageLabels = {
  stageNomorOrder: 'Nomor order',
  stageNomorAntrian: 'Nomor antrian',
  stageStatusPengerjaan: 'Status pengerjaan',
  stageEstimasi: 'Estimasi',
  stagePersetujuanPelanggan: 'Persetujuan pelanggan',
};

class StoreSettingsScreen extends StatefulWidget {
  const StoreSettingsScreen({super.key});

  @override
  State<StoreSettingsScreen> createState() => _StoreSettingsScreenState();
}

class _StoreSettingsScreenState extends State<StoreSettingsScreen> {
  StoreSettings? _settings;
  List<Map<String, Object?>> _accounts = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await StoreSettingsService.instance.ensure();
    final accounts = await AccountService.instance.listAccounts();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _accounts = accounts;
    });
  }

  List<Map<String, Object?>> get _activeAccounts =>
      _accounts.where((row) => row['aktif'] == 1).toList();

  void _update(StoreSettings Function(StoreSettings current) change) {
    final current = _settings;
    if (current == null) return;
    setState(() => _settings = change(current));
  }

  StoreSettings _copy({
    Map<String, bool>? types,
    Map<String, bool>? stages,
    bool? simpanEstimasiLepas,
    bool? approvalDiscount,
    bool? vehicleRequired,
    String? approverMode,
    String? approverEmployeeSyncId,
    Map<String, Map<String, bool>>? rolePermissions,
    String? preset,
  }) {
    final current = _settings!;
    return StoreSettings(
      storeId: current.storeId,
      syncId: current.syncId,
      types: types ?? current.types,
      stages: stages ?? current.stages,
      simpanEstimasiLepas:
          simpanEstimasiLepas ?? current.simpanEstimasiLepas,
      approvalDiscount: approvalDiscount ?? current.approvalDiscount,
      vehicleRequired: vehicleRequired ?? current.vehicleRequired,
      approverMode: approverMode ?? current.approverMode,
      approverEmployeeSyncId: approverEmployeeSyncId ??
          (approverMode == null || approverMode == approverEmployee
              ? current.approverEmployeeSyncId
              : null),
      rolePermissions: rolePermissions ?? current.rolePermissions,
      preset: preset ?? current.preset,
      syncHlcWall: current.syncHlcWall,
      syncHlcCounter: current.syncHlcCounter,
    );
  }

  Map<String, Map<String, bool>> _withRole(
    Map<String, Map<String, bool>> source,
    String role,
    String capability,
    bool value,
  ) {
    final next = {
      for (final entry in source.entries)
        entry.key: Map<String, bool>.from(entry.value),
    };
    next.putIfAbsent(role, () => <String, bool>{});
    next[role]![capability] = value;
    return next;
  }

  void _applyPreset(String preset) {
    final current = _settings;
    if (current == null) return;
    final types = {
      for (final type in transactionTypes)
        type: preset == presetOrderLengkap
            ? true
            : preset == presetLayananLangsung
                ? type != transactionOrderKerja
                : current.typeEnabled(type),
    };
    final stages = {
      for (final stage in orderStages)
        stage: preset == presetOrderLengkap
            ? true
            : preset == presetLayananLangsung
                ? stage != stageStatusPengerjaan
                : current.stageEnabled(stage),
    };
    setState(
      () => _settings = _copy(types: types, stages: stages, preset: preset),
    );
  }

  Future<void> _addRole() async {
    final settings = _settings;
    if (settings == null) return;
    final controller = TextEditingController();
    var source = 'KASIR';
    final created = await showDialog<Map<String, String>?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Tambah peran'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nama peran',
                  hintText: 'Contoh: Penanggung Jawab',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: source,
                decoration: const InputDecoration(
                  labelText: 'Salin akses dari',
                ),
                items: settings.roleNames
                    .map(
                      (role) => DropdownMenuItem(
                        value: role,
                        child: Text(roleDisplayName(role)),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => source = value ?? 'KASIR'),
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
                final name = controller.text.trim();
                if (!RegExp(r'^[A-Za-z0-9 _-]{2,32}$').hasMatch(name)) {
                  showSnack(
                    context,
                    'Nama peran 2-32 karakter (huruf, angka, spasi, _ atau -).',
                    error: true,
                  );
                  return;
                }
                final exists = _settings!.roleNames.any(
                  (role) => role.toLowerCase() == name.toLowerCase(),
                );
                if (exists) {
                  showSnack(context, 'Peran itu sudah ada.', error: true);
                  return;
                }
                Navigator.pop(context, {'name': name, 'source': source});
              },
              child: const Text('Tambah'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (created == null) return;
    final name = canonicalRole(created['name']!);
    final sourceRole = canonicalRole(created['source']!);
    final sourceMap = {
      for (final key in allAccessKeys())
        if (_settings!.roleAllows(sourceRole, key)) key: true,
    };
    _update(
      (current) => _copy(
        rolePermissions: {
          ...current.rolePermissions,
          name: sourceMap,
        },
      ),
    );
  }

  Future<void> _removeRole(String role) async {
    if (isBuiltinRole(role)) return;
    final users = _accounts
        .where(
          (row) => canonicalRole('${row['role_base'] ?? ''}') == role,
        )
        .map((row) => '${row['username'] ?? row['nama'] ?? '?'}')
        .toList();
    if (users.isNotEmpty) {
      showSnack(
        context,
        'Peran masih dipakai akun: ${users.join(', ')}. Ubah peran akun itu dulu.',
        error: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus peran ${roleDisplayName(role)}?'),
        content: const Text('Akses peran ini akan dihapus dari pengaturan toko.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _update(
      (current) => _copy(
        rolePermissions: {
          for (final entry in current.rolePermissions.entries)
            if (entry.key != role) entry.key: entry.value,
        },
      ),
    );
  }

  void _resetRole(String role) {
    _update(
      (current) => _copy(
        rolePermissions: {
          for (final entry in current.rolePermissions.entries)
            if (entry.key != role) entry.key: entry.value,
        },
      ),
    );
  }

  Widget _accessChips(
    StoreSettings settings,
    String role,
    Map<String, String> labels,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in labels.entries)
          FilterChip(
            label: Text(entry.value),
            selected: settings.roleAllows(role, entry.key),
            onSelected: (value) => _update(
              (current) => _copy(
                rolePermissions: _withRole(
                  current.rolePermissions,
                  role,
                  entry.key,
                  value,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _roleCard(StoreSettings settings, String role) {
    final builtin = isBuiltinRole(role);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        key: PageStorageKey('role-$role'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(roleDisplayName(role)),
        subtitle: Text(builtin ? 'Peran bawaan' : 'Peran kustom'),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: builtin
                ? TextButton.icon(
                    onPressed: () => _resetRole(role),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Pakai akses bawaan'),
                  )
                : TextButton.icon(
                    onPressed: () => _removeRole(role),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Hapus peran'),
                  ),
          ),
          _group(
            'Menu yang terlihat',
            _accessChips(settings, role, viewAccessLabels),
          ),
          const SizedBox(height: 12),
          _group(
            'Tindakan yang diizinkan',
            _accessChips(settings, role, actionAccessLabels),
          ),
          const SizedBox(height: 12),
          _group(
            'Jenis transaksi',
            _accessChips(settings, role, transactionAccessLabels),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Future<void> _save() async {
    final settings = _settings;
    if (settings == null) return;
    setState(() => _busy = true);
    try {
      await StoreSettingsService.instance.save(
        settings: settings,
        actor: AppState.instance.operator,
        enqueue: (txn, syncId) => SyncService.instance.enqueueStoreSettings(
          syncId,
          txn: txn,
        ),
      );
      AppState.instance.touch();
      if (!mounted) return;
      showSnack(context, 'Aturan transaksi disimpan.');
      await _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final approverCandidates = _activeAccounts.where((row) {
      final role = row['role_base'] as String? ?? 'KASIR';
      return settings.roleAllows(role, 'setujui');
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Aturan transaksi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Preset cepat',
            subtitle: 'Pilih pola lalu sesuaikan bila perlu.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Layanan langsung'),
                  selected: settings.preset == presetLayananLangsung,
                  onSelected: (_) => _applyPreset(presetLayananLangsung),
                ),
                ChoiceChip(
                  label: const Text('Order lengkap'),
                  selected: settings.preset == presetOrderLengkap,
                  onSelected: (_) => _applyPreset(presetOrderLengkap),
                ),
                ChoiceChip(
                  label: const Text('Manual'),
                  selected: settings.preset == presetManual,
                  onSelected: (_) => _applyPreset(presetManual),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Jenis transaksi',
            subtitle: 'Jenis yang dimatikan tidak tampil di kasir.',
            child: Column(
              children: [
                for (final type in transactionTypes)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(_transactionLabels[type] ?? type),
                    value: settings.typeEnabled(type),
                    onChanged: (value) {
                      final types = Map<String, bool>.from(settings.types)
                        ..[type] = value;
                      _update((current) => _copy(
                            types: types,
                            preset: presetManual,
                          ));
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Tahap order kerja',
            subtitle: 'Tahap yang mati dilewati pada order baru.',
            child: Column(
              children: [
                for (final stage in orderStages)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(_stageLabels[stage] ?? stage),
                    value: settings.stageEnabled(stage),
                    onChanged: settings.typeEnabled(transactionOrderKerja)
                        ? (value) {
                            final stages =
                                Map<String, bool>.from(settings.stages)
                                  ..[stage] = value;
                            _update((current) => _copy(
                                  stages: stages,
                                  preset: presetManual,
                                ));
                          }
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Kasir dan persetujuan',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Simpan estimasi terpisah'),
                  subtitle: const Text(
                    'Mati: estimasi hanya dicetak dan tidak disimpan.',
                  ),
                  value: settings.simpanEstimasiLepas,
                  onChanged: (value) => _update(
                    (current) =>
                        _copy(simpanEstimasiLepas: value, preset: presetManual),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Kendaraan wajib untuk servis'),
                  subtitle: const Text(
                    'Mati: kasir boleh membuat nota servis tanpa unit.',
                  ),
                  value: settings.vehicleRequired,
                  onChanged: (value) => _update(
                    (current) => _copy(
                      vehicleRequired: value,
                      preset: presetManual,
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Kasir wajib persetujuan untuk diskon'),
                  subtitle: const Text(
                    'Mati: diskon kasir sampai selisih harga jual dan modal '
                    'langsung dipakai. Hidup: setiap diskon kasir perlu '
                    'persetujuan. Harga tetap tidak boleh di bawah modal.',
                  ),
                  value: settings.approvalDiscount,
                  onChanged: (value) => _update(
                    (current) => _copy(
                      approvalDiscount: value,
                      preset: presetManual,
                    ),
                  ),
                ),
                const Divider(),
                Text(
                  'Yang boleh menyetujui',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                RadioGroup<String>(
                  groupValue: settings.approverMode,
                  onChanged: (value) {
                    if (value == null) return;
                    if (value == approverEmployee &&
                        approverCandidates.isEmpty) {
                      return;
                    }
                    _update((current) => _copy(approverMode: value));
                  },
                  child: Column(
                    children: [
                      const RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: approverOwner,
                        title: Text('Pemilik'),
                        subtitle:
                            Text('Memakai PIN pemilik di perangkat ini.'),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: approverEmployee,
                        enabled: approverCandidates.isNotEmpty,
                        title: const Text('Penanggung jawab'),
                        subtitle: const Text(
                          'Akun karyawan aktif dengan izin menyetujui.',
                        ),
                      ),
                    ],
                  ),
                ),
                if (settings.approverMode == approverEmployee)
                  DropdownButtonFormField<String>(
                    initialValue: approverCandidates.any(
                      (row) => row['sync_id'] == settings.approverEmployeeSyncId,
                    )
                        ? settings.approverEmployeeSyncId
                        : null,
                    decoration:
                        const InputDecoration(labelText: 'Penanggung jawab'),
                    items: approverCandidates
                        .map(
                          (row) => DropdownMenuItem(
                            value: '${row['sync_id']}',
                            child: Text(
                              '${row['nama'] ?? row['username']} · '
                              '${roleDisplayName('${row['role_base'] ?? ''}')}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => _update(
                      (current) => _copy(approverEmployeeSyncId: value),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Peran dan akses',
            subtitle:
                'Peran hanya menandai orang. Atur menu dan tindakan yang boleh '
                'dipakai tiap peran; peran kustom dimulai tanpa akses.',
            trailing: FilledButton.tonalIcon(
              onPressed: _addRole,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Tambah peran'),
            ),
            child: Column(
              children: [
                for (final role in settings.roleNames) _roleCard(settings, role),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_busy ? 'Menyimpan...' : 'Simpan aturan'),
          ),
        ],
      ),
    );
  }
}
