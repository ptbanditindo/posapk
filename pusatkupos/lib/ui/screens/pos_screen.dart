import 'package:flutter/material.dart';

import '../../auth/operator.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/account_service.dart';
import '../../data/app_database.dart';
import '../../data/employee_service.dart';
import '../../data/feature_flags.dart';
import '../../data/followup_service.dart';
import '../../data/models.dart';
import '../../data/order_service.dart';
import '../../data/pajak.dart';
import '../../data/store_settings.dart';
import '../../printer/printer_config.dart';
import '../../printer/printer_service.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';
import '../receipt_dialog.dart';
import '../widgets.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _keluhan = TextEditingController();
  final _diskon = TextEditingController();
  final _alasanDiskon = TextEditingController();
  final _bayar = TextEditingController();
  final _garansiBulan = TextEditingController(text: '1');
  bool _garansiEdited = false;
  final _garansiCatatan = TextEditingController();
  final _garansiBarangNilai = TextEditingController(text: '7');
  final List<JobDraft> _jobs = [];
  final List<PartDraft> _parts = [];

  List<Customer> _customers = [];
  List<VehicleUnit> _units = [];
  List<StockItem> _stock = [];
  List<ServiceCatalog> _catalog = [];
  List<Map<String, Object?>> _mechanics = [];
  int? _customerId;
  int? _unitId;
  final Set<int> _mechanicIds = {};
  String _metode = 'CASH';
  String _requestId = newSyncId();
  String _jenis = transactionServisLangsung;
  StoreSettings? _settings;
  bool _loading = true;
  bool _saving = false;
  bool _bergaransi = true;
  bool get _sparepartOnly => _jenis == transactionJualSparepart;
  bool _garansiBarang = false;
  String _garansiBarangSatuan = 'HARI';
  bool _unitDitinggal = false;
  int _garansiDefaultBulan = 1;
  DateTime? _jatuhTempo;

  Operator? get _actor => AppState.instance.operator;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_load);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_load);
    _keluhan.dispose();
    _diskon.dispose();
    _alasanDiskon.dispose();
    _bayar.dispose();
    _garansiBulan.dispose();
    _garansiCatatan.dispose();
    _garansiBarangNilai.dispose();
    super.dispose();
  }

  int get _biayaJasa =>
      _jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents);
  int get _totalPart =>
      _parts.fold<int>(0, (sum, part) => sum + part.subtotalCents);
  int get _bruto => _biayaJasa + _totalPart;

  int get _dppBase => (_bruto - _diskonCents).clamp(0, _bruto).toInt();

  PajakSnapshot get _pajak => PajakSnapshot.hitung(
        brutoCents: _dppBase,
        config: _settings?.pajakConfig ?? const PajakConfig(),
      );

  int get _estimatedCommission {
    final selected =
        _mechanics.where((row) => _mechanicIds.contains(row['id'])).toList();
    final pajak = _pajak;
    final factorBp = _dppBase == 0 ? 10000 : pajak.dppCents * 10000 ~/ _dppBase;
    int scale(int value) => value * factorBp ~/ 10000;
    final margin = _parts.fold<int>(
      0,
      (sum, part) =>
          sum +
          ((scale(part.hargaCents) - part.modalCents) * part.qtyMilli) ~/ 1000,
    );
    return EmployeeService.estimateRecordCommissions(
      selected,
      jasaCents: scale(_biayaJasa),
      marginCents: margin,
      hasJobs: _jobs.isNotEmpty,
      hasParts: _parts.isNotEmpty,
    );
  }
  int get _diskonCents => tryParseRupiahToCents(_diskon.text) ?? 0;
  bool get _diskonInvalid =>
      _diskon.text.trim().isNotEmpty &&
      tryParseRupiahToCents(_diskon.text) == null;

  /// Selisih harga jual dan modal seluruh baris. Diskon kasir tidak boleh
  /// melewati nilai ini dan harga akhir tidak boleh di bawah modal.
  int get _maxDiscountCents {
    final margin = _jobs.fold<int>(
          0,
          (sum, job) =>
              sum + (job.hargaCents - job.modalCents) * job.jumlah,
        ) +
        _parts.fold<int>(
          0,
          (sum, part) =>
              sum +
              ((part.hargaCents - part.modalCents) * part.qtyMilli) ~/ 1000,
        );
    return margin < 0 ? 0 : margin;
  }

  /// Alasan nota wajib bila ada diskon atau baris nego tanpa alasan sendiri.
  bool get _alasanWajib =>
      _diskonCents > 0 ||
      _jobs.any(
        (job) =>
            job.hargaTerdaftarCents > 0 &&
            job.hargaCents < job.hargaTerdaftarCents &&
            (job.alasanDiskon ?? '').trim().isEmpty,
      ) ||
      _parts.any(
        (part) =>
            part.hargaTerdaftarCents > 0 &&
            part.hargaCents < part.hargaTerdaftarCents &&
            (part.alasanDiskon ?? '').trim().isEmpty,
      );

  bool get _diskonMelebihiMargin =>
      !AppState.instance.isOwner &&
      !_diskonInvalid &&
      _diskonCents > _maxDiscountCents;
  bool get _diskonMelebihiTotal =>
      !_diskonInvalid && _diskonCents > _bruto;
  bool get _canDiscount {
    final actor = _actor;
    final settings = _settings;
    if (actor == null || settings == null) return false;
    return AppState.instance.can('diskon') &&
        settings.roleAllows(actor.role, 'diskon');
  }

  bool get _canCredit {
    final actor = _actor;
    final settings = _settings;
    if (actor == null || settings == null) return false;
    return AppState.instance.can('beri_kredit') &&
        settings.roleAllows(actor.role, 'beri_kredit');
  }

  bool get _canStockOut {
    final actor = _actor;
    final settings = _settings;
    if (actor == null || settings == null) return false;
    return AppState.instance.can('stok_keluar') &&
        settings.roleAllows(actor.role, 'stok_keluar');
  }

  bool get _canSave {
    if (AppState.instance.isOwner) return true;
    return AppState.instance.can(
      _jenis == transactionEstimasiSaja ? 'buat_estimasi' : 'buat_nota',
    );
  }

  bool get _canEditCustomers {
    if (AppState.instance.isOwner) return true;
    return AppState.instance.can('ubah_pelanggan');
  }

  int get _total => _pajak.totalCents;
  int get _bayarCents => tryParseRupiahToCents(_bayar.text) ?? 0;
  bool get _bayarInvalid =>
      _bayar.text.trim().isNotEmpty &&
      tryParseRupiahToCents(_bayar.text) == null;

  List<String> get _availableTypes {
    final settings = _settings;
    if (settings == null) return const [transactionServisLangsung];
    if (!AppState.instance.isOwner &&
        !AppState.instance.can('buat_nota')) {
      return const [];
    }
    final canEstimasi =
        FeatureFlagsService.instance.isEnabled(featureEstimasi) &&
        (AppState.instance.isOwner ||
            AppState.instance.can('buat_estimasi'));
    final role = _actor?.role ?? 'owner';
    return [
      transactionJualSparepart,
      transactionServisLangsung,
      transactionEstimasiSaja,
    ].where((type) {
      return settings.typeEnabled(type) &&
          (type != transactionEstimasiSaja || canEstimasi) &&
          (role == 'owner' || settings.roleAllows(role, 'jenis_$type'));
    }).toList();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final settings = await StoreSettingsService.instance.ensure();
    final customers = await db.listCustomers();
    final stock = await db.listStock();
    final catalog = await db.listCatalog();
    final accounts = await AccountService.instance.listAccounts();
    final defaultGaransi = await db.getSetting('garansi.default_bulan');
    var units = <VehicleUnit>[];
    var customerId = _customerId;
    if (customerId != null &&
        !customers.any((customer) => customer.id == customerId)) {
      customerId = null;
    }
    if (customerId != null) {
      units = await db.listUnits(customerId);
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      final allowed = _availableTypes;
      if (allowed.isNotEmpty && !allowed.contains(_jenis)) {
        _jenis = allowed.first;
      }
      _customers = customers;
      _stock = stock;
      _catalog = catalog;
      _mechanics = accounts
          .where(
            (account) =>
                account['aktif'] == 1 &&
                settings.roleAllows(
                  account['role_base'] as String? ?? 'KASIR',
                  'ubah_status',
                ),
          )
          .toList();
      _garansiDefaultBulan = int.tryParse(defaultGaransi ?? '') ?? 1;
      if (!_garansiEdited && _garansiDefaultBulan != 1) {
        _garansiBulan.text = '$_garansiDefaultBulan';
      }
      _customerId = customerId;
      _units = units;
      final unitId = _unitId;
      if (unitId == null || !units.any((unit) => unit.id == unitId)) {
        _unitId = null;
      }
      if (_mechanicIds.isNotEmpty &&
          !_mechanicIds.every(
            (id) => _mechanics.any((row) => row['id'] == id),
          )) {
        _mechanicIds.clear();
      }
      _loading = false;
    });
  }

  Future<void> _addCustomer() async {
    if (!_canEditCustomers) {
      showSnack(
        context,
        'Peran ini tidak diizinkan menambah atau mengubah pelanggan.',
        error: true,
      );
      return;
    }
    final input = await showDialog<_QuickCustomer>(
      context: context,
      builder: (_) => const _QuickCustomerDialog(),
    );
    if (input == null) return;
    try {
      final id = await AppDatabase.instance.addCustomer(
        nama: input.nama,
        nomorHp: input.nomorHp,
        alamat: input.alamat,
        enqueue: (txn, customerId) =>
            SyncService.instance.enqueueCustomer(customerId, txn: txn),
      );
      _customerId = id;
      _unitId = null;
      AppState.instance.touch();
      await _load();
    } on DuplicateCustomerException catch (duplicate) {
      if (!mounted) return;
      final useExisting = await confirmAction(
        context,
        title: 'Pelanggan sudah ada',
        message: '$duplicate. Pakai pelanggan "${duplicate.existingName}"?',
        confirmLabel: 'Pakai yang ada',
      );
      if (!useExisting) return;
      _customerId = duplicate.existingId;
      _unitId = null;
      await _load();
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Future<void> _addUnit() async {
    if (!_canEditCustomers) {
      showSnack(
        context,
        'Peran ini tidak diizinkan menambah atau mengubah pelanggan.',
        error: true,
      );
      return;
    }
    final customerId = _customerId;
    if (customerId == null) {
      showSnack(context, 'Pilih pelanggan terlebih dahulu.', error: true);
      return;
    }
    final input = await showDialog<_QuickUnit>(
      context: context,
      builder: (_) => const _QuickUnitDialog(),
    );
    if (input == null) return;
    final id = await AppDatabase.instance.addUnit(
      customerId: customerId,
      unitType: input.unitType,
      nopol: input.nopol,
      jenisMobil: input.jenisMobil,
      tahunMobil: input.tahunMobil,
      enqueue: (txn, unitId) =>
          SyncService.instance.enqueueUnit(unitId, txn: txn),
    );
    _unitId = id;
    AppState.instance.touch();
    await _load();
  }

  Future<void> _addJob() async {
    if (_sparepartOnly) {
      showSnack(
        context,
        'Mode sparepart saja tidak boleh memuat jasa.',
        error: true,
      );
      return;
    }
    final job = await showDialog<JobDraft>(
      context: context,
      builder: (_) => _JobDialog(catalog: _catalog),
    );
    if (job == null) return;
    setState(() => _jobs.add(job));
  }

  Future<void> _addPart() async {
    if (_jenis != transactionEstimasiSaja && !_canStockOut) {
      showSnack(
        context,
        'Peran ini tidak berhak mengeluarkan stok.',
        error: true,
      );
      return;
    }
    if (_stock.isEmpty) {
      showSnack(context, 'Belum ada sparepart. Tambahkan di menu Stok.',
          error: true);
      return;
    }
    final part = await showDialog<PartDraft>(
      context: context,
      builder: (_) => _PartDialog(stock: _stock),
    );
    if (part == null) return;
    if (!mounted) return;
    final index = _parts.indexWhere(
      (item) => item.stockItemId == part.stockItemId,
    );
    if (index < 0) {
      setState(() => _parts.add(part));
      return;
    }
    final existing = _parts[index];
    final totalMilli = existing.qtyMilli + part.qtyMilli;
    StockItem? stockItem;
    for (final item in _stock) {
      if (item.id == part.stockItemId) {
        stockItem = item;
        break;
      }
    }
    if (stockItem != null && totalMilli > stockItem.jumlahMilli) {
      showSnack(
        context,
        'Stok ${stockItem.nama} tidak cukup. Tersisa ${stockItem.jumlahLabel}.',
        error: true,
      );
      return;
    }
    setState(() {
      _parts[index] = PartDraft(
        stockItemId: existing.stockItemId,
        nama: existing.nama,
        jumlah: totalMilli ~/ 1000,
        qtyMilli: totalMilli,
        hargaCents: existing.hargaCents,
        modalCents: existing.modalCents,
        intervalBulan: existing.intervalBulan,
        syncId: existing.syncId,
        hargaTerdaftarCents: existing.hargaTerdaftarCents,
      );
    });
  }

  Future<void> _save() async {
    if (!_canSave) {
      showSnack(
        context,
        _jenis == transactionEstimasiSaja
            ? 'Peran ini tidak diizinkan membuat estimasi.'
            : 'Peran ini tidak diizinkan membuat nota.',
        error: true,
      );
      return;
    }
    if (_customerId == null) {
      showSnack(context, 'Pilih pelanggan terlebih dahulu.', error: true);
      return;
    }
    final unitRequired =
        FeatureFlagsService.instance.isEnabled(featureUnitKendaraan) &&
        (_settings?.vehicleRequired ?? true) &&
        _jenis != transactionJualSparepart;
    if (unitRequired && _unitId == null) {
      showSnack(context, 'Pilih unit kendaraan terlebih dahulu.', error: true);
      return;
    }
    if (_jobs.isEmpty && _parts.isEmpty) {
      showSnack(context, 'Tambahkan minimal satu jasa atau part.', error: true);
      return;
    }
    if (_jenis != transactionEstimasiSaja &&
        _parts.isNotEmpty &&
        !_canStockOut) {
      showSnack(
        context,
        'Peran ini tidak berhak mengeluarkan stok. Hapus part atau minta '
        'izin stok keluar.',
        error: true,
      );
      return;
    }
    if (_diskonInvalid) {
      showSnack(
        context,
        'Diskon harus berupa angka tanpa titik atau huruf.',
        error: true,
      );
      return;
    }
    if (_diskonMelebihiTotal) {
      showSnack(
        context,
        'Diskon tidak boleh melebihi total tagihan '
        '${formatRupiah(_bruto)}.',
        error: true,
      );
      return;
    }
    if (_diskonMelebihiMargin) {
      showSnack(
        context,
        'Diskon maksimal ${formatRupiah(_maxDiscountCents)} '
        '(selisih harga jual dan modal).',
        error: true,
      );
      return;
    }
    if (_alasanWajib && _alasanDiskon.text.trim().isEmpty) {
      showSnack(
        context,
        'Alasan negosiasi/diskon wajib diisi.',
        error: true,
      );
      return;
    }
    if (_bayarInvalid) {
      showSnack(
        context,
        'Nominal bayar harus berupa angka tanpa titik atau huruf.',
        error: true,
      );
      return;
    }
    if (_metode == 'TRANSFER' && _bayarCents > _total) {
      showSnack(
        context,
        'Pembayaran transfer tidak boleh melebihi tagihan.',
        error: true,
      );
      return;
    }
    final sisa = (_total - _bayarCents).clamp(0, _total).toInt();
    if (sisa > 0) {
      if (!AppState.instance.isOwner && !_canCredit) {
        showSnack(
          context,
          'Peran ini tidak berhak memberi kredit.',
          error: true,
        );
        return;
      }
      if (_jatuhTempo == null) {
        showSnack(
          context,
          'Jatuh tempo wajib diisi untuk nota dengan sisa bayar.',
          error: true,
        );
        return;
      }
    }
    if (_sparepartOnly && _jobs.isNotEmpty) {
      showSnack(
        context,
        'Mode sparepart saja tidak boleh memuat jasa.',
        error: true,
      );
      return;
    }
    if (_sparepartOnly && _parts.isEmpty) {
      showSnack(
        context,
        'Mode sparepart saja membutuhkan minimal satu part.',
        error: true,
      );
      return;
    }
    final garansiBulan = int.tryParse(_garansiBulan.text.trim()) ?? 0;
    if (!_sparepartOnly && _bergaransi && garansiBulan < 1) {
      showSnack(context, 'Durasi garansi minimal 1 bulan.', error: true);
      return;
    }
    final garansiBarangNilai =
        int.tryParse(_garansiBarangNilai.text.trim()) ?? 0;
    if (_sparepartOnly && _garansiBarang && garansiBarangNilai < 1) {
      showSnack(
        context,
        'Durasi garansi barang minimal 1 hari atau 1 bulan.',
        error: true,
      );
      return;
    }
    if (_jenis == transactionEstimasiSaja) {
      await _saveEstimate();
      return;
    }
    final actor = _actor;
    final mechanics = _mechanics
        .where((row) => _mechanicIds.contains(row['id']))
        .toList();
    setState(() => _saving = true);
    int? id;
    try {
      id = await _createWithApproval(
        actor: actor,
        mechanics: mechanics,
        garansiBulan: garansiBulan,
        garansiBarangNilai: garansiBarangNilai,
      );
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal menyimpan: $error', error: true);
      }
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (id == null) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    // Nota sudah tersimpan. Kegagalan setelah titik ini tidak boleh
    // dilaporkan sebagai gagal simpan.
    try {
      AppState.instance.touch();
      FollowupService.instance.scheduleSync();
      await _load();
      if (!mounted) return;
      setState(() {
        _jobs.clear();
        _parts.clear();
        _keluhan.clear();
        _diskon.clear();
        _alasanDiskon.clear();
        _bayar.clear();
        _unitId = null;
        _mechanicIds.clear();
        _requestId = newSyncId();
        _bergaransi = true;
        _garansiBulan.text = '$_garansiDefaultBulan';
        _garansiCatatan.clear();
        _garansiBarang = false;
        _unitDitinggal = false;
        _jatuhTempo = null;
      });
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          'Nota tersimpan, tetapi daftar gagal dimuat ulang: $error',
          error: true,
        );
      }
    }
    try {
      final detail = await AppDatabase.instance.recordDetail(id);
      if (detail != null) await _showReceipt(detail);
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          'Nota tersimpan, tetapi struk gagal dibuka: $error',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<EstimateItemInput> _estimateItems() => [
        for (final job in _jobs)
          EstimateItemInput(
            jenis: 'jasa',
            deskripsi: job.deskripsi,
            jumlah: job.jumlah,
            hargaCents: job.hargaCents,
            modalCents: job.modalCents,
            jasaId: job.jasaId,
            intervalBulan: job.intervalBulan,
            hargaTerdaftarCents: job.hargaTerdaftarCents,
          ),
        for (final part in _parts)
          EstimateItemInput(
            jenis: 'part',
            deskripsi: part.nama,
            jumlah: part.jumlah,
            qtyMilli: part.qtyMilli,
            hargaCents: part.hargaCents,
            modalCents: part.modalCents,
            stockItemId: part.stockItemId,
            intervalBulan: part.intervalBulan,
            hargaTerdaftarCents: part.hargaTerdaftarCents,
          ),
      ];

  Future<EstimateRecord?> _createEstimateWithApproval() async {
    final actor = AppState.instance.requireOperator;
    final settings = _settings;
    String? ownerPin;
    String? approverSecret;
    var asked = false;
    while (true) {
      try {
        return await OrderService.instance.createEstimate(
          customerId: _customerId,
          unitId: _unitId,
          items: _estimateItems(),
          jenisTransaksi: _jenis == transactionEstimasiSaja
              ? transactionServisLangsung
              : _jenis,
          diskonCents: _diskonCents,
          alasanDiskon: _alasanDiskon.text.trim().isEmpty
              ? (_alasanWajib ? 'Diskon estimasi' : null)
              : _alasanDiskon.text.trim(),
          ownerPin: ownerPin,
          approverSecret: approverSecret,
          actor: actor,
          enqueue: (txn, syncId) => SyncService.instance.enqueueEstimate(
            syncId,
            txn: txn,
          ),
        );
      } on StateError catch (error) {
        if (asked || !error.message.contains('persetujuan')) rethrow;
        final secret = await _askApproval(settings);
        if (secret == null) return null;
        asked = true;
        if (settings?.approverMode == approverEmployee) {
          approverSecret = secret;
        } else {
          ownerPin = secret;
        }
      }
    }
  }

  Future<void> _saveEstimate() async {
    setState(() => _saving = true);
    try {
      final record = await _createEstimateWithApproval();
      if (!mounted) return;
      if (record == null) {
        await _printEstimateText(null);
        if (!mounted) return;
        showSnack(
          context,
          'Estimasi hanya dicetak karena penyimpanan estimasi dimatikan.',
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Estimasi tersimpan'),
            content: Text(
              '${record.nomorEstimasi}\n'
              'Total ${formatRupiah(record.totalCents)}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Tutup'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _printEstimateText(record);
                },
                icon: const Icon(Icons.print_outlined),
                label: const Text('Cetak'),
              ),
            ],
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _jobs.clear();
        _parts.clear();
        _keluhan.clear();
        _diskon.clear();
        _alasanDiskon.clear();
        _bayar.clear();
        _unitId = null;
        _mechanicIds.clear();
        _requestId = newSyncId();
        _garansiBarang = false;
        _unitDitinggal = false;
      });
    } catch (error) {
      if (mounted) showSnack(context, 'Gagal menyimpan: $error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _printEstimateText(EstimateRecord? record) async {
    final printer = await PrinterStore.instance.primary();
    if (printer == null) {
      if (mounted) {
        showSnack(
          context,
          'Belum ada printer. Tambahkan printer di Pengaturan.',
          error: true,
        );
      }
      return;
    }
    final store = await AppDatabase.instance.getSetting('bengkel.nama') ??
        'PUSATKU POS';
    final lines = <String>[
      store,
      'ESTIMASI - bukan bukti pembayaran',
      List.filled(printer.width, '-').join(),
      if (record != null) 'No: ${record.nomorEstimasi}',
      dateTimeId.format(DateTime.now()),
      List.filled(printer.width, '-').join(),
      for (final job in _jobs)
        '${job.deskripsi} ${job.jumlah}x = ${formatRupiah(job.subtotalCents)}',
      for (final part in _parts)
        '${part.nama} ${part.qtyLabel}x = ${formatRupiah(part.subtotalCents)}',
      List.filled(printer.width, '-').join(),
      if (_pajak.active) ...[
        'DPP: ${formatRupiah(_pajak.dppCents)}',
        'PPN ${formatPersenBp(_pajak.persenBp)}: '
            '${formatRupiah(_pajak.pajakCents)}'
            '${_pajak.penanggung == pajakPenanggungBengkel ? ' (bengkel)' : ''}',
      ],
      'Total: ${formatRupiah(record?.totalCents ?? _total)}',
      '',
      'Harga dapat berubah sebelum pekerjaan disetujui.',
    ];
    final result = await PrinterService.instance.printText(
      lines.join('\n'),
      printer: printer,
    );
    if (mounted) showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _pickJatuhTempo() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _jatuhTempo ?? now.add(const Duration(days: 14)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _jatuhTempo = picked);
  }

  Future<int?> _createWithApproval({
    required Operator? actor,
    required List<Map<String, Object?>> mechanics,
    required int garansiBulan,
    required int garansiBarangNilai,
  }) async {
    final settings = _settings;
    String? ownerPin;
    String? approverSecret;
    // Satu grant berlaku untuk seluruh baris dan limit kredit transaksi ini.
    var approvalPrompts = 0;
    final alasan = _alasanDiskon.text.trim();
    while (true) {
      try {
        return await AppDatabase.instance.createTransaction(
          unitId: _unitId,
          customerId: _customerId,
          jenisTransaksi: _jenis,
          keluhan: _keluhan.text.trim().isEmpty
              ? 'Servis di kasir'
              : _keluhan.text.trim(),
          jobs: List.of(_jobs),
          parts: List.of(_parts),
          diskonCents: _diskonCents,
          metodeBayar: _metode,
          bayarCents: _bayarCents,
          jatuhTempo: (_total - _bayarCents) > 0 ? _jatuhTempo : null,
          requestId: _requestId,
          actor: actor,
          mechanic: mechanics.isEmpty
              ? null
              : mechanics.map((row) => '${row['nama']}').join(', '),
          mechanicEmployeeSyncId: mechanics.isEmpty
              ? null
              : mechanics.first['sync_id'] as String?,
          mechanicEmployeeSyncIds: mechanics
              .map((row) => '${row['sync_id']}')
              .toList(),
          sparepartOnly: _sparepartOnly,
          bergaransi: _bergaransi,
          garansiBulan: garansiBulan,
          catatanGaransi: _garansiCatatan.text.trim(),
          garansiBarangAktif: _sparepartOnly && _garansiBarang,
          garansiBarangNilai: garansiBarangNilai,
          garansiBarangSatuan: _garansiBarangSatuan,
          unitDitinggal: _unitDitinggal,
          alasanDiskon: alasan.isEmpty ? null : alasan,
          ownerPin: ownerPin,
          approverSecret: approverSecret,
          enqueue: (txn, recordId) =>
              SyncService.instance.enqueueNote(recordId, txn: txn),
          enqueueCommission: (txn, commissionId) =>
              SyncService.instance.enqueueCommission(commissionId, txn: txn),
        );
      } on StateError catch (error) {
        if (approvalPrompts >= 1 || !error.message.contains('persetujuan')) {
          rethrow;
        }
        final secret = await _askApproval(settings);
        if (secret == null) return null;
        approvalPrompts++;
        if (settings?.approverMode == approverEmployee) {
          approverSecret = secret;
        } else {
          ownerPin = secret;
        }
      }
    }
  }

  Future<String?> _askApproval(StoreSettings? settings) {
    final delegated = settings?.approverMode == approverEmployee;
    return showDialog<String>(
      context: context,
      builder: (_) => _ApprovalDialog(delegated: delegated),
    );
  }

  Future<void> _showReceipt(RecordDetail detail) async {
    final record = detail.record;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nota tersimpan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _receiptRow('No. nota', record.noNota),
            _receiptRow('Pelanggan', record.customerNama),
            _receiptRow('Unit', record.unitLabel),
            const Divider(),
            _receiptRow('Total', formatRupiah(record.totalCents)),
            _receiptRow('Dibayar', formatRupiah(detail.totalDibayarCents)),
            _receiptRow('Sisa', formatRupiah(detail.sisaCents)),
            if (record.metodeBayar == 'CASH' &&
                record.bayarCents > record.totalCents)
              _receiptRow(
                'Kembalian',
                formatRupiah(record.bayarCents - record.totalCents),
              ),
            _receiptRow('Status', record.statusBayar),
            if (record.bergaransi && record.garansiSampai != null)
              _receiptRow(
                'Garansi',
                's.d. ${dateId.format(record.garansiSampai!)}',
              ),
            if (record.unitDitinggal) _receiptRow('Unit', 'Masih di bengkel'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => showReceiptPreview(
              context,
              detail.record.id,
              title: 'Struk ${record.noNota}',
            ),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Lihat struk'),
          ),
          TextButton.icon(
            onPressed: () => printReceiptFor(context, detail.record.id),
            icon: const Icon(Icons.print_outlined),
            label: const Text('Cetak'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  Widget _receiptRow(String label, String value) {
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Kasir',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              'Total ${formatRupiah(_total)}',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_availableTypes.length > 1) ...[
          SectionCard(
            title: 'Jenis transaksi',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in _availableTypes)
                  ChoiceChip(
                    label: Text(
                      type == transactionJualSparepart
                          ? 'Jual sparepart'
                          : type == transactionEstimasiSaja
                              ? 'Estimasi saja'
                              : 'Servis langsung',
                    ),
                    selected: _jenis == type,
                    onSelected: (_) => setState(() {
                      _jenis = type;
                      if (_sparepartOnly) _bergaransi = false;
                    }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        SectionCard(
          title: 'Pelanggan dan unit',
          subtitle:
              'Pelanggan wajib dipilih. Unit dipakai untuk mencatat servis '
              'kendaraan.',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _customerId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Pelanggan',
                        helperText: 'Pilih nama pelanggan yang membeli.',
                      ),
                      items: _customers
                          .map(
                            (customer) => DropdownMenuItem(
                              value: customer.id,
                              child: Text(
                                '${customer.nama} · ${customer.nomorHp}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) async {
                        setState(() {
                          _customerId = value;
                          _unitId = null;
                          _units = [];
                        });
                        if (value != null) {
                          final units =
                              await AppDatabase.instance.listUnits(value);
                          if (mounted) setState(() => _units = units);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_canEditCustomers)
                    IconButton.filledTonal(
                      onPressed: _addCustomer,
                      icon: const Icon(Icons.person_add_alt_1),
                      tooltip: 'Pelanggan baru',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _unitId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: (_settings?.vehicleRequired ?? true) &&
                                !_sparepartOnly
                            ? 'Unit kendaraan'
                            : 'Unit kendaraan (opsional)',
                        helperText: _units.isEmpty
                            ? 'Pelanggan ini belum punya unit. Tekan tombol '
                                  'sebelah kanan untuk menambah.'
                            : 'Pilih kendaraan yang sedang diservis.',
                      ),
                      items: _units
                          .map(
                            (unit) => DropdownMenuItem(
                              value: unit.id,
                              child: Text(
                                unit.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => _unitId = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_canEditCustomers)
                    IconButton.filledTonal(
                      onPressed: _addUnit,
                      icon: const Icon(Icons.add_road_outlined),
                      tooltip: 'Unit baru',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _keluhan,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Keluhan atau keterangan',
                  hintText: 'Contoh: radiator bocor sejak kemarin',
                  helperText:
                      'Tulis keluhan pelanggan atau pekerjaan yang diminta.',
                ),
              ),
              if (_mechanics.isNotEmpty) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Mekanik yang mengerjakan (boleh lebih dari satu)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _mechanics
                      .map(
                        (row) => FilterChip(
                          label: Text('${row['nama'] ?? row['username']}'),
                          selected: _mechanicIds.contains(row['id']),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _mechanicIds.add(row['id'] as int);
                            } else {
                              _mechanicIds.remove(row['id'] as int);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
                if (_mechanicIds.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Perkiraan komisi: ${formatRupiah(_estimatedCommission)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Jasa',
          trailing: TextButton.icon(
            onPressed: _addJob,
            icon: const Icon(Icons.add),
            label: const Text('Tambah'),
          ),
          child: _jobs.isEmpty
              ? const Text(
                  'Belum ada jasa. Tekan Tambah untuk mencatat pekerjaan.',
                )
              : Column(
                  children: [
                    for (var i = 0; i < _jobs.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_jobs[i].deskripsi),
                        subtitle: Text(
                          _jobs[i].hargaTerdaftarCents > 0 &&
                                  _jobs[i].hargaTerdaftarCents !=
                                      _jobs[i].hargaCents
                              ? '${_jobs[i].jumlah} × '
                                  '${formatRupiah(_jobs[i].hargaCents)} · '
                                  'acuan '
                                  '${formatRupiah(_jobs[i].hargaTerdaftarCents)}'
                              : '${_jobs[i].jumlah} × '
                                  '${formatRupiah(_jobs[i].hargaCents)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatRupiah(_jobs[i].subtotalCents)),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _jobs.removeAt(i)),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Sparepart',
          trailing: TextButton.icon(
            onPressed: _addPart,
            icon: const Icon(Icons.add),
            label: const Text('Tambah'),
          ),
          child: _parts.isEmpty
              ? const Text(
                  'Belum ada sparepart. Tekan Tambah untuk mengambil dari stok.',
                )
              : Column(
                  children: [
                    for (var i = 0; i < _parts.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_parts[i].nama),
                        subtitle: Text(
                          _parts[i].hargaTerdaftarCents > 0 &&
                                  _parts[i].hargaTerdaftarCents !=
                                      _parts[i].hargaCents
                              ? '${_parts[i].qtyLabel} × '
                                  '${formatRupiah(_parts[i].hargaCents)} · '
                                  'acuan '
                                  '${formatRupiah(_parts[i].hargaTerdaftarCents)}'
                              : '${_parts[i].qtyLabel} × '
                                  '${formatRupiah(_parts[i].hargaCents)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatRupiah(_parts[i].subtotalCents)),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _parts.removeAt(i)),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Garansi dan unit',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Unit ditinggal di bengkel'),
                subtitle: const Text(
                  'Aktifkan bila kendaraan belum diambil; masuk daftar '
                  'kendaraan selesai di menu Tindak lanjut.',
                ),
                value: _unitDitinggal,
                onChanged: (value) => setState(() => _unitDitinggal = value),
              ),
              if (!_sparepartOnly) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Garansi servis'),
                  value: _bergaransi,
                  onChanged: (value) => setState(() => _bergaransi = value),
                ),
                if (_bergaransi)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _garansiBulan,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => _garansiEdited = true,
                          decoration: const InputDecoration(
                            labelText: 'Garansi (bulan)',
                            hintText: 'Contoh: 1',
                            helperText: '1 bulan = 30 hari',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _garansiCatatan,
                          decoration: const InputDecoration(
                            labelText: 'Syarat garansi (opsional)',
                            hintText: 'Contoh: tidak berlaku untuk kecelakaan',
                          ),
                        ),
                      ),
                    ],
                  ),
              ] else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Garansi barang'),
                  value: _garansiBarang,
                  onChanged: (value) => setState(() => _garansiBarang = value),
                ),
                if (_garansiBarang)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _garansiBarangNilai,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Durasi garansi',
                            hintText: 'Contoh: 7',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _garansiBarangSatuan,
                          decoration: const InputDecoration(labelText: 'Satuan'),
                          items: const [
                            DropdownMenuItem(
                              value: 'HARI',
                              child: Text('Hari'),
                            ),
                            DropdownMenuItem(
                              value: 'BULAN',
                              child: Text('Bulan'),
                            ),
                          ],
                          onChanged: (value) => setState(
                            () => _garansiBarangSatuan = value ?? 'HARI',
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Pembayaran',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _diskon,
                      enabled: _canDiscount,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Diskon (Rp)',
                        hintText: 'Contoh: 5000',
                        errorText: _diskonInvalid
                            ? 'Format tidak valid'
                            : _diskonMelebihiTotal
                            ? 'Maks. ${formatRupiah(_bruto)}'
                            : _diskonMelebihiMargin
                            ? 'Maks. ${formatRupiah(_maxDiscountCents)}'
                            : null,
                        helperText: AppState.instance.isOwner
                            ? null
                            : 'Maks. ${formatRupiah(_maxDiscountCents)} '
                                  '(selisih modal)',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _metode,
                      decoration: const InputDecoration(
                        labelText: 'Cara bayar',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                        DropdownMenuItem(
                          value: 'TRANSFER',
                          child: Text('Transfer'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _metode = value ?? 'CASH'),
                    ),
                  ),
                ],
              ),
              if (_alasanWajib) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _alasanDiskon,
                  decoration: const InputDecoration(
                    labelText: 'Alasan negosiasi/diskon (wajib)',
                    hintText: 'Contoh: pelanggan langganan',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _bayar,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Dibayar (Rp)',
                        hintText: 'Contoh: 150000',
                        errorText: _bayarInvalid ? 'Format tidak valid' : null,
                        helperText:
                            'Kosongkan bila pelanggan belum membayar.',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () {
                      _bayar.text = formatRupiahInput(_total);
                      setState(() {});
                    },
                    child: const Text('Bayar penuh'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _summaryRow('Jasa', _biayaJasa),
              _summaryRow('Sparepart', _totalPart),
              _summaryRow('Diskon', -_diskonCents),
              if (_pajak.active) ...[
                _summaryRow('DPP', _pajak.dppCents),
                _summaryRow(
                  _pajak.penanggung == pajakPenanggungBengkel
                      ? 'PPN ditanggung bengkel'
                      : 'PPN ${formatPersenBp(_pajak.persenBp)}',
                  _pajak.pajakCents,
                ),
              ],
              const Divider(),
              _summaryRow('Total', _total, bold: true),
              _summaryRow(
                'Kembalian',
                _metode == 'CASH' && _total > 0 && _bayarCents > _total
                    ? _bayarCents - _total
                    : 0,
              ),
              _summaryRow(
                'Sisa belum dibayar',
                (_total - _bayarCents).clamp(0, _total).toInt(),
              ),
              if ((_total - _bayarCents) > 0) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickJatuhTempo,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Jatuh tempo (wajib)',
                      helperText:
                          'Tanggal terakhir pelanggan harus melunasi sisa.',
                      suffixIcon: Icon(Icons.event_outlined),
                    ),
                    child: Text(
                      _jatuhTempo == null
                          ? 'Belum ditentukan'
                          : dateId.format(_jatuhTempo!),
                    ),
                  ),
                ),
                if (!AppState.instance.isOwner && !_canCredit)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Peran ini tidak berhak memberi kredit.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving || !_canSave ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(
            _saving
                ? 'Menyimpan...'
                : _jenis == transactionEstimasiSaja
                ? 'Simpan estimasi'
                : 'Simpan nota',
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _summaryRow(String label, int cents, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            formatRupiah(cents),
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
        ],
      ),
    );
  }
}

class _QuickCustomer {
  const _QuickCustomer(this.nama, this.nomorHp, this.alamat);

  final String nama;
  final String nomorHp;
  final String alamat;
}

class _QuickCustomerDialog extends StatefulWidget {
  const _QuickCustomerDialog();

  @override
  State<_QuickCustomerDialog> createState() => _QuickCustomerDialogState();
}

class _QuickCustomerDialogState extends State<_QuickCustomerDialog> {
  final _nama = TextEditingController();
  final _hp = TextEditingController();
  final _alamat = TextEditingController();

  @override
  void dispose() {
    _nama.dispose();
    _hp.dispose();
    _alamat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pelanggan baru'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nama,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nama pelanggan',
              hintText: 'Contoh: Budi Santoso',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _hp,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Nomor HP',
              hintText: 'Contoh: 081234567890',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alamat,
            decoration: const InputDecoration(
              labelText: 'Alamat (opsional)',
              hintText: 'Contoh: Jl. Merdeka No. 10',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            if (_nama.text.trim().isEmpty || _hp.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              _QuickCustomer(
                _nama.text.trim(),
                _hp.text.trim(),
                _alamat.text.trim(),
              ),
            );
          },
          child: const Text('Simpan pelanggan'),
        ),
      ],
    );
  }
}

class _QuickUnit {
  const _QuickUnit({
    required this.unitType,
    this.nopol,
    this.jenisMobil,
    this.tahunMobil,
  });

  final String unitType;
  final String? nopol;
  final String? jenisMobil;
  final int? tahunMobil;
}

class _QuickUnitDialog extends StatefulWidget {
  const _QuickUnitDialog();

  @override
  State<_QuickUnitDialog> createState() => _QuickUnitDialogState();
}

class _QuickUnitDialogState extends State<_QuickUnitDialog> {
  final _nopol = TextEditingController();
  final _jenis = TextEditingController();
  final _tahun = TextEditingController();
  String _type = 'MOBIL';

  @override
  void dispose() {
    _nopol.dispose();
    _jenis.dispose();
    _tahun.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unit baru'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: 'Jenis unit',
              helperText: 'Pilih kendaraan atau barang yang diservis.',
            ),
            items: const [
              DropdownMenuItem(value: 'MOBIL', child: Text('Mobil')),
              DropdownMenuItem(
                value: 'MOTOR_LENGKAP',
                child: Text('Motor lengkap'),
              ),
              DropdownMenuItem(
                value: 'RADIATOR_ONLY',
                child: Text('Radiator saja'),
              ),
              DropdownMenuItem(
                value: 'SPAREPART',
                child: Text('Sparepart'),
              ),
            ],
            onChanged: (value) => setState(() => _type = value ?? 'MOBIL'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nopol,
            decoration: const InputDecoration(
              labelText: 'Nomor polisi',
              hintText: 'Contoh: B 1234 XYZ',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _jenis,
            decoration: const InputDecoration(
              labelText: 'Jenis kendaraan',
              hintText: 'Contoh: Honda Beat 2020',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tahun,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Tahun',
              hintText: 'Contoh: 2020',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _QuickUnit(
              unitType: _type,
              nopol: _nopol.text.trim().isEmpty ? null : _nopol.text.trim(),
              jenisMobil:
                  _jenis.text.trim().isEmpty ? null : _jenis.text.trim(),
              tahunMobil: int.tryParse(_tahun.text.trim()),
            ),
          ),
          child: const Text('Simpan unit'),
        ),
      ],
    );
  }
}

class _JobDialog extends StatefulWidget {
  const _JobDialog({required this.catalog});

  final List<ServiceCatalog> catalog;

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _acuan = TextEditingController();
  final _harga = TextEditingController();
  final _alasan = TextEditingController();
  int? _catalogId;
  String? _error;

  int? get _acuanCents => tryParseRupiahToCents(_acuan.text);
  int? get _hargaCents => tryParseRupiahToCents(_harga.text);
  bool get _nego {
    final acuan = _acuanCents;
    final harga = _hargaCents;
    return acuan != null && harga != null && harga < acuan;
  }

  @override
  void dispose() {
    _desc.dispose();
    _qty.dispose();
    _acuan.dispose();
    _harga.dispose();
    _alasan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah jasa'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.catalog.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              initialValue: _catalogId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Pilih dari daftar tarif',
                helperText: 'Opsional. Isi sendiri bila jasa belum terdaftar.',
              ),
              items: widget.catalog
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(
                        '${item.nama} · ${formatRupiah(item.hargaCents)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                final item = widget.catalog
                    .where((row) => row.id == value)
                    .firstOrNull;
                setState(() {
                  _catalogId = value;
                  if (item != null) {
                    _desc.text = item.nama;
                    _acuan.text = formatRupiahPlain(item.hargaCents);
                    _harga.text = formatRupiahPlain(item.hargaCents);
                  }
                });
              },
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _desc,
            decoration: const InputDecoration(
              labelText: 'Deskripsi pekerjaan',
              hintText: 'Contoh: ganti oli mesin',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Jumlah',
                    hintText: 'Contoh: 1',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _acuan,
                  keyboardType: TextInputType.number,
                  readOnly: _catalogId != null,
                  decoration: InputDecoration(
                    labelText: 'Harga normal',
                    hintText: 'Contoh: 50000',
                    helperText: _catalogId == null
                        ? 'Harga acuan sebelum nego'
                        : 'Dari daftar tarif',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _harga,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Harga disepakati',
              hintText: 'Contoh: 45000',
              errorText: _error,
              helperText: 'Boleh di bawah harga normal dengan alasan',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_nego) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _alasan,
              decoration: const InputDecoration(
                labelText: 'Alasan nego (wajib)',
                hintText: 'Contoh: pelanggan langganan',
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () async {
            final desc = _desc.text.trim();
            final qty = int.tryParse(_qty.text.trim()) ?? 0;
            final acuan = tryParseRupiahToCents(_acuan.text);
            final harga = tryParseRupiahToCents(_harga.text);
            if (desc.isEmpty || qty < 1) {
              setState(
                () => _error = 'Isi deskripsi pekerjaan dan jumlah minimal 1.',
              );
              return;
            }
            if (acuan == null || acuan < 0) {
              setState(() => _error = 'Harga normal belum diisi dengan benar.');
              return;
            }
            if (harga == null || harga < 0) {
              setState(() => _error = 'Harga disepakati belum diisi.');
              return;
            }
            if (harga > acuan) {
              setState(() => _error = 'Harga disepakati melebihi harga normal.');
              return;
            }
            if (_nego && _alasan.text.trim().isEmpty) {
              setState(() => _error = 'Alasan nego wajib diisi.');
              return;
            }
            if (harga == 0) {
              final ok = await confirmAction(
                context,
                title: 'Harga jasa nol',
                message:
                    'Jasa ini akan dicatat dengan harga Rp 0. '
                    'Lanjutkan bila memang gratis.',
                confirmLabel: 'Simpan harga nol',
              );
              if (!ok || !context.mounted) return;
            }
            if (!context.mounted) return;
            final selected = widget.catalog
                .where((item) => item.id == _catalogId)
                .firstOrNull;
            Navigator.pop(
              context,
              JobDraft(
                deskripsi: desc,
                jumlah: qty,
                hargaCents: harga,
                jasaId: _catalogId,
                modalCents: selected?.hargaModalCents ?? 0,
                intervalBulan: selected?.intervalBulan ?? 0,
                hargaTerdaftarCents: acuan,
                alasanDiskon: _nego && _alasan.text.trim().isNotEmpty
                    ? _alasan.text.trim()
                    : null,
              ),
            );
          },
          child: const Text('Tambah jasa'),
        ),
      ],
    );
  }
}

class _PartDialog extends StatefulWidget {
  const _PartDialog({required this.stock});

  final List<StockItem> stock;

  @override
  State<_PartDialog> createState() => _PartDialogState();
}

class _PartDialogState extends State<_PartDialog> {
  final _qty = TextEditingController(text: '1');
  final _acuan = TextEditingController();
  final _harga = TextEditingController();
  final _alasan = TextEditingController();
  int? _stockId;
  String? _error;

  int? get _acuanCents => tryParseRupiahToCents(_acuan.text);
  int? get _hargaCents => tryParseRupiahToCents(_harga.text);
  bool get _nego {
    final acuan = _acuanCents;
    final harga = _hargaCents;
    return acuan != null && harga != null && harga < acuan;
  }

  @override
  void dispose() {
    _qty.dispose();
    _acuan.dispose();
    _harga.dispose();
    _alasan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.stock
        .where((item) => item.id == _stockId)
        .firstOrNull;
    return AlertDialog(
      title: const Text('Tambah sparepart'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _stockId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Barang dari stok',
              helperText: 'Stok berkurang setelah nota disimpan.',
            ),
            items: widget.stock
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(
                      '${item.nama} · stok ${item.jumlahLabel}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              final item = widget.stock
                  .where((row) => row.id == value)
                  .firstOrNull;
              setState(() {
                _stockId = value;
                if (item != null) {
                  _acuan.text = formatRupiahPlain(item.hargaJualCents);
                  _harga.text = formatRupiahPlain(item.hargaJualCents);
                }
              });
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _acuan,
                  keyboardType: TextInputType.number,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Harga normal',
                    helperText: 'Dari daftar stok',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _harga,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Harga disepakati',
                    hintText: 'Contoh: 60000',
                    errorText: _error,
                    helperText: 'Boleh kurang dari harga normal dengan alasan.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          if (_nego) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _alasan,
              decoration: const InputDecoration(
                labelText: 'Alasan nego (wajib)',
                hintText: 'Contoh: pembelian banyak',
              ),
            ),
          ],
          TextField(
            controller: _qty,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Jumlah',
              hintText: 'Contoh: 1 atau 0,5',
              helperText: selected == null
                  ? 'Pilih barang dulu untuk melihat stok tersedia.'
                  : 'Stok tersedia: ${selected.jumlahLabel}',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (selected != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Harga jual ${formatRupiah(selected.hargaJualCents)} · '
                'stok ${selected.jumlahLabel}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            final item = selected;
            final qtyMilli = item == null
                ? null
                : parseQuantityToMilli(_qty.text.trim(), desimal: item.desimal);
            final acuan = _acuanCents;
            final harga = _hargaCents;
            if (item == null || qtyMilli == null || qtyMilli <= 0) {
              setState(
                () => _error = 'Pilih barang dan isi jumlah lebih dari 0.',
              );
              return;
            }
            if (acuan == null || acuan < 0) {
              setState(() => _error = 'Harga normal belum tersedia.');
              return;
            }
            if (harga == null || harga < 0) {
              setState(() => _error = 'Harga disepakati belum diisi.');
              return;
            }
            if (harga > acuan) {
              setState(() => _error = 'Harga melebihi harga normal.');
              return;
            }
            if (_nego && _alasan.text.trim().isEmpty) {
              setState(() => _error = 'Alasan nego wajib diisi.');
              return;
            }
            if (qtyMilli > item.jumlahMilli) {
              setState(
                () => _error =
                    'Stok tidak cukup. Tersisa ${item.jumlahLabel}.',
              );
              return;
            }
            Navigator.pop(
              context,
              PartDraft(
                stockItemId: item.id,
                nama: item.nama,
                jumlah: qtyMilli ~/ 1000,
                qtyMilli: qtyMilli,
                hargaCents: harga,
                modalCents: item.hargaModalCents,
                intervalBulan: item.intervalBulan,
                hargaTerdaftarCents: acuan,
                alasanDiskon: _nego && _alasan.text.trim().isNotEmpty
                    ? _alasan.text.trim()
                    : null,
              ),
            );
          },
          child: const Text('Tambah sparepart'),
        ),
      ],
    );
  }
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.delegated});

  final bool delegated;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _secret = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label =
        widget.delegated ? 'PIN penanggung jawab' : 'PIN pemilik';
    return AlertDialog(
      title: const Text('Persetujuan diperlukan'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.delegated
                ? 'Transaksi ini memerlukan persetujuan penanggung jawab.'
                : 'Transaksi ini memerlukan persetujuan pemilik.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secret,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: label,
              helperText: widget.delegated
                  ? 'Minta penanggung jawab memasukkan PIN.'
                  : 'Masukkan PIN pemilik untuk menyetujui.',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Setujui')),
      ],
    );
  }

  void _submit() {
    final value = _secret.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Isi PIN terlebih dahulu.');
      return;
    }
    Navigator.pop(context, value);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
