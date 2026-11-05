/// Aturan otorisasi murni yang dipakai `RelayServer`.
///
/// Dipisahkan dari server agar dapat diuji tanpa PostgreSQL. Server tetap
/// tidak dapat membaca isi amplop; `entity` dan `action` adalah petunjuk
/// terang yang ditandatangani perangkat pada `hints_signature` (wajib).
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

const Map<String, Set<String>> baseRolePermissions = {
  'KASIR': {
    'buat_nota',
    'buat_estimasi',
    'buat_order',
    'ubah_status',
    'ubah_stok',
    'koreksi',
    'followup',
  },
  'MEKANIK': {'ubah_status'},
  'KEDUANYA': {
    'buat_nota',
    'buat_estimasi',
    'buat_order',
    'ubah_status',
    'ubah_stok',
    'koreksi',
    'followup',
  },
};

bool employeeEntityAllowed({
  required String entity,
  required String action,
  required String roleBase,
  required Set<String> extras,
}) {
  if (entity.isEmpty || action.isEmpty) return false;
  bool allowed(String permission) =>
      extras.contains(permission) ||
      (baseRolePermissions[roleBase]?.contains(permission) ?? false);
  if (entity == 'supplier_followup') return allowed('followup');
  if (entity == 'nota') {
    if (action == 'void') return allowed('void');
    if (action == 'warranty' || action == 'taken') {
      return allowed('ubah_status');
    }
    return allowed('buat_nota');
  }
  const direct = {
    'customer',
    'unit',
    'day_digest',
    'data_response',
  };
  if (direct.contains(entity)) return true;
  // Harga jasa hanya dari pemilik. Data barang dan mutasinya boleh diubah
  // karyawan yang punya izin stok; penerima tetap menolak bila harga ikut
  // berubah.
  if (entity == 'harga_jasa') return false;
  if (entity == 'stock' || entity == 'stock_movement') {
    return allowed('ubah_stok');
  }
  if (entity == 'estimate') return allowed('buat_estimasi');
  if (entity == 'work_order') return allowed('buat_order');
  if (entity == 'work_order_status') return allowed('ubah_status');
  if (entity == 'nota_adjustment') return allowed('koreksi');
  return false;
}
