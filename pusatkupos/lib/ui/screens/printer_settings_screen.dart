import 'package:flutter/material.dart';

import '../../printer/printer_config.dart';
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
  bool _busy = false;

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
      showSnack(context, 'Gagal menyimpan printer: $error', error: true);
    }
  }

  Future<void> _makePrimary(PrinterConfig printer) async {
    await _persist(
      _printers
          .map((item) => item.copyWith(utama: item.id == printer.id))
          .toList(),
    );
  }

  Future<void> _test(PrinterConfig printer) async {
    setState(() => _busy = true);
    final result = await PrinterService.instance.testPrint(printer);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, result.message, error: !result.ok);
  }

  Future<void> _delete(PrinterConfig printer) async {
    final ok = await confirmAction(
      context,
      title: 'Hapus printer',
      message: 'Hapus printer "${printer.nama}" dari daftar?',
      confirmLabel: 'Hapus',
    );
    if (!ok) return;
    await _persist(
      _printers.where((item) => item.id != printer.id).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Printer thermal')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading
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
                        'Tambahkan printer thermal jaringan (ESC/POS) dengan '
                        'alamat IP dan port, biasanya 9100.',
                  )
                else
                  ..._printers.map(
                    (printer) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SectionCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: Icon(
                            printer.utama
                                ? Icons.print
                                : Icons.print_outlined,
                          ),
                          title: Text(
                            printer.nama,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${printer.host}:${printer.port} · '
                            '${printer.paperMm} mm · '
                            '${printerModes[printer.mode] ?? printer.mode}'
                            '${printer.utama ? ' · utama' : ''}',
                          ),
                          trailing: PopupMenuButton<String>(
                            enabled: !_busy,
                            onSelected: (value) {
                              switch (value) {
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
                    ),
                  ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 12),
                Text(
                  'Printer thermal dihubungkan lewat jaringan lokal (port '
                  'mentah 9100). Data struk tidak dikirim ke internet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
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
  late final TextEditingController _host;
  late final TextEditingController _port;
  late int _paper;
  late String _mode;
  late bool _utama;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nama = TextEditingController(text: widget.initial.nama);
    _host = TextEditingController(text: widget.initial.host);
    _port = TextEditingController(text: '${widget.initial.port}');
    _paper = widget.initial.paperMm;
    _mode = widget.initial.mode;
    _utama = widget.initial.utama || widget.firstPrinter;
  }

  @override
  void dispose() {
    _nama.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      setState(() => _error = 'Port harus berupa angka.');
      return;
    }
    final printer = PrinterConfig(
      id: widget.initial.id,
      nama: _nama.text.trim(),
      host: _host.text.trim(),
      port: port,
      paperMm: _paper,
      mode: _mode,
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
    return AlertDialog(
      title: Text(widget.initial.nama.isEmpty ? 'Tambah printer' : 'Ubah printer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nama,
              decoration: const InputDecoration(labelText: 'Nama printer'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Alamat IP / host',
                hintText: '192.168.1.50',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: _paper,
              decoration: const InputDecoration(labelText: 'Ukuran kertas'),
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
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Mode cetak'),
              items: printerModes.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _mode = value ?? 'ESCPOS'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jadikan printer utama'),
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
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
