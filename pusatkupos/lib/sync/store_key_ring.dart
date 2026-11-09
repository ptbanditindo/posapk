import 'dart:convert';

import 'crypto.dart';

/// Kunci toko aktif dan kunci lama yang masih disimpan untuk membaca riwayat.
/// Rotasi menaikkan versi tanpa menghapus versi lama.
class StoreKeyRing {
  const StoreKeyRing({required this.activeVersion, required this.keys});

  final int activeVersion;
  final Map<int, List<int>> keys;

  List<int> get active => keys[activeVersion]!;

  int get keyIdVersionCount => keys.length;

  Map<String, List<int>> byKeyId() => {
        for (final entry in keys.entries) keyIdFor(entry.value): entry.value,
      };

  int versionForKeyId(String keyId) {
    for (final entry in keys.entries) {
      if (keyIdFor(entry.value) == keyId) return entry.key;
    }
    return 0;
  }

  StoreKeyRing withKey(int version, List<int> key, {bool activate = false}) {
    final next = Map<int, List<int>>.of(keys)..[version] = key;
    return StoreKeyRing(
      activeVersion: activate ? version : activeVersion,
      keys: next,
    );
  }

  String toJson() => jsonEncode({
        'v': 1,
        'active': activeVersion,
        'keys': {
          for (final entry in keys.entries) '${entry.key}': b64e(entry.value),
        },
      });

  static StoreKeyRing fromJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Key ring rusak.');
    final active = (decoded['active'] as num?)?.toInt() ?? 0;
    final rawKeys = decoded['keys'];
    if (rawKeys is! Map || rawKeys.isEmpty) {
      throw const FormatException('Key ring tanpa kunci.');
    }
    final keys = <int, List<int>>{};
    for (final entry in rawKeys.entries) {
      final version = int.tryParse('${entry.key}');
      if (version == null || version < 1) {
        throw const FormatException('Versi kunci tidak valid.');
      }
      keys[version] = b64d('${entry.value}');
    }
    if (!keys.containsKey(active)) {
      throw const FormatException('Kunci aktif tidak ada di key ring.');
    }
    return StoreKeyRing(activeVersion: active, keys: keys);
  }
}
