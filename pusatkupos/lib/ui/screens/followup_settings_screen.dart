import 'package:flutter/material.dart';

import '../../data/followup_service.dart';
import '../widgets.dart';

class FollowupSettingsScreen extends StatefulWidget {
  const FollowupSettingsScreen({super.key});

  @override
  State<FollowupSettingsScreen> createState() => _FollowupSettingsScreenState();
}

class _FollowupSettingsScreenState extends State<FollowupSettingsScreen> {
  final _cooldown = TextEditingController();
  final _garansiHari = TextEditingController();
  final _garansiArsip = TextEditingController();
  final _servisAwal = TextEditingController();
  final _piutangJeda = TextEditingController();
  final _prospek1 = TextEditingController();
  final _prospek2 = TextEditingController();
  final _prospek3 = TextEditingController();
  final _belumBisa = TextEditingController();
  final _maksHari = TextEditingController();
  final _maksBulan = TextEditingController();
  final _jedaProspek = TextEditingController();
  final _maksTidakRespons = TextEditingController();
  final Map<TextEditingController, String> _errors = {};
  bool _aktif = true;
  String _jamMulai = '08:00';
  String _jamSelesai = '20:00';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _cooldown,
      _garansiHari,
      _garansiArsip,
      _servisAwal,
      _piutangJeda,
      _prospek1,
      _prospek2,
      _prospek3,
      _belumBisa,
      _maksHari,
      _maksBulan,
      _jedaProspek,
      _maksTidakRespons,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await FollowupService.instance.loadSettings();
    if (!mounted) return;
    setState(() {
      _aktif = settings.aktif;
      _jamMulai = settings.jamMulai;
      _jamSelesai = settings.jamSelesai;
      _errors.clear();
      _cooldown.text = '${settings.cooldownHari}';
      _garansiHari.text = '${settings.garansiAkanHabisHari}';
      _garansiArsip.text = '${settings.garansiArsipHari}';
      _servisAwal.text = '${settings.servisBerkalaAwalHari}';
      _piutangJeda.text = '${settings.piutangJedaHari}';
      _prospek1.text = '${settings.prospekHari1}';
      _prospek2.text = '${settings.prospekHari2}';
      _prospek3.text = '${settings.prospekHari3}';
      _belumBisa.text = '${settings.belumBisaHari}';
      _maksHari.text = '${settings.maksPesanHari}';
      _maksBulan.text = '${settings.maksPesanBulan}';
      _jedaProspek.text = '${settings.jedaProspekServisHari}';
      _maksTidakRespons.text = '${settings.maksTidakMerespons}';
      _loading = false;
    });
  }

  int? _parse(
    Map<TextEditingController, String> errors,
    TextEditingController controller,
    String label, {
    int min = 0,
    int max = 3650,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) {
      errors[controller] = '$label wajib diisi.';
      return null;
    }
    final value = int.tryParse(text);
    if (value == null) {
      errors[controller] = '$label harus berupa angka.';
      return null;
    }
    if (value < min) {
      errors[controller] = min == 0
          ? '$label tidak boleh negatif.'
          : '$label minimal $min.';
      return null;
    }
    if (value > max) {
      errors[controller] = '$label maksimal $max.';
      return null;
    }
    return value;
  }

  Future<void> _pickTime(bool start) async {
    final current = (start ? _jamMulai : _jamSelesai).split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(current.first) ?? 8,
        minute: int.tryParse(current.last) ?? 0,
      ),
      helpText: start ? 'Jam mulai pengingat' : 'Jam selesai pengingat',
    );
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (start) {
        _jamMulai = text;
      } else {
        _jamSelesai = text;
      }
    });
  }

  Future<void> _save() async {
    final errors = <TextEditingController, String>{};
    final cooldown = _parse(errors, _cooldown, 'Jeda tindak lanjut', min: 1);
    final maksHari = _parse(
      errors,
      _maksHari,
      'Batas pesan per hari',
      min: 1,
      max: 100,
    );
    final maksBulan = _parse(
      errors,
      _maksBulan,
      'Batas pesan per bulan',
      min: 1,
      max: 1000,
    );
    final jedaProspek = _parse(
      errors,
      _jedaProspek,
      'Jeda prospek setelah servis',
    );
    final maksTidakRespons = _parse(
      errors,
      _maksTidakRespons,
      'Jumlah tindak lanjut tanpa balasan',
      min: 1,
      max: 100,
    );
    final garansiHari = _parse(
      errors,
      _garansiHari,
      'Hari pengingat garansi',
    );
    final garansiArsip = _parse(
      errors,
      _garansiArsip,
      'Hari arsip garansi',
    );
    final servisAwal = _parse(
      errors,
      _servisAwal,
      'Hari tampil servis berkala',
    );
    final piutangJeda = _parse(
      errors,
      _piutangJeda,
      'Jeda pengingat piutang',
    );
    final prospek1 = _parse(errors, _prospek1, 'Prospek tahap 1', min: 1);
    final prospek2 = _parse(errors, _prospek2, 'Prospek tahap 2', min: 1);
    final prospek3 = _parse(errors, _prospek3, 'Prospek tahap 3', min: 1);
    final belumBisa = _parse(
      errors,
      _belumBisa,
      'Jeda setelah pelanggan masih terkendala',
      min: 1,
    );
    if (prospek1 != null &&
        prospek2 != null &&
        prospek3 != null &&
        !(prospek1 < prospek2 && prospek2 < prospek3)) {
      errors[_prospek3] =
          'Tahap 3 harus lebih besar dari tahap 2, dan tahap 2 dari tahap 1.';
    }
    if (errors.isNotEmpty) {
      setState(() {
        _errors
          ..clear()
          ..addAll(errors);
      });
      showSnack(context, 'Periksa kembali isian yang ditandai.', error: true);
      return;
    }
    setState(() {
      _errors.clear();
      _saving = true;
    });
    try {
      await FollowupService.instance.saveSettings(
        FollowupSettings(
          aktif: _aktif,
          jamMulai: _jamMulai,
          jamSelesai: _jamSelesai,
          cooldownHari: cooldown!,
          garansiAkanHabisHari: garansiHari!,
          garansiArsipHari: garansiArsip!,
          servisBerkalaAwalHari: servisAwal!,
          piutangJedaHari: piutangJeda!,
          prospekHari1: prospek1!,
          prospekHari2: prospek2!,
          prospekHari3: prospek3!,
          belumBisaHari: belumBisa!,
          maksPesanHari: maksHari!,
          maksPesanBulan: maksBulan!,
          jedaProspekServisHari: jedaProspek!,
          maksTidakMerespons: maksTidakRespons!,
        ),
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      showSnack(context, 'Pengaturan pengingat disimpan.');
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        'Pengaturan gagal disimpan: $error',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _number(
    String label,
    TextEditingController controller, {
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        onChanged: (_) {
          if (_errors.remove(controller) != null) setState(() {});
        },
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: _errors[controller],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan pengingat')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Status fitur',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pengingat pelanggan aktif'),
              subtitle: const Text(
                'Jika dimatikan, aplikasi berhenti membuat pengingat dan '
                'tautan WhatsApp.',
              ),
              value: _aktif,
              onChanged: (value) => setState(() => _aktif = value),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Jam dan batas pesan',
            subtitle: 'Memakai jam perangkat ini. Pengingat hanya dibuat '
                'dalam rentang jam tersebut.',
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Jam mulai'),
                  subtitle: const Text(
                    'Pengingat hanya dibuat setelah jam ini.',
                  ),
                  trailing: Text(_jamMulai),
                  onTap: () => _pickTime(true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Jam selesai'),
                  subtitle: const Text(
                    'Pengingat berhenti dibuat setelah jam ini.',
                  ),
                  trailing: Text(_jamSelesai),
                  onTap: () => _pickTime(false),
                ),
                _number(
                  'Jeda tindak lanjut (hari)',
                  _cooldown,
                  helper: 'Contoh: 7. Jarak hari sebelum pelanggan yang sama '
                      'boleh dihubungi lagi.',
                ),
                _number(
                  'Batas pesan per hari',
                  _maksHari,
                  helper: 'Contoh: 20. Batas pesan tindak lanjut per hari.',
                ),
                _number(
                  'Batas pesan prospek dan servis per bulan',
                  _maksBulan,
                  helper: 'Contoh: 200. Batas pesan prospek dan servis per '
                      'bulan.',
                ),
                _number(
                  'Jeda prospek setelah servis (hari)',
                  _jedaProspek,
                  helper: 'Contoh: 3. Jeda sebelum menawarkan servis '
                      'berikutnya.',
                ),
                _number(
                  'Arsip otomatis setelah tidak merespons',
                  _maksTidakRespons,
                  helper: 'Contoh: 3. Setelah 3 tindak lanjut tanpa balasan, '
                      'pelanggan diarsipkan.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Interval pengingat',
            subtitle: 'Jarak hari untuk setiap jenis pengingat. Isi angka '
                'hari, misalnya 7 untuk satu minggu.',
            child: Column(
              children: [
                _number(
                  'Pengingat garansi H- (hari)',
                  _garansiHari,
                  helper: 'Contoh: 7. Pengingat dibuat 7 hari sebelum garansi '
                      'berakhir.',
                ),
                _number(
                  'Arsip garansi setelah berakhir (hari)',
                  _garansiArsip,
                  helper: 'Contoh: 30. Garansi diarsipkan 30 hari setelah '
                      'berakhir.',
                ),
                _number(
                  'Servis berkala tampil sebelum jatuh tempo (hari)',
                  _servisAwal,
                  helper: 'Contoh: 14. Layanan servis muncul 14 hari sebelum '
                      'jatuh tempo.',
                ),
                _number(
                  'Jeda pengingat piutang (hari)',
                  _piutangJeda,
                  helper: 'Contoh: 7. Jarak hari antar pengingat piutang.',
                ),
                _number(
                  'Prospek tahap 1 (hari)',
                  _prospek1,
                  helper: 'Contoh: 3. Tindak lanjut pertama setelah pelanggan '
                      'tertarik.',
                ),
                _number(
                  'Prospek tahap 2 (hari)',
                  _prospek2,
                  helper: 'Contoh: 14. Tindak lanjut kedua bila belum ada '
                      'keputusan.',
                ),
                _number(
                  'Prospek tahap 3 (hari)',
                  _prospek3,
                  helper: 'Contoh: 30. Tindak lanjut terakhir sebelum '
                      'diarsipkan.',
                ),
                _number(
                  'Jeda setelah pelanggan masih terkendala (hari)',
                  _belumBisa,
                  helper: 'Contoh: 7. Jeda sebelum menghubungi lagi setelah '
                      'pelanggan masih terkendala.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan pengaturan'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
