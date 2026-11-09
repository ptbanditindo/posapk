import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/app_database.dart';
import '../../data/pajak.dart';
import '../../data/pajak_payment_service.dart';
import '../../data/pajak_report_service.dart';
import '../../printer/printer_config.dart';
import '../../printer/printer_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';

class PajakScreen extends StatefulWidget {
  const PajakScreen({super.key});

  @override
  State<PajakScreen> createState() => _PajakScreenState();
}

class _PajakScreenState extends State<PajakScreen> {
  String _masa = PajakReportService.masaOf(DateTime.now());
  PajakRekap? _rekap;
  List<Map<String, Object?>> _payments = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rekap = await PajakReportService.instance.rekap(_masa);
      final payments = await PajakReportService.instance.listPayments(_masa);
      if (!mounted) return;
      setState(() {
        _rekap = rekap;
        _payments = payments;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _shiftMonth(int delta) {
    final start = PajakReportService.startOfMasa(_masa);
    final next = DateTime(start.year, start.month + delta, 1);
    setState(() => _masa = PajakReportService.masaOf(next));
    _load();
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: PajakReportService.startOfMasa(_masa),
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      helpText: 'Pilih bulan',
    );
    if (picked == null || !mounted) return;
    setState(() => _masa = PajakReportService.masaOf(picked));
    await _load();
  }

  Future<void> _export() async {
    final rekap = _rekap;
    if (rekap == null) return;
    setState(() => _busy = true);
    try {
      final path = await PajakReportService.instance.exportCsv(rekap);
      if (mounted) showSnack(context, 'Rekap disimpan: $path');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Ekspor gagal: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final rekap = _rekap;
    if (rekap == null) return;
    await Clipboard.setData(
      ClipboardData(text: PajakReportService.instance.rekapCsv(rekap)),
    );
    if (mounted) showSnack(context, 'Rekap disalin ke clipboard.');
  }

  Future<void> _print() async {
    final rekap = _rekap;
    if (rekap == null) return;
    final printer = await PrinterStore.instance.primary();
    if (!mounted) return;
    if (printer == null) {
      showSnack(
        context,
        'Belum ada printer. Tambahkan printer di Pengaturan.',
        error: true,
      );
      return;
    }
    final store =
        await AppDatabase.instance.getSetting('bengkel.nama') ??
        'PUSATKU POS';
    final divider = List.filled(printer.width, '-').join();
    final lines = <String>[
      store,
      'REKAP PPN ${PajakReportService.masaLabel(rekap.masa)}',
      'Rekap internal - bukan e-Faktur resmi',
      divider,
      'PPN keluaran: ${formatRupiah(rekap.pajakKeluaranCents)}',
      'DPP keluaran: ${formatRupiah(rekap.dppKeluaranCents)}',
      if (rekap.returPajakCents > 0)
        'Retur PPN: ${formatRupiah(rekap.returPajakCents)}',
      'PPN masukan: ${formatRupiah(rekap.pajakMasukanNetoCents)}',
      'PPN diserap: ${formatRupiah(rekap.diserapNetoCents)}',
      divider,
      'PPN neto: ${formatRupiah(rekap.pajakNetoCents)}',
      'Sudah dibayar: ${formatRupiah(rekap.pajakDibayarCents)}',
      'Sisa kewajiban: ${formatRupiah(rekap.sisaKewajibanCents)}',
      divider,
      for (final row in rekap.rincian)
        '${row.mode} ${formatPersenBp(row.persenBp)} '
            '${row.penanggung}: ${formatRupiah(row.pajakNetoCents)}',
      if (rekap.rincian.isNotEmpty) divider,
      for (final row in _payments.where((row) => row['status'] == 'AKTIF'))
        'Bayar ${dateId.format(localTime(row['dibayar_at']))}: '
            '${formatRupiah((row['nominal'] as num?)?.toInt() ?? 0)}',
      '',
    ];
    final result = await PrinterService.instance.printText(
      lines.join('\n'),
      printer: printer,
    );
    if (mounted) showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _recordPayment() async {
    final rekap = _rekap;
    if (rekap == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _PaymentDialog(masa: _masa, sisa: rekap.sisaKewajibanCents),
    );
    if (result == true) {
      await _load();
      if (mounted) showSnack(context, 'Pembayaran PPN dicatat.');
    }
  }

  Future<void> _voidPayment(Map<String, Object?> row) async {
    final reason = await _askReason(
      'Batalkan pembayaran PPN',
      'Alasan pembatalan',
    );
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      await PajakPaymentService.instance.voidPayment(
        paymentId: row['id'] as int,
        alasan: reason,
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePajakPayment(id, txn: txn),
      );
      await _load();
      if (mounted) showSnack(context, 'Pembayaran PPN dibatalkan.');
    } catch (error) {
      if (mounted) showSnack(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askReason(String title, String label) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(context, text);
            },
            child: const Text('Lanjut'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (!AppState.instance.isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('PPN')),
        body: const EmptyState(
          title: 'Hanya pemilik',
          subtitle: 'Rekap dan pembayaran PPN hanya dapat dibuka oleh pemilik.',
          icon: Icons.lock_outline,
        ),
      );
    }
    final rekap = _rekap;
    return Scaffold(
      appBar: AppBar(title: const Text('PPN')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Rekap PPN bulanan',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Rekap internal untuk pembukuan. Bukan e-Faktur resmi.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                onPressed: () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Bulan sebelumnya',
              ),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickMonth,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(PajakReportService.masaLabel(_masa)),
                ),
              ),
              IconButton(
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Bulan berikutnya',
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            EmptyState(
              title: 'Rekap gagal dimuat',
              subtitle: _error,
              icon: Icons.error_outline,
            )
          else if (rekap == null)
            const EmptyState(title: 'Rekap tidak tersedia')
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 760
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: width,
                      child: StatCard(
                        label: 'PPN keluaran',
                        value: formatRupiah(rekap.pajakKeluaranCents),
                        icon: Icons.south_west_outlined,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: StatCard(
                        label: 'PPN masukan',
                        value: formatRupiah(rekap.pajakMasukanNetoCents),
                        icon: Icons.north_east_outlined,
                        tone: Colors.teal,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: StatCard(
                        label: 'PPN neto',
                        value: formatRupiah(rekap.pajakNetoCents),
                        icon: Icons.account_balance_outlined,
                        tone: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: StatCard(
                        label: 'PPN diserap bengkel',
                        value: formatRupiah(rekap.diserapNetoCents),
                        icon: Icons.volunteer_activism_outlined,
                        tone: Colors.orange,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Rincian masa ${PajakReportService.masaLabel(_masa)}',
              subtitle:
                  '${rekap.jumlahNota} nota · ${rekap.jumlahRetur} retur · '
                  '${rekap.jumlahPembelian} pembelian',
              child: Column(
                children: [
                  _line('DPP keluaran', formatRupiah(rekap.dppKeluaranCents)),
                  _line('PPN keluaran', formatRupiah(rekap.pajakKeluaranCents)),
                  if (rekap.returPajakCents > 0) ...[
                    _line('Retur DPP', '-${formatRupiah(rekap.returDppCents)}'),
                    _line(
                      'Retur PPN keluaran',
                      '-${formatRupiah(rekap.returPajakCents)}',
                    ),
                  ],
                  const Divider(),
                  _line(
                    'PPN masukan pembelian',
                    formatRupiah(rekap.pajakMasukanCents),
                  ),
                  if (rekap.returMasukanCents > 0)
                    _line(
                      'Retur PPN masukan',
                      '-${formatRupiah(rekap.returMasukanCents)}',
                    ),
                  const Divider(),
                  _line(
                    'PPN neto',
                    formatRupiah(rekap.pajakNetoCents),
                    bold: true,
                  ),
                  _line(
                    'Sudah dibayar',
                    formatRupiah(rekap.pajakDibayarCents),
                  ),
                  _line(
                    'Sisa kewajiban',
                    formatRupiah(rekap.sisaKewajibanCents),
                    bold: true,
                  ),
                  if (rekap.sisaKewajibanCents < 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Pembayaran melebihi kewajiban masa ini. Periksa '
                        'kembali data retur/pembelian sebelum masa ditutup.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Rincian mode, tarif, dan penanggung',
              subtitle:
                  'Memakai snapshot yang tersimpan pada tiap nota, bukan '
                  'pengaturan saat ini.',
              child: rekap.rincian.isEmpty
                  ? const Text('Tidak ada nota ber-PPN pada masa ini.')
                  : Column(
                      children: [
                        for (final row in rekap.rincian)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(row.label),
                            subtitle: Text(
                              '${row.jumlahNota} nota · DPP '
                              '${formatRupiah(row.dppNetoCents)}'
                              '${row.diserapCents == 0 ? '' : ' · diserap '
                                        '${formatRupiah(row.diserapCents)}'}',
                            ),
                            trailing: Text(
                              formatRupiah(row.pajakNetoCents),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Pembayaran PPN',
              subtitle: 'Kas/transfer beserta referensi pembayaran.',
              trailing: FilledButton.icon(
                onPressed: _busy || rekap.sisaKewajibanCents <= 0
                    ? null
                    : _recordPayment,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Catat'),
              ),
              child: _payments.isEmpty
                  ? const Text('Belum ada pembayaran PPN pada masa ini.')
                  : Column(
                      children: [
                        for (final row in _payments)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              '${formatRupiah((row['nominal'] as num?)?.toInt() ?? 0)}'
                              ' · ${row['metode'] == 'TRANSFER' ? 'Transfer' : 'Kas'}',
                            ),
                            subtitle: Text(
                              '${dateId.format(localTime(row['dibayar_at']))}'
                              '${_referensi(row)}'
                              '${row['status'] == 'VOID' ? ' · DIBATALKAN' : ''}',
                            ),
                            trailing: row['status'] == 'VOID'
                                ? Text(
                                    'VOID',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _voidPayment(row),
                                    child: const Text('Batalkan'),
                                  ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Ekspor CSV'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _copy,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Salin rekap'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _print,
              icon: const Icon(Icons.print_outlined),
              label: const Text('Cetak / simpan PDF'),
            ),
          ],
        ],
      ),
    );
  }

  String _referensi(Map<String, Object?> row) {
    final referensi = '${row['referensi'] ?? ''}'.trim();
    final catatan = '${row['catatan'] ?? ''}'.trim();
    final parts = [
      if (referensi.isNotEmpty) 'Ref: $referensi',
      if (catatan.isNotEmpty) catatan,
    ];
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }

  Widget _line(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
        ],
      ),
    );
  }
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.masa, required this.sisa});

  final String masa;
  final int sisa;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late final TextEditingController _nominal;
  final _referensi = TextEditingController();
  final _catatan = TextEditingController();
  String _metode = 'CASH';
  DateTime _dibayarAt = DateTime.now();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nominal = TextEditingController(text: formatRupiahPlain(widget.sisa));
  }

  @override
  void dispose() {
    _nominal.dispose();
    _referensi.dispose();
    _catatan.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dibayarAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _dibayarAt = picked);
  }

  Future<void> _submit() async {
    final nominal = tryParseRupiahToCents(_nominal.text);
    if (nominal == null || nominal <= 0) {
      setState(() => _error = 'Nominal pembayaran tidak valid.');
      return;
    }
    if (nominal > widget.sisa) {
      setState(
        () => _error = 'Nominal melebihi sisa kewajiban '
            '${formatRupiah(widget.sisa)}.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PajakPaymentService.instance.createPayment(
        input: PajakPaymentInput(
          masa: widget.masa,
          nominalCents: nominal,
          metode: _metode,
          referensi: _referensi.text,
          catatan: _catatan.text,
          dibayarAt: _dibayarAt,
        ),
        actor: AppState.instance.requireOperator,
        enqueue: (txn, id) =>
            SyncService.instance.enqueuePajakPayment(id, txn: txn),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Catat pembayaran PPN ${PajakReportService.masaLabel(widget.masa)}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sisa kewajiban ${formatRupiah(widget.sisa)}. Pembayaran tidak '
                'boleh melebihi nilai ini.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nominal,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Nominal (Rp)',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _metode,
                decoration: const InputDecoration(labelText: 'Metode'),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Kas')),
                  DropdownMenuItem(value: 'TRANSFER', child: Text('Transfer')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _metode = value);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _referensi,
                decoration: const InputDecoration(
                  labelText: 'Referensi',
                  helperText: 'Nomor bukti setor atau transaksi bank.',
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Tanggal bayar',
                    suffixIcon: Icon(Icons.event_outlined),
                  ),
                  child: Text(dateId.format(_dibayarAt)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _catatan,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Catatan'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Menyimpan...' : 'Simpan'),
        ),
      ],
    );
  }
}
