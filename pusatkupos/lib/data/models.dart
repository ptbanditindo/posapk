import '../core/dates.dart';
import '../core/quantity.dart';

class Customer {
  const Customer({
    required this.id,
    required this.syncId,
    required this.nama,
    required this.nomorHp,
    this.alamat,
  });

  final int id;
  final String syncId;
  final String nama;
  final String nomorHp;
  final String? alamat;

  factory Customer.fromRow(Map<String, Object?> row) => Customer(
        id: row['id'] as int,
        syncId: row['sync_id'] as String,
        nama: row['nama'] as String,
        nomorHp: row['nomor_hp'] as String,
        alamat: row['alamat'] as String?,
      );
}
class VehicleUnit {
  const VehicleUnit({
    required this.id,
    this.customerId,
    required this.unitType,
    this.nopol,
    this.merek,
    this.tipe,
    this.jenisMobil,
    this.tahunMobil,
    this.noRangka,
    this.noMesin,
    this.kmTerakhir,
    this.tipeRadiator,
    this.labelRadiator,
  });

  final int id;
  final int? customerId;
  final String unitType;
  final String? nopol;
  final String? merek;
  final String? tipe;
  final String? jenisMobil;
  final int? tahunMobil;
  final String? noRangka;
  final String? noMesin;
  final int? kmTerakhir;
  final String? tipeRadiator;
  final String? labelRadiator;

  String get displayLabel {
    final parts = <String>[
      if ((nopol ?? '').trim().isNotEmpty) nopol!.trim(),
      if ((merek ?? jenisMobil ?? '').trim().isNotEmpty)
        (merek ?? jenisMobil)!.trim(),
      if ((tipe ?? labelRadiator ?? '').trim().isNotEmpty)
        (tipe ?? labelRadiator)!.trim(),
    ];
    return parts.isEmpty ? unitType : parts.join(' · ');
  }

  factory VehicleUnit.fromRow(Map<String, Object?> row) => VehicleUnit(
        id: row['id'] as int,
        customerId: row['customer_id'] as int?,
        unitType: row['unit_type'] as String? ?? 'MOBIL',
        nopol: row['nopol'] as String?,
        merek: row['merek'] as String?,
        tipe: row['tipe'] as String?,
        jenisMobil: row['jenis_mobil'] as String?,
        tahunMobil: row['tahun_mobil'] as int?,
        noRangka: row['no_rangka'] as String?,
        noMesin: row['no_mesin'] as String?,
        kmTerakhir: row['km_terakhir'] as int?,
        tipeRadiator: row['tipe_radiator'] as String?,
        labelRadiator: row['label_radiator'] as String?,
      );
}

class StockItem {
  const StockItem({
    required this.id,
    required this.kode,
    required this.nama,
    required this.hargaModalCents,
    required this.hargaJualCents,
    required this.jumlah,
    required this.stokMinimum,
    this.satuan = 'pcs',
    this.desimal = 0,
    this.jumlahMilliOverride,
    this.intervalBulan = 0,
  });

  final int id;
  final String kode;
  final String nama;
  final int hargaModalCents;
  final int hargaJualCents;
  final int jumlah;
  final int stokMinimum;
  final String satuan;
  final int desimal;
  final int? jumlahMilliOverride;
  final int intervalBulan;

  int get jumlahMilli => jumlahMilliOverride ?? jumlah * 1000;
  double get jumlahValue => jumlahMilli / 1000;
  bool get negatif => jumlahMilli < 0;
  bool get lowStock => jumlahMilli <= stokMinimum * 1000;

  String get jumlahLabel => formatQuantity(
        jumlahMilli,
        desimal,
        satuan: satuan,
      );

  factory StockItem.fromRow(Map<String, Object?> row) => StockItem(
        id: row['id'] as int,
        kode: row['kode'] as String,
        nama: row['nama'] as String,
        hargaModalCents: row['harga_modal'] as int? ?? 0,
        hargaJualCents: row['harga_jual'] as int? ?? 0,
        jumlah: row['jumlah'] as int? ?? 0,
        stokMinimum: row['stok_minimum'] as int? ?? 0,
        satuan: row['satuan'] as String? ?? 'pcs',
        desimal: row['desimal'] as int? ?? 0,
        jumlahMilliOverride: row['jumlah_milli'] as int?,
        intervalBulan: row['interval_servis_bulan'] as int? ?? 0,
      );
}

class ServiceCatalog {
  const ServiceCatalog({
    required this.id,
    required this.nama,
    required this.hargaCents,
    this.hargaModalCents = 0,
    this.intervalBulan = 0,
  });

  final int id;
  final String nama;
  final int hargaCents;
  final int hargaModalCents;
  final int intervalBulan;

  factory ServiceCatalog.fromRow(Map<String, Object?> row) => ServiceCatalog(
        id: row['id'] as int,
        nama: row['nama'] as String,
        hargaCents: row['harga_jual'] as int? ?? 0,
        hargaModalCents: row['harga_modal'] as int? ?? 0,
        intervalBulan: row['interval_servis_bulan'] as int? ?? 0,
      );
}

