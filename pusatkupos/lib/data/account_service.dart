import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'access_control.dart';
import 'app_database.dart';
import 'license_service.dart';
import 'login_guard.dart';
import 'store_settings.dart';

const roles = builtinRoles;
const roleLabels = builtinRoleLabels;

/// Izin yang dapat ditambahkan per akun di atas akses perannya.
Map<String, String> get permissionLabels => allAccessLabels;

const _iterations = 600000;

class AccountService {
  AccountService._();

  static final AccountService instance = AccountService._();

  Future<List<Map<String, Object?>>> listAccounts() async {
    return AppDatabase.instance.db.query(
      'employee_accounts',
      orderBy: 'nama COLLATE NOCASE',
    );
  }

  Future<Set<String>> effectivePermissions(Map<String, Object?> account) async {
    final settings = await StoreSettingsService.instance.ensure();
    return settings.accessFor(
      account['role_base'] as String? ?? 'MEKANIK',
      extras: _jsonList(account['extra_permissions_json']),
    );
  }

  Future<void> _requireKnownRole(String role) async {
    final settings = await StoreSettingsService.instance.ensure();
    final target = canonicalRole(role);
    if (!settings.roleNames.contains(target)) {
      throw ArgumentError('Peran tidak dikenal. Tambahkan peran di aturan toko.');
    }
  }

