import 'package:intl/intl.dart';

final DateFormat dateOnly = DateFormat('yyyy-MM-dd');
final DateFormat dateTimeId = DateFormat('dd MMM yyyy HH:mm', 'id_ID');
final DateFormat dateId = DateFormat('dd MMM yyyy', 'id_ID');

String nowIso() => DateTime.now().toUtc().toIso8601String();
String todayKey() => dateOnly.format(DateTime.now());

DateTime startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

String isoStartOfDay(DateTime value) =>
    startOfDay(value).toUtc().toIso8601String();
String isoEndOfDay(DateTime value) =>
    endOfDay(value).toUtc().toIso8601String();

DateTime localTime(Object? value) {
  final parsed = value is DateTime
      ? value
      : DateTime.tryParse('${value ?? ''}') ?? DateTime.now();
  return parsed.toLocal();
}
