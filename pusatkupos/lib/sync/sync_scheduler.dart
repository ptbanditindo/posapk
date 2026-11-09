import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_config.dart';
import '../data/license_service.dart';
import '../data/period_closing_service.dart';
import '../data/purge_service.dart';
import '../data/reconciliation_service.dart';
import '../data/restore_lock.dart';
import 'archive_service.dart';
import 'compensation_service.dart';
import 'sync_service.dart';

/// Sinkronisasi otomatis selama aplikasi berjalan.
///
/// Perubahan lokal memicu `requestSync` dengan debounce 3 detik sehingga
/// beberapa perubahan berdekatan terkirim sebagai satu putaran. Sebagai
/// jaring pengaman, saat aplikasi di depan tetap ada percobaan ringan setiap
/// 15 menit dan setiap kembali ke depan. Tidak ada timer yang berjalan saat
/// aplikasi di belakang.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  static const fallbackInterval = Duration(minutes: 15);
  static const debounceDelay = Duration(seconds: 3);

  Timer? _fallbackTimer;
  Timer? _debounceTimer;
  bool _started = false;
  bool _running = false;
  bool _foreground = true;
  Completer<void>? _tickDone;

  bool get isStarted => _started;

  /// Menunggu putaran `tick` yang sedang berjalan selesai, termasuk pekerjaan
  /// sebelum `syncNow` dipanggil.
  Future<void> whenIdle() async {
    final done = _tickDone;
    if (done == null) return;
    try {
      await done.future;
    } catch (_) {
      // Alasan gagal sudah dicatat di `sync.last_error`.
    }
  }

  void start() {
    if (_started) return;
    _started = true;
    _foreground = true;
    WidgetsBinding.instance.addObserver(this);
    _scheduleFallback();
    tick();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// Dipanggil setelah perubahan lokal masuk outbox. Beberapa panggilan
  /// berdekatan digabung menjadi satu putaran sinkronisasi.
  void requestSync() {
    if (!_started || !_foreground) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounceDelay, () {
      _debounceTimer = null;
      if (!_started || !_foreground) return;
      tick(force: true);
    });
  }

  void _scheduleFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (!_started || !_foreground) return;
    _fallbackTimer = Timer(fallbackInterval, () async {
      _fallbackTimer = null;
      if (!_started || !_foreground) return;
      try {
        await tick(force: true);
      } finally {
        if (_started && _foreground) _scheduleFallback();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _scheduleFallback();
      tick(force: true);
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Tanpa sinkronisasi latar belakang: hentikan semua timer.
      _foreground = false;
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
      _debounceTimer?.cancel();
      _debounceTimer = null;
    }
  }

  Future<void> tick({bool force = false}) async {
    if (!_foreground && !force) return;
    if (_running || RestoreLock.instance.isRestoring) return;
    _running = true;
    final done = Completer<void>();
    _tickDone = done;
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
      await CompensationService.instance.processPending();
      await ReconciliationService.instance.publishRecent(
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueDayDigest(syncId, txn: txn),
      );
      await SyncService.instance.syncNow();
      // Arsip berjalan setelah sync dan tidak menahan penjualan; kegagalan
      // arsip hanya tercatat per dokumen.
      await ArchiveService.instance.processPending();
      await PeriodClosingService.instance.maybeAutoClose();
      await PurgeService.instance.run();
    } catch (_) {
      // Pesan tersimpan di `sync.last_error`; periode berikutnya mencoba lagi.
    } finally {
      _running = false;
      if (identical(_tickDone, done)) _tickDone = null;
      done.complete();
    }
  }
}
