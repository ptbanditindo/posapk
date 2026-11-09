import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../data/app_database.dart';
import '../data/audit_service.dart';
import '../data/backup_scheduler.dart';
import '../data/license_service.dart';
import '../data/pin_service.dart';
import '../data/secure_store.dart';
import '../data/session_service.dart';
import '../state/app_state.dart';
import '../sync/sync_scheduler.dart';
import '../sync/sync_service.dart';
import 'onboarding.dart';
import 'pin_gate.dart';
import 'session_recovery.dart';

class EntryGate extends StatefulWidget {
  const EntryGate({super.key});

  @override
  State<EntryGate> createState() => _EntryGateState();
}

class _EntryGateState extends State<EntryGate> {
  SessionProfile? _profile;
  bool _loading = true;
  bool _needsRecovery = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var profile = await SessionService.instance.load();
    if (profile == null && AppState.instance.pinConfigured) {
      // PIN perangkat menyimpan identitas pemiliknya. Jangan pernah
      // menyintesis profil owner hanya karena PIN masih terpasang.
      profile = await SessionService.instance.readPinIdentity();
    }
    if (profile != null && profile.isOwner) {
      final localOwner = await LicenseService.instance.ownerId();
      if (localOwner != null &&
          localOwner.isNotEmpty &&
          profile.ownerId.isNotEmpty &&
          profile.ownerId != localOwner) {
        profile = null;
      }
    }
    final needsRecovery = profile == null && AppState.instance.pinConfigured;
    if (profile != null && profile.isViewer) {
      try {
        await AppDatabase.instance.openViewerDatabase(profile.ownerId);
      } catch (_) {
        // Biarkan layar PIN tampil; data ringkasan akan dimuat ulang.
      }
    } else {
      await AppDatabase.instance.useMainDatabase();
    }
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _needsRecovery = needsRecovery;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_needsRecovery) {
      return const SessionRecoveryScreen();
    }
    final profile = _profile;
    if (profile == null) return const OnboardingFlow();
    return PinGate(profile: profile);
  }
}

Future<void> signOutToOnboarding(BuildContext context) async {
  Map<String, Object?> summary;
  try {
    summary = await SyncService.instance.outboxSummary();
  } catch (error) {
    AppLog.instance.event(
      LogCategory.sync,
      'signout.outbox.fail',
      error: error,
    );
    summary = const {};
  }
  final total = (summary['total'] as num?)?.toInt() ?? 0;
  if (total > 0) {
    String? choice;
    do {
      if (!context.mounted) return;
      choice = await _showOutboxDialog(context, summary);
      if (!context.mounted) return;
      if (choice == 'export') await _exportOutbox(context);
    } while (choice == 'export');
    if (choice != 'logout') return;
  }
  await signOutSession(owner: AppState.instance.isOwner);
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const EntryGate()),
    (_) => false,
  );
}

Future<String?> _showOutboxDialog(
  BuildContext context,
  Map<String, Object?> summary,
) {
  final pending = (summary['pending'] as num?)?.toInt() ?? 0;
  final failed = (summary['failed'] as num?)?.toInt() ?? 0;
  final total = (summary['total'] as num?)?.toInt() ?? 0;
  final oldest = '${summary['oldest_at'] ?? ''}';
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Masih ada antrean sinkronisasi'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$total dokumen belum terkirim: $pending menunggu, '
              '$failed gagal.'),
          if (oldest.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Dokumen tertua: ${_formatOutboxStamp(oldest)}.'),
          ],
          const SizedBox(height: 12),
          const Text(
            'Dokumen yang belum terkirim tetap tersimpan di perangkat setelah '
            'keluar. Ekspor antrean bila Anda perlu bukti atau cadangan '
            'sebelum meninggalkan perangkat ini.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: const Text('Batal'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, 'export'),
          child: const Text('Ekspor antrean'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'logout'),
          child: const Text('Keluar'),
        ),
      ],
    ),
  );
}

String _formatOutboxStamp(String raw) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}-${two(local.month)}-${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

Future<bool> _exportOutbox(BuildContext context) async {
  try {
    final payload = await SyncService.instance.exportOutboxJson();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final target = await FilePicker.saveFile(
      dialogTitle: 'Simpan antrean sinkronisasi',
      fileName: 'pusatkupos_outbox_$stamp.json',
      bytes: Uint8List.fromList(utf8.encode(payload)),
      mimeType: 'application/json',
    );
    if (!context.mounted) return target != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          target == null
              ? 'Ekspor antrean dibatalkan.'
              : 'Antrean sinkronisasi disimpan.',
        ),
      ),
    );
    return target != null;
  } catch (error) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ekspor antrean gagal: $error')),
    );
    return false;
  }
}

