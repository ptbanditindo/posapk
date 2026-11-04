import 'dart:convert';

/// Penyusun perintah ESC/POS. Teks dikirim sebagai Latin-1 sehingga
/// karakter di luar jangkauan printer diganti agar tidak memotong struk.
class EscPosBuilder {
  EscPosBuilder({this.width = 32, this.encoding = 'LATIN1'});

  final int width;
  final String encoding;
  final List<int> _bytes = <int>[];

  static const _esc = 0x1b;
  static const _gs = 0x1d;

  List<int> get bytes => List<int>.unmodifiable(_bytes);

  void init() => _bytes.addAll([_esc, 0x40]);

  void text(String value) {
    for (final line in value.split('\n')) {
      _bytes.addAll(_encode(line));
      _bytes.add(0x0a);
    }
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

  void feed([int lines = 1]) {
    for (var i = 0; i < lines; i++) {
      _bytes.add(0x0a);
    }
  }

  void cut() => _bytes.addAll([_gs, 0x56, 0x42, 0x00]);

  List<int> _encode(String value) {
    final asciiOnly = encoding.toUpperCase() == 'ASCII';
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 0x09 || (rune >= 0x20 && rune <= 0x7e)) {
        buffer.writeCharCode(rune);
      } else if (!asciiOnly && rune >= 0xa0 && rune <= 0xff) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
      }
    }
    return latin1.encode(buffer.toString());
  }
}
