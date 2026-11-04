import 'operator.dart';

const permissionVoid = 'void';
const permissionChangeServicePrice = 'ubah_harga_jasa';
const permissionChangeStock = 'ubah_stok';
const permissionStockIn = 'stok_masuk';
const permissionStockOut = 'stok_keluar';
const permissionOpname = 'opname';
const permissionDiscount = 'diskon';
const permissionViewReport = 'lihat_laporan';
const permissionPrintReport = 'cetak_laporan';
const permissionBackup = 'backup';

class Permissions {
  Permissions._();

  static bool can(Operator? operator, String permission) {
    if (operator == null) return false;
    if (operator.isOwner) return true;
    return operator.permissions.contains(permission);
  }

  static void require(Operator? operator, String permission) {
    if (!can(operator, permission)) {
      throw StateError(
        'Izin "$permission" tidak tersedia untuk peran ini.',
      );
    }
  }
}
