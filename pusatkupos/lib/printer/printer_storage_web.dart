// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'printer_storage.dart';

PrinterStorage createPrinterStorage() => WebPrinterStorage();

class WebPrinterStorage implements PrinterStorage {
  static const key = 'pusatkupos.printer_config';

  @override
  Future<String?> read() async => html.window.localStorage[key];

  @override
  Future<void> write(String data) async {
    html.window.localStorage[key] = data;
  }
}
