import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../sync/sync_conflict_rules.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

const _reasonLabels = {
  'versi_lokal_lebih_baru': 'Versi lokal lebih baru',
  'harga_dikunci_owner': 'Harga jasa dikunci pemilik',
  'harga_tidak_valid': 'Harga barang/jasa tidak valid',
  'harga_di_bawah_batas': 'Harga di bawah batas',
  'stok_negatif': 'Stok menjadi negatif',
  'tanda_tangan_tidak_valid': 'Tanda tangan tidak valid',
  'dekripsi_gagal': 'Data tidak dapat dibuka',
  'konflik_unik': 'Bentrok data unik',
  'entity_belum_didukung': 'Jenis data belum didukung',
  'nota_butuh_induk': 'Nota induk belum tersedia',
  'gagal_terapkan': 'Perubahan gagal diterapkan',
  'retryable': 'Perubahan tertunda',
  'pembayaran_melebihi_total': 'Pembayaran melebihi total efektif',
  'gaji_ganda': 'Gaji siklus dibayar lebih dari sekali',
  'retur_pada_nota_void': 'Retur pada nota VOID',
  'retur_melebihi_qty': 'Retur melebihi qty terjual',
  'retur_baris_tidak_ditemukan': 'Baris retur tidak ditemukan',
  'retur_tidak_valid': 'Data retur tidak valid',
  'koreksi_pada_nota_void': 'Koreksi pada nota VOID',
  'koreksi_di_bawah_batas': 'Koreksi di bawah batas',
  'void_setelah_retur': 'Void setelah retur aktif',
  'void_menang': 'Void menang atas retur',
  'kompensasi_dibutuhkan': 'Kompensasi diperlukan',
  'kompensasi_gagal': 'Kompensasi gagal',
  'pengirim_dicabut': 'Perangkat pengirim sudah dicabut',
  'akun_pengirim_nonaktif': 'Akun pengirim tidak aktif',
  'peran_viewer_hanya_baca': 'Peran viewer hanya baca',
  'hanya_owner': 'Hanya pemilik yang boleh',
  'hapus_order_hanya_owner': 'Hapus order hanya oleh pemilik',
  'komisi_akun_hilang': 'Akun mekanik komisi tidak ditemukan',
  'komisi_tanpa_snapshot': 'Tarif komisi nota tidak tersedia',
  'kode_barang_bentrok': 'Kode barang bentrok',
  'kode_barang_kosong': 'Barang tanpa kode',
  'no_nota_bentrok': 'Nomor nota bentrok',
  'rekonsiliasi_beda': 'Rekonsiliasi berbeda',
  'pembelian_tanpa_supplier': 'Pembelian tanpa supplier',
  'no_pembelian_bentrok': 'Nomor pembelian bentrok',
  'saldo_awal_stok_berubah': 'Stok berubah setelah saldo awal',
};

String _reasonLabel(String reason) {
  if (reason.startsWith('peran_tidak_berhak')) {
    return 'Peran pengirim tidak berhak';
  }
  return _reasonLabels[reason] ?? reason;
}

const _detailLabels = {
  'no_nota': 'No. nota',
  'employee_nama': 'Karyawan',
  'cycle_start': 'Awal siklus',
  'cycle_end': 'Akhir siklus',
  'tanggal': 'Tanggal',
  'nominal_masuk': 'Nominal masuk',
  'nominal_tersimpan': 'Nominal tersimpan',
  'kas_keluar': 'Kas keluar',
  'potongan_hutang': 'Potongan hutang',
  'total_efektif': 'Total efektif',
  'total_dibayar': 'Total dibayar',
  'kelebihan': 'Kelebihan bayar',
  'retur_aktif': 'Retur aktif',
  'void_refund': 'Refund void',
  'stok_sebelum_milli': 'Stok sebelum (×1000)',
  'stok_sesudah_milli': 'Stok sesudah (×1000)',
  'terjual_milli': 'Terjual (×1000)',
  'sudah_retur_milli': 'Sudah diretur (×1000)',
  'retur_masuk_milli': 'Retur masuk (×1000)',
  'harga_modal': 'Harga modal',
  'harga_jual': 'Harga jual',
  'kode_asal': 'Kode asal',
  'kode_baru': 'Kode baru',
  'sender_device_id': 'Perangkat pengirim',
  'sender_account': 'Akun pengirim',
  'sender_kind': 'Jenis pengirim',
  'pemenang': 'Pemenang',
  'butuh_bantuan_owner': 'Butuh bantuan owner',
  'kompensasi_status': 'Status kompensasi',
  'kompensasi_error': 'Kesalahan kompensasi',
  'return_sync_ids': 'Retur yang dikompensasi',
  'void_hlc': 'HLC void',
};

