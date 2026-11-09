import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/feature_flags.dart';
import '../../data/followup_service.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

class FollowupScreen extends StatefulWidget {
  const FollowupScreen({super.key, this.onOpenPremium});

  final VoidCallback? onOpenPremium;

  @override
  State<FollowupScreen> createState() => _FollowupScreenState();
}

class _FollowupScreenState extends State<FollowupScreen> {
  String _filter = 'semua';
  String? _jenis;
  FollowupSettings _settings = const FollowupSettings();
  FollowupQuota? _quota;
  List<FollowupRow> _aktif = const [];
  List<FollowupRow> _arsip = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool sync = false}) async {
    if (sync) setState(() => _loading = true);
    try {
      if (sync) await FollowupService.instance.syncItems();
      final settings = await FollowupService.instance.loadSettings();
      final quota = await FollowupService.instance.quotaStatus();
      final aktif = await FollowupService.instance.listItems(jenis: _jenis);
      final arsip = await FollowupService.instance
          .listItems(filter: 'arsip', jenis: _jenis);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _quota = quota;
        _aktif = aktif;
        _arsip = arsip;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, 'Gagal memuat follow up: $error', error: true);
    }
  }

  DateTime get _today => startOfDay(DateTime.now());

  List<FollowupRow> get _visible {
    switch (_filter) {
      case 'hari_ini':
        return _aktif
            .where((row) => startOfDay(row.jatuhTempo) == _today)
            .toList();
      case 'terlambat':
        return _aktif.where((row) => row.terlambat).toList();
      case 'arsip':
        return _arsip;
      default:
        return _aktif;
    }
  }

  int get _hariIni =>
      _aktif.where((row) => startOfDay(row.jatuhTempo) == _today).length;
  int get _terlambat => _aktif.where((row) => row.terlambat).length;

  Future<void> _remind(FollowupRow row) async {
    if (!FeatureFlagsService.instance.isEnabled(featureWhatsapp)) {
      showSnack(
        context,
        'Fitur WhatsApp dinonaktifkan pemilik.',
        error: true,
      );
      return;
    }
    final quota = _quota;
    if (quota != null && quota.locked) {
      await _quotaHabis();
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Ingatkan lewat WhatsApp',
      message:
          'Buka pesan untuk ${row.customerNama} (${row.nomorMasked})?\n\n'
          'Satu kredit kuota WhatsApp akan terpakai saat tautan dibuat.',
      confirmLabel: 'Buat pesan',
    );
    if (!ok) return;
    try {
      final attempt = await FollowupService.instance.followUp(
        row.id,
        actor: AppState.instance.requireOperator,
      );
      if (!mounted) return;
      setState(() => _quota = attempt.quota);
      await _showMessage(attempt);
      await _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '$error', error: true);
    }
  }

  Future<void> _quotaHabis() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kuota follow up habis'),
        content: const Text(
          'Kuota gratis 20 kredit WhatsApp sudah terpakai. Data lama tetap '
          'dapat dibaca dan diekspor. Aktifkan Premium untuk follow up tanpa '
          'batas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
          if (widget.onOpenPremium != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onOpenPremium!();
              },
              child: const Text('Lihat Premium'),
            ),
        ],
      ),
    );
  }

  Future<void> _showMessage(FollowupAttempt attempt) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pesan untuk ${attempt.nomorMasked}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(attempt.message),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: attempt.message));
              if (context.mounted) Navigator.pop(context, 'copy');
            },
            child: const Text('Salin pesan'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
          if (FeatureFlagsService.instance.isEnabled(featureWhatsapp))
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'open'),
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Buka WhatsApp'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      showSnack(context, 'Pesan disalin. Tempel di WhatsApp.');
      return;
    }
    if (action == 'open') {
      final opened = await _openWhatsApp(attempt.link);
      if (!mounted) return;
      if (opened) {
        showSnack(context, 'WhatsApp dibuka.');
      } else {
        await Clipboard.setData(ClipboardData(text: attempt.link));
        if (!mounted) return;
        showSnack(context, 'WhatsApp tidak terbuka. Tautan disalin.');
      }
    }
  }

  Future<bool> _openWhatsApp(String link) async {
    try {
      return await launchUrl(
        Uri.parse(link),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  List<String> _statusOptions(FollowupRow row) {
    if (row.status == 'ARSIP') return const [];
    switch (row.jenis) {
      case 'piutang':
        return const ['JANJI_BAYAR', 'MASIH_KENDALA', 'SUDAH_BAYAR'];
      case 'servis_berkala':
      case 'garansi':
        return const [
          'AKAN_DATANG',
          'MASIH_KENDALA',
          'TIDAK_DATANG',
          'SELESAI',
          'ARSIP',
        ];
      default:
        return const ['AKAN_DATANG', 'MASIH_KENDALA', 'SELESAI', 'ARSIP'];
    }
  }

  Future<void> _changeStatus(FollowupRow row, String status) async {
    String? alasan;
    DateTime? tanggal;
    if (status == 'ARSIP') {
      alasan = await _askText(
        title: 'Arsipkan pengingat',
        label: 'Alasan arsip',
      );
      if (alasan == null || alasan.trim().isEmpty) return;
      if (!mounted) return;
    }
    if (status == 'AKAN_DATANG') {
      tanggal = await showDatePicker(
        context: context,
        initialDate: DateTime.now().add(const Duration(days: 1)),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        helpText: 'Tanggal kedatangan',
      );
      if (tanggal == null) return;
      if (!mounted) return;
    }
    if (status == 'JANJI_BAYAR') {
      tanggal = await showDatePicker(
        context: context,
        initialDate: DateTime.now().add(const Duration(days: 1)),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        helpText: 'Tanggal janji bayar',
      );
      if (tanggal == null) return;
    }
    try {
      await FollowupService.instance.changeStatus(
        row.id,
        status: status,
        actor: AppState.instance.requireOperator,
        alasan: alasan,
        janjiBayar: status == 'JANJI_BAYAR' ? tanggal : null,
        tanggalService: status == 'AKAN_DATANG' ? tanggal : null,
      );
      await _load();
      if (!mounted) return;
      showSnack(
        context,
        'Status diubah: ${followupStatusLabels[status] ?? status}.',
      );
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '$error', error: true);
    }
  }

  Future<String?> _askText({
    required String title,
    required String label,
  }) async {
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
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _showDetail(FollowupRow row) async {
    final events = await FollowupService.instance.events(row.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Detail follow up'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detailLine('Pelanggan', row.customerNama),
                _detailLine('Nomor', row.nomorMasked),
                _detailLine('Jenis', row.jenisLabel),
                _detailLine('Status', row.statusLabel),
                _detailLine('Unit', row.unitLabel),
                if (row.noNota != null) _detailLine('Nota', row.noNota!),
                _detailLine('Jatuh tempo', _fmtDate(row.jatuhTempo)),
                if (row.sisaBayar > 0)
                  _detailLine('Sisa bayar', formatRupiah(row.sisaBayar)),
                if (row.janjiBayar != null)
                  _detailLine('Janji bayar', _fmtDate(row.janjiBayar!)),
                if (row.tanggalService != null)
                  _detailLine('Tanggal service', _fmtDate(row.tanggalService!)),
                if (row.followupTerakhir != null)
                  _detailLine(
                    'Follow up terakhir',
                    _fmtDateTime(row.followupTerakhir!),
                  ),
                if (row.alasanArsip != null)
                  _detailLine('Alasan arsip', row.alasanArsip!),
                if (row.alasanArsip == null && row.bisaAlasan.isNotEmpty)
                  _detailLine('Catatan', row.bisaAlasan),
                const Divider(height: 24),
                Text(
                  'Riwayat',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                if (events.isEmpty)
                  const Text('Belum ada riwayat.')
                else
                  ...events.reversed.map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_fmtDateTime(localTime(event['created_at']))}'
                            ' · ${followupStatusLabels['${event['status']}'] ?? event['status']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if ('${event['catatan'] ?? ''}'.isNotEmpty)
                            Text(
                              '${event['catatan']}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
  static String _fmtDate(DateTime value) =>
      '${_two(value.day)}/${_two(value.month)}/${value.year}';
  static String _fmtDateTime(DateTime value) =>
      '${_fmtDate(value)} ${_two(value.hour)}:${_two(value.minute)}';

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final rows = _visible;
    return RefreshIndicator(
      onRefresh: () => _load(sync: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(),
          const SizedBox(height: 12),
          if (!_settings.aktif)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SectionCard(
                child: Row(
                  children: [
                    Icon(
                      Icons.pause_circle_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Fitur follow up sedang dimatikan. Aktifkan melalui '
                        'Pengaturan › Follow up.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _filters(),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            EmptyState(
              icon: Icons.notifications_none,
              title: _filter == 'arsip'
                  ? 'Belum ada pengingat diarsipkan'
                  : 'Belum ada pengingat',
              subtitle: _filter == 'arsip'
                  ? 'Pengingat yang selesai atau tidak aktif akan tampil di sini.'
                  : 'Pengingat dibuat otomatis dari servis, garansi, piutang, '
                      'dan prospek pelanggan.',
              action: OutlinedButton.icon(
                onPressed: () => _load(sync: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Sinkronkan'),
              ),
            )
          else
            ...rows.map(_card),
        ],
      ),
    );
  }

  Widget _header() {
    final quota = _quota;
    final theme = Theme.of(context);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.notifications_active_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Follow up pelanggan',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      quota == null ? 'Memuat kuota…' : quota.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: quota?.locked == true
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Sinkronkan pengingat',
                onPressed: () => _load(sync: true),
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          if (quota != null && quota.locked) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: widget.onOpenPremium,
                icon: const Icon(Icons.workspace_premium_outlined),
                label: const Text('Aktifkan Premium'),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _stat('Hari ini', _hariIni, theme.colorScheme.primary),
              const SizedBox(width: 8),
              _stat('Terlambat', _terlambat, theme.colorScheme.error),
              const SizedBox(width: 8),
              _stat('Arsip', _arsip.length, theme.colorScheme.outline),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _filters() {
    const filters = {
      'semua': 'Semua',
      'hari_ini': 'Hari ini',
      'terlambat': 'Terlambat',
      'arsip': 'Arsip',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in filters.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _filter == entry.key,
                    onSelected: (_) => setState(() => _filter = entry.key),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: _jenis,
          decoration: const InputDecoration(
            labelText: 'Jenis pengingat',
            isDense: true,
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Semua jenis'),
            ),
            for (final jenis in followupJenis)
              DropdownMenuItem<String?>(
                value: jenis,
                child: Text(followupJenisLabels[jenis] ?? jenis),
              ),
          ],
          onChanged: (value) {
            setState(() => _jenis = value);
            _load();
          },
        ),
      ],
    );
  }

  Widget _card(FollowupRow row) {
    final theme = Theme.of(context);
    final color = row.terlambat
        ? theme.colorScheme.error
        : row.sisaHari == 0
            ? theme.colorScheme.primary
            : theme.colorScheme.outline;
    final options = _statusOptions(row);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SectionCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(_jenisIcon(row.jenis), size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.customerNama.isEmpty
                            ? 'Pelanggan'
                            : row.customerNama,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${row.jenisLabel} · ${row.judul}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    row.statusLabel,
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _dueText(row),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  row.nomorMasked,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            if (row.sisaBayar > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Sisa bayar ${formatRupiah(row.sisaBayar)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (row.jenis == 'prospek' && row.stage > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Tahap ${row.stage}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (!row.bisaFollowup && row.status != 'ARSIP' &&
                !closedFollowupStatuses.contains(row.status)) ...[
              const SizedBox(height: 6),
              Text(
                row.bisaAlasan,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (row.status != 'ARSIP' &&
                    AppState.instance.can('followup')) ...[
                  FilledButton.tonalIcon(
                    onPressed:
                        row.bisaFollowup ? () => _remind(row) : null,
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('WA'),
                  ),
                  const SizedBox(width: 8),
                ],
                TextButton.icon(
                  onPressed: () => _showDetail(row),
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Detail'),
                ),
                const Spacer(),
                if (options.isNotEmpty &&
                    AppState.instance.can('followup'))
                  PopupMenuButton<String>(
                    tooltip: 'Ubah status',
                    onSelected: (value) => _changeStatus(row, value),
                    itemBuilder: (context) => [
                      for (final status in options)
                        PopupMenuItem(
                          value: status,
                          child: Text(
                            followupStatusLabels[status] ?? status,
                          ),
                        ),
                    ],
                    child: const Chip(
                      avatar: Icon(Icons.flag_outlined, size: 16),
                      label: Text('Status'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _jenisIcon(String jenis) {
    switch (jenis) {
      case 'garansi':
        return Icons.verified_outlined;
      case 'servis_berkala':
        return Icons.build_outlined;
      case 'piutang':
        return Icons.payments_outlined;
      case 'unit_selesai':
        return Icons.two_wheeler_outlined;
      default:
        return Icons.person_search_outlined;
    }
  }

  String _dueText(FollowupRow row) {
    if (row.status == 'ARSIP') {
      return 'Diarsipkan ${_fmtDate(row.jatuhTempo)}';
    }
    if (row.status == 'AKAN_DATANG' && row.tanggalService != null) {
      return 'Service ${_fmtDate(row.tanggalService!)}';
    }
    if (row.janjiBayar != null && row.status == 'JANJI_BAYAR') {
      return 'Janji bayar ${_fmtDate(row.janjiBayar!)}';
    }
    if (row.sisaHari == 0) return 'Jatuh tempo hari ini';
    if (row.sisaHari > 0) {
      return 'Jatuh tempo dalam ${row.sisaHari} hari '
          '(${_fmtDate(row.jatuhTempo)})';
    }
    return 'Terlambat ${-row.sisaHari} hari '
        '(${_fmtDate(row.jatuhTempo)})';
  }
}
