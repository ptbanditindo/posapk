import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/core/app_config.dart';
import 'package:pusatkupos/core/app_log.dart';
import 'package:pusatkupos/data/diagnostics_service.dart';
import 'package:pusatkupos/data/schema.dart';

import '../support/test_harness.dart';

void main() {
  final harness = ServiceTestHarness();

  setUp(() async {
    await harness.setUp();
    await createOperationalSchema(harness.db);
    AppLog.instance.clear();
  });
  tearDown(() async {
    AppLog.instance.clear();
    await harness.tearDown();
  });

  test('diagnostik memuat versi dan meredaksi rahasia', () async {
    final db = harness.db;
    await db.insert('app_meta', {
      'key': 'sync.last_error',
      'value': 'gagal token=abc123',
    });
    await db.insert('app_meta', {
      'key': 'device.kode_lokal',
      'value': 'utama-01',
    });
    await db.insert('sync_outbox', {
      'device_id': 'dev-1',
      'seq': 1,
      'hlc_wall': 1,
      'hlc_counter': 0,
      'idempotency_key': 'uji-1',
      'entity': 'nota',
      'action': 'upsert',
      'status': 'pending',
      'retry_count': 2,
      'error': 'kunci=rahasia',
      'created_at': '2026-11-09T00:00:00',
    });
    await db.insert('business_audits', {
      'sync_id': 'audit-1',
      'waktu': '2026-11-09T00:00:00',
      'aktor': 'pemilik',
      'aksi': 'void',
      'entity': 'nota',
      'alasan': 'password=hunter2',
      'created_at': '2026-11-09T00:00:00',
      'updated_at': '2026-11-09T00:00:00',
    });
    AppLog.instance.event(
      LogCategory.sync,
      'uji.log',
      data: {'token': 'harus-hilang', 'store_id': 'utama'},
    );

    final diagnostics = await DiagnosticsService.instance.collect();
    expect(diagnostics['versi_aplikasi'], appVersion);
    expect(diagnostics['outbox'], {'pending': 1});
    expect(
      (diagnostics['sinkronisasi'] as Map)['sync.last_error'],
      'gagal token=***',
    );
    expect(
      (diagnostics['outbox_galat'] as List).first['error'],
      'kunci=***',
    );
    expect(
      (diagnostics['audit_terakhir'] as List).first['alasan'],
      'password=***',
    );
    final log = (diagnostics['log_terakhir'] as List).first as Map;
    expect(log['event'], 'uji.log');
    expect((log['data'] as Map).containsKey('token'), isFalse);

    final text = await DiagnosticsService.instance.exportText();
    expect(text, isNot(contains('abc123')));
    expect(text, isNot(contains('rahasia')));
    expect(text, isNot(contains('hunter2')));
  });
}
