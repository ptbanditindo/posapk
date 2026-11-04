import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/app_database.dart';
import 'data/backup_scheduler.dart';
import 'dev/dummy_seed.dart';
import 'state/app_state.dart';
import 'sync/sync_scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');
  await AppDatabase.instance.init();
  await seedDummyDataIfEnabled();
  await AppState.instance.load();
  BackupScheduler.instance.start();
  SyncScheduler.instance.start();
  runApp(const PusatkuApp());
}
