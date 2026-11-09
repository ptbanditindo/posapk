import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../data/backup_service.dart';
import '../../data/license_service.dart';
import '../../data/print_queue_service.dart';
import '../../sync/archive_service.dart';
import '../../sync/sync_service.dart';
import '../error_messages.dart';

class HealthSnapshot {
  const HealthSnapshot({
    required this.premium,
    this.backupAt,
    this.backupAttemptAt,
    this.backupStatus = '',
    this.backupError = '',
    this.syncActive = false,
    this.syncAt,
    this.syncHost = '',
    this.syncError = '',
    this.syncPending = 0,
    this.syncFailed = 0,
    this.syncConflicts = 0,
    this.archiveArchived = 0,
    this.archivePending = 0,
    this.archiveFailed = 0,
    this.archiveError = '',
    this.archiveAt,
    this.printPending = 0,
    this.printFailed = 0,
  });

  final bool premium;
  final DateTime? backupAt;
  final DateTime? backupAttemptAt;
  final String backupStatus;
  final String backupError;
  final bool syncActive;
  final DateTime? syncAt;
  final String syncHost;
  final String syncError;
  final int syncPending;
  final int syncFailed;
  final int syncConflicts;
  final int archiveArchived;
  final int archivePending;
  final int archiveFailed;
  final String archiveError;
  final DateTime? archiveAt;
  final int printPending;
  final int printFailed;

  bool get backupStale {
    final at = backupAt;
    if (at == null) return false;
    return DateTime.now().difference(at.toLocal()) >= const Duration(days: 7);
  }

  bool get hasProblem =>
      backupError.trim().isNotEmpty ||
      backupStatus.toLowerCase() == 'error' ||
      backupStale ||
      archiveFailed > 0 ||
      archiveError.trim().isNotEmpty ||
      printFailed > 0 ||
      (syncActive && (syncFailed > 0 || syncConflicts > 0));
}

Future<HealthSnapshot> loadHealthSnapshot() async {
  var premium = false;
  try {
    premium = await LicenseService.instance.isPremium();
  } catch (_) {
    premium = false;
  }

  DateTime? backupAt;
  DateTime? backupAttemptAt;
  var backupStatus = '';
  var backupError = '';
  try {
    final status = await BackupService.instance.status();
    backupAt = DateTime.tryParse(status['last_local_at']?.toString() ?? '');
    backupAttemptAt =
        DateTime.tryParse(status['last_attempt_at']?.toString() ?? '');
    backupStatus = status['last_status']?.toString() ?? '';
    backupError = status['last_error']?.toString() ?? '';
  } catch (_) {
    // Ringkasan kesehatan tidak boleh menggagalkan beranda.
  }

  var syncActive = false;
  DateTime? syncAt;
  var syncHost = '';
  var syncError = '';
  var syncPending = 0;
  var syncFailed = 0;
  var syncConflicts = 0;
  try {
    final status = await SyncService.instance.status();
    final relay = '${status['relay_url'] ?? ''}'.trim();
    final device = '${status['relay_device_id'] ?? ''}'.trim();
    if (premium && relay.isNotEmpty && device.isNotEmpty) {
      syncActive = true;
      syncHost = Uri.tryParse(relay)?.host ?? relay;
      syncAt = DateTime.tryParse('${status['last_success_at'] ?? ''}');
      syncError = status['last_error']?.toString() ?? '';
      syncConflicts = (status['blocking'] as num?)?.toInt() ?? 0;
      final summary = await SyncService.instance.outboxSummary();
      syncPending = (summary['pending'] as num?)?.toInt() ?? 0;
      syncFailed = ((summary['failed'] as num?)?.toInt() ?? 0) +
          ((summary['dead_letter'] as num?)?.toInt() ?? 0);
    }
  } catch (_) {
    // Status sync belum tersedia saat database/perangkat belum siap.
  }

  var archiveArchived = 0;
  var archivePending = 0;
  var archiveFailed = 0;
  var archiveError = '';
  DateTime? archiveAt;
  if (premium) {
    try {
      final status = await ArchiveService.instance.status();
      archiveArchived = (status['archived'] as num?)?.toInt() ?? 0;
      archivePending = (status['pending'] as num?)?.toInt() ?? 0;
      archiveFailed = (status['failed'] as num?)?.toInt() ?? 0;
      archiveError = status['last_error']?.toString() ?? '';
      archiveAt = DateTime.tryParse('${status['last_at'] ?? ''}');
    } catch (_) {
      // Arsip opsional; kegagalan status tidak menghalangi menu lain.
    }
  }

  var printPending = 0;
  var printFailed = 0;
  try {
    printPending = await PrintQueueService.instance.pendingCount();
    printFailed = await PrintQueueService.instance.failedCount();
  } catch (_) {
    // Antrean cetak dibuat setelah database siap.
  }

  return HealthSnapshot(
    premium: premium,
    backupAt: backupAt,
    backupAttemptAt: backupAttemptAt,
    backupStatus: backupStatus,
    backupError: backupError,
    syncActive: syncActive,
    syncAt: syncAt,
    syncHost: syncHost,
    syncError: syncError,
    syncPending: syncPending,
    syncFailed: syncFailed,
    syncConflicts: syncConflicts,
    archiveArchived: archiveArchived,
    archivePending: archivePending,
    archiveFailed: archiveFailed,
    archiveError: archiveError,
    archiveAt: archiveAt,
    printPending: printPending,
    printFailed: printFailed,
  );
}

