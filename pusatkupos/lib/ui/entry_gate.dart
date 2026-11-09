import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../data/app_database.dart';
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
  await signOutSession(owner: AppState.instance.isOwner);
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const EntryGate()),
    (_) => false,
  );
}

/// Membersihkan sesi perangkat. Pemilik kehilangan database lokal beserta
/// kunci identitas lamanya; karyawan hanya kehilangan sesi sehingga data toko
/// tetap tersedia untuk pemilik.
Future<void> signOutSession({required bool owner}) async {
  // Pemilik yang keluar dari sesinya sendiri boleh mendaftar ulang dalam
  // proses yang sama; karyawan tidak boleh mewarisi hak itu.
  SessionService.allowOwnerRebind = owner;
  SyncScheduler.instance.stop();
  // Kembali dari mode ringkasan sebelum menyentuh pengaturan, karena salinan
  // ringkasan dibuka sebagai database baca-saja.
  await AppDatabase.instance.useMainDatabase();
  // Cabut token perangkat (jika masih terhubung) dan hapus kunci sinkronisasi
  // sebelum database toko dilepas, agar perangkat yang keluar tidak lagi
  // dapat mengirim data.
  try {
    await SyncService.instance.purgeDeviceIdentity();
  } catch (_) {
    // Keluar tetap harus berhasil walau relay/database sedang bermasalah.
  }
  // Jangan biarkan backup otomatis menyalin database saat berkas dihapus.
  await BackupScheduler.instance.whenIdle();
  await SessionService.instance.clear();
  await PinService.instance.clear();
  await SecureStore.instance.delete('owner.enroll_token');
  await AppDatabase.instance.deleteSetting('sync.enroll_token');
  if (owner) {
    // Pemilik yang keluar menghapus database lokal beserta kunci identitas
    // lamanya. Masuk lagi memakai akun yang sama akan mengambil salinan
    // terbaru dari relay, bukan melanjutkan data yang tertinggal di perangkat.
    try {
      await AppDatabase.instance.deleteLocalDatabases();
      await SecureStore.instance.delete('owner.signing.private');
      await SecureStore.instance.delete('owner.recovery.code');
      LicenseService.instance.clearCache();
      await AppState.instance.load();
    } catch (error) {
      // Kontrol pemulihan owner tetap aktif selama owner_identity masih ada,
      // jadi kegagalan hapus berkas tidak membuka jalan pengambilalihan.
      AppLog.instance.event(
        LogCategory.database,
        'signout.wipe.fail',
        error: error,
      );
    }
  }
  AppState.instance.setOperator(null);
  await AppState.instance.refreshPinState();
}
