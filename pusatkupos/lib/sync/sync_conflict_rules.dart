/// Kegagalan yang masih bisa berhasil bila dicoba lagi setelah delta lain
/// (misalnya induk baris) diterapkan.
class RetryableSyncException implements Exception {
  RetryableSyncException(this.message, {this.code = 'retryable'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Profil pengirim diambil dari daftar perangkat relay dan terikat pada kunci
/// yang memverifikasi tanda tangan amplop. Relay tidak membaca isi payload.
class SenderProfile {
  const SenderProfile({
    required this.kind,
    this.roleBase = '',
    this.extraPermissions = const {},
    this.permissionsExplicit = false,
    this.storeIds = const [],
    this.legacyAll = false,
  });

  const SenderProfile.legacy(this.kind)
      : roleBase = '',
        extraPermissions = const {},
        permissionsExplicit = false,
        storeIds = const [],
        legacyAll = true;

  final String kind; // owner | employee | viewer
  final String roleBase; // owner | peran bawaan | peran kustom
  final Set<String> extraPermissions;

  /// Bila true, izin yang dikirim sudah final; izin bawaan peran tidak
  /// ditambahkan lagi.
  final bool permissionsExplicit;
  final List<String> storeIds;

  /// Hanya dipakai harness lama yang belum mengirim profil perangkat.
  final bool legacyAll;

  /// Izin bawaan per peran relay. Pemilik dapat menambah lewat
  /// `extra_permissions`; pengaturan toko di perangkat tetap bisa mematikan.
  static const Map<String, Set<String>> baseRolePermissions = {
    'KASIR': {
      'buat_nota',
      'buat_estimasi',
      'buat_order',
      'ubah_status',
      'ubah_stok',
      'koreksi',
    },
    'MEKANIK': {'ubah_status'},
    'SUPERVISOR': {
      'buat_nota',
      'buat_estimasi',
      'buat_order',
      'ubah_status',
      'ubah_stok',
      'koreksi',
    },
    'KEDUANYA': {
      'buat_nota',
      'buat_estimasi',
      'buat_order',
      'ubah_status',
      'ubah_stok',
      'koreksi',
    },
  };

  bool get isOwner => kind == 'owner';

  bool can(String permission) =>
      isOwner ||
      legacyAll ||
      extraPermissions.contains(permission) ||
      (!permissionsExplicit &&
          (baseRolePermissions[roleBase]?.contains(permission) ?? false));
}

/// Satu tempat untuk aturan konflik sinkronisasi.
///
/// - Harga (`harga_jasa`, `stock`), pengaturan toko, dan permintaan
///   rekonsiliasi hanya boleh berasal dari perangkat owner.
/// - Data master lain memakai HLC terbesar.
/// - Nota final tidak diubah; koreksi adalah baris append-only.
/// - Entity sensitif dari perangkat karyawan diperiksa terhadap
///   `extra_permissions` sebelum diterapkan.
class SyncConflictRules {
  static const int maxRetries = 8;

  /// Delta tetap diterapkan karena versi lokal lebih baru (HLC menang).
  static const Set<String> supersededReasons = {'versi_lokal_lebih_baru'};

  /// Data diterapkan, tetapi pemilik perlu meninjau hasilnya.
  static const Set<String> reviewReasons = {
    'harga_di_bawah_batas',
    'stok_negatif',
    'koreksi_di_bawah_batas',
    'rekonsiliasi_beda',
    'no_nota_bentrok',
  };

  static const Set<String> priceEntities = {'harga_jasa'};
  static const Set<String> ownerOnlyEntities = {
    'store_settings',
    'data_request',
  };

  /// Konflik yang sudah final: perubahan tidak diterapkan, tetapi tidak
  /// menghalangi kursor sinkronisasi. Pemilik tetap melihatnya di daftar
  /// konflik.
  static const Set<String> finalReasons = {
    'peran_viewer_hanya_baca',
    'hanya_owner',
    'harga_dikunci_owner',
    'hapus_order_hanya_owner',
    'peran_tidak_berhak',
  };

  static bool isFinal(String reason) =>
      finalReasons.contains(reason) || reason.startsWith('peran_tidak_berhak');

  static const Set<String> employeeEntities = {
    'nota',
    'customer',
    'unit',
    'stock',
    'stock_movement',
    'supplier_followup',
    'estimate',
    'work_order',
    'work_order_status',
    'nota_adjustment',
    'day_digest',
    'data_response',
  };

  static const Map<String, String> employeeExtraPermission = {
    'estimate': 'buat_estimasi',
    'work_order': 'buat_order',
    'work_order_status': 'ubah_status',
    'nota_adjustment': 'koreksi',
    'stock': 'ubah_stok',
    'stock_movement': 'ubah_stok',
  };

  /// Alasan konflik bila peran pengirim tidak berhak, atau `null` bila boleh.
  static String? senderViolation({
    required SenderProfile sender,
    required String entity,
    required String action,
  }) {
    if (sender.kind == 'viewer') return 'peran_viewer_hanya_baca';
    if (ownerOnlyEntities.contains(entity) && !sender.isOwner) {
      return 'hanya_owner';
    }
    if (priceEntities.contains(entity) && !sender.isOwner) {
      return 'harga_dikunci_owner';
    }
    if (!sender.isOwner) {
      if (!employeeEntities.contains(entity)) {
        return 'peran_tidak_berhak';
      }
      if (entity == 'nota') {
        final required = action == 'void'
            ? 'void'
            : (action == 'warranty' || action == 'taken')
                ? 'ubah_status'
                : 'buat_nota';
        if (!sender.can(required)) return 'peran_tidak_berhak_$required';
      }
      final required = employeeExtraPermission[entity];
      if (required != null && !sender.can(required)) {
        return 'peran_tidak_berhak_$required';
      }
      if (entity == 'work_order' && action == 'delete') {
        return 'hapus_order_hanya_owner';
      }
    }
    return null;
  }

  /// 1, 2, 4, ... menit, dibatasi 240 menit.
  static Duration backoffFor(int retryCount) {
    final shift = retryCount < 0 ? 0 : (retryCount > 8 ? 8 : retryCount);
    final minutes = 1 << shift;
    return Duration(minutes: minutes > 240 ? 240 : minutes);
  }

  static bool ownerWins(String entity) => ownerOnlyEntities.contains(entity);

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

/// Relay memakai satu deret `relay_seq` untuk semua pemilik dan toko. Karena
/// itu `log_start_seq` bisa jauh di atas kursor perangkat baru tanpa ada data
/// yang hilang. `pruned_through` adalah batas yang dicatat relay hanya saat
/// retensi benar-benar menghapus amplop; relay lama belum mengirimkannya.
bool relayHistoryPruned({
  required int cursor,
  required int logStart,
  int? prunedThrough,
}) {
  if (prunedThrough != null) {
    return prunedThrough > 0 && prunedThrough > cursor;
  }
  return cursor > 0 && logStart > 0 && logStart > cursor + 1;
}
