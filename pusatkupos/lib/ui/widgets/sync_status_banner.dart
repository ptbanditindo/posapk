import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../data/backup_service.dart';
import '../../data/license_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../entry_gate.dart';
import '../error_messages.dart';
import '../widgets.dart';

/// Banner 24 jam tanpa sync sukses. Hanya muncul untuk akun premium yang
/// perangkatnya sudah terhubung ke relay; toko gratis memakai indikator
/// backup lokal di kaki laci menu.
class SyncHealthBanner extends StatefulWidget {
  const SyncHealthBanner({super.key});

  @override
  State<SyncHealthBanner> createState() => _SyncHealthBannerState();
}

class _SyncHealthBannerState extends State<SyncHealthBanner> {
  static const _threshold = Duration(hours: 24);

  Timer? _timer;
  bool _visible = false;
  bool _neverSynced = false;
  int _outstanding = 0;
  DateTime? _lastSuccess;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _load(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    var premium = false;
    try {
      premium = await LicenseService.instance.isPremium();
    } catch (_) {
      premium = false;
    }
    if (!premium) {
      _apply(visible: false);
      return;
    }
    try {
      final status = await SyncService.instance.status();
      final active = '${status['relay_url'] ?? ''}'.trim().isNotEmpty &&
          '${status['relay_device_id'] ?? ''}'.trim().isNotEmpty;
      if (!active) {
        _apply(visible: false);
        return;
      }
      final summary = await SyncService.instance.outboxSummary();
      final outstanding = (summary['total'] as num?)?.toInt() ?? 0;
      final lastSuccess = DateTime.tryParse(
        '${status['last_success_at'] ?? ''}',
      )?.toUtc();
      final oldestPending = DateTime.tryParse(
        '${summary['oldest_at'] ?? ''}',
      )?.toUtc();
      final anchor = lastSuccess ?? oldestPending;
      final stale =
          anchor != null && DateTime.now().toUtc().difference(anchor) >= _threshold;
      _apply(
        visible: stale,
        neverSynced: lastSuccess == null,
        outstanding: outstanding,
        lastSuccess: lastSuccess,
      );
    } catch (_) {
      _apply(visible: false);
    }
  }

