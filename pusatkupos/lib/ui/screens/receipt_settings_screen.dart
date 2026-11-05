import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/backup_platform.dart' as platform;
import '../../data/receipt_service.dart';
import '../../data/receipt_settings.dart';
import '../../data/receipt_template.dart';
import '../../printer/logo_platform.dart';
import '../../printer/printer_config.dart';
import '../../printer/printer_service.dart';
import '../../printer/receipt_builder.dart';
import '../widgets.dart';

class ReceiptSettingsScreen extends StatefulWidget {
  const ReceiptSettingsScreen({super.key});

  @override
  State<ReceiptSettingsScreen> createState() => _ReceiptSettingsScreenState();
}

class _LineEditor {
  _LineEditor({
    String text = '',
    this.align = ReceiptAlign.center,
    this.bold = false,
  }) : controller = TextEditingController(text: text);

  final TextEditingController controller;
  ReceiptAlign align;
  bool bold;

  void dispose() => controller.dispose();
}

class _ReceiptSettingsScreenState extends State<ReceiptSettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _tagline = TextEditingController();
  final _kontak = TextEditingController();
  final _footer = TextEditingController();
  final _bankNama = TextEditingController();
  final _bankNomor = TextEditingController();
  final _bankAtasNama = TextEditingController();
  final _bankCatatan = TextEditingController();
  final _warrantyNote = TextEditingController();
  final _signature = TextEditingController();
  final Map<String, TextEditingController> _labels = {};
  final List<_LineEditor> _headerExtra = [];
  final List<_LineEditor> _footerExtra = [];

  ReceiptTemplate _template = ReceiptTemplate.defaults();
  ReceiptDocument? _preview;
  String? _previewError;
  int? _previewWidth;
  bool _loading = true;
  bool _saving = false;
  bool _previewBusy = false;
  String? _validation;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this)
      ..addListener(_onTabChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    for (final controller in [
      _tagline,
      _kontak,
      _footer,
      _bankNama,
      _bankNomor,
      _bankAtasNama,
      _bankCatatan,
      _warrantyNote,
      _signature,
      ..._labels.values,
      for (final editor in _headerExtra) editor.controller,
      for (final editor in _footerExtra) editor.controller,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    if (_tabs.index == 5) _refreshPreview();
  }

  Future<void> _load() async {
    final template = await ReceiptSettings.instance.load();
    final db = AppDatabase.instance;
    final tagline = await db.getSetting('bengkel.tagline') ?? '';
    final kontak = await db.getSetting('bengkel.telepon') ?? '';
    if (!mounted) return;
    setState(() {
      _template = template;
      _tagline.text = tagline;
      _kontak.text = kontak;
      _applyControllers();
      _loading = false;
    });
    _refreshPreview();
  }

  void _applyControllers() {
    _footer.text = _template.footerLines.join('\n');
    _bankNama.text = _template.bankNama;
    _bankNomor.text = _template.noRekening;
    _bankAtasNama.text = _template.atasNama;
    _bankCatatan.text = _template.bankCatatan;
    _warrantyNote.text = _template.warrantyNote;
    _signature.text = _template.signature;
    for (final key in receiptDefaultLabels.keys) {
      final text = _template.label(key);
      final existing = _labels[key];
      if (existing == null) {
        _labels[key] = TextEditingController(text: text);
      } else {
        existing.text = text;
      }
    }
    _syncEditors(_headerExtra, _template.headerExtra);
    _syncEditors(_footerExtra, _template.footerExtra);
  }

  /// Menyamakan editor dengan daftar baris tanpa membuang controller yang
  /// masih menempel pada `TextField` yang sedang tampil.
  void _syncEditors(List<_LineEditor> editors, List<ReceiptTextLine> lines) {
    while (editors.length > lines.length) {
      final removed = editors.removeLast();
      _disposeLater(removed.controller);
    }
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (index < editors.length) {
        final editor = editors[index];
        editor.controller.text = line.text;
        editor.align = line.align;
        editor.bold = line.bold;
      } else {
        editors.add(
          _LineEditor(text: line.text, align: line.align, bold: line.bold),
        );
      }
    }
  }

  void _disposeLater(TextEditingController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  void _collectTemplate() {
    _template.footerLines = _footer.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    _template.bankNama = _bankNama.text.trim();
    _template.noRekening = _bankNomor.text.trim();
    _template.atasNama = _bankAtasNama.text.trim();
    _template.bankCatatan = _bankCatatan.text.trim();
    _template.warrantyNote = _warrantyNote.text.trim();
    _template.signature = _signature.text.trim();
    for (final entry in _labels.entries) {
      final text = entry.value.text.trim();
      _template.labels[entry.key] =
          text.isEmpty ? receiptDefaultLabels[entry.key]! : text;
    }
    _template.headerExtra = _headerExtra
        .where((editor) => editor.controller.text.trim().isNotEmpty)
        .map(
          (editor) => ReceiptTextLine(
            editor.controller.text.trim(),
            align: editor.align,
            bold: editor.bold,
          ),
        )
        .toList();
    _template.footerExtra = _footerExtra
        .where((editor) => editor.controller.text.trim().isNotEmpty)
        .map(
          (editor) => ReceiptTextLine(
            editor.controller.text.trim(),
            align: editor.align,
            bold: editor.bold,
          ),
        )
        .toList();
  }

  int get _columns => _previewWidth ?? _template.width;

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      String? validation;
      try {
        _collectTemplate();
        _template.validate();
      } catch (error) {
        validation = '$error';
      }
      setState(() => _validation = validation);
      if (_tabs.index == 5) _refreshPreview();
    });
  }

  Future<void> _refreshPreview() async {
    if (!mounted) return;
    String? validation;
    try {
      _collectTemplate();
      _template.validate();
    } catch (error) {
      validation = '$error';
    }
    setState(() {
      _validation = validation;
      _previewBusy = true;
      _previewError = null;
    });
    if (validation != null) {
      setState(() => _previewBusy = false);
      return;
    }
    try {
      final document = await ReceiptService.instance.sample(
        template: _template,
        width: _columns,
      );
      if (!mounted) return;
      setState(() {
        _preview = document;
        _previewBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewError = '$error';
        _previewBusy = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _collectTemplate();
      _template.validate();
      await ReceiptSettings.instance.save(_template);
      await AppDatabase.instance
          .setSetting('bengkel.tagline', _tagline.text.trim());
      await AppDatabase.instance
          .setSetting('bengkel.telepon', _kontak.text.trim());
      if (!mounted) return;
      showSnack(context, 'Template struk disimpan.');
      await _refreshPreview();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Gagal menyimpan: $error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset template struk?',
      message: 'Semua pengaturan tampilan struk kembali ke default. '
          'Nama toko dan alamat tidak diubah.',
      confirmLabel: 'Reset',
    );
    if (confirmed != true) return;
    setState(() {
      _template = ReceiptTemplate.defaults();
      _applyControllers();
    });
    try {
      await ReceiptSettings.instance.save(_template);
      if (!mounted) return;
      showSnack(context, 'Template struk direset.');
      await _refreshPreview();
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mereset: $error', error: true);
      }
    }
  }

  Future<void> _printTest() async {
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
    try {
      _collectTemplate();
      final document = await ReceiptService.instance.sample(
        template: _template,
        width: printer.width,
      );
      final result =
          await PrinterService.instance.printReceipt(document, printer: printer);
      if (mounted) showSnack(context, result.message, error: !result.ok);
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mencetak: $error', error: true);
      }
    }
  }

  Future<void> _pickLogo() async {
    if (kIsWeb) {
      showSnack(
        context,
        'Logo struk tersedia di aplikasi Android/desktop.',
        error: true,
      );
      return;
    }
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Pilih logo struk',
        type: FileType.image,
      );
      final path = picked?.path ?? '';
      if (path.isEmpty) return;
      setState(() => _template.logoPath = path);
      _schedulePreview();
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal memilih logo: $error', error: true);
      }
    }
  }

  Future<void> _exportTemplate() async {
    if (kIsWeb) {
      showSnack(
        context,
        'Ekspor template tersedia di aplikasi Android/desktop.',
        error: true,
      );
      return;
    }
    try {
      _collectTemplate();
      _template.validate();
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(_template.toJson()),
      );
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Simpan template struk',
        fileName: 'template-struk-$stamp.json',
        bytes: bytes,
        mimeType: 'application/json',
      );
      if (uri == null) return;
      if (mounted) showSnack(context, 'Template struk diekspor.');
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mengekspor template: $error', error: true);
      }
    }
  }

  Future<void> _importTemplate() async {
    if (kIsWeb) {
      showSnack(
        context,
        'Impor template tersedia di aplikasi Android/desktop.',
        error: true,
      );
      return;
    }
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Pilih template struk',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = picked?.path ?? '';
      if (path.isEmpty) return;
      final raw = utf8.decode(await platform.readFile(path));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Isi file bukan objek JSON.');
      }
      final map = Map<String, Object?>.from(decoded);
      if (map['version'] != 2) {
        throw const FormatException('Versi template tidak didukung.');
      }
      final imported = ReceiptTemplate.fromJson(map)..validate();
      setState(() {
        _template = imported;
        _validation = null;
        _previewWidth = null;
        _preview = null;
        _previewError = null;
        _applyControllers();
      });
      await _refreshPreview();
      if (mounted) {
        showSnack(
          context,
          'Template dimuat. Tekan Simpan untuk menerapkan.',
        );
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Gagal mengimpor template: $error', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pengaturan struk'),
        bottom: _loading
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Tampilan'),
                  Tab(text: 'Kepala'),
                  Tab(text: 'Isi'),
                  Tab(text: 'Pembayaran'),
                  Tab(text: 'Penutup'),
                  Tab(text: 'Pratinjau'),
                ],
              ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Template JSON',
            enabled: !_loading,
            onSelected: (value) {
              if (value == 'export') _exportTemplate();
              if (value == 'import') _importTemplate();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Ekspor template')),
              PopupMenuItem(value: 'import', child: Text('Impor template')),
            ],
          ),
          IconButton(
            tooltip: 'Reset',
            onPressed: _loading ? null : _reset,
            icon: const Icon(Icons.restart_alt),
          ),
          IconButton(
            tooltip: 'Simpan',
            onPressed: _loading || _saving || _validation != null
                ? null
                : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_validation != null)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      _validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _appearanceTab(),
                      _headerTab(),
                      _contentTab(),
                      _paymentTab(),
                      _closingTab(),
                      _previewTab(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _switch(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: (next) {
        setState(() => onChanged(next));
        _schedulePreview();
      },
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<T>(
        key: ValueKey('$label-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: items.entries
            .map(
              (entry) => DropdownMenuItem<T>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(),
        onChanged: (next) {
          if (next != null) {
            setState(() => onChanged(next));
            _schedulePreview();
          }
        },
      ),
    );
  }

  Widget _appearanceTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Kertas dan salinan',
          subtitle: 'Printer tetap menentukan lebar akhir saat mencetak.',
          child: Column(
            children: [
              _dropdown<int>(
                label: 'Lebar kertas default',
                value: _template.paperWidth,
                items: const {58: '58 mm (32 kolom)', 80: '80 mm (48 kolom)'},
                onChanged: (value) {
                  _template.paperWidth = value;
                  _previewWidth = null;
                },
              ),
              _dropdown<int>(
                label: 'Jumlah salinan',
                value: _template.copies,
                items: const {1: '1 salinan', 2: '2 salinan', 3: '3 salinan'},
                onChanged: (value) => _template.copies = value,
              ),
              _dropdown<int>(
                label: 'Baris kosong sebelum potong',
                value: _template.blankLines,
                items: {
                  for (var i = 0; i <= 5; i++) i: '$i baris',
                },
                onChanged: (value) => _template.blankLines = value,
              ),
              _dropdown<String>(
                label: 'Codepage printer',
                value: _template.codepage,
                items: receiptCodepages,
                onChanged: (value) => _template.codepage = value,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Penanda',
          child: Column(
            children: [
              _switch(
                'Tampilkan banner VOID',
                _template.voidBanner,
                (value) => _template.voidBanner = value,
                subtitle: 'Banner dan alasan tampil pada nota yang dibatalkan.',
              ),
              _switch(
                'Tampilkan banner pelunasan',
                _template.pelunasanBanner,
                (value) => _template.pelunasanBanner = value,
                subtitle: 'Muncul saat sisa pembayaran lunas.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Identitas di struk',
          subtitle:
              'Nama toko dan alamat diatur di Pengaturan › Identitas toko.',
          child: Column(
            children: [
              TextField(
                controller: _tagline,
                decoration: const InputDecoration(labelText: 'Tagline'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _kontak,
                decoration: const InputDecoration(
                  labelText: 'Telepon / WhatsApp',
                ),
              ),
              const SizedBox(height: 8),
              _switch(
                'Tampilkan tagline',
                _template.showTagline,
                (value) => _template.showTagline = value,
              ),
              _switch(
                'Tampilkan alamat',
                _template.showAlamat,
                (value) => _template.showAlamat = value,
              ),
              _switch(
                'Tampilkan kontak',
                _template.showKontak,
                (value) => _template.showKontak = value,
              ),
              _switch(
                'Nama toko tebal',
                _template.headerBold,
                (value) => _template.headerBold = value,
              ),
              _switch(
                'Nama toko huruf ganda',
                _template.headerDouble,
                (value) => _template.headerDouble = value,
                subtitle: 'Otomatis normal bila nama terlalu panjang.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Logo struk',
          subtitle: 'Logo dicetak sebagai gambar raster di atas kepala struk.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_template.logoPath.trim().isNotEmpty)
                FutureBuilder<List<int>?>(
                  future: readLogoBytes(_template.logoPath),
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes == null || bytes.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Logo tidak dapat dibaca. Pilih ulang.'),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Center(
                        child: Image.memory(
                          Uint8List.fromList(bytes),
                          height: 72,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    );
                  },
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickLogo,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(
                        _template.logoPath.trim().isEmpty
                            ? 'Pilih logo'
                            : 'Ganti logo',
                      ),
                    ),
                  ),
                  if (_template.logoPath.trim().isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        setState(() => _template.logoPath = '');
                        _schedulePreview();
                      },
                      child: const Text('Hapus'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text('Lebar logo: ${_template.logoWidthMm} mm'),
              Slider(
                value: _template.logoWidthMm.toDouble(),
                min: 10,
                max: 40,
                divisions: 30,
                label: '${_template.logoWidthMm} mm',
                onChanged: (value) {
                  setState(() => _template.logoWidthMm = value.round());
                  _schedulePreview();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _lineCard(
          title: 'Baris tambahan kepala',
          subtitle: 'Maksimal 5 baris, 80 karakter per baris.',
          editors: _headerExtra,
        ),
      ],
    );
  }

  Widget _contentTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Urutan bagian',
          subtitle: 'Atur urutan blok yang tampil pada struk.',
          child: Column(
            children: [
              for (var i = 0; i < _template.blockOrder.length; i++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    receiptBlockNames[_template.blockOrder[i]] ??
                        _template.blockOrder[i],
                  ),
                  leading: Switch(
                    value: _template.visible(_template.blockOrder[i]),
                    onChanged: (value) => setState(
                      () => _template.blockVisible[_template.blockOrder[i]] =
                          value,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: i == 0 ? null : () => _moveBlock(i, -1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: i == _template.blockOrder.length - 1
                            ? null
                            : () => _moveBlock(i, 1),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Informasi nota',
          child: Column(
            children: [
              for (final entry in receiptMetaFields.entries)
                _switch(
                  entry.value,
                  _template.metaFields[entry.key] ?? true,
                  (value) => _template.metaFields[entry.key] = value,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Rincian jasa dan part',
          child: Column(
            children: [
              _switch(
                'Tampilkan jasa',
                _template.showJasa,
                (value) => _template.showJasa = value,
              ),
              _switch(
                'Tampilkan sparepart',
                _template.showPart,
                (value) => _template.showPart = value,
              ),
              _switch(
                'Garis pemisah setelah rincian',
                _template.itemsDivider,
                (value) => _template.itemsDivider = value,
              ),
              _switch(
                'Diskon per baris',
                _template.showLineDiscount,
                (value) => _template.showLineDiscount = value,
                subtitle: 'Tampilkan potongan diskon di bawah baris yang '
                    'mendapat diskon.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Total pembayaran',
          child: Column(
            children: [
              for (final entry in receiptTotalFields.entries)
                _switch(
                  entry.value,
                  _template.totalFields[entry.key] ?? true,
                  (value) => _template.totalFields[entry.key] = value,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Label',
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Ubah teks label'),
            children: [
              for (final entry in receiptDefaultLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _labels[entry.key],
                    maxLength: ReceiptTemplate.maxLabelLength,
                    onChanged: (_) {
                      setState(() {});
                      _schedulePreview();
                    },
                    decoration: InputDecoration(
                      labelText: entry.value,
                      counterText: '',
                      errorText:
                          (_labels[entry.key]?.text.trim().isEmpty ?? true)
                              ? 'Label wajib diisi'
                              : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _moveBlock(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _template.blockOrder.length) return;
    setState(() {
      final order = _template.blockOrder;
      final value = order.removeAt(index);
      order.insert(target, value);
    });
  }

  Widget _paymentTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Riwayat pembayaran',
          child: Column(
            children: [
              _switch(
                'Tampilkan riwayat pembayaran',
                _template.paymentShowHistory,
                (value) => _template.paymentShowHistory = value,
                subtitle: 'Muncul bila ada lebih dari satu pembayaran atau DP.',
              ),
              _switch(
                'Tampilkan sisa pembayaran',
                _template.paymentShowSisa,
                (value) => _template.paymentShowSisa = value,
                subtitle: 'Untuk nota yang belum lunas.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Rekening bank',
          subtitle: 'Kosongkan semua isian untuk menyembunyikan rekening.',
          child: Column(
            children: [
              TextField(
                controller: _bankNama,
                onChanged: (_) => _schedulePreview(),
                decoration: const InputDecoration(labelText: 'Nama bank'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bankNomor,
                onChanged: (_) => _schedulePreview(),
                decoration: const InputDecoration(labelText: 'Nomor rekening'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bankAtasNama,
                onChanged: (_) => _schedulePreview(),
                decoration: const InputDecoration(labelText: 'Atas nama'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bankCatatan,
                maxLines: 2,
                onChanged: (_) => _schedulePreview(),
                decoration: const InputDecoration(
                  labelText: 'Catatan rekening (opsional)',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _closingTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Footer struk',
          subtitle: 'Satu baris teks per baris struk.',
          child: TextField(
            controller: _footer,
            maxLines: 4,
            onChanged: (_) => _schedulePreview(),
            decoration: const InputDecoration(
              labelText: 'Teks penutup',
              helperText: 'Contoh: Simpan struk ini sebagai bukti garansi.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        _lineCard(
          title: 'Baris tambahan penutup',
          subtitle: 'Maksimal 5 baris, 80 karakter per baris.',
          editors: _footerExtra,
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Garansi',
          child: Column(
            children: [
              _switch(
                'Tampilkan masa garansi',
                _template.warrantyShowStatus,
                (value) => _template.warrantyShowStatus = value,
              ),
              _switch(
                'Tampilkan catatan garansi',
                _template.warrantyShowNote,
                (value) => _template.warrantyShowNote = value,
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _warrantyNote,
                maxLines: 2,
                onChanged: (_) => _schedulePreview(),
                decoration: const InputDecoration(
                  labelText: 'Catatan garansi tambahan',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Tanda tangan',
          child: TextField(
            controller: _signature,
            onChanged: (_) => _schedulePreview(),
            decoration: const InputDecoration(
              labelText: 'Teks tanda tangan (opsional)',
              helperText: 'Contoh: Hormat kami, Andi.',
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineCard({
    required String title,
    required String subtitle,
    required List<_LineEditor> editors,
  }) {
    return SectionCard(
      title: title,
      subtitle: subtitle,
      trailing: IconButton(
        tooltip: 'Tambah baris',
        onPressed: editors.length >= ReceiptTemplate.maxCustomLines
            ? null
            : () => setState(() => editors.add(_LineEditor())),
        icon: const Icon(Icons.add),
      ),
      child: Column(
        children: [
          for (var index = 0; index < editors.length; index++)
            _lineEditorRow(editors, index),
          if (editors.isEmpty)
            const Text('Belum ada baris tambahan.', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _lineEditorRow(List<_LineEditor> editors, int index) {
    final editor = editors[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: editor.controller,
            maxLength: ReceiptTemplate.maxCustomLineLength,
            onChanged: (_) => _schedulePreview(),
            decoration: InputDecoration(
              labelText: 'Baris ${index + 1}',
              counterText: '',
            ),
          ),
          Row(
            children: [
              DropdownButton<ReceiptAlign>(
                value: editor.align,
                items: const [
                  DropdownMenuItem(
                    value: ReceiptAlign.left,
                    child: Text('Kiri'),
                  ),
                  DropdownMenuItem(
                    value: ReceiptAlign.center,
                    child: Text('Tengah'),
                  ),
                  DropdownMenuItem(
                    value: ReceiptAlign.right,
                    child: Text('Kanan'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => editor.align = value);
                },
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Tebal'),
                selected: editor.bold,
                onSelected: (value) => setState(() => editor.bold = value),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Hapus baris',
                onPressed: () => setState(() {
                  _disposeLater(editors.removeAt(index).controller);
                }),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Pratinjau',
          subtitle: 'Contoh nota memakai template yang sedang diedit.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 32, label: Text('58 mm')),
                  ButtonSegment(value: 48, label: Text('80 mm')),
                ],
                selected: {_columns},
                onSelectionChanged: (value) {
                  setState(() => _previewWidth = value.first);
                  _refreshPreview();
                },
              ),
              const SizedBox(height: 10),
              if (_previewBusy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_previewError != null)
                Text('Pratinjau gagal: $_previewError')
              else if (_preview != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in _preview!.lines)
                          Text(
                            line.text.isEmpty ? ' ' : line.text,
                            textAlign: switch (line.align) {
                              ReceiptAlign.center => TextAlign.center,
                              ReceiptAlign.right => TextAlign.right,
                              ReceiptAlign.left => TextAlign.left,
                            },
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: line.double ? 13 : 11,
                              height: 1.3,
                              color: Colors.black87,
                              fontWeight:
                                  line.bold ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _previewBusy ? null : _refreshPreview,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Muat ulang'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _previewBusy ? null : _printTest,
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Cetak tes'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
