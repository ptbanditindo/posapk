import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos/data/access_control.dart';
import 'package:pusatkupos/data/store_settings.dart';

StoreSettings _settings([Map<String, Map<String, bool>> roles = const {}]) {
  return StoreSettings(
    storeId: 'utama',
    syncId: 'store-sync',
    rolePermissions: roles,
  );
}

void main() {
  test('peran bawaan dan alias lama dikenali', () {
    expect(builtinRoles, containsAll(['KASIR', 'MEKANIK', 'SUPERVISOR']));
    expect(canonicalRole('keduanya'), 'SUPERVISOR');
    expect(roleDisplayName('keduanya'), 'Supervisor');
    expect(isBuiltinRole('Kasir'), isTrue);
  });

  test('peran kustom tanpa peta akses tidak mendapat izin', () {
    final settings = _settings();
    expect(settings.roleAllows('Penanggung Jawab', 'buat_nota'), isFalse);
    expect(settings.roleAllows('Penanggung Jawab', 'lihat_riwayat'), isFalse);
  });

  test('akses tersimpan menimpa bawaan dan sisanya memakai bawaan', () {
    final settings = _settings({
      'KASIR': {'lihat_stok': false},
    });
    expect(settings.roleAllows('KASIR', 'lihat_stok'), isFalse);
    expect(settings.roleAllows('KASIR', 'lihat_kasir'), isTrue);
  });

  test('izin tambahan akun menambah akses efektif', () {
    final settings = _settings();
    final permissions = settings.accessFor(
      'MEKANIK',
      extras: ['lihat_laporan'],
    );
    expect(permissions, contains('lihat_laporan'));
    expect(permissions, contains('lihat_riwayat'));
  });

  test('daftar peran memuat peran kustom tanpa duplikat alias', () {
    final settings = _settings({
      'Penanggung Jawab': {'lihat_riwayat': true},
      'keduanya': {'lihat_kasir': true},
    });
    final roles = settings.roleNames;
    expect(roles, contains('Penanggung Jawab'));
    expect(roles, contains('SUPERVISOR'));
    expect(roles.where((role) => role == 'SUPERVISOR').length, 1);
  });

  test('jenis transaksi mengikuti peran dan saklar toko', () {
    final settings = StoreSettings(
      storeId: 'utama',
      syncId: 'store-sync',
      types: const {
        transactionServisLangsung: true,
        transactionOrderKerja: true,
      },
      rolePermissions: const {
        'KASIR': {'buat_nota': true, 'jenis_order_kerja': false},
      },
    );
    expect(settings.roleCanSelect('KASIR', transactionServisLangsung), isTrue);
    expect(settings.roleCanSelect('KASIR', transactionOrderKerja), isFalse);
    expect(settings.roleCanSelect('MEKANIK', transactionServisLangsung),
        isFalse);
  });
}
