import 'package:flutter/material.dart';

import 'data/restore_lock.dart';
import 'state/app_state.dart';
import 'ui/entry_gate.dart';
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
          builder: (context, child) {
            return AnimatedBuilder(
              animation: Listenable.merge([RestoreLock.instance, AppState.instance]),
              builder: (context, _) {
                final content = child ?? const SizedBox.shrink();
                final scene = AppState.instance.scene;
                final busy = scene == AppScene.restoring ||
                    scene == AppScene.switchingStore;
                if (!busy) return content;
                return Stack(
                  children: [
                    content,
                    _BusyOverlay(switchingStore: scene == AppScene.switchingStore),
                  ],
                );
              },
            );
          },
          home: const EntryGate(),
        );
      },
    );
  }
}

/// Menghalangi aksi lain selama database sedang ditukar atau toko berganti.
class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay({required this.switchingStore});

  final bool switchingStore;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      switchingStore
                          ? 'Berpindah toko'
                          : 'Restore sedang berjalan',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switchingStore
                          ? 'Tunggu sampai database toko tujuan selesai dibuka.'
                          : 'Jangan menutup aplikasi atau mematikan perangkat '
                              'sampai proses selesai.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
