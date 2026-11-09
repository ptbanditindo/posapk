import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/core/app_log.dart';

void main() {
  setUp(() => AppLog.instance.clear());
  tearDown(() => AppLog.instance.clear());

  test('kunci sensitif dibuang dan nilai panjang dipotong', () {
    AppLog.instance.event(
      LogCategory.auth,
      'login',
      data: {
        'pin': '123456',
        'password_hash': 'abc',
        'license_token': 'xyz',
        'store_id': 'utama',
        'catatan': 'a' * 200,
      },
    );

    final data = AppLog.instance.entries.single.data;
    expect(data.containsKey('pin'), isFalse);
    expect(data.containsKey('password_hash'), isFalse);
    expect(data.containsKey('license_token'), isFalse);
    expect(data['store_id'], 'utama');
    expect('${data['catatan']}'.length, 123);
    expect('${data['catatan']}'.endsWith('...'), isTrue);
  });

  test('error hanya menyimpan tipe, bukan pesan mentah', () {
    AppLog.instance.event(
      LogCategory.sync,
      'kirim',
      error: StateError('token=rahasia'),
    );

    final entry = AppLog.instance.entries.single;
    expect(entry.errorType, 'StateError');
    expect(entry.toJson().toString(), isNot(contains('rahasia')));
  });

  test('ring buffer dibatasi 200 entri', () {
    for (var i = 0; i < AppLog.maxEntries + 5; i++) {
      AppLog.instance.event(LogCategory.database, 'event-$i');
    }

    expect(AppLog.instance.entries, hasLength(AppLog.maxEntries));
    expect(AppLog.instance.entries.first.event, 'event-5');
  });

  test('trace mencatat start/ok dan start/fail tanpa menelan error', () async {
    final value = await AppLog.instance.trace(
      LogCategory.business,
      'nota',
      () async => 42,
    );
    expect(value, 42);
    expect(
      AppLog.instance.entries.map((entry) => entry.event),
      ['nota.start', 'nota.ok'],
    );

    AppLog.instance.clear();
    await expectLater(
      AppLog.instance.trace<void>(
        LogCategory.business,
        'nota',
        () async => throw ArgumentError('gagal'),
      ),
      throwsArgumentError,
    );
    final failed = AppLog.instance.entries.last;
    expect(failed.event, 'nota.fail');
    expect(failed.errorType, 'ArgumentError');
  });
}
