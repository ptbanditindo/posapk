class Operator {
  const Operator({
    required this.kind,
    required this.role,
    required this.label,
    this.employeeId,
    this.username,
    this.permissions = const {},
    this.deviceId,
    this.mustChangePassword = false,
  });

  final String kind; // owner | employee
  final String role; // owner | KASIR | MEKANIK | KEDUANYA
  final String label;
  final int? employeeId;
  final String? username;
  final Set<String> permissions;
  final String? deviceId;
  final bool mustChangePassword;

  bool get isOwner => kind == 'owner';
  bool get canWriteMoney =>
      isOwner || role == 'KASIR' || role == 'KEDUANYA';
  bool get canVoid => canWriteMoney;
  bool can(String permission) => permissions.contains(permission);

  static const owner = Operator(
    kind: 'owner',
    role: 'owner',
    label: 'Pemilik',
    permissions: {
      'opname',
      'stok_masuk',
      'stok_keluar',
      'lihat_laporan',
      'cetak_laporan',
      'baca_supplier',
      'baca_followup',
      'kelola_akun',
      'kelola_perangkat',
      'lisensi',
    },
  );
}