/// Mengakhiri sesi tanpa menghapus database toko, antrean keluar, atau kunci
/// identitas. Pemilik dapat membuka data yang sama lagi dengan PIN perangkat;
/// karyawan harus masuk ulang dengan akunnya.
Future<void> signOutSession({required bool owner}) async {
  // Pemilik yang keluar dari sesinya sendiri boleh mendaftar ulang dalam
  // proses yang sama; karyawan tidak boleh mewarisi hak itu.
  SessionService.allowOwnerRebind = owner;
  SyncScheduler.instance.stop();
  // Kembali dari mode ringkasan sebelum menyentuh pengaturan, karena salinan
  // ringkasan dibuka sebagai database baca-saja.
  await AppDatabase.instance.useMainDatabase();
  // Jangan biarkan backup otomatis menyalin database saat sesi berakhir.
  await BackupScheduler.instance.whenIdle();
  if (owner) {
    await SessionService.instance.clearProfile();
  } else {
    // PIN pada perangkat karyawan bukan PIN pemilik; jangan diwariskan.
    await SessionService.instance.clear();
    await PinService.instance.clear();
  }
  await SecureStore.instance.delete('owner.enroll_token');
  await AppDatabase.instance.deleteSetting('sync.enroll_token');
  AppState.instance.setOperator(null);
  await AppState.instance.refreshPinState();
}

/// Menghapus seluruh data dan identitas perangkat. Berbeda dari keluar, aksi
/// ini hanya boleh dijalankan pemilik yang memverifikasi PIN. Antrean yang
/// belum terkirim ditawarkan untuk diekspor terlebih dahulu (F0-1/F0-2).
Future<void> resetDeviceSession(BuildContext context) async {
  if (!AppState.instance.isOwner) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hanya pemilik yang boleh mereset perangkat.')),
    );
    return;
  }
  Map<String, Object?> summary;
  try {
    summary = await SyncService.instance.outboxSummary();
  } catch (error) {
    AppLog.instance.event(
      LogCategory.sync,
      'reset.outbox.fail',
      error: error,
    );
    summary = const {};
  }
  final total = (summary['total'] as num?)?.toInt() ?? 0;
  if (total > 0) {
    String? choice;
    do {
      if (!context.mounted) return;
      choice = await _showOutboxDialog(context, summary);
      if (!context.mounted) return;
      if (choice == 'export') await _exportOutbox(context);
    } while (choice == 'export');
    if (choice != 'logout') return;
  }
  if (!context.mounted) return;
  if (!await _confirmOwnerPin(context)) return;
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reset perangkat?'),
      content: const Text(
        'Database toko, kunci identitas, dan antrean sinkronisasi di '
        'perangkat ini akan dihapus permanen. Tindakan ini tidak dapat '
        'dibatalkan. Buat backup dan ekspor antrean terlebih dahulu bila '
        'masih diperlukan.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Reset perangkat'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final operator = AppState.instance.operator;
  var deviceId = '';
  try {
    deviceId = await AppDatabase.instance.deviceCode(
      AppDatabase.instance.db,
    );
  } catch (_) {
    // Kode perangkat hanya pelengkap audit.
  }
  try {
    await AuditService.instance.recordNow(
      aksi: 'reset_perangkat',
      entity: 'device',
      entityId: deviceId,
      aktor: operator?.label ?? 'Pemilik',
      aktorEmployeeSyncId: operator?.employeeSyncId,
      alasan: 'Reset perangkat oleh pemilik',
      before: {'outbox_total': total},
      after: const {'database': 'dihapus'},
    );
  } catch (error) {
    AppLog.instance.event(LogCategory.database, 'reset.audit.fail', error: error);
  }

  SessionService.allowOwnerRebind = true;
  SyncScheduler.instance.stop();
  await AppDatabase.instance.useMainDatabase();
  try {
    await SyncService.instance.purgeDeviceIdentity();
  } catch (error) {
    AppLog.instance.event(LogCategory.sync, 'reset.revoke.fail', error: error);
  }
  await BackupScheduler.instance.whenIdle();
  try {
    await AppDatabase.instance.deleteLocalDatabases();
    await SecureStore.instance.delete('owner.signing.private');
    await SecureStore.instance.delete('owner.recovery.code');
    await SecureStore.instance.delete('owner.enroll_token');
    await SecureStore.instance.delete('session.device_token');
    LicenseService.instance.clearCache();
  } catch (error) {
    // Kontrol pemulihan owner tetap aktif selama owner_identity masih ada.
    AppLog.instance.event(LogCategory.database, 'reset.wipe.fail', error: error);
  }
  await SessionService.instance.clear();
  await PinService.instance.clear();
  await AppDatabase.instance.deleteSetting('sync.enroll_token');
  await AppState.instance.load();
  AppState.instance.setOperator(null);
  await AppState.instance.refreshPinState();
  AppLog.instance.event(LogCategory.database, 'device.reset');
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const EntryGate()),
    (_) => false,
  );
}

/// PIN perangkat adalah autentikasi pemilik. Bila PIN belum pernah dibuat,
/// pemilik tetap harus menyatakan persetujuan lewat dialog reset.
Future<bool> _confirmOwnerPin(BuildContext context) async {
  if (!await PinService.instance.isConfigured()) return true;
  if (!context.mounted) return false;
  final controller = TextEditingController();
  String? error;
  final pin = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('Konfirmasi pemilik'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Masukkan PIN pemilik untuk melanjutkan reset.'),
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
  if (pin == null) return false;
  final result = await PinService.instance.verifyDetailed(pin);
  if (result == PinVerification.ok ||
      result == PinVerification.weakLegacyPin) {
    return true;
  }
  if (!context.mounted) return false;
  final message = switch (result) {
    PinVerification.locked => 'Terlalu banyak percobaan. Coba lagi nanti.',
    PinVerification.wrong => 'PIN pemilik salah.',
    _ => 'PIN pemilik tidak dapat diverifikasi.',
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
  return false;
}
