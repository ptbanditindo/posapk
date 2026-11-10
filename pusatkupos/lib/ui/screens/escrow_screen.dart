import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/summary_file_io.dart';
import '../../data/escrow_service.dart';
import '../../data/google_drive_escrow.dart';
import '../../state/app_state.dart';
import '../error_messages.dart';
import '../widgets.dart';

/// Pemulihan kunci owner dan toko lewat frasa 12 kata + Argon2id.
///
/// Frasa dan share admin hanya ditampilkan sekali setelah dibuat; escrow yang
/// diunggah ke Drive tidak berguna tanpa salah satunya.
class EscrowScreen extends StatefulWidget {
  const EscrowScreen({super.key});

  @override
  State<EscrowScreen> createState() => _EscrowScreenState();
}

class _EscrowScreenState extends State<EscrowScreen> {
  final _phraseInput = TextEditingController();
  final _verifyInput = TextEditingController();
  final _shareInputs = [TextEditingController(), TextEditingController()];
  bool _busy = false;
  bool _verified = false;
  bool _hasBundle = false;
  DateTime? _createdAt;
  String? _driveFileId;
  String? _phrase;
  List<String> _shares = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phraseInput.dispose();
    _verifyInput.dispose();
    for (final controller in _shareInputs) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final verified = await EscrowService.instance.isVerified();
    final createdAt = await EscrowService.instance.createdAt();
    final hasBundle = await EscrowService.instance.hasLocalBundle();
    final driveId = await EscrowService.instance.driveFileId();
    final phrase = await EscrowService.instance.pendingPhraseOnce();
    final shares = await EscrowService.instance.pendingSharesOnce();
    if (!mounted) return;
    setState(() {
      _verified = verified;
      _createdAt = createdAt;
      _hasBundle = hasBundle;
      _driveFileId = driveId;
      _phrase = phrase;
      _shares = shares;
    });
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      showSnack(context, success);
    } on EscrowException catch (error) {
      if (!mounted) return;
      showSnack(context, error.message, error: true);
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Gagal diproses: ${friendlyError(error)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmLabel = 'Lanjutkan',
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _create() async {
    if (!AppState.instance.isOwner) {
      showSnack(
        context,
        'Hanya pemilik yang bisa membuat cadangan kunci.',
        error: true,
      );
      return;
    }
    final ok = await _confirm(
      title: 'Buat cadangan kunci baru?',
      message: 'Cadangan lama akan diganti. Frasa dan share admin yang lama '
          'tidak berlaku lagi setelah cadangan baru dibuat.',
      confirmLabel: 'Buat cadangan',
    );
    if (!ok) return;
    await _run(() async {
      final result = await EscrowService.instance.create();
      await _load();
      if (!mounted) return;
      setState(() {
        _phrase = result.phrase;
        _shares = result.shares;
      });
    }, 'Cadangan kunci dibuat. Salin frasa dan share admin sekarang sebelum '
        'meninggalkan layar ini.');
  }

  Future<void> _verifyPhrase() async {
    final phrase = _verifyInput.text.trim();
    if (phrase.isEmpty) {
      showSnack(context, 'Masukkan frasa pemulihan.', error: true);
      return;
    }
    await _run(() async {
      await EscrowService.instance.verifyPhrase(phrase);
      await EscrowService.instance.clearPendingPhrase();
      await EscrowService.instance.clearPendingShares();
      _verifyInput.clear();
      await _load();
    }, 'Frasa cocok. Cadangan kunci ditandai terverifikasi.');
  }

  Future<void> _verifyShares() async {
    final shares = _shareInputs
        .map((controller) => controller.text.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (shares.length < 2) {
      showSnack(
        context,
        'Isi dua share admin dari orang yang berbeda.',
        error: true,
      );
      return;
    }
    await _run(() async {
      await EscrowService.instance.verifyShares(shares);
      await EscrowService.instance.clearPendingPhrase();
      await EscrowService.instance.clearPendingShares();
      for (final controller in _shareInputs) {
        controller.clear();
      }
      await _load();
    }, 'Share cocok. Cadangan kunci ditandai terverifikasi.');
  }

  Future<void> _restorePhrase() async {
    final ok = await _confirm(
      title: 'Pulihkan dengan frasa?',
      message: 'Kunci pemilik dan kunci toko di perangkat ini akan diganti '
          'dengan isi cadangan. Pastikan cadangan ini milik toko yang sedang '
          'aktif.',
      confirmLabel: 'Pulihkan',
    );
    if (!ok) return;
    await _run(() async {
      await EscrowService.instance.restoreWithPhrase(_phraseInput.text.trim());
      _phraseInput.clear();
      await _load();
    }, 'Kunci berhasil dipulihkan dari cadangan.');
  }

  Future<void> _restoreShares() async {
    final shares = _shareInputs
        .map((controller) => controller.text.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (shares.length < 2) {
      showSnack(context, 'Isi minimal dua share admin.', error: true);
      return;
    }
    final ok = await _confirm(
      title: 'Pulihkan dengan share admin?',
      message: 'Kunci pemilik dan kunci toko di perangkat ini akan diganti '
          'dengan isi cadangan.',
      confirmLabel: 'Pulihkan',
    );
    if (!ok) return;
    await _run(() async {
      await EscrowService.instance.restoreWithShares(shares);
      for (final controller in _shareInputs) {
        controller.clear();
      }
      await _load();
    }, 'Kunci berhasil dipulihkan dari cadangan.');
  }

  Future<void> _upload() => _run(
        () => EscrowService.instance.uploadToDrive(),
        'Cadangan kunci diunggah ke Google Drive.',
      );

  Future<void> _download() async {
    final ok = await _confirm(
      title: 'Unduh cadangan kunci dari Google Drive?',
      message: 'Berkas cadangan ini menggantikan cadangan di perangkat. '
          'Pemulihan tetap memerlukan frasa atau share admin.',
      confirmLabel: 'Unduh',
    );
    if (!ok) return;
    await _run(() async {
      await EscrowService.instance.downloadFromDrive();
      await _load();
    }, 'Cadangan kunci berhasil diunduh dari Google Drive.');
  }

  Future<void> _exportFile() async {
    await _run(() async {
      final text = await EscrowService.instance.exportBundleText();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      await FilePicker.saveFile(
        dialogTitle: 'Simpan berkas cadangan kunci',
        fileName: 'pusatkupos_escrow_$stamp.json',
        bytes: utf8.encode(text),
        mimeType: 'application/json',
      );
    }, 'Berkas cadangan kunci disimpan.');
  }

  Future<void> _importFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Pilih berkas cadangan kunci',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;
    await _run(() async {
      final text = await readSummaryFile(picked);
      await EscrowService.instance.importBundleText(text);
      await _load();
    }, 'Berkas cadangan kunci diimpor.');
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    showSnack(context, '$label disalin.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final driveReady = GoogleDriveEscrow.instance.configured &&
        GoogleDriveEscrow.instance.supported;
    return Scaffold(
      appBar: AppBar(title: const Text('Cadangan kunci pemulihan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Status cadangan kunci',
            subtitle: 'Cadangan ini menyimpan kunci pemilik dan kunci tiap '
                'toko. Untuk membukanya, gunakan frasa pemulihan atau 2 dari '
                '3 share admin.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      _verified
                          ? Icons.verified_user_outlined
                          : Icons.gpp_maybe_outlined,
                      color: _verified
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _verified
                            ? 'Terverifikasi. Pemulihan sudah diuji.'
                            : _hasBundle
                                ? 'Belum diverifikasi. Uji frasa atau share '
                                    'admin.'
                                : 'Belum ada cadangan kunci di perangkat ini.',
                      ),
                    ),
                  ],
                ),
                if (_createdAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Dibuat ${dateTimeId.format(_createdAt!.toLocal())}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (_driveFileId != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Salinan Google Drive tersedia.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || !AppState.instance.isOwner
                          ? null
                          : _create,
                      icon: const Icon(Icons.key_outlined),
                      label: const Text('Buat cadangan kunci'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !_hasBundle || !driveReady
                          ? null
                          : _upload,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Unggah ke Google Drive'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !driveReady ? null : _download,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('Unduh dari Google Drive'),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          if (_phrase != null || _shares.isNotEmpty) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Simpan sekarang juga',
              subtitle: 'Hanya ditampilkan sekali. Tanpa frasa atau share '
                  'admin, cadangan di Google Drive tidak bisa dibuka.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_phrase != null) ...[
                    Text(
                      'Frasa pemulihan',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _phrase!,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => _copy('Frasa pemulihan', _phrase!),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Salin frasa'),
                      ),
                    ),
                  ],
                  if (_shares.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('Share admin (2 dari 3)', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    for (final share in _shares)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                share,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Salin share',
                              onPressed: () => _copy('Share admin', share),
                              icon: const Icon(Icons.copy_outlined),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _verifyInput,
                    decoration: const InputDecoration(
                      labelText: 'Ulangi frasa untuk verifikasi',
                      helperText: 'Minimal 6 kata, urutan bebas.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _verifyPhrase,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Verifikasi frasa'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          SectionCard(
            title: 'Pulihkan kunci',
            subtitle: 'Dipakai di perangkat pengganti. Data lokal tidak '
                'dihapus, hanya kunci pemilik dan kunci toko yang dipulihkan.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _phraseInput,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Frasa pemulihan',
                    helperText: 'Minimal 6 kata.',
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _restorePhrase,
                    icon: const Icon(Icons.lock_open_outlined),
                    label: const Text('Pulihkan dengan frasa'),
                  ),
                ),
                const Divider(height: 30),
                Text(
                  'Atau pakai dua share admin',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _shareInputs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _shareInputs[i],
                      decoration: InputDecoration(
                        labelText: 'Share admin ${i + 1}',
                        hintText: 'shamir:v1:...',
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _verifyShares,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Verifikasi share'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _restoreShares,
                      icon: const Icon(Icons.groups_outlined),
                      label: const Text('Pulihkan dengan share'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Berkas cadangan kunci',
            subtitle: 'Simpan salinan terenkripsi di tempat yang aman. Berkas '
                'tetap tidak bisa dibuka tanpa frasa atau share admin.',
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || !_hasBundle ? null : _exportFile,
                  icon: const Icon(Icons.save_alt_outlined),
                  label: const Text('Ekspor berkas'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importFile,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Impor berkas'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