class ServiceRecordSummary {
  const ServiceRecordSummary({
    required this.id,
    required this.noNota,
    required this.waktu,
    required this.customerNama,
    required this.unitLabel,
    required this.keluhan,
    required this.biayaJasaCents,
    required this.totalPartCents,
    required this.diskonCents,
    required this.totalCents,
    required this.bayarCents,
    required this.statusBayar,
    required this.metodeBayar,
    required this.voidedAt,
    this.bergaransi = false,
    this.garansiSampai,
    this.catatanGaransi,
    this.statusKlaim = 'Belum claim',
    this.tanggalKlaim,
    this.unitDitinggal = false,
    this.diambilAt,
    this.jenisTransaksi = 'servis_langsung',
  });

  final int id;
  final String noNota;
  final DateTime waktu;
  final String jenisTransaksi;
  final String customerNama;
  final String unitLabel;
  final String keluhan;
  final int biayaJasaCents;
  final int totalPartCents;
  final int diskonCents;
  final int totalCents;
  final int bayarCents;
  final String statusBayar;
  final String metodeBayar;
  final DateTime? voidedAt;
  final bool bergaransi;
  final DateTime? garansiSampai;
  final String? catatanGaransi;
  final String statusKlaim;
  final DateTime? tanggalKlaim;
  final bool unitDitinggal;
  final DateTime? diambilAt;

  bool get isVoid => voidedAt != null;

  bool get warrantyActive {
    final end = garansiSampai;
    if (isVoid || !bergaransi || end == null) return false;
    if (statusKlaim == 'Sudah claim') return false;
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    return !day.isAfter(end);
  }

  String get warrantyStatus {
    if (isVoid) return 'DIBATALKAN';
    if (!bergaransi || garansiSampai == null) return 'TANPA GARANSI';
    if (statusKlaim == 'Sudah claim') return 'SUDAH CLAIM';
    return warrantyActive ? 'AKTIF' : 'KEDALUWARSA';
  }

  factory ServiceRecordSummary.fromRow(Map<String, Object?> row) =>
      ServiceRecordSummary(
        id: row['id'] as int,
        noNota: row['no_nota'] as String,
        waktu: localTime(row['waktu_service']),
        customerNama: (row['customer_nama'] as String?) ?? '',
        unitLabel: (row['unit_label'] as String?) ?? '',
        keluhan: (row['keluhan_awal'] as String?) ?? '',
        jenisTransaksi:
            row['jenis_transaksi'] as String? ?? 'servis_langsung',
        biayaJasaCents: row['biaya_jasa'] as int? ?? 0,
        totalPartCents: row['total_part'] as int? ?? 0,
        diskonCents: row['diskon'] as int? ?? 0,
        totalCents: row['total_servis'] as int? ?? 0,
        bayarCents: row['bayar'] as int? ?? 0,
        statusBayar: (row['status_bayar'] as String?) ?? 'LUNAS',
        metodeBayar: (row['metode_bayar'] as String?) ?? 'CASH',
        voidedAt: row['voided_at'] == null
            ? null
            : DateTime.tryParse(row['voided_at'] as String)?.toLocal(),
        bergaransi: (row['bergaransi'] as int? ?? 0) == 1,
        garansiSampai: row['garansi_sampai'] == null
            ? null
            : DateTime.tryParse(row['garansi_sampai'] as String),
        catatanGaransi: row['catatan_garansi'] as String?,
        statusKlaim: (row['status_klaim'] as String?) ?? 'Belum claim',
        tanggalKlaim: row['tanggal_klaim'] == null
            ? null
            : DateTime.tryParse(row['tanggal_klaim'] as String),
        unitDitinggal: (row['unit_ditinggal'] as int? ?? 0) == 1,
        diambilAt: row['diambil_at'] == null
            ? null
            : DateTime.tryParse(row['diambil_at'] as String)?.toLocal(),
      );
}

class JobDraft {
  JobDraft({
    required this.deskripsi,
    required this.jumlah,
    required this.hargaCents,
    this.jasaId,
    this.modalCents = 0,
    this.intervalBulan = 0,
  }) : hargaTerdaftarCents = hargaCents;

  String deskripsi;
  int jumlah;
  int hargaCents;
  final int? jasaId;
  int modalCents;
  final int intervalBulan;
  final int hargaTerdaftarCents;
  int hargaFinalCents = 0;
  int diskonAlokasiCents = 0;
  String? alasanDiskon;
  String? disetujuiOleh;

  int get subtotalCents => jumlah * hargaCents;
}

class PartDraft {
  PartDraft({
    required this.stockItemId,
    required this.nama,
    required this.jumlah,
    required this.hargaCents,
    required this.modalCents,
    this.intervalBulan = 0,
  }) : hargaTerdaftarCents = hargaCents;

  final int stockItemId;
  String nama;
  int jumlah;
  int hargaCents;
  int modalCents;
  final int intervalBulan;
  final int hargaTerdaftarCents;
  int hargaFinalCents = 0;
  int diskonAlokasiCents = 0;
  String? alasanDiskon;
  String? disetujuiOleh;

