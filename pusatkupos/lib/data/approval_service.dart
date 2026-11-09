import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'login_guard.dart';
import 'pin_service.dart';
import 'store_settings.dart';

class ApprovalResult {
  const ApprovalResult({required this.label, required this.isOwner});

  final String label;
  final bool isOwner;
}

/// Grant persetujuan: hasil verifikasi yang berlaku untuk seluruh baris pada
/// satu transaksi. PIN hanya membuka grant; grant inilah yang memberi izin.
class ApprovalGrant extends ApprovalResult {
  ApprovalGrant({
    required super.label,
    required super.isOwner,
    DateTime? verifiedAt,
  }) : verifiedAt = verifiedAt ?? DateTime.now();

  final DateTime verifiedAt;
}

class ApprovalException implements Exception {
  ApprovalException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Persetujuan pengecualian. Pemilik dapat menunjuk satu penanggung jawab
/// (akun karyawan aktif dengan izin `setujui`) agar persetujuan tidak selalu
/// harus lewat pemilik.
class ApprovalService {
  ApprovalService._();

  static final ApprovalService instance = ApprovalService._();

  bool needsDelegatedApprover(StoreSettings settings) =>
      settings.approverMode == approverEmployee;

  /// [executor] wajib diisi bila dipanggil di dalam transaksi database agar
  /// verifikasi memakai koneksi transaksi yang sama.
  Future<ApprovalGrant> verify({
    required StoreSettings settings,
    String? ownerPin,
    String? approverSecret,
    DatabaseExecutor? executor,
  }) async {
    if (!needsDelegatedApprover(settings)) {
      final pin = (ownerPin ?? '').trim();
      if (pin.isEmpty) {
        throw ApprovalException('PIN pemilik diperlukan untuk menyetujui.');
      }
      final verification = await PinService.instance.verifyDetailed(
        pin,
        executor: executor,
      );
      if (verification == PinVerification.locked) {
        throw ApprovalException('Persetujuan pemilik terkunci. Coba lagi.');
      }
      if (verification == PinVerification.weakLegacyPin) {
        throw ApprovalException(
          'PIN pemilik masih lemah. Ganti ke minimal 6 digit sebelum '
          'menyetujui.',
        );
      }
      if (verification != PinVerification.ok) {
        throw ApprovalException('PIN pemilik tidak valid.');
      }
      return ApprovalGrant(label: 'Pemilik', isOwner: true);
    }

    final syncId = (settings.approverEmployeeSyncId ?? '').trim();
    if (syncId.isEmpty) {
      throw ApprovalException(
        'Penanggung jawab persetujuan belum dipilih di pengaturan toko.',
      );
    }
    final db = executor ?? AppDatabase.instance.db;
    final rows = await db.query(
      'employee_accounts',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['aktif'] != 1) {
      throw ApprovalException('Akun penanggung jawab tidak aktif.');
    }
    final account = rows.first;
    final role = account['role_base'] as String? ?? 'KASIR';
    if (!settings.roleAllows(role, 'setujui')) {
      throw ApprovalException(
        'Peran $role belum diberi izin menyetujui oleh pemilik.',
      );
    }
    final secret = (approverSecret ?? '').trim();
    if (secret.isEmpty) {
      throw ApprovalException('PIN penanggung jawab diperlukan.');
    }
    final scope = 'approver:$syncId';
    try {
      await LoginGuard.check(scope, executor: executor);
    } on LoginLockedException {
      throw ApprovalException('Persetujuan penanggung jawab terkunci.');
    }
    final pinHash = account['pin_hash'] as String?;
    var valid = false;
    if (pinHash != null && pinHash.isNotEmpty) {
      valid = await _verify(
        secret,
        pinHash,
        account['pin_salt'] as String? ?? '',
        (account['pin_iterations'] as num?)?.toInt() ?? 120000,
      );
    } else {
      valid = await _verify(
        secret,
        account['password_hash'] as String? ?? '',
        account['password_salt'] as String? ?? '',
        (account['password_iterations'] as num?)?.toInt() ?? 120000,
      );
    }
    if (!valid) {
      await LoginGuard.fail(scope, executor: executor);
      throw ApprovalException('PIN penanggung jawab tidak valid.');
    }
    await LoginGuard.clear(scope, executor: executor);
    final nama =
        '${account['nama'] ?? account['username'] ?? 'Penanggung jawab'}';
    return ApprovalGrant(label: '$nama (Penanggung jawab)', isOwner: false);
  }

  Future<bool> _verify(
    String value,
    String hash,
    String salt,
    int iterations,
  ) async {
    if (salt.isEmpty || hash.isEmpty) return false;
    final key =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: iterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(value)),
          nonce: base64Url.decode(salt),
        );
    return base64UrlEncode(await key.extractBytes()) == hash;
  }
}
