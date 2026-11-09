import '../core/dates.dart';
import '../core/money.dart';
import '../printer/receipt_builder.dart';
import 'app_database.dart';
import 'models.dart';
import 'pajak.dart';
import 'receipt_settings.dart';
import 'receipt_template.dart';
import 'store_settings.dart';

class ReceiptDocument {
  const ReceiptDocument({
    required this.lines,
    required this.width,
    this.recordId,
    this.copies = 1,
    this.blankLines = 3,
    this.codepage = '',
    this.logoPath = '',
    this.logoWidthMm = 20,
    this.customerPhone = '',
    this.customerName = '',
    this.noNota = '',
    this.totalCents = 0,
  });

  final List<ReceiptLine> lines;
  final int width;
  final int? recordId;
  final int copies;
  final int blankLines;
  final String codepage;
  final String logoPath;
  final int logoWidthMm;
  final String customerPhone;
  final String customerName;
  final String noNota;
  final int totalCents;

  String get text => lines.map((line) => line.text).join('\n');
}

class ReceiptService {
  ReceiptService._();

  static final ReceiptService instance = ReceiptService._();

  Future<ReceiptDocument> build(int recordId, {int width = 32}) async {
    if (width != 32 && width != 48) {
      throw ArgumentError('Lebar struk hanya 32 atau 48 kolom.');
    }
    final template = await ReceiptSettings.instance.load();
    return buildFromTemplate(recordId, template: template, width: width);
  }

  Future<ReceiptDocument> buildFromTemplate(
    int recordId, {
    required ReceiptTemplate template,
    int? width,
  }) async {
    final detail = await AppDatabase.instance.recordDetail(recordId);
    if (detail == null) throw StateError('Nota tidak ditemukan.');
    final db = AppDatabase.instance;
    final store = _StoreInfo(
      nama: await db.getSetting('bengkel.nama') ?? 'PUSATKU POS',
      alamat: await db.getSetting('bengkel.alamat') ?? '',
      tagline: await db.getSetting('bengkel.tagline') ?? '',
      telepon: await db.getSetting('bengkel.telepon') ?? '',
    );
    final phoneRows = await db.db.rawQuery(
      '''
      SELECT COALESCE(NULLIF(TRIM(r.customer_hp), ''), c.nomor_hp) AS nomor_hp
      FROM service_records r
      LEFT JOIN vehicle_or_units u ON u.id = r.unit_id
      LEFT JOIN customers c ON c.id = COALESCE(r.customer_id, u.customer_id)
      WHERE r.id = ? LIMIT 1
      ''',
      [recordId],
    );
    final customerPhone = phoneRows.isEmpty
        ? ''
        : (phoneRows.first['nomor_hp'] as String? ?? '');
    final karyawanAktif = (await db.getSetting('fitur.karyawan') ?? '1') == '1';
    return _render(
      template,
      detail,
      store,
      width: width ?? template.width,
      customerPhone: customerPhone,
      karyawanAktif: karyawanAktif,
    );
  }

  /// Struk contoh untuk pratinjau di pengaturan.
  Future<ReceiptDocument> sample({
    ReceiptTemplate? template,
    int? width,
  }) async {
    final resolved = template ?? await ReceiptSettings.instance.load();
    final db = AppDatabase.instance;
    final store = _StoreInfo(
      nama: await db.getSetting('bengkel.nama') ?? 'PUSATKU POS',
      alamat: await db.getSetting('bengkel.alamat') ?? '',
      tagline: await db.getSetting('bengkel.tagline') ?? '',
      telepon: await db.getSetting('bengkel.telepon') ?? '',
    );
    return _render(
      resolved,
      _sampleDetail(),
      store,
      width: width ?? resolved.width,
      customerPhone: '0812-3456-7890',
      karyawanAktif: true,
    );
  }

  ReceiptDocument _render(
    ReceiptTemplate template,
    RecordDetail detail,
    _StoreInfo store, {
    required int width,
    required String customerPhone,
    required bool karyawanAktif,
  }) {
    if (width != 32 && width != 48) {
      throw ArgumentError('Lebar struk hanya 32 atau 48 kolom.');
    }
    final record = detail.record;
    final builder = ReceiptBuilder(width);
    final values = <String, String>{
      'nama_toko': store.nama,
      'tagline': store.tagline,
      'alamat': store.alamat,
      'kontak': store.telepon.trim().isEmpty
          ? ''
          : 'Telp/WA ${store.telepon.trim()}',
      'no_nota': record.noNota,
      'tanggal': dateTimeId.format(record.waktu),
      'pelanggan': record.customerNama,
      'unit': record.unitLabel,
      'total': formatRupiah(record.totalCents),
      'sisa': formatRupiah(detail.sisaCents),
      'jatuh_tempo': record.jatuhTempo == null
          ? ''
          : dateId.format(record.jatuhTempo!),
      'kasir': detail.createdBy ?? '',
      'mekanik': detail.mechanic ?? '',
    };
    String resolve(String text) => text.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'),
      (match) => values[match.group(1)] ?? match.group(0)!,
    );

