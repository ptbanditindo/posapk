import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/diagnostics_service.dart';
import '../widgets.dart';

/// Diagnostik perangkat (TASK-076): integrity check, ukuran database/antrean,
/// ekspor log teredaksi. Tidak memuat kredensial, token, atau passphrase.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Map<String, Object?>? _data;
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await DiagnosticsService.instance.collect();
      if (mounted) setState(() => _data = data);
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          'Laporan diagnostik gagal dibuat: $error',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    final data = _data;
    if (data == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(data),
      ),
    );
    if (mounted) showSnack(context, 'Laporan diagnostik disalin.');
  }

  Future<void> _export() async {
    if (kIsWeb) {
      await _copy();
      return;
    }
    setState(() => _exporting = true);
    try {
      final path = await DiagnosticsService.instance.exportToFile();
      if (mounted) showSnack(context, 'Laporan diagnostik disimpan: $path');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Laporan gagal diekspor: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostik perangkat'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
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
                  subtitle: 'Laporan untuk meminta bantuan teknis. Tidak '
                      'memuat kata sandi, token, atau frasa sandi.',
                  child: Column(
                    children: [
                      _line('Dibuat', '${_data?['dibuat_pada'] ?? '-'}'),
                      _line('Sistem', '${_data?['platform'] ?? '-'}'),
                      _line('Versi skema', '${_data?['versi'] ?? '-'}'),
                      _line(
                        'Integritas',
                        '${_data?['integrity_check'] ?? '-'}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Ukuran data',
                  subtitle: 'Ukuran berkas data di perangkat ini.',
                  child: Column(
                    children: _sizeLines(),
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Antrean sinkronisasi',
                  subtitle: 'Data yang menunggu dikirim ke server dan diterima '
                      'dari server.',
                  child: Column(
                    children: [
                      _line('Akan dikirim', _mapText('outbox')),
                      _line('Sudah diterima', _mapText('inbox')),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Data yang perlu diputuskan',
                  subtitle: 'Data yang berbeda antar perangkat dan menunggu '
                      'keputusan.',
                  child: _conflictList(),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Integritas data',
                  subtitle: 'Hanya laporan, tidak mengubah data. Duplikat '
                      'berarti data tercatat dua kali. Selisih berarti saldo '
                      'tidak sama dengan riwayat.',
                  child: _integrityList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copy,
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Salin laporan'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _exporting ? null : _export,
                        icon: const Icon(Icons.save_alt_outlined),
                        label: Text(
                          kIsWeb ? 'Salin (web)' : 'Ekspor berkas',
                        ),
                      ),
                    ),
                  ],
                ),
                if (_exporting) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
    );
  }

  List<Widget> _sizeLines() {
    final sizes = _data?['ukuran'];
    if (sizes is! Map) return const [Text('-')];
    const labels = {
      'database': 'Berkas data',
      'wal': 'Jurnal WAL',
      'shm': 'Memori bersama',
    };
    return [
      for (final entry in sizes.entries)
        _line(
          labels[entry.key] ?? '${entry.key}',
          _bytes((entry.value as num?)?.toInt() ?? 0),
        ),
    ];
  }

  String _mapText(String key) {
    final value = _data?[key];
    if (value is! Map || value.isEmpty) return '-';
    return value.entries.map((entry) => '${entry.key}: ${entry.value}').join(' · ');
  }

  Widget _conflictList() {
    final rows = _data?['konflik'];
    if (rows is! List || rows.isEmpty) {
      return const Text('Tidak ada data yang perlu diputuskan.');
    }
    return Column(
      children: [
        for (final row in rows)
          if (row is Map)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${row['reason']}'),
              subtitle: Text('${row['status']}'),
              trailing: Text('${row['jumlah']}'),
            ),
      ],
    );
  }

  Widget _integrityList() {
    final data = _data?['integritas'];
    if (data is! Map) return const Text('-');
    List rows(String key) {
      final value = data[key];
      return value is List ? value : const [];
    }

    final duplicates = rows('duplikat');
    final stock = rows('stok_selisih');
    final cash = rows('kas_selisih');
    final negative = rows('stok_negatif');
    if (duplicates.isEmpty &&
        stock.isEmpty &&
        cash.isEmpty &&
        negative.isEmpty) {
      return const Text('Tidak ada selisih atau duplikat terdeteksi.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (duplicates.isNotEmpty) ...[
          Text('Duplikat: ${duplicates.length}'),
          for (final row in duplicates)
            if (row is Map)
              Text(
                '· ${row['tabel']} (${row['kunci']}): ${row['jumlah']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          const SizedBox(height: 8),
        ],
        if (stock.isNotEmpty) ...[
          Text('Selisih saldo stok: ${stock.length}'),
          for (final row in stock)
            if (row is Map)
              Text(
                '· ${row['nama']}: saldo ${row['saldo_milli']} vs '
                'ledger ${row['ledger_milli']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          const SizedBox(height: 8),
        ],
        if (cash.isNotEmpty) ...[
          Text('Selisih kas: ${cash.length}'),
          for (final row in cash)
            if (row is Map)
              Text(
                '· ${row['jenis']} ${row['payment_sync_id']}: '
                'sumber ${row['sumber']} vs ledger ${row['ledger']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          const SizedBox(height: 8),
        ],
        if (negative.isNotEmpty) ...[
          Text('Stok negatif: ${negative.length}'),
          for (final row in negative)
            if (row is Map)
              Text(
                '· ${row['nama']}: ${row['jumlah_milli']} unit terkecil',
                style: Theme.of(context).textTheme.bodySmall,
              ),
        ],
      ],
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(
            child: Text(value, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  String _bytes(int value) {
    if (value <= 0) return '0 B';
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
