import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/app_config.dart';
import '../core/money.dart';
import '../core/summary_file_stub.dart'
    if (dart.library.io) '../core/summary_file_io.dart'
    if (dart.library.html) '../core/summary_file_web.dart';
import '../data/access_control.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/device_service.dart';
import '../data/license_service.dart';
import '../data/license_verifier.dart';
import '../data/models.dart';
import '../data/owner_access_api.dart';
import '../data/secure_store.dart';
import '../data/session_service.dart';
import '../data/store_settings.dart';
import '../sync/crypto.dart';
import '../sync/sync_service.dart';
import 'entry_gate.dart';
import 'pin_gate.dart';
import 'screens/sync_conflicts_screen.dart';

const _summaryKey = 'owner.summary.signed';
const _enrollKey = 'owner.enroll_token';

String _statusBayarLabel(String value) => switch (value.toUpperCase()) {
      'LUNAS' => 'Lunas',
      'KREDIT' => 'Belum lunas',
      _ => value,
    };

String _deviceKindLabel(Object? value) =>
    '${value ?? ''}' == 'owner' ? 'Pemilik' : 'Karyawan';

class OwnerViewerShell extends StatefulWidget {
  const OwnerViewerShell({super.key});

  @override
  State<OwnerViewerShell> createState() => _OwnerViewerShellState();
}

class _OwnerViewerSummary {
  const _OwnerViewerSummary({
    required this.payload,
    required this.signature,
    required this.publicKey,
  });

  final Map<String, Object?> payload;
  final String signature;
  final String publicKey;
}

