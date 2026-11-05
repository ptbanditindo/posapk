import 'dart:math' as math;
import 'dart:typed_data';

import 'receipt_builder.dart';

/// Penyusun perintah ESC/POS. Teks dibungkus sesuai lebar kertas, lalu
/// diubah ke codepage printer. Karakter yang tidak didukung ditransliterasi
/// agar tidak berubah menjadi "?".
class EscPosBuilder {
  EscPosBuilder({this.width = 32, this.encoding = 'LATIN1'});

  final int width;
  final String encoding;
  final List<int> _bytes = <int>[];

  static const _esc = 0x1b;
  static const _gs = 0x1d;

  List<int> get bytes => List<int>.unmodifiable(_bytes);

  int get _codepage => switch (encoding.toUpperCase()) {
        'CP437' => 0,
        'CP850' => 2,
        'CP1252' || 'WINDOWS-1252' => 16,
        _ => -1,
      };

  void init() {
    _bytes.addAll([_esc, 0x40]);
    final page = _codepage;
    if (page >= 0) _bytes.addAll([_esc, 0x74, page]);
  }

  void text(String value) {
    for (final line in wrapLines(value, width)) {
      if (line.isEmpty) {
        _bytes.add(0x0a);
        continue;
      }
      _writeChunked(line, width);
    }
  }

  /// Tulis baris struk bergaya: perataan, tebal, dan huruf ganda.
  void writeLines(List<ReceiptLine> lines) {
    for (final line in lines) {
      final alignment = switch (line.align) {
        ReceiptAlign.center => 0x01,
        ReceiptAlign.right => 0x02,
        ReceiptAlign.left => 0x00,
      };
      _bytes.addAll([_esc, 0x61, alignment]);
      _bytes.addAll([_esc, 0x45, line.bold ? 0x01 : 0x00]);
      _bytes.addAll([_gs, 0x21, line.double ? 0x11 : 0x00]);
      if (line.text.isEmpty) {
        _bytes.add(0x0a);
        continue;
      }
      // Baris tengah/kanan sudah diberi padding untuk pratinjau; buang
      // padding itu agar perataan hardware tidak menghitungnya dua kali.
      final text = line.align == ReceiptAlign.left
          ? line.text
          : line.text.trimLeft();
      _writeChunked(text, line.double ? math.max(1, width ~/ 2) : width);
    }
    _bytes.addAll([_esc, 0x61, 0x00, _esc, 0x45, 0x00, _gs, 0x21, 0x00]);
  }

  /// Transliterasi bisa membuat satu karakter menjadi beberapa byte. Pecah
  /// hasil encode agar baris tidak melewati lebar kertas.
  void _writeChunked(String text, int columns) {
    final encoded = _encode(text);
    if (encoded.isEmpty) {
      _bytes.add(0x0a);
      return;
    }
    for (var start = 0; start < encoded.length; start += columns) {
      final end = math.min(start + columns, encoded.length);
      _bytes.addAll(encoded.sublist(start, end));
      _bytes.add(0x0a);
    }
  }

  void selectCodePage(int page) => _bytes.addAll([_esc, 0x74, page]);

  void align(ReceiptAlign align) {
    final value = switch (align) {
      ReceiptAlign.center => 0x01,
      ReceiptAlign.right => 0x02,
      ReceiptAlign.left => 0x00,
    };
    _bytes.addAll([_esc, 0x61, value]);
  }

  void center(String value) {
    _bytes.addAll([_esc, 0x61, 0x01]);
    text(value);
    _bytes.addAll([_esc, 0x61, 0x00]);
  }

  void bold(bool enabled) {
    _bytes.addAll([_esc, 0x45, enabled ? 0x01 : 0x00]);
  }

  void doubleSize(bool enabled) {
    final value = enabled ? 0x11 : 0x00;
    _bytes.addAll([_gs, 0x21, value]);
  }

  void rule([String char = '-']) => text(char * width);

  /// Cetak bitmap 1-bit (hitam = bit 1) memakai perintah GS v 0.
  void raster(Uint8List data, int widthBytes, int height) {
    if (widthBytes <= 0 || height <= 0 || data.isEmpty) return;
    _bytes.addAll([
      _gs, 0x76, 0x30, 0x00,
      widthBytes & 0xff, (widthBytes >> 8) & 0xff,
      height & 0xff, (height >> 8) & 0xff,
    ]);
    _bytes.addAll(data);
  }

  void feed([int lines = 1]) {
    for (var i = 0; i < lines; i++) {
      _bytes.add(0x0a);
    }
  }

  void cut() => _bytes.addAll([_gs, 0x56, 0x42, 0x00]);

  /// Bungkus setiap baris teks sesuai lebar kertas. Baris kosong tetap
  /// dipertahankan sebagai baris kosong.
  static List<String> wrapLines(String value, int width) {
    final result = <String>[];
    for (final line in value.split('\n')) {
      final chunks = line.length <= width ? [line] : _wrapLine(line, width);
      if (chunks.isEmpty) {
        result.add('');
      } else {
        result.addAll(chunks);
      }
    }
    return result;
  }

