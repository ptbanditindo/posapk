import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/operator.dart';
import '../data/access_control.dart';
import '../data/app_database.dart';
import '../data/pin_service.dart';
import '../data/session_service.dart';
import '../data/store_settings.dart';
import '../state/app_state.dart';
import 'entry_gate.dart';
import 'home_shell.dart';
import 'owner_viewer.dart';

class PinGate extends StatefulWidget {
  const PinGate({
    super.key,
    required this.profile,
    this.unlockOnly = false,
  });

  final SessionProfile profile;

  /// Bila true, PIN hanya membuka kunci layar dan kembali ke halaman semula.
  final bool unlockOnly;

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _isEmployee => !widget.profile.isOwner;

  String get _roleLabel {
    if (widget.profile.isViewer) return 'Ringkasan laporan toko';
    if (widget.profile.isOwner) {
      return widget.profile.mode == 'premium' ? 'Pemilik premium' : 'Pemilik';
    }
    return roleDisplayName(widget.profile.role);
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'Isi PIN terlebih dahulu.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await PinService.instance.verifyDetailed(pin);
      if (result == PinVerification.locked) {
        setState(
          () => _error = 'PIN dikunci sementara karena terlalu banyak '
              'percobaan. Tunggu sebentar, lalu coba lagi.',
        );
        return;
      }
      if (result == PinVerification.wrong) {
        setState(() => _error = 'PIN tidak cocok. Periksa lagi.');
        return;
      }
      final profile = widget.profile;
      if (result == PinVerification.weakLegacyPin) {
        final upgraded = await _forcePinUpgrade(pin);
        if (!upgraded) return;
      }
      var permissions = profile.permissions;
      var role = profile.role;
      var extras = profile.extraPermissions;
      if (!profile.isOwner && !profile.isViewer) {
        // Akun nonaktif tidak boleh membuka sesi walau PIN lokal benar.
        final employeeSync = profile.employeeSyncId ?? '';
        if (employeeSync.isNotEmpty) {
          final rows = await AppDatabase.instance.db.query(
            'employee_accounts',
            columns: ['aktif', 'role_base', 'extra_permissions_json'],
            where: 'sync_id = ?',
            whereArgs: [employeeSync],
            limit: 1,
          );
          if (rows.isNotEmpty && (rows.first['aktif'] as int? ?? 1) == 0) {
            setState(() {
              _error = 'Akun karyawan ini sudah dinonaktifkan pemilik.';
              _busy = false;
            });
            return;
          }
          if (rows.isNotEmpty) {
            role = '${rows.first['role_base'] ?? profile.role}';
            final raw = rows.first['extra_permissions_json'];
            if (raw is String && raw.trim().isNotEmpty) {
              try {
                final decoded = jsonDecode(raw);
                if (decoded is List) {
                  extras = decoded.map((item) => '$item').toList();
                }
              } on FormatException {
                extras = const [];
              }
            }
          }
        }
        // Hitung ulang agar perubahan akses peran langsung berlaku saat
        // perangkat dibuka, termasuk sesi lama yang belum punya kunci menu.
        final settings = await StoreSettingsService.instance.ensure();
        permissions = settings.accessFor(role, extras: extras).toList();
      }
      AppState.instance.setOperator(
        Operator(
          kind: profile.isViewer
              ? 'viewer'
              : (profile.isOwner ? 'owner' : 'employee'),
          role: profile.isViewer
              ? 'VIEWER'
              : (profile.isOwner ? 'owner' : role),
          label: profile.nama,
          employeeSyncId: profile.employeeSyncId,
          username: profile.username,
          extraPermissions: extras,
          permissions: permissions.toSet(),
          storeIds: profile.storeIds,
          mustChangePassword: profile.mustChangePassword,
        ),
      );
      await AppState.instance.load();
      if (!mounted) return;
      if (widget.unlockOnly) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => profile.isViewer
                ? const OwnerViewerShell()
                : const HomeShell(),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Gagal membuka aplikasi: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PIN lama yang pendek tidak boleh dipakai masuk. Pengguna wajib membuat
  /// PIN minimal 6 digit dahulu.
  Future<bool> _forcePinUpgrade(String oldPin) async {
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    var saving = false;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('PIN perlu diperbarui'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'PIN di perangkat ini masih kurang dari 6 angka. Buat PIN '
                'baru minimal 6 angka untuk melanjutkan.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: next,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'PIN baru',
                  helperText: 'Minimal 6 angka.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirm,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Ulangi PIN baru'),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context, false),
              child: const Text('Keluar'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final value = next.text.trim();
                      if (value.length < 6 || value != confirm.text.trim()) {
                        setDialogState(
                          () => error =
                              'Isi PIN minimal 6 angka di kedua kolom.',
                        );
                        return;
                      }
                      setDialogState(() => saving = true);
                      final ok = await PinService.instance.change(
                        oldPin: oldPin,
                        newPin: value,
                      );
                      if (context.mounted) Navigator.pop(context, ok);
                    },
              child: const Text('Simpan PIN baru'),
            ),
          ],
        ),
      ),
    );
    next.dispose();
    confirm.dispose();
    return changed ?? false;
  }

  Future<void> _switchAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari akun ini?'),
        content: Text(
          widget.profile.isOwner
              ? 'Sesi ditutup. Data toko, data yang belum terkirim, dan PIN '
                  'pemilik tetap tersimpan di perangkat ini. Buka lagi dengan '
                  'PIN yang sama. Untuk menghapus data, pakai Reset perangkat '
                  'di Pengaturan.'
              : 'PIN dan sesi karyawan di perangkat ini akan dihapus. Data '
                  'transaksi dan data yang belum terkirim tetap tersimpan '
                  'untuk pemilik.',
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = widget.profile;
    final scaffold = Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(
                          widget.profile.isViewer
                              ? Icons.insights_outlined
                              : _isEmployee
                                  ? Icons.badge_outlined
                                  : Icons.storefront_outlined,
                          color: scheme.onPrimary,
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'PUSATKU POS',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        profile.nama.isEmpty ? _roleLabel : profile.nama,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _isEmployee
                            ? '$_roleLabel · ${profile.storeIds.length} toko'
                            : _roleLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _pin,
                        autofocus: true,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        maxLength: 12,
                        decoration: const InputDecoration(
                          labelText: 'PIN',
                          helperText: 'Masukkan PIN yang Anda buat saat '
                              'pertama membuka aplikasi.',
                          counterText: '',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_forward),
                        label: const Text('Masuk ke aplikasi'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy ? null : _switchAccount,
                        child: const Text('Ganti akun atau keluar'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Transaksi tersimpan di perangkat ini.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    );
    if (!widget.unlockOnly) return scaffold;
    return PopScope(canPop: false, child: scaffold);
  }
}

Future<void> lockNow(BuildContext context) async {
  final profile = await SessionService.instance.load();
  if (profile == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PinGate(profile: profile, unlockOnly: true),
    ),
  );
}
