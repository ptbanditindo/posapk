import 'package:flutter/material.dart';

import '../sync/sync_service.dart';

Future<bool> showUploadBackupDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _UploadBackupDialog(),
  );
  return result == true;
}

class _UploadBackupDialog extends StatefulWidget {
  const _UploadBackupDialog();

  @override
  State<_UploadBackupDialog> createState() => _UploadBackupDialogState();
}

class _UploadBackupDialogState extends State<_UploadBackupDialog> {
  Map<String, Object?>? _round;
  String? _error;
  bool _busy = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final round = await SyncService.instance.startUploadCheck();
      if (!mounted) return;
      setState(() {
        _round = round;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  Future<void> _refresh() async {
    final id = '${_round?['id'] ?? ''}';
    if (id.isEmpty) {
      await _start();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var round = await SyncService.instance.refreshUploadCheck(id);
      if (round['stale'] == true) {
        await SyncService.instance.syncNow();
        round = await SyncService.instance.startUploadCheck();
      }
      if (!mounted) return;
      setState(() {
        _round = round;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  Future<void> _upload() async {
    final id = '${_round?['id'] ?? ''}';
    if (id.isEmpty) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      await SyncService.instance.uploadSnapshot(roundId: id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _uploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy && !_uploading,
      child: AlertDialog(
        title: const Text('Periksa kelengkapan cadangan'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(child: _content(scheme)),
        ),
        actions: _actions(),
      ),
    );
  }

  Widget _content(ColorScheme scheme) {
    if (_busy && _round == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Memeriksa perangkat toko...')),
          ],
        ),
      );
    }
    if (_round == null) {
      return Text(_error ?? 'Pemeriksaan tidak dapat dilakukan.');
    }
    final round = _round!;
    final devices = (round['devices'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', value)))
        .toList();
    final total = (round['total'] as num?)?.toInt() ?? 0;
    final synced = (round['synced'] as num?)?.toInt() ?? 0;
    final stale = round['stale'] == true;
    final pending = total - synced;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Cadangan hanya dapat diunggah setelah semua perangkat toko '
          'mengirim datanya. Perangkat yang offline akan menahan proses ini.',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                '$synced dari $total perangkat sudah sinkron',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text('$synced/$total'),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: total == 0 ? 0 : synced / total,
          minHeight: 6,
          borderRadius: BorderRadius.circular(6),
        ),
        const SizedBox(height: 14),
        for (final device in devices) _deviceRow(device, scheme),
        if (stale) ...[
          const SizedBox(height: 12),
          _notice(
            scheme,
            'Ada data baru masuk setelah pemeriksaan. Periksa ulang sebelum '
            'mengunggah.',
          ),
        ] else if (pending > 0) ...[
          const SizedBox(height: 12),
          _notice(
            scheme,
            'Minta karyawan membuka aplikasi lalu menekan Sinkron sekarang. '
            'Perangkat yang benar-benar hilang dapat dicabut di menu Akses.',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
      ],
    );
  }

  Widget _deviceRow(Map<String, Object?> device, ColorScheme scheme) {
    final state = '${device['state'] ?? 'pending'}';
    final icon = switch (state) {
      'synced' => Icons.check_circle,
      'revoked' => Icons.block,
      _ => Icons.schedule,
    };
    final color = switch (state) {
      'synced' => scheme.primary,
      'revoked' => scheme.outline,
      _ => scheme.tertiary,
    };
    final label = switch (state) {
      'synced' => 'Sudah sinkron',
      'revoked' => 'Akses dicabut',
      _ => 'Belum sinkron',
    };
    final kind = switch ('${device['kind']}') {
      'employee' => 'Karyawan',
      'viewer' => 'Ringkasan',
      _ => 'Owner',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${device['nama'] ?? 'Perangkat'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('$kind · $label', style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _notice(ColorScheme scheme, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: const TextStyle(fontSize: 13)),
    );
  }

  List<Widget> _actions() {
    final round = _round;
    final total = (round?['total'] as num?)?.toInt() ?? 0;
    final stale = round?['stale'] == true;
    final complete = round != null && total > 0 && round['complete'] == true;
    return [
      TextButton(
        onPressed: _busy || _uploading ? null : () => Navigator.pop(context),
        child: const Text('Tutup'),
      ),
      OutlinedButton(
        onPressed: _busy || _uploading ? null : _refresh,
        child: Text(_busy && round != null ? 'Memeriksa...' : 'Periksa lagi'),
      ),
      FilledButton(
        onPressed: complete && !stale && !_busy && !_uploading
            ? _upload
            : null,
        child: _uploading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Unggah sekarang'),
      ),
    ];
  }
}
