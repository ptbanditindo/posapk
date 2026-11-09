import 'package:flutter/material.dart';

import '../../auth/permissions.dart';
import '../../core/quantity.dart';
import '../../data/feature_flags.dart';
import '../../data/license_service.dart';
import '../../data/supplier_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';
import 'purchase_screen.dart';

class SupplierScreen extends StatefulWidget {
  const SupplierScreen({super.key});

  @override
  State<SupplierScreen> createState() => _SupplierScreenState();
}

class _SupplierScreenState extends State<SupplierScreen> {
  List<Map<String, Object?>> _suppliers = [];
  List<Map<String, Object?>> _lowStock = [];
  bool _loading = true;
  bool _premium = false;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final premium = await LicenseService.instance.isPremium();
    await FeatureFlagsService.instance.load();
    final enabled = FeatureFlagsService.instance.supplierHubEnabled;
    final suppliers = await SupplierService.instance.listSuppliers();
    final lowStock = await SupplierService.instance.lowStockItems();
    if (!mounted) return;
    setState(() {
      _premium = premium;
      _enabled = enabled;
      _suppliers = suppliers;
      _lowStock = lowStock;
      _loading = false;
    });
  }

  bool get _canEdit =>
      AppState.instance.isOwner || AppState.instance.can('ubah_supplier');

  Future<void> _openForm([Map<String, Object?>? supplier]) async {
    if (!_canEdit) {      showSnack(context, 'Peran ini tidak boleh mengelola supplier.', error: true);
      return;
    }
    final input = await showDialog<_SupplierInput>(
      context: context,
      builder: (context) => _SupplierDialog(supplier: supplier),
    );
    if (input == null) return;
    try {
      await SupplierService.instance.saveSupplier(
        id: supplier?['id'] as int?,
        nama: input.nama,
        nomorHp: input.nomorHp,
        alamat: input.alamat,
        catatan: input.catatan,
        aktif: input.aktif,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueueSupplier(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Supplier disimpan.');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyimpan: $error', error: true);
      }
    }
  }

  Future<void> _delete(Map<String, Object?> supplier) async {
    if (!_canEdit) {
      showSnack(context, 'Peran ini tidak boleh mengelola supplier.', error: true);
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Hapus supplier',
      message:
          'Hapus "${supplier['nama']}"? Barang tidak lagi dihubungkan ke '
          'supplier ini.',
      confirmLabel: 'Hapus',
    );
    if (!ok) return;
    await SupplierService.instance.deleteSupplier(
      supplier['id'] as int,
      actor: AppState.instance.requireOperator,
      enqueue: (txn, id) =>
          SyncService.instance.enqueueSupplier(id, txn: txn),
    );
    await _load();
    if (mounted) showSnack(context, 'Supplier dihapus.');
  }

  Future<void> _setStatus(Map<String, Object?> row, String status) async {
    if (!_canEdit) {
      showSnack(context, 'Peran ini tidak boleh mengubah status supplier.', error: true);
      return;
    }
    try {
      await SupplierService.instance.setFollowupStatus(
        supplierId: row['supplier_id'] as int,
        stockItemId: row['stock_item_id'] as int,
        status: status,
        catatan: row['catatan'] as String?,
        enqueue: (txn, supplierId, stockItemId) =>
            SyncService.instance.enqueueSupplierFollowup(
          supplierId: supplierId,
          stockItemId: stockItemId,
          txn: txn,
        ),
      );
      await _load();
      if (mounted) showSnack(context, 'Status follow up disimpan.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_premium) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.workspace_premium_outlined,
            title: 'Fitur supplier khusus premium',
            subtitle:
                'Aktifkan lisensi di menu Premium untuk mencatat supplier '
                'dan follow up reseller.',
          ),
        ],
      );
    }
    if (!_enabled) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.local_shipping_outlined,
            title: 'Fitur supplier dimatikan',
            subtitle:
                'Aktifkan kembali melalui Pengaturan › Fitur dan data toko.',
          ),
        ],
      );
    }
    final purchaseEnabled = FeatureFlagsService.instance.purchaseDebtEnabled;
    final followupEnabled =
        FeatureFlagsService.instance.isEnabled(featureFollowup);
    final canSeePurchase = AppState.instance.isOwner ||
        AppState.instance.can(permissionViewPurchase);
    final showPurchase = purchaseEnabled && canSeePurchase;
    final tabs = <Widget>[
      const Tab(text: 'Supplier'),
      if (followupEnabled) const Tab(text: 'Follow up Reseller'),
      if (showPurchase) const Tab(text: 'Pembelian & Utang'),
    ];
    final views = <Widget>[
      _supplierTab(),
      if (followupEnabled) _followupTab(),
      if (showPurchase) const PurchaseDebtTab(),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          TabBar(tabs: tabs),
          Expanded(
            child: TabBarView(children: views),
          ),
        ],
      ),
    );
  }

  Widget _supplierTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_suppliers.length} supplier',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_canEdit)
              FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: const Text('Supplier'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_suppliers.isEmpty)
          const EmptyState(
            icon: Icons.local_shipping_outlined,
            title: 'Belum ada supplier',
            subtitle:
                'Tambahkan supplier lalu kaitkan barang di layar Stok agar '
                'barang menipis bisa ditindaklanjuti.',
          )
        else
          ..._suppliers.map(
            (supplier) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${supplier['nama']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      if ('${supplier['nomor_hp'] ?? ''}'.isNotEmpty)
                        '${supplier['nomor_hp']}',
                      '${supplier['jumlah_barang'] ?? 0} barang',
                      if (supplier['aktif'] != 1) 'nonaktif',
                    ].join(' · '),
                  ),
                  onTap: _canEdit ? () => _openForm(supplier) : null,
                  trailing: _canEdit
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'ubah') _openForm(supplier);
                            if (value == 'hapus') _delete(supplier);
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'ubah', child: Text('Ubah')),
                            PopupMenuItem(value: 'hapus', child: Text('Hapus')),
                          ],
                        )
                      : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _followupTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Barang menipis / habis',
          subtitle:
              'Batas memakai stok minimum barang, atau 3 jika belum diisi.',
          child: _lowStock.isEmpty
              ? const Text('Tidak ada barang supplier yang menipis.')
              : Column(
                  children: _lowStock.map((row) {
                    final status = '${row['status'] ?? 'BELUM'}';
                    final milli = row['jumlah_milli'] as int? ?? 0;
                    final qty = formatQuantity(
                      milli,
                      (row['desimal'] as num?)?.toInt() ?? 0,
                    );
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${row['nama']}'),
                      subtitle: Text(
                        '${row['supplier_nama']} · stok $qty '
                        '${row['satuan'] ?? ''}',
                      ),
                      trailing: _canEdit
                          ? PopupMenuButton<String>(
                              tooltip: 'Ubah status',
                              onSelected: (value) => _setStatus(row, value),
                              itemBuilder: (context) => [
                                for (final entry in supplierStatusLabels.entries)
                                  if (entry.key != 'BELUM')
                                    PopupMenuItem(
                                      value: entry.key,
                                      child: Text(
                                        entry.key == status
                                            ? '${entry.value} (aktif)'
                                            : entry.value,
                                      ),
                                    ),
                              ],
                              child: Chip(
                                label: Text(
                                  supplierStatusLabels[status] ?? status,
                                ),
                              ),
                            )
                          : Chip(
                              label: Text(
                                supplierStatusLabels[status] ?? status,
                              ),
                            ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }
}

class _SupplierInput {
  const _SupplierInput({
    required this.nama,
    required this.aktif,
    this.nomorHp,
    this.alamat,
    this.catatan,
  });

  final String nama;
  final String? nomorHp;
  final String? alamat;
  final String? catatan;
  final bool aktif;
}

class _SupplierDialog extends StatefulWidget {
  const _SupplierDialog({this.supplier});

  final Map<String, Object?>? supplier;

  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  late final TextEditingController _nama;
  late final TextEditingController _hp;
  late final TextEditingController _alamat;
  late final TextEditingController _catatan;
  late bool _aktif;
  String? _error;

  @override
  void initState() {
    super.initState();
    final supplier = widget.supplier;
    _nama = TextEditingController(text: '${supplier?['nama'] ?? ''}');
    _hp = TextEditingController(text: '${supplier?['nomor_hp'] ?? ''}');
    _alamat = TextEditingController(text: '${supplier?['alamat'] ?? ''}');
    _catatan = TextEditingController(text: '${supplier?['catatan'] ?? ''}');
    _aktif = supplier == null || supplier['aktif'] == 1;
  }

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    _catatan.dispose();
    super.dispose();
  }

  void _save() {
    if (_nama.text.trim().length < 2) {
      setState(() => _error = 'Nama supplier minimal 2 karakter.');
      return;
    }
    Navigator.pop(
      context,
      _SupplierInput(
        nama: _nama.text,
        nomorHp: _hp.text,
        alamat: _alamat.text,
        catatan: _catatan.text,
        aktif: _aktif,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.supplier == null ? 'Supplier baru' : 'Ubah supplier',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nama,
              autofocus: widget.supplier == null,
              decoration: const InputDecoration(labelText: 'Nama supplier'),
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
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Alamat'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _catatan,
              decoration: const InputDecoration(labelText: 'Catatan'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Aktif'),
              value: _aktif,
              onChanged: (value) => setState(() => _aktif = value),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
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
          onPressed: _save,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
