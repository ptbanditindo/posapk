import 'package:flutter/material.dart';

import '../../data/account_service.dart';
import '../../data/app_database.dart';
import '../../data/device_service.dart';
import '../../data/google_auth_service.dart';
import '../../data/license_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

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
  Map<String, Object?>? _syncStatus;
  bool _busy = false;

  final _relayUrl = TextEditingController();
  final _enrollToken = TextEditingController();
  final _storeId = TextEditingController(text: 'utama');

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    _relayUrl.dispose();
    _enrollToken.dispose();
    _storeId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final status = await LicenseService.instance.status();
    final owner = await LicenseService.instance.owner();
    final accounts = await AccountService.instance.listAccounts();
    final devices = await DeviceService.instance.listDevices();
    final sync = await SyncService.instance.status();
    final url = await SyncService.instance.relayUrl();
    final enroll = await SyncService.instance.enrollToken();
    final store = await SyncService.instance.storeId();
    final email = await AppDatabase.instance.getSetting('license.email');
    if (!mounted) return;
    setState(() {
      _status = status;
      _ownerRow = owner;
      _licenseEmail = email;
      _accounts = accounts;
      _devices = devices;
      _syncStatus = sync;
      _relayUrl.text = url ?? '';
      _enrollToken.text = enroll ?? '';
      _storeId.text = store;
    });
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
      final result = await GoogleAuthService.instance.activate(
        relayUrl: _relayUrl.text,
      );
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
    final input = await showDialog<_AccountInput>(
      context: context,
      builder: (_) => const _AccountDialog(),
    );
    if (input == null) return;
    try {
      await AccountService.instance.createAccount(
        username: input.username,
        nama: input.nama,
        role: input.role,
        password: input.password,
        extraPermissions: input.permissions,
      );
      await _load();
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

  Future<void> _saveSyncConfig() async {
    await SyncService.instance.configure(
      relayUrl: _relayUrl.text,
      enrollToken: _enrollToken.text,
      storeId: _storeId.text,
    );
    await _load();
    if (mounted) showSnack(context, 'Konfigurasi relay disimpan.');
  }

  Future<void> _registerRelayDevice() async {
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
          'Relay terdaftar. Minta owner membagikan kunci toko.',
        );
      } else {
        showSnack(context, 'Relay: ${result['relay_device_id']}');
      }
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal daftar relay: $error', error: true);
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
    setState(() => _busy = true);
    try {
      final result = await SyncService.instance.uploadSnapshot();
      if (mounted) {
        showSnack(context, 'Snapshot diunggah sampai urutan ${result['store_seq']}.');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal unggah snapshot: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
                          'bisa dipakai; sinkronisasi dan multi-perangkat '
                          'dinonaktifkan sampai lisensi diperbarui.'
                      : 'Belum ada lisensi server yang valid. Kasir offline '
                          'tetap gratis; sinkronisasi, multi-perangkat, dan '
                          'akun karyawan memerlukan lisensi.',
                ),
              ),
            ),
          ),
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
              _line('Batas perangkat', '${_status?['device_limit'] ?? 1}'),
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
                    'masa berlaku, dan batas perangkat.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
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
        SectionCard(
          title: 'Sinkronisasi relay',
          subtitle:
              'Perangkat mengirim delta terenkripsi. Server tidak menerapkan data bisnis.',
          child: Column(
            children: [
              TextField(
                controller: _relayUrl,
                decoration: const InputDecoration(
                  labelText: 'Alamat relay',
                  hintText: 'https://relay.contoh.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _enrollToken,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: 'Token pendaftaran relay'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _storeId,
                decoration: const InputDecoration(labelText: 'ID toko relay'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _saveSyncConfig,
                    child: const Text('Simpan konfigurasi'),
                  ),
                  FilledButton.tonal(
                    onPressed: premium ? _registerRelayDevice : null,
                    child: const Text('Daftarkan ke relay'),
                  ),
                  FilledButton(
                    onPressed: premium ? _syncNow : null,
                    child: const Text('Sinkron sekarang'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _shareStoreKey : null,
                    child: const Text('Bagikan kunci'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _uploadSnapshot : null,
                    child: const Text('Unggah snapshot'),
                  ),
                  OutlinedButton(
                    onPressed: premium ? _takeSnapshot : null,
                    child: const Text('Ambil snapshot'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _line('Antrean pending', '${_syncStatus?['pending'] ?? 0}'),
              _line('Kursor', '${_syncStatus?['cursor'] ?? 0}'),
              _line(
                'Perangkat relay',
                '${_syncStatus?['relay_device_id'] ?? '-'}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
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
    if (action == 'reset-password') {
      final password = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset password'),
          content: TextField(
            controller: password,
            decoration: const InputDecoration(
              labelText: 'Password baru (minimal 8)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                password.text.trim().length >= 8,
              ),
              child: const Text('Simpan'),
            ),
          ],
        ),
      );
      final nextPassword = password.text.trim();
      password.dispose();
      if (ok != true) return;
      await AccountService.instance.resetPassword(
        id,
        password: nextPassword,
      );
      await _load();
      if (mounted) showSnack(context, 'Password direset.');
    } else if (action == 'reset-pin') {
      await AccountService.instance.resetPin(id);
      await _load();
      if (mounted) showSnack(context, 'PIN direset; karyawan membuat PIN baru saat login.');
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
  });

  final String username;
  final String nama;
  final String role;
  final String password;
  final List<String> permissions;
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog();

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  final _username = TextEditingController();
  final _nama = TextEditingController();
  final _password = TextEditingController();
  String _role = 'KASIR';
  final Set<String> _permissions = {};

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
      title: const Text('Akun karyawan baru'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _username,
              autofocus: true,
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
              items: roles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(roleLabels[role] ?? role),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _role = value ?? 'KASIR'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password awal (minimal 8)',
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Izin tambahan',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Wrap(
              spacing: 6,
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
              ),
            );
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
