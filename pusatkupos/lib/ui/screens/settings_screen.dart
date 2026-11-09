import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/app_database.dart';
import '../../data/backup_service.dart';
import '../../data/owner_summary_service.dart';
import '../../data/pin_service.dart';
import '../../state/app_state.dart';
import '../entry_gate.dart';
import '../pin_gate.dart';
import '../widgets.dart';
import 'diagnostics_screen.dart';
import 'followup_settings_screen.dart';
import 'opening_balance_screen.dart';
import 'printer_settings_screen.dart';
import 'receipt_settings_screen.dart';
import 'store_features_screen.dart';
import 'store_settings_screen.dart';
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
  final _backupChat = TextEditingController();
  final _backupToken = TextEditingController();
  final _backupPassphrase = TextEditingController();
  bool _backupPassphraseConfigured = false;
  bool _fiturKaryawan = true;
  bool _busy = false;
  bool _backupAuto = true;
  String _backupJam = '02:00';
  bool _backupTelegram = false;
  bool _backupTokenConfigured = false;
  bool _backupBusy = false;
  int _autoLockMinutes = 5;
  Map<String, String?> _backupStatus = const {};

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: AppState.instance.storeName);
    _alamat = TextEditingController(text: AppState.instance.storeAddress);
    _loadGaransi();
    _loadBackup();
    _loadSecurity();
  }

  Future<void> _loadBackup() async {
    final settings = await BackupService.instance.loadSettings();
    final status = await BackupService.instance.status();
    if (!mounted) return;
    setState(() {
      _backupAuto = settings.autoEnabled;
      _backupJam = settings.jam;
      _backupTelegram = settings.telegramEnabled;
      _backupChat.text = settings.telegramChatId;
      _backupTokenConfigured = settings.telegramTokenConfigured;
      _backupPassphraseConfigured = settings.passphraseConfigured;
      _backupStatus = status;
    });
  }

  Future<void> _loadSecurity() async {
    final raw =
        await AppDatabase.instance.getSetting('security.auto_lock_minutes');
    final minutes = int.tryParse(raw ?? '') ?? 5;
    if (!mounted) return;
    setState(() => _autoLockMinutes = minutes);
  }

  Future<void> _pickBackupTime() async {
    final parts = _backupJam.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 2,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      ),
      helpText: 'Jam backup otomatis',
    );
    if (picked == null) return;
    setState(() {
      _backupJam = '${picked.hour.toString().padLeft(2, '0')}:'
          '${picked.minute.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _saveBackup() async {
    final passphrase = _backupPassphrase.text.trim();
    if (passphrase.isNotEmpty && passphrase.length < 8) {
      showSnack(context, 'Passphrase backup minimal 8 karakter.', error: true);
      return;
    }
    setState(() => _backupBusy = true);
    try {
      await BackupService.instance.saveSettings(
        autoEnabled: _backupAuto,
        jam: _backupJam,
        telegramEnabled: _backupTelegram,
        telegramChatId: _backupChat.text,
        telegramToken: _backupToken.text,
        autoPassphrase: _backupPassphrase.text,
      );
      _backupToken.clear();
      _backupPassphrase.clear();
      await _loadBackup();
      if (!mounted) return;
      showSnack(context, 'Pengaturan backup disimpan.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Gagal menyimpan backup: $error', error: true);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _backupNow() async {
    setState(() => _backupBusy = true);
    try {
      final result = await BackupService.instance.createAutomaticBackup();
      await _loadBackup();
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) showSnack(context, 'Backup gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  String _friendlyTime(String? iso) {
    final parsed = DateTime.tryParse(iso ?? '');
    if (parsed == null) return '-';
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _loadGaransi() async {
    final db = AppDatabase.instance;
    final bulan = await db.getSetting('garansi.default_bulan') ?? '1';
    final syarat = await db.getSetting('garansi.syarat') ?? '';
    final karyawan = await db.getSetting('fitur.karyawan') ?? '1';
    if (!mounted) return;
    _garansiBulan.text = bulan;
    _garansiSyarat.text = syarat;
    setState(() {
      _fiturKaryawan = karyawan == '1';
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
    _backupChat.dispose();
    _backupToken.dispose();
    _backupPassphrase.dispose();
    super.dispose();
  }

  Future<void> _saveStore() async {
    await AppState.instance.saveStoreInfo(_nama.text, _alamat.text);
    if (!mounted) return;
    showSnack(context, 'Identitas toko disimpan.');
  }

  /// Mengembalikan `null` bila dialog dibatalkan, string kosong bila pemilik
  /// memilih backup tanpa passphrase.
  Future<String?> _askBackupPassphrase({
    required String title,
    required String help,
    bool requiredPass = false,
  }) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                help,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  errorText: error,
                  helperText: requiredPass
                      ? 'Wajib, minimal 8 karakter.'
                      : 'Kosongkan untuk backup khusus perangkat ini.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (requiredPass && value.length < 8) {
                  setLocal(() => error = 'Passphrase minimal 8 karakter.');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Lanjut'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askOwnerPin() async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Konfirmasi pemilik'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Masukkan PIN pemilik untuk menyalin passphrase backup. '
                'Passphrase tidak ditampilkan di layar.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'PIN pemilik',
                  errorText: error,
                ),
                onSubmitted: (_) =>
                    Navigator.pop(context, controller.text.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setLocal(() => error = 'Masukkan PIN pemilik.');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Lanjut'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _copyStoredPassphrase() async {
    if (!await PinService.instance.isConfigured()) {
      if (!mounted) return;
      showSnack(
        context,
        'Atur PIN pemilik terlebih dahulu untuk membuka passphrase.',
        error: true,
      );
      return;
    }
    final pin = await _askOwnerPin();
    if (pin == null || !mounted) return;
    final verification = await PinService.instance.verifyDetailed(pin);
    if (!mounted) return;
    switch (verification) {
      case PinVerification.ok:
      case PinVerification.weakLegacyPin:
        final value = await BackupService.instance.autoPassphrase();
        await Clipboard.setData(ClipboardData(text: value));
        if (!mounted) return;
        showSnack(
          context,
          'Passphrase disalin. Hapus clipboard setelah dipakai.',
        );
      case PinVerification.locked:
        showSnack(
          context,
          'Terlalu banyak percobaan. Coba lagi nanti.',
          error: true,
        );
      case PinVerification.wrong:
        showSnack(context, 'PIN pemilik salah.', error: true);
    }
  }

  Future<void> _backup() async {
    if (!AppState.instance.can('backup')) {
      showSnack(context, 'Izin backup tidak tersedia.', error: true);
      return;
    }
    final passphrase = await _askBackupPassphrase(
      title: 'Backup manual',
      help:
          'Isi passphrase agar backup dapat dipulihkan di perangkat lain. '
          'Tanpa passphrase, backup tetap terenkripsi dengan kunci perangkat '
          'ini dan hanya bisa dipulihkan di sini.',
    );
    if (passphrase == null) return;
    setState(() => _busy = true);
    try {
      final result = await BackupService.instance.createBackup(
        passphrase: passphrase,
      );
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) showSnack(context, 'Backup gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (!AppState.instance.can('backup')) {
      showSnack(context, 'Izin restore tidak tersedia.', error: true);
      return;
    }
    final path = await BackupService.instance.pickBackupArchive();
    if (path == null || !mounted) return;
    final ok = await confirmAction(
      context,
      title: 'Pulihkan backup',
      message:
          'Seluruh data lokal akan diganti dengan isi backup. Restore ke '
          'perangkat kedua atau perangkat lama dapat menyebabkan nomor nota '
          'dan antrean sinkron bentrok. Kode perangkat baru akan dibuat; '
          'jalankan bootstrap sebelum sinkronisasi. Buat backup terbaru dulu '
          'bila ragu.',
      confirmLabel: 'Pulihkan',
    );
    if (!ok || !mounted) return;
    final needsPass = await BackupService.instance.needsPassphrase(path);
    if (!mounted) return;
    final passphrase = await _askBackupPassphrase(
      title: 'Passphrase backup',
      help: needsPass
          ? 'Backup ini terkunci passphrase yang dibuat saat backup.'
          : 'Kosongkan bila backup dibuat tanpa passphrase pemilik.',
      requiredPass: needsPass,
    );
    if (passphrase == null) return;
    setState(() => _busy = true);
    try {
      final result = await BackupService.instance.restoreBackup(
        path: path,
        passphrase: passphrase.isEmpty ? null : passphrase,
      );
      if (!mounted) return;
      if (result.ok) {
        await AppState.instance.load();
        AppState.instance.touch();
        _nama.text = AppState.instance.storeName;
        _alamat.text = AppState.instance.storeAddress;
      }
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) showSnack(context, 'Restore gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    final lastBackup =
        DateTime.tryParse(_backupStatus['last_local_at'] ?? '');
    final backupStale = _backupAuto &&
        (lastBackup == null ||
            DateTime.now().difference(lastBackup) > const Duration(days: 2));
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
              'Setiap toko memakai database terpisah. Akun gratis memakai 1 '
              'toko; toko tambahan memerlukan Premium dan login Google.',
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
          title: 'Aturan transaksi',
          subtitle:
              'Jenis transaksi, tahap order, persetujuan kasir, dan izin peran.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune_outlined),
            title: const Text('Atur transaksi dan izin'),
            subtitle: const Text('Preset, persetujuan, dan hak tiap peran'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StoreSettingsScreen()),
            ),
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
          title: 'Fitur dan data toko',
          subtitle:
              'Saklar modul opsional per toko dan saldo awal usaha. '
              'Data lama tidak dihapus saat modul dimatikan.',
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.toggle_on_outlined),
                title: const Text('Fitur toko'),
                subtitle: const Text(
                  'Estimasi, order kerja, supplier, follow up, unit, WhatsApp',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const StoreFeaturesScreen(),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_balance_outlined),
                title: const Text('Saldo awal toko'),
                subtitle: const Text('Stok, utang supplier, piutang pelanggan'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OpeningBalanceScreen(),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('Diagnostik perangkat'),
                subtitle: const Text(
                  'Integritas database, antrean sinkron, ekspor log',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DiagnosticsScreen(),
                  ),
                ),
              ),
            ],
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
          subtitle:
              'PIN pemilik melindungi pembukaan aplikasi dan kunci otomatis.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _autoLockMinutes,
                decoration: const InputDecoration(
                  labelText: 'Kunci otomatis',
                  helperText: 'Aplikasi terkunci setelah tidak dipakai.',
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Nonaktif')),
                  DropdownMenuItem(value: 1, child: Text('1 menit')),
                  DropdownMenuItem(value: 2, child: Text('2 menit')),
                  DropdownMenuItem(value: 5, child: Text('5 menit')),
                  DropdownMenuItem(value: 10, child: Text('10 menit')),
                  DropdownMenuItem(value: 30, child: Text('30 menit')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _autoLockMinutes = value);
                  await AppState.instance.setAutoLockMinutes(value);
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _changePin,
                      icon: const Icon(Icons.password_outlined),
                      label: const Text('Ganti PIN'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => lockNow(context),
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Kunci sekarang'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      AppDatabase.instance.databaseEncrypted
                          ? Icons.enhanced_encryption_outlined
                          : Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppDatabase.instance.encryptionNote,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
          title: 'Backup otomatis',
          subtitle:
              'Menyimpan backup harian ke folder aplikasi. Unggah Telegram '
              'opsional.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (kIsWeb)
                const Text(
                  'Backup otomatis tersedia di Android/desktop. Di versi web '
                  'gunakan tombol Buat backup manual.',
                )
              else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Aktifkan backup harian'),
                  subtitle: const Text(
                    'Backup disusulkan saat aplikasi dibuka bila jadwal '
                    'terlewat.',
                  ),
                  value: _backupAuto,
                  onChanged: _backupBusy
                      ? null
                      : (value) => setState(() => _backupAuto = value),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Jam backup'),
                  trailing: Text(_backupJam),
                  onTap: _backupBusy ? null : _pickBackupTime,
                ),
                if ((_backupStatus['folder'] ?? '').isNotEmpty)
                  SelectableText(
                    'Folder: ${_backupStatus['folder']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Unggah ke Telegram'),
                  subtitle: const Text(
                    'Bot mengirim berkas ZIP backup ke chat pemilik.',
                  ),
                  value: _backupTelegram,
                  onChanged: _backupBusy
                      ? null
                      : (value) => setState(() => _backupTelegram = value),
                ),
                if (_backupTelegram) ...[
                  TextField(
                    controller: _backupChat,
                    decoration: const InputDecoration(
                      labelText: 'Chat ID Telegram',
                      helperText: 'ID chat atau grup penerima backup.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _backupToken,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Bot token',
                      helperText: _backupTokenConfigured
                          ? 'Token tersimpan. Kosongkan untuk mempertahankan.'
                          : 'Belum ada token tersimpan.',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Token disimpan di penyimpanan aman perangkat.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: _backupPassphrase,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Passphrase backup baru (opsional)',
                    helperText: _backupPassphraseConfigured
                        ? 'Passphrase tersimpan tidak ditampilkan. Isi hanya '
                              'bila ingin menggantinya (minimal 8 karakter).'
                        : 'Belum ada passphrase tersimpan. Minimal 8 karakter; '
                              'kosongkan bila tidak diperlukan.',
                    suffixIcon: _backupPassphraseConfigured
                        ? IconButton(
                            tooltip: 'Salin passphrase (perlu PIN pemilik)',
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: _backupBusy
                                ? null
                                : _copyStoredPassphrase,
                          )
                        : null,
                  ),
                ),
                if (_backupTelegram)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Telegram hanya menerima arsip terenkripsi. Passphrase '
                      'tidak dapat dibaca dari layar; tanpa passphrase ini, '
                      'backup tidak dapat dipulihkan di perangkat lain.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _backupBusy ? null : _saveBackup,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Simpan'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _backupNow,
                        icon: const Icon(Icons.backup_outlined),
                        label: const Text('Backup sekarang'),
                      ),
                    ),
                  ],
                ),
                if (_backupBusy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
                const Divider(height: 24),
                Text(
                  'Status backup',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Lokal terakhir: '
                  '${_friendlyTime(_backupStatus['last_local_at'])}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'Telegram terakhir: '
                  '${_friendlyTime(_backupStatus['last_telegram_at'])}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if ((_backupStatus['last_error'] ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Error terakhir: ${_backupStatus['last_error']}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                if ((_backupStatus['telegram_error'] ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Telegram: ${_backupStatus['telegram_error']}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (backupStale) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Belum ada backup dalam 2 hari terakhir. Periksa folder '
                    'backup atau jalankan Backup sekarang.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Sesi',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Keluar akun?'),
                    content: const Text(
                      'Data toko tetap tersimpan di perangkat ini. '
                      'Untuk masuk kembali Anda perlu akun dan PIN.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Batal'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Keluar'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await signOutToOnboarding(context);
                }
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
