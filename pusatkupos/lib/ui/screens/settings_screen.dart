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
import 'escrow_screen.dart';
import 'followup_settings_screen.dart';
import 'opening_balance_screen.dart';
import 'pajak_screen.dart';
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
      helpText: 'Jam cadangan otomatis',
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
      showSnack(
        context,
        'Kata sandi cadangan minimal 8 karakter.',
        error: true,
      );
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
      showSnack(context, 'Pengaturan cadangan disimpan.');
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        'Gagal menyimpan pengaturan cadangan. $error',
        error: true,
      );
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
      if (mounted) {
        showSnack(context, 'Cadangan gagal dibuat. $error', error: true);
      }
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
                  labelText: 'Kata sandi cadangan',
                  errorText: error,
                  helperText: requiredPass
                      ? 'Wajib diisi, minimal 8 karakter.'
                      : 'Kosongkan untuk cadangan khusus perangkat ini.',
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
                  setLocal(
                    () => error = 'Kata sandi minimal 8 karakter.',
                  );
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Pakai kata sandi'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askOwnerPin({
    String reason =
        'Masukkan PIN pemilik untuk menyalin kata sandi cadangan. '
        'Kata sandi tidak ditampilkan di layar.',
  }) async {
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
              Text(reason),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'PIN pemilik',
                  helperText: 'PIN yang Anda buat saat membuka aplikasi.',
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
                  setLocal(() => error = 'Isi PIN pemilik terlebih dahulu.');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('Periksa PIN'),
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
        'Atur PIN pemilik dulu agar kata sandi cadangan bisa dibuka.',
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
        final value = await BackupService.instance.autoPassphrase();
        await Clipboard.setData(ClipboardData(text: value));
        if (!mounted) return;
        showSnack(
          context,
          'Kata sandi cadangan disalin. Hapus dari clipboard setelah '
          'dipakai.',
        );
      case PinVerification.weakLegacyPin:
        showSnack(
          context,
          'Perbarui PIN ke minimal 6 angka sebelum membuka kata sandi '
          'cadangan.',
          error: true,
        );
      case PinVerification.locked:
        showSnack(
          context,
          'PIN terkunci sementara karena terlalu banyak percobaan. '
          'Tunggu sebentar, lalu coba lagi.',
          error: true,
        );
      case PinVerification.wrong:
        showSnack(
          context,
          'PIN pemilik tidak cocok. Periksa lagi.',
          error: true,
        );
    }
  }

  Future<void> _backup() async {
    if (!AppState.instance.can('backup')) {
      showSnack(
        context,
        'Akun ini tidak punya izin membuat cadangan.',
        error: true,
      );
      return;
    }
    final passphrase = await _askBackupPassphrase(
      title: 'Buat cadangan manual',
      help:
          'Isi kata sandi agar cadangan bisa dipulihkan di perangkat lain. '
          'Tanpa kata sandi, cadangan tetap terkunci dengan kunci perangkat '
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
      if (mounted) {
        showSnack(context, 'Cadangan gagal dibuat. $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (!AppState.instance.can('backup')) {
      showSnack(
        context,
        'Akun ini tidak punya izin memulihkan cadangan.',
        error: true,
      );
      return;
    }
    if (!AppState.instance.isOwner) {
      showSnack(
        context,
        'Hanya pemilik yang bisa memulihkan cadangan.',
        error: true,
      );
      return;
    }
    final path = await BackupService.instance.pickBackupArchive();
    if (path == null || !mounted) return;
    if (AppState.instance.pinConfigured) {
      final pin = await _askOwnerPin(
        reason: 'Memulihkan cadangan akan mengganti seluruh data di perangkat '
            'ini. Masukkan PIN pemilik untuk melanjutkan.',
      );
      if (pin == null || !mounted) return;
      final verification = await PinService.instance.verifyDetailed(pin);
      if (!mounted) return;
      if (verification != PinVerification.ok &&
          verification != PinVerification.weakLegacyPin) {
        final message = switch (verification) {
          PinVerification.locked =>
            'PIN terkunci sementara. Tunggu sebentar, lalu coba lagi.',
          PinVerification.wrong => 'PIN pemilik tidak cocok. Periksa lagi.',
          _ => 'PIN pemilik tidak dapat diverifikasi.',
        };
        showSnack(context, message, error: true);
        return;
      }
    }
    final ok = await confirmAction(
      context,
      title: 'Pulihkan cadangan',
      message:
          'Seluruh data di perangkat ini akan diganti dengan isi cadangan. '
          'Memulihkan ke perangkat kedua atau perangkat lama bisa membuat '
          'nomor nota dan data kiriman bentrok. Kode perangkat baru akan '
          'dibuat, jadi jalankan penyiapan perangkat sebelum sinkronisasi. '
          'Buat cadangan terbaru dulu bila ragu.',
      confirmLabel: 'Pulihkan',
    );
    if (!ok || !mounted) return;
    final needsPass = await BackupService.instance.needsPassphrase(path);
    if (!mounted) return;
    final passphrase = await _askBackupPassphrase(
      title: 'Kata sandi cadangan',
      help: needsPass
          ? 'Cadangan ini dikunci kata sandi yang dibuat saat membuat '
              'cadangan.'
          : 'Kosongkan bila cadangan dibuat tanpa kata sandi.',
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
        await AppState.instance.reloadStore();
        AppState.instance.touch();
        _nama.text = AppState.instance.storeName;
        _alamat.text = AppState.instance.storeAddress;
      }
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) showSnack(context, 'Pemulihan gagal: $error', error: true);
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
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Ganti PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: oldPin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'PIN lama',
                    helperText: 'PIN yang sekarang dipakai.',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: newPin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'PIN baru',
                    helperText: 'Minimal 6 angka. Jangan pakai tanggal lahir.',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Ulangi PIN baru',
                    errorText: error,
                  ),
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
                  if (newPin.text.trim().length < 6) {
                    setLocal(
                      () => error = 'PIN baru minimal 6 angka.',
                    );
                    return;
                  }
                  if (newPin.text.trim() != confirm.text.trim()) {
                    setLocal(
                      () => error = 'Ulangi PIN belum sama dengan PIN baru.',
                    );
                    return;
                  }
                  final changed = await PinService.instance.change(
                    oldPin: oldPin.text.trim(),
                    newPin: newPin.text.trim(),
                  );
                  if (context.mounted) Navigator.pop(context, changed);
                },
                child: const Text('Simpan PIN baru'),
              ),
            ],
          ),
        );
      },
    );
    oldPin.dispose();
    newPin.dispose();
    confirm.dispose();
    if (!mounted) return;
    showSnack(
      context,
      success == true
          ? 'PIN diperbarui.'
          : 'PIN belum diubah. Periksa PIN lama Anda.',
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
                decoration: const InputDecoration(
                  labelText: 'Nama toko',
                  hintText: 'Contoh: Bengkel Jaya Motor',
                  helperText: 'Nama ini tampil di struk dan laporan.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _alamat,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Alamat',
                  hintText: 'Contoh: Jl. Merdeka No. 10, Bandung',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saveStore,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Simpan identitas'),
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
            subtitle: const Text(
              'Tambah toko baru atau pindah ke toko lain',
            ),
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
                subtitle: const Text(
                  'Atur bagian yang tampil di struk pelanggan',
                ),
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
                subtitle: const Text(
                  'Hubungkan printer thermal lewat jaringan toko',
                ),
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
                  hintText: 'Contoh: 1',
                  helperText: '1 bulan = 30 hari',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _garansiSyarat,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Syarat garansi standar',
                  hintText:
                      'Contoh: tidak berlaku untuk kerusakan akibat kecelakaan',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saveGaransi,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Simpan garansi'),
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
          title: 'PPN',
          subtitle: 'Rekap bulanan dan pencatatan pembayaran PPN.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.percent_outlined),
            title: const Text('Rekap PPN'),
            subtitle: const Text(
              'PPN keluaran, masukan, diserap, dan pembayaran per masa',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PajakScreen()),
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
                  'Estimasi, order kerja, supplier, tindak lanjut, unit, WhatsApp',
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
          title: 'Tindak lanjut',
          subtitle: 'Jam, interval, dan batas pesan WhatsApp.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Pengaturan tindak lanjut'),
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
                  helperText:
                      'Aplikasi terkunci setelah tidak dipakai beberapa saat.',
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
          title: 'Pemulihan kunci',
          subtitle:
              'Frasa pemulihan 12 kata dan bagian kunci admin untuk '
              'memulihkan kunci bila perangkat atau akun Google hilang.',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key_outlined),
            title: const Text('Kelola pemulihan kunci'),
            subtitle: const Text('Buat, verifikasi, dan pulihkan kunci'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EscrowScreen()),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Cadangan data',
          subtitle:
              'Menyimpan seluruh data toko ke satu berkas ZIP. Memulihkan '
              'cadangan akan mengganti data di perangkat ini.',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _backup,
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Buat cadangan'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _restore,
                      icon: const Icon(Icons.unarchive_outlined),
                      label: const Text('Pulihkan cadangan'),
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
                    if (!AppState.instance.isOwner) {
                      showSnack(
                        context,
                        'Hanya pemilik yang bisa mengekspor ringkasan.',
                        error: true,
                      );
                      return;
                    }
                    final pin = await _askOwnerPin(
                      reason:
                          'Masukkan PIN pemilik untuk mengekspor ringkasan '
                          'pemilik.',
                    );
                    if (pin == null || !mounted) return;
                    try {
                      final path = await OwnerSummaryService.instance.export(
                        actor: AppState.instance.requireOperator,
                        pin: pin,
                      );
                      if (!context.mounted) return;
                      showSnack(
                        context,
                        path == null
                            ? 'Ekspor dibatalkan.'
                            : 'Ringkasan pemilik tersimpan.',
                      );
                    } catch (error) {
                      if (!context.mounted) return;
                      showSnack(
                        context,
                        'Ekspor gagal. $error',
                        error: true,
                      );
                    }
                  },
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Ekspor ringkasan pemilik'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Cadangan otomatis',
          subtitle:
              'Menyimpan cadangan harian ke folder aplikasi. Unggah ke '
              'Telegram opsional.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (kIsWeb)
                const Text(
                  'Cadangan otomatis tersedia di Android dan desktop. Di '
                  'versi web, gunakan tombol Buat cadangan.',
                )
              else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Aktifkan cadangan harian'),
                  subtitle: const Text(
                    'Cadangan dibuat saat aplikasi dibuka bila jadwal '
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
                  title: const Text('Jam cadangan'),
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
                    'Bot mengirim berkas ZIP cadangan ke chat pemilik.',
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
                      hintText: 'Contoh: 123456789',
                      helperText:
                          'ID chat atau grup yang menerima berkas cadangan.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _backupToken,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Token bot Telegram',
                      hintText: 'Tempel token dari BotFather',
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
                    labelText: 'Kata sandi cadangan baru (opsional)',
                    helperText: _backupPassphraseConfigured
                        ? 'Kata sandi tersimpan tidak ditampilkan. Isi hanya '
                              'bila ingin menggantinya, minimal 8 karakter.'
                        : 'Belum ada kata sandi tersimpan. Isi minimal 8 '
                              'karakter, atau kosongkan bila tidak perlu.',
                    suffixIcon: _backupPassphraseConfigured
                        ? IconButton(
                            tooltip:
                                'Salin kata sandi cadangan (perlu PIN pemilik)',
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
                      'Telegram hanya menerima arsip terenkripsi. Kata sandi '
                      'tidak bisa dibaca dari layar. Tanpa kata sandi ini, '
                      'cadangan tidak bisa dipulihkan di perangkat lain.',
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
                        label: const Text('Simpan pengaturan'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _backupNow,
                        icon: const Icon(Icons.backup_outlined),
                        label: const Text('Buat cadangan sekarang'),
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
                  'Status cadangan',
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
                    'Kendala terakhir: ${_backupStatus['last_error']}',
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
                    'Belum ada cadangan dalam 2 hari terakhir. Periksa folder '
                    'cadangan atau jalankan Buat cadangan sekarang.',
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
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Keluar akun?'),
                        content: Text(
                          AppState.instance.isOwner
                              ? 'Sesi ditutup, tetapi data toko, data yang belum terkirim, '
                                  'dan PIN pemilik tetap tersimpan di '
                                  'perangkat ini. Buka kembali dengan PIN '
                                  'yang sama.'
                              : 'Sesi karyawan ditutup. Data toko dan data yang belum '
                                  'terkirim tetap tersimpan untuk pemilik.',
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
                if (AppState.instance.isOwner)
                  OutlinedButton.icon(
                    onPressed: () => resetDeviceSession(context),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Reset perangkat'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Tentang',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PusatkuPOS'),
              const SizedBox(height: 4),
              Text(
                'Aplikasi kasir dan stok untuk UMKM. Data tersimpan di perangkat ini dan tidak memerlukan internet.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
