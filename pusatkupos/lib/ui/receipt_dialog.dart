import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/receipt_service.dart';
import '../printer/logo_platform.dart';
import '../printer/printer_config.dart';
import '../printer/printer_service.dart';
import '../printer/receipt_builder.dart';
import 'widgets.dart';

Future<void> showReceiptPreview(
  BuildContext context,
  int recordId, {
  String title = 'Struk',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ReceiptDialog(recordId: recordId, title: title),
  );
}

Future<bool> printReceiptFor(BuildContext context, int recordId) async {
  final printer = await PrinterStore.instance.primary();
  final width = printer?.width ?? 32;
  ReceiptDocument document;
  try {
    document = await ReceiptService.instance.build(recordId, width: width);
  } catch (error) {
    if (context.mounted) {
      showSnack(context, 'Gagal menyiapkan struk: $error', error: true);
    }
    return false;
  }
  final result = await PrinterService.instance.printReceipt(document);
  if (context.mounted) {
    showSnack(context, result.message, error: !result.ok);
  }
  return result.ok;
}

class _ReceiptDialog extends StatefulWidget {
  const _ReceiptDialog({required this.recordId, required this.title});

  final int recordId;
  final String title;

  @override
  State<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<_ReceiptDialog> {
  Future<ReceiptDocument>? _document;
  int _columns = 32;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final printer = await PrinterStore.instance.primary();
    if (!mounted) return;
    setState(() {
      _columns = printer?.width ?? 32;
      _document = _load();
    });
  }

  Future<ReceiptDocument> _load() {
    return ReceiptService.instance.build(
      widget.recordId,
      width: _columns,
    );
  }

  void _setColumns(int value) {
    if (value == _columns) return;
    setState(() {
      _columns = value;
      _document = _load();
    });
  }

  Future<void> _sendWhatsApp(ReceiptDocument document) async {
    final phone = _normalizePhone(document.customerPhone);
    if (phone.isEmpty) {
      showSnack(context, 'Nomor HP pelanggan belum diisi.', error: true);
      return;
    }
    var body = document.text.trim();
    if (body.length > 3500) {
      body = '${body.substring(0, 3500)}\n...';
    }
    final uri = Uri.parse(
      'https://wa.me/$phone?text=${Uri.encodeComponent(body)}',
    );
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        showSnack(context, 'WhatsApp tidak dapat dibuka.', error: true);
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal membuka WhatsApp: $error', error: true);
      }
    }
  }

  static String _normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    if (digits.startsWith('62')) return digits;
    if (digits.startsWith('0')) return '62${digits.substring(1)}';
    if (digits.startsWith('8')) return '62$digits';
    return digits;
  }

  Future<void> _print(ReceiptDocument document) async {
    setState(() => _printing = true);
    try {
      final result = await PrinterService.instance.printReceipt(document);
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mencetak: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReceiptDocument>(
      future: _document,
      builder: (context, snapshot) {
        final document = snapshot.data;
        final canWhatsApp =
            document != null && _normalizePhone(document.customerPhone).isNotEmpty;
        return AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 32, label: Text('58 mm')),
                    ButtonSegment(value: 48, label: Text('80 mm')),
                  ],
                  selected: {_columns},
                  onSelectionChanged: (value) => _setColumns(value.first),
                ),
                const SizedBox(height: 10),
                _buildContent(snapshot),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tutup'),
            ),
            if (canWhatsApp)
              TextButton.icon(
                onPressed: () => _sendWhatsApp(document),
                icon: const Icon(Icons.chat_outlined),
                label: const Text('WhatsApp'),
              ),
            FilledButton.icon(
              onPressed: _printing || document == null
                  ? null
                  : () => _print(document),
              icon: const Icon(Icons.print_outlined),
              label: Text(_printing ? 'Mencetak...' : 'Cetak'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildContent(AsyncSnapshot<ReceiptDocument> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (snapshot.hasError) {
      return Text('Struk gagal disiapkan: ${snapshot.error}');
    }
    final document = snapshot.data!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (document.logoPath.trim().isNotEmpty)
              _LogoPreview(path: document.logoPath),
            for (final line in document.lines)
              SelectableText(
                line.text.isEmpty ? ' ' : line.text,
                textAlign: switch (line.align) {
                  ReceiptAlign.center => TextAlign.center,
                  ReceiptAlign.right => TextAlign.right,
                  ReceiptAlign.left => TextAlign.left,
                },
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: line.double ? 13 : 12,
                  height: 1.3,
                  fontWeight: line.bold ? FontWeight.bold : FontWeight.normal,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LogoPreview extends StatelessWidget {
  const _LogoPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<int>?>(
      future: readLogoBytes(path),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Center(
            child: Image.memory(
              Uint8List.fromList(bytes),
              height: 72,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}
