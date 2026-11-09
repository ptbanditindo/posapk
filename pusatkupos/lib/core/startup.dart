import 'package:intl/date_symbol_data_local.dart';

import '../data/app_database.dart';
import '../data/backup_scheduler.dart';
import '../dev/dummy_seed.dart';
import '../state/app_state.dart';
import '../sync/sync_scheduler.dart';
import 'app_log.dart';
import 'startup_diagnosis.dart';

/// Urutan pembukaan aplikasi. Dipakai [main] dan layar pemulihan agar
/// kegagalan inisialisasi tidak menghasilkan layar kosong tanpa jalan keluar.
class StartupService {
  StartupService._();

  static final StartupService instance = StartupService._();

  bool _localeReady = false;

  /// Mengembalikan error bila startup gagal. [quarantine] memindahkan
  /// database yang rusak ke berkas `.corrupt-*` sebelum membuat yang baru.
  Future<Object?> boot({bool quarantine = false}) async {
    try {
      if (!_localeReady) {
        await initializeDateFormatting('id_ID');
        _localeReady = true;
      }
      if (quarantine) {
        await AppDatabase.instance.openSafeMode();
      } else {
        await AppDatabase.instance.init();
      }
      await seedDummyDataIfEnabled();
      await AppState.instance.load();
      BackupScheduler.instance.start();
      SyncScheduler.instance.start();
      return null;
    } catch (error) {
      final diagnosis = diagnoseStartupError(error);
      AppLog.instance.event(
        LogCategory.database,
        quarantine ? 'startup.safe_mode.fail' : 'startup.fail',
        data: {
          'cause': diagnosis.cause,
          'action': diagnosis.action,
        },
        error: error,
      );
      return error;
    }
  }
}