/// Ringkasan kesehatan backup, arsip, dan cetak di beranda. Status sinkronisasi
/// rinci tetap ditangani [SyncStatusStrip]; strip ini memastikan kegagalan
/// backup/arsip/cetak yang berkepanjangan juga terlihat.
class OperationalHealthStrip extends StatefulWidget {
  const OperationalHealthStrip({super.key});

  @override
  State<OperationalHealthStrip> createState() => _OperationalHealthStripState();
}

class _OperationalHealthStripState extends State<OperationalHealthStrip> {
  Timer? _timer;
  HealthSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final snapshot = await loadHealthSnapshot();
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final problem = snapshot.hasProblem;
    final parts = <String>[
      snapshot.backupAt == null
          ? 'Backup belum ada'
          : 'Backup ${dateTimeId.format(snapshot.backupAt!.toLocal())}',
      if (snapshot.premium)
        snapshot.archivePending > 0
            ? 'Arsip ${snapshot.archivePending} tertunda'
            : 'Arsip ${snapshot.archiveArchived}',
      if (snapshot.printFailed > 0) 'Cetak ${snapshot.printFailed} gagal',
    ];
    return Material(
      color: problem ? scheme.errorContainer : scheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => HealthDialog(initial: snapshot),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(
                problem ? Icons.health_and_safety : Icons.health_and_safety_outlined,
                size: 18,
                color: problem ? scheme.onErrorContainer : scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  parts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: problem ? scheme.onErrorContainer : null,
                      ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: problem ? scheme.onErrorContainer : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HealthDialog extends StatefulWidget {
  const HealthDialog({super.key, required this.initial});

  final HealthSnapshot initial;

  @override
  State<HealthDialog> createState() => _HealthDialogState();
}

class _HealthDialogState extends State<HealthDialog> {
  late HealthSnapshot _snapshot = widget.initial;
  bool _loading = false;

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final snapshot = await loadHealthSnapshot();
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _snapshot;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Kesehatan perangkat'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section(
                icon: Icons.backup_outlined,
                title: 'Backup lokal',
                problem: s.backupError.isNotEmpty ||
                    s.backupStatus.toLowerCase() == 'error' ||
                    s.backupStale,
                lines: [
                  s.backupAt == null
                      ? 'Belum ada backup lokal yang berhasil.'
                      : 'Terakhir berhasil: '
                          '${dateTimeId.format(s.backupAt!.toLocal())}',
                  if (s.backupAttemptAt != null)
                    'Percobaan terakhir: '
                        '${dateTimeId.format(s.backupAttemptAt!.toLocal())}',
                  if (s.backupStatus.isNotEmpty)
                    'Status terakhir: ${s.backupStatus}',
                  if (s.backupError.isNotEmpty)
                    'Error: ${friendlyError(s.backupError)}',
                  if (s.backupStale)
                    'Backup terakhir lebih dari 7 hari. Buat backup baru dari '
                        'Pengaturan.',
                ],
              ),
              _section(
                icon: Icons.cloud_outlined,
                title: 'Sinkronisasi',
                problem: s.syncActive &&
                    (s.syncFailed > 0 ||
                        s.syncConflicts > 0 ||
                        s.syncError.isNotEmpty),
                lines: [
                  if (!s.premium)
                    'Akun gratis: sinkronisasi server tidak aktif.'
                  else if (!s.syncActive)
                    'Perangkat belum terhubung ke relay. Pasangkan perangkat '
                        'dari menu Premium.'
                  else ...[
                    'Relay: ${s.syncHost}',
                    s.syncAt == null
                        ? 'Belum pernah sinkron berhasil.'
                        : 'Terakhir berhasil: '
                            '${dateTimeId.format(s.syncAt!.toLocal())}',
                    'Menunggu: ${s.syncPending} · gagal: ${s.syncFailed} · '
                        'konflik: ${s.syncConflicts}',
                    if (s.syncError.isNotEmpty)
                      'Error: ${friendlyError(s.syncError)}',
                  ],
                ],
              ),
              _section(
                icon: Icons.archive_outlined,
                title: 'Arsip nota',
                problem: s.archiveFailed > 0 || s.archiveError.isNotEmpty,
                lines: [
                  if (!s.premium)
                    'Arsip server hanya tersedia untuk akun premium.'
                  else ...[
                    'Tersimpan: ${s.archiveArchived} · '
                        'menunggu: ${s.archivePending} · '
                        'gagal: ${s.archiveFailed}',
                    s.archiveAt == null
                        ? 'Belum ada nota yang selesai diarsipkan.'
                        : 'Arsip terakhir: '
                            '${dateTimeId.format(s.archiveAt!.toLocal())}',
                    if (s.archiveError.isNotEmpty)
                      'Error: ${friendlyError(s.archiveError)}',
                  ],
                ],
              ),
              _section(
                icon: Icons.print_outlined,
                title: 'Antrean cetak',
                problem: s.printFailed > 0,
                lines: [
                  'Menunggu: ${s.printPending} · gagal: ${s.printFailed}',
                  if (s.printFailed > 0)
                    'Buka Riwayat atau struk nota, lalu tekan "Cetak ulang". '
                        'Struk tidak hilang saat printer gagal.',
                ],
              ),
              if (_loading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (s.hasProblem)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Periksa bagian yang ditandai. Data lokal tidak dihapus '
                    'oleh pemeriksaan ini.',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : _refresh,
          child: const Text('Muat ulang'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Tutup'),
        ),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required bool problem,
    required List<String> lines,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: problem ? scheme.error : scheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: problem ? scheme.error : null,
                  ),
                ),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(line, style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
