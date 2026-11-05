/// Tempat penyimpanan daftar printer. Konfigurasi printer (MAC/IP) sengaja
/// disimpan di berkas terpisah agar tidak masuk backup atau sinkronisasi.
abstract class PrinterStorage {
  Future<String?> read();

  Future<void> write(String data);

  /// Salinan data sebelum penulisan terakhir, untuk pemulihan bila berkas
  /// utama rusak. Penyimpanan tanpa cadangan mengembalikan null.
  Future<String?> readBackup() async => null;
}

class MemoryPrinterStorage implements PrinterStorage {
  MemoryPrinterStorage({String? initial}) : _data = initial;

  String? _data;

  @override
  Future<String?> read() async => _data;

  @override
  Future<String?> readBackup() async => null;

  @override
  Future<void> write(String data) async {
    _data = data;
  }
}
