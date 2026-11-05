import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../data/app_database.dart';
import '../../data/employee_service.dart';
import '../../data/models.dart';
import '../../data/order_service.dart';
import '../../data/store_settings.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../widgets.dart';
import 'estimates_screen.dart';

const _statusLabels = <String, String>{
  'dibuka': 'Dibuka',
  'antri': 'Antri',
  'diagnosa': 'Diagnosa',
  'menunggu_persetujuan': 'Menunggu persetujuan',
  'menunggu_sparepart': 'Menunggu sparepart',
  'dikerjakan': 'Dikerjakan',
  'selesai': 'Selesai',
  'diambil': 'Diambil',
  'batal': 'Batal',
};

String _statusLabel(String status) => _statusLabels[status] ?? status;

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'dikerjakan' => scheme.primary,
    'selesai' => Colors.green.shade700,
    'diambil' => scheme.outline,
    'batal' => scheme.error,
    'antri' => scheme.tertiary,
    'diagnosa' ||
    'menunggu_persetujuan' ||
    'menunggu_sparepart' =>
      Colors.orange.shade700,
    _ => scheme.secondary,
  };
}

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  Future<_OrdersData>? _future;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      _future = _loadData();
    });
  }

  Future<_OrdersData> _loadData() async {
    final settings = await StoreSettingsService.instance.ensure();
    final rows = await OrderService.instance.listWorkOrderRows();
    final customers = await AppDatabase.instance.listCustomers();
    final employees = await EmployeeService.instance.listEmployees();
    return _OrdersData(
      settings: settings,
      rows: rows,
      customers: customers,
      employees: employees.where((row) => row['aktif'] == 1).toList(),
    );
  }

  Future<void> _create(_OrdersData data) async {
    final draft = await showDialog<_OrderDraft>(
      context: context,
      builder: (_) => _OrderDialog(
        settings: data.settings,
        customers: data.customers,
        employees: data.employees,
      ),
    );
    if (draft == null) return;
    try {
      final order = await OrderService.instance.createWorkOrder(
        customerId: draft.customerId,
        unitId: draft.unitId,
        keluhan: draft.keluhan,
        mekanikSyncId: draft.mekanikSyncId,
        mekanikNama: draft.mekanikNama,
        actor: AppState.instance.operator,
        enqueue: (txn, syncId) =>
            SyncService.instance.enqueueWorkOrder(syncId, txn: txn),
        enqueueStatus: (txn, syncId) =>
            SyncService.instance.enqueueWorkOrderStatus(syncId, txn: txn),
      );
      if (!mounted) return;
      final label = order.nomorOrder ??
          (order.nomorAntrian == null ? 'baru' : '#${order.nomorAntrian}');
      showSnack(context, 'Order $label dibuat.');
      AppState.instance.touch();
      _load();
    } catch (error) {
      if (mounted) showSnack(context, '$error', error: true);
    }
  }

  void _openDetail(_OrdersData data, Map<String, Object?> row) {
    showDialog<void>(
      context: context,
      builder: (_) => _OrderDetailDialog(
        order: WorkOrderRecord.fromRow(row),
        settings: data.settings,
        customerName: row['customer_nama'] as String?,
        unitLabel: _unitLabel(row),
        onChanged: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_OrdersData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data;
        if (data == null) {
          return const EmptyState(
            title: 'Order belum dapat dimuat',
            subtitle: 'Coba buka kembali halaman ini.',
            icon: Icons.assignment_outlined,
          );
        }
        final settings = data.settings;
        final typeOn = settings.typeEnabled(transactionOrderKerja);
        final role = AppState.instance.operator?.role ?? 'owner';
        final canCreate = typeOn && settings.roleAllows(role, 'buat_nota');
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Order kerja',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Antrian hari ini dan riwayat status.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EstimatesScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.request_quote_outlined),
                    label: const Text('Estimasi'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: canCreate ? () => _create(data) : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Order baru'),
                  ),
                ],
              ),
            ),
            if (!typeOn)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SectionCard(
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Order kerja sedang dimatikan pemilik. '
                          'Aktifkan di Pengaturan → Aturan transaksi.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: data.rows.isEmpty
                  ? EmptyState(
                      title: 'Belum ada order aktif',
                      subtitle:
                          'Buka order baru saat kendaraan masuk untuk '
                          'mendapat nomor antrian.',
                      icon: Icons.assignment_outlined,
                      action: canCreate
                          ? FilledButton(
                              onPressed: () => _create(data),
                              child: const Text('Order baru'),
                            )
                          : null,
                    )
                  : RefreshIndicator(
                      onRefresh: () async => _load(),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: data.rows.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final row = data.rows[index];
                          return _OrderCard(
                            row: row,
                            onTap: () => _openDetail(data, row),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _OrdersData {
  const _OrdersData({
    required this.settings,
    required this.rows,
    required this.customers,
    required this.employees,
  });

  final StoreSettings settings;
  final List<Map<String, Object?>> rows;
  final List<Customer> customers;
  final List<Map<String, Object?>> employees;
}

String _unitLabel(Map<String, Object?> row) {
  final parts = [row['nopol'], row['merek'], row['tipe']]
      .map((value) => '${value ?? ''}'.trim())
      .where((value) => value.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '${row['unit_type'] ?? 'Unit'}';
  return parts.join(' · ');
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.row, required this.onTap});

  final Map<String, Object?> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = row['status'] as String? ?? 'antri';
    final queue = row['nomor_antrian'] as String?;
    final nomor = row['nomor_order'] as String?;
    final customer = row['customer_nama'] as String?;
    final unit = _unitLabel(row);
    final mekanik = row['mekanik_nama'] as String?;
    final waktu = dateTimeId.format(localTime(row['waktu_masuk']));
    final statusColor = _statusColor(context, status);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  queue == null ? '—' : '#$queue',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            nomor ?? 'Tanpa nomor',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _statusLabel(status),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${customer ?? 'Tanpa pelanggan'} · $unit',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${row['keluhan'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [waktu, ?mekanik].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderDraft {
  const _OrderDraft({
    required this.customerId,
    this.unitId,
    required this.keluhan,
    this.mekanikSyncId,
    this.mekanikNama,
  });

  final int customerId;
  final int? unitId;
  final String keluhan;
  final String? mekanikSyncId;
  final String? mekanikNama;
}

class _OrderDialog extends StatefulWidget {
  const _OrderDialog({
    required this.settings,
    required this.customers,
    required this.employees,
  });

  final StoreSettings settings;
  final List<Customer> customers;
  final List<Map<String, Object?>> employees;

  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  final _keluhan = TextEditingController();
  int? _customerId;
  int? _unitId;
  String? _mekanikSyncId;
  List<VehicleUnit> _units = const [];
  bool _loadingUnits = false;

  @override
  void dispose() {
    _keluhan.dispose();
    super.dispose();
  }

  Future<void> _selectCustomer(int? customerId) async {
    setState(() {
      _customerId = customerId;
      _unitId = null;
      _units = const [];
      _loadingUnits = customerId != null;
    });
    if (customerId == null) return;
    final units = await AppDatabase.instance.listUnits(customerId);
    if (!mounted || _customerId != customerId) return;
    setState(() {
      _units = units;
      _loadingUnits = false;
    });
  }

  void _submit() {
    if (_customerId == null) {
      showSnack(context, 'Pilih pelanggan terlebih dahulu.', error: true);
      return;
    }
    if (_keluhan.text.trim().isEmpty) {
      showSnack(context, 'Isi keluhan atau pekerjaan yang diminta.',
          error: true);
      return;
    }
    if (widget.settings.vehicleRequired && _unitId == null) {
      showSnack(context, 'Pilih unit kendaraan.', error: true);
      return;
    }
    Navigator.of(context).pop(
      _OrderDraft(
        customerId: _customerId!,
        unitId: _unitId,
        keluhan: _keluhan.text.trim(),
        mekanikSyncId: _mekanikSyncId,
        mekanikNama: _mekanikName(_mekanikSyncId),
      ),
    );
  }

  String? _mekanikName(String? syncId) {
    if (syncId == null) return null;
    for (final row in widget.employees) {
      if (row['sync_id'] == syncId) return '${row['nama'] ?? ''}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stages = widget.settings.stages;
    return AlertDialog(
      title: const Text('Order kerja baru'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _customerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Pelanggan'),
                items: [
                  for (final customer in widget.customers)
                    DropdownMenuItem(
                      value: customer.id,
                      child: Text(
                        '${customer.nama} · ${customer.nomorHp}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _selectCustomer,
              ),
              const SizedBox(height: 12),
              if (_loadingUnits)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                )
              else
                DropdownButtonFormField<int>(
                  initialValue: _unitId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.settings.vehicleRequired
                        ? 'Unit'
                        : 'Unit (opsional)',
                  ),
                  items: [
                    if (!widget.settings.vehicleRequired)
                      const DropdownMenuItem<int>(
                        value: null,
                        child: Text('Tanpa unit'),
                      ),
                    for (final unit in _units)
                      DropdownMenuItem(
                        value: unit.id,
                        child: Text(
                          unit.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _unitId = value),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _keluhan,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Keluhan / pekerjaan',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mekanikSyncId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Mekanik'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Tanpa mekanik')),
                  for (final employee in widget.employees)
                    DropdownMenuItem(
                      value: employee['sync_id'] as String? ?? '',
                      child: Text(
                        '${employee['nama'] ?? '-'} '
                        '(${employee['role_base'] ?? 'KARYAWAN'})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(
                  () => _mekanikSyncId =
                      value == null || value.isEmpty ? null : value,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  [
                    if (stages[stageNomorOrder] != false) 'Nomor order otomatis',
                    if (stages[stageNomorAntrian] != false) 'Nomor antrian harian',
                    if (stages[stageStatusPengerjaan] == false)
                      'Status pengerjaan dimatikan',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Buat order')),
      ],
    );
  }
}

class _OrderDetailDialog extends StatefulWidget {
  const _OrderDetailDialog({
    required this.order,
    required this.settings,
    required this.customerName,
    required this.unitLabel,
    required this.onChanged,
  });

  final WorkOrderRecord order;
  final StoreSettings settings;
  final String? customerName;
  final String unitLabel;
  final VoidCallback onChanged;

  @override
  State<_OrderDetailDialog> createState() => _OrderDetailDialogState();
}

class _OrderDetailDialogState extends State<_OrderDetailDialog> {
  late String _status = widget.order.status;
  late Future<List<WorkOrderStatusLog>> _log;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _log = OrderService.instance.statusLog(widget.order.syncId);
  }

  Map<String, Object?> get _stages {
    final raw = widget.order.modeSaatDibuat['stages'];
    if (raw is Map) return {for (final e in raw.entries) '${e.key}': e.value};
    final decoded = jsonDecode('${raw ?? '{}'}');
    return decoded is Map
        ? {for (final e in decoded.entries) '${e.key}': e.value}
        : const {};
  }

  bool get _pengerjaanOn =>
      _stages[stageStatusPengerjaan] != false &&
      widget.settings.stageEnabled(stageStatusPengerjaan);

  List<String> get _allowedStatuses =>
      _pengerjaanOn ? workOrderStatuses : workOrderStatusesMinimal;

  List<String> get _options {
    final permitted = allowedWorkOrderTransitions(_status);
    final owner = AppState.instance.isOwner;
    final base = owner ? _allowedStatuses : permitted;
    return base
        .where((status) => status != _status)
        .where(
          (status) =>
              status != 'menunggu_persetujuan' ||
              _stages[stagePersetujuanPelanggan] != false,
        )
        .toList();
  }

  Future<void> _changeStatus(String status) async {
    final permitted = allowedWorkOrderTransitions(_status).contains(status);
    final operator = AppState.instance.operator;
    if (!permitted && (operator?.isOwner ?? true)) {
      final ok = await confirmAction(
        context,
        title: 'Status di luar alur',
        message: '${_statusLabel(_status)} → ${_statusLabel(status)} '
            'bukan alur normal. Perubahan tetap disimpan dan dicatat '
            'sebagai konflik untuk ditinjau.',
        confirmLabel: 'Tetap ubah',
      );
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      await OrderService.instance.changeStatus(
        workOrderSyncId: widget.order.syncId,
        status: status,
        actor: operator,
        enqueueStatus: (txn, syncId) =>
            SyncService.instance.enqueueWorkOrderStatus(syncId, txn: txn),
        enqueueOrder: (txn, syncId) =>
            SyncService.instance.enqueueWorkOrder(syncId, txn: txn),
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        _log = OrderService.instance.statusLog(widget.order.syncId);
        AppState.instance.touch();
      });
      widget.onChanged();
      showSnack(context, 'Status order: ${_statusLabel(status)}.');
    } catch (error) {
      if (mounted) showSnack(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final role = AppState.instance.operator?.role ?? 'owner';
    final canChange = widget.settings.roleAllows(role, 'ubah_status');
    final header = order.nomorOrder ?? order.syncId;
    return AlertDialog(
      title: Text(header),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _statusColor(context, _status)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusLabel(_status),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _statusColor(context, _status),
                      ),
                    ),
                  ),
                  if (order.nomorAntrian != null) ...[
                    const SizedBox(width: 8),
                    Text('Antrian #${order.nomorAntrian}'),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              _line('Pelanggan', widget.customerName ?? 'Tanpa pelanggan'),
              _line('Unit', widget.unitLabel),
              _line('Mekanik', order.mekanikNama ?? 'Belum ditentukan'),
              _line(
                'Masuk',
                dateTimeId.format(localTime(order.waktuMasuk)),
              ),
              _line('Keluhan', order.keluhan),
              const SizedBox(height: 16),
              Text(
                'Ubah status',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (!canChange)
                Text(
                  'Peran $role tidak berhak mengubah status order.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_options.isEmpty)
                Text(
                  'Tidak ada transisi tersedia dari status ini.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final status in _options)
                      ActionChip(
                        label: Text(
                          _statusLabel(status) +
                              (allowedWorkOrderTransitions(_status)
                                      .contains(status)
                                  ? ''
                                  : ' (paksa)'),
                        ),
                        onPressed: _saving
                            ? null
                            : () => _changeStatus(status),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              Text(
                'Riwayat status',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              FutureBuilder<List<WorkOrderStatusLog>>(
                future: _log,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final rows = snapshot.data ?? const [];
                  if (rows.isEmpty) {
                    return Text(
                      'Belum ada catatan status.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  return Column(
                    children: [
                      for (final row in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: _statusColor(context, row.status),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _statusLabel(row.status) +
                                      (row.pembuat == null
                                          ? ''
                                          : ' · ${row.pembuat}'),
                                ),
                              ),
                              Text(
                                dateTimeId.format(localTime(row.waktu)),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Tutup'),
        ),
      ],
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
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
}
