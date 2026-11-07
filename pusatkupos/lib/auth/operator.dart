class Operator {
  const Operator({
    required this.kind,
    required this.role,
    required this.label,
    this.employeeId,
    this.employeeSyncId,
    this.username,
    this.permissions = const {},
    this.extraPermissions = const [],
    this.deviceId,
    this.storeIds = const ['utama'],
    this.mustChangePassword = false,
  });

  final String kind; // owner | employee
  final String role; // owner | peran bawaan | peran kustom
  final String label;
  final int? employeeId;
  final String? employeeSyncId;
  final String? username;
  final Set<String> permissions;
  final List<String> extraPermissions;
  final String? deviceId;
  final List<String> storeIds;
  final bool mustChangePassword;

  bool get isOwner => kind == 'owner';
  bool get canWriteMoney => can('buat_nota');
  bool get canVoid => can('void');
  bool can(String permission) => isOwner || permissions.contains(permission);

  static const owner = Operator(
    kind: 'owner',
    role: 'owner',
    label: 'Pemilik',
    permissions: {
      'void',
      'retur',
      'koreksi',
      'ubah_harga_jasa',
      'ubah_stok',
      'stok_masuk',
      'stok_keluar',
      'opname',
      'diskon',
      'lihat_laporan',
      'cetak_laporan',
      'backup',
      'kelola_akun',
      'kelola_perangkat',
      'lisensi',
      'lihat_karyawan',
      'lihat_pengaturan',
      'lihat_premium',
    },
  );
}
