import '../core/money.dart';

/// Aturan harga minimum dan alokasi diskon tingkat nota.
///
/// Harga batas transaksi selalu sama dengan harga modal yang tersimpan pada
/// baris saat transaksi dibuat. Tidak ada kolom batas terpisah: pemilik tidak
/// dapat menurunkan batas tanpa menurunkan modal.
///
/// Untuk selain pemilik, batas modal bersifat mutlak dan diskon maksimal
/// adalah selisih harga jual terdaftar dengan modal. Contoh: jual 70.000,
/// modal 50.000, maka diskon maksimal 20.000 dan harga akhir minimal 50.000.
class PriceLine {
  PriceLine({
    required this.jenis,
    required this.label,
    required this.jumlah,
    required this.hargaTerdaftar,
    required this.hargaModal,
    int? qtyMilli,
    this.stockItemId,
    this.jasaId,
    this.intervalBulan = 0,
    this.alasanDiskon,
    this.disetujuiOleh,
  }) : qtyMilli = qtyMilli ?? jumlah * 1000;

  final String jenis; // jasa | part
  final String label;
  final int jumlah;
  final int qtyMilli;
  final int hargaTerdaftar;
  final int hargaModal;
  final int? stockItemId;
  final int? jasaId;
  final int intervalBulan;
  String? alasanDiskon;
  String? disetujuiOleh;

  int get subtotal => (hargaTerdaftar * qtyMilli / 1000).round();
  int get batasTotal => (hargaModal * qtyMilli / 1000).round();

  int hargaFinal = 0;
  int diskonAlokasi = 0;

  int get finalTotal => (hargaFinal * qtyMilli / 1000).round();
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

  /// Ada baris yang harga finalnya di bawah modal. Hanya mungkin terjadi
  /// pada transaksi pemilik; selain pemilik selalu ditolak.
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
            qtyMilli: line.qtyMilli,
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
      if (line.qtyMilli <= 0) {
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
    final modalTotal = lines.fold<int>(0, (sum, line) => sum + line.batasTotal);
    final marginTotal = bruto - modalTotal;
    if (!allowBelowMinimum) {
      for (final line in lines) {
        if (line.hargaTerdaftar < line.hargaModal) {
          throw PriceRuleViolation(
            'di_bawah_batas_minimal',
            'Harga ${line.label} ${formatRupiah(line.hargaTerdaftar)} '
                'di bawah modal ${formatRupiah(line.hargaModal)}.',
          );
        }
      }
      if (diskonCents > marginTotal) {
        throw PriceRuleViolation(
          'diskon_melebihi_margin',
          'Diskon ${formatRupiah(diskonCents)} melebihi batas '
              '${formatRupiah(marginTotal)} '
              '(selisih harga jual dan modal).',
        );
      }
    }
    // Diskon dialokasikan proporsional, tetapi tiap baris dibatasi agar
    // harga akhirnya tidak jatuh di bawah modal kecuali pemilik mengizinkan.
    // Sisa yang tidak tertampung dipindahkan ke baris lain yang masih punya
    // ruang, sehingga total alokasi tetap sama dengan diskon nota.
    final capacity = <int>[
      for (final line in lines)
        allowBelowMinimum ? line.subtotal : line.subtotal - line.batasTotal,
    ];
    final shares = List<int>.filled(lines.length, 0);
    var remaining = diskonCents;
    if (bruto > 0) {
      for (var index = 0; index < lines.length; index++) {
        if (remaining <= 0) break;
        final raw = diskonCents * lines[index].subtotal ~/ bruto;
        final share = raw.clamp(0, capacity[index]).clamp(0, remaining);
        shares[index] = share;
        remaining -= share;
      }
    }
    for (var index = lines.length - 1; index >= 0 && remaining > 0; index--) {
      final room = capacity[index] - shares[index];
      if (room <= 0) continue;
      final extra = remaining < room ? remaining : room;
      shares[index] += extra;
      remaining -= extra;
    }
    if (remaining > 0) {
      throw PriceRuleViolation(
        'diskon_melebihi_margin',
        'Diskon tidak dapat dialokasikan tanpa menembus batas modal.',
      );
    }
    var allocated = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final share = shares[index];
      allocated += share;
      line.diskonAlokasi = share;
      final finalTotal = line.subtotal - share;
      line.hargaFinal = line.qtyMilli <= 0
          ? 0
          : (finalTotal * 1000 / line.qtyMilli).round();
    }
    var belowMinimum = false;
    for (final line in lines) {
      if (line.subtotal - line.diskonAlokasi < line.batasTotal) {
        belowMinimum = true;
      }
    }
    if (belowMinimum && !allowBelowMinimum) {
      final line = lines.firstWhere((item) => item.finalTotal < item.batasTotal);
      throw PriceRuleViolation(
        'di_bawah_batas_minimal',
        'Diskon membuat harga ${line.label} '
            '${formatRupiah(line.hargaFinal)} di bawah modal '
            '${formatRupiah(line.hargaModal)}.',
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
