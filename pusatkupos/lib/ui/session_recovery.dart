import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/license_service.dart';
import '../data/pin_service.dart';
import '../data/session_service.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
import 'onboarding.dart';

/// Ditampilkan ketika sesi hilang tetapi PIN perangkat masih terpasang dan
/// identitas pemilik PIN tidak diketahui. Tanpa layar ini, siapa pun yang
/// memegang perangkat dapat masuk sebagai owner hanya dengan PIN apa pun.
class SessionRecoveryScreen extends StatefulWidget {
  const SessionRecoveryScreen({super.key});

  @override
  State<SessionRecoveryScreen> createState() => _SessionRecoveryScreenState();
}

class _SessionRecoveryScreenState extends State<SessionRecoveryScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    if (_busy) return;
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Masukkan kode pemulihan owner.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await LicenseService.instance.verifyRecoveryCode(code)) {
        setState(() => _error = 'Kode pemulihan tidak cocok.');
        return;
      }
      final ownerId = await LicenseService.instance.ownerId() ?? '';
      if (ownerId.isEmpty) {
        setState(() => _error = 'Identitas owner tidak ditemukan.');
        return;
      }
      final premium = await LicenseService.instance.isPremium();
      final profile = SessionProfile(
        mode: premium ? 'premium' : 'free',
        ownerId: ownerId,
        nama: 'Pemilik',
        role: 'owner',
        plan: premium ? 'premium' : 'free',
      );
      if (!mounted) return;
      final pin = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => const PinSetupPage(
            title: 'Buat PIN pemilik baru',
            subtitle:
                'Kode pemulihan valid. Buat PIN baru untuk membuka aplikasi '
                'di perangkat ini.',
          ),
        ),
      );
      if (pin == null || !mounted) return;
      await PinService.instance.setup(pin, profile: profile);
      await SessionService.instance.save(profile);
      await AppState.instance.load();
      await AppState.instance.refreshPinState();
      AppState.instance.setOperator(profile.toOperator());
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (_) => false,
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'Pemulihan gagal: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOnboarding() async {
    await AppDatabase.instance.useMainDatabase();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OnboardingFlow()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.key_outlined, size: 48, color: scheme.primary),
                    const SizedBox(height: 16),
                    Text(
                      'Sesi tidak ditemukan',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Data toko tetap tersimpan di perangkat ini. Untuk '
                      'membuka akses pemilik, masukkan kode pemulihan yang '
                      'ditampilkan saat aplikasi pertama kali diaktifkan.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _code,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Kode pemulihan owner',
                        prefixIcon: Icon(Icons.password),
                      ),
                      onSubmitted: (_) => _recover(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: scheme.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _recover,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_open),
                      label: const Text('Pulihkan akses pemilik'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _openOnboarding,
                      child: const Text('Masuk sebagai karyawan'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Karyawan tetap dapat masuk dengan akun dan password '
                      'masing-masing.',
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
  }
}
