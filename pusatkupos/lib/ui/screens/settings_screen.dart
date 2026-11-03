import 'package:flutter/material.dart';

import '../../data/backup_service.dart';
import '../../data/owner_summary_service.dart';
import '../../data/pin_service.dart';
import '../../state/app_state.dart';
import '../pin_gate.dart';
import '../widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nama;
  late final TextEditingController _alamat;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: AppState.instance.storeName);
    _alamat = TextEditingController(text: AppState.instance.storeAddress);
  }

  @override
  void dispose() {
    _nama.dispose();
    _alamat.dispose();
    super.dispose();
  }

  Future<void> _saveStore() async {
    await AppState.instance.saveStoreInfo(_nama.text, _alamat.text);
    if (!mounted) return;
    showSnack(context, 'Identitas toko disimpan.');
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    final result = await BackupService.instance.createBackup();
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _restore() async {
    final ok = await confirmAction(
      context,
      title: 'Pulihkan backup',
      message:
          'Seluruh data lokal akan diganti dengan isi backup. Buat backup terbaru dulu bila ragu.',
      confirmLabel: 'Pulihkan',
    );
    if (!ok) return;
    setState(() => _busy = true);
    final result = await BackupService.instance.restoreBackup();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      await AppState.instance.load();
      AppState.instance.touch();
      _nama.text = AppState.instance.storeName;
      _alamat.text = AppState.instance.storeAddress;
    }
    if (!mounted) return;
    showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _changePin() async {
    final oldPin = TextEditingController();
    final newPin = TextEditingController();
    final confirm = TextEditingController();
    final success = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ganti PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN lama'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newPin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN baru'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Ulangi PIN baru'),
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
              if (newPin.text.trim().length < 4 ||
                  newPin.text.trim() != confirm.text.trim()) {
                return;
              }
              final changed = await PinService.instance.change(
                oldPin: oldPin.text.trim(),
                newPin: newPin.text.trim(),
              );
              if (context.mounted) Navigator.pop(context, changed);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    oldPin.dispose();
    newPin.dispose();
    confirm.dispose();
    if (!mounted) return;
    showSnack(
      context,
      success == true ? 'PIN diperbarui.' : 'PIN gagal diubah.',
      error: success != true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Pengaturan',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Identitas toko',
          child: Column(
            children: [
              TextField(
                controller: _nama,
                decoration: const InputDecoration(labelText: 'Nama toko'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _alamat,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Alamat'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saveStore,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Simpan'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Tampilan',
          child: AnimatedBuilder(
            animation: appState,
            builder: (context, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('Sistem'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Terang'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Gelap'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {appState.themeMode},
              onSelectionChanged: (value) =>
                  appState.setThemeMode(value.first),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Keamanan',
          subtitle: 'PIN pemilik melindungi pembukaan aplikasi.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _changePin,
              icon: const Icon(Icons.password_outlined),
              label: const Text('Ganti PIN'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Backup lokal',
          subtitle:
              'Menyimpan seluruh database ke berkas ZIP. Restore mengganti data lokal.',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _backup,
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Buat backup'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _restore,
                      icon: const Icon(Icons.unarchive_outlined),
                      label: const Text('Restore'),
                    ),
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 14),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final path = await OwnerSummaryService.instance.export();
                      if (!context.mounted) return;
                      showSnack(
                        context,
                        path == null
                            ? 'Ekspor dibatalkan.'
                            : 'Ringkasan owner disimpan.',
                      );
                    } catch (error) {
                      if (!context.mounted) return;
                      showSnack(
                        context,
                        'Ekspor gagal: $error',
                        error: true,
                      );
                    }
                  },
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Ekspor ringkasan owner'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Sesi',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                AppState.instance.setOperator(null);
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const PinGate()),
                  (_) => false,
                );
              },
              icon: const Icon(Icons.logout),
              label: const Text('Keluar'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Tentang',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PusatkuPOS · Fase 2 Flutter'),
              const SizedBox(height: 4),
              Text(
                'Database lokal SQLite. Tidak memerlukan internet.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
