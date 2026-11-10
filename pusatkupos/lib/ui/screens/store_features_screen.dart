import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../data/feature_flags.dart';
import '../../data/pin_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

/// Manajemen modul dan fitur opsional per toko. Hanya pemilik dengan PIN
/// valid yang dapat mengubah; data historis tidak dihapus saat fitur mati.
class StoreFeaturesScreen extends StatefulWidget {
  const StoreFeaturesScreen({super.key});

  @override
  State<StoreFeaturesScreen> createState() => _StoreFeaturesScreenState();
}

class _StoreFeaturesScreenState extends State<StoreFeaturesScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, Object?>> _history = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await FeatureFlagsService.instance.load();
    final history = await FeatureFlagsService.instance.history();
    if (mounted) {
      setState(() {
        _history = history;
        _loading = false;
      });
    }
  }

  bool get _isOwner => AppState.instance.operator?.isOwner ?? false;

  Future<String?> _askOwnerPin() async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Konfirmasi pemilik'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Masukkan PIN pemilik untuk mengubah modul toko. Setiap '
                'perubahan dicatat di riwayat fitur.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'PIN pemilik',
                  helperText: 'PIN yang dipakai pemilik saat membuka aplikasi.',
                  errorText: error,
                ),
                onSubmitted: (_) =>
                    Navigator.pop(context, controller.text.trim()),
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
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setLocal(() => error = 'Masukkan PIN pemilik.');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Periksa PIN'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<bool> _confirmChildImpact(StoreFeature feature) async {
    final children = FeatureCatalog.childrenOf(feature.key)
        .where((child) => FeatureFlagsService.instance.isEnabled(child.key))
        .toList();
    if (children.isEmpty) return true;
    final names = children.map((child) => child.label).join(', ');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Matikan fitur induk?'),
        content: Text(
          '${feature.label} adalah induk dari $names yang masih aktif. Jika '
          'induk dimatikan, $names tidak berlaku. Data lama tetap tersimpan '
          'dan bisa dilihat di riwayat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Matikan induk'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _toggle(StoreFeature feature, bool value) async {
    if (!_isOwner) {
      showSnack(
        context,
        'Hanya pemilik yang boleh mengubah fitur toko.',
        error: true,
      );
      return;
    }
    final pin = await _askOwnerPin();
    if (pin == null) return;
    final verification = await PinService.instance.verifyDetailed(pin);
    if (!mounted) return;
    if (verification != PinVerification.ok) {
      showSnack(
        context,
        verification == PinVerification.weakLegacyPin
            ? 'PIN pemilik masih lemah. Ganti ke minimal 6 digit.'
            : 'PIN pemilik tidak valid.',
        error: true,
      );
      return;
    }
    if (!value && !await _confirmChildImpact(feature)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await FeatureFlagsService.instance.setEnabled(
        key: feature.key,
        enabled: value,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, _) => SyncService.instance.enqueueStoreFeature(
          feature.key,
          txn: txn,
        ),
      );
      await AppState.instance.reloadStore();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      showSnack(
        context,
        value
            ? '${feature.label} diaktifkan.'
            : '${feature.label} dinonaktifkan.',
      );
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Fitur gagal diubah: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> _warnings() {
    final flags = FeatureFlagsService.instance;
    return [
      for (final feature in FeatureCatalog.items)
        if (feature.dependsOn != null &&
            flags.isEnabled(feature.key) &&
            !flags.isEnabled(feature.dependsOn!))
          '${feature.label} aktif, tetapi induknya '
              '${FeatureCatalog.definition(feature.dependsOn!)?.label ?? feature.dependsOn} '
              'sedang dimatikan. Fitur ini belum berlaku sampai induknya '
              'diaktifkan.',
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Modul dan fitur toko')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final flags = FeatureFlagsService.instance;
    final warnings = _warnings();
    return Scaffold(
      appBar: AppBar(title: const Text('Modul dan fitur toko')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Fitur opsional',
            subtitle: _isOwner
                ? 'Matikan modul yang tidak dipakai toko ini. Data lama '
                    'tetap tersimpan, tampil di riwayat, dan ikut '
                    'dicadangkan.'
                : 'Hanya pemilik yang bisa mengubah saklar fitur.',
            child: Column(
              children: [
                for (final feature in FeatureCatalog.items)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: flags.isEnabled(feature.key),
                    onChanged: _busy || !_isOwner
                        ? null
                        : (value) => _toggle(feature, value),
                    title: Row(
                      children: [
                        Expanded(child: Text(feature.label)),
                        Text(
                          flags.isEnabled(feature.key) ? 'Aktif' : 'Nonaktif',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                    subtitle: Text(
                      [
                        feature.description,
                        if (feature.dependsOn != null)
                          'Butuh induk: '
                              '${FeatureCatalog.definition(feature.dependsOn!)?.label ?? feature.dependsOn}.',
                        if (!feature.optional)
                          'Selalu aktif dan tidak bisa dimatikan.',
                        if (feature.dependsOn != null &&
                            !flags.isEnabled(feature.dependsOn!))
                          'Induknya belum aktif, jadi fitur ini belum '
                              'berlaku.',
                      ].join(' '),
                    ),
                  ),
              ],
            ),
          ),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Perlu diperiksa',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final warning in warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(warning),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          SectionCard(
            title: 'Riwayat perubahan',
            subtitle: 'Setiap perubahan memakai PIN pemilik dan tercatat di '
                'sini.',
            child: _history.isEmpty
                ? Text(
                    'Belum ada perubahan fitur.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : Column(
                    children: [
                      for (final row in _history)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${FeatureCatalog.definition('${row['feature_key']}')?.label ?? row['feature_key']} '
                            '${row['after_enabled'] == 1 ? 'diaktifkan' : 'dinonaktifkan'}',
                          ),
                          subtitle: Text(
                            '${row['actor'] ?? '-'} · '
                            '${dateTimeId.format(localTime(row['created_at']))}',
                          ),
                          dense: true,
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Catatan',
            child: Text(
              'Fitur dasar selalu aktif: kasir, stok, pelanggan, pembayaran, '
              'retur, laporan, cadangan, akun, sinkronisasi, lisensi, dan '
              'pengaturan. Perubahan fitur opsional ikut tersinkron dan '
              'tercatat di riwayat.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
