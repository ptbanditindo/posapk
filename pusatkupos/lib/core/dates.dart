import 'package:intl/intl.dart';

final DateFormat dateOnly = DateFormat('yyyy-MM-dd');
final DateFormat dateTimeId = DateFormat('dd MMM yyyy HH:mm', 'id_ID');
final DateFormat dateId = DateFormat('dd MMM yyyy', 'id_ID');
final DateFormat monthId = DateFormat('MMMM yyyy', 'id_ID');

const String zonaWaktuDefault = 'Asia/Jakarta';

const Map<String, int> zonaWaktuOffsets = {
  'Asia/Jakarta': 7 * 60,
  'Asia/Makassar': 8 * 60,
  'Asia/Jayapura': 9 * 60,
};

String zonaWaktuLabel(String zona) => switch (zona) {
      'Asia/Makassar' => 'WITA (UTC+8)',
      'Asia/Jayapura' => 'WIT (UTC+9)',
      _ => 'WIB (UTC+7)',
    };

int zonaWaktuOffsetMenit(String zona) =>
    zonaWaktuOffsets[zona] ?? zonaWaktuOffsets[zonaWaktuDefault]!;

int _storeOffsetMinutes = zonaWaktuOffsets[zonaWaktuDefault]!;

/// Offset zona toko dipakai untuk semua tampilan dan filter tanggal laporan.
/// Indonesia tidak memakai DST, jadi offset tetap per zona.
void setZonaWaktuToko(String zona) {
  _storeOffsetMinutes = zonaWaktuOffsetMenit(zona);
}

/// Waktu dinding toko sebagai DateTime UTC. Format tanggal membaca field UTC,
/// sehingga hasilnya seragam di perangkat dengan zona sistem berbeda.
DateTime storeWallTime(DateTime value) =>
    value.toUtc().add(Duration(minutes: _storeOffsetMinutes));

String nowIso() => DateTime.now().toUtc().toIso8601String();
String todayKey() => dateOnly.format(storeWallTime(DateTime.now()));

DateTime startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

String isoStartOfDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day)
        .subtract(Duration(minutes: _storeOffsetMinutes))
        .toIso8601String();
String isoEndOfDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day, 23, 59, 59, 999)
        .subtract(Duration(minutes: _storeOffsetMinutes))
        .toIso8601String();

DateTime localTime(Object? value) {
  final parsed = value is DateTime
      ? value
      : DateTime.tryParse('${value ?? ''}') ?? DateTime.now();
  return storeWallTime(parsed);
}