  /// Menyelaraskan akses toko eksplisit dengan data akun.
  ///
  /// Toko yang tidak lagi ditugaskan dinonaktifkan (bukan dihapus) agar
  /// pencabutan akses tetap dapat diaudit dan tidak terhidupkan kembali oleh
  /// snapshot lama.
  static Future<void> syncStoreAccess(
    DatabaseExecutor db, {
    required String employeeSyncId,
    required String role,
    required List<String> extraPermissions,
    required bool explicit,
    required bool aktif,
    required List<String> storeIds,
    int version = 1,
  }) async {
    if (employeeSyncId.isEmpty) return;
    final now = nowIso();
    final desired = storeIds.where((id) => id.trim().isNotEmpty).toSet();
    final existing = await db.query(
      'employee_store_access',
      where: 'employee_sync_id = ?',
      whereArgs: [employeeSyncId],
    );
    final byStore = {
      for (final row in existing) '${row['store_id']}': row,
    };
    final payload = {
      'role_base': role,
      'extra_permissions_json': jsonEncode(extraPermissions),
      'permissions_explicit': explicit ? 1 : 0,
      'aktif': aktif ? 1 : 0,
      'version': version,
      'updated_at': now,
    };
    for (final storeId in desired) {
      final row = byStore[storeId];
      if (row == null) {
        await db.insert('employee_store_access', {
          'sync_id': newSyncId(),
          'store_id': storeId,
          'employee_sync_id': employeeSyncId,
          'created_at': now,
          ...payload,
        });
      } else {
        await db.update(
          'employee_store_access',
          payload,
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    for (final entry in byStore.entries) {
      if (desired.contains(entry.key)) continue;
      if ((entry.value['aktif'] as int? ?? 1) == 0) continue;
      await db.update(
        'employee_store_access',
        {'aktif': 0, 'version': version, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [entry.value['id']],
      );
    }
  }

  Future<Map<String, Object?>> createAccount({
    required String username,
    required String nama,
    required String role,
    required String password,
    List<String> extraPermissions = const [],
    List<String> storeIds = const ['utama'],
    String actor = 'owner',
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    if (!await LicenseService.instance.isPremium()) {
      throw StateError(
        'Lisensi server yang valid diperlukan untuk membuat akun karyawan.',
      );
    }
    final clean = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$').hasMatch(clean)) {
      throw ArgumentError(
        'Nama pengguna 3-32 karakter, huruf kecil/angka/titik/strip.',
      );
    }
    await _requireKnownRole(role);
    role = canonicalRole(role);
    final existing = await AppDatabase.instance.db.query(
      'employee_accounts',
      columns: ['id'],
      where: 'username = ?',
      whereArgs: [clean],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw StateError('Nama pengguna sudah dipakai.');
    }
    final salt = _newSalt();
    final hash = await _derive(password, salt, _iterations);
    final now = nowIso();
    final syncId = newSyncId();
    final hlc = await AppDatabase.instance.nextSyncHlc(AppDatabase.instance.db);
    final id = await AppDatabase.instance.db.insert('employee_accounts', {
      'sync_id': syncId,
      'sync_hlc_wall': hlc.wall,
      'sync_hlc_counter': hlc.counter,
      'username': clean,
      'nama': nama.trim().isEmpty ? clean : nama.trim(),
      'role_base': role,
      'extra_permissions_json': jsonEncode(extraPermissions),
      'store_ids_json': jsonEncode(storeIds),
      'password_hash': hash,
      'password_salt': salt,
      'password_iterations': _iterations,
      'must_change_password': 1,
      'aktif': 1,
      'permission_version': 1,
      'permissions_explicit': 1,
      'created_at': now,
      'updated_at': now,
    });
    await syncStoreAccess(
      AppDatabase.instance.db,
      employeeSyncId: syncId,
      role: role,
      extraPermissions: extraPermissions,
      explicit: true,
      aktif: true,
      storeIds: storeIds,
    );
    await recordAudit(
      actor: actor,
      targetAccountId: id,
      action: 'buat akun',
      detail: {'username': clean, 'role': role},
    );
    if (enqueue != null) await enqueue(AppDatabase.instance.db, syncId);
    return (await _accountById(id))!;
  }

  Future<int> installRemoteAccount(Map<String, Object?> account) async {
    final syncId = account['sync_id'] as String? ?? '';
    final username = (account['username'] as String? ?? '').trim().toLowerCase();
    if (syncId.isEmpty || username.isEmpty) {
      throw StateError('Profil akun dari relay tidak lengkap.');
    }
    final db = AppDatabase.instance.db;
    final existing = await db.query(
      'employee_accounts',
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    final now = nowIso();
    final extras = _remoteExtras(account);
    final rawStores = account['store_ids'];
    final storeIds = rawStores is List
        ? rawStores.map((item) => '$item').toList()
        : _jsonList(rawStores);
    final version =
        (account['permission_version'] as num?)?.toInt() ?? 1;
    final values = {
      'sync_id': syncId,
      'username': username,
      'nama': (account['nama'] as String? ?? username).trim(),
      'role_base': account['role_base'] as String? ?? 'KASIR',
      'extra_permissions_json': jsonEncode(extras),
      'store_ids_json': jsonEncode(account['store_ids'] ?? []),
      'password_hash': account['password_hash'] as String? ?? '',
      'password_salt': account['password_salt'] as String? ?? '',
      'password_iterations':
          (account['password_iterations'] as num?)?.toInt() ?? _iterations,
      'must_change_password': 1,
      'aktif': account['aktif'] == false ? 0 : 1,
      'permission_version': version,
      'permissions_explicit':
          account['permissions_explicit'] == true ? 1 : 0,
      'updated_at': now,
    };
    if (existing.isNotEmpty) {
      await db.update(
        'employee_accounts',
        values,
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      await syncStoreAccess(
        db,
        employeeSyncId: syncId,
        role: '${values['role_base']}',
        extraPermissions: extras,
        explicit: values['permissions_explicit'] == 1,
        aktif: values['aktif'] == 1,
        storeIds: storeIds,
        version: version,
      );
      return existing.first['id'] as int;
    }
    final id = await db.insert('employee_accounts', {
      ...values,
      'created_at': now,
      'updated_at': now,
    });
    await syncStoreAccess(
      db,
      employeeSyncId: syncId,
      role: '${values['role_base']}',
      extraPermissions: extras,
      explicit: values['permissions_explicit'] == 1,
      aktif: values['aktif'] == 1,
      storeIds: storeIds,
      version: version,
    );
    await recordAudit(
      actor: 'relay',
      targetAccountId: id,
      action: 'pasangkan akun',
      detail: {'username': username, 'sync_id': syncId},
    );
    return id;
  }

  Future<void> applyRemotePermissions(Map<String, Object?> account) async {
    final syncId = account['sync_id'] as String? ?? '';
    if (syncId.isEmpty) return;
    final rows = await AppDatabase.instance.db.query(
      'employee_accounts',
      columns: ['id', 'permission_version'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final current = (rows.first['permission_version'] as int?) ?? 0;
    final incoming = (account['permission_version'] as num?)?.toInt() ?? 0;
    if (incoming < current) return;
    final extras = _remoteExtras(account);
    final rawStores = account['store_ids'];
    final storeIds = rawStores is List
        ? rawStores.map((item) => '$item').toList()
        : _jsonList(rawStores);
    final role = account['role_base'] as String? ?? 'KASIR';
    final aktif = account['aktif'] != false;
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'nama': account['nama'],
        'role_base': role,
        'extra_permissions_json': jsonEncode(extras),
        'store_ids_json': jsonEncode(account['store_ids'] ?? []),
        'aktif': aktif ? 1 : 0,
        'permission_version': incoming,
        'permissions_explicit':
            account['permissions_explicit'] == true ? 1 : 0,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
    await syncStoreAccess(
      AppDatabase.instance.db,
      employeeSyncId: syncId,
      role: role,
      extraPermissions: extras,
      explicit: account['permissions_explicit'] == true,
      aktif: aktif,
      storeIds: storeIds,
      version: incoming,
    );
  }

  Future<Map<String, Object?>> updateAccount(
    int id, {
    required String nama,
    required String role,
    required bool aktif,
    List<String> extraPermissions = const [],
    List<String> storeIds = const ['utama'],
    String actor = 'owner',
    Future<void> Function(DatabaseExecutor txn, String syncId)? enqueue,
  }) async {
    final before = await _accountById(id);
    if (before == null) throw StateError('Akun tidak ditemukan.');
    await _requireKnownRole(role);
    role = canonicalRole(role);
    final hlc = await AppDatabase.instance.nextSyncHlc(AppDatabase.instance.db);
    final nextVersion =
        ((before['permission_version'] as int?) ?? 1) + 1;
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'nama': nama.trim(),
        'role_base': role,
        'aktif': aktif ? 1 : 0,
        'extra_permissions_json': jsonEncode(extraPermissions),
        'store_ids_json': jsonEncode(storeIds),
        'permission_version': nextVersion,
        'permissions_explicit': 1,
        'sync_hlc_wall': hlc.wall,
        'sync_hlc_counter': hlc.counter,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await syncStoreAccess(
      AppDatabase.instance.db,
      employeeSyncId: before['sync_id'] as String? ?? '',
      role: role,
      extraPermissions: extraPermissions,
      explicit: true,
      aktif: aktif,
      storeIds: storeIds,
      version: nextVersion,
    );
    await recordAudit(
      actor: actor,
      targetAccountId: id,
      action: 'ubah akun',
      detail: {
        'sebelum': {
          'role': before['role_base'],
          'aktif': before['aktif'],
          'toko': _jsonList(before['store_ids_json']),
        },
        'sesudah': {'role': role, 'aktif': aktif, 'toko': storeIds},
      },
    );
    if (enqueue != null) {
      await enqueue(AppDatabase.instance.db, before['sync_id'] as String? ?? '');
    }
    return (await _accountById(id))!;
  }

  Future<void> resetPassword(
    int id, {
    required String password,
    String actor = 'owner',
  }) async {
    final salt = _newSalt();
    final hash = await _derive(password, salt, _iterations);
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'password_hash': hash,
        'password_salt': salt,
        'password_iterations': _iterations,
        'must_change_password': 1,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await recordAudit(
      actor: actor,
      targetAccountId: id,
      action: 'reset password',
    );
  }

  Future<void> resetPin(int id, {String actor = 'owner'}) async {
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'pin_hash': null,
        'pin_salt': null,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await recordAudit(actor: actor, targetAccountId: id, action: 'reset PIN');
  }

  Future<void> changePassword(
    int id, {
    required String oldPassword,
    required String newPassword,
  }) async {
    final account = await _accountById(id);
    if (account == null) throw StateError('Akun tidak ditemukan.');
    if (!await _verify(
      oldPassword,
      account['password_hash'] as String,
      account['password_salt'] as String,
      account['password_iterations'] as int? ?? _iterations,
    )) {
      throw StateError('Password lama salah.');
    }
    final salt = _newSalt();
    final hash = await _derive(newPassword, salt, _iterations);
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'password_hash': hash,
        'password_salt': salt,
        'password_iterations': _iterations,
        'must_change_password': 0,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await recordAudit(
      actor: 'employee:$id',
      targetAccountId: id,
      action: 'ganti password',
    );
  }

  Future<Operator?> loginHub({
    required String username,
    required String password,
    required String pin,
  }) async {
    final clean = username.trim().toLowerCase();
    final guardScope = 'hub:$clean';
    await LoginGuard.check(guardScope);
    final account = await _accountByUsername(clean);
    if (account == null ||
        account['aktif'] != 1 ||
        !await _verify(
          password,
          account['password_hash'] as String,
          account['password_salt'] as String,
          account['password_iterations'] as int? ?? _iterations,
        )) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    final pinHash = account['pin_hash'] as String?;
    if (pinHash == null || pinHash.isEmpty) {
      if (!RegExp(r'^\d{6,}$').hasMatch(pin)) {
        await LoginGuard.fail(guardScope);
        return null;
      }
      final salt = _newSalt();
      final hash = await _derive(pin, salt, _iterations);
      await AppDatabase.instance.db.update(
        'employee_accounts',
        {
          'pin_hash': hash,
          'pin_salt': salt,
          'pin_iterations': _iterations,
        },
        where: 'id = ?',
        whereArgs: [account['id']],
      );
    } else if (!await _verify(
      pin,
      pinHash,
      account['pin_salt'] as String? ?? '',
      account['pin_iterations'] as int? ?? _iterations,
    )) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    await LoginGuard.clear(guardScope);
    await _upgradePassword(
      account['id'] as int,
      password,
      account['password_iterations'] as int? ?? 0,
    );
    await _touchLogin(account['id'] as int);
    return _operator(account);
  }

  /// Login akun lokal untuk build uji tanpa layanan akun. PIN perangkat
  /// diatur terpisah setelah sesi dibuka.
  Future<Operator?> loginLocal({
    required String username,
    required String password,
  }) async {
    final clean = username.trim().toLowerCase();
    final guardScope = 'local:$clean';
    await LoginGuard.check(guardScope);
    final account = await _accountByUsername(clean);
    if (account == null ||
        account['aktif'] != 1 ||
        !await _verify(
          password,
          account['password_hash'] as String,
          account['password_salt'] as String,
          account['password_iterations'] as int? ?? _iterations,
        )) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    await LoginGuard.clear(guardScope);
    await _upgradePassword(
      account['id'] as int,
      password,
      account['password_iterations'] as int? ?? 0,
    );
    await _touchLogin(account['id'] as int);
    return _operator(account);
  }

  Future<Operator?> loginDevice({
    required String ownerId,
    required String username,
    required String password,
    required String token,
  }) async {
    final guardScope = 'device:${ownerId.trim()}';
    await LoginGuard.check(guardScope);
    final owner = await AppDatabase.instance.db.query(
      'owner_identity',
      columns: ['owner_id'],
      limit: 1,
    );
    if (owner.isEmpty || owner.first['owner_id'] != ownerId.trim()) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    final device = await AppDatabase.instance.db.query(
      'devices',
      where: 'token_hash = ? AND revoked_at IS NULL',
      whereArgs: [_hashToken(token)],
      limit: 1,
    );
    if (device.isEmpty) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    final clean = username.trim().toLowerCase();
    final account = await _accountByUsername(clean);
    if (account == null ||
        account['aktif'] != 1 ||
        device.first['employee_account_id'] != account['id'] ||
        !await _verify(
          password,
          account['password_hash'] as String,
          account['password_salt'] as String,
          account['password_iterations'] as int? ?? _iterations,
        )) {
      await LoginGuard.fail(guardScope);
      return null;
    }
    await LoginGuard.clear(guardScope);
    await _upgradePassword(
      account['id'] as int,
      password,
      account['password_iterations'] as int? ?? 0,
    );
    await _touchLogin(account['id'] as int);
    return _operator(account, deviceId: device.first['id'] as String);
  }

  Future<void> recordAudit({
    required String actor,
    int? targetAccountId,
    required String action,
    Map<String, Object?> detail = const {},
  }) async {
    await AppDatabase.instance.db.insert('permission_audits', {
      'sync_id': newSyncId(),
      'actor': actor,
      'target_account_id': targetAccountId,
      'action': action,
      'detail_json': jsonEncode(detail),
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
  }

  Future<List<Map<String, Object?>>> auditRows(int accountId) {
    return AppDatabase.instance.db.query(
      'permission_audits',
      where: 'target_account_id = ?',
      whereArgs: [accountId],
      orderBy: 'created_at DESC',
      limit: 100,
    );
  }

  Future<Operator> _operator(
    Map<String, Object?> account, {
    String? deviceId,
  }) async {
    final settings = await StoreSettingsService.instance.ensure();
    final extras = _jsonList(account['extra_permissions_json']);
    final permissions = settings.accessFor(
      account['role_base'] as String? ?? 'MEKANIK',
      extras: extras,
    );
    return Operator(
      kind: 'employee',
      role: canonicalRole(account['role_base'] as String? ?? 'MEKANIK'),
      label: account['nama'] as String? ?? 'Karyawan',
      employeeId: account['id'] as int,
      employeeSyncId: account['sync_id'] as String?,
      username: account['username'] as String,
      permissions: permissions,
      extraPermissions: extras,
      deviceId: deviceId,
      storeIds: _jsonList(account['store_ids_json']).isEmpty
          ? const ['utama']
          : _jsonList(account['store_ids_json']),
      mustChangePassword: account['must_change_password'] == 1,
    );
  }

  Future<Map<String, Object?>?> _accountById(int id) async {
    final rows = await AppDatabase.instance.db.query(
      'employee_accounts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> _accountByUsername(String username) async {
    final rows = await AppDatabase.instance.db.query(
      'employee_accounts',
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> _touchLogin(int id) async {
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {'last_login_at': nowIso()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _upgradePassword(int id, String password, int iterations) async {
    if (iterations >= _iterations) return;
    final salt = _newSalt();
    final hash = await _derive(password, salt, _iterations);
    await AppDatabase.instance.db.update(
      'employee_accounts',
      {
        'password_hash': hash,
        'password_salt': salt,
        'password_iterations': _iterations,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String> _derive(String value, String salt, int iterations) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(value)),
      nonce: base64Url.decode(salt),
    );
    return base64UrlEncode(await key.extractBytes());
  }

  Future<bool> _verify(
    String value,
    String hash,
    String salt,
    int iterations,
  ) async {
    if (salt.isEmpty) return false;
    final derived = await _derive(value, salt, iterations);
    return derived == hash;
  }

  String _newSalt() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  String _hashToken(String token) {
    return crypto.sha256.convert(utf8.encode(token)).toString();
  }

  List<String> _jsonList(Object? value) {
    try {
      final decoded = jsonDecode(value as String? ?? '[]');
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (_) {}
    return const [];
  }

  /// `extra_permissions` dari relay adalah izin efektif; `permission_grants`
  /// menyimpan tambahan semantik per akun agar pencabutan akses peran tidak
  /// tertahan oleh izin lama di perangkat.
  List<String> _remoteExtras(Map<String, Object?> account) {
    final grants = account['permission_grants'];
    final explicit = account['permissions_explicit'] == true;
    if (explicit && grants is List) {
      return grants.map((item) => '$item').toList();
    }
    final extras = account['extra_permissions'];
    if (extras is List) return extras.map((item) => '$item').toList();
    if (grants is List) return grants.map((item) => '$item').toList();
    return _jsonList(extras);
  }
}
