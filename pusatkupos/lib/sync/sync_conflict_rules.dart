import '../auth/permissions.dart';

/// Kegagalan yang masih bisa berhasil bila dicoba lagi setelah delta lain
/// (misalnya induk baris) diterapkan.
class RetryableSyncException implements Exception {
  RetryableSyncException(this.message, {this.code = 'retryable'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Amplop dibuat oleh versi protokol yang lebih baru dari yang dikenal
/// perangkat ini. Bukan dead-letter: kursor berhenti sebelum amplop dan
/// pengguna diminta memperbarui aplikasi (D26).
class ProtocolVersionException implements Exception {
  const ProtocolVersionException(this.requiredVersion, {this.received = 0});

  final int requiredVersion;
  final int received;

  @override
  String toString() =>
      'Amplop memakai protokol v$received, perangkat ini hanya mengenal '
      'v$requiredVersion. Perbarui aplikasi untuk melanjutkan sinkronisasi.';
}

/// Konflik domain yang menuntut dokumen kompensasi. Transaksi penerapan
/// dibatalkan, lalu antrean kompensasi ditulis di luar transaksi agar tidak
/// ikut ter-rollback.
class CompensationRequired extends RetryableSyncException {
  CompensationRequired({
    required this.kind,
    required this.notaSyncId,
    required this.returnSyncIds,
    required String message,
    this.detail = const {},
    String code = 'kompensasi_dibutuhkan',
  }) : super(message, code: code);

  /// `cancel_return` satu-satunya kompensasi otomatis yang aman saat ini.
  final String kind;
  final String notaSyncId;
  final List<String> returnSyncIds;
  final Map<String, Object?> detail;
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
    this.revoked = false,
    this.accountActive = true,
    this.employeeSyncId = '',
  });

  const SenderProfile.legacy(this.kind)
      : roleBase = '',
        extraPermissions = const {},
        permissionsExplicit = false,
        storeIds = const [],
        legacyAll = true,
        revoked = false,
        accountActive = true,
        employeeSyncId = '';

  final String kind; // owner | employee | viewer
  final String roleBase; // owner | peran bawaan | peran kustom
  final Set<String> extraPermissions;

  /// Bila true, izin yang dikirim sudah final; izin bawaan peran tidak
  /// ditambahkan lagi.
  final bool permissionsExplicit;
  final List<String> storeIds;

  /// Hanya dipakai harness lama yang belum mengirim profil perangkat.
  final bool legacyAll;

  /// Perangkat sudah dicabut pemilik. Amplop yang belum diterapkan tidak
  /// boleh menambah data baru.
  final bool revoked;

  /// Status akun karyawan pada saat sinkronisasi. Perangkat pemilik selalu
  /// dianggap aktif.
  final bool accountActive;
  final String employeeSyncId;

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
      permissionStockOut,
    },
    'GUDANG': {permissionStockIn},
    'MEKANIK': {'ubah_status'},
    'SUPERVISOR': {
      'buat_nota',
      'buat_estimasi',
      'buat_order',
      'ubah_status',
      'ubah_stok',
      'koreksi',
      'beri_kredit',
      permissionStockIn,
      permissionStockOut,
      permissionOpname,
    },
    'KEDUANYA': {
      'buat_nota',
      'buat_estimasi',
      'buat_order',
      'ubah_status',
      'ubah_stok',
      'koreksi',
      'beri_kredit',
      permissionStockIn,
      permissionStockOut,
      permissionOpname,
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
    'harga_tidak_valid',
    'stok_negatif',
    'koreksi_di_bawah_batas',
    'koreksi_pada_nota_void',
    'rekonsiliasi_beda',
    'no_nota_bentrok',
    'pembayaran_melebihi_total',
    'gaji_ganda',
    'retur_pada_nota_void',
    'retur_melebihi_qty',
    'retur_baris_tidak_ditemukan',
    'retur_tidak_valid',
    'void_setelah_retur',
    'komisi_akun_hilang',
    'komisi_tanpa_snapshot',
    'kode_barang_bentrok',
    'kode_barang_kosong',
    'pembelian_void_final',
    'pembelian_tanpa_supplier',
    'no_pembelian_bentrok',
    'pembayaran_melebihi_sisa',
    'pembayaran_pada_pembelian_void',
    'retur_pembelian_melebihi_qty',
    'retur_pembelian_void',
    'saldo_awal_ganda',
    'saldo_awal_stok_berubah',
    'fitur_nonaktif',
  };

  static const Set<String> priceEntities = {'harga_jasa'};
  static const Set<String> ownerOnlyEntities = {
    'store_settings',
    'store_feature',
    'opening_balance',
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
    'pengirim_dicabut',
    'akun_pengirim_nonaktif',
    'toko_tidak_cocok',
    'pembayaran_ppn_melebihi_sisa',
  };

  static bool isFinal(String reason) =>
      finalReasons.contains(reason) || reason.startsWith('peran_tidak_berhak');

  /// Amplop yang tidak akan pernah berhasil diverifikasi ulang. Setelah
  /// menjadi dead-letter, amplop tidak menahan kursor perangkat lain.
  static const Set<String> permanentReasons = {
    'tanda_tangan_tidak_valid',
    'dekripsi_gagal',
    'amplop_tidak_lengkap',
    'petunjuk_tidak_cocok',
    'idempotency_tidak_valid',
    'konflik_unik',
  };

  static bool isPermanent(Object error) =>
      permanentReasons.contains(reasonFor(error));

