import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/backup_service.dart';
import '../../data/owner_summary_service.dart';
import '../../data/pin_service.dart';
import '../../state/app_state.dart';
import '../pin_gate.dart';
import '../widgets.dart';
import 'followup_settings_screen.dart';
import 'printer_settings_screen.dart';
import 'receipt_settings_screen.dart';
import 'stores_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nama;
  late final TextEditingController _alamat;
  final _garansiBulan = TextEditingController(text: '1');
  final _garansiSyarat = TextEditingController();
  bool _fiturKaryawan = true;
  bool _fiturSupplier = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: AppState.instance.storeName);
    _alamat = TextEditingController(text: AppState.instance.storeAddress);
    _loadGaransi();
  }

  Future<void> _loadGaransi() async {
    final db = AppDatabase.instance;
    final bulan = await db.getSetting('garansi.default_bulan') ?? '1';
    final syarat = await db.getSetting('garansi.syarat') ?? '';
    final karyawan = await db.getSetting('fitur.karyawan') ?? '1';
    final supplier = await db.getSetting('fitur.supplier') ?? '1';
    if (!mounted) return;
    _garansiBulan.text = bulan;
    _garansiSyarat.text = syarat;
    setState(() {
      _fiturKaryawan = karyawan == '1';
      _fiturSupplier = supplier == '1';
    });
  }

  Future<void> _saveGaransi() async {
    final bulan = int.tryParse(_garansiBulan.text.trim()) ?? 1;
    if (bulan < 1) {
      showSnack(context, 'Durasi garansi minimal 1 bulan.', error: true);
      return;
    }
    await AppDatabase.instance
        .setSetting('garansi.default_bulan', '$bulan');
    await AppDatabase.instance
        .setSetting('garansi.syarat', _garansiSyarat.text.trim());
    if (!mounted) return;
    showSnack(context, 'Pengaturan garansi disimpan.');
  }

  @override
  void dispose() {
    _nama.dispose();
    _alamat.dispose();
    _garansiBulan.dispose();
    _garansiSyarat.dispose();
    super.dispose();
  }

  Future<void> _saveStore() async {
    await AppState.instance.saveStoreInfo(_nama.text, _alamat.text);
    if (!mounted) return;
    showSnack(context, 'Identitas toko disimpan.');
  }

  Future<void> _backup() async {
    if (!AppState.instance.can('backup')) {
      showSnack(context, 'Izin backup tidak tersedia.', error: true);
      return;
    }
    setState(() => _busy = true);
    final result = await BackupService.instance.createBackup();
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _restore() async {
    if (!AppState.instance.can('backup')) {
      showSnack(context, 'Izin restore tidak tersedia.', error: true);
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Pulihkan backup',
      message:
          'Seluruh data lokal akan diganti dengan isi backup. Restore ke '
          'perangkat kedua atau perangkat lama dapat menyebabkan nomor nota '
          'dan antrean sinkron bentrok. Prefix nota baru akan dibuat; jalankan '
          'bootstrap sebelum sinkronisasi. Buat backup terbaru dulu bila ragu.',
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
              if (newPin.text.trim().length < 6 ||
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
          title: 'Toko',
          subtitle:
              'Setiap toko memakai database terpisah. Tambah toko khusus '
              'Premium.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('Kelola toko'),
            subtitle: const Text('Tambah, pilih, dan ganti toko aktif'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StoresScreen()),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Struk dan printer',
          subtitle: 'Atur bagian struk serta printer thermal jaringan.',
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Pengaturan struk'),
                subtitle: const Text('Pilih bagian yang tampil di nota'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ReceiptSettingsScreen(),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.print_outlined),
                title: const Text('Printer thermal'),
                subtitle: const Text('Printer ESC/POS lewat jaringan lokal'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PrinterSettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Garansi',
          subtitle: 'Nilai bawaan saat kasir membuat nota baru.',
          child: Column(
            children: [
              TextField(
                controller: _garansiBulan,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Durasi garansi (bulan)',
                  helperText: '1 bulan = 30 hari',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _garansiSyarat,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Syarat garansi standar',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saveGaransi,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Simpan'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Karyawan',
          subtitle:
              'Jika dimatikan, nama kasir dan mekanik tidak dicetak di struk.',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tampilkan data karyawan'),
            value: _fiturKaryawan,
            onChanged: (value) async {
              setState(() => _fiturKaryawan = value);
              await AppDatabase.instance
                  .setSetting('fitur.karyawan', value ? '1' : '0');
            },
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Supplier',
          subtitle:
              'Jika dimatikan, pencatatan supplier dan follow up reseller '
              'disembunyikan.',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aktifkan fitur supplier'),
            value: _fiturSupplier,
            onChanged: (value) async {
              setState(() => _fiturSupplier = value);
              await AppDatabase.instance
                  .setSetting('fitur.supplier', value ? '1' : '0');
            },
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Follow up',
          subtitle: 'Jam, interval, dan batas pesan WhatsApp.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Pengaturan follow up'),
            subtitle: const Text('Kuota gratis 20 kredit WhatsApp'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const FollowupSettingsScreen(),
              ),
            ),
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
