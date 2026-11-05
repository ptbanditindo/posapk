import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_config.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/employee_auth_service.dart';
import '../data/google_auth_service.dart';
import '../data/license_service.dart';
import '../data/pairing_service.dart';
import '../data/pin_service.dart';
import '../data/secure_store.dart';
import '../data/session_service.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
import 'owner_viewer.dart';

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _pages = PageController();
  int _index = 0;
  bool _busy = false;

  static const _slides = [
    (
      icon: Icons.storefront_outlined,
      title: 'Semua transaksi bengkel di satu tempat',
      body:
          'Kasir, stok, pelanggan, dan laporan tersimpan rapi. '
          'Tidak perlu buku catatan terpisah.',
    ),
    (
      icon: Icons.offline_bolt_outlined,
      title: 'Tetap jalan tanpa internet',
      body:
          'Data disimpan di perangkat ini. Saat internet tersedia, '
          'data diselaraskan otomatis.',
    ),
    (
      icon: Icons.groups_outlined,
      title: 'Satu aplikasi untuk pemilik dan karyawan',
      body:
          'Pemilik mengatur toko dan laporan. Karyawan bekerja sesuai '
          'peran dan toko yang ditugaskan.',
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_index >= _slides.length) return;
    await _pages.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  Future<void> _toChoices() async {
    if (_index == _slides.length) return;
    await _pages.animateToPage(
      _slides.length,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
  }

  Future<void> _startFree() => _run(() async {
        try {
          final ownerId = await LicenseService.instance.ensureOwner();
          final profile = SessionProfile(
            mode: 'free',
            ownerId: ownerId,
            nama: 'Pemilik',
            role: 'owner',
            plan: 'free',
          );
          await _finish(profile, ownerPin: true);
        } catch (error) {
          _showError(error);
        }
      });

  Future<void> _startGoogle() => _run(() async {
        if (!GoogleAuthService.instance.configured) {
          _showError(
            'Masuk dengan Google belum tersedia di aplikasi ini. '
            'Gunakan mode tanpa akun.',
          );
          return;
        }
        try {
          final result = await GoogleAuthService.instance.activate();
          final stores = result['stores'];
          final storeIds = <String>[];
          if (stores is List) {
            for (final store in stores) {
              if (store is Map && '${store['store_id'] ?? ''}'.isNotEmpty) {
                storeIds.add('${store['store_id']}');
              }
            }
          }
          final email = '${result['email'] ?? ''}';
          final profile = SessionProfile(
            mode: 'premium',
            ownerId: '${result['owner_id']}',
            nama: email.isEmpty ? 'Pemilik' : email,
            role: 'owner',
            email: email,
            plan: '${result['plan'] ?? 'premium'}',
            periodEnd: result['period_end'] as String?,
            storeIds: storeIds.isEmpty ? const ['utama'] : storeIds,
          );
          await _finish(profile, ownerPin: true);
        } on GoogleAuthException catch (error) {
          _showError(error.message);
        } catch (error) {
          _showError(error);
        }
      });

  Future<void> _startViewer() => _run(() async {
        if (!GoogleAuthService.instance.configured) {
          _showError(
            'Mode ringkasan belum tersedia di build ini. '
            'Hubungi penjual.',
          );
          return;
        }
        var switched = false;
        try {
          final result = await GoogleAuthService.instance.signIn();
          final ownerId = '${result['owner_id'] ?? ''}';
          if (ownerId.isEmpty) {
            throw GoogleAuthException('Akun tidak mengembalikan ID owner.');
          }
          await AppDatabase.instance.openViewerDatabase(ownerId);
          switched = true;
          await GoogleAuthService.instance.install(result);
          final rawSummary = result['summary'];
          if (rawSummary is Map) {
            await AppDatabase.instance.setSetting(
              'owner.summary.signed',
              jsonEncode(rawSummary),
            );
          }
          final enroll = '${result['enroll_token'] ?? ''}';
          if (enroll.isNotEmpty) {
            await SecureStore.instance.write('owner.enroll_token', enroll);
          }
          final stores = result['stores'];
          final storeIds = <String>[];
          if (stores is List) {
            for (final store in stores) {
              if (store is Map && '${store['store_id'] ?? ''}'.isNotEmpty) {
                storeIds.add('${store['store_id']}');
              }
            }
          }
          final email = '${result['email'] ?? ''}';
          final profile = SessionProfile(
            mode: 'viewer',
            ownerId: ownerId,
            nama: email.isEmpty ? 'Pemilik' : email,
            role: 'owner',
            email: email,
            plan: '${result['plan'] ?? 'premium'}',
            periodEnd: result['period_end'] as String?,
            storeIds: storeIds.isEmpty ? const ['utama'] : storeIds,
          );
          await _finish(profile, ownerPin: true);
        } on GoogleAuthException catch (error) {
          if (switched) await AppDatabase.instance.useMainDatabase();
          _showError(error.message);
        } catch (error) {
          if (switched) await AppDatabase.instance.useMainDatabase();
          _showError(error);
        }
      });

  Future<void> _startEmployee() => _run(() async {
        try {
          final result = await Navigator.of(context).push<EmployeeLoginResult>(
            MaterialPageRoute(builder: (_) => const EmployeeLoginPage()),
          );
          if (result == null || !mounted) return;
          var profile = result.profile;
          if (profile.mustChangePassword) {
            final changed = await _changePassword(result);
            if (!changed) return;
            profile = profile.copyWith(mustChangePassword: false);
          }
          await _finish(profile, ownerPin: false);
        } catch (error) {
          _showError(error);
        }
      });

  Future<bool> _changePassword(EmployeeLoginResult result) async {
    final oldController = TextEditingController(text: result.password);
    final newController = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    var saving = false;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Ganti password awal'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: oldController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password saat ini',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: newController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password baru (minimal 8)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Ulangi password baru',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final next = newController.text;
                        if (next.length < 8 || next != confirm.text) {
                          setDialogState(
                            () => error = 'Password baru minimal 8 karakter '
                                'dan harus sama.',
                          );
                          return;
                        }
                        setDialogState(() => saving = true);
                        try {
                          await EmployeeAuthService.instance.changePassword(
                            ownerId: result.profile.ownerId,
                            username: result.profile.username ?? '',
                            oldPassword: oldController.text,
                            newPassword: next,
                          );
                          if (context.mounted) Navigator.pop(context, true);
                        } catch (failure) {
                          setDialogState(() {
                            saving = false;
                            error = '$failure';
                          });
                        }
                      },
                child: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );
    oldController.dispose();
    newController.dispose();
    confirm.dispose();
    return changed ?? false;
  }

  Future<void> _finish(
    SessionProfile profile, {
    required bool ownerPin,
  }) async {
    final pin = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PinSetupPage(
          title: ownerPin ? 'Buat PIN pemilik' : 'Buat PIN karyawan',
          subtitle: ownerPin
              ? 'PIN dipakai setiap membuka aplikasi. '
                  'Simpan di tempat yang hanya Anda ketahui.'
              : 'PIN dipakai setiap membuka aplikasi di perangkat ini.',
        ),
      ),
    );
    if (pin == null || !mounted) {
      if (profile.isViewer) {
        await SecureStore.instance.delete('owner.enroll_token');
        await AppDatabase.instance.useMainDatabase();
      }
      return;
    }
    await PinService.instance.setup(pin);
    await SessionService.instance.save(profile);
    await AppDatabase.instance.setSetting(
      'app.store_id',
      profile.storeIds.first,
    );
    await AppState.instance.load();
    await AppState.instance.refreshPinState();
    AppState.instance.setOperator(profile.toOperator());
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => profile.isViewer
            ? const OwnerViewerShell()
            : const HomeShell(),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
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
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextButton(
                    onPressed: _busy || _index >= _slides.length
                        ? null
                        : _toChoices,
                    child: const Text('Lewati'),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (value) => setState(() => _index = value),
                  children: [
                    ..._slides.map((slide) => _SlideView(slide: slide)),
                    _ChoiceView(
                      busy: _busy,
                      onFree: _startFree,
                      onGoogle: _startGoogle,
                      onEmployee: _startEmployee,
                      onViewer: _startViewer,
                    ),
                  ],
                ),
              ),
              if (_index < _slides.length)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _slides.length,
                          (dot) => AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: dot == _index ? 22 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: dot == _index
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _next,
                          child: Text(
                            _index == _slides.length - 1
                                ? 'Pilih cara masuk'
                                : 'Lanjut',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});

  final ({IconData icon, String title, String body}) slide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(slide.icon, size: 48, color: scheme.onPrimary),
              ),
              const SizedBox(height: 32),
              Text(
                slide.title,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Text(
                slide.body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceView extends StatelessWidget {
  const _ChoiceView({
    required this.busy,
    required this.onFree,
    required this.onGoogle,
    required this.onEmployee,
    required this.onViewer,
  });

  final bool busy;
  final VoidCallback onFree;
  final VoidCallback onGoogle;
  final VoidCallback onEmployee;
  final VoidCallback onViewer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pilih cara masuk',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Pilihan ini menentukan data dan fitur yang tersedia.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              _ChoiceTile(
                icon: Icons.storefront_outlined,
                title: 'Lewati tanpa akun',
                subtitle: 'Pemilik lokal · gratis',
                onTap: busy ? null : onFree,
              ),
              const SizedBox(height: 12),
              _ChoiceTile(
                icon: Icons.account_circle_outlined,
                title: 'Masuk dengan Google',
                subtitle: 'Pemilik premium · lisensi per toko',
                onTap: busy ? null : onGoogle,
              ),
              const SizedBox(height: 12),
              _ChoiceTile(
                icon: Icons.badge_outlined,
                title: 'Masuk karyawan',
                subtitle: 'Gunakan ID owner, nama pengguna, dan password',
                onTap: busy ? null : onEmployee,
              ),
              const SizedBox(height: 12),
              _ChoiceTile(
                icon: Icons.insights_outlined,
                title: 'Ringkasan laporan toko',
                subtitle:
                    'Khusus owner yang sudah login Google · hanya membaca '
                    'dan mengelola akses',
                onTap: busy ? null : onViewer,
              ),
              if (busy) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class PinSetupPage extends StatefulWidget {
  const PinSetupPage({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    final pin = _pin.text.trim();
    if (!RegExp(r'^\d{6,}$').hasMatch(pin)) {
      setState(() => _error = 'PIN minimal 6 angka.');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = 'PIN yang diulang tidak sama.');
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.pin_outlined, size: 42, color: scheme.primary),
                    const SizedBox(height: 12),
                    Text(
                      widget.subtitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
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
                        labelText: 'PIN baru',
                        counterText: '',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: 12,
                      decoration: const InputDecoration(
                        labelText: 'Ulangi PIN',
                        counterText: '',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      onSubmitted: (_) => _save(),
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
                      onPressed: _save,
                      icon: const Icon(Icons.check),
                      label: const Text('Simpan PIN'),
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

class EmployeeLoginPage extends StatefulWidget {
  const EmployeeLoginPage({super.key});

  @override
  State<EmployeeLoginPage> createState() => _EmployeeLoginPageState();
}

class _EmployeeLoginPageState extends State<EmployeeLoginPage> {
  final _ownerId = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ownerId.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ownerId = _ownerId.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (ownerId.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Isi ID owner, nama pengguna, dan password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await EmployeeAuthService.instance.login(
        ownerId: ownerId,
        username: username,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
        _busy = false;
      }
    }
  }

  Future<void> _submitInvite() async {
    if (!serviceConfigured) {
      setState(() => _error = 'Layanan akun belum siap. Hubungi penjual.');
      return;
    }
    final draft = await showDialog<_InviteDraft>(
      context: context,
      builder: (_) => const _InviteDialog(),
    );
    if (draft == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await PairingService.instance.claim(
        relayUrl: normalizedServiceUrl,
        code: draft.code,
        deviceName: draft.deviceName,
      );
      final accountId = (result['account_id'] as num?)?.toInt() ?? 0;
      final rows = await AppDatabase.instance.db.query(
        'employee_accounts',
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Akun hasil pairing tidak ditemukan.');
      }
      final account = rows.first;
      final role = '${account['role_base'] ?? 'KASIR'}';
      final extras = _stringList(account['extra_permissions_json']);
      final stores = _stringList(account['store_ids_json']);
      final profile = SessionProfile(
        mode: 'employee',
        ownerId: '${result['owner_id'] ?? ''}',
        nama: '${account['nama'] ?? account['username'] ?? 'Karyawan'}',
        role: role,
        employeeSyncId: account['sync_id'] as String?,
        username: '${account['username'] ?? ''}',
        permissions: [...(rolePermissions[role] ?? const <String>{}), ...extras],
        storeIds: stores.isEmpty
            ? ['${result['store_id'] ?? 'utama'}']
            : stores,
        plan: 'premium',
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        EmployeeLoginResult(
          profile: profile,
          password: '',
          deviceToken: null,
          deviceId: result['relay_device_id'] as String?,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  List<String> _stringList(Object? raw) {
    try {
      final decoded = jsonDecode('${raw ?? '[]'}');
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (_) {
      // Nilai lama atau rusak diabaikan; profil tetap bisa dibuka.
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Masuk karyawan')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Masuk dengan akun karyawan',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Akun dibuat dan diatur oleh pemilik toko.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _ownerId,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'ID owner',
                        prefixIcon: Icon(Icons.qr_code_2_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: 'Nama pengguna',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.password_outlined),
                      ),
                      onSubmitted: (_) => _busy ? null : _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _submit,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: const Text('Masuk'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _submitInvite,
                      icon: const Icon(Icons.pin_outlined),
                      label: const Text('Punya kode pairing'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Kode pairing dibuat pemilik, berlaku singkat, dan '
                      'hanya dapat dipakai satu perangkat.',
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

class _InviteDraft {
  const _InviteDraft({required this.code, required this.deviceName});

  final String code;
  final String deviceName;
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog();

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _code = TextEditingController();
  final _deviceName = TextEditingController(text: 'Perangkat karyawan');
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    if (code.length < 4) {
      setState(() => _error = 'Masukkan kode dari pemilik.');
      return;
    }
    final name = _deviceName.text.trim();
    Navigator.pop(
      context,
      _InviteDraft(
        code: code,
        deviceName: name.isEmpty ? 'Perangkat karyawan' : name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Kode pairing'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Minta kode kepada pemilik. Kode hanya berlaku sebentar dan '
            'hangus setelah dipakai.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            maxLength: 8,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
            ],
            decoration: InputDecoration(
              labelText: 'Kode dari pemilik',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          TextField(
            controller: _deviceName,
            decoration: const InputDecoration(labelText: 'Nama perangkat'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Pasangkan')),
      ],
    );
  }
}
