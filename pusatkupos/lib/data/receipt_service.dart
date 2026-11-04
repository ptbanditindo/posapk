import '../core/dates.dart';
import '../core/money.dart';
import 'app_database.dart';
import 'receipt_settings.dart';

class ReceiptDocument {
  const ReceiptDocument({required this.text, required this.width});

  final String text;
  final int width;
}

class ReceiptService {
  ReceiptService._();

  static final ReceiptService instance = ReceiptService._();

  Future<ReceiptDocument> build(int recordId, {int width = 32}) async {
    if (width != 32 && width != 48) {
      throw ArgumentError('Lebar struk hanya 32 atau 48 kolom.');
    }
    final detail = await AppDatabase.instance.recordDetail(recordId);
    if (detail == null) throw StateError('Nota tidak ditemukan.');
    final db = AppDatabase.instance;
    final settings = await ReceiptSettings.instance.load();
    final storeName = await db.getSetting('bengkel.nama') ?? 'PUSATKU POS';
    final storeAddress = await db.getSetting('bengkel.alamat') ?? '';
    final tagline = await db.getSetting('bengkel.tagline') ?? '';
    final contact = await db.getSetting('bengkel.telepon') ?? '';
    final rekening = await db.getSetting('bengkel.rekening') ?? '';
    final footer = await db.getSetting('struk.footer') ?? 'Terima kasih';
    final karyawanAktif = (await db.getSetting('fitur.karyawan') ?? '1') == '1';

    final customerRows = await db.db.rawQuery(
      '''
      SELECT c.nomor_hp, c.alamat
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE r.id = ? LIMIT 1
      ''',
      [recordId],
    );
    final customerPhone = customerRows.isEmpty
        ? ''
        : (customerRows.first['nomor_hp'] as String? ?? '');

    final lines = <String>[];
    void add(String line) => lines.add(line);
    void center(String line) {
      for (final part in wrapText(line, width)) {
        final padding = (width - part.length) ~/ 2;
        add('${' ' * padding}$part');
      }
    }

    void rule() => add('-' * width);

    void pair(String label, String value) {
      final valueLines = wrapText(value, width - 12);
      if (valueLines.isEmpty) return;
      add('${label.padRight(10).substring(0, 10)}: ${valueLines.first}');
      for (final extra in valueLines.skip(1)) {
        add('${' ' * 12}$extra');
      }
    }

    void amount(String label, int cents) {
      final value = formatRupiah(cents);
      final space = width - label.length - value.length;
      if (space >= 1) {
        add('$label${' ' * space}$value');
      } else {
        add(label);
        add(value.padLeft(width));
      }
    }

    center(storeName);
    if (settings['tagline']! && tagline.trim().isNotEmpty) {
      center(tagline.trim());
    }
    if (settings['alamat']! && storeAddress.trim().isNotEmpty) {
      center(storeAddress.trim());
    }
    if (settings['kontak']! && contact.trim().isNotEmpty) {
      center('Telp/WA ${contact.trim()}');
    }
    rule();

    final record = detail.record;
    if (settings['no_nota']!) pair('No. Nota', record.noNota);
    if (settings['tanggal']!) pair('Tanggal', dateTimeId.format(record.waktu));
    if (karyawanAktif && settings['kasir']! && (detail.createdBy ?? '').isNotEmpty) {
      pair('Kasir', detail.createdBy!);
    }
    if (karyawanAktif &&
        settings['mekanik']! &&
        (detail.mechanic ?? '').isNotEmpty) {
      pair('Mekanik', detail.mechanic!);
    }
    if (settings['pelanggan']! && record.customerNama.isNotEmpty) {
      pair('Pelanggan', record.customerNama);
    }
    if (settings['hp']! && customerPhone.isNotEmpty) {
      pair('HP', customerPhone);
    }
    if (settings['unit']! && record.unitLabel.isNotEmpty) {
      pair('Unit', record.unitLabel);
    }
    if (settings['keluhan']! && record.keluhan.trim().isNotEmpty) {
      pair('Keluhan', record.keluhan.trim());
    }
    if (settings['catatan']! && (detail.catatan ?? '').trim().isNotEmpty) {
      pair('Catatan', detail.catatan!.trim());
    }
    rule();

    if (settings['jasa']! && detail.jobs.isNotEmpty) {
      add('JASA');
      for (final job in detail.jobs) {
        for (final line in wrapText(job.deskripsi, width - 4)) {
          add('  $line');
        }
        final label = '  ${job.jumlah} x ${formatRupiah(job.hargaCents)}';
        amount(label, job.subtotalCents);
      }
    }
    if (settings['part']! && detail.parts.isNotEmpty) {
      if (settings['jasa']! && detail.jobs.isNotEmpty) add('');
      add('SPAREPART');
      for (final part in detail.parts) {
        for (final line in wrapText(part.nama, width - 4)) {
          add('  $line');
        }
        final label = '  ${part.jumlah} x ${formatRupiah(part.hargaCents)}';
        amount(label, part.subtotalCents);
      }
    }
    rule();
    if (settings['total_jasa']!) {
      amount('Total jasa', record.biayaJasaCents);
    }
    if (settings['total_part']!) {
      amount('Total part', record.totalPartCents);
    }
    if (settings['diskon']! && record.diskonCents > 0) {
      amount('Diskon', -record.diskonCents);
    }
    if (settings['grand_total']!) {
      amount('GRAND TOTAL', record.totalCents);
    }
    if (settings['metode']!) {
      pair('Metode', record.metodeBayar == 'TRANSFER' ? 'Transfer' : 'Tunai');
    }
    if (settings['bayar']!) {
      amount('Dibayar', detail.totalDibayarCents);
    }
    if (settings['kembalian']!) {
      final change = record.bayarCents > record.totalCents &&
              record.metodeBayar == 'CASH'
          ? record.bayarCents - record.totalCents
          : 0;
      amount('Kembalian', change);
    }
    if (settings['status_bayar']!) {
      pair('Status', record.statusBayar);
    }
    if (settings['garansi']! && record.bergaransi) {
      final end = record.garansiSampai;
      pair(
        'Garansi',
        end == null ? 'Tanpa garansi' : 's.d. ${dateId.format(end)}',
      );
      if (record.statusKlaim == 'Sudah claim') {
        pair('Klaim', 'Sudah diklaim');
      }
      if ((record.catatanGaransi ?? '').trim().isNotEmpty) {
        for (final line in wrapText(record.catatanGaransi!.trim(), width)) {
          add(line);
        }
      }
    }
    if (settings['rekening']! && rekening.trim().isNotEmpty) {
      rule();
      for (final line in wrapText(rekening.trim(), width)) {
        add(line);
      }
    }
    if (settings['footer']! && footer.trim().isNotEmpty) {
      rule();
      center(footer.trim());
    }
    add('');
    return ReceiptDocument(text: lines.join('\n'), width: width);
  }
}

List<String> wrapText(String value, int width) {
  if (width < 1) return const [];
  final words = value.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
  final lines = <String>[];
  var current = '';
  for (final word in words) {
    if (word.isEmpty) continue;
    if (current.isEmpty) {
      current = word;
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
      continue;
    }
    if (current.length + 1 + word.length <= width) {
      current = '$current $word';
    } else {
      lines.add(current);
      current = word;
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}
