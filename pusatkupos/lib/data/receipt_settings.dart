import 'app_database.dart';

/// 25 bagian struk. Semua default tampil; nilai disimpan di app_settings
/// dengan awalan `receipt.`.
const receiptFields = <String, String>{
  'tagline': 'Tagline',
  'alamat': 'Alamat',
  'kontak': 'Kontak',
  'no_nota': 'Nomor nota',
  'tanggal': 'Tanggal',
  'kasir': 'Kasir',
  'mekanik': 'Mekanik',
  'pelanggan': 'Pelanggan',
  'hp': 'Nomor HP',
  'unit': 'Unit',
  'keluhan': 'Keluhan',
  'catatan': 'Catatan',
  'jasa': 'Rincian jasa',
  'part': 'Rincian part',
  'total_jasa': 'Total jasa',
  'total_part': 'Total part',
  'diskon': 'Diskon',
  'grand_total': 'Grand total',
  'metode': 'Metode bayar',
  'bayar': 'Dibayar',
  'kembalian': 'Kembalian',
  'status_bayar': 'Status bayar',
  'garansi': 'Garansi',
  'rekening': 'Rekening',
  'footer': 'Footer',
};

class ReceiptSettings {
  ReceiptSettings._();

  static final ReceiptSettings instance = ReceiptSettings._();

  Future<Map<String, bool>> load() async {
    final result = <String, bool>{};
    for (final key in receiptFields.keys) {
      final value = await AppDatabase.instance.getSetting('receipt.$key');
      result[key] = value == null ? true : value == '1';
    }
    return result;
  }

  Future<void> save(String key, bool enabled) async {
    if (!receiptFields.containsKey(key)) {
      throw ArgumentError('Bagian struk tidak dikenal: $key');
    }
    await AppDatabase.instance
        .setSetting('receipt.$key', enabled ? '1' : '0');
  }

  Future<void> saveAll(Map<String, bool> values) async {
    for (final entry in values.entries) {
      await save(entry.key, entry.value);
    }
  }
}
