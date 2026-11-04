/// Aturan otorisasi murni yang dipakai `RelayServer`.
///
/// Dipisahkan dari server agar dapat diuji tanpa PostgreSQL. Server tetap
/// tidak dapat membaca isi amplop; `entity` dan `action` adalah petunjuk
/// terang yang ditandatangani perangkat pada `hints_signature` (perangkat
/// lama mungkin belum mengirimnya).
/// Perangkat ringkasan hanya membaca; selain viewer boleh mengirim amplop
/// (karyawan tetap dibatasi oleh [employeeEntityAllowed]).
bool canDeviceSubmitEnvelope(String kind) => kind != 'viewer';

/// Field yang ditandatangani perangkat pada `hints_signature`.
Map<String, Object?> envelopeHintFields({
  required String storeId,
  required String senderDeviceId,
  required String entity,
  required String action,
  required String entityId,
  required String idempotencyKey,
}) {
  return {
    'store_id': storeId,
    'sender_device_id': senderDeviceId,
    'entity': entity,
    'action': action,
    'entity_id': entityId,
    'idempotency_key': idempotencyKey,
  };
}

bool employeeEntityAllowed({
  required String entity,
  required String action,
  required String roleBase,
  required Set<String> extras,
}) {
  if (entity.isEmpty || action.isEmpty) return false;
  if (entity == 'supplier_followup') {
    return extras.contains('followup') ||
        roleBase == 'KASIR' ||
        roleBase == 'KEDUANYA';
  }
  const allowed = {'nota', 'customer', 'unit', 'stock_movement'};
  if (allowed.contains(entity)) return true;
  if (entity == 'harga_jasa') return extras.contains('ubah_harga_jasa');
  if (entity == 'stock') {
    return action == 'delta' || extras.contains('ubah_stok');
  }
  return false;
}
