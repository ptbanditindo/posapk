// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<void> browserPrint(String text) async {
  // Window baru di dart:html bertipe WindowBase, tetapi pada runtime browser
  // objeknya Window penuh (document + print).
  final dynamic window =
      html.window.open('', '_blank', 'width=420,height=720');
  final dynamic document = window.document;
  document.title = 'Struk';
  final pre = document.createElement('pre')
    ..text = text
    ..setAttribute(
      'style',
      'font-family: ui-monospace, monospace; font-size: 12px; margin: 12px;',
    );
  document.body?.children.clear();
  document.body?.append(pre);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  window.print();
}
