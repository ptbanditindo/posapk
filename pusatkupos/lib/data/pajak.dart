import 'dart:math' as math;

/// PPN per nota (BD-28/BD-29/BD-30).
///
/// Nilai uang disimpan dalam sen (integer). Persentase disimpan dalam basis
/// poin (bp): 1100 berarti 11,00%. Pembulatan dilakukan satu kali per nota
/// dengan aturan setengah ke atas (half-up) pada nilai absolut.
const pajakModeEksklusif = 'EKSLUSIF';
const pajakModeInklusif = 'INKLUSIF';
const pajakModeTanpa = 'TANPA';

const pajakPenanggungPembeli = 'PEMBELI';
const pajakPenanggungBengkel = 'BENGKEL';

const pajakPersenBpMinAktif = 1; // 0,01%
const pajakPersenBpMax = 10000; // 100,00%
const pajakPersenBpDefault = 1100; // 11,00%

const pajakModes = [pajakModeEksklusif, pajakModeInklusif];
const pajakPenanggungValues = [pajakPenanggungPembeli, pajakPenanggungBengkel];

String pajakModeLabel(String mode) {
  switch (mode) {
    case pajakModeEksklusif:
      return 'Eksklusif (PPN ditambahkan)';
    case pajakModeInklusif:
      return 'Inklusif (harga sudah termasuk PPN)';
    default:
      return 'Tanpa PPN';
  }
}

String pajakPenanggungLabel(String penanggung) =>
    penanggung == pajakPenanggungBengkel ? 'Ditanggung bengkel' : 'Dibayar pembeli';

String formatPersenBp(int bp) {
  final whole = bp ~/ 100;
  final fraction = bp % 100;
  if (fraction == 0) return '$whole%';
  final text = fraction.toString().padLeft(2, '0');
  return '$whole,$text%';
}

int _roundHalfUp(int numerator, int denominator) {
  if (denominator == 0) return 0;
  final value = numerator < 0 ? -numerator : numerator;
  final result = (value + denominator ~/ 2) ~/ denominator;
  return numerator < 0 ? -result : result;
}

/// Konfigurasi PPN aktif per toko. Disimpan pada `store_settings` dan
/// disalin ke setiap nota sebagai snapshot agar nota lama tidak berubah saat
/// tarif diubah.
class PajakConfig {
  const PajakConfig({
    this.aktif = false,
    this.mode = pajakModeEksklusif,
    this.persenBp = pajakPersenBpDefault,
    this.penanggung = pajakPenanggungPembeli,
  });

  final bool aktif;
  final String mode;
  final int persenBp;
  final String penanggung;

  bool get enabled => aktif && persenBp > 0;

  String? validationError() {
    if (mode != pajakModeEksklusif && mode != pajakModeInklusif) {
      return 'Mode PPN harus EKSLUSIF atau INKLUSIF.';
    }
    if (penanggung != pajakPenanggungPembeli &&
        penanggung != pajakPenanggungBengkel) {
      return 'Penanggung PPN harus PEMBELI atau BENGKEL.';
    }
    if (persenBp < 0 || persenBp > pajakPersenBpMax) {
      return 'Tarif PPN harus antara 0% dan 100%.';
    }
    if (aktif && persenBp < pajakPersenBpMinAktif) {
      return 'Tarif PPN minimal 0,01% saat PPN diaktifkan.';
    }
    return null;
  }

  Map<String, Object?> toSnapshot() => {
        'aktif': enabled,
        'mode': enabled ? mode : pajakModeTanpa,
        'persen_bp': enabled ? persenBp : 0,
        'penanggung': penanggung,
      };

  PajakConfig copyWith({
    bool? aktif,
    String? mode,
    int? persenBp,
    String? penanggung,
  }) =>
      PajakConfig(
        aktif: aktif ?? this.aktif,
        mode: mode ?? this.mode,
        persenBp: persenBp ?? this.persenBp,
        penanggung: penanggung ?? this.penanggung,
      );
}

/// Hasil hitung PPN untuk satu nota.
class PajakSnapshot {
  const PajakSnapshot({
    required this.active,
    required this.mode,
    required this.persenBp,
    required this.penanggung,
    required this.dppCents,
    required this.pajakCents,
    required this.totalCents,
    required this.diserapCents,
  });

  final bool active;
  final String mode;
  final int persenBp;
  final String penanggung;

  /// Dasar pengenaan pajak (nilai barang/jasa setelah diskon).
  final int dppCents;

  /// PPN terutang yang dipungut atau diserap.
  final int pajakCents;

  /// Nilai yang ditagihkan ke pembeli (DPP atau DPP+PPN).
  final int totalCents;

  /// PPN yang ditanggung bengkel (biaya non-kas).
  final int diserapCents;

  bool get enabled => active;

  static const PajakSnapshot none = PajakSnapshot(
    active: false,
    mode: pajakModeTanpa,
    persenBp: 0,
    penanggung: pajakPenanggungPembeli,
    dppCents: 0,
    pajakCents: 0,
    totalCents: 0,
    diserapCents: 0,
  );

