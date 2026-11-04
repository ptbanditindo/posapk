/// Kegagalan yang masih bisa berhasil bila dicoba lagi setelah delta lain
/// (misalnya induk baris) diterapkan.
class RetryableSyncException implements Exception {
  RetryableSyncException(this.message, {this.code = 'retryable'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Satu tempat untuk aturan konflik sinkronisasi.
///
/// - Harga jasa (`harga_jasa`): hanya perangkat `owner` yang boleh menang.
///   Perubahan dari karyawan/viewer ditolak dan dicatat sebagai konflik.
/// - Data master lain (pelanggan, unit, barang, supplier, follow-up supplier,
///   komisi, hutang, gaji): versi dengan HLC (`hlc_wall`, `hlc_counter`)
///   terbesar yang menang. Urutan kedatangan amplop tidak menentukan.
/// - HLC sama: versi yang sudah ada dipertahankan dan kedatangan dicatat
///   sebagai konflik agar tidak terjadi ping-pong antar perangkat.
/// - Nota final (jasa/part/pembayaran) tidak dapat diubah; hanya status
///   garansi, pengambilan unit, dan pembayaran tambahan yang boleh menyusul.
class SyncConflictRules {
  static const int maxRetries = 8;
  static const String priceEntity = 'harga_jasa';

  /// Entity yang boleh ditulis perangkat karyawan. Server relay memakai daftar
  /// yang sama, tetapi klien memeriksa ulang setelah amplop didekripsi karena
  /// petunjuk terang di relay tidak dapat dibaca isinya oleh server.
  static const Set<String> employeeEntities = {
    'nota',
    'customer',
    'unit',
    'stock',
    'stock_movement',
    'supplier_followup',
  };

  /// Alasan konflik bila peran pengirim tidak berhak atas entity/action,
  /// atau `null` bila boleh diterapkan. `senderKind` berasal dari daftar
  /// perangkat relay dan terikat pada kunci yang memverifikasi tanda tangan.
  static String? senderViolation({
    required String senderKind,
    required String entity,
    required String action,
  }) {
    if (senderKind == 'viewer') return 'peran_viewer_hanya_baca';
    if (ownerWins(entity) && senderKind != 'owner') {
      return 'harga_dikunci_owner';
    }
    if (senderKind == 'employee' && !employeeEntities.contains(entity)) {
      return 'peran_tidak_berhak';
    }
    return null;
  }

  /// 1, 2, 4, ... menit, dibatasi 240 menit.
  static Duration backoffFor(int retryCount) {
    final shift = retryCount < 0 ? 0 : (retryCount > 8 ? 8 : retryCount);
    final minutes = 1 << shift;
    return Duration(minutes: minutes > 240 ? 240 : minutes);
  }

  static bool ownerWins(String entity) => entity == priceEntity;

  static bool isRetryable(Object error) => error is RetryableSyncException;

  static String reasonFor(Object error) {
    if (error is RetryableSyncException) return error.code;
    final text = '$error'.toLowerCase();
    if (text.contains('tanda tangan')) return 'tanda_tangan_tidak_valid';
    if (text.contains('dekripsi')) return 'dekripsi_gagal';
    if (text.contains('unique') || text.contains('constraint')) {
      return 'konflik_unik';
    }
    return 'gagal_terapkan';
  }
}