bool _isMoneyKey(String key) =>
    key == 'nominal' ||
    key == 'kas_keluar' ||
    key == 'kelebihan' ||
    key == 'potongan_hutang' ||
    key == 'void_refund' ||
    key.startsWith('nominal_') ||
    key.startsWith('total_') ||
    key.startsWith('harga_');

String _detailLabel(String key) => _detailLabels[key] ?? key;

String _detailValue(String key, Object? value) {
  if (value == null) return '-';
  if (value is bool) return value ? 'Ya' : 'Tidak';
  if (value is num && _isMoneyKey(key)) return formatRupiah(value.toInt());
  if (value is List || value is Map) {
    return const JsonEncoder.withIndent(' ').convert(value);
  }
  return '$value';
}


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

  Future<void> _ignore(
    Map<String, Object?> row, {
    String resolution = 'abaikan',
  }) async {
    final ownerHelp = resolution == 'bantuan_owner';
    final ok = await confirmAction(
      context,
      title: ownerHelp ? 'Selesaikan sebagai owner' : 'Abaikan konflik',
      message: ownerHelp
          ? 'Perubahan ini ditandai selesai atas bantuan owner dan dicatat '
              'di audit. Dokumen bisnis yang sudah ada tidak diubah.'
          : 'Perubahan ini tidak akan diterapkan di perangkat ini dan akan '
              'ditandai selesai. Konflik tetap tercatat dan tidak dihapus.',
      confirmLabel: ownerHelp ? 'Selesaikan' : 'Abaikan',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await SyncService.instance.ignoreConflict(
        row['id'] as int,
        resolution: resolution,
      );
      await _load();
      if (mounted) {
        showSnack(
          context,
          ownerHelp
              ? 'Konflik diselesaikan sebagai bantuan owner.'
              : 'Konflik ditandai diabaikan.',
        );
      }
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
    final retryCount = (row['retry_count'] as num?)?.toInt() ?? 0;
    final deadLetter = !resolved &&
        (retryCount >= SyncConflictRules.maxRetries ||
            SyncConflictRules.permanentReasons.contains(reason));
    final ownerHelpDue = !resolved &&
        SyncConflictRules.ownerHelpReasons.contains(reason) &&
        created != null &&
        DateTime.now().difference(created.toLocal()) >=
            SyncConflictRules.ownerHelpAfter;
    final kompensasi = '${detail?['kompensasi_status'] ?? ''}';
    final needsOwner = detail?['butuh_bantuan_owner'] == true ||
        kompensasi == 'gagal' ||
        ownerHelpDue;
    final suggestion = needsOwner || deadLetter
        ? _suggestion(reason, deadLetter: deadLetter)
        : '';
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: _reasonLabel(reason),
      subtitle: '${row['entity'] ?? ''} ${row['entity_id'] ?? ''} · '
          '${_statusLabel(row)}'
          '${needsOwner ? ' · Perlu bantuan owner' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (created != null)
            _line('Waktu', _dateFormat.format(created.toLocal())),
          if (retryCount > 0) _line('Percobaan', '$retryCount'),
          if (kompensasi.isNotEmpty)
            _line('Kompensasi', _kompensasiLabel(kompensasi)),
          if (('${row['last_error'] ?? ''}').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${row['last_error']}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (suggestion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                suggestion,
                style: TextStyle(fontSize: 12, color: scheme.primary),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in detail.entries)
                        _line(
                          _detailLabel(entry.key),
                          _detailValue(entry.key, entry.value),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          if (!resolved)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canRetry)
                  FilledButton.tonal(
                    onPressed: _busy ? null : () => _retry(row),
                    child: const Text('Coba lagi'),
                  ),
                if (needsOwner)
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _ignore(row, resolution: 'bantuan_owner'),
                    child: const Text('Selesaikan (owner)'),
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

  String _suggestion(String reason, {required bool deadLetter}) {
    final text = SyncConflictRules.suggestionForReason(reason);
    if (text.isNotEmpty) return text;
    if (!deadLetter) return '';
    return 'Amplop ini tidak dapat dipulihkan. Minta perangkat pengirim '
        'mengirim ulang dokumennya, lalu sinkronkan ulang.';
  }

  String _kompensasiLabel(String status) => switch (status) {
        'selesai' => 'Selesai',
        'gagal' => 'Gagal — perlu bantuan owner',
        'pending' => 'Menunggu perangkat asal',
        _ => status,
      };

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
