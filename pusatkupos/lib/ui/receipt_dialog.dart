import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/feature_flags.dart';
import '../data/print_queue_service.dart';
import '../data/receipt_service.dart';
import '../printer/logo_platform.dart';
import '../printer/printer_config.dart';
import '../printer/receipt_builder.dart';
import 'error_messages.dart';
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
  final result = await PrintQueueService.instance.printReceipt(
    recordId,
    width: printer?.width,
  );
  if (context.mounted) {
    showSnack(
      context,
      result.ok ? result.message : friendlyError(result.message),
      error: !result.ok,
    );
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
  PrintJob? _printJob;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final printer = await PrinterStore.instance.primary();
    final job = await PrintQueueService.instance.latest(widget.recordId);
    if (!mounted) return;
    setState(() {
      _columns = printer?.width ?? 32;
      _printJob = job;
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
      final result = await PrintQueueService.instance.printReceipt(
        widget.recordId,
        document: document,
        width: _columns,
      );
      final job = await PrintQueueService.instance.latest(widget.recordId);
      if (!mounted) return;
      setState(() => _printJob = job);
      showSnack(
        context,
        result.ok ? result.message : friendlyError(result.message),
        error: !result.ok,
      );
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mencetak: ${friendlyError(error)}',
            error: true);
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
        final canWhatsApp = FeatureFlagsService.instance.isEnabled(
              featureWhatsapp,
            ) &&
            document != null &&
            _normalizePhone(document.customerPhone).isNotEmpty;
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
                if (_printJob != null) ...[
                  const SizedBox(height: 10),
                  _PrintStatus(job: _printJob!),
                ],
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
              label: Text(
                _printing
                    ? 'Mencetak...'
                    : (_printJob?.failed == true ? 'Cetak ulang' : 'Cetak'),
              ),
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

class _PrintStatus extends StatelessWidget {
  const _PrintStatus({required this.job});

  final PrintJob job;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = job.failed;
    final color = failed ? scheme.error : scheme.onSurfaceVariant;
    final detail = job.lastError.trim().isEmpty
        ? ''
        : ' — ${friendlyError(job.lastError)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: failed ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            failed
                ? Icons.print_disabled_outlined
                : (job.printed
                    ? Icons.print_outlined
                    : Icons.hourglass_empty),
            size: 18,
            color: failed ? scheme.onErrorContainer : color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Cetak: ${job.label}$detail',
              style: TextStyle(
                fontSize: 12,
                color: failed ? scheme.onErrorContainer : color,
              ),
            ),
          ),
          if (job.attempts > 0)
            Text(
              '${job.attempts}x',
              style: TextStyle(
                fontSize: 11,
                color: failed ? scheme.onErrorContainer : color,
              ),
            ),
        ],
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
