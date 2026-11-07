import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/sync/sync_conflict_rules.dart';

void main() {
  group('relayHistoryPruned', () {
    test('pemilik baru tidak dianggap dipangkas walau seq global tinggi', () {
      expect(
        relayHistoryPruned(cursor: 0, logStart: 5120, prunedThrough: 0),
        isFalse,
      );
    });

    test('relay lama dengan kursor nol juga tidak dianggap dipangkas', () {
      expect(relayHistoryPruned(cursor: 0, logStart: 5120), isFalse);
    });

    test('amplop yang belum diakui perangkat dianggap dipangkas', () {
      expect(
        relayHistoryPruned(cursor: 100, logStart: 500, prunedThrough: 260),
        isTrue,
      );
    });

    test('pemangkasan di belakang kursor tidak mengganggu', () {
      expect(
        relayHistoryPruned(cursor: 300, logStart: 301, prunedThrough: 260),
        isFalse,
      );
    });

    test('relay lama tetap mendeteksi pemangkasan saat kursor berjalan', () {
      expect(relayHistoryPruned(cursor: 100, logStart: 500), isTrue);
    });

    test('relay lama tanpa pemangkasan tidak memicu kesalahan', () {
      expect(relayHistoryPruned(cursor: 700, logStart: 640), isFalse);
    });
  });
}
