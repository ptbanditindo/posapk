import 'package:flutter/foundation.dart';

/// Kunci tunggal proses restore.
///
/// Selama restore berjalan, scheduler sync/backup dan aksi UI lain harus
/// berhenti agar tidak menulis ke database yang sedang ditukar. UI mendengarkan
/// [instance] untuk menampilkan penghalang "restore dalam proses".
class RestoreLock extends ChangeNotifier {
  RestoreLock._();

  static final RestoreLock instance = RestoreLock._();

  bool _restoring = false;

  bool get isRestoring => _restoring;

  /// Mengambil kunci. Mengembalikan `false` bila restore lain sedang berjalan.
  bool begin() {
    if (_restoring) return false;
    _restoring = true;
    notifyListeners();
    return true;
  }

  void end() {
    if (!_restoring) return;
    _restoring = false;
    notifyListeners();
  }
}