    void header() {
      final name = store.nama.trim();
      if (name.isNotEmpty) {
        builder.add(
          name,
          align: ReceiptAlign.center,
          bold: template.headerBold,
          double: template.headerDouble && name.length <= (width ~/ 2) - 1,
        );
      }
      if (template.showTagline && store.tagline.trim().isNotEmpty) {
        builder.center(store.tagline.trim());
      }
      if (template.showAlamat && store.alamat.trim().isNotEmpty) {
        builder.center(store.alamat.trim());
      }
      if (template.showKontak && store.telepon.trim().isNotEmpty) {
        builder.center('Telp/WA ${store.telepon.trim()}');
      }
      for (final line in template.headerExtra) {
        final text = resolve(line.text).trim();
        if (text.isNotEmpty) {
          builder.add(text, align: line.align, bold: line.bold);
        }
      }
      builder.divider();
    }

    void meta() {
      bool on(String key) => template.metaFields[key] ?? true;
      if (on('no_nota')) {
        builder.field(template.label('no_nota'), record.noNota);
      }
      if (on('tanggal')) {
        builder.field(
          template.label('tanggal'),
          dateTimeId.format(record.waktu),
        );
      }
      if (karyawanAktif &&
          on('kasir') &&
          (detail.createdBy ?? '').trim().isNotEmpty) {
        builder.field(template.label('kasir'), detail.createdBy!.trim());
      }
      if (karyawanAktif &&
          on('mekanik') &&
          (detail.mechanic ?? '').trim().isNotEmpty) {
        builder.field(template.label('mekanik'), detail.mechanic!.trim());
      }
      if (on('pelanggan') && record.customerNama.trim().isNotEmpty) {
        builder.field(template.label('pelanggan'), record.customerNama.trim());
      }
      if (on('hp') && customerPhone.trim().isNotEmpty) {
        builder.field(template.label('hp'), customerPhone.trim());
      }
      if (on('unit') && record.unitLabel.trim().isNotEmpty) {
        builder.field(template.label('unit'), record.unitLabel.trim());
      }
      if (on('keluhan') && record.keluhan.trim().isNotEmpty) {
        builder.field(template.label('keluhan'), record.keluhan.trim());
      }
      if (on('catatan') && (detail.catatan ?? '').trim().isNotEmpty) {
        builder.field(template.label('catatan'), detail.catatan!.trim());
      }
      if (on('jatuh_tempo') &&
          record.jatuhTempo != null &&
          detail.sisaCents > 0) {
        builder.field(
          template.label('jatuh_tempo'),
          dateId.format(record.jatuhTempo!),
        );
      }
      builder.divider();
    }

    void items() {
      var printed = false;
      void line(
        String nama,
        int jumlah,
        int harga,
        int subtotal,
        int diskon, {
        String? qtyLabel,
      }) {
        builder.item(nama, jumlah, harga, subtotal, qtyLabel: qtyLabel);
        if (!template.showLineDiscount || diskon <= 0) return;
        builder.amount('  ${template.label('diskon')}', -diskon);
      }

      if (template.showJasa && detail.jobs.isNotEmpty) {
        builder.add('JASA', bold: true);
        for (final job in detail.jobs) {
          line(
            job.deskripsi,
            job.jumlah,
            job.hargaTerdaftarCents,
            job.subtotalCents,
            job.diskonAlokasiCents,
          );
        }
        printed = true;
      }
      if (template.showPart && detail.parts.isNotEmpty) {
        if (printed) builder.blank();
        builder.add('SPAREPART', bold: true);
        for (final part in detail.parts) {
          line(
            part.nama,
            part.jumlah,
            part.hargaTerdaftarCents,
            part.subtotalCents,
            part.diskonAlokasiCents,
            qtyLabel: part.qtyLabel,
          );
        }
        printed = true;
      }
      if (printed && template.itemsDivider) builder.divider();
    }

    final kredit =
        record.statusBayar.toUpperCase() != 'LUNAS' ||
        detail.jenisBayar.toUpperCase() != 'LUNAS' ||
        detail.sisaCents > 0;
    final tampilkanRiwayat =
        template.paymentShowHistory &&
        detail.payments.isNotEmpty &&
        (detail.payments.length > 1 || kredit);
    final tampilkanKembalian = template.totalFields['kembalian'] ?? true;
    PaymentRow? pembayaranPertama;
    for (final entry in detail.payments) {
      if (pembayaranPertama == null || entry.id < pembayaranPertama.id) {
        pembayaranPertama = entry;
      }
    }