  void _apply({
    required bool visible,
    bool neverSynced = false,
    int outstanding = 0,
    DateTime? lastSuccess,
  }) {
    if (!mounted) return;
    setState(() {
      _visible = visible;
      _neverSynced = neverSynced;
      _outstanding = outstanding;
      _lastSuccess = lastSuccess;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final message = _neverSynced
        ? 'Perangkat ini belum pernah berhasil mengirim data ke server.'
        : 'Pengiriman terakhir '
            '${dateTimeId.format(_lastSuccess!.toLocal())} '
            '(sudah lebih dari 24 jam).';
    final detail = _outstanding > 0
        ? '$_outstanding data menunggu dikirim.'
        : 'Tidak ada data baru yang menunggu dikirim.';
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data belum terkirim ke server',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$message $detail',
                      style: TextStyle(color: scheme.onErrorContainer),
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

/// Panel ringkas sinkronisasi di beranda. Hanya tampil saat akun premium dan
/// perangkat sudah terhubung ke relay; toko gratis memakai indikator backup
/// lokal di kaki laci menu.
class SyncStatusStrip extends StatefulWidget {
  const SyncStatusStrip({super.key});

  @override
  State<SyncStatusStrip> createState() => _SyncStatusStripState();
}

class _SyncStatusStripState extends State<SyncStatusStrip> {
  Timer? _timer;
  bool _visible = false;
  bool _busy = false;
  int _pending = 0;
  int _failed = 0;
  int _conflicts = 0;
  DateTime? _lastSuccess;
  String _lastError = '';
  String _relayHost = '';
  bool _upgradeRequired = false;
  bool _revoked = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    var premium = false;
    try {
      premium = await LicenseService.instance.isPremium();
    } catch (_) {
      premium = false;
    }
    if (!premium) {
      _apply(visible: false);
      return;
    }
    try {
      final status = await SyncService.instance.status();
      final relayUrl = '${status['relay_url'] ?? ''}'.trim();
      final relayDevice = '${status['relay_device_id'] ?? ''}'.trim();
      if (relayUrl.isEmpty || relayDevice.isEmpty) {
        _apply(visible: false);
        return;
      }
      final summary = await SyncService.instance.outboxSummary();
      _apply(
        visible: true,
        pending: (summary['pending'] as num?)?.toInt() ?? 0,
        failed: ((summary['failed'] as num?)?.toInt() ?? 0) +
            ((summary['dead_letter'] as num?)?.toInt() ?? 0),
        conflicts: (status['blocking'] as num?)?.toInt() ?? 0,
        lastSuccess: DateTime.tryParse(
          '${status['last_success_at'] ?? ''}',
        )?.toLocal(),
        lastError: '${status['last_error'] ?? ''}'.trim(),
        relayHost: Uri.tryParse(relayUrl)?.host ?? relayUrl,
        upgradeRequired: '${status['upgrade_required'] ?? ''}'.isNotEmpty,
        revoked: '${status['device_revoked_at'] ?? ''}'.isNotEmpty,
      );
    } catch (_) {
      _apply(visible: false);
    }
  }

  void _apply({
    required bool visible,
    int? pending,
    int? failed,
    int? conflicts,
    DateTime? lastSuccess,
    String? lastError,
    String? relayHost,
    bool upgradeRequired = false,
    bool revoked = false,
  }) {
    if (!mounted) return;
    setState(() {
      _visible = visible;
      if (!visible) return;
      _pending = pending ?? _pending;
      _failed = failed ?? _failed;
      _conflicts = conflicts ?? _conflicts;
      _lastSuccess = lastSuccess;
      _lastError = lastError ?? '';
      _relayHost = relayHost ?? _relayHost;
      _upgradeRequired = upgradeRequired;
      _revoked = revoked;
    });
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await SyncService.instance.syncNow();
      if (!mounted) return;
      if (result['key_pending'] == true) {
        showSnack(
          context,
          'Perangkat sudah terhubung. Tunggu pemilik mengirim kunci toko '
          'sebelum data bisa dikirim.',
        );
      } else if (result['snapshot_applied'] == true) {
        showSnack(
          context,
          'Cadangan data dari server sudah dimuat. Tekan Sinkron lagi untuk '
          'mengambil perubahan berikutnya.',
        );
      } else if (result['snapshot_required'] == true) {
        showSnack(
          context,
          'Data di perangkat ini tertinggal. Minta pemilik mengunggah '
          'cadangan data dari perangkat utamanya.',
          error: true,
        );
      } else {
        showSnack(
          context,
          'Sinkron selesai: ${result['sent'] ?? 0} data terkirim, '
          '${result['applied'] ?? 0} data diterima.',
        );
      }
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          'Sinkron gagal. ${friendlyError(error)}',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    if (_revoked) {
      final owner = AppState.instance.isOwner;
      return Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gpp_bad_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Pemilik mencabut akses perangkat ini. Sinkronisasi berhenti, '
                  'tetapi data di perangkat tidak dihapus. Ekspor data yang '
                  'belum terkirim, lalu hubungkan perangkat lagi.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () async {
                  if (owner) {
                    await resetDeviceSession(context);
                    return;
                  }
                  await signOutSession(owner: false);
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const EntryGate()),
                    (_) => false,
                  );
                },
                child: Text(
                  owner ? 'Ekspor lalu atur ulang' : 'Keluar dari akun',
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_upgradeRequired) {
      return Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.system_update, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Perbarui aplikasi. Versi ini tidak didukung server lagi, '
                  'jadi sinkronisasi berhenti sampai aplikasi diperbarui. '
                  'Data di perangkat tetap aman.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final hasProblem = _failed > 0 || _conflicts > 0 || _lastError.isNotEmpty;
    final last = _lastSuccess == null
        ? 'Belum pernah sinkron'
        : 'Terakhir ${dateTimeId.format(_lastSuccess!)}';
    final detail = [
      last,
      if (_pending > 0) '$_pending menunggu dikirim',
      if (_failed > 0) '$_failed gagal terkirim',
      if (_conflicts > 0) '$_conflicts perlu diputuskan',
    ].join(' · ');
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(
              hasProblem ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
              size: 20,
              color: hasProblem ? scheme.error : scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Tooltip(
                message: _lastError.isEmpty ? _relayHost : _lastError,
                child: Text(
                  'Sinkron dengan $_relayHost\n$detail',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: const Text('Sinkron'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pengganti indikator sync untuk toko gratis: kapan backup lokal terakhir
/// berhasil dibuat.
class BackupStatusFooter extends StatelessWidget {
  const BackupStatusFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<DateTime?>(
        future: BackupService.instance.lastLocalAt(),
        builder: (context, snapshot) {
          final at = snapshot.data?.toLocal();
          return Text(
            at == null
                ? 'Belum ada cadangan lokal. Buka Pengaturan untuk membuatnya.'
                : 'Cadangan lokal terakhir: ${dateTimeId.format(at)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          );
        },
      ),
    );
  }
}
