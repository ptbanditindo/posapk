import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../auth/permissions.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/archive_return_service.dart';
import '../../state/app_state.dart';
import '../../sync/archive_service.dart';
import '../../sync/sync_service.dart';
import '../error_messages.dart';
import '../widgets.dart';

/// Pencarian arsip dua tahun ke server. Server hanya menerima token HMAC dan
/// mengembalikan ciphertext; isi nota didekripsi lokal saat dibuka.
class ArchiveSearchScreen extends StatefulWidget {
  const ArchiveSearchScreen({super.key});

  @override
  State<ArchiveSearchScreen> createState() => _ArchiveSearchScreenState();
}

class _ArchiveSearchScreenState extends State<ArchiveSearchScreen> {
  final _query = TextEditingController();
  DateTime? _dari;
  DateTime? _sampai;
  List<Map<String, Object?>> _results = const [];
  bool _loading = false;
  bool _exporting = false;
  bool _hasMore = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String get _dariParam =>
      _dari == null ? '' : dateOnly.format(_dari!);
  String get _sampaiParam =>
      _sampai == null ? '' : dateOnly.format(_sampai!);

  Future<void> _pickDate({required bool start}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (start ? _dari : _sampai) ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (start) {
        _dari = picked;
      } else {
        _sampai = picked;
      }
    });
  }

  Future<void> _search({bool append = false}) async {
    final query = _query.text.trim();
    if (query.isEmpty && _dari == null && _sampai == null) {
      setState(() => _error = 'Masukkan nomor nota, nama, nopol, atau tanggal.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _results = const [];
    });
    try {
      final limit = append ? (_results.length + 50).clamp(50, 200) : 50;
      final rows = await ArchiveService.instance.search(
        query: query,
        dari: _dariParam,
        sampai: _sampaiParam,
        limit: limit,
      );
      if (!mounted) return;
      setState(() {
        _results = rows;
        _hasMore = rows.length >= limit && limit < 200;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(error);
      });
    }
  }

  Future<void> _open(Map<String, Object?> row) async {
    final docId = '${row['doc_id'] ?? ''}';
    if (docId.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final payload = await ArchiveService.instance.open(
        docId: docId,
        contentHash: '${row['content_hash'] ?? ''}',
      );
      if (!mounted) return;
      Navigator.pop(context);
      await showArchivedDocument(context, payload: payload, metadata: row);
    } catch (error) {
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Gagal membuka arsip: ${friendlyError(error)}',
          error: true);
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final archive = await ArchiveService.instance.exportArchive();
      final raw = const JsonEncoder.withIndent('  ').convert(archive);
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Simpan ekspor arsip',
        fileName: 'pusatkupos_arsip_'
            '${DateTime.now().millisecondsSinceEpoch}.json',
        bytes: utf8.encode(raw),
        mimeType: 'application/json',
      );
      if (!mounted) return;
      showSnack(
        context,
        uri == null
            ? 'Ekspor arsip dibatalkan.'
            : 'Ekspor arsip tersimpan tanpa dekripsi di server.',
      );
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Ekspor arsip gagal: ${friendlyError(error)}',
          error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cari di server'),
        actions: [
          IconButton(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
            tooltip: 'Ekspor seluruh arsip',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Nomor nota, nama pelanggan, atau nopol',
                    prefixIcon: Icon(Icons.manage_search),
                  ),
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.event_outlined, size: 18),
                      label: Text(
                        _dari == null
                            ? 'Dari tanggal'
                            : 'Dari ${dateId.format(_dari!)}',
                      ),
                      selected: _dari != null,
                      onSelected: (_) => _pickDate(start: true),
                      onDeleted: _dari == null
                          ? null
                          : () => setState(() => _dari = null),
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.event_available_outlined,
                          size: 18),
                      label: Text(
                        _sampai == null
                            ? 'Sampai tanggal'
                            : 'Sampai ${dateId.format(_sampai!)}',
                      ),
                      selected: _sampai != null,
                      onSelected: (_) => _pickDate(start: false),
                      onDeleted: _sampai == null
                          ? null
                          : () => setState(() => _sampai = null),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _loading ? null : () => _search(),
                  icon: const Icon(Icons.search),
                  label: const Text('Cari arsip'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const EmptyState(
        title: 'Belum ada hasil',
        subtitle: 'Nota lama yang tersimpan di arsip server akan tampil di sini.',
        icon: Icons.inventory_2_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _results.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= _results.length) {
          return Center(
            child: OutlinedButton.icon(
              onPressed: _loading ? null : () => _search(append: true),
              icon: const Icon(Icons.expand_more),
              label: const Text('Muat lebih banyak'),
            ),
          );
        }
        final row = _results[index];
        final tanggal = DateTime.tryParse('${row['tanggal'] ?? ''}');
        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            onTap: () => _open(row),
            leading: const CircleAvatar(child: Icon(Icons.cloud_outlined)),
            title: Text('${row['no_nota'] ?? row['doc_id'] ?? ''}'),
            subtitle: Text(
              tanggal == null
                  ? 'Tanggal tidak diketahui'
                  : dateTimeId.format(localTime(tanggal)),
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
        );
      },
    );
  }
}

Future<void> showArchivedDocument(
  BuildContext context, {
  required Map<String, Object?> payload,
  Map<String, Object?> metadata = const {},
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ArchivedDocumentSheet(
      payload: payload,
      metadata: metadata,
    ),
  );
}

class ArchivedDocumentSheet extends StatefulWidget {
  const ArchivedDocumentSheet({
    super.key,
    required this.payload,
    this.metadata = const {},
  });

  final Map<String, Object?> payload;
  final Map<String, Object?> metadata;