    void totals() {
      bool on(String key) => template.totalFields[key] ?? true;
      if (on('total_jasa')) {
        builder.amount(template.label('total_jasa'), record.biayaJasaCents);
      }
      if (on('total_part')) {
        builder.amount(template.label('total_part'), record.totalPartCents);
      }
      if (on('diskon') && record.diskonCents > 0) {
        builder.amount(template.label('diskon'), -record.diskonCents);
      }
      if (on('koreksi') && record.totalKoreksiCents != 0) {
        builder.amount(
          template.label('koreksi'),
          record.totalKoreksiCents,
        );
      }
      if (on('retur') && record.totalReturCents > 0) {
        builder.amount(template.label('retur'), -record.totalReturCents);
      }
      if (record.pajakAktif) {
        if (on('dpp')) {
          builder.amount(template.label('dpp'), record.pajakDppCents);
        }
        if (on('ppn')) {
          final suffix = record.pajakPenanggung == pajakPenanggungBengkel
              ? ' (bengkel)'
              : '';
          builder.amount(
            '${template.label('ppn')} '
            '${formatPersenBp(record.pajakPersenBp)}$suffix',
            record.pajakCents,
          );
        }
      }
      if (on('grand_total')) {
        builder.amount(
          template.label('grand_total'),
          record.totalCents,
          bold: true,
        );
      }
      if (on('metode')) {
        builder.field(
          template.label('metode'),
          record.metodeBayar == 'TRANSFER' ? 'Transfer' : 'Tunai',
        );
      }
      if (on('bayar')) {
        builder.amount(template.label('bayar'), detail.totalDibayarCents);
      }
      if (on('kembalian') && !tampilkanRiwayat) {
        // Kembalian hanya dari uang tunai yang benar-benar diterima pada nota,
        // bukan dari nominal pembayaran yang sudah dibatasi tagihan. Bila nota
        // punya riwayat pembayaran, kembalian dicetak per pembayaran.
        final kasDiterima =
            record.metodeBayar == 'CASH' ? record.bayarCents : 0;
        final change = kasDiterima > record.totalCents
            ? kasDiterima - record.totalCents
            : 0;
        builder.amount(template.label('kembalian'), change);
      }
      if (on('status_bayar')) {
        builder.field(template.label('status_bayar'), record.statusBayar);
      }
      builder.divider();
    }

    void payment() {
      if (tampilkanRiwayat) {
        builder.add('RIWAYAT PEMBAYARAN', bold: true);
        for (final entry in detail.payments) {
          builder.field(
            '${dateId.format(entry.waktu)} ${entry.jenis}',
            formatRupiah(entry.nominalCents),
          );
          final tunai = entry.metode == 'CASH' && entry.nominalCents > 0;
          if (tampilkanKembalian &&
              tunai &&
              entry.id == pembayaranPertama?.id) {
            final change = record.bayarCents > entry.nominalCents
                ? record.bayarCents - entry.nominalCents
                : 0;
            if (change > 0) {
              builder.amount(
                '  ${template.label('kembalian')}',
                change,
              );
            }
          }
        }
      }
      if (kredit) {
        if (template.paymentShowSisa) {
          builder.amount('Sisa', detail.sisaCents, bold: true);
        }
      }
      if (tampilkanRiwayat || kredit) builder.divider();
    }

    void warranty() {
      final note = (record.catatanGaransi ?? '').trim();
      final extra = template.warrantyNote.trim();
      var printed = false;
      if (record.bergaransi && template.warrantyShowStatus) {
        builder.field(
          template.label('garansi'),
          record.garansiSampai == null
              ? 'Tanpa garansi'
              : 's.d. ${dateId.format(record.garansiSampai!)}',
        );
        builder.field('Status', record.warrantyStatus);
        printed = true;
      }
      if (template.warrantyShowNote && note.isNotEmpty) {
        for (final line in wrapText(note, width)) {
          builder.add(line);
        }
        printed = true;
      }
      if (template.warrantyShowNote && extra.isNotEmpty) {
        for (final line in wrapText(extra, width)) {
          builder.add(line);
        }
        printed = true;
      }
      if (printed) builder.divider();
    }

