import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pusatkupos/core/dates.dart';
import 'package:pusatkupos/core/money.dart';
import 'package:pusatkupos/data/account_service.dart';
import 'package:pusatkupos/data/app_database.dart';
import 'package:pusatkupos/data/device_service.dart';
import 'package:pusatkupos/data/models.dart';
import 'package:pusatkupos/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'owner_api.dart';
import 'summary_file_stub.dart'
    if (dart.library.io) 'summary_file_io.dart'
    if (dart.library.html) 'summary_file_web.dart';

const _summaryKey = 'owner.summary.signed';
const _relayKey = 'owner.relay_url';
const _tokenKey = 'owner.enroll_token';
const _storeKey = 'owner.store_id';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.init();
  runApp(const OwnerApp());
}

class OwnerApp extends StatelessWidget {
  const OwnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PusatkuPOS Owner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF155E75)),
        scaffoldBackgroundColor: const Color(0xFFF4F7FA),
      ),
      home: const OwnerHome(),
    );
  }
}

class OwnerSummary {
  const OwnerSummary({
    required this.payload,
    required this.signature,
    required this.publicKey,
  });

  final Map<String, Object?> payload;
  final String signature;
  final String publicKey;
}

class OwnerHome extends StatefulWidget {
  const OwnerHome({super.key});

  @override
  State<OwnerHome> createState() => _OwnerHomeState();
}

