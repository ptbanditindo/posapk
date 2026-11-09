import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backup_service.dart';
import 'restore_lock.dart';

/// Menjalankan backup harian selama aplikasi terbuka. Bila aplikasi sempat
/// tertutup pada jam backup, pekerjaan disusulkan saat aplikasi dibuka lagi.
class BackupScheduler {
  BackupScheduler._();

  static final BackupScheduler instance = BackupScheduler._();

  Timer? _timer;
  bool _running = false;
  Completer<void>? _tickDone;

  bool get isRunning => _running;

  /// Menunggu backup otomatis yang sedang berjalan selesai sebelum restore
  /// menukar berkas database.
  Future<void> whenIdle() async {
    final done = _tickDone;
    if (done == null) return;
    try {
      await done.future;
    } catch (_) {
      // Kegagalan backup sudah dicatat di status backup.
    }
  }

  void start() {
    if (kIsWeb) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick() async {
    if (_running || kIsWeb || RestoreLock.instance.isRestoring) return;
    _running = true;
    final done = Completer<void>();
    _tickDone = done;
    try {
      final settings = await BackupService.instance.loadSettings();
      if (!settings.autoEnabled) return;
      final now = DateTime.now();
      final scheduled = _scheduledAt(now, settings.jam);
      if (now.isBefore(scheduled)) return;
      final lastAttempt = await BackupService.instance.lastAttemptAt();
      if (lastAttempt != null &&
          now.difference(lastAttempt) < telegramRetryInterval) {
        return;
      }
      final lastLocal = await BackupService.instance.lastLocalAt();
      if (lastLocal == null || lastLocal.isBefore(scheduled)) {
        await BackupService.instance.createAutomaticBackup();
        return;
      }
      if (settings.telegramEnabled &&
          await BackupService.instance.telegramPending()) {
        await BackupService.instance.retryTelegramBackup();
      }
    } catch (_) {
      // Scheduler mencoba lagi pada menit berikutnya.
    } finally {
      _running = false;
      if (identical(_tickDone, done)) _tickDone = null;
      done.complete();
    }
  }

  DateTime _scheduledAt(DateTime now, String jam) {
    final parts = jam.split(':');
    final hour = int.tryParse(parts.first) ?? 2;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(now.year, now.month, now.day, hour, minute);
  }
}
