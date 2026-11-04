import 'package:flutter/material.dart';

import '../../data/app_database.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isOwner => AppState.instance.operator?.isOwner ?? false;

  Future<void> _load() async {
    final stores = await StoreService.instance.listStores();
    if (!mounted) return;
    setState(() {
      _stores = stores;
      _loading = false;
    });
  }

  Future<void> _switch(StoreRecord store) async {
    if (!_isOwner) {
      showSnack(context, 'Hanya pemilik yang dapat pindah toko.', error: true);
      return;
    }
    if (store.storeId == AppDatabase.instance.activeStoreId) return;
    setState(() => _busy = true);
    try {
      await StoreService.instance.switchStore(store.storeId);
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
    final nama = TextEditingController();
    final alamat = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tambah toko'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nama,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nama toko'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: alamat,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Alamat'),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Tambah toko hanya untuk pelanggan Premium. Berkas toko '
                'baru dibuat terpisah.',
                style: TextStyle(fontSize: 12),
              ),
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
            child: const Text('Buat toko'),
          ),
        ],
      ),
    );
    final text = nama.text;
    final address = alamat.text;
    nama.dispose();
    alamat.dispose();
    if (result != true) return;
    setState(() => _busy = true);
    try {
      await StoreService.instance.createStore(nama: text, alamat: address);
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
      appBar: AppBar(title: const Text('Toko')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: '${_stores.length} toko',
                  subtitle:
                      'Setiap toko memakai berkas database terpisah. Data '
                      'pelanggan, nota, stok, dan kuota tidak bercampur.',
                  child: Column(
                    children: [
                      for (final store in _stores)
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
                                ? store.storeId
                                : '${store.alamat} · ${store.storeId}',
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
