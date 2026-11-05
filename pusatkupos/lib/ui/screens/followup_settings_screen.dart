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
      helpText: start ? 'Jam mulai follow up' : 'Jam selesai follow up',
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
    final cooldown = _parse(errors, _cooldown, 'Jeda follow up', min: 1);
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
      'Arsip otomatis setelah tidak merespons',
      min: 1,
      max: 100,
    );
    final garansiHari = _parse(
      errors,
      _garansiHari,
      'Garansi diingatkan H-',
    );
    final garansiArsip = _parse(
      errors,
      _garansiArsip,
      'Arsip garansi setelah berakhir',
    );
    final servisAwal = _parse(
      errors,
      _servisAwal,
      'Servis berkala tampil sebelum jatuh tempo',
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
      'Tunda setelah masih kendala',
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
      showSnack(context, 'Pengaturan follow up disimpan.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, 'Gagal menyimpan: $error', error: true);
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
      appBar: AppBar(title: const Text('Pengaturan follow up')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Jalankan fitur',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Follow up aktif'),
              subtitle: const Text(
                'Jika dimatikan, pengingat tidak dibuat dan tautan WhatsApp '
                'tidak dapat dibuat.',
              ),
              value: _aktif,
              onChanged: (value) => setState(() => _aktif = value),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Jam dan batas pesan',
            subtitle: 'Mengikuti waktu perangkat toko.',
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Jam mulai'),
                  trailing: Text(_jamMulai),
                  onTap: () => _pickTime(true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Jam selesai'),
                  trailing: Text(_jamSelesai),
                  onTap: () => _pickTime(false),
                ),
                _number('Jeda follow up (hari)', _cooldown),
                _number('Batas pesan per hari', _maksHari),
                _number(
                  'Batas pesan prospek/servis per bulan',
                  _maksBulan,
                ),
                _number(
                  'Jeda prospek setelah servis (hari)',
                  _jedaProspek,
                ),
                _number(
                  'Arsip otomatis setelah tidak merespons',
                  _maksTidakRespons,
                  helper: 'Jumlah follow up tanpa balasan.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Interval pengingat',
            subtitle: 'Jarak hari untuk setiap jenis pengingat.',
            child: Column(
              children: [
                _number(
                  'Garansi diingatkan H- (hari)',
                  _garansiHari,
                  helper: 'Pengingat sebelum garansi berakhir.',
                ),
                _number(
                  'Arsip garansi setelah berakhir (hari)',
                  _garansiArsip,
                ),
                _number(
                  'Servis berkala tampil sebelum jatuh tempo (hari)',
                  _servisAwal,
                ),
                _number('Jeda pengingat piutang (hari)', _piutangJeda),
                _number('Prospek tahap 1 (hari)', _prospek1),
                _number('Prospek tahap 2 (hari)', _prospek2),
                _number('Prospek tahap 3 (hari)', _prospek3),
                _number(
                  'Tunda setelah masih kendala (hari)',
                  _belumBisa,
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
