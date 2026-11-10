import 'package:flutter/material.dart';

import '../../printer/printer_adapter.dart';
import '../../printer/printer_config.dart';
import '../../printer/printer_device.dart';
import '../../printer/printer_manager.dart';
import '../../printer/printer_service.dart';
import '../widgets.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  List<PrinterConfig> _printers = const [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final printers = await PrinterStore.instance.load();
    if (!mounted) return;
    setState(() {
      _printers = printers;
      _loading = false;
    });
  }

  Future<void> _addOrEdit(PrinterConfig printer) async {
    final result = await showDialog<PrinterConfig>(
      context: context,
      builder: (context) => _PrinterDialog(
        initial: printer,
        firstPrinter: _printers.isEmpty,
      ),
    );
    if (result == null) return;
    final next = [..._printers];
    final index = next.indexWhere((item) => item.id == result.id);
    if (index >= 0) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _persist(next);
  }

  Future<void> _persist(List<PrinterConfig> printers) async {
    try {
      await PrinterStore.instance.saveAll(printers);
      await _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Printer gagal disimpan: $error', error: true);
    }
  }

  Future<void> _makePrimary(PrinterConfig printer) async {
    await _persist(
      _printers
          .map((item) => item.copyWith(utama: item.id == printer.id))
          .toList(),
    );
  }

  Future<void> _connect(PrinterConfig printer) async {
    setState(() => _busyId = printer.id);
    try {
      await PrinterManager.instance.connect(printer);
      if (!mounted) return;
      showSnack(context, 'Printer ${printer.nama} terhubung.');
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error is PrinterException
            ? error.message
            : 'Printer gagal dihubungkan: $error',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _disconnect(PrinterConfig printer) async {
    setState(() => _busyId = printer.id);
    try {
      await PrinterManager.instance.disconnect(printer);
      if (!mounted) return;
      showSnack(context, 'Printer ${printer.nama} diputus.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Gagal memutus printer: $error', error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _test(PrinterConfig printer) async {
    setState(() => _busyId = printer.id);
    try {
      if (printer.connectionType == 'BLUETOOTH' ||
          printer.connectionType == 'USB') {
        await PrinterManager.instance.connect(printer);
      }
      final result = await PrinterService.instance.testPrint(printer);
      if (!mounted) return;
      showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error is PrinterException
            ? error.message
            : 'Uji cetak gagal: $error',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _delete(PrinterConfig printer) async {
    final ok = await confirmAction(
      context,
      title: 'Hapus printer',
      message: 'Printer "${printer.nama}" akan dihapus dari daftar perangkat '
          'ini. Printer lain tetap bisa dipakai.',
      confirmLabel: 'Hapus printer',
    );
    if (!ok) return;
    await PrinterManager.instance.disconnect(printer).catchError((_) {});
    PrinterManager.instance.forget(printer.id);
    await _persist(
      _printers.where((item) => item.id != printer.id).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Printer')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading || _printers.length >= maxPrinters
            ? null
            : () => _addOrEdit(PrinterConfig.draft()),
        icon: const Icon(Icons.add),
        label: const Text('Tambah printer'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                if (_printers.isEmpty)
                  const EmptyState(
                    icon: Icons.print_outlined,
                    title: 'Belum ada printer',
                    subtitle:
                        'Tambahkan printer kasir lewat Bluetooth, Wi-Fi/LAN, '
                        'USB OTG, atau cetak lewat layanan Android. Setelah '
                        'tersimpan, coba Uji cetak.',
                  )
                else
                  ..._printers.map(_printerCard),
                if (_printers.length >= maxPrinters) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Maksimal $maxPrinters printer. Hapus salah satu untuk '
                    'menambah printer baru.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Alamat printer disimpan di perangkat ini dan tidak ikut '
                  'cadangan atau sinkronisasi. Setiap perangkat yang mencetak '
                  'perlu mengatur printer sendiri.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }

  Widget _printerCard(PrinterConfig printer) {
    final runtime = PrinterManager.instance.statusOf(printer);
    final busy = _busyId == printer.id;
    final connected = runtime.status == 'CONNECTED';
    final subtitle = [
      '${printer.typeLabel} · ${printer.targetLabel}',
      '${printer.paperMm} mm · ${printerModes[printer.mode] ?? printer.mode}',
      if (printer.connectionType == 'BLUETOOTH')
        bluetoothTransports[printer.transport] ?? printer.transport,
      if (printer.utama) 'utama',
      _statusLabel(runtime.status),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ListTile(
          leading: Icon(
            printer.utama ? Icons.print : Icons.print_outlined,
            color: connected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(
            printer.nama,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            runtime.message.isEmpty ? subtitle : '$subtitle\n${runtime.message}',
          ),
          isThreeLine: runtime.message.isNotEmpty,
          trailing: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'hubungkan':
                        _connect(printer);
                        break;
                      case 'putus':
                        _disconnect(printer);
                        break;
                      case 'utama':
                        _makePrimary(printer);
                        break;
                      case 'tes':
                        _test(printer);
                        break;
                      case 'ubah':
                        _addOrEdit(printer);
                        break;
                      case 'hapus':
                        _delete(printer);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    if (_canConnect(printer) && !connected)
                      const PopupMenuItem(
                        value: 'hubungkan',
                        child: Text('Hubungkan'),
                      ),
                    if (connected)
                      const PopupMenuItem(
                        value: 'putus',
                        child: Text('Putuskan'),
                      ),
                    if (!printer.utama)
                      const PopupMenuItem(
                        value: 'utama',
                        child: Text('Jadikan utama'),
                      ),
                    const PopupMenuItem(
                      value: 'tes',
                      child: Text('Uji cetak'),
                    ),
                    const PopupMenuItem(
                      value: 'ubah',
                      child: Text('Ubah'),
                    ),
                    const PopupMenuItem(
                      value: 'hapus',
                      child: Text('Hapus'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  bool _canConnect(PrinterConfig printer) =>
      printer.connectionType == 'BLUETOOTH' ||
      printer.connectionType == 'USB';

  String _statusLabel(String status) {
    switch (status) {
      case 'CONNECTED':
        return 'terhubung';
      case 'CONNECTING':
        return 'menghubungkan';
      case 'ERROR':
        return 'bermasalah';
      case 'UNAVAILABLE':
        return 'tidak tersedia';
      default:
        return 'tersimpan';
    }
  }
}

class _PrinterDialog extends StatefulWidget {
  const _PrinterDialog({required this.initial, required this.firstPrinter});

  final PrinterConfig initial;
  final bool firstPrinter;

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  late final TextEditingController _nama;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late String _type;
  late String _transport;
  late int _paper;
  late String _mode;
  late bool _utama;
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nama = TextEditingController(text: initial.nama);
    _address = TextEditingController(text: _addressOf(initial));
    _port = TextEditingController(text: '${initial.port ?? 9100}');
    _type = initial.connectionType;
    _transport = initial.transport.isEmpty ? 'SPP' : initial.transport;
    _paper = initial.paperMm;
    _mode = initial.mode;
    _utama = initial.utama || widget.firstPrinter;
  }

  String _addressOf(PrinterConfig printer) {
    switch (printer.connectionType) {
      case 'NETWORK':
        return printer.ip;
      case 'BLUETOOTH':
      case 'USB':
        return printer.address;
      default:
        return '';
    }
  }

  @override
  void dispose() {
    _nama.dispose();
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  List<String> get _allowedModes =>
      (printerAllowedModes[_type] ?? const {'ESCPOS'}).toList();

  bool get _needsAddress => _type == 'BLUETOOTH' || _type == 'USB';
  bool get _isNetwork => _type == 'NETWORK';

  void _changeType(String type) {
    setState(() {
      _type = type;
      _address.clear();
      _error = null;
      _transport = type == 'BLUETOOTH' ? 'SPP' : '';
      _mode = printerDefaultModes[type] ?? 'ESCPOS';
      if (type == 'NETWORK') _port.text = '9100';
    });
  }

  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final devices = await PrinterManager.instance.discover(
        _type,
        transport: _type == 'BLUETOOTH' ? _transport : '',
      );
      if (!mounted) return;
      setState(() => _scanning = false);
      if (devices.isEmpty) {
        setState(() {
          _error = 'Printer tidak ditemukan. Pastikan printer menyala, sudah '
              'dipasangkan, dan berada dekat perangkat ini.';
        });
        return;
      }
      final picked = await showDialog<PrinterDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pilih printer'),
          content: SizedBox(
            width: 340,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  enabled: device.supported,
                  title: Text(device.name),
                  subtitle: Text(device.label),
                  onTap: () => Navigator.pop(context, device),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _address.text = picked.address;
        if (_isNetwork) {
          final port = RegExp(r'Port (\d+)').firstMatch(picked.detail)?.group(1);
          if (port != null) _port.text = port;
        }
        if (picked.transport.isNotEmpty) _transport = picked.transport;
        if (_nama.text.trim().isEmpty) _nama.text = picked.name;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = error is PrinterException
            ? error.message
            : 'Pencarian printer gagal: $error';
      });
    }
  }

  void _submit() {
    final int? port = _isNetwork ? int.tryParse(_port.text.trim()) : null;
    if (_isNetwork && port == null) {
      setState(
        () => _error = 'Port harus berupa angka, misalnya 9100.',
      );
      return;
    }
    final printer = PrinterConfig(
      id: widget.initial.id,
      nama: _nama.text.trim(),
      connectionType: _type,
      address: _needsAddress ? _address.text.trim() : '',
      ip: _isNetwork ? _address.text.trim() : '',
      port: port,
      paperMm: _paper,
      encoding: widget.initial.encoding,
      mode: _mode,
      transport: _transport,
      utama: _utama,
    );
    try {
      printer.validate();
    } on ArgumentError catch (error) {
      setState(() => _error = '${error.message}');
      return;
    }
    Navigator.pop(context, printer);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.initial.nama.isEmpty ? 'Tambah printer' : 'Ubah printer';
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nama,
              decoration: const InputDecoration(
                labelText: 'Nama printer',
                hintText: 'Contoh: Printer Kasir',
                helperText: 'Nama ini hanya tampil di pengaturan printer.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Jenis koneksi',
                helperText: 'Pilih cara printer tersambung ke perangkat ini.',
              ),
              items: printerTypes.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) _changeType(value);
              },
            ),
            if (_type == 'BLUETOOTH') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('transport-$_transport'),
                initialValue: _transport,
                decoration: const InputDecoration(
                  labelText: 'Jenis Bluetooth',
                  helperText: 'Bluetooth Classic untuk printer kasir umum. '
                      'Pilih Bluetooth LE bila printer hanya mendukung BLE.',
                ),
                items: bluetoothTransports.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _transport = value ?? 'SPP'),
              ),
            ],
            if (_needsAddress || _isNetwork) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      decoration: InputDecoration(
                        labelText: _isNetwork
                            ? 'Alamat IP'
                            : _type == 'USB'
                                ? 'Identitas USB'
                                : 'Alamat Bluetooth',
                        hintText: _isNetwork
                            ? 'Contoh: 192.168.1.50'
                            : _type == 'USB'
                                ? 'Contoh: usb:0416:5011'
                                : 'Contoh: AA:BB:CC:DD:EE:FF',
                        helperText: _isNetwork
                            ? 'Lihat alamat ini di menu jaringan printer.'
                            : 'Tekan Cari printer untuk memilih dari daftar.',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton(
                      onPressed: _scanning ? null : _discover,
                      child: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Cari printer'),
                    ),
                  ),
                ],
              ),
            ],
            if (_isNetwork) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: 'Contoh: 9100',
                  helperText: 'Port jaringan printer. Umumnya 9100.',
                ),
              ),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: _paper,
              decoration: const InputDecoration(
                labelText: 'Ukuran kertas',
                helperText: 'Pilih sesuai lebar kertas struk yang dipakai.',
              ),
              items: printerPapers.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _paper = value ?? 58),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey('mode-$_type'),
              initialValue: _allowedModes.contains(_mode)
                  ? _mode
                  : _allowedModes.first,
              decoration: const InputDecoration(
                labelText: 'Mode cetak',
                helperText: 'ESC/POS untuk printer struk. Pilih Teks biasa '
                    'bila hasil cetak berantakan.',
              ),
              items: _allowedModes
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(printerModes[value] ?? value),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _mode = value ?? _allowedModes.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jadikan printer utama'),
              subtitle: const Text(
                'Printer utama dipakai otomatis saat mencetak struk.',
              ),
              value: _utama,
              onChanged: (value) => setState(() => _utama = value),
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
          onPressed: _submit,
          child: const Text('Simpan printer'),
        ),
      ],
    );
  }
}
