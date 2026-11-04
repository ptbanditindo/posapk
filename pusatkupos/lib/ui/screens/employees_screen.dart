import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/employee_service.dart';
import '../../data/license_service.dart';
import '../widgets.dart';

class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  List<Map<String, Object?>> _employees = [];
  List<Map<String, Object?>> _debts = [];
  List<Map<String, Object?>> _salaryPayments = [];
  String? _selected;
  PayrollSummary? _summary;
  bool _loading = true;
  bool _premium = false;
  bool _busy = false;
  final _bonus = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bonus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final premium = await LicenseService.instance.isPremium();
    final employees = await EmployeeService.instance.listEmployees();
    final selected = _selected ??
        (employees.isEmpty ? null : '${employees.first['sync_id']}');
    if (!mounted) return;
    setState(() {
      _premium = premium;
      _employees = employees;
      _selected = selected;
      _loading = false;
      _summary = null;
    });
    if (selected != null && premium) await _loadSelected();
  }

  Future<void> _loadSelected() async {
    final selected = _selected;
    if (selected == null) return;
    final summary = await EmployeeService.instance.payrollSummary(selected);
    final debts = await EmployeeService.instance.listDebts(selected);
    final payments =
        await EmployeeService.instance.listSalaryPayments(selected);
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _debts = debts;
      _salaryPayments = payments;
    });
  }

  Map<String, Object?>? get _employee {
    for (final row in _employees) {
      if ('${row['sync_id']}' == _selected) return row;
    }
    return null;
  }

  Future<void> _editCompensation() async {
    final employee = _employee;
    if (employee == null) return;
    final result = await showDialog<_CompensationInput>(
      context: context,
      builder: (context) => _CompensationDialog(employee: employee),
    );
    if (result == null) return;
    try {
      await EmployeeService.instance.updateCompensation(
        '${employee['sync_id']}',
        jenisImbalan: result.jenisImbalan,
        gajiBulananCents: result.gajiBulananCents,
        komisiMode: result.komisiMode,
        komisiBarangNilai: result.komisiBarangNilai,
        komisiJasaNilai: result.komisiJasaNilai,
        payrollPeriod: result.payrollPeriod,
        payrollTanggal: result.payrollTanggal,
        payrollHari: result.payrollHari,
        bankNama: result.bankNama,
        bankNomor: result.bankNomor,
        bankPemilik: result.bankPemilik,
      );
      await _load();
      if (mounted) showSnack(context, 'Kompensasi disimpan.');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyimpan: $error', error: true);
      }
    }
  }

  Future<void> _paySalary() async {
    final selected = _selected;
    if (selected == null) return;
    final bonus = tryParseRupiahToCents(_bonus.text) ?? 0;
    final ok = await confirmAction(
      context,
      title: 'Bayar gaji',
      message:
          'Bayar imbalan siklus ini untuk ${_summary?.nama ?? 'karyawan'}? '
          'Hutang karyawan akan dipotong otomatis.',
      confirmLabel: 'Bayar',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await EmployeeService.instance.paySalary(
        selected,
        bonusCents: bonus,
      );
      _bonus.clear();
      await _loadSelected();
      if (mounted) showSnack(context, 'Pembayaran gaji dicatat.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal membayar: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDebt() async {
    final selected = _selected;
    if (selected == null) return;
    final nominal = TextEditingController();
    final catatan = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tambah hutang'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nominal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Nominal'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: catatan,
              decoration: const InputDecoration(labelText: 'Catatan'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final cents = tryParseRupiahToCents(nominal.text);
    final note = catatan.text;
    nominal.dispose();
    catatan.dispose();
    if (result != true) return;
    if (cents == null || cents <= 0) {
      if (mounted) showSnack(context, 'Nominal tidak valid.', error: true);
      return;
    }
    try {
      await EmployeeService.instance.addDebt(
        selected,
        nominalCents: cents,
        catatan: note,
      );
      await _loadSelected();
      if (mounted) showSnack(context, 'Hutang dicatat.');
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_premium) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.workspace_premium_outlined,
            title: 'Fitur karyawan khusus premium',
            subtitle:
                'Aktifkan lisensi di menu Premium untuk mengelola komisi, '
                'gaji, dan hutang karyawan.',
          ),
        ],
      );
    }
    if (_employees.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.badge_outlined,
            title: 'Belum ada karyawan',
            subtitle:
                'Buat akun karyawan di menu Premium, lalu atur kompensasinya '
                'di sini.',
          ),
        ],
      );
    }
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Karyawan'),
              Tab(text: 'Komisi & Gaji'),
              Tab(text: 'Hutang'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _employeesTab(),
                _payrollTab(),
                _debtTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _employeesTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final employee in _employees)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SectionCard(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text(
                    '${employee['nama'] ?? '?'}'
                        .substring(0, 1)
                        .toUpperCase(),
                  ),
                ),
                title: Text(
                  '${employee['nama'] ?? employee['username']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${employee['role_base']} · '
                  '${employee['jenis_imbalan'] == 'GAJI' ? 'Gaji' : 'Komisi'} · '
                  '${employee['payroll_period']}'
                  '${employee['aktif'] == 1 ? '' : ' · nonaktif'}',
                ),
                trailing: TextButton(
                  onPressed: () {
                    setState(() => _selected = '${employee['sync_id']}');
                    _editCompensation();
                  },
                  child: const Text('Atur'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _payrollTab() {
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _employeePicker(),
        const SizedBox(height: 12),
        if (summary != null)
          SectionCard(
            title: 'Siklus ${summary.periode.toLowerCase()}',
            subtitle:
                '${dateId.format(summary.cycleStart)} – '
                '${dateId.format(summary.cycleEnd)}',
            child: Column(
              children: [
                _row('Komisi siklus', formatRupiah(summary.commissionCents)),
                _row('Gaji pokok', formatRupiah(summary.gajiCents)),
                _row('Hutang', formatRupiah(summary.debtCents)),
                _row('Potongan hutang', formatRupiah(summary.deductionCents)),
                const Divider(),
                _row('Dibayarkan', formatRupiah(summary.netCents), bold: true),
                if (summary.paid)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Gaji siklus ini sudah dibayar.'),
                    ),
                  )
                else ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _bonus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Bonus (opsional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _paySalary,
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Bayar gaji'),
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        if (_salaryPayments.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Riwayat gaji',
            child: Column(
              children: _salaryPayments
                  .map(
                    (payment) => _row(
                      dateId.format(localTime(payment['cycle_start'])),
                      formatRupiah(
                        (payment['nominal'] as int) -
                            (payment['potongan_hutang'] as int? ?? 0),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _debtTab() {
    final total = _debts.fold<int>(
      0,
      (sum, debt) =>
          sum + (debt['nominal'] as int) - (debt['terbayar'] as int? ?? 0),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _employeePicker(),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Hutang karyawan',
          subtitle: 'Total sisa ${formatRupiah(total)}',
          trailing: IconButton(
            tooltip: 'Tambah hutang',
            onPressed: _addDebt,
            icon: const Icon(Icons.add),
          ),
          child: _debts.isEmpty
              ? const Text('Belum ada hutang.')
              : Column(
                  children: _debts
                      .map((debt) {
                        final remaining = (debt['nominal'] as int) -
                            (debt['terbayar'] as int? ?? 0);
                        return _row(
                          '${debt['catatan'] ?? 'Hutang'} · '
                          '${dateId.format(localTime(debt['created_at']))}',
                          formatRupiah(remaining),
                        );
                      })
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _employeePicker() {
    return DropdownButtonFormField<String>(
      initialValue: _selected,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Karyawan'),
      items: _employees
          .map(
            (employee) => DropdownMenuItem(
              value: '${employee['sync_id']}',
              child: Text('${employee['nama'] ?? employee['username']}'),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        setState(() => _selected = value);
        _loadSelected();
      },
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
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

class _CompensationInput {
  const _CompensationInput({
    required this.jenisImbalan,
    required this.gajiBulananCents,
    required this.komisiMode,
    required this.komisiBarangNilai,
    required this.komisiJasaNilai,
    required this.payrollPeriod,
    required this.payrollTanggal,
    required this.payrollHari,
    this.bankNama,
    this.bankNomor,
    this.bankPemilik,
  });

  final String jenisImbalan;
  final int gajiBulananCents;
  final String komisiMode;
  final int komisiBarangNilai;
  final int komisiJasaNilai;
  final String payrollPeriod;
  final int payrollTanggal;
  final int payrollHari;
  final String? bankNama;
  final String? bankNomor;
  final String? bankPemilik;
}

class _CompensationDialog extends StatefulWidget {
  const _CompensationDialog({required this.employee});

  final Map<String, Object?> employee;

  @override
  State<_CompensationDialog> createState() => _CompensationDialogState();
}

class _CompensationDialogState extends State<_CompensationDialog> {
  late final TextEditingController _gaji;
  late final TextEditingController _barang;
  late final TextEditingController _jasa;
  late final TextEditingController _tanggal;
  late final TextEditingController _hari;
  late final TextEditingController _bankNama;
  late final TextEditingController _bankNomor;
  late final TextEditingController _bankPemilik;
  late String _jenis;
  late String _mode;
  late String _periode;
  String? _error;

  @override
  void initState() {
    super.initState();
    final employee = widget.employee;
    _jenis = '${employee['jenis_imbalan'] ?? 'KOMISI'}';
    _mode = '${employee['komisi_mode'] ?? 'PERSEN'}';
    _periode = '${employee['payroll_period'] ?? 'BULANAN'}';
    _gaji = TextEditingController(
      text: formatRupiahPlain((employee['gaji_bulanan'] as num?)?.toInt() ?? 0),
    );
    _barang = TextEditingController(
      text: '${(employee['komisi_barang_nilai'] as num?)?.toInt() ?? 0}',
    );
    _jasa = TextEditingController(
      text: '${(employee['komisi_jasa_nilai'] as num?)?.toInt() ?? 0}',
    );
    _tanggal = TextEditingController(
      text: '${(employee['payroll_tanggal'] as num?)?.toInt() ?? 1}',
    );
    _hari = TextEditingController(
      text: '${(employee['payroll_hari'] as num?)?.toInt() ?? 1}',
    );
    _bankNama = TextEditingController(
      text: '${employee['bank_nama'] ?? ''}',
    );
    _bankNomor = TextEditingController(
      text: '${employee['bank_nomor'] ?? ''}',
    );
    _bankPemilik = TextEditingController(
      text: '${employee['bank_pemilik'] ?? ''}',
    );
  }

  @override
  void dispose() {
    _gaji.dispose();
    _barang.dispose();
    _jasa.dispose();
    _tanggal.dispose();
    _hari.dispose();
    _bankNama.dispose();
    _bankNomor.dispose();
    _bankPemilik.dispose();
    super.dispose();
  }

  void _save() {
    final gaji = tryParseRupiahToCents(_gaji.text);
    final barang = int.tryParse(_barang.text.trim());
    final jasa = int.tryParse(_jasa.text.trim());
    final tanggal = int.tryParse(_tanggal.text.trim());
    final hari = int.tryParse(_hari.text.trim());
    if (gaji == null || barang == null || jasa == null) {
      setState(() => _error = 'Nilai kompensasi tidak valid.');
      return;
    }
    if (tanggal == null || hari == null) {
      setState(() => _error = 'Jadwal payroll tidak valid.');
      return;
    }
    Navigator.pop(
      context,
      _CompensationInput(
        jenisImbalan: _jenis,
        gajiBulananCents: gaji,
        komisiMode: _mode,
        komisiBarangNilai: barang,
        komisiJasaNilai: jasa,
        payrollPeriod: _periode,
        payrollTanggal: tanggal,
        payrollHari: hari,
        bankNama: _bankNama.text,
        bankNomor: _bankNomor.text,
        bankPemilik: _bankPemilik.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final persen = _mode == 'PERSEN';
    return AlertDialog(
      title: Text('Kompensasi ${widget.employee['nama'] ?? ''}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _jenis,
              decoration: const InputDecoration(labelText: 'Jenis imbalan'),
              items: const [
                DropdownMenuItem(value: 'KOMISI', child: Text('Komisi')),
                DropdownMenuItem(value: 'GAJI', child: Text('Gaji bulanan')),
              ],
              onChanged: (value) => setState(() => _jenis = value ?? 'KOMISI'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _gaji,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Gaji bulanan'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Mode komisi'),
              items: const [
                DropdownMenuItem(value: 'PERSEN', child: Text('Persen')),
                DropdownMenuItem(value: 'NOMINAL', child: Text('Nominal tetap')),
              ],
              onChanged: (value) => setState(() => _mode = value ?? 'PERSEN'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _barang,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: persen
                    ? 'Komisi barang (%)'
                    : 'Komisi barang per nota',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _jasa,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: persen ? 'Komisi jasa (%)' : 'Komisi jasa per nota',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _periode,
              decoration: const InputDecoration(labelText: 'Periode payroll'),
              items: const [
                DropdownMenuItem(value: 'MINGGUAN', child: Text('Mingguan')),
                DropdownMenuItem(value: 'BULANAN', child: Text('Bulanan')),
              ],
              onChanged: (value) =>
                  setState(() => _periode = value ?? 'BULANAN'),
            ),
            const SizedBox(height: 10),
            if (_periode == 'BULANAN')
              TextField(
                controller: _tanggal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Tanggal payroll (1-31)',
                ),
              )
            else
              TextField(
                controller: _hari,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Hari payroll (1=Senin, 7=Minggu)',
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _bankNama,
              decoration: const InputDecoration(labelText: 'Bank'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bankNomor,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Nomor rekening'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bankPemilik,
              decoration: const InputDecoration(labelText: 'Pemilik rekening'),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
