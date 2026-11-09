import 'operator.dart';

const permissionVoid = 'void';
const permissionRetur = 'retur';
const permissionChangeServicePrice = 'ubah_harga_jasa';
const permissionChangeStock = 'ubah_stok';
const permissionStockIn = 'stok_masuk';
const permissionStockOut = 'stok_keluar';
const permissionOpname = 'opname';
const permissionDiscount = 'diskon';
const permissionCredit = 'beri_kredit';
const permissionViewReport = 'lihat_laporan';
const permissionPrintReport = 'cetak_laporan';
const permissionBackup = 'backup';
const permissionViewPurchase = 'lihat_pembelian';
const permissionCreatePurchase = 'buat_pembelian';
const permissionPayDebt = 'bayar_utang';
const permissionPaySalary = 'bayar_gaji';
const permissionSupplier = 'ubah_supplier';
const permissionManageAccounts = 'kelola_akun';

class Permissions {
  Permissions._();

  static bool can(Operator? operator, String permission) {
    if (operator == null) return false;
    // Mode ringkasan tidak boleh menulis ke salinan laporan, apa pun izin
    // yang tercatat di sesinya.
    if (operator.isViewer) return false;
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