  static List<String> _wrapLine(String value, int width) {
    final words = value.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
    final result = <String>[];
    var current = '';
    for (final word in words) {
      if (word.isEmpty) continue;
      if (current.isEmpty) {
        current = word;
      } else if (current.length + 1 + word.length <= width) {
        current = '$current $word';
      } else {
        result.add(current);
        current = word;
      }
      while (current.length > width) {
        result.add(current.substring(0, width));
        current = current.substring(width);
      }
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }

  List<int> _encode(String value) {
    final out = <int>[];
    for (final rune in value.runes) {
      if (rune == 0x09 || rune >= 0x20 && rune <= 0x7e) {
        out.add(rune);
        continue;
      }
      final byte = _byteForRune(rune);
      if (byte != null) {
        out.add(byte);
      } else {
        for (final replacement in _transliterate(rune).codeUnits) {
          out.add(replacement <= 0x7e ? replacement : 0x3f);
        }
      }
    }
    return out;
  }

  /// Byte codepage untuk rune, atau `null` bila tidak tersedia dan perlu
  /// ditransliterasi.
  int? _byteForRune(int rune) {
    final upper = encoding.toUpperCase();
    if (upper == 'ASCII') return null;
    if (upper == 'LATIN1') {
      return rune >= 0xa0 && rune <= 0xff ? rune : null;
    }
    if (upper == 'CP437') return _codepageByte(_cp437, rune);
    if (upper == 'CP850') return _codepageByte(_cp850, rune);
    if (upper == 'CP1252' || upper == 'WINDOWS-1252') {
      final special = _cp1252Specials[rune];
      if (special != null) return special;
      return rune >= 0xa0 && rune <= 0xff ? rune : null;
    }
    return null;
  }

  int? _codepageByte(List<int> table, int rune) {
    if (rune >= 0xa0 && rune <= 0xff) {
      final byte = table[rune - 0xa0];
      if (byte >= 0) return byte;
    }
    return _cp437fSpecials[rune];
  }

  String _transliterate(int rune) {
    const map = {
      0x00a0: ' ',
      0x2018: "'",
      0x2019: "'",
      0x201c: '"',
      0x201d: '"',
      0x2013: '-',
      0x2014: '-',
      0x2026: '...',
      0x2022: '-',
      0x00b0: ' derajat',
      0x00d7: 'x',
      0x20ac: 'EUR',
      0x2122: 'TM',
      0x00a9: '(c)',
      0x00ae: '(r)',
    };
    return map[rune] ?? '?';
  }

  // Nilai byte untuk rune 0xA0..0xFF pada CP437. -1 berarti tidak tersedia.
  static const List<int> _cp437 = [
    255, 173, 155, 156, -1, 157, -1, -1, -1, -1, 166, 174, 170, -1, -1, -1,
    248, 241, 253, -1, -1, 230, -1, 250, -1, -1, 167, 175, 172, 171, -1, 168,
    -1, -1, -1, -1, 142, 143, 146, 128, -1, 144, -1, -1, -1, -1, -1, -1,
    -1, 165, -1, -1, -1, -1, 153, -1, -1, -1, -1, -1, 154, -1, -1, 225,
    133, 160, 131, -1, 132, 134, 145, 135, 138, 130, 136, 137, 141, 161, 140,
    139, -1, 164, 149, 162, 147, -1, 148, 246, -1, 151, 163, 150, 129, -1, -1,
    152,
  ];

  // Nilai byte untuk rune 0xA0..0xFF pada CP850. -1 berarti tidak tersedia.
  static const List<int> _cp850 = [
    255, 173, 189, 156, 207, 190, 221, 245, 249, 184, 166, 174, 170, 240, 169,
    238, 248, 241, 253, 252, 239, 230, 244, 250, 247, 251, 167, 175, 172, 171,
    243, 168, 183, 181, 182, 199, 142, 143, 146, 128, 212, 144, 210, 211, 222,
    214, 215, 216, 209, 165, 227, 224, 226, 229, 153, 158, 157, 235, 233, 234,
    154, 237, 232, 225, 133, 160, 131, 198, 132, 134, 145, 135, 138, 130, 136,
    137, 141, 161, 140, 139, 208, 164, 149, 162, 147, 228, 148, 246, 155, 151,
    163, 150, 129, 236, 231, 152,
  ];

  static const Map<int, int> _cp437fSpecials = {
    0x0192: 0x9f, // ƒ
  };

  /// Encode teks biasa memakai tabel codepage yang sama dengan ESC/POS.
  static List<int> encodeText(String value, String encoding) =>
      EscPosBuilder(encoding: encoding)._encode(value);

  static const Map<int, int> _cp1252Specials = {
    0x20ac: 0x80,
    0x201a: 0x82,
    0x0192: 0x83,
    0x201e: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x02c6: 0x88,
    0x2030: 0x89,
    0x0160: 0x8a,
    0x2039: 0x8b,
    0x0152: 0x8c,
    0x017d: 0x8e,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201c: 0x93,
    0x201d: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02dc: 0x98,
    0x2122: 0x99,
    0x0161: 0x9a,
    0x203a: 0x9b,
    0x0153: 0x9c,
    0x017e: 0x9e,
    0x0178: 0x9f,
  };
}