  /// Konflik kompensasi yang boleh berakhir sebagai bantuan owner. Dipakai
  /// layar Konflik untuk menandai item yang sudah melewati tenggang 7 hari.
  static const Set<String> ownerHelpReasons = {
    'void_setelah_retur',
    'retur_pada_nota_void',
    'retur_melebihi_qty',
    'koreksi_pada_nota_void',
  };

  static const Duration ownerHelpAfter = Duration(days: 7);

  /// Aturan umum Lampiran C: HLC lebih awal menang; bila sama, `device_id`
  /// terkecil menang. Nilai negatif berarti `a` lebih awal.
  static int compareHlc({
    required int aWall,
    required int aCounter,
    required String aDevice,
    required int bWall,
    required int bCounter,
    required String bDevice,
  }) {
    if (aWall != bWall) return aWall < bWall ? -1 : 1;
    if (aCounter != bCounter) return aCounter < bCounter ? -1 : 1;
    if (aDevice == bDevice) return 0;
    return aDevice.compareTo(bDevice);
  }

  static bool aEarlierThanB({
    required int aWall,
    required int aCounter,
    required String aDevice,
    required int bWall,
    required int bCounter,
    required String bDevice,
  }) =>
      compareHlc(
        aWall: aWall,
        aCounter: aCounter,
        aDevice: aDevice,
        bWall: bWall,
        bCounter: bCounter,
        bDevice: bDevice,
      ) <
      0;

  /// Pesan yang dapat langsung ditindaklanjuti pengguna, bukan kode internal.
  static String suggestionFor(Object error) =>
      suggestionForReason(reasonFor(error));

  /// Versi berbasis alasan tersimpan, dipakai layar Konflik.
  static String suggestionForReason(String reason) {
    return switch (reason) {
      'kunci_toko_tidak_cocok' =>
        'Muat ulang kunci toko dari perangkat pemilik, lalu coba lagi.',
      'tanda_tangan_tidak_valid' || 'dekripsi_gagal' =>
        'Minta pemilik mengirim ulang kunci toko. Bila tetap gagal, '
            'abaikan amplop ini dan minta perangkat pengirim mengirim ulang.',
      'amplop_tidak_lengkap' || 'petunjuk_tidak_cocok' ||
      'idempotency_tidak_valid' =>
        'Amplop rusak dan tidak dapat dipulihkan. Minta perangkat pengirim '
            'mengirim ulang dokumennya.',
      'konflik_unik' =>
        'Data bentrok dengan dokumen lain. Selesaikan bentrok lalu coba lagi.',
      'kompensasi_dibutuhkan' || 'kompensasi_gagal' =>
        'Perangkat asal perlu menerbitkan dokumen kompensasi. Bila tidak '
            'selesai dalam 7 hari, pemilik dapat menyelesaikannya dari layar '
            'Konflik.',
      _ => '',
    };
  }

  static const Set<String> employeeEntities = {
    'nota',
    'customer',
    'unit',
    'stock',
    'stock_movement',
    'supplier',
    'supplier_followup',
    'estimate',
    'work_order',
    'work_order_status',
    'nota_adjustment',
    'day_digest',
    'data_response',
    'supplier_purchase',
    'supplier_payment',
    'supplier_purchase_return',
  };

  static const Map<String, String> employeeExtraPermission = {
    'estimate': 'buat_estimasi',
    'work_order': 'buat_order',
    'work_order_status': 'ubah_status',
    'nota_adjustment': 'koreksi',
    'stock': 'ubah_stok',
    'supplier': 'ubah_supplier',
    'supplier_purchase': 'buat_pembelian',
    'supplier_payment': 'bayar_utang',
    'supplier_purchase_return': 'buat_pembelian',
  };

  /// Alasan konflik bila peran pengirim tidak berhak, atau `null` bila boleh.
  static String? senderViolation({
    required SenderProfile sender,
    required String entity,
    required String action,
    Map<String, Object?> payload = const {},
  }) {
    // Status perangkat/akun diperiksa sebelum isi payload dipercaya. Amplop
    // lama dari perangkat yang sudah dicabut atau akun nonaktif tidak boleh
    // menambah data baru.
    if (sender.revoked) return 'pengirim_dicabut';
    if (!sender.accountActive) return 'akun_pengirim_nonaktif';
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
        if (_notaNeedsCreditPermission(payload) &&
            !sender.can(permissionCredit)) {
          return 'peran_tidak_berhak_$permissionCredit';
        }
      }
      if (entity == 'stock_movement') {
        final jenis = '${payload['jenis'] ?? ''}'.toUpperCase();
        final required = switch (jenis) {
          'MASUK' => permissionStockIn,
          'KELUAR' => permissionStockOut,
          _ when payload['opname_absolut_milli'] != null => permissionOpname,
          _ => permissionChangeStock,
        };
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

  /// Nota dengan sisa bayar butuh izin kredit pengirim, kecuali sudah
  /// disetujui (label persetujuan ikut pada payload).
  static bool _notaNeedsCreditPermission(Map<String, Object?> payload) {
    final record = payload['record'];
    if (record is! Map) return false;
    final sisa = (record['sisa_bayar'] as num?)?.toInt() ?? 0;
    if (sisa <= 0) return false;
    final approver = '${record['kredit_disetujui_oleh'] ?? ''}'.trim();
    return approver.isEmpty;
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
    if (text.contains('kunci toko tidak cocok')) {
      return 'kunci_toko_tidak_cocok';
    }
    if (text.contains('amplop tanpa') || text.contains('tidak lengkap')) {
      return 'amplop_tidak_lengkap';
    }
    if (text.contains('petunjuk') || text.contains('tidak cocok dengan isi')) {
      return 'petunjuk_tidak_cocok';
    }
    if (text.contains('idempotency')) return 'idempotency_tidak_valid';
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