  /// Menghitung PPN dari nilai setelah diskon.
  ///
  /// Eksklusif: DPP = nilai, PPN = roundHalfUp(DPP x tarif).
  /// Inklusif: bruto sudah termasuk PPN, DPP = roundHalfUp(bruto x 10000 /
  /// (10000 + tarif)), PPN = bruto - DPP. Bila bengkel menanggung, pembeli
  /// hanya membayar DPP.
  factory PajakSnapshot.hitung({
    required int brutoCents,
    required PajakConfig config,
  }) {
    final base = brutoCents < 0 ? 0 : brutoCents;
    if (!config.enabled || base == 0) {
      return PajakSnapshot(
        active: config.aktif,
        mode: config.enabled ? config.mode : pajakModeTanpa,
        persenBp: config.enabled ? config.persenBp : 0,
        penanggung: config.penanggung,
        dppCents: base,
        pajakCents: 0,
        totalCents: base,
        diserapCents: 0,
      );
    }
    final bengkel = config.penanggung == pajakPenanggungBengkel;
    int dpp;
    int pajak;
    int total;
    if (config.mode == pajakModeInklusif) {
      dpp = _roundHalfUp(base * 10000, 10000 + config.persenBp);
      pajak = base - dpp;
      total = bengkel ? dpp : base;
    } else {
      dpp = base;
      pajak = _roundHalfUp(base * config.persenBp, 10000);
      total = bengkel ? dpp : dpp + pajak;
    }
    return PajakSnapshot(
      active: true,
      mode: config.mode,
      persenBp: config.persenBp,
      penanggung: config.penanggung,
      dppCents: dpp,
      pajakCents: pajak,
      totalCents: total,
      diserapCents: bengkel ? pajak : 0,
    );
  }

  /// Snapshot JSON yang disimpan pada nota.
  Map<String, Object?> toJson() => {
        'versi': 1,
        'aktif': active,
        'mode': mode,
        'persen_bp': persenBp,
        'penanggung': penanggung,
        'dpp': dppCents,
        'pajak': pajakCents,
        'total': totalCents,
        'diserap': diserapCents,
      };

  static PajakSnapshot fromJson(Map<String, Object?> json) {
    return PajakSnapshot(
      active: json['aktif'] == true,
      mode: '${json['mode'] ?? pajakModeTanpa}',
      persenBp: (json['persen_bp'] as num?)?.toInt() ?? 0,
      penanggung:
          '${json['penanggung'] ?? pajakPenanggungPembeli}',
      dppCents: (json['dpp'] as num?)?.toInt() ?? 0,
      pajakCents: (json['pajak'] as num?)?.toInt() ?? 0,
      totalCents: (json['total'] as num?)?.toInt() ?? 0,
      diserapCents: (json['diserap'] as num?)?.toInt() ?? 0,
    );
  }

  /// Bagian PPN pada nilai retur yang proporsional terhadap nilai nota.
  ///
  /// Semua argumen dalam sen. `nilaiRetur` adalah nilai DPP yang dikembalikan
  /// (bukan termasuk PPN). Untuk nota inklusif, pemanggil mengirim porsi
  /// bruto lalu fungsi ini memecah DPP/PPN dengan tarif yang sama.
  static int pajakProporsional({
    required int pajakNotaCents,
    required int dppNotaCents,
    required int dppReturCents,
  }) {
    if (pajakNotaCents <= 0 || dppNotaCents <= 0 || dppReturCents <= 0) {
      return 0;
    }
    final value = dppReturCents > dppNotaCents ? dppNotaCents : dppReturCents;
    return _roundHalfUp(pajakNotaCents * value, dppNotaCents);
  }

  /// Porsi PPN yang harus dikembalikan pada retur terakhir agar total retur
  /// PPN tepat sama dengan PPN nota (menyerap sisa pembulatan).
  static int pajakSisa({
    required int pajakNotaCents,
    required int pajakSudahReturCents,
    required bool returTerakhir,
  }) {
    final sisa = math.max(0, pajakNotaCents - pajakSudahReturCents);
    return returTerakhir ? sisa : 0;
  }

  /// Membagi DPP dan PPN nota ke baris secara proporsional terhadap nilai
  /// dasar tiap baris. Sisa pembulatan masuk ke baris terakhir yang bernilai
  /// sehingga jumlah per baris selalu sama dengan snapshot nota.
  static List<PajakBaris> alokasiBaris({
    required PajakSnapshot snapshot,
    required List<int> bases,
  }) {
    if (bases.isEmpty) return const [];
    final normalized = [
      for (final base in bases) base < 0 ? 0 : base,
    ];
    final totalBase = normalized.fold<int>(0, (sum, base) => sum + base);
    if (totalBase == 0) {
      return List<PajakBaris>.generate(
        bases.length,
        (_) => const PajakBaris(dppCents: 0, pajakCents: 0, totalCents: 0),
      );
    }
    var totalDpp = snapshot.dppCents;
    var totalPajak = snapshot.pajakCents;
    if (totalDpp == 0 && totalPajak == 0) {
      totalDpp = totalBase;
    }
    List<int> split(int total) {
      final result = List<int>.filled(normalized.length, 0);
      var remaining = total;
      for (var index = 0; index < normalized.length; index++) {
        if (total <= 0) break;
        final share = total * normalized[index] ~/ totalBase;
        final applied = share < 0 ? 0 : (share > remaining ? remaining : share);
        result[index] = applied;
        remaining -= applied;
      }
      for (var index = normalized.length - 1;
          index >= 0 && remaining > 0;
          index--) {
        if (normalized[index] <= 0) continue;
        result[index] += remaining;
        remaining = 0;
      }
      return result;
    }

    final dpp = split(totalDpp);
    final pajak = split(totalPajak);
    final pembeli = snapshot.penanggung == pajakPenanggungPembeli;
    return List<PajakBaris>.generate(normalized.length, (index) {
      final dppCents = dpp[index];
      final pajakCents = pajak[index];
      return PajakBaris(
        dppCents: dppCents,
        pajakCents: pajakCents,
        totalCents: pembeli ? dppCents + pajakCents : dppCents,
      );
    });
  }
}

class PajakBaris {
  const PajakBaris({
    required this.dppCents,
    required this.pajakCents,
    required this.totalCents,
  });

  final int dppCents;
  final int pajakCents;
  final int totalCents;
}
