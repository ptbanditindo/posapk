import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../data/access_control.dart';
import '../../data/account_service.dart';
import '../../data/app_database.dart';
import '../../data/device_service.dart';
import '../../data/google_auth_service.dart';
import '../../data/license_service.dart';
import '../../data/owner_access_api.dart';
import '../../data/reconciliation_service.dart';
import '../../data/store_settings.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../upload_backup_dialog.dart';
import '../widgets.dart';
import 'sync_conflicts_screen.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  Map<String, Object?>? _status;
  Map<String, Object?>? _ownerRow;
  String? _licenseEmail;
  List<Map<String, Object?>> _accounts = [];
  List<Map<String, Object?>> _devices = [];
  List<Map<String, Object?>>? _relayAccounts;
  List<Map<String, Object?>>? _relayDevices;
  List<Map<String, Object?>> _reconcileRequests = [];
  Map<String, Object?>? _syncStatus;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final status = await LicenseService.instance.status();
    final owner = await LicenseService.instance.owner();
    final accounts = await AccountService.instance.listAccounts();
    final devices = await DeviceService.instance.listDevices();
    final sync = await SyncService.instance.status();
    final email = await AppDatabase.instance.getSetting('license.email');
    final reconcile = await ReconciliationService.instance.openRequests();
    List<Map<String, Object?>>? relayAccounts = _relayAccounts;
    List<Map<String, Object?>>? relayDevices = _relayDevices;
    if (relayAccounts == null || relayDevices == null) {
      final api = await _ownerApi();
      if (api != null) {
        try {
          relayAccounts = await api.accounts();
          relayDevices = await api.devices();
        } catch (_) {
          // Server belum siap; daftar akses tetap kosong.
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _ownerRow = owner;
      _licenseEmail = email;
      _accounts = accounts;
      _devices = devices;
      _syncStatus = sync;
      _reconcileRequests = reconcile;
      _relayAccounts = relayAccounts;
      _relayDevices = relayDevices;
    });
  }

  Future<OwnerApi?> _ownerApi() async {
    final url = await SyncService.instance.relayUrl();
    final token = await SyncService.instance.relayDeviceToken();
    final ownerId = await LicenseService.instance.ownerId();
    if (url == null ||
        url.isEmpty ||
        token == null ||
        token.isEmpty ||
        ownerId == null ||
        ownerId.isEmpty) {
      return null;
    }
    return OwnerApi(baseUrl: url, deviceToken: token, ownerId: ownerId);
  }

  Future<void> _refreshRelayAccess() async {
    final api = await _ownerApi();
    if (api == null) {
      if (mounted) {
        showSnack(
          context,
          'Perangkat ini belum terhubung ke server akun.',
          error: true,
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final accounts = await api.accounts();
      final devices = await api.devices();
      if (!mounted) return;
      setState(() {
        _relayAccounts = accounts;
        _relayDevices = devices;
      });
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal memuat akses: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushAccountsToServer({bool silent = false}) async {
    final api = await _ownerApi();
    if (api == null) {
      if (!silent && mounted) {
        showSnack(
          context,
          'Perangkat ini belum terhubung ke server akun.',
          error: true,
        );
      }
      return;
    }
    final store = await SyncService.instance.storeId();
    final settings = await StoreSettingsService.instance.ensure();
    if (!silent) setState(() => _busy = true);
    try {
      var count = 0;
      // Akun nonaktif juga wajib dikirim agar relay mencabut sesinya.
      for (final account in _accounts) {
        final syncId = '${account['sync_id'] ?? ''}';
        final username = '${account['username'] ?? ''}';
        if (syncId.isEmpty || username.isEmpty) continue;
        final stores = _jsonList(account['store_ids']);
        final role = '${account['role_base'] ?? 'KASIR'}';
        final extras = _jsonList(account['extra_permissions_json']);
        await api.saveAccount(
          syncId: syncId,
          username: username,
          nama: '${account['nama'] ?? ''}',
          role: role,
          permissions: settings.accessFor(role, extras: extras).toList(),
          permissionGrants: extras,
          stores: stores.isEmpty ? [store] : stores,
          passwordHash: '${account['password_hash'] ?? ''}',
          passwordSalt: '${account['password_salt'] ?? ''}',
          passwordIterations:
              (account['password_iterations'] as num?)?.toInt() ?? 600000,
          aktif: account['aktif'] == 1,
          permissionVersion:
              (account['permission_version'] as num?)?.toInt() ?? 1,
          permissionsExplicit: true,
        );
        count++;
      }
      await _refreshRelayAccess();
      if (!silent && mounted) {
        showSnack(context, '$count akun dikirim ke server akun.');
      }
    } catch (error) {
      if (!silent && mounted) {
        showSnack(context, 'Gagal mengirim akun: $error', error: true);
      }
    } finally {
      if (!silent && mounted) setState(() => _busy = false);
    }
  }

  List<String> _jsonList(Object? raw) {
    if (raw is List) return raw.map((value) => '$value').toList();
    try {
      final decoded = jsonDecode('${raw ?? '[]'}');
      if (decoded is List) return decoded.map((value) => '$value').toList();
    } catch (_) {}
    return const [];
  }

  Future<void> _createPairingCode(Map<String, Object?> account) async {
    final api = await _ownerApi();
    final syncId = '${account['sync_id'] ?? ''}';
    if (api == null || syncId.isEmpty) {
      if (mounted) {
        showSnack(
          context,
          'Perangkat ini belum terhubung ke server akun.',
          error: true,
        );
      }
      return;
    }
    final stores = _jsonList(account['store_ids']);
    final storeId =
        stores.isEmpty ? await SyncService.instance.storeId() : stores.first;
    setState(() => _busy = true);
    try {
      final result = await api.createInvite(
        accountSyncId: syncId,
        storeId: storeId,
      );
      if (!mounted) return;
      final expires = DateTime.tryParse('${result['expires_at'] ?? ''}');
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Kode pairing'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                '${result['code'] ?? ''}',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                expires == null
                    ? 'Kode hanya dapat dipakai sekali.'
                    : 'Berlaku sampai '
                        '${DateFormat('dd/MM/yyyy HH:mm').format(expires.toLocal())}.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Buka aplikasi di HP karyawan, pilih "Hubungkan perangkat '
                'karyawan", lalu masukkan kode ini. Kode hangus setelah '
                'dipakai.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: '${result['code'] ?? ''}'),
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
      await _refreshRelayAccess();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membuat kode: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeRelayDevice(Map<String, Object?> device) async {
    final api = await _ownerApi();
    final id = '${device['id'] ?? ''}';
    final current = await SyncService.instance.relayDeviceId();
    if (api == null || id.isEmpty) return;
    if (!mounted) return;
    if (id == current) {
      showSnack(
        context,
        'Perangkat ini tidak dapat dicabut dari dirinya sendiri.',
        error: true,
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cabut perangkat'),
        content: Text(
          'Cabut ${device['nama'] ?? 'perangkat ini'}? Perangkat tersebut '
          'harus pairing ulang untuk mengirim data.',
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
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await api.revokeDevice(id);
      await _refreshRelayAccess();
      if (mounted) showSnack(context, 'Perangkat dicabut.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal mencabut: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showReconcileRequests() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rekonsiliasi tertunda'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final row in _reconcileRequests)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${row['tanggal']} · ${row['data_type']}'),
                  subtitle: Text('${row['alasan']} · ${row['status']}'),
                ),
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

  Future<void> _activateLicense() async {
    final token = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pasang lisensi server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Tempel token lisensi yang diterbitkan server. Aplikasi akan '
              'memverifikasi tanda tangan dan masa berlakunya secara lokal.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Token lisensi'),
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
            child: const Text('Pasang'),
          ),
        ],
      ),
    );
    final value = token.text.trim();
    token.dispose();
    if (confirmed != true || value.isEmpty) return;
    try {
      await LicenseService.instance.installToken(value);
      final recovery = await LicenseService.instance.recoveryCodeOnce();
      await _load();
      if (!mounted) return;
      if (recovery != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Kode pemulihan owner'),
            content: Text(
              '$recovery\n\nTampil sekali. Simpan offline; setelah '
              'dikonfirmasi kode ini dihapus dari penyimpanan aman.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Sudah disimpan'),
              ),
            ],
          ),
        );
        await LicenseService.instance.clearRecoveryCode();
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal memasang lisensi: $error', error: true);
    }
  }

  Future<void> _googleLogin() async {
    setState(() => _busy = true);
    try {
      final result = await GoogleAuthService.instance.activate();
      await _load();
      if (!mounted) return;
      showSnack(
        context,
        'Lisensi aktif untuk ${result['email']} sampai '
        '${result['period_end'] ?? '-'}.',
      );
    } on GoogleAuthException catch (error) {
      if (mounted) showSnack(context, error.message, error: true);
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mengaktifkan lisensi Google: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAccount() async {
    final settings = await StoreSettingsService.instance.ensure();
    if (!mounted) return;
    final input = await showDialog<_AccountInput>(
      context: context,
      builder: (_) => _AccountDialog(
        roles: settings.roleNames,
        roleName: roleDisplayName,
      ),
    );
    if (input == null) return;
    try {
      await AccountService.instance.createAccount(
        username: input.username,
        nama: input.nama,
        role: input.role,
        password: input.password,
        extraPermissions: input.permissions,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueEmployee(syncId, txn: txn),
      );
      await _load();
      await _pushAccountsToServer(silent: true);
      if (mounted) {
        showSnack(
          context,
          'Akun ${input.username} dibuat. Password: ${input.password}',
        );
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membuat akun: $error', error: true);
    }
  }

  Future<void> _editAccount(Map<String, Object?> account) async {
    final settings = await StoreSettingsService.instance.ensure();
    if (!mounted) return;
    final input = await showDialog<_AccountInput>(
      context: context,
      builder: (_) => _AccountDialog(
        roles: settings.roleNames,
        roleName: roleDisplayName,
        account: account,
      ),
    );
    if (input == null) return;
    try {
      await AccountService.instance.updateAccount(
        account['id'] as int,
        nama: input.nama,
        role: input.role,
        aktif: input.aktif,
        extraPermissions: input.permissions,
        storeIds: _jsonList(account['store_ids']).isEmpty
            ? const ['utama']
            : _jsonList(account['store_ids']),
        actor: AppState.instance.requireOperator,
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueEmployee(syncId, txn: txn),
      );
      await _load();
      await _pushAccountsToServer(silent: true);
      if (mounted) showSnack(context, 'Akun ${input.username} diperbarui.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal mengubah akun: $error', error: true);
    }
  }

  Future<void> _registerOwnerDevice() async {
    setState(() => _busy = true);
    try {
      final result = await DeviceService.instance.registerDevice(
        nama: 'Perangkat ini',
        kind: 'owner',
        makeCurrent: true,
      );
      await _load();
      if (mounted) {
        showSnack(context, 'Perangkat owner terdaftar: ${result['id']}');
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal daftar perangkat: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _registerEmployeeDevice() async {
    final active = _accounts.where((row) => row['aktif'] == 1).toList();
    if (active.isEmpty) {
      showSnack(context, 'Buat akun karyawan terlebih dahulu.', error: true);
      return;
    }
    int? accountId = active.first['id'] as int;
    final nama = TextEditingController(text: 'Perangkat karyawan');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Perangkat karyawan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nama,
                decoration: const InputDecoration(labelText: 'Nama perangkat'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: accountId,
                decoration: const InputDecoration(labelText: 'Akun'),
                items: active
                    .map(
                      (row) => DropdownMenuItem(
                        value: row['id'] as int,
                        child: Text('${row['nama']} (${row['username']})'),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => accountId = value),
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
              child: const Text('Daftarkan'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await DeviceService.instance.registerDevice(
        nama: nama.text,
        kind: 'employee',
        employeeAccountId: accountId,
      );
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Token perangkat'),
          content: Text(
            '${result['nama']}\nID: ${result['id']}\n\n'
            'Token (tampil sekali):\n${result['token']}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal daftar perangkat: $error', error: true);
    }
  }

  Future<void> _connectDevice() async {
    setState(() => _busy = true);
    try {
      final result = await SyncService.instance.registerRelayDevice(
        nama: 'Perangkat PusatkuPOS',
      );
      await _load();
      if (!mounted) return;
      if (result['key_pending'] == true) {
        showSnack(
          context,
          'Perangkat tersambung. Tunggu pemilik membagikan akses toko.',
        );
      } else {
        showSnack(context, 'Perangkat tersambung.');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyambungkan perangkat: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final result = await SyncService.instance.syncNow();
      await _load();
      if (!mounted) return;
      if (result['snapshot_required'] == true) {
        showSnack(
          context,
          'Perangkat tertinggal. Minta owner mengunggah snapshot.',
        );
      } else if (result['snapshot_applied'] == true) {
        showSnack(context, 'Snapshot diterapkan. Sinkronkan lagi untuk delta.');
      } else {
        showSnack(
          context,
          'Sinkron: ${result['sent']} terkirim, ${result['applied']} diterapkan.',
        );
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Sinkron gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareStoreKey() async {
    setState(() => _busy = true);
    try {
      final devices = await SyncService.instance.relayDevices();
      final current = await SyncService.instance.relayDeviceId();
      var count = 0;
      for (final device in devices) {
        final id = device['id'] as String? ?? '';
        final revoked = device['revoked_at'] as String? ?? '';
        if (id.isEmpty || id == current || revoked.isNotEmpty) continue;
        await SyncService.instance.wrapStoreKeyForDevice(
          targetRelayDeviceId: id,
          targetEncryptionKey: device['encryption_key'] as String,
        );
        count++;
      }
      if (mounted) {
        showSnack(context, 'Kunci toko dibagikan ke $count perangkat.');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal bagikan kunci: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadSnapshot() async {
    final uploaded = await showUploadBackupDialog(context);
    if (!mounted || !uploaded) return;
    await _load();
    if (mounted) {
      showSnack(context, 'Cadangan toko berhasil diunggah.');
    }
  }

  Future<void> _takeSnapshot() async {
    setState(() => _busy = true);
    try {
      final result = await SyncService.instance.bootstrapNow();
      await _load();
      if (!mounted) return;
      if (result['applied'] == true) {
        showSnack(context, 'Snapshot diterapkan sampai urutan ${result['cursor']}.');
      } else {
        showSnack(context, 'Belum ada snapshot yang dapat diterapkan.');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal ambil snapshot: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyRecoveryCode() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pulihkan akses dengan kode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Masukkan kode pemulihan owner. Jika cocok, minta token '
              'lisensi baru ke server menggunakan ID owner.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Kode pemulihan'),
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
            child: const Text('Verifikasi'),
          ),
        ],
      ),
    );
    final code = controller.text.trim();
    controller.dispose();
    if (ok != true || code.isEmpty) return;
    final valid = await LicenseService.instance.verifyRecoveryCode(code);
    if (!mounted) return;
    if (!valid) {
      showSnack(context, 'Kode pemulihan tidak cocok.', error: true);
      return;
    }
    final ownerId = await LicenseService.instance.ownerId();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kode pemulihan valid'),
        content: Text(
          'ID owner: ${ownerId ?? '-'}\n\n'
          'Hubungi penyedia lisensi untuk menerbitkan ulang token lisensi '
          'server, lalu pasang token itu di layar ini.',
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

  bool get _canManageAccounts =>
      AppState.instance.isOwner || AppState.instance.can('kelola_akun');
  bool get _canManageDevices =>
      AppState.instance.isOwner || AppState.instance.can('kelola_perangkat');
  bool get _canManageLicense =>
      AppState.instance.isOwner || AppState.instance.can('lisensi');

  @override
  Widget build(BuildContext context) {
    final premium = _status?['premium'] == true;
    final expired = _status?['expired'] == true;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Premium',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (_busy) const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!premium)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  expired
                      ? 'Lisensi kedaluwarsa. Data dan kasir offline tetap '
                          'bisa dipakai; sinkronisasi dan multi-toko '
                          'dinonaktifkan sampai lisensi diperbarui.'
                      : 'Belum ada lisensi server yang valid. Kasir offline '
                          'tetap gratis; sinkronisasi, multi-toko, dan '
                          'akun karyawan memerlukan lisensi.',
                ),
              ),
            ),
          ),
        if (_canManageLicense)
          SectionCard(
            title: 'Lisensi dan ID owner',
          trailing: premium
              ? const Chip(label: Text('Premium'))
              : FilledButton.tonal(
                  onPressed: _activateLicense,
                  child: const Text('Aktifkan'),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _line('ID owner', '${_status?['owner_id'] ?? '-'}'),
              _line('Paket', '${_status?['plan'] ?? 'free'}'),
              _line('Berlaku sampai', '${_status?['period_end'] ?? '-'}'),
              _line('Jumlah toko', '${_status?['store_limit'] ?? 1} toko'),
              if ((_licenseEmail ?? '').isNotEmpty)
                _line('Akun Google', _licenseEmail!),
              if (!premium) ...[
                const SizedBox(height: 12),
                if (GoogleAuthService.instance.configured &&
                    GoogleAuthService.instance.supported)
                  FilledButton.icon(
                    onPressed: _busy ? null : _googleLogin,
                    icon: const Icon(Icons.login),
                    label: Text(
                      expired
                          ? 'Pulihkan lisensi dengan Google'
                          : 'Masuk dengan Google',
                    ),
                  )
                else
                  Text(
                    !GoogleAuthService.instance.configured
                        ? 'Login Google belum diaktifkan pada build ini. '
                            'Gunakan token lisensi manual.'
                        : 'Login Google hanya tersedia di Android, iOS, '
                            'macOS, dan web.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              if (_status?['recovery_available'] == true) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _verifyRecoveryCode,
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('Pulihkan akses dengan kode'),
                  ),
                ),
              ],
              if ((_ownerRow?['public_key'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Kunci publik owner',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                SelectableText(
                  _ownerRow!['public_key'] as String,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (!premium)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Lisensi hanya diterbitkan server. Token berisi owner, '
                    'masa berlaku, dan jumlah toko.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_canManageAccounts)
          SectionCard(
            title: 'Akun karyawan',
          trailing: TextButton.icon(
            onPressed: premium ? _addAccount : null,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Tambah'),
          ),
          child: _accounts.isEmpty
              ? const Text('Belum ada akun karyawan.')
              : Column(
                  children: _accounts
                      .map(
                        (account) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${account['nama']}'),
                          subtitle: Text(
                            '${account['username']} · '
                            '${roleLabels[account['role_base']] ?? account['role_base']} · '
                            '${account['aktif'] == 1 ? 'aktif' : 'nonaktif'}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) => _accountAction(account, value),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'ubah',
                                child: Text('Ubah peran & akses'),
                              ),
                              PopupMenuItem(
                                value: 'reset-password',
                                child: Text('Reset password'),
                              ),
                              PopupMenuItem(
                                value: 'reset-pin',
                                child: Text('Reset PIN'),
                              ),
                              PopupMenuItem(
                                value: 'audit',
                                child: Text('Audit'),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        const SizedBox(height: 12),
        if (_canManageDevices)
          SectionCard(
            title: 'Perangkat',
          trailing: PopupMenuButton<String>(
            enabled: premium,
            onSelected: (value) {
              if (value == 'owner') _registerOwnerDevice();
              if (value == 'employee') _registerEmployeeDevice();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'owner', child: Text('Daftarkan perangkat owner')),
              PopupMenuItem(
                value: 'employee',
                child: Text('Daftarkan perangkat karyawan'),
              ),
            ],
          ),
          child: _devices.isEmpty
              ? const Text('Belum ada perangkat terdaftar.')
              : Column(
                  children: _devices
                      .map(
                        (device) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            device['kind'] == 'owner'
                                ? Icons.phone_android_outlined
                                : Icons.badge_outlined,
                          ),
                          title: Text('${device['nama']}'),
                          subtitle: Text(
                            '${device['kind']} · ${device['id']}\n'
                            '${device['revoked_at'] == null ? 'aktif' : 'dicabut'}',
                          ),
                          isThreeLine: true,
                          trailing: device['revoked_at'] == null
                              ? TextButton(
                                  onPressed: () async {
                                    await DeviceService.instance
                                        .revokeDevice(device['id'] as String);
                                    await _load();
                                  },
                                  child: const Text('Cabut'),
                                )
                              : null,
                        ),
                      )
                      .toList(),
                ),
        ),
        const SizedBox(height: 12),
        if (_canManageAccounts || _canManageDevices)
          SectionCard(
            title: 'Akses karyawan',
          subtitle:
              'Kode pairing berlaku 10 menit dan hangus setelah dipakai '
              'satu perangkat.',
          trailing: IconButton(
            tooltip: 'Muat akses',
            onPressed: _busy ? null : _refreshRelayAccess,
            icon: const Icon(Icons.refresh),
          ),
          child: _relayAccounts == null
              ? const Text(
                  'Perangkat ini belum terhubung ke server akun. '
                  'Sambungkan perangkat lebih dulu.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _busy ? null : _pushAccountsToServer,
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Kirim akun ke server'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_relayAccounts!.isEmpty)
                      const Text('Belum ada akun karyawan di server.')
                    else
                      ..._relayAccounts!.map(
                        (account) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.badge_outlined),
                          title: Text('${account['nama'] ?? '-'}'),
                          subtitle: Text(
                            '${account['username'] ?? '-'} · '
                            '${account['role_base'] ?? '-'}',
                          ),
                          trailing: TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _createPairingCode(account),
                            icon: const Icon(Icons.qr_code_2, size: 18),
                            label: const Text('Kode pairing'),
                          ),
                        ),
                      ),
                    const Divider(height: 24),
                    Text(
                      'Perangkat terdaftar',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    if ((_relayDevices ?? const []).isEmpty)
                      const Text('Belum ada perangkat terdaftar.')
                    else
                      ...(_relayDevices ?? const []).map(
                        (device) {
                          final revoked =
                              '${device['revoked_at'] ?? ''}'.isNotEmpty;
                          final lastSeen = _lastSeenLabel(device);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              device['kind'] == 'owner'
                                  ? Icons.phone_android_outlined
                                  : Icons.badge_outlined,
                            ),
                            title: Text('${device['nama'] ?? 'Perangkat'}'),
                            subtitle: Text(
                              revoked
                                  ? 'dicabut'
                                  : '${device['kind'] ?? '-'} · $lastSeen',
                            ),
                            trailing: revoked
                                ? null
                                : TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _revokeRelayDevice(device),
                                    child: const Text('Cabut'),
                                  ),
                          );
                        },
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        if (_canManageDevices)
          SectionCard(
            title: 'Sinkronisasi',
          subtitle:
              'Data toko dikirim terenkripsi antar perangkat milik akun Anda.',
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: premium ? _connectDevice : null,
                    child: const Text('Sambungkan perangkat ini'),
                  ),
                  FilledButton(
                    onPressed: premium ? _syncNow : null,
                    child: const Text('Sinkron sekarang'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _shareStoreKey : null,
                    child: const Text('Bagikan akses toko'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _uploadSnapshot : null,
                    child: const Text('Unggah snapshot'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _takeSnapshot : null,
                    child: const Text('Ambil snapshot'),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SyncConflictsScreen(),
                      ),
                    ),
                    child: Text(
                      'Konflik (${_syncStatus?['conflicts'] ?? 0})',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _line('Sinkron terakhir', _lastSyncLabel),
              _line('Menunggu dikirim', '${_syncStatus?['pending'] ?? 0}'),
              _line(
                'Konflik / gagal',
                '${((_syncStatus?['failed'] as int?) ?? 0) + ((_syncStatus?['blocking'] as int?) ?? 0)}',
              ),
              _line(
                'Terakhir diterima',
                '${_syncStatus?['cursor'] ?? 0}',
              ),
              _line(
                'Rekonsiliasi terbuka',
                '${_reconcileRequests.length}',
              ),
              if (_reconcileRequests.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _showReconcileRequests,
                    child: const Text('Lihat rekonsiliasi'),
                  ),
                ),
              if (_syncStatus?['storage_warning'] == true) ...[
                const SizedBox(height: 8),
                Text(
                  'Penyimpanan server hampir penuh. Data lama dibersihkan '
                  'otomatis setelah semua perangkat menerimanya; cabut '
                  'perangkat yang sudah tidak dipakai.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              if (_syncStatus?['stale'] == true) ...[
                const SizedBox(height: 8),
                Text(
                  'Ada perubahan yang belum terkirim lebih dari 24 jam. '
                  'Periksa koneksi atau buka daftar konflik.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              if (('${_syncStatus?['last_error'] ?? ''}').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${_syncStatus?['last_error']}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  String get _lastSyncLabel {
    final raw = '${_syncStatus?['last_success_at'] ?? ''}';
    if (raw.isEmpty) return 'Belum pernah';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return DateFormat('dd/MM/yyyy HH:mm').format(parsed.toLocal());
  }

  String _lastSeenLabel(Map<String, Object?> device) {
    final raw = '${device['last_seen_at'] ?? ''}';
    if (raw.isEmpty) return 'belum pernah terhubung';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final days = DateTime.now().difference(local).inDays;
    final label = DateFormat('dd/MM/yyyy HH:mm').format(local);
    return days >= 7 ? '$label (tertinggal)' : label;
  }

  Widget _line(String label, String value) {
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

  Future<void> _accountAction(Map<String, Object?> account, String action) async {
    final id = account['id'] as int;
    if (action == 'ubah') {
      await _editAccount(account);
      return;
    }
    if (action == 'reset-password') {
      final password = TextEditingController();
      var error = '';
      final nextPassword = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Reset password'),
            content: TextField(
              controller: password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password baru (minimal 8)',
                errorText: error.isEmpty ? null : error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () {
                  final value = password.text.trim();
                  if (value.length < 8) {
                    setDialogState(
                      () => error = 'Password minimal 8 karakter.',
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, value);
                },
                child: const Text('Simpan'),
              ),
            ],
          ),
        ),
      );
      password.dispose();
      if (nextPassword == null) return;
      try {
        await AccountService.instance.resetPassword(
          id,
          password: nextPassword,
          actor: AppState.instance.requireOperator,
        );
        await _load();
        if (mounted) showSnack(context, 'Password direset.');
      } catch (resetError) {
        if (mounted) {
          showSnack(
            context,
            'Gagal mereset password: $resetError',
            error: true,
          );
        }
      }
    } else if (action == 'reset-pin') {
      try {
        await AccountService.instance.resetPin(
          id,
          actor: AppState.instance.requireOperator,
        );
        await _load();
        if (mounted) {
          showSnack(
            context,
            'PIN direset; karyawan membuat PIN baru saat login.',
          );
        }
      } catch (resetError) {
        if (mounted) {
          showSnack(context, 'Gagal mereset PIN: $resetError', error: true);
        }
      }
    } else if (action == 'audit') {
      final rows = await AccountService.instance.auditRows(id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Audit ${account['username']}'),
          content: SizedBox(
            width: 420,
            child: rows.isEmpty
                ? const Text('Belum ada audit.')
                : ListView(
                    shrinkWrap: true,
                    children: rows
                        .map(
                          (row) => ListTile(
                            dense: true,
                            title: Text('${row['action']}'),
                            subtitle: Text('${row['created_at']} · ${row['actor']}'),
                          ),
                        )
                        .toList(),
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
  }
}

class _AccountInput {
  const _AccountInput({
    required this.username,
    required this.nama,
    required this.role,
    required this.password,
    required this.permissions,
    this.aktif = true,
  });

  final String username;
  final String nama;
  final String role;
  final String password;
  final List<String> permissions;
  final bool aktif;
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({
    required this.roles,
    required this.roleName,
    this.account,
  });

  final List<String> roles;
  final String Function(String role) roleName;
  final Map<String, Object?>? account;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  final _username = TextEditingController();
  final _nama = TextEditingController();
  final _password = TextEditingController();
  late final List<String> _roles;
  late String _role;
  late bool _aktif;
  final Set<String> _permissions = {};

  bool get _editing => widget.account != null;

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    _username.text = '${account?['username'] ?? ''}';
    _nama.text = '${account?['nama'] ?? ''}';
    _roles = [...widget.roles];
    _role = canonicalRole('${account?['role_base'] ?? _roles.first}');
    if (!_roles.contains(_role)) _roles.insert(0, _role);
    _aktif = account?['aktif'] != 0;
    _permissions.addAll(
      _decodeList('${account?['extra_permissions_json'] ?? '[]'}'),
    );
  }

  @override
  void dispose() {
    _username.dispose();
    _nama.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? 'Ubah akun karyawan' : 'Akun karyawan baru'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _username,
              autofocus: !_editing,
              enabled: !_editing,
              decoration: const InputDecoration(labelText: 'Nama pengguna'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nama,
              decoration: const InputDecoration(labelText: 'Nama lengkap'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'Peran'),
              items: _roles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(widget.roleName(role)),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _role = value ?? _roles.first),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _editing
                    ? 'Password baru (kosongkan jika tetap)'
                    : 'Password awal (minimal 8)',
              ),
            ),
            if (_editing)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aktif'),
                value: _aktif,
                onChanged: (value) => setState(() => _aktif = value),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Izin tambahan (di atas akses peran)',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: permissionLabels.entries
                  .map(
                    (entry) => FilterChip(
                      label: Text(entry.value),
                      selected: _permissions.contains(entry.key),
                      onSelected: (value) => setState(() {
                        if (value) {
                          _permissions.add(entry.key);
                        } else {
                          _permissions.remove(entry.key);
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
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _AccountInput(
                username: _username.text.trim(),
                nama: _nama.text.trim(),
                role: _role,
                password: _password.text.trim(),
                permissions: _permissions.toList(),
                aktif: _aktif,
              ),
            );
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

List<String> _decodeList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded.map((item) => '$item').toList();
  } catch (_) {}
  return const [];
}
