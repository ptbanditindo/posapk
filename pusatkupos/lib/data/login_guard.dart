import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

const int maxLoginFailures = 5;

class LoginLockedException implements Exception {
  LoginLockedException(this.until);

  final DateTime until;

  @override
  String toString() {
    final seconds = until.difference(DateTime.now()).inSeconds.clamp(1, 86400);
    return 'Terlalu banyak percobaan. Coba lagi dalam $seconds detik.';
  }
}

/// Lockout bertingkat yang dipakai PIN pemilik dan login perangkat.
///
/// Operasi di dalam transaksi wajib meneruskan [executor] agar tidak memakai
/// koneksi database utama saat transaksi masih terbuka (sqflite menunggu
/// koneksi yang sama dan dapat deadlock).
class LoginGuard {
  LoginGuard._();

  static Future<void> check(String scope, {DatabaseExecutor? executor}) async {
    final db = executor ?? AppDatabase.instance.db;
    final rows = await db.query(
      'login_guards',
      where: 'scope = ?',
      whereArgs: [scope],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final lock = DateTime.tryParse(rows.first['lock_until'] as String? ?? '');
    if (lock != null && lock.isAfter(DateTime.now())) {
      throw LoginLockedException(lock);
    }
  }

  static Future<void> fail(String scope, {DatabaseExecutor? executor}) async {
    final db = executor ?? AppDatabase.instance.db;
    final rows = await db.query(
      'login_guards',
      where: 'scope = ?',
      whereArgs: [scope],
      limit: 1,
    );
    final failures =
        ((rows.isEmpty ? 0 : rows.first['failures'] as int?) ?? 0) + 1;
    String? lockUntil;
    if (failures >= maxLoginFailures) {
      final tier = failures - maxLoginFailures;
      final seconds = (30 * (1 << tier)).clamp(30, 3600);
      lockUntil = DateTime.now()
          .add(Duration(seconds: seconds))
          .toIso8601String();
    }
    await db.insert('login_guards', {
      'scope': scope,
      'failures': failures,
      'lock_until': lockUntil,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> clear(String scope, {DatabaseExecutor? executor}) async {
    final db = executor ?? AppDatabase.instance.db;
    await db.delete('login_guards', where: 'scope = ?', whereArgs: [scope]);
  }
}
