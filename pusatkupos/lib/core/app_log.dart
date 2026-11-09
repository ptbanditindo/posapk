import 'dart:collection';
import 'dart:developer' as developer;

/// Kategori log terstruktur agar diagnosa dapat disaring per area.
enum LogCategory { database, sync, backup, auth, business }

class LogEntry {
  const LogEntry({
    required this.time,
    required this.category,
    required this.event,
    required this.data,
    this.errorType,
  });

  final DateTime time;
  final LogCategory category;
  final String event;
  final Map<String, Object?> data;
  final String? errorType;

  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'category': category.name,
    'event': event,
    'data': data,
    if (errorType != null) 'error': errorType,
  };
}

/// Log ringkas di memori (maksimal [maxEntries]).
///
/// Nilai sensitif tidak pernah disimpan: kunci yang memuat pin/password/
/// token/secret/hash/salt dibuang, dan pesan error mentah tidak disimpan.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int maxEntries = 200;

  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void event(
    LogCategory category,
    String event, {
    Map<String, Object?> data = const {},
    Object? error,
  }) {
    final entry = LogEntry(
      time: DateTime.now(),
      category: category,
      event: event,
      data: _sanitize(data),
      errorType: error?.runtimeType.toString(),
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    developer.log(event, name: 'pusatkupos.${category.name}');
  }

  /// Mencatat hasil operasi tanpa mengubah alur atau exception.
  Future<T> trace<T>(
    LogCategory category,
    String event,
    Future<T> Function() action,
  ) async {
    this.event(category, '$event.start');
    try {
      final result = await action();
      this.event(category, '$event.ok');
      return result;
    } catch (error) {
      this.event(category, '$event.fail', error: error);
      rethrow;
    }
  }

  void clear() => _entries.clear();

  static const _sensitiveKeyParts = [
    'pin',
    'password',
    'passphrase',
    'token',
    'secret',
    'hash',
    'salt',
    'auth',
    'license',
    'recovery',
  ];

  static Map<String, Object?> _sanitize(Map<String, Object?> data) {
    final safe = <String, Object?>{};
    for (final entry in data.entries) {
      final key = entry.key.toLowerCase();
      if (_sensitiveKeyParts.any(key.contains)) continue;
      final value = entry.value;
      if (value is String) {
        safe[entry.key] =
            value.length <= 120 ? value : '${value.substring(0, 120)}...';
      } else if (value is num || value is bool || value == null) {
        safe[entry.key] = value;
      } else {
        safe[entry.key] = '<${value.runtimeType}>';
      }
    }
    return safe;
  }
}