class _OwnerViewerShellState extends State<OwnerViewerShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 6, vsync: this);
  final _search = TextEditingController();
  final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  SessionProfile? _profile;
  _OwnerViewerSummary? _summary;
  String _enrollToken = '';
  String _deviceToken = '';
  String _defaultStoreId = 'utama';
  String? _error;
  bool _busy = false;
  bool _connected = false;
  bool _keyReady = false;

  DashboardData? _dashboard;
  List<ServiceRecordSummary> _records = [];
  List<StockItem> _stock = [];
  List<Customer> _customers = [];
  ReportSummary? _reportAll;
  ReportSummary? _reportToday;
  Map<String, Object?>? _syncStatus;

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
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      _profile = await SessionService.instance.load();
      _enrollToken = await SecureStore.instance.read(_enrollKey) ?? '';
      _deviceToken = await SyncService.instance.relayDeviceToken() ?? '';
      final cached = await AppDatabase.instance.getSetting(_summaryKey);
      if (cached != null && cached.isNotEmpty) {
        await _parseSummary(cached, persist: false);
      } else {
        await _loadLocal();
      }
      if (_summary != null) {
        await _connectViewer(silent: true);
      }
      await _refreshConnectionState();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refreshConnectionState() async {
    final device = await DeviceService.instance.currentDevice();
    final relayId = await SyncService.instance.relayDeviceId();
    final key = await SyncService.instance.existingStoreKey();
    final token = await SyncService.instance.relayDeviceToken() ?? '';
    if (!mounted) return;
    setState(() {
      _connected = device != null && relayId != null && relayId.isNotEmpty;
      _keyReady = key != null;
      _deviceToken = token;
    });
  }

  Future<void> _pickSummary() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pilih ringkasan pemilik',
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
        throw const FormatException(
          'Ringkasan tidak lengkap: tanda tangan tidak ditemukan.',
        );
      }
      final trustedKey = serverLicensePublicKey.trim();
      if (trustedKey.isEmpty) {
        throw const FormatException(
          'Kunci lisensi server belum tersedia, jadi ringkasan belum bisa '
          'diperiksa.',
        );
      }
      if (trustedKey != publicKey) {
        throw const FormatException(
          'Ringkasan dibuat oleh kunci yang tidak dikenal. Minta salinan '
          'baru dari pemilik.',
        );
      }
      final verified = await Ed25519().verify(
        utf8.encode(canonicalJson(payload)),
        signature: Signature(
          base64Url.decode(signature),
          publicKey: SimplePublicKey(
            base64Url.decode(trustedKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!verified) {
        throw const FormatException(
          'Tanda tangan ringkasan tidak cocok. Minta salinan baru dari '
          'pemilik.',
        );
      }
      final viewedOwner = '${payload['owner_id'] ?? ''}';
      final sessionOwner = _profile?.ownerId ?? '';
      if (sessionOwner.isNotEmpty && viewedOwner != sessionOwner) {
        throw const FormatException(
          'Ringkasan milik akun lain. Keluar lalu masuk dengan akun tersebut.',
        );
      }
      await AppDatabase.instance.runViewerSyncWrite(() => _seedOwner(payload));
      if (persist) {
        await AppDatabase.instance.runViewerSyncWrite(
          () => AppDatabase.instance.setSetting(_summaryKey, raw),
        );
      }
      if (!mounted) return;
      setState(() {
        _summary = _OwnerViewerSummary(
          payload: payload,
          signature: signature,
          publicKey: publicKey,
        );
        final stores = payload['stores'] as List? ?? const [];
        if (stores.isNotEmpty) {
          final first = stores.first;
          if (first is Map && '${first['store_id'] ?? ''}'.isNotEmpty) {
            _defaultStoreId = '${first['store_id']}';
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

  Future<void> _seedOwner(Map<String, Object?> payload) async {
    final ownerId = '${payload['owner_id']}';
    final ownerPublic = '${payload['owner_public_key'] ?? ''}';
    if (ownerPublic.isNotEmpty) {
      await LicenseService.instance.installRemoteOwner(
        ownerId: ownerId,
        publicKey: ownerPublic,
      );
    }
    final token = payload['license_token'] as String? ?? '';
    if (token.isNotEmpty) {
      await LicenseService.instance.installToken(
        token,
        expectedOwnerId: ownerId,
      );
    }
  }

  Future<void> _connectViewer({bool silent = false}) =>
      AppDatabase.instance.runViewerSyncWrite(
        () => _connectViewerBody(silent: silent),
      );

  Future<void> _connectViewerBody({required bool silent}) async {
    if (_summary == null) {
      if (!silent) {
        _snack('Ringkasan pemilik belum tersedia.', error: true);
      }
      return;
    }
    if (_enrollToken.isEmpty) {
      if (!silent) {
        _snack('Sesi sudah berakhir. Masuk ulang dengan akun Google.',
            error: true);
      }
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SyncService.instance.configure(
        relayUrl: normalizedServiceUrl,
        enrollToken: _enrollToken,
        storeId: _defaultStoreId,
      );
      final device = await DeviceService.instance.currentDevice();
      final relayId = await SyncService.instance.relayDeviceId();
      if (device == null || relayId == null || relayId.isEmpty) {
        final result = await SyncService.instance.registerRelayDevice(
          nama: 'Ringkasan pemilik',
          viewer: true,
        );
        if (!silent) {
          _snack(
            result['key_pending'] == true
                ? 'Perangkat terdaftar. Kunci toko akan dikirim menyusul.'
                : 'Perangkat ringkasan sudah terhubung.',
          );
        }
      } else {
        await SyncService.instance.refreshStoreKey();
      }
      if (await SyncService.instance.existingStoreKey() != null) {
        await SyncService.instance.bootstrapNow();
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
              ? 'Salinan toko dipasang sampai urutan ${result['cursor']}.'
              : 'Sinkron selesai: ${result['applied']} data diterima.',
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
              ? 'Salinan toko dipasang sampai urutan ${result['cursor']}.'
              : 'Belum ada salinan toko yang bisa dipasang.',
        );
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
      includeArchived: false,
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
    if (summary == null ||
        _deviceToken.isEmpty ||
        !serviceConfigured) {
      return null;
    }
    return OwnerApi(
      baseUrl: normalizedServiceUrl,
      deviceToken: _deviceToken,
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
      result.add({'store_id': _defaultStoreId, 'nama': 'Toko utama'});
    }
    return result;
  }

  Future<void> _editAccount([Map<String, Object?>? account]) async {
    final settings = await StoreSettingsService.instance.ensure();
    if (!mounted) return;
    final username = TextEditingController(text: '${account?['username'] ?? ''}');
    final nama = TextEditingController(text: '${account?['nama'] ?? ''}');
    final password = TextEditingController();
    var role = canonicalRole('${account?['role_base'] ?? 'KASIR'}');
    var aktif = account?['aktif'] != false;
    final explicit = account?['permissions_explicit'] == true;
    final grantSource = explicit
        ? (account?['permission_grants'] as List?)
        : (account?['extra_permissions'] as List?);
    final permissions = <String>{
      ...((grantSource ?? const []).map((e) => '$e')),
    };
    final roleOptions = <String>{
      ...settings.roleNames,
      role,
      for (final row in _accounts)
        canonicalRole('${row['role_base'] ?? ''}'),
    }.toList();
    final stores = <String>{
      ...((account?['store_ids'] as List?) ?? const []).map((e) => '$e'),
    };
    if (stores.isEmpty) stores.add(_defaultStoreId);
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
                  decoration: const InputDecoration(
                    labelText: 'Nama pengguna',
                    helperText: 'Dipakai untuk masuk, tanpa spasi. '
                        'Contoh: budi.',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nama,
                  decoration: const InputDecoration(
                    labelText: 'Nama lengkap',
                    helperText: 'Contoh: Budi Santoso.',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: roleOptions.contains(role) ? role : 'KASIR',
                  decoration: const InputDecoration(
                    labelText: 'Peran',
                    helperText: 'Menentukan menu dan tindakan yang bisa '
                        'dibuka.',
                  ),
                  items: roleOptions
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(roleDisplayName(item)),
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
                    helperText: account == null
                        ? 'Minimal 8 huruf atau angka. Berikan ke karyawan.'
                        : 'Kosongkan jika password tidak diganti.',
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Akun aktif'),
                  subtitle: const Text(
                    'Karyawan bisa masuk dan memakai aplikasi.',
                  ),
                  value: aktif,
                  onChanged: (value) => setDialogState(() => aktif = value),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Izin tambahan',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        'Centang hanya izin yang benar-benar dibutuhkan.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
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
                    permissions:
                        settings.accessFor(role, extras: permissions.toList()).toList(),
                    permissionGrants: permissions.toList(),
                    stores: stores.toList(),
                    password: temp.isEmpty ? null : temp,
                    aktif: aktif,
                    permissionVersion:
                        (account?['permission_version'] as num?)?.toInt() ?? 0,
                  );
                  if (context.mounted) Navigator.pop(context, true);
                  if (temp.isNotEmpty && mounted) {
                    _snack('Password awal: $temp. Catat sekarang.');
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Akun gagal disimpan: $error'),
                      ),
                    );
                  }
                }
              },
              child: const Text('Simpan akun'),
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
      _snack('Akun ini belum diberi toko. Pilih toko dulu saat mengubah '
          'akun.', error: true);
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
          title: const Text('Kode hubungkan perangkat'),
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
      if (mounted) _snack('Kode gagal dibuat: $error', error: true);
    }
  }

  Future<void> _revokeDevice(Map<String, Object?> device) async {
    final api = _api;
    if (api == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cabut perangkat'),
        content: Text(
          'Cabut ${device['nama']}? Perangkat itu harus dihubungkan ulang '
          'untuk mengirim data.',
        ),
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
      if (mounted) _snack('Perangkat gagal dicabut: $error', error: true);
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari ringkasan?'),
        content: const Text(
          'PIN dan sesi akan dihapus. Salinan ringkasan di perangkat ini juga '
          'dihapus. Untuk masuk lagi, Anda perlu salinan baru dari server '
          'akun.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await signOutToOnboarding(context);
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
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ringkasan toko',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            if (profile != null && profile.nama.isNotEmpty)
              Text(
                '${profile.nama} · hanya baca',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
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
            ),
          IconButton(
            onPressed: () => lockNow(context),
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Kunci layar',
          ),
          IconButton(
            onPressed: _confirmSignOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Keluar',
          ),
        ],
        bottom: summary == null
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Ringkasan'),
                  Tab(text: 'Riwayat'),
                  Tab(text: 'Laporan'),
                  Tab(text: 'Data dan cadangan'),
                  Tab(text: 'Akses'),
                  Tab(text: 'Pengaturan'),
                ],
              ),
      ),
      body: summary == null
          ? _waitingView()
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

  Widget _waitingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const CircularProgressIndicator(),
            if (_busy) const SizedBox(height: 16),
            Text(
              _error ??
                  'Salinan toko belum tersedia. Pastikan perangkat toko '
                      'sudah mengunggah cadangan data.',
              textAlign: TextAlign.center,
            ),
            if (!_busy) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _connectViewer,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Muat salinan toko'),
              ),
            ],
          ],
        ),
      ),
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
              child: _metric(
                'Omzet hari ini',
                dashboard.todayRevenueCents,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _metric(
                'Jumlah nota',
                dashboard.todayCount,
                money: false,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _metric('Piutang', dashboard.receivableCents)),
            const SizedBox(width: 10),
            Expanded(
              child: _metric(
                'Stok menipis',
                dashboard.lowStockCount,
                money: false,
              ),
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
                    title: Text(
                      row.customerNama.isEmpty ? row.noNota : row.customerNama,
                    ),
                    subtitle: Text(
                      '${row.noNota} · ${_dateFormat.format(row.waktu)}',
                    ),
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
        const Text(
          'Mode ini hanya membaca pembukuan dan mengelola akses karyawan. '
          'Transaksi dilakukan di aplikasi utama.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
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
              hintText: 'Cari no. nota atau nama pelanggan',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _loadLocal,
                tooltip: 'Muat ulang daftar',
                icon: const Icon(Icons.refresh),
              ),
            ),
            onChanged: (_) => _loadLocal(),
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? const Center(
                  child: Text('Belum ada data. Muat salinan toko dulu.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final row = _records[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _showRecord(row.id),
                        title: Text(
                          row.customerNama.isEmpty
                              ? row.noNota
                              : row.customerNama,
                        ),
                        subtitle: Text(
                          '${row.noNota} · ${_dateFormat.format(row.waktu)}\n'
                          '${row.unitLabel}',
                        ),
                        isThreeLine: true,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(formatRupiah(row.totalCents)),
                            Text(
                              row.isVoid
                                  ? 'Dibatalkan'
                                  : _statusBayarLabel(row.statusBayar),
                            ),
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
              _row(
                'Status nota',
                record.isVoid
                    ? 'Dibatalkan'
                    : _statusBayarLabel(record.statusBayar),
              ),
              const Divider(),
              _row('Jasa', formatRupiah(record.jasaEfektifCents)),
              _row('Part', formatRupiah(record.partEfektifCents)),
              _row('Diskon', '-${formatRupiah(record.diskonEfektifCents)}'),
              if (record.totalReturCents > 0)
                _row('Retur', '-${formatRupiah(record.totalReturCents)}'),
              _row('Total', formatRupiah(record.totalCents)),
              _row(
                'Sudah dibayar',
                formatRupiah(detail.totalDibayarCents),
              ),
              _row('Sisa tagihan', formatRupiah(detail.sisaCents)),
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
              _row('Jumlah nota', '${today.transaksi}'),
              _row('Omzet sebelum retur', formatRupiah(today.totalCents)),
              _row('Retur', '-${formatRupiah(today.returCents)}'),
              _row('Omzet setelah retur', formatRupiah(today.totalNetCents)),
              _row('Uang diterima', formatRupiah(
                today.cashByMethod.values.fold<int>(
                  0,
                  (sum, value) => sum + value,
                ),
              )),
              _row('Sudah dibayar', formatRupiah(today.dibayarCents)),
              _row('Piutang', formatRupiah(today.piutangCents)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Semua data',
          Column(
            children: [
              _row('Jumlah nota', '${all.transaksi}'),
              _row('Penjualan jasa', formatRupiah(all.totalJasaCents)),
              _row('Penjualan part', formatRupiah(all.totalPartCents)),
              _row('Diskon', formatRupiah(all.diskonCents)),
              _row('Omzet sebelum retur', formatRupiah(all.totalCents)),
              _row('Retur', '-${formatRupiah(all.returCents)}'),
              _row('Omzet setelah retur', formatRupiah(all.totalNetCents)),
              _row('Sudah dibayar', formatRupiah(all.dibayarCents)),
              _row('Piutang', formatRupiah(all.piutangCents)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Data lain',
          Column(
            children: [
              _row('Jumlah pelanggan', '${_customers.length}'),
              _row('Jumlah barang di stok', '${_stock.length}'),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorCard(),
        ],
      ],
    );
  }

  String _lastSyncLabel(Map<String, Object?>? status) {
    final raw = '${status?['last_success_at'] ?? ''}';
    if (raw.isEmpty) return 'Belum pernah';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return _dateFormat.format(parsed.toLocal());
  }

  Widget _dataTab() {
    final status = _syncStatus;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          'Status salinan',
          Column(
            children: [
              _row('Perangkat', _connected ? 'terhubung' : 'belum terhubung'),
              _row(
                'Kunci toko',
                _keyReady ? 'tersedia' : 'menunggu dari perangkat toko',
              ),
              _row('Nomor urut data', '${status?['cursor'] ?? 0}'),
              _row('Data menunggu dikirim', '${status?['pending'] ?? 0}'),
              _row('Sinkron terakhir', _lastSyncLabel(status)),
              _row(
                'Data bermasalah / gagal',
                '${((status?['failed'] as int?) ?? 0) + ((status?['blocking'] as int?) ?? 0)}',
              ),
              if (status?['stale'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Ada perubahan yang belum terkirim lebih dari 24 jam.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
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
              label: const Text('Perbarui salinan'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _takeSnapshot,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Muat salinan'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SyncConflictsScreen(),
                ),
              ),
              icon: const Icon(Icons.warning_amber_outlined),
              label: Text(
                'Perlu diputuskan (${status?['conflicts'] ?? 0})',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          'Cadangan',
          const Text(
            'Mode ringkasan hanya membaca pembukuan dan memuat cadangan data. '
            'Unggah cadangan dilakukan dari perangkat toko agar semua data '
            'ikut lengkap.',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorCard(),
        ],
      ],
    );
  }

  Widget _accessTab() {
    if (_api == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Masuk dengan Google untuk mengelola akun dan perangkat.',
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
              label: const Text('Tambah akun'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_accounts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Belum ada akun. Tambahkan akun untuk membuka akses karyawan.',
              ),
            ),
          )
        else
          ..._accounts.map(
            (account) => Card(
              child: ListTile(
                title: Text('${account['nama']} (${account['username']})'),
                subtitle: Text(
                  '${roleDisplayName('${account['role_base'] ?? ''}')} · '
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
                '${_deviceKindLabel(device['kind'])} · ${device['id']}\n'
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
                      ' · berlaku sampai ${invite['expires_at']}',
                    ),
                  ),
                ),
              ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorCard(),
        ],
      ],
    );
  }

  Widget _settingsTab() {
    final summary = _summary;
    final profile = _profile;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(
          'Ringkasan pemilik',
          Column(
            children: [
              _row('ID pemilik', '${summary?.payload['owner_id'] ?? '-'}'),
              _row('Paket', '${summary?.payload['plan'] ?? '-'}'),
              _row(
                'Berlaku sampai',
                '${summary?.payload['period_end'] ?? '-'}',
              ),
              _row('Jumlah toko', '${summary?.payload['store_limit'] ?? '-'}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Akun Google',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(
                'Email terhubung',
                (profile?.email ?? '').isEmpty ? '-' : profile!.email!,
              ),
              const SizedBox(height: 8),
              const Text(
                'Mode ini hanya membaca pembukuan dan mengelola akses '
                'karyawan. Transaksi tetap dilakukan di aplikasi utama.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          'Perangkat ini',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('Status', _connected ? 'terhubung' : 'belum terhubung'),
              _row(
                'Kunci toko',
                _keyReady ? 'tersedia' : 'menunggu dari perangkat toko',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _connectViewer,
                    child: Text(
                      _connected ? 'Perbarui koneksi' : 'Hubungkan perangkat',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _pickSummary,
                    child: const Text('Impor ringkasan pemilik'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorCard(),
        ],
        const SizedBox(height: 12),
        Text(
          'Mode ringkasan tidak dapat membuat atau mengubah pembukuan.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _errorCard() {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Ada masalah: ${_error ?? ''}\n'
          'Periksa koneksi lalu coba lagi.',
        ),
      ),
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
