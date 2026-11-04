import 'package:pusatkupos_relay/sync_round.dart';
import 'package:test/test.dart';

void main() {
  const devices = [
    {'id': 'dev_owner', 'nama': 'Pemilik', 'kind': 'owner'},
    {'id': 'dev_a', 'nama': 'Karyawan A', 'kind': 'employee'},
    {'id': 'dev_b', 'nama': 'Karyawan B', 'kind': 'employee'},
    {'id': 'dev_c', 'nama': 'Karyawan C', 'kind': 'employee'},
  ];

  Map<String, Object?> evaluate({
    required List<Map<String, Object?>> acks,
    int latest = 40,
    int current = 40,
    Set<String> revoked = const {},
  }) {
    return evaluateSyncRound(
      latestSeq: latest,
      currentLatestSeq: current,
      devices: devices,
      acks: acks,
      revokedDeviceIds: revoked,
    );
  }

  test('satu karyawan belum sync membuat cadangan tidak lengkap', () {
    final result = evaluate(
      acks: [
        {'device_id': 'dev_owner', 'last_seq': 40, 'pending_count': 0},
        {'device_id': 'dev_a', 'last_seq': 40, 'pending_count': 0},
        {'device_id': 'dev_b', 'last_seq': 40, 'pending_count': 0},
      ],
    );
    expect(result['complete'], isFalse);
    expect(result['synced'], 3);
    expect(result['total'], 4);
    final states = (result['devices'] as List).cast<Map>();
    final c = states.firstWhere((item) => item['id'] == 'dev_c');
    expect(c['state'], 'pending');
  });

  test('semua perangkat mengaku sync membuat putaran lengkap', () {
    final result = evaluate(
      acks: [
        for (final device in devices)
          {
            'device_id': device['id'],
            'last_seq': 40,
            'pending_count': 0,
          },
      ],
    );
    expect(result['complete'], isTrue);
    expect(result['stale'], isFalse);
    expect(result['synced'], 4);
  });

  test('perubahan lokal yang belum terkirim menahan upload', () {
    final result = evaluate(
      acks: [
        for (final device in devices)
          {
            'device_id': device['id'],
            'last_seq': 40,
            'pending_count': device['id'] == 'dev_b' ? 2 : 0,
          },
      ],
    );
    expect(result['complete'], isFalse);
    final states = (result['devices'] as List).cast<Map>();
    final b = states.firstWhere((item) => item['id'] == 'dev_b');
    expect(b['state'], 'pending');
    expect(b['pending'], 2);
  });

  test('perangkat dengan urutan tertinggal menahan upload', () {
    final result = evaluate(
      acks: [
        for (final device in devices)
          {
            'device_id': device['id'],
            'last_seq': device['id'] == 'dev_c' ? 37 : 40,
            'pending_count': 0,
          },
      ],
    );
    expect(result['complete'], isFalse);
  });

  test('perangkat yang dicabut tidak lagi dihitung', () {
    final result = evaluate(
      acks: [
        for (final device in devices.where((item) => item['id'] != 'dev_c'))
          {
            'device_id': device['id'],
            'last_seq': 40,
            'pending_count': 0,
          },
      ],
      revoked: {'dev_c'},
    );
    expect(result['complete'], isTrue);
    expect(result['total'], 3);
    final states = (result['devices'] as List).cast<Map>();
    final c = states.firstWhere((item) => item['id'] == 'dev_c');
    expect(c['state'], 'revoked');
  });

  test('data baru setelah putaran dibuka membatalkan kelengkapan', () {
    final result = evaluate(
      acks: [
        for (final device in devices)
          {
            'device_id': device['id'],
            'last_seq': 40,
            'pending_count': 0,
          },
      ],
      current: 42,
    );
    expect(result['stale'], isTrue);
    expect(result['complete'], isFalse);
  });

  test('tanpa perangkat terdaftar gate tetap menolak', () {
    final result = evaluateSyncRound(
      latestSeq: 1,
      currentLatestSeq: 1,
      devices: const [],
      acks: const [],
      revokedDeviceIds: const {},
    );
    expect(result['complete'], isFalse);
  });
}
