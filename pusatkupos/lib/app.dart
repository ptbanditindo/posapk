import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/pin_gate.dart';
import 'ui/theme.dart';

class PusatkuApp extends StatelessWidget {
  const PusatkuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'PusatkuPOS',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: AppState.instance.themeMode,
          home: const PinGate(),
        );
      },
    );
  }
}
