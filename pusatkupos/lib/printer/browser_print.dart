import 'browser_print_stub.dart'
    if (dart.library.html) 'browser_print_web.dart';

Future<void> printInBrowser(String text) => browserPrint(text);
