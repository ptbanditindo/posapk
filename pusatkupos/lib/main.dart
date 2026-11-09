import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/startup.dart';
import 'ui/startup_recovery.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runZonedGuarded(
    () async {
      final error = await StartupService.instance.boot();
      if (error == null) {
        runApp(const PusatkuApp());
      } else {
        runApp(StartupRecoveryApp(error: error));
      }
    },
    (error, stack) {
      // Galat asinkron di luar startup tidak boleh mematikan aplikasi tanpa
      // jejak; layar pemulihan tetap tersedia untuk kegagalan berikutnya.
      runApp(StartupRecoveryApp(error: error));
    },
  );
}
