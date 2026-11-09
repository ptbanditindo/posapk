import 'package:flutter/material.dart';

import '../../data/feature_flags.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

/// Saklar fitur opsional per toko (BD-26). Hanya pemilik penuh yang dapat
/// mengubah; data historis tidak dihapus saat fitur dimatikan.
class StoreFeaturesScreen extends StatefulWidget {
  const StoreFeaturesScreen({super.key});

  @override
  State<StoreFeaturesScreen> createState() => _StoreFeaturesScreenState();
}

class _StoreFeaturesScreenState extends State<StoreFeaturesScreen> {
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await FeatureFlagsService.instance.load();
    if (mounted) setState(() => _loading = false);
  }

  bool get _isOwner => AppState.instance.operator?.isOwner ?? false;

  Future<void> _toggle(StoreFeature feature, bool value) async {
    if (!_isOwner) {
      showSnack(
        context,
        'Hanya pemilik yang boleh mengubah fitur toko.',
        error: true,
      );
      return;
    }
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
      setState(() {});
      showSnack(
        context,
        value
            ? '${feature.label} diaktifkan.'
            : '${feature.label} dinonaktifkan.',
      );
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Fitur Toko')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final flags = FeatureFlagsService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Fitur Toko')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Fitur opsional',
            subtitle: _isOwner
                ? 'Nonaktifkan modul yang tidak dipakai toko ini. Data lama '
                    'tetap tersimpan, tampil di riwayat, dan ikut backup.'
                : 'Hanya pemilik yang dapat mengubah saklar fitur.',
            child: Column(
              children: [
                for (final feature in storeFeatureCatalog)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: flags.isEnabled(feature.key),
                    onChanged: _busy || !_isOwner
                        ? null
                        : (value) => _toggle(feature, value),
                    title: Text(feature.label),
                    subtitle: Text(
                      [
                        feature.description,
                        if (feature.dependsOn != null &&
                            !flags.isEnabled(feature.dependsOn!))
                          'Butuh induk aktif untuk berlaku.',
                      ].join(' '),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Catatan',
            child: Text(
              'Fitur wajib seperti kasir, stok, pelanggan, pembayaran, '
              'retur, laporan, backup, akun, sinkronisasi, lisensi, dan '
              'pengaturan selalu aktif. Perubahan disinkronkan dan dicatat '
              'di audit bisnis.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