  @override
  State<ArchivedDocumentSheet> createState() => _ArchivedDocumentSheetState();
}

class _ArchivedDocumentSheetState extends State<ArchivedDocumentSheet> {
  bool _showStruk = false;

  Map<String, Object?> get _record =>
      Map<String, Object?>.from(widget.payload['record'] as Map? ?? const {});

  Map<String, Object?> get _struk =>
      Map<String, Object?>.from(widget.payload['struk'] as Map? ?? const {});

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final total = (record['total_efektif'] as num?)?.toInt() ?? 0;
    final status = '${record['status'] ?? ''}' == 'VOID'
        ? 'VOID'
        : '${record['status_bayar'] ?? ''}';
    final strukText = '${_struk['text'] ?? ''}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${record['no_nota'] ?? widget.metadata['no_nota'] ?? ''}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              [
                if ('${record['customer_nama'] ?? ''}'.isNotEmpty)
                  '${record['customer_nama']}',
                if ('${record['unit_nopol'] ?? ''}'.isNotEmpty)
                  '${record['unit_nopol']}',
                'Total ${formatRupiah(total)}',
                if (status.isNotEmpty) status,
              ].join(' • '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _showStruk = !_showStruk),
                    icon: Icon(
                      _showStruk ? Icons.receipt_long : Icons.receipt_outlined,
                    ),
                    label: Text(_showStruk ? 'Sembunyikan struk' : 'Lihat struk'),
                  ),
                ),
                if (Permissions.can(
                  AppState.instance.operator,
                  permissionRetur,
                )) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            _ArchiveReturnDialog(document: widget.payload),
                      ),
                      icon: const Icon(Icons.assignment_return_outlined),
                      label: const Text('Retur'),
                    ),
                  ),
                ],
              ],
            ),
            if (_showStruk) ...[
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 420),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    strukText.isEmpty
                        ? 'Struk tidak tersimpan; data nota tetap lengkap di '
                            'arsip.'
                        : strukText,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Retur atas nota yang sudah dipurge. Baris dan sisa kuantitas dibaca dari
/// bundel arsip; tabel nota tidak disentuh. Stok dan kas diposting lokal lalu
/// disinkronkan sebagai dokumen `archive_return`.
class _ArchiveReturnDialog extends StatefulWidget {
  const _ArchiveReturnDialog({required this.document});

  final Map<String, Object?> document;

  @override
  State<_ArchiveReturnDialog> createState() => _ArchiveReturnDialogState();
}

class _ArchiveReturnDialogState extends State<_ArchiveReturnDialog> {
  final _reason = TextEditingController();
  final Map<String, TextEditingController> _qty = {};
  List<Map<String, Object?>> _lines = const [];
  String _metode = 'CASH';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final controller in _qty.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lines = await ArchiveReturnService.instance.returnableLines(
        widget.document,
      );
      if (!mounted) return;
      setState(() {
        _lines = lines;
        for (final line in lines) {
          final key = '${line['line_type']}:${line['sync_id']}';
          _qty[key] = TextEditingController(
            text: formatQuantity(
              (line['sisa_milli'] as num?)?.toInt() ?? 0,
              3,
            ),
          );
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(error);
      });
    }
  }

  Future<void> _submit() async {
    final actor = AppState.instance.operator;
    if (actor == null) {
      setState(() => _error = 'Sesi operator tidak tersedia.');
      return;
    }
    final inputs = <ArchiveReturnLineInput>[];
    for (final line in _lines) {
      final key = '${line['line_type']}:${line['sync_id']}';
      final raw = _qty[key]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      final milli = parseQuantityToMilli(raw, desimal: 3);
      if (milli == null) {
        setState(() => _error = 'Jumlah "${line['deskripsi']}" tidak valid.');
        return;
      }
      if (milli <= 0) continue;
      inputs.add(
        ArchiveReturnLineInput(
          lineType: '${line['line_type']}',
          lineSyncId: '${line['sync_id']}',
          qtyMilli: milli,
        ),
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ArchiveReturnService.instance.create(
        document: widget.document,
        items: inputs,
        alasan: _reason.text,
        actor: actor,
        requestId: newSyncId(),
        metodeRefund: _metode,
        enqueue: (txn, id) =>
            SyncService.instance.enqueueArchiveReturn(id, txn: txn),
        enqueueMovement: (txn, id) =>
            SyncService.instance.enqueueStockMovement(id, txn: txn),
      );
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Retur arsip tersimpan.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Retur dari arsip',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Kosongkan baris yang tidak diretur. Nota asli tidak diubah.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _lines.isEmpty
                    ? const Center(
                        child: Text('Semua baris sudah diretur.'),
                      )
                    : ListView.separated(
                        itemCount: _lines.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, index) {
                          final line = _lines[index];
                          final key =
                              '${line['line_type']}:${line['sync_id']}';
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${line['deskripsi'] ?? ''}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Sisa '
                                      '${formatQuantity((line['sisa_milli'] as num?)?.toInt() ?? 0, 3)}'
                                      ' · ${_lineLabel('${line['line_type']}')}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 92,
                                child: TextField(
                                  controller: _qty[key],
                                  textAlign: TextAlign.right,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Qty',
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                  labelText: 'Alasan retur (wajib)',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _metode,
                decoration: const InputDecoration(labelText: 'Metode refund'),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                  DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
                ],
                onChanged: (value) =>
                    setState(() => _metode = value ?? 'CASH'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Batal'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving || _lines.isEmpty ? null : _submit,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Simpan retur'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _lineLabel(String type) => type == 'jasa' ? 'Jasa' : 'Part';
}
