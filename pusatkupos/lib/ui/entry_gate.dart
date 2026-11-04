import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/license_service.dart';
import '../data/pin_service.dart';
import '../data/secure_store.dart';
import '../data/session_service.dart';
import '../state/app_state.dart';
import 'onboarding.dart';
import 'pin_gate.dart';

class EntryGate extends StatefulWidget {
  const EntryGate({super.key});

  @override
  State<EntryGate> createState() => _EntryGateState();
}

class _EntryGateState extends State<EntryGate> {
  SessionProfile? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var profile = await SessionService.instance.load();
    if (profile == null && AppState.instance.pinConfigured) {
      final ownerId = await LicenseService.instance.ownerId() ?? '';
      final premium = await LicenseService.instance.isPremium();
      profile = SessionProfile(
        mode: premium ? 'premium' : 'free',
        ownerId: ownerId,
        nama: 'Pemilik',
        role: 'owner',
        plan: premium ? 'premium' : 'free',
      );
      await SessionService.instance.save(profile);
    }
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
    final profile = _profile;
    if (profile == null) return const OnboardingFlow();
    return PinGate(profile: profile);
  }
}

Future<void> signOutToOnboarding(BuildContext context) async {
  await SessionService.instance.clear();
  await PinService.instance.clear();
  await SecureStore.instance.delete('owner.enroll_token');
  await AppDatabase.instance.deleteSetting('sync.enroll_token');
  await AppDatabase.instance.useMainDatabase();
  AppState.instance.setOperator(null);
  await AppState.instance.refreshPinState();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const EntryGate()),
    (_) => false,
  );
}
