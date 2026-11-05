import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../core/app_config.dart';
import '../data/license_service.dart';
import '../data/reconciliation_service.dart';
import 'sync_service.dart';

/// Sinkronisasi otomatis selama aplikasi berjalan.
///
/// Tanpa paket konektivitas tambahan, penggantinya adalah pemeriksaan berkala
/// yang juga berfungsi sebagai percobaan ulang saat koneksi kembali, ditambah
/// percobaan langsung ketika aplikasi kembali ke depan atau ditutup.
/// `SyncService.syncNow` memegang kunci tunggal, jadi pemanggilan bersamaan
/// aman.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  static const defaultIntervalMinutes = 15;
  static const minIntervalMinutes = 10;
  static const maxIntervalMinutes = 20;

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  DateTime? _lastAttempt;
  Duration _interval = const Duration(minutes: defaultIntervalMinutes);

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    configuredInterval().then((value) {
      if (!_started) return;
      _interval = value;
      _scheduleNext();
    }).catchError((Object _) {
      if (_started) _scheduleNext();
      return const Duration(minutes: defaultIntervalMinutes);
    });
    tick();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  /// Selang 10-20 menit yang ditentukan pemilik, ditambah jitter ±1-2 menit.
  Future<Duration> configuredInterval() async {
    final raw = await SyncService.instance.setting('sync.interval_minutes');
    final minutes =
        (int.tryParse(raw ?? '') ?? defaultIntervalMinutes).clamp(
      minIntervalMinutes,
      maxIntervalMinutes,
    );
    return Duration(minutes: minutes);
  }

  void _scheduleNext() {
    _timer?.cancel();
    final random = Random();
    final jitterSeconds = (random.nextBool() ? 1 : -1) *
        (60 + random.nextInt(61));
    final jitter = Duration(seconds: jitterSeconds);
    _timer = Timer(_interval + jitter, () async {
      try {
        await tick(force: true);
      } finally {
        if (!_started) return;
        try {
          _interval = await configuredInterval();
        } catch (_) {
          // Pakai interval terakhir bila pengaturan belum dapat dibaca.
        }
        _scheduleNext();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      tick(force: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Satu sinkronisasi terakhir saat aplikasi ditutup atau shift berakhir.
      tick(force: true);
    }
  }

  Future<void> tick({bool force = false}) async {
    if (_running) return;
    final now = DateTime.now();
    if (!force &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < _interval) {
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
      await ReconciliationService.instance.publishRecent(
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueDayDigest(syncId, txn: txn),
      );
      await SyncService.instance.syncNow();
    } catch (_) {
      // Pesan tersimpan di `sync.last_error`; periode berikutnya mencoba lagi.
    } finally {
      _running = false;
    }
  }
}
