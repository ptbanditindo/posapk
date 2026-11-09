import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/startup.dart';
import '../data/app_database.dart';
import '../data/backup_platform_stub.dart'
    if (dart.library.io) '../data/backup_platform_io.dart'
    as backup_platform;
import '../data/backup_service.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Root aplikasi saat inisialisasi gagal. Semua tindakan di sini eksplisit;
/// tidak ada database yang dihapus tanpa persetujuan pengguna.
class StartupRecoveryApp extends StatefulWidget {
  const StartupRecoveryApp({super.key, required this.error});

  final Object error;

  @override
  State<StartupRecoveryApp> createState() => _StartupRecoveryAppState();
}

class _StartupRecoveryAppState extends State<StartupRecoveryApp> {
  late Object _error = widget.error;
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    final error = await StartupService.instance.boot();
    if (!mounted) return;
    if (error == null) {
      runApp(const PusatkuApp());
      return;
    }
    setState(() {
      _error = error;
      _busy = false;
    });
  }

  Future<void> _openSafeMode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Buka mode aman?'),
        content: const Text(
          'Database yang gagal dibuka akan dipindahkan ke berkas '
          '"corrupt-..." di folder aplikasi, lalu aplikasi mulai dengan '
          'database kosong. Berkas lama tidak dihapus dan tetap dapat '
          'diekspor atau dipulihkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Buka mode aman'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final error = await StartupService.instance.boot(quarantine: true);
    if (!mounted) return;
    if (error == null) {
      runApp(const PusatkuApp());
      return;
    }
    setState(() {
      _error = error;
      _busy = false;
    });
  }

  Future<void> _restoreBackup() async {
    final path = await BackupService.instance.pickBackupArchive();
    if (path == null || !mounted) return;
    final needsPass = await BackupService.instance.needsPassphrase(path);
    final passphrase = await _askPassphrase(needsPass);
    if (passphrase == null || !mounted) return;
    setState(() => _busy = true);
    // Restore membutuhkan database yang dapat dibuka untuk membaca pengaturan
    // lama. Database rusak dikarantina lebih dulu, bukan dihapus.
    final bootError = await StartupService.instance.boot(quarantine: true);
    if (!mounted) return;
    if (bootError != null) {
      setState(() {
        _error = bootError;
        _busy = false;
      });
      return;
    }
    final result = await BackupService.instance.restoreBackup(
      path: path,
      passphrase: passphrase.isEmpty ? null : passphrase,
    );
    if (!mounted) return;
    if (result.ok) {
      // Setelah restore, database aktif berubah: muat ulang pengaturan,
      // fitur, dan status PIN sebelum membuka gerbang sesi.
      await AppState.instance.load();
      AppState.instance.setOperator(null);
      runApp(const PusatkuApp());
      return;
    }
    setState(() {
      _error = result.message;
      _busy = false;
    });
  }

  Future<String?> _askPassphrase(bool required) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Passphrase backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              required
                  ? 'Backup ini terkunci passphrase yang dibuat saat backup.'
                  : 'Kosongkan bila backup dibuat tanpa passphrase pemilik.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Passphrase'),
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
            child: const Text('Pulihkan'),
          ),
        ],
      ),
    );
    final value = controller.text;
    controller.dispose();
    if (ok != true) return null;
    if (required && value.trim().isEmpty) return null;
    return value;
  }

  Future<void> _exportRawDatabase() async {
    try {
      final db = AppDatabase.instance;
      if (!db.isOpen) {
        await StartupService.instance.boot();
      }
      final path = db.databasePath;
      final bytes = await backup_platform.readFile(path);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final target = await FilePicker.saveFile(
        dialogTitle: 'Simpan berkas database',
        fileName: 'pusatkupos_database_$stamp.db',
        bytes: Uint8List.fromList(bytes),
        mimeType: 'application/octet-stream',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            target == null
                ? 'Ekspor dibatalkan.'
                : 'Berkas database disimpan. Jangan bagikan ke pihak lain.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ekspor gagal: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PusatkuPOS',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 48,
                            color: scheme.error,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Aplikasi gagal dibuka',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Data tidak dihapus. Pilih tindakan pemulihan di '
                            'bawah; jika ragu, ekspor berkas database lebih '
                            'dulu lalu hubungi dukungan.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Versi aplikasi: '
                                  'skema v${AppDatabase.schemaVersion} · '
                                  'kontrak v${AppDatabase.schemaContractVersion}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 6),
                                SelectableText(
                                  '$_error',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: _busy ? null : _retry,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Coba buka ulang'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _restoreBackup,
                            icon: const Icon(Icons.unarchive_outlined),
                            label: const Text('Pulihkan dari backup'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _exportRawDatabase,
                            icon: const Icon(Icons.save_alt),
                            label: const Text('Ekspor berkas database'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _openSafeMode,
                            icon: const Icon(Icons.health_and_safety_outlined),
                            label: const Text('Buka mode aman'),
                          ),
                          if (_busy) ...[
                            const SizedBox(height: 16),
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
