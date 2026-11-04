import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../sync/sync_service.dart';
import '../widgets.dart';

const _reasonLabels = {
  'versi_lokal_lebih_baru': 'Versi lokal lebih baru',
  'harga_dikunci_owner': 'Harga jasa dikunci pemilik',
  'stok_negatif': 'Stok menjadi negatif',
  'tanda_tangan_tidak_valid': 'Tanda tangan tidak valid',
  'dekripsi_gagal': 'Data tidak dapat dibuka',
  'konflik_unik': 'Bentrok data unik',
  'entity_belum_didukung': 'Jenis data belum didukung',
  'nota_butuh_induk': 'Nota induk belum tersedia',
  'gagal_terapkan': 'Perubahan gagal diterapkan',
  'retryable': 'Perubahan tertunda',
};

String _statusLabel(Map<String, Object?> row) {
  final resolved = row['resolved_at'] != null;
  final status = '${row['status'] ?? ''}';
  if (status == 'ignored') return 'Diabaikan';
  if (resolved) return 'Selesai';
  return switch (status) {
    'failed' => 'Perlu tindakan',
    'retrying' => 'Menunggu dicoba ulang',
    _ => 'Tercatat',
  };
}

class SyncConflictsScreen extends StatefulWidget {
  const SyncConflictsScreen({super.key});

  @override
  State<SyncConflictsScreen> createState() => _SyncConflictsScreenState();
}

class _SyncConflictsScreenState extends State<SyncConflictsScreen> {
  final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');
  List<Map<String, Object?>> _rows = [];
  Map<String, Object?> _status = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await SyncService.instance.conflicts();
    final status = await SyncService.instance.status();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _status = status;
      _loading = false;
    });
  }

  Future<void> _retry(Map<String, Object?> row) async {
    setState(() => _busy = true);
    try {
      await SyncService.instance.retryConflict(row['id'] as int);
      await SyncService.instance.syncNow();
      await _load();
      if (mounted) showSnack(context, 'Perubahan dicoba ulang.');
    } catch (error) {
      await _load();
      if (mounted) {
        showSnack(context, 'Masih tertahan: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ignore(Map<String, Object?> row) async {
    final ok = await confirmAction(
      context,
      title: 'Abaikan konflik',
      message:
          'Perubahan ini tidak akan diterapkan di perangkat ini dan akan '
          'ditandai selesai. Konflik tetap tercatat dan tidak dihapus.',
      confirmLabel: 'Abaikan',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await SyncService.instance.ignoreConflict(row['id'] as int);
      await _load();
      if (mounted) showSnack(context, 'Konflik ditandai diabaikan.');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menandai konflik: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await SyncService.instance.syncNow();
      await _load();
    } catch (error) {
      await _load();
      if (mounted) showSnack(context, 'Sinkron gagal: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _rows.where((row) => row['resolved_at'] == null).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Konflik sinkronisasi'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _sync,
            icon: const Icon(Icons.sync),
            tooltip: 'Sinkron sekarang',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: 'Ringkasan',
                  child: Column(
                    children: [
                      _line('Belum selesai', '$pending'),
                      _line('Antrean kirim', '${_status['pending'] ?? 0}'),
                      _line('Gagal diterapkan', '${_status['failed'] ?? 0}'),
                      if (('${_status['last_error'] ?? ''}').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${_status['last_error']}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (_rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text('Tidak ada konflik yang tercatat.'),
                    ),
                  ),
                for (final row in _rows) ...[
                  _conflictCard(row),
                  const SizedBox(height: 10),
                ],
              ],
            ),
    );
  }

  Widget _conflictCard(Map<String, Object?> row) {
    final resolved = row['resolved_at'] != null;
    final reason = '${row['reason'] ?? ''}';
    final created = DateTime.tryParse('${row['created_at'] ?? ''}');
    final detail = _detail(row);
    final canRetry = !resolved && row['inbox_id'] != null;
    return SectionCard(
      title: _reasonLabels[reason] ?? reason,
      subtitle:
          '${row['entity'] ?? ''} ${row['entity_id'] ?? ''} · ${_statusLabel(row)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (created != null)
            _line('Waktu', _dateFormat.format(created.toLocal())),
          if (((row['retry_count'] as num?)?.toInt() ?? 0) > 0)
            _line('Percobaan', '${row['retry_count']}'),
          if (('${row['last_error'] ?? ''}').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${row['last_error']}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (detail != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Rincian', style: TextStyle(fontSize: 13)),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(detail),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          if (!resolved)
            Wrap(
              spacing: 8,
              children: [
                if (canRetry)
                  FilledButton.tonal(
                    onPressed: _busy ? null : () => _retry(row),
                    child: const Text('Coba lagi'),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _ignore(row),
                  child: const Text('Abaikan'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Map<String, Object?>? _detail(Map<String, Object?> row) {
    final raw = row['detail_json'] as String? ?? '';
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? decoded.map((key, value) => MapEntry('$key', value))
          : null;
    } catch (_) {
      return null;
    }
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
