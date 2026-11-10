import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/feature_flags.dart';
import '../../data/license_service.dart';
import '../../data/store_registry.dart';
import '../../data/store_service.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

class StoresScreen extends StatefulWidget {
  const StoresScreen({super.key});

  @override
  State<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends State<StoresScreen> {
  List<StoreRecord> _stores = const [];
  bool _loading = true;
  bool _busy = false;
  bool _premium = false;
  bool _googleLinked = false;
  int _storeLimit = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isOwner => AppState.instance.operator?.isOwner ?? false;

  Set<String> get _allowedStoreIds {
    if (_isOwner) return <String>{};
    return (AppState.instance.operator?.storeIds ?? const <String>[]).toSet();
  }

  List<StoreRecord> get _visibleStores {
    if (_isOwner) return _stores;
    final allowed = _allowedStoreIds;
    return _stores.where((store) => allowed.contains(store.storeId)).toList();
  }

  Future<void> _load() async {
    final stores = await StoreService.instance.listStores();
    final status = _isOwner ? await LicenseService.instance.status() : null;
    final provider = await AppDatabase.instance.getSetting('license.provider');
    if (!mounted) return;
    setState(() {
      _stores = stores;
      _premium = status?['premium'] == true;
      _googleLinked = (provider ?? '') == 'google';
      _storeLimit = (status?['store_limit'] as num?)?.toInt() ?? 1;
      _loading = false;
    });
  }

  Future<void> _switch(StoreRecord store) async {
    if (!_isOwner && !_allowedStoreIds.contains(store.storeId)) {
      showSnack(
        context,
        'Akun Anda tidak punya akses ke toko ini. Minta pemilik menugaskan.',
        error: true,
      );
      return;
    }
    if (store.storeId == AppDatabase.instance.activeStoreId) return;
    setState(() => _busy = true);
    try {
      await StoreService.instance.switchStore(
        store.storeId,
        allowedStoreIds: _isOwner ? null : _allowedStoreIds,
      );
      await AppState.instance.reloadStore();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      showSnack(context, 'Toko aktif: ${store.nama}.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addStore() async {
    if (!_premium) {
      showSnack(
        context,
        'Akun gratis hanya memakai 1 toko. Menambah toko memerlukan '
        'Premium dan login Google pemilik.',
        error: true,
      );
      return;
    }
    if (!_googleLinked) {
      showSnack(
        context,
        'Masuk dengan Google di menu Premium untuk menambah toko.',
        error: true,
      );
      return;
    }
    final nama = TextEditingController();
    final alamat = TextEditingController();
    final features = {
      for (final feature in storeFeatureCatalog)
        feature.key: feature.defaultEnabled,
    };
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Tambah toko'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nama,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Nama toko',
                      hintText: 'Contoh: Bengkel Jaya Motor Cabang Dago',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: alamat,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Alamat',
                      hintText: 'Contoh: Jl. Dago No. 21, Bandung',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _premium
                          ? 'Premium dihitung per toko. Kuota Anda $_storeLimit '
                              'toko dan saat ini terpakai ${_stores.length}.'
                          : 'Akun gratis hanya memakai 1 toko. Toko tambahan '
                              'memerlukan Premium dan login Google pemilik.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const Divider(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Fitur opsional'),
                  ),
                  for (final feature in storeFeatureCatalog)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(feature.label),
                      value: features[feature.key] ?? feature.defaultEnabled,
                      onChanged: (value) => setLocal(
                        () => features[feature.key] = value,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Buat toko'),
            ),
          ],
        ),
      ),
    );
    final text = nama.text;
    final address = alamat.text;
    nama.dispose();
    alamat.dispose();
    if (result != true) return;
    setState(() => _busy = true);
    try {
      await StoreService.instance.createStore(
        nama: text,
        alamat: address,
        features: features,
      );
      await _load();
      if (!mounted) return;
      showSnack(context, 'Toko baru dibuat.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daftar toko')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: '${_visibleStores.length} toko',
                  subtitle: _isOwner
                      ? 'Setiap toko memakai berkas database terpisah. Data '
                          'pelanggan, nota, stok, dan kuota tidak bercampur.'
                          '${_premium ? ' Kuota $_storeLimit toko.' : ' Akun gratis: 1 toko.'}'
                          '${_premium && !_googleLinked ? ' Login Google diperlukan untuk menambah toko.' : ''}'
                      : 'Hanya toko yang ditugaskan untuk akun Anda.',
                  child: Column(
                    children: [
                      if (_visibleStores.isEmpty)
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Belum ada toko untuk akun ini.'),
                        ),
                      for (final store in _visibleStores)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            store.storeId ==
                                    AppDatabase.instance.activeStoreId
                                ? Icons.radio_button_checked
                                : Icons.storefront_outlined,
                            color: store.storeId ==
                                    AppDatabase.instance.activeStoreId
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(store.nama),
                          subtitle: Text(
                            store.alamat.isEmpty
                                ? 'Alamat belum diisi'
                                : store.alamat,
                          ),
                          trailing: store.storeId ==
                                  AppDatabase.instance.activeStoreId
                              ? const Chip(label: Text('Aktif'))
                              : const Icon(Icons.chevron_right),
                          onTap: _busy ? null : () => _switch(store),
                        ),
                    ],
                  ),
                ),
                if (_isOwner) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _addStore,
                    icon: const Icon(Icons.add_business_outlined),
                    label: const Text('Tambah toko'),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
    );
  }
}
