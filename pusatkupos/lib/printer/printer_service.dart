import 'dart:typed_data';
import 'dart:ui' as ui;

import '../data/receipt_service.dart';
import 'escpos_builder.dart';
import 'logo_platform.dart';
import 'printer_adapter.dart';
import 'printer_config.dart';
import 'printer_manager.dart';
import 'receipt_builder.dart';

class PrintResult {
  const PrintResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class PrinterService {
  PrinterService({PrinterManager? manager, PrinterStore? store})
      : _manager = manager ?? PrinterManager.instance,
        _store = store ?? PrinterStore.instance;

  static final PrinterService instance = PrinterService();

  final PrinterManager _manager;
  final PrinterStore _store;

  Future<PrintResult> printReceipt(
    ReceiptDocument document, {
    PrinterConfig? printer,
  }) async {
    final target = printer ?? await _store.primary();
    if (target == null) {
      return const PrintResult(
        ok: false,
        message: 'Belum ada printer. Tambahkan printer di Pengaturan.',
      );
    }
    var resolved = document;
    if (resolved.width != target.width) {
      final recordId = resolved.recordId;
      if (recordId == null) {
        return PrintResult(
          ok: false,
          message: 'Lebar struk ${resolved.width} kolom tidak cocok dengan '
              'printer ${target.width} kolom. Buka ulang nota.',
        );
      }
      resolved = await ReceiptService.instance.build(
        recordId,
        width: target.width,
      );
    }
    final payload = await _receiptPayload(target, resolved);
    final copies = target.mode == 'ESCPOS' || target.mode == 'TEXT'
        ? resolved.copies.clamp(1, 3).toInt()
        : 1;
    PrintResult? last;
    for (var copy = 0; copy < copies; copy++) {
      last = await _send(target, payload);
      if (!last.ok) return last;
    }
    return last!;
  }

  Future<PrintResult> printText(
    String text, {
    required PrinterConfig printer,
  }) =>
      _print(printer, text, printer.width);

  Future<PrintResult> testPrint(PrinterConfig printer) {
    final text = [
      'PUSATKU POS',
      'Tes printer',
      List.filled(printer.width, '-').join(),
      'Printer: ${printer.nama}',
      'Jenis: ${printer.typeLabel}',
      'Tujuan: ${printer.targetLabel}',
      'Kertas: ${printer.paperMm} mm',
      '',
    ].join('\n');
    return _print(printer, text, printer.width);
  }

  Future<PrintResult> _print(
    PrinterConfig printer,
    String text,
    int width,
  ) =>
      _send(printer, _payload(printer, text, width));

  Future<PrintResult> _send(PrinterConfig printer, PrintPayload payload) async {
    try {
      if ((printer.connectionType == 'BLUETOOTH' ||
              printer.connectionType == 'USB') &&
          _manager.statusOf(printer).status != 'CONNECTED') {
        await _manager.connect(printer);
      }
      await _manager.send(printer, payload);
      return PrintResult(
        ok: true,
        message: _successMessage(printer),
      );
    } on PrinterException catch (error) {
      return PrintResult(ok: false, message: error.message);
    } on UnsupportedError catch (error) {
      return PrintResult(ok: false, message: '$error');
    } catch (error) {
      return PrintResult(
        ok: false,
        message: 'Gagal mencetak ke ${printer.nama}. '
            'Periksa koneksi printer. Detail: $error',
      );
    }
  }

  Future<PrintPayload> _receiptPayload(
    PrinterConfig printer,
    ReceiptDocument document,
  ) async {
    final width = document.width;
    final encoding =
        document.codepage.isEmpty ? printer.encoding : document.codepage;
    switch (printer.mode) {
      case 'ESCPOS':
        final builder = EscPosBuilder(width: width, encoding: encoding)
          ..init();
        await _writeLogo(builder, document, width);
        builder
          ..writeLines(document.lines)
          ..feed(document.blankLines)
          ..cut();
        return PrintPayload(
          text: document.text,
          bytes: builder.bytes,
          width: width,
          encoding: encoding,
        );
      case 'TEXT':
        final text =
            '${document.text}\n${'\n' * (document.blankLines + 1)}';
        return PrintPayload(
          text: text,
          bytes: EscPosBuilder.encodeText(text, encoding),
          width: width,
          encoding: encoding,
        );
      case 'SYSTEM':
      case 'BROWSER':
        return PrintPayload(
          text: document.text,
          bytes: const [],
          width: width,
          encoding: encoding,
        );
      default:
        throw PrinterException(
          'Mode cetak ${printer.mode} tidak dikenal.',
          code: 'INVALID_MODE',
        );
    }
  }

  Future<void> _writeLogo(
    EscPosBuilder builder,
    ReceiptDocument document,
    int columns,
  ) async {
    final path = document.logoPath.trim();
    if (path.isEmpty) return;
    ui.Image? image;
    try {
      final bytes = await readLogoBytes(path);
      if (bytes == null || bytes.isEmpty) return;
      final maxDots = columns * 12;
      final requested =
          (document.logoWidthMm * 8).clamp(1, maxDots).toInt();
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(bytes),
        targetWidth: requested,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return;
      final rgba = raw.buffer.asUint8List(
        raw.offsetInBytes,
        raw.lengthInBytes,
      );
      final imageWidth = image.width;
      final imageHeight = image.height;
      final widthBytes = (imageWidth + 7) ~/ 8;
      final raster = Uint8List(widthBytes * imageHeight);
      for (var y = 0; y < imageHeight; y++) {
        final row = y * imageWidth * 4;
        for (var x = 0; x < imageWidth; x++) {
          final index = row + x * 4;
          final alpha = rgba[index + 3] / 255;
          if (alpha <= 0) continue;
          final luma = (rgba[index] * 299 +
                  rgba[index + 1] * 587 +
                  rgba[index + 2] * 114) ~/
              1000;
          final value = luma * alpha + 255 * (1 - alpha);
          if (value < 160) {
            raster[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
          }
        }
      }
      builder
        ..align(ReceiptAlign.center)
        ..raster(raster, widthBytes, imageHeight)
        ..align(ReceiptAlign.left)
        ..feed(1);
    } catch (_) {
      // Logo rusak atau tidak terbaca: struk tetap dicetak tanpa logo.
    } finally {
      image?.dispose();
    }
  }

  PrintPayload _payload(PrinterConfig printer, String text, int width) {
    switch (printer.mode) {
      case 'ESCPOS':
        final builder = EscPosBuilder(
          width: width,
          encoding: printer.encoding,
        )
          ..init()
          ..text(text)
          ..feed(3)
          ..cut();
        return PrintPayload(
          text: text,
          bytes: builder.bytes,
          width: width,
          encoding: printer.encoding,
        );
      case 'TEXT':
        final wrapped = EscPosBuilder.wrapLines(text, width).join('\n');
        return PrintPayload(
          text: wrapped,
          bytes: _plainBytes(wrapped, printer.encoding),
          width: width,
          encoding: printer.encoding,
        );
      case 'SYSTEM':
      case 'BROWSER':
        return PrintPayload(
          text: text,
          bytes: const [],
          width: width,
          encoding: printer.encoding,
        );
      default:
        throw PrinterException(
          'Mode cetak ${printer.mode} tidak dikenal.',
          code: 'INVALID_MODE',
        );
    }
  }

  String _successMessage(PrinterConfig printer) {
    switch (printer.mode) {
      case 'SYSTEM':
        return 'Dialog cetak Android dibuka untuk ${printer.nama}. '
            'Konfirmasi di dialog lalu periksa hasil cetak.';
      case 'BROWSER':
        return 'Dialog cetak browser dibuka. Konfirmasi di dialog lalu '
            'periksa hasil cetak.';
      default:
        return 'Struk dikirim ke ${printer.nama}. Periksa hasil cetak.';
    }
  }

  List<int> _plainBytes(String text, String encoding) =>
      EscPosBuilder.encodeText('$text\n\n\n', encoding);
}