    void bank() {
      final nama = template.bankNama.trim();
      final nomor = template.noRekening.trim();
      final atas = template.atasNama.trim();
      final catatan = template.bankCatatan.trim();
      if (nama.isEmpty && nomor.isEmpty && atas.isEmpty && catatan.isEmpty) {
        return;
      }
      builder.divider();
      builder.add(template.label('rekening'), bold: true);
      final account = [nama, nomor].where((part) => part.isNotEmpty).join(' ');
      if (account.isNotEmpty) builder.add(account);
      if (atas.isNotEmpty) builder.add('a.n. $atas');
      for (final line in wrapText(catatan, width)) {
        builder.add(line);
      }
    }

    void footer() {
      for (final line in template.footerLines) {
        final text = resolve(line).trim();
        if (text.isNotEmpty) builder.center(text);
      }
      for (final line in template.footerExtra) {
        final text = resolve(line.text).trim();
        if (text.isNotEmpty) {
          builder.add(text, align: line.align, bold: line.bold);
        }
      }
      if (template.signature.trim().isNotEmpty) {
        builder.blank();
        builder.center(template.signature.trim());
        builder.center('(__________________)');
      }
    }

    final sudahLunas = detail.sisaCents == 0 && detail.totalDibayarCents > 0;
    final isPelunasan =
        template.pelunasanBanner &&
        !record.isVoid &&
        sudahLunas &&
        (record.jenisTransaksi == transactionPelunasanOrder ||
            detail.payments.length > 1);
    if (isPelunasan) {
      builder.divider('=');
      builder.center(template.label('pelunasan'), bold: true);
      builder.divider('=');
    }

    if (template.voidBanner && record.isVoid) {
      builder.divider('=');
      builder.center('STRUK DIBATALKAN', bold: true);
      builder.center('(VOID)');
      final reason = (detail.voidReason ?? '').trim();
      if (reason.isNotEmpty) {
        for (final line in wrapText(reason, width)) {
          builder.center(line);
        }
      }
      builder.divider('=');
    }

    final blocks = <String, void Function()>{
      'header': header,
      'meta': meta,
      'items': items,
      'totals': totals,
      'payment': payment,
      'warranty': warranty,
      'bank': bank,
      'footer': footer,
    };
    for (final id in template.blockOrder) {
      if (!template.visible(id)) continue;
      blocks[id]?.call();
    }

    return ReceiptDocument(
      lines: builder.lines,
      width: width,
      recordId: detail.record.id > 0 ? detail.record.id : null,
      copies: template.copies,
      blankLines: template.blankLines,
      codepage: template.codepage,
      logoPath: template.logoPath.trim(),
      logoWidthMm: template.logoWidthMm,
      customerPhone: customerPhone.trim(),
      customerName: record.customerNama.trim(),
      noNota: record.noNota,
      totalCents: record.totalCents,
    );
  }

  RecordDetail _sampleDetail() {
    final now = DateTime.now();
    final record = ServiceRecordSummary(
      id: 0,
      noNota: 'SRV-2026-0001',
      waktu: now,
      customerNama: 'Budi Santoso',
      unitLabel: 'B 1234 CD Honda Beat',
      keluhan: 'Radiator bocor dan suhu cepat naik',
      biayaJasaCents: 20000000,
      totalPartCents: 9000000,
      diskonCents: 1000000,
      totalCents: 28000000,
      bayarCents: 30000000,
      statusBayar: 'LUNAS',
      metodeBayar: 'CASH',
      voidedAt: null,
      bergaransi: true,
      garansiSampai: now.add(const Duration(days: 30)),
      catatanGaransi: 'Garansi servis 30 hari.',
    );
    return RecordDetail(
      record: record,
      jobs: [
        JobDraft(deskripsi: 'Servis radiator', jumlah: 1, hargaCents: 15000000),
        JobDraft(deskripsi: 'Ganti oli', jumlah: 1, hargaCents: 5000000),
      ],
      parts: [
        PartDraft(
          stockItemId: 0,
          nama: 'Oli Mesin 1L',
          jumlah: 2,
          hargaCents: 4500000,
          modalCents: 3500000,
        ),
      ],
      payments: [
        PaymentRow(
          id: 1,
          jenis: 'PELUNASAN',
          metode: 'CASH',
          nominalCents: 30000000,
          waktu: now,
        ),
      ],
      requestId: null,
      catatan: 'Periksa air radiator setelah 100 km.',
      jenisBayar: 'LUNAS',
      totalDibayarCents: 30000000,
      sisaCents: 0,
      voidReason: null,
      createdBy: 'Kasir',
      mechanic: 'Andi',
    );
  }
}

class _StoreInfo {
  const _StoreInfo({
    required this.nama,
    required this.alamat,
    required this.tagline,
    required this.telepon,
  });

  final String nama;
  final String alamat;
  final String tagline;
  final String telepon;
}
