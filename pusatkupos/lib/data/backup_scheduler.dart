import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backup_service.dart';

/// Menjalankan backup harian selama aplikasi terbuka. Bila aplikasi sempat
/// tertutup pada jam backup, pekerjaan disusulkan saat aplikasi dibuka lagi.
class BackupScheduler {
  BackupScheduler._();

  static final BackupScheduler instance = BackupScheduler._();

  Timer? _timer;
  bool _running = false;

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
    if (_running || kIsWeb) return;
    _running = true;
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
    }
  }

  DateTime _scheduledAt(DateTime now, String jam) {
    final parts = jam.split(':');
    final hour = int.tryParse(parts.first) ?? 2;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(now.year, now.month, now.day, hour, minute);
  }
}
