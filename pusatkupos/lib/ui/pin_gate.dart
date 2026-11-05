import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/operator.dart';
import '../data/pin_service.dart';
import '../data/session_service.dart';
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
    return switch (widget.profile.role) {
      'KASIR' => 'Kasir',
      'MEKANIK' => 'Mekanik',
      'KEDUANYA' => 'Kasir & mekanik',
      _ => 'Karyawan',
    };
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'Masukkan PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await PinService.instance.verifyDetailed(pin);
      if (result == PinVerification.locked) {
        setState(() => _error = 'Terlalu banyak percobaan. Coba lagi nanti.');
        return;
      }
      if (result == PinVerification.wrong) {
        setState(() => _error = 'PIN salah.');
        return;
      }
      final profile = widget.profile;
      AppState.instance.setOperator(
        Operator(
          kind: profile.isOwner ? 'owner' : 'employee',
          role: profile.isOwner ? 'owner' : profile.role,
          label: profile.nama,
          employeeSyncId: profile.employeeSyncId,
          username: profile.username,
          permissions: profile.permissions.toSet(),
          storeIds: profile.storeIds,
          mustChangePassword: profile.mustChangePassword,
        ),
      );
      await AppState.instance.load();
      if (!mounted) return;
      if (result == PinVerification.weakLegacyPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'PIN Anda masih 4 digit. Segera ganti ke minimal 6 digit di '
              'Pengaturan.',
            ),
          ),
        );
      }
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

  Future<void> _switchAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari akun ini?'),
        content: const Text(
          'PIN dan sesi di perangkat ini akan dihapus. '
          'Data transaksi tetap tersimpan.',
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
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              scheme.primaryContainer.withValues(alpha: 0.55),
              Theme.of(context).scaffoldBackgroundColor,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
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
                        label: const Text('Buka aplikasi'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy ? null : _switchAccount,
                        child: const Text('Bukan akun ini?'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Data tersimpan lokal di perangkat ini.',
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
