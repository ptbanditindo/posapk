import 'dart:convert';

import '../auth/operator.dart';
import 'app_database.dart';
import 'secure_store.dart';

const _profileKey = 'session.profile';
const _pinSaltKey = 'session.pin_salt';
const _pinHashKey = 'session.pin_hash';
const _pinIterationsKey = 'session.pin_iterations';

class SessionProfile {
  const SessionProfile({
    required this.mode,
    required this.ownerId,
    required this.nama,
    required this.role,
    this.employeeSyncId,
    this.username,
    this.permissions = const [],
    this.storeIds = const ['utama'],
    this.mustChangePassword = false,
    this.email,
    this.plan = 'free',
    this.periodEnd,
  });

  /// `free`, `premium`, `employee`, atau `viewer`.
  final String mode;
  final String ownerId;
  final String nama;
  final String role;
  final String? employeeSyncId;
  final String? username;
  final List<String> permissions;
  final List<String> storeIds;
  final bool mustChangePassword;
  final String? email;
  final String plan;
  final String? periodEnd;

  bool get isOwner => mode != 'employee';

  /// Mode ringkasan laporan: hanya membaca data toko dan mengelola akses.
  bool get isViewer => mode == 'viewer';

  Map<String, Object?> toJson() => {
        'mode': mode,
        'owner_id': ownerId,
        'nama': nama,
        'role': role,
        'employee_sync_id': employeeSyncId,
        'username': username,
        'permissions': permissions,
        'store_ids': storeIds,
        'must_change_password': mustChangePassword,
        'email': email,
        'plan': plan,
        'period_end': periodEnd,
      };

  factory SessionProfile.fromJson(Map<String, Object?> json) {    List<String> list(Object? value) =>
        (value is List) ? value.map((item) => '$item').toList() : const [];
    return SessionProfile(
      mode: '${json['mode'] ?? 'free'}',
      ownerId: '${json['owner_id'] ?? ''}',
      nama: '${json['nama'] ?? ''}',
      role: '${json['role'] ?? 'owner'}',
      employeeSyncId: json['employee_sync_id'] as String?,
      username: json['username'] as String?,
      permissions: list(json['permissions']),
      storeIds: list(json['store_ids']).isEmpty
          ? const ['utama']
          : list(json['store_ids']),
      mustChangePassword: json['must_change_password'] == true,
      email: json['email'] as String?,
      plan: '${json['plan'] ?? 'free'}',
      periodEnd: json['period_end'] as String?,
    );
  }

  SessionProfile copyWith({
    String? mode,
    String? ownerId,
    String? nama,
    String? role,
    String? employeeSyncId,
    String? username,
    List<String>? permissions,
    List<String>? storeIds,
    bool? mustChangePassword,
    String? email,
    String? plan,
    String? periodEnd,
  }) =>
      SessionProfile(
        mode: mode ?? this.mode,
        ownerId: ownerId ?? this.ownerId,
        nama: nama ?? this.nama,
        role: role ?? this.role,
        employeeSyncId: employeeSyncId ?? this.employeeSyncId,
        username: username ?? this.username,
        permissions: permissions ?? this.permissions,
        storeIds: storeIds ?? this.storeIds,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
        email: email ?? this.email,
        plan: plan ?? this.plan,
        periodEnd: periodEnd ?? this.periodEnd,
      );

  Operator toOperator() => Operator(
        kind: isOwner ? 'owner' : 'employee',
        role: isOwner ? 'owner' : role,
        label: nama.isEmpty ? (isOwner ? 'Pemilik' : 'Karyawan') : nama,
        employeeSyncId: employeeSyncId,
        username: username,
        permissions: permissions.toSet(),
        storeIds: storeIds,
        mustChangePassword: mustChangePassword,
      );
}

class SessionService {
  SessionService._();

  static final SessionService instance = SessionService._();

  SessionProfile? _cached;

  SessionProfile? get cached => _cached;

  Future<SessionProfile?> load() async {
    if (_cached != null) return _cached;
    final raw = await SecureStore.instance.read(_profileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      _cached = SessionProfile.fromJson(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
      return _cached;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SessionProfile profile) async {
    await SecureStore.instance.write(_profileKey, jsonEncode(profile.toJson()));
    _cached = profile;
    await AppDatabase.instance.setSetting('app.mode', profile.mode);
    await AppDatabase.instance
        .setSetting('app.role', profile.isOwner ? 'owner' : 'employee');
    final ownerRows = await AppDatabase.instance.db.query(
      'owner_identity',
      columns: ['owner_id'],
      limit: 1,
    );
    final localOwner =
        ownerRows.isEmpty ? '' : '${ownerRows.first['owner_id'] ?? ''}';
    if (profile.ownerId.isNotEmpty &&
        (localOwner.isEmpty || localOwner == profile.ownerId)) {
      AppDatabase.instance.setSetting('app.owner_id', profile.ownerId);
    }
  }

  Future<void> clear() async {
    _cached = null;
    await SecureStore.instance.delete(_profileKey);
    await SecureStore.instance.delete(_pinSaltKey);
    await SecureStore.instance.delete(_pinHashKey);
    await SecureStore.instance.delete(_pinIterationsKey);
    await SecureStore.instance.delete('session.device_token');
    await AppDatabase.instance.deleteSetting('app.mode');
    await AppDatabase.instance.deleteSetting('app.role');
  }

  Future<void> savePin(String hash, String salt, int iterations) async {
    await SecureStore.instance.write(_pinSaltKey, salt);
    await SecureStore.instance.write(_pinHashKey, hash);
    await SecureStore.instance.write(_pinIterationsKey, '$iterations');
  }

  Future<({String salt, String hash, int iterations})?> readPin() async {
    final salt = await SecureStore.instance.read(_pinSaltKey);
    final hash = await SecureStore.instance.read(_pinHashKey);
    final iterations = int.tryParse(
      await SecureStore.instance.read(_pinIterationsKey) ?? '',
    );
    if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) {
      return null;
    }
    return (salt: salt, hash: hash, iterations: iterations ?? 0);
  }

  Future<void> clearPin() async {
    await SecureStore.instance.delete(_pinSaltKey);
    await SecureStore.instance.delete(_pinHashKey);
    await SecureStore.instance.delete(_pinIterationsKey);
  }

  Future<void> saveDeviceToken(String? token, String? deviceId) async {
    if (token == null || token.isEmpty) return;
    await SecureStore.instance.write('session.device_token', token);
    await AppDatabase.instance.setSetting('sync.relay_device_token', token);
    if (deviceId != null && deviceId.isNotEmpty) {
      await AppDatabase.instance.setSetting('sync.relay_device_id', deviceId);
    }
  }
}
