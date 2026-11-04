import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/operator.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/pairing_service.dart';
import '../data/pin_service.dart';
import '../data/secure_store.dart';
import '../state/app_state.dart';
import '../sync/sync_service.dart';
import 'home_shell.dart';

class PinGate extends StatefulWidget {
  const PinGate({super.key});

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _employeePin = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _employeeMode = false;
  String? _deviceRole;

  bool get _setup => !AppState.instance.pinConfigured;
  bool get _employeeDevice => _deviceRole == 'employee';

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final role = await AppDatabase.instance.getSetting('app.role');
    if (!mounted) return;
    setState(() {
      _deviceRole = role;
      if (role == 'employee') _employeeMode = true;
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _username.dispose();
    _password.dispose();
    _employeePin.dispose();
    super.dispose();
  }

  Future<void> _ownerSubmit() async {
    final pin = _pin.text.trim();
    if (_setup) {
      if (!RegExp(r'^\d{6,}$').hasMatch(pin)) {
        setState(() => _error = 'PIN baru minimal 6 angka.');
        return;
      }
      if (pin != _confirm.text.trim()) {
        setState(() => _error = 'PIN yang diulang tidak sama.');
        return;
      }
    } else if (pin.isEmpty) {
      setState(() => _error = 'Masukkan PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var weakPin = false;
      if (_setup) {
        await PinService.instance.setup(pin);
        await AppState.instance.refreshPinState();
      } else {
        final result = await PinService.instance.verifyDetailed(pin);
        if (result == PinVerification.locked) {
          setState(() => _error = 'Terlalu banyak percobaan. Coba lagi nanti.');
          return;
        }
        if (result == PinVerification.wrong) {
          setState(() => _error = 'PIN salah.');
          return;
        }
        weakPin = result == PinVerification.weakLegacyPin;
      }
      await AppDatabase.instance.setSetting('app.role', 'owner');
      AppState.instance.setOperator(Operator.owner);
      if (!mounted) return;
      if (weakPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'PIN Anda masih 4 digit. Segera ganti ke minimal 6 digit di Pengaturan.',
            ),
          ),
        );
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
    } catch (error) {
      setState(() => _error = 'Gagal membuka aplikasi: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<({String ownerId, String token})?> _pairedDevice() async {
    final rows = await AppDatabase.instance.db.query(
      'owner_identity',
      columns: ['owner_id'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final ownerId = rows.first['owner_id'] as String? ?? '';
    final token =
        await SecureStore.instance.read('device.current_token') ?? '';
    if (ownerId.isEmpty || token.isEmpty) return null;
    return (ownerId: ownerId, token: token);
  }

  Future<void> _employeeSubmit() async {
    final username = _username.text.trim();
    final password = _password.text;
    final pin = _employeePin.text.trim();
    final paired = _employeeDevice ? await _pairedDevice() : null;
    if (username.isEmpty ||
        password.isEmpty ||
        (paired == null && pin.length != 6)) {
      setState(
        () => _error = paired == null
            ? 'Isi username, password, dan PIN 6 angka.'
            : 'Isi username dan password.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final operator = paired == null
          ? await AccountService.instance.loginHub(
              username: username,
              password: password,
              pin: pin,
            )
          : await AccountService.instance.loginDevice(
              ownerId: paired.ownerId,
              username: username,
              password: password,
              token: paired.token,
            );
      if (operator == null) {
        setState(() => _error = 'Username, password, atau PIN salah.');
        return;
      }
      if (operator.mustChangePassword) {
        final changed = await _forcePasswordChange(operator);
        if (!changed) {
          setState(() => _error = 'Password awal harus diganti.');
          return;
        }
      }
      AppState.instance.setOperator(operator);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _forcePasswordChange(Operator operator) async {
    final oldPassword = TextEditingController(text: _password.text);
    final newPassword = TextEditingController();
    final confirm = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Ganti password awal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPassword,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password lama'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password baru (minimal 8)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Ulangi password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () async {
              final next = newPassword.text;
              if (next.length < 8 || next != confirm.text) return;
              try {
                await AccountService.instance.changePassword(
                  operator.employeeId!,
                  oldPassword: oldPassword.text,
                  newPassword: next,
                );
                if (context.mounted) Navigator.pop(context, true);
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
    );
    oldPassword.dispose();
    newPassword.dispose();
    confirm.dispose();
    return result ?? false;
  }

  Future<void> _openPairing() async {
    final savedUrl = await SyncService.instance.relayUrl();
    if (!mounted) return;
    final relay = TextEditingController(text: savedUrl ?? '');
    final code = TextEditingController();
    final name = TextEditingController(text: 'HP Karyawan');
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) {
        var saving = false;
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Hubungkan perangkat karyawan'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: relay,
                    decoration: const InputDecoration(
                      labelText: 'Alamat relay',
                      hintText: 'https://relay.contoh.com',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Kode undangan',
                      hintText: 'Dari aplikasi Owner',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nama perangkat',
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
                  const SizedBox(height: 10),
                  Text(
                    'Perangkat ini akan menjadi perangkat karyawan. '
                    'Minta password awal kepada owner.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        setDialogState(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          final paired = await PairingService.instance.claim(
                            relayUrl: relay.text,
                            code: code.text,
                            deviceName: name.text,
                          );
                          if (context.mounted) Navigator.pop(context, paired);
                        } catch (failure) {
                          setDialogState(() {
                            saving = false;
                            error = '$failure';
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Hubungkan'),
              ),
            ],
          ),
        );
      },
    );
    relay.dispose();
    code.dispose();
    name.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _deviceRole = 'employee';
      _employeeMode = true;
      _error = null;
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Perangkat terhubung'),
        content: Text(
          'Akun: ${result['username']}\n'
          'Toko: ${result['store_id']}\n\n'
          'Masuk dengan password awal dari owner, lalu ganti password. '
          'Minta perangkat toko mengirim kunci agar sinkronisasi berjalan.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Mengerti'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showEmployee = _employeeDevice || (!_setup && _employeeMode);
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
                          Icons.storefront_outlined,
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
                      const SizedBox(height: 6),
                      Text(
                        _employeeDevice
                            ? 'Masuk dengan akun karyawan.'
                            : _setup
                                ? 'Buat PIN pemilik atau hubungkan perangkat karyawan.'
                                : showEmployee
                                    ? 'Masuk dengan akun karyawan.'
                                    : 'Masukkan PIN pemilik untuk melanjutkan.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 20),
                      if (showEmployee) ..._employeeFields() else ..._ownerFields(),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : showEmployee
                                ? _employeeSubmit
                                : _ownerSubmit,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_forward),
                        label: Text(
                          showEmployee
                              ? 'Masuk karyawan'
                              : _setup
                                  ? 'Simpan PIN'
                                  : 'Buka aplikasi',
                        ),
                      ),
                      if (!_setup && !_employeeDevice) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _employeeMode = !_employeeMode;
                                    _error = null;
                                  }),
                          child: Text(
                            showEmployee
                                ? 'Kembali ke pemilik'
                                : 'Masuk sebagai karyawan',
                          ),
                        ),
                      ],
                      if (_setup && !_employeeDevice) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _busy ? null : _openPairing,
                          icon: const Icon(Icons.link_outlined),
                          label: const Text('Hubungkan perangkat karyawan'),
                        ),
                      ],
                      const SizedBox(height: 8),
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
  }

  List<Widget> _ownerFields() {
    return [
      TextField(
        controller: _pin,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 12,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'PIN',
          counterText: '',
          prefixIcon: Icon(Icons.lock_outline),
        ),
        onSubmitted: (_) => _ownerSubmit(),
      ),
      if (_setup) ...[
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
          onSubmitted: (_) => _ownerSubmit(),
        ),
      ],
    ];
  }

  List<Widget> _employeeFields() {
    return [
      TextField(
        controller: _username,
        autofocus: true,
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
      ),
      const SizedBox(height: 12),
      if (!_employeeDevice) ...[
        TextField(
          controller: _employeePin,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'PIN 6 angka',
            counterText: '',
            prefixIcon: Icon(Icons.pin_outlined),
          ),
          onSubmitted: (_) => _employeeSubmit(),
        ),
      ],
    ];
  }
}