class _OwnerHomeState extends State<OwnerHome>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 6, vsync: this);
  final _relayUrl = TextEditingController();
  final _enrollToken = TextEditingController();
  final _storeId = TextEditingController(text: 'utama');
  final _search = TextEditingController();
  final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  OwnerSummary? _summary;
  String? _error;
  bool _busy = false;
  bool _connected = false;
  bool _keyReady = false;
  Map<String, Object?>? _syncStatus;

  DashboardData? _dashboard;
  List<ServiceRecordSummary> _records = [];
  List<StockItem> _stock = [];
  List<Customer> _customers = [];
  ReportSummary? _reportAll;
  ReportSummary? _reportToday;

  List<Map<String, Object?>> _accounts = [];
  List<Map<String, Object?>> _devices = [];
  List<Map<String, Object?>> _invites = [];

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (_tabs.index == 4) _refreshAccess();
    });
    _bootstrap();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _relayUrl.dispose();
    _enrollToken.dispose();
    _storeId.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    _relayUrl.text = prefs.getString(_relayKey) ?? 'http://127.0.0.1:8120';
    _enrollToken.text = prefs.getString(_tokenKey) ?? '';
    _storeId.text = prefs.getString(_storeKey) ?? 'utama';
    final cached = prefs.getString(_summaryKey);
    if (cached != null) {
      await _parseSummary(cached, persist: false);
    } else {
      await _loadLocal();
    }
    await _refreshConnectionState();
  }

  Future<void> _refreshConnectionState() async {
    final device = await DeviceService.instance.currentDevice();
    final relayId = await SyncService.instance.relayDeviceId();
    final key = await SyncService.instance.existingStoreKey();
    if (!mounted) return;
    setState(() {
      _connected = device != null && relayId != null && relayId.isNotEmpty;
      _keyReady = key != null;
    });
  }

  Future<void> _pickSummary() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pilih ringkasan owner',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;
    final raw = await readSummaryFile(file);
    await _parseSummary(raw, persist: true);
  }

  Future<void> _parseSummary(String raw, {required bool persist}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final payload = Map<String, Object?>.from(data['payload'] as Map);
      final signature = data['signature'] as String? ?? '';
      final publicKey = data['public_key'] as String? ?? '';
      if (signature.isEmpty || publicKey.isEmpty) {
        throw const FormatException('Tanda tangan ringkasan tidak ada.');
      }
      final verified = await Ed25519().verify(
        utf8.encode(_canonical(payload)),
        signature: Signature(
          base64Url.decode(signature),
          publicKey: SimplePublicKey(
            base64Url.decode(publicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!verified) {
        throw const FormatException('Tanda tangan ringkasan tidak valid.');
      }
      await _seedOwner(payload, publicKey);
      if (persist) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_summaryKey, raw);
      }
      if (!mounted) return;
      setState(() {
        _summary = OwnerSummary(
          payload: payload,
          signature: signature,
          publicKey: publicKey,
        );
        final stores = payload['stores'] as List? ?? const [];
        if (_storeId.text == 'utama' && stores.isNotEmpty) {
          final first = stores.first;
          if (first is Map && (first['store_id'] as String? ?? '').isNotEmpty) {
            _storeId.text = first['store_id'] as String;
          }
        }
      });
      await _loadLocal();
      await _refreshAccess();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seedOwner(Map<String, Object?> payload, String publicKey) async {
    final db = AppDatabase.instance.db;
    await db.delete('owner_identity');
    await db.insert('owner_identity', {
      'id': 1,
      'owner_id': payload['owner_id'],
      'public_key': publicKey,
      'created_at': nowIso(),
    });
    await db.delete('license');
    await db.insert('license', {
      'id': 1,
      'plan': payload['plan'] ?? 'premium',
      'period_end': payload['period_end'],
      'device_limit': payload['device_limit'] ?? 1,
      'provider': 'summary',
      'token': null,
      'activated_at': nowIso(),
    });
  }

  Future<void> _saveRelaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_relayKey, _relayUrl.text.trim());
    await prefs.setString(_tokenKey, _enrollToken.text.trim());
    await prefs.setString(_storeKey, _storeId.text.trim());
    await SyncService.instance.configure(
      relayUrl: _relayUrl.text,
      enrollToken: _enrollToken.text,
      storeId: _storeId.text,
    );
    await _refreshAccess();
    if (mounted) _snack('Pengaturan relay disimpan.');
  }

  Future<void> _connectViewer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _saveRelaySettings();
      final device = await DeviceService.instance.currentDevice();
      final relayId = await SyncService.instance.relayDeviceId();
      if (device == null || relayId == null || relayId.isEmpty) {
        final result = await SyncService.instance.registerRelayDevice(
          nama: 'Owner Viewer',
          viewer: true,
        );
        if (mounted) {
          _snack(
            result['key_pending'] == true
                ? 'Perangkat owner terdaftar. Minta perangkat toko mengirim kunci.'
                : 'Perangkat owner terhubung.',
          );
        }
      } else {
        await SyncService.instance.refreshStoreKey();
      }
      await _refreshConnectionState();
      await _loadLocal();
      await _refreshAccess();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await SyncService.instance.syncNow();
      _syncStatus = await SyncService.instance.status();
      await _refreshConnectionState();
      await _loadLocal();
      if (mounted) {
        _snack(
          result['snapshot_applied'] == true
              ? 'Snapshot diterapkan sampai urutan ${result['cursor']}.'
              : 'Sinkron: ${result['applied']} diterapkan.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeSnapshot() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await SyncService.instance.bootstrapNow();
      await _refreshConnectionState();
      await _loadLocal();
      if (mounted) {
        _snack(
          result['applied'] == true
              ? 'Snapshot diterapkan sampai urutan ${result['cursor']}.'
              : 'Belum ada snapshot yang dapat diterapkan.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadSnapshot() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await SyncService.instance.uploadSnapshot();
      if (mounted) {
        _snack('Snapshot cadangan diunggah sampai urutan ${result['store_seq']}.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadLocal() async {
    final db = AppDatabase.instance;
    final today = DateTime.now();
    final records = await db.listRecords(
      query: _search.text,
      limit: 200,
    );
    final dashboard = await db.dashboard();
    final stock = await db.listStock();
    final customers = await db.listCustomers();
    final all = await db.reportSummary(DateTime(2000), DateTime(2100));
    final day = await db.reportSummary(today, today);
    final status = await SyncService.instance.status();
    if (!mounted) return;
    setState(() {
      _records = records;
      _dashboard = dashboard;
      _stock = stock;
      _customers = customers;
      _reportAll = all;
      _reportToday = day;
      _syncStatus = status;
    });
  }

  OwnerApi? get _api {
    final summary = _summary;
    if (summary == null || _enrollToken.text.trim().isEmpty) return null;
    return OwnerApi(
      baseUrl: _relayUrl.text,
      enrollToken: _enrollToken.text.trim(),
      ownerId: '${summary.payload['owner_id']}',
    );
  }

  Future<void> _refreshAccess() async {
    final api = _api;
    if (api == null) {
      if (mounted) {
        setState(() {
          _accounts = [];
          _devices = [];
          _invites = [];
        });
      }
      return;
    }
    try {
      final accounts = await api.accounts();
      final devices = await api.devices();
      final invites = await api.invites();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _devices = devices;
        _invites = invites;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  List<Map<String, String>> get _summaryStores {
    final stores = _summary?.payload['stores'] as List? ?? const [];
    final result = <Map<String, String>>[];
    for (final item in stores) {
      if (item is Map) {
        result.add({
          'store_id': '${item['store_id'] ?? 'utama'}',
          'nama': '${item['nama'] ?? item['store_id'] ?? 'Toko'}',
        });
      }
    }
    if (result.isEmpty) {
      result.add({'store_id': 'utama', 'nama': 'Toko utama'});
    }
    return result;
  }

  Future<void> _editAccount([Map<String, Object?>? account]) async {
    final username = TextEditingController(text: '${account?['username'] ?? ''}');
    final nama = TextEditingController(text: '${account?['nama'] ?? ''}');
    final password = TextEditingController();
    var role = '${account?['role_base'] ?? 'KASIR'}';
    var aktif = account?['aktif'] != false;
    final permissions = <String>{
      ...((account?['extra_permissions'] as List?) ?? const []).map((e) => '$e'),
    };
    final stores = <String>{
      ...((account?['store_ids'] as List?) ?? const []).map((e) => '$e'),
    };
    if (stores.isEmpty) stores.add(_storeId.text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(account == null ? 'Akun karyawan baru' : 'Ubah akun'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: username,
                  enabled: account == null,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nama,
                  decoration: const InputDecoration(labelText: 'Nama'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: roles.contains(role) ? role : 'KASIR',
                  decoration: const InputDecoration(labelText: 'Peran'),
                  items: roles
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(roleLabels[item] ?? item),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => role = value ?? 'KASIR'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: account == null
                        ? 'Password awal'
                        : 'Password baru (kosongkan jika tetap)',
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Aktif'),
                  value: aktif,
                  onChanged: (value) => setDialogState(() => aktif = value),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Izin tambahan',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: permissionLabels.entries
                      .map(
                        (entry) => FilterChip(
                          label: Text(entry.value),
                          selected: permissions.contains(entry.key),
                          onSelected: (selected) => setDialogState(() {
                            if (selected) {
                              permissions.add(entry.key);
                            } else {
                              permissions.remove(entry.key);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Toko',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: _summaryStores
                      .map(
                        (store) => FilterChip(
                          label: Text(store['nama']!),
                          selected: stores.contains(store['store_id']),
                          onSelected: (selected) => setDialogState(() {
                            if (selected) {
                              stores.add(store['store_id']!);
                            } else {
                              stores.remove(store['store_id']);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () async {
                final api = _api;
                if (api == null) return;
                try {
                  final temp = password.text.trim();
                  await api.saveAccount(
                    syncId: account?['sync_id'] as String?,
                    username: username.text,
                    nama: nama.text,
                    role: role,
                    permissions: permissions.toList(),
                    stores: stores.toList(),
                    password: temp.isEmpty ? null : temp,
                    aktif: aktif,
                    permissionVersion:
                        (account?['permission_version'] as num?)?.toInt() ?? 0,
                  );
                  if (context.mounted) Navigator.pop(context, true);
                  if (temp.isNotEmpty && mounted) {
                    _snack('Password awal: $temp');
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$error')),
                    );
                  }
                }
              },
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    username.dispose();
    nama.dispose();
    password.dispose();
    if (saved == true) await _refreshAccess();
  }

  Future<void> _createInvite(Map<String, Object?> account) async {
    final api = _api;
    if (api == null) return;
    final stores = ((account['store_ids'] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    if (stores.isEmpty) {
      _snack('Akun belum punya toko.', error: true);
      return;
    }
    final storeId = stores.first;
    try {
      final result = await api.createInvite(
        accountSyncId: '${account['sync_id']}',
        storeId: storeId,
      );
      await _refreshAccess();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Kode undangan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                '${result['code']}',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text('Berlaku sampai ${result['expires_at']}'),
              const SizedBox(height: 8),
              const Text(
                'Buka aplikasi PusatkuPOS di HP karyawan, pilih '
                'Hubungkan perangkat karyawan, lalu masukkan kode ini.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: '${result['code']}'),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Salin'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _snack('$error', error: true);
    }
  }

  Future<void> _revokeDevice(Map<String, Object?> device) async {
    final api = _api;
    if (api == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cabut perangkat'),
        content: Text('Cabut ${device['nama']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cabut'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.revokeDevice('${device['id']}');
      await _refreshAccess();
    } catch (error) {
      if (mounted) _snack('$error', error: true);
    }
  }

  String _canonical(Object? value) {
    Object? sort(Object? item) {
      if (item is Map) {
        final keys = item.keys.map((key) => '$key').toList()..sort();
        return {for (final key in keys) key: sort(item[key])};
      }
      if (item is List) return item.map(sort).toList();
      return item;
    }

    return jsonEncode(sort(value));
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'PusatkuPOS Owner',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              onPressed: _pickSummary,
              icon: const Icon(Icons.file_open_outlined),
              tooltip: 'Muat ringkasan owner',
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Ringkasan'),
            Tab(text: 'Riwayat'),
            Tab(text: 'Laporan'),
            Tab(text: 'Data & Backup'),
            Tab(text: 'Akses'),
            Tab(text: 'Pengaturan'),
          ],
        ),
      ),
      body: summary == null
          ? _emptySummary()
          : TabBarView(
              controller: _tabs,
              children: [
                _dashboardTab(),
                _historyTab(),
                _reportTab(),
                _dataTab(),
                _accessTab(),
                _settingsTab(),
              ],
            ),
    );
  }

  Widget _emptySummary() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.verified_user_outlined, size: 56),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            'Impor ringkasan owner yang diekspor dari aplikasi utama.',
            textAlign: TextAlign.center,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _pickSummary,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Muat ringkasan owner'),
        ),
      ],
    );
  }

  Widget _dashboardTab() {
    final dashboard = _dashboard;
    if (dashboard == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: _metric('Pendapatan hari ini', dashboard.todayRevenueCents),
            ),
            const SizedBox(width: 10),
            Expanded(child: _metric('Transaksi', dashboard.todayCount, money: false)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _metric('Piutang', dashboard.receivableCents)),
            const SizedBox(width: 10),
            Expanded(
              child: _metric('Stok menipis', dashboard.lowStockCount, money: false),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          'Nota terbaru',
          Column(
            children: dashboard.recent
                .map(
                  (row) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(row.customerNama.isEmpty ? row.noNota : row.customerNama),
                    subtitle: Text('${row.noNota} · ${_dateFormat.format(row.waktu)}'),
                    trailing: Text(
                      formatRupiah(row.totalCents),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Aplikasi Owner hanya membaca data. Transaksi dilakukan di aplikasi utama.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _metric(String label, int value, {bool money = true}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(
              money ? formatRupiah(value) : '$value',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Cari nota atau pelanggan',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _loadLocal,
                icon: const Icon(Icons.refresh),
              ),
            ),
            onChanged: (_) => _loadLocal(),
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? const Center(child: Text('Belum ada data. Sinkronkan perangkat.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final row = _records[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _showRecord(row.id),
                        title: Text(row.customerNama.isEmpty ? row.noNota : row.customerNama),
                        subtitle: Text(
                          '${row.noNota} · ${_dateFormat.format(row.waktu)}\n${row.unitLabel}',
                        ),
                        isThreeLine: true,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(formatRupiah(row.totalCents)),
                            Text(row.isVoid ? 'VOID' : row.statusBayar),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showRecord(int id) async {
    final detail = await AppDatabase.instance.recordDetail(id);
    if (detail == null || !mounted) return;
    final record = detail.record;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(record.noNota),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row('Pelanggan', record.customerNama),
              _row('Unit', record.unitLabel),
              _row('Waktu', _dateFormat.format(record.waktu)),
              _row('Status', record.isVoid ? 'VOID' : record.statusBayar),
              const Divider(),
              _row('Jasa', formatRupiah(record.biayaJasaCents)),
              _row('Part', formatRupiah(record.totalPartCents)),
              _row('Diskon', '-${formatRupiah(record.diskonCents)}'),
              _row('Total', formatRupiah(record.totalCents)),
              _row('Dibayar', formatRupiah(detail.totalDibayarCents)),
              _row('Sisa', formatRupiah(detail.sisaCents)),
              if (record.keluhan.isNotEmpty) ...[
                const Divider(),
                Text(record.keluhan),
              ],
            ],
          ),
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

  Widget _reportTab() {
    final all = _reportAll;
    final today = _reportToday;
    if (all == null || today == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          'Hari ini',
          Column(
            children: [
              _row('Transaksi', '${today.transaksi}'),
              _row('Total', formatRupiah(today.totalCents)),
              _row('Dibayar', formatRupiah(today.dibayarCents)),
              _row('Piutang', formatRupiah(today.piutangCents)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Semua data',
          Column(
            children: [
              _row('Transaksi', '${all.transaksi}'),
              _row('Jasa', formatRupiah(all.totalJasaCents)),
              _row('Part', formatRupiah(all.totalPartCents)),
              _row('Diskon', formatRupiah(all.diskonCents)),
              _row('Total', formatRupiah(all.totalCents)),
              _row('Dibayar', formatRupiah(all.dibayarCents)),
              _row('Piutang', formatRupiah(all.piutangCents)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Data lain',
          Column(
            children: [
              _row('Pelanggan', '${_customers.length}'),
              _row('Item stok', '${_stock.length}'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dataTab() {
    final status = _syncStatus;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          'Status sinkronisasi',
          Column(
            children: [
              _row('Perangkat', _connected ? 'terhubung' : 'belum terhubung'),
              _row('Kunci toko', _keyReady ? 'tersedia' : 'menunggu dari toko'),
              _row('Kursor', '${status?['cursor'] ?? 0}'),
              _row('Antrean', '${status?['pending'] ?? 0}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: const Text('Sinkronkan'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _takeSnapshot,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Ambil snapshot'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _uploadSnapshot,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Unggah snapshot'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          'Backup',
          const Text(
            'Unggah snapshot menyimpan salinan lengkap semua data ke relay. '
            'Perangkat toko baru dapat memulihkannya lewat Ambil snapshot.',
          ),
        ),
      ],
    );
  }

  Widget _accessTab() {
    if (_api == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Isi alamat relay dan token pendaftaran di Pengaturan untuk mengelola akses.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Akun karyawan',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: _refreshAccess,
              icon: const Icon(Icons.refresh),
              tooltip: 'Muat ulang akses',
            ),
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              onPressed: () => _editAccount(),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Akun'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_accounts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Belum ada akun. Tambahkan akun untuk membuka akses karyawan.'),
            ),
          )
        else
          ..._accounts.map(
            (account) => Card(
              child: ListTile(
                title: Text('${account['nama']} (${account['username']})'),
                subtitle: Text(
                  '${account['role_base']} · '
                  '${(account['store_ids'] as List? ?? const []).join(', ')} · '
                  '${account['aktif'] == false ? 'nonaktif' : 'aktif'}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      onPressed: () => _createInvite(account),
                      icon: const Icon(Icons.qr_code_2),
                      tooltip: 'Buat kode undangan',
                    ),
                    IconButton(
                      onPressed: () => _editAccount(account),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Ubah akun',
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 18),
        const Text(
          'Perangkat terdaftar',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        ..._devices.map(
          (device) => Card(
            child: ListTile(
              leading: Icon(
                device['kind'] == 'owner'
                    ? Icons.phone_android_outlined
                    : Icons.badge_outlined,
              ),
              title: Text('${device['nama']}'),
              subtitle: Text(
                '${device['kind']} · ${device['id']}\n'
                '${device['revoked_at'] == null || '${device['revoked_at']}'.isEmpty ? 'aktif' : 'dicabut'}'
                '${device['kind'] == 'employee' ? ' · kunci ${device['has_key'] == true ? 'ada' : 'belum'}' : ''}',
              ),
              isThreeLine: true,
              trailing: device['revoked_at'] == null ||
                      '${device['revoked_at']}'.isEmpty
                  ? TextButton(
                      onPressed: () => _revokeDevice(device),
                      child: const Text('Cabut'),
                    )
                  : null,
            ),
          ),
        ),
        if (_invites.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text(
            'Undangan',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ..._invites.take(10).map(
                (invite) => Card(
                  child: ListTile(
                    title: Text('${invite['username']} · ${invite['store_id']}'),
                    subtitle: Text(
                      '${invite['claimed_at'] == null || '${invite['claimed_at']}'.isEmpty ? 'belum dipakai' : 'sudah dipakai'}'
                      ' · berlaku ${invite['expires_at']}',
                    ),
                  ),
                ),
              ),
        ],
      ],
    );
  }

  Widget _settingsTab() {
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          'Ringkasan owner',
          Column(
            children: [
              _row('ID owner', '${summary?.payload['owner_id'] ?? '-'}'),
              _row('Paket', '${summary?.payload['plan'] ?? '-'}'),
              _row('Berlaku sampai', '${summary?.payload['period_end'] ?? '-'}'),
              _row('Batas perangkat', '${summary?.payload['device_limit'] ?? '-'}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Relay',
          Column(
            children: [
              TextField(
                controller: _relayUrl,
                decoration: const InputDecoration(labelText: 'Alamat relay'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _enrollToken,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Token pendaftaran'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _storeId,
                decoration: const InputDecoration(labelText: 'ID toko'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _saveRelaySettings,
                    child: const Text('Simpan'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _connectViewer,
                    child: Text(_connected ? 'Perbarui koneksi' : 'Hubungkan owner'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Aplikasi Owner hanya membaca data dan mengelola akses. '
          'Transaksi tetap di aplikasi utama.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _card(String title, Widget child) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
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
}
