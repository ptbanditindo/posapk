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

  int _int(TextEditingController controller, int fallback) {
    return int.tryParse(controller.text.trim()) ?? fallback;
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
    setState(() => _saving = true);
    try {
      await FollowupService.instance.saveSettings(
        FollowupSettings(
          aktif: _aktif,
          jamMulai: _jamMulai,
          jamSelesai: _jamSelesai,
          cooldownHari: _int(_cooldown, 7),
          garansiAkanHabisHari: _int(_garansiHari, 7),
          garansiArsipHari: _int(_garansiArsip, 7),
          servisBerkalaAwalHari: _int(_servisAwal, 14),
          piutangJedaHari: _int(_piutangJeda, 14),
          prospekHari1: _int(_prospek1, 30),
          prospekHari2: _int(_prospek2, 60),
          prospekHari3: _int(_prospek3, 90),
          belumBisaHari: _int(_belumBisa, 14),
          maksPesanHari: _int(_maksHari, 1),
          maksPesanBulan: _int(_maksBulan, 2),
          jedaProspekServisHari: _int(_jedaProspek, 7),
          maksTidakMerespons: _int(_maksTidakRespons, 3),
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
        decoration: InputDecoration(labelText: label, helperText: helper),
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
