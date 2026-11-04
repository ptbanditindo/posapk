/// Evaluasi kelengkapan satu putaran sinkron.
///
/// Putaran dianggap lengkap hanya bila setiap perangkat tulis yang tercatat
/// saat putaran dibuka sudah mengaku menerima data sampai `latestSeq` dan
/// tidak menyisakan perubahan lokal. Perangkat yang dicabut tidak lagi
/// dihitung. Bila ada data baru masuk setelah putaran dibuka, putaran
/// dianggap basi dan harus dibuka ulang.
Map<String, Object?> evaluateSyncRound({
  required int latestSeq,
  required int currentLatestSeq,
  required List<Map<String, Object?>> devices,
  required List<Map<String, Object?>> acks,
  required Set<String> revokedDeviceIds,
}) {
  final ackByDevice = <String, Map<String, Object?>>{
    for (final ack in acks) '${ack['device_id']}': ack,
  };
  final states = <Map<String, Object?>>[];
  var required = 0;
  var synced = 0;
  for (final device in devices) {
    final id = '${device['id'] ?? ''}';
    if (id.isEmpty) continue;
    final base = {
      'id': id,
      'nama': '${device['nama'] ?? 'Perangkat'}',
      'kind': '${device['kind'] ?? 'owner'}',
    };
    if (revokedDeviceIds.contains(id)) {
      states.add({...base, 'state': 'revoked', 'last_seq': 0, 'pending': 0});
      continue;
    }
    required++;
    final ack = ackByDevice[id];
    final lastSeq = (ack?['last_seq'] as num?)?.toInt() ?? 0;
    final pending = (ack?['pending_count'] as num?)?.toInt() ?? 0;
    final ready = ack != null && lastSeq >= latestSeq && pending == 0;
    if (ready) synced++;
    states.add({
      ...base,
      'state': ready ? 'synced' : 'pending',
      'last_seq': lastSeq,
      'pending': pending,
      'acked_at': ack?['acked_at'],
    });
  }
  final stale = currentLatestSeq > latestSeq;
  return {
    'latest_seq': latestSeq,
    'current_latest_seq': currentLatestSeq,
    'total': required,
    'synced': synced,
    'stale': stale,
    'complete': required > 0 && synced == required && !stale,
    'devices': states,
  };
}
