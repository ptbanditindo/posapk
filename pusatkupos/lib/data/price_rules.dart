/// Aturan harga minimum dan alokasi diskon tingkat nota.
///
/// Harga batas transaksi selalu sama dengan harga modal yang tersimpan pada
/// baris saat transaksi dibuat. Tidak ada kolom batas terpisah: pemilik tidak
/// dapat menurunkan batas tanpa menurunkan modal.
class PriceLine {
  PriceLine({
    required this.jenis,
    required this.label,
    required this.jumlah,
    required this.hargaTerdaftar,
    required this.hargaModal,
    this.stockItemId,
    this.jasaId,
    this.intervalBulan = 0,
    this.alasanDiskon,
    this.disetujuiOleh,
  });

  final String jenis; // jasa | part
  final String label;
  final int jumlah;
  final int hargaTerdaftar;
  final int hargaModal;
  final int? stockItemId;
  final int? jasaId;
  final int intervalBulan;
  String? alasanDiskon;
  String? disetujuiOleh;

  int get subtotal => jumlah * hargaTerdaftar;
  int get batasTotal => jumlah * hargaModal;

  int hargaFinal = 0;
  int diskonAlokasi = 0;

  int get finalTotal => hargaFinal * jumlah;
}

class PriceRuleViolation implements Exception {
  PriceRuleViolation(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class PriceAllocation {
  const PriceAllocation({
    required this.lines,
    required this.bruto,
    required this.diskon,
    required this.total,
    required this.belowMinimum,
  });

  final List<PriceLine> lines;
  final int bruto;
  final int diskon;
  final int total;

  /// Ada baris yang harga finalnya di bawah modal. Data lapisan pemanggil
  /// wajib sudah meminta persetujuan owner sebelum memakai hasil ini.
  final bool belowMinimum;
}

class PriceRules {
  PriceRules._();

  /// Membagi diskon nota secara proporsional ke baris, lalu memvalidasi tiap
  /// baris terhadap modalnya. Sisa pembulatan selalu masuk ke baris terakhir
  /// yang masih punya nilai, sehingga jumlah alokasi sama dengan diskon nota.
  static PriceAllocation allocate(
    List<PriceLine> source, {
    required int diskonCents,
    bool ownerApproved = false,
    bool allowBelowMinimum = false,
    String? alasanDiskon,
    String? disetujuiOleh,
  }) {
    if (diskonCents < 0) {
      throw PriceRuleViolation('diskon_negatif', 'Diskon tidak boleh negatif.');
    }
    final lines = source
        .map(
          (line) => PriceLine(
            jenis: line.jenis,
            label: line.label,
            jumlah: line.jumlah,
            hargaTerdaftar: line.hargaTerdaftar,
            hargaModal: line.hargaModal,
            stockItemId: line.stockItemId,
            jasaId: line.jasaId,
            intervalBulan: line.intervalBulan,
            alasanDiskon: alasanDiskon ?? line.alasanDiskon,
            disetujuiOleh: disetujuiOleh ?? line.disetujuiOleh,
          ),
        )
        .toList();
    if (lines.isEmpty) {
      throw PriceRuleViolation(
        'tanpa_baris',
        'Tambahkan minimal satu jasa atau part.',
      );
    }
    for (final line in lines) {
      if (line.jumlah <= 0) {
        throw PriceRuleViolation(
          'jumlah_tidak_valid',
          'Jumlah ${line.label} harus lebih dari nol.',
        );
      }
      if (line.hargaTerdaftar < 0 || line.hargaModal < 0) {
        throw PriceRuleViolation(
          'harga_negatif',
          'Harga ${line.label} tidak boleh negatif.',
        );
      }
    }
    final bruto = lines.fold<int>(0, (sum, line) => sum + line.subtotal);
    if (diskonCents > bruto) {
      throw PriceRuleViolation(
        'diskon_melebihi_total',
        'Diskon melebihi total tagihan.',
      );
    }
    var remaining = diskonCents;
    var allocated = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      int share;
      if (index == lines.length - 1) {
        share = remaining;
      } else {
        share = bruto == 0 ? 0 : diskonCents * line.subtotal ~/ bruto;
        if (share > remaining) share = remaining;
      }
      if (share < 0) share = 0;
      remaining -= share;
      allocated += share;
      line.diskonAlokasi = share;
      final finalTotal = line.subtotal - share;
      if (finalTotal < 0) {
        throw PriceRuleViolation(
          'diskon_melebihi_baris',
          'Diskon melebihi nilai ${line.label}.',
        );
      }
      line.hargaFinal = finalTotal ~/ line.jumlah;
    }
    var belowMinimum = false;
    for (final line in lines) {
      // Pembulatan ke bawah per unit tidak boleh menutupi penjualan di bawah
      // modal: total baris tetap dibandingkan dengan total modal baris.
      if (line.finalTotal < line.batasTotal) {
        belowMinimum = true;
      }
    }
    if (belowMinimum && !ownerApproved && !allowBelowMinimum) {
      final line = lines.firstWhere((item) => item.finalTotal < item.batasTotal);
      throw PriceRuleViolation(
        'di_bawah_batas_minimal',
        'Harga ${line.label} di bawah batas minimal. '
            'Minta persetujuan pemilik untuk melanjutkan.',
      );
    }
    if (belowMinimum) {
      for (final line in lines) {
        if (line.finalTotal < line.batasTotal) {
          line.disetujuiOleh = disetujuiOleh ?? 'Pemilik';
        }
      }
    }
    final total = bruto - allocated;
    return PriceAllocation(
      lines: lines,
      bruto: bruto,
      diskon: allocated,
      total: total,
      belowMinimum: belowMinimum,
    );
  }

  /// Validasi nilai koreksi terhadap total modal baris nota asal.
  static void validateCorrection({
    required int modalTotal,
    required int nilaiBaru,
    required bool ownerApproved,
  }) {
    if (nilaiBaru < 0) {
      throw PriceRuleViolation(
        'nilai_koreksi_negatif',
        'Nilai koreksi tidak boleh negatif.',
      );
    }
    if (nilaiBaru < modalTotal && !ownerApproved) {
      throw PriceRuleViolation(
        'di_bawah_batas_minimal',
        'Nilai koreksi di bawah batas minimal. '
            'Minta persetujuan pemilik untuk melanjutkan.',
      );
    }
  }
}
