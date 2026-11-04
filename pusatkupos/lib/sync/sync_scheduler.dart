import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_config.dart';
import '../data/license_service.dart';
import 'sync_service.dart';

/// Sinkronisasi otomatis selama aplikasi berjalan.
///
/// Tanpa paket konektivitas tambahan, penggantinya adalah pemeriksaan berkala
/// yang juga berfungsi sebagai percobaan ulang saat koneksi kembali, ditambah
/// percobaan langsung ketika aplikasi kembali ke depan. `SyncService.syncNow`
/// sudah memegang kunci tunggal, jadi pemanggilan bersamaan aman.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  static const interval = Duration(minutes: 2);

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  DateTime? _lastAttempt;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => tick());
    tick();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) tick(force: true);
  }

  Future<void> tick({bool force = false}) async {
    if (_running) return;
    final now = DateTime.now();
    if (!force &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < interval) {
      return;
    }
    _running = true;
    _lastAttempt = now;
    try {
      if (!serviceConfigured) return;
      if (!await LicenseService.instance.isPremium()) return;
      final url = await SyncService.instance.relayUrl();
      if (url == null || url.isEmpty) return;
      final deviceId = await SyncService.instance.relayDeviceId();
      final token = await SyncService.instance.relayDeviceToken();
      if (deviceId == null ||
          deviceId.isEmpty ||
          token == null ||
          token.isEmpty) {
        return;
      }
      await SyncService.instance.syncNow();
    } catch (_) {
      // Pesan tersimpan di `sync.last_error`; periode berikutnya mencoba lagi.
    } finally {
      _running = false;
    }
  }
}
