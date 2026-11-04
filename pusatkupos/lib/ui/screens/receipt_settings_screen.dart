import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/receipt_settings.dart';
import '../widgets.dart';

class ReceiptSettingsScreen extends StatefulWidget {
  const ReceiptSettingsScreen({super.key});

  @override
  State<ReceiptSettingsScreen> createState() => _ReceiptSettingsScreenState();
}

class _ReceiptSettingsScreenState extends State<ReceiptSettingsScreen> {
  final _tagline = TextEditingController();
  final _kontak = TextEditingController();
  final _rekening = TextEditingController();
  final _footer = TextEditingController();
  Map<String, bool> _settings = {
    for (final key in receiptFields.keys) key: true,
  };
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tagline.dispose();
    _kontak.dispose();
    _rekening.dispose();
    _footer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final settings = await ReceiptSettings.instance.load();
    final values = await Future.wait([
      db.getSetting('bengkel.tagline'),
      db.getSetting('bengkel.telepon'),
      db.getSetting('bengkel.rekening'),
      db.getSetting('struk.footer'),
    ]);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _tagline.text = values[0] ?? '';
      _kontak.text = values[1] ?? '';
      _rekening.text = values[2] ?? '';
      _footer.text = values[3] ?? 'Terima kasih';
      _loading = false;
    });
  }

  Future<void> _saveTexts() async {
    final db = AppDatabase.instance;
    await db.setSetting('bengkel.tagline', _tagline.text.trim());
    await db.setSetting('bengkel.telepon', _kontak.text.trim());
    await db.setSetting('bengkel.rekening', _rekening.text.trim());
    await db.setSetting('struk.footer', _footer.text.trim());
    if (!mounted) return;
    showSnack(context, 'Teks struk disimpan.');
  }

  Future<void> _toggle(String key, bool value) async {
    setState(() => _settings = {..._settings, key: value});
    try {
      await ReceiptSettings.instance.save(key, value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _settings = {..._settings, key: !value});
      showSnack(context, 'Gagal menyimpan: $error', error: true);
    }
  }

  Widget _group(String title, List<String> keys) {
    return SectionCard(
      title: title,
      child: Column(
        children: keys
            .map(
              (key) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(receiptFields[key]!),
                value: _settings[key] ?? true,
                onChanged: (value) => _toggle(key, value),
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan struk')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: 'Teks tambahan',
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
                      const SizedBox(height: 10),
                      TextField(
                        controller: _rekening,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Rekening pembayaran',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _footer,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Footer struk',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _saveTexts,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Simpan teks'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _group('Kepala struk', const [
                  'tagline',
                  'alamat',
                  'kontak',
                ]),
                const SizedBox(height: 12),
                _group('Informasi nota', const [
                  'no_nota',
                  'tanggal',
                  'kasir',
                  'mekanik',
                  'pelanggan',
                  'hp',
                  'unit',
                  'keluhan',
                  'catatan',
                ]),
                const SizedBox(height: 12),
                _group('Rincian dan total', const [
                  'jasa',
                  'part',
                  'total_jasa',
                  'total_part',
                  'diskon',
                  'grand_total',
                  'metode',
                  'bayar',
                  'kembalian',
                  'status_bayar',
                ]),
                const SizedBox(height: 12),
                _group('Garansi dan penutup', const [
                  'garansi',
                  'rekening',
                  'footer',
                ]),
                const SizedBox(height: 20),
                Text(
                  'Perubahan langsung berlaku untuk cetak struk berikutnya.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