  int get subtotalCents => jumlah * hargaCents;
}

class PaymentRow {
  const PaymentRow({
    required this.id,
    required this.jenis,
    required this.metode,
    required this.nominalCents,
    required this.waktu,
    this.catatan,
  });

  final int id;
  final String jenis;
  final String metode;
  final int nominalCents;
  final DateTime waktu;
  final String? catatan;
}

class CommissionRow {
  const CommissionRow({
    required this.employeeSyncId,
    required this.nama,
    required this.nominalCents,
    this.overrideCents,
  });

  final String employeeSyncId;
  final String nama;
  final int nominalCents;
  final int? overrideCents;

  int get finalCents => overrideCents ?? nominalCents;
}

class RecordDetail {
  const RecordDetail({
    required this.record,
    required this.jobs,
    required this.parts,
    required this.payments,
    required this.requestId,
    required this.catatan,
    required this.jenisBayar,
    required this.totalDibayarCents,
    required this.sisaCents,
    required this.voidReason,
    this.createdBy,
    this.mechanic,
    this.commissions = const [],
    this.corrections = const [],
  });

  final ServiceRecordSummary record;
  final List<JobDraft> jobs;
  final List<PartDraft> parts;
  final List<PaymentRow> payments;
  final String? requestId;
  final String? catatan;
  final String jenisBayar;
  final int totalDibayarCents;
  final int sisaCents;
  final String? voidReason;
  final String? createdBy;
  final String? mechanic;
  final List<CommissionRow> commissions;
  final List<CorrectionEntry> corrections;
}

class ReportSummary {
  const ReportSummary({
    required this.transaksi,
    required this.totalJasaCents,
    required this.totalPartCents,
    required this.diskonCents,
    required this.totalCents,
    required this.dibayarCents,
    required this.piutangCents,
    this.totalModalPartCents = 0,
    this.labaKotorPartCents = 0,
    this.komisiCents = 0,
    this.gajiCents = 0,
    this.cashByMethod = const {},
    this.countByType = const {},
    this.totalByType = const {},
  });

  final int transaksi;
  final int totalJasaCents;
  final int totalPartCents;
  final int diskonCents;
  final int totalCents;
  final int dibayarCents;
  final int piutangCents;
  final int totalModalPartCents;
  final int labaKotorPartCents;
  final int komisiCents;
  final int gajiCents;
  final Map<String, int> cashByMethod;
  final Map<String, int> countByType;
  final Map<String, int> totalByType;
}

class BelowPriceSale {
  const BelowPriceSale({
    required this.noNota,
    required this.waktu,
    required this.jenis,
    required this.deskripsi,
    required this.jumlah,
    required this.hargaTerdaftarCents,
    required this.hargaFinalCents,
    this.kasir,
    this.disetujuiOleh,
  });

  final String noNota;
  final DateTime waktu;
  final String jenis;
  final String deskripsi;
  final int jumlah;
  final int hargaTerdaftarCents;
  final int hargaFinalCents;
  final String? kasir;
  final String? disetujuiOleh;

  int get selisihCents => (hargaFinalCents - hargaTerdaftarCents) * jumlah;
}

class CorrectionEntry {
  const CorrectionEntry({
    required this.noNota,
    required this.waktu,
    required this.alasan,
    required this.nilaiSelisihCents,
    required this.nilaiBaruCents,
    this.dibuatOleh,
    this.disetujuiOleh,
  });

  final String noNota;
  final DateTime waktu;
  final String alasan;
  final int nilaiSelisihCents;
  final int nilaiBaruCents;
  final String? dibuatOleh;
  final String? disetujuiOleh;
}

class EstimateAgingRow {
  const EstimateAgingRow({
    required this.nomorEstimasi,
    required this.totalCents,
    required this.status,
    this.dibuatOleh,
    this.masaBerlaku,
    this.convertedNotaSyncId,
    this.finalNotaCents,
  });

  final String nomorEstimasi;
  final int totalCents;
  final String status;
  final String? dibuatOleh;
  final DateTime? masaBerlaku;
  final String? convertedNotaSyncId;
  final int? finalNotaCents;

  bool get converted => (convertedNotaSyncId ?? '').isNotEmpty;

  bool get kedaluwarsa {
    final expiry = masaBerlaku;
    if (expiry == null || converted) return false;
    final today = DateTime.now();
    return DateTime(today.year, today.month, today.day)
        .isAfter(DateTime(expiry.year, expiry.month, expiry.day));
  }

  int get varianceCents {
    final finalTotal = finalNotaCents;
    if (!converted || finalTotal == null) return 0;
    return finalTotal - totalCents;
  }
}

class DashboardData {
  const DashboardData({
    required this.todayRecords,
    required this.todayRevenueCents,
    required this.todayCount,
    required this.lowStockCount,
    required this.receivableCents,
    required this.recent,
    this.negativeStockCount = 0,
  });

  final List<ServiceRecordSummary> todayRecords;
  final int todayRevenueCents;
  final int todayCount;
  final int lowStockCount;
  final int receivableCents;
  final List<ServiceRecordSummary> recent;
  final int negativeStockCount;
}
