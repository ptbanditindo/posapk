import 'package:flutter/material.dart';

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

const _capabilityLabels = {
  'buat_nota': 'Buat nota',
  'ubah_status': 'Ubah status order',
  'void': 'Batalkan nota',
  'koreksi': 'Koreksi nota',
  'diskon': 'Beri diskon',
  'setujui': 'Menyetujui',
  'ubah_pengaturan': 'Ubah pengaturan',
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
      _accounts = accounts.where((row) => row['aktif'] == 1).toList();
    });
  }

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
    final approverCandidates = _accounts.where((row) {
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
                              '${row['role_base']}',
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
          for (final role in const ['KASIR', 'MEKANIK'])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SectionCard(
                title: 'Izin $role',
                child: Column(
                  children: [
                    for (final entry in _capabilityLabels.entries)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(entry.value),
                        value:
                            settings.roleAllows(role, entry.key),
                        onChanged: (value) => _update(
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
                    const Divider(),
                    for (final type in transactionTypes)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          'Boleh pilih ${_transactionLabels[type] ?? type}',
                        ),
                        value: settings
                            .roleCanSelect(role, type),
                        onChanged: (value) => _update(
                          (current) => _copy(
                            rolePermissions: _withRole(
                              current.rolePermissions,
                              role,
                              'jenis_$type',
                              value,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
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
