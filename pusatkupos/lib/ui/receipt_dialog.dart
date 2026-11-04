import 'package:flutter/material.dart';

import '../data/receipt_service.dart';
import '../printer/printer_config.dart';
import '../printer/printer_service.dart';
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
  late final Future<ReceiptDocument> _document;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _document = _load();
  }

  Future<ReceiptDocument> _load() async {
    final printer = await PrinterStore.instance.primary();
    return ReceiptService.instance.build(
      widget.recordId,
      width: printer?.width ?? 32,
    );
  }

  Future<void> _print(ReceiptDocument document) async {
    setState(() => _printing = true);
    final result = await PrinterService.instance.printReceipt(document);
    if (!mounted) return;
    setState(() => _printing = false);
    showSnack(context, result.message, error: !result.ok);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: FutureBuilder<ReceiptDocument>(
          future: _document,
          builder: (context, snapshot) {
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
                child: SelectableText(
                  document.text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Tutup'),
        ),
        FilledButton.icon(
          onPressed: _printing
              ? null
              : () async {
                  final snapshot = await _document;
                  await _print(snapshot);
                },
          icon: const Icon(Icons.print_outlined),
          label: Text(_printing ? 'Mencetak...' : 'Cetak'),
        ),
      ],
    );
  }
}
