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
    required this.customerId,
    required this.unitType,
    this.nopol,
    this.jenisMobil,
    this.tahunMobil,
    this.tipeRadiator,
    this.labelRadiator,
  });

  final int id;
  final int customerId;
  final String unitType;
  final String? nopol;
  final String? jenisMobil;
  final int? tahunMobil;
  final String? tipeRadiator;
  final String? labelRadiator;

  String get displayLabel {
    final parts = <String>[
      if ((nopol ?? '').trim().isNotEmpty) nopol!.trim(),
      if ((jenisMobil ?? '').trim().isNotEmpty) jenisMobil!.trim(),
      if ((labelRadiator ?? '').trim().isNotEmpty) labelRadiator!.trim(),
    ];
    return parts.isEmpty ? unitType : parts.join(' · ');
  }

  factory VehicleUnit.fromRow(Map<String, Object?> row) => VehicleUnit(
        id: row['id'] as int,
        customerId: row['customer_id'] as int,
        unitType: row['unit_type'] as String,
        nopol: row['nopol'] as String?,
        jenisMobil: row['jenis_mobil'] as String?,
        tahunMobil: row['tahun_mobil'] as int?,
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
  });

  final int id;
  final String kode;
  final String nama;
  final int hargaModalCents;
  final int hargaJualCents;
  final int jumlah;
  final int stokMinimum;

  bool get lowStock => jumlah <= stokMinimum;

  factory StockItem.fromRow(Map<String, Object?> row) => StockItem(
        id: row['id'] as int,
        kode: row['kode'] as String,
        nama: row['nama'] as String,
        hargaModalCents: row['harga_modal'] as int? ?? 0,
        hargaJualCents: row['harga_jual'] as int? ?? 0,
        jumlah: row['jumlah'] as int? ?? 0,
        stokMinimum: row['stok_minimum'] as int? ?? 0,
      );
}

class ServiceCatalog {
  const ServiceCatalog({
    required this.id,
    required this.nama,
    required this.hargaCents,
  });

  final int id;
  final String nama;
  final int hargaCents;

  factory ServiceCatalog.fromRow(Map<String, Object?> row) => ServiceCatalog(
        id: row['id'] as int,
        nama: row['nama'] as String,
        hargaCents: row['harga_standar'] as int? ?? 0,
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
  });

  final int id;
  final String noNota;
  final DateTime waktu;
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

  bool get isVoid => voidedAt != null;

  factory ServiceRecordSummary.fromRow(Map<String, Object?> row) =>
      ServiceRecordSummary(
        id: row['id'] as int,
        noNota: row['no_nota'] as String,
        waktu: DateTime.parse(row['waktu_service'] as String),
        customerNama: (row['customer_nama'] as String?) ?? '',
        unitLabel: (row['unit_label'] as String?) ?? '',
        keluhan: (row['keluhan_awal'] as String?) ?? '',
        biayaJasaCents: row['biaya_jasa'] as int? ?? 0,
        totalPartCents: row['total_part'] as int? ?? 0,
        diskonCents: row['diskon'] as int? ?? 0,
        totalCents: row['total_servis'] as int? ?? 0,
        bayarCents: row['bayar'] as int? ?? 0,
        statusBayar: (row['status_bayar'] as String?) ?? 'LUNAS',
        metodeBayar: (row['metode_bayar'] as String?) ?? 'CASH',
        voidedAt: row['voided_at'] == null
            ? null
            : DateTime.tryParse(row['voided_at'] as String),
      );
}

class JobDraft {
  JobDraft({required this.deskripsi, required this.jumlah, required this.hargaCents});

  String deskripsi;
  int jumlah;
  int hargaCents;

  int get subtotalCents => jumlah * hargaCents;
}

class PartDraft {
  PartDraft({
    required this.stockItemId,
    required this.nama,
    required this.jumlah,
    required this.hargaCents,
    required this.modalCents,
  });

  final int stockItemId;
  String nama;
  int jumlah;
  int hargaCents;
  int modalCents;

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
  });

  final int transaksi;
  final int totalJasaCents;
  final int totalPartCents;
  final int diskonCents;
  final int totalCents;
  final int dibayarCents;
  final int piutangCents;
}

class DashboardData {
  const DashboardData({
    required this.todayRecords,
    required this.todayRevenueCents,
    required this.todayCount,
    required this.lowStockCount,
    required this.receivableCents,
    required this.recent,
  });

  final List<ServiceRecordSummary> todayRecords;
  final int todayRevenueCents;
  final int todayCount;
  final int lowStockCount;
  final int receivableCents;
  final List<ServiceRecordSummary> recent;
}
