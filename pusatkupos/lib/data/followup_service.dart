import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../core/app_config.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/money.dart';
import '../core/phone.dart';
import '../core/wa_link.dart';
import '../sync/relay_client.dart';
import '../sync/sync_service.dart';
import 'app_database.dart';
import 'feature_flags.dart';
import 'license_service.dart';
import 'store_settings.dart';

const followupJenis = [
  'prospek',
  'servis_berkala',
  'garansi',
  'piutang',
  'unit_selesai',
];

const followupJenisLabels = {
  'prospek': 'Prospek',
  'servis_berkala': 'Servis berkala',
  'garansi': 'Garansi',
  'piutang': 'Piutang',
  'unit_selesai': 'Unit selesai',
};

const followupStatuses = [
  'BARU',
  'SUDAH_FOLLOWUP',
  'JANJI_BAYAR',
  'MASIH_KENDALA',
  'SELESAI',
  'ARSIP',
  'AKAN_DATANG',
  'TIDAK_DATANG',
  'SUDAH_BAYAR',
];

const followupStatusLabels = {
  'BARU': 'Baru',
  'SUDAH_FOLLOWUP': 'Sudah dihubungi',
  'JANJI_BAYAR': 'Janji bayar',
  'MASIH_KENDALA': 'Masih kendala',
  'SELESAI': 'Selesai',
  'ARSIP': 'Arsip',
  'AKAN_DATANG': 'Akan datang service',
  'TIDAK_DATANG': 'Tidak akan datang service',
  'SUDAH_BAYAR': 'Sudah bayar',
};

const openFollowupStatuses = {
  'BARU',
  'SUDAH_FOLLOWUP',
  'JANJI_BAYAR',
  'MASIH_KENDALA',
  'AKAN_DATANG',
};

const closedFollowupStatuses = {
  'SELESAI',
  'TIDAK_DATANG',
  'SUDAH_BAYAR',
  'ARSIP',
};

const autoArchiveReason = 'Sumber pengingat sudah tidak aktif.';

const _freeQuotaLimit = 20;
const _quotaKey = 'followup.wa_used';
// Penanda lokal disamarkan agar tidak terlihat sebagai kode kuota.
const _quotaCodeKey = 'ops.arsip_sesi';
const _quotaSyncTimeout = Duration(seconds: 4);

class FollowupSettings {
  const FollowupSettings({
    this.aktif = true,
    this.jamMulai = '08:00',
    this.jamSelesai = '20:00',
    this.cooldownHari = 7,
    this.garansiAkanHabisHari = 7,
    this.garansiArsipHari = 7,
    this.servisBerkalaAwalHari = 14,
    this.piutangJedaHari = 14,
    this.prospekHari1 = 30,
    this.prospekHari2 = 60,
    this.prospekHari3 = 90,
    this.belumBisaHari = 14,
    this.maksPesanHari = 1,
    this.maksPesanBulan = 2,
    this.jedaProspekServisHari = 7,
    this.maksTidakMerespons = 3,
  });

  final bool aktif;
  final String jamMulai;
  final String jamSelesai;
  final int cooldownHari;
  final int garansiAkanHabisHari;
  final int garansiArsipHari;
  final int servisBerkalaAwalHari;
  final int piutangJedaHari;
  final int prospekHari1;
  final int prospekHari2;
  final int prospekHari3;
  final int belumBisaHari;
  final int maksPesanHari;
  final int maksPesanBulan;
  final int jedaProspekServisHari;
  final int maksTidakMerespons;

  FollowupSettings copyWith({
    bool? aktif,
    String? jamMulai,
    String? jamSelesai,
    int? cooldownHari,
    int? garansiAkanHabisHari,
    int? garansiArsipHari,
    int? servisBerkalaAwalHari,
    int? piutangJedaHari,
    int? prospekHari1,
    int? prospekHari2,
    int? prospekHari3,
    int? belumBisaHari,
    int? maksPesanHari,
    int? maksPesanBulan,
    int? jedaProspekServisHari,
    int? maksTidakMerespons,
  }) {
    return FollowupSettings(
      aktif: aktif ?? this.aktif,
      jamMulai: jamMulai ?? this.jamMulai,
      jamSelesai: jamSelesai ?? this.jamSelesai,
      cooldownHari: cooldownHari ?? this.cooldownHari,
      garansiAkanHabisHari:
          garansiAkanHabisHari ?? this.garansiAkanHabisHari,
      garansiArsipHari: garansiArsipHari ?? this.garansiArsipHari,
      servisBerkalaAwalHari:
          servisBerkalaAwalHari ?? this.servisBerkalaAwalHari,
      piutangJedaHari: piutangJedaHari ?? this.piutangJedaHari,
      prospekHari1: prospekHari1 ?? this.prospekHari1,
      prospekHari2: prospekHari2 ?? this.prospekHari2,
      prospekHari3: prospekHari3 ?? this.prospekHari3,
      belumBisaHari: belumBisaHari ?? this.belumBisaHari,
      maksPesanHari: maksPesanHari ?? this.maksPesanHari,
      maksPesanBulan: maksPesanBulan ?? this.maksPesanBulan,
      jedaProspekServisHari:
          jedaProspekServisHari ?? this.jedaProspekServisHari,
      maksTidakMerespons: maksTidakMerespons ?? this.maksTidakMerespons,
    );
  }
}

class FollowupQuota {
  const FollowupQuota({
    required this.premium,
    required this.used,
    required this.limit,
  });

  final bool premium;
  final int used;
  final int? limit;

  int? get remaining => premium ? null : (limit! - used).clamp(0, limit!).toInt();
  bool get locked => !premium && used >= limit!;

  String get label {
    if (premium) return 'Premium: tanpa batas';
    return 'Sisa $remaining dari $limit kredit';
  }
}

class FollowupRow {
  const FollowupRow({
    required this.id,
    required this.jenis,
    required this.itemKey,
    required this.status,
    required this.stage,
    required this.customerId,
    required this.customerNama,
    required this.nomorHp,
    required this.nomorMasked,
    required this.unitId,
    required this.unitLabel,
    required this.recordId,
    required this.noNota,
    required this.judul,
    required this.jatuhTempo,
    required this.followupTerakhir,
    required this.janjiBayar,
    required this.tanggalService,
    required this.tundaSampai,
    required this.noResponseCount,
    required this.alasanArsip,
    required this.sisaHari,
    required this.terlambat,
    required this.dnc,
    required this.consent,
    required this.sisaBayar,
    required this.bisaFollowup,
    required this.bisaAlasan,
  });

  final int id;
  final String jenis;
  final String itemKey;
  final String status;
  final int stage;
  final int customerId;
  final String customerNama;
  final String nomorHp;
  final String nomorMasked;
  final int unitId;
  final String unitLabel;
  final int? recordId;
  final String? noNota;
  final String judul;
  final DateTime jatuhTempo;
  final DateTime? followupTerakhir;
  final DateTime? janjiBayar;
  final DateTime? tanggalService;
  final DateTime? tundaSampai;
  final int noResponseCount;
  final String? alasanArsip;
  final int sisaHari;
  final bool terlambat;
  final bool dnc;
  final bool consent;
  final int sisaBayar;
  final bool bisaFollowup;
  final String bisaAlasan;

  String get statusLabel => followupStatusLabels[status] ?? status;
  String get jenisLabel => followupJenisLabels[jenis] ?? jenis;
}

class FollowupAttempt {
  const FollowupAttempt({
    required this.message,
    required this.link,
    required this.nomorMasked,
    required this.itemIds,
    required this.quota,
  });

  final String message;
  final String link;
  final String nomorMasked;
  final List<int> itemIds;
  final FollowupQuota quota;
}

class _ServiceRecordSource {
  _ServiceRecordSource({
    required this.id,
    required this.unitId,
    required this.customerId,
    required this.noNota,
    required this.waktu,
    required this.unitType,
    required this.unitLabel,
    required this.customerNama,
    required this.nomorHp,
    required this.consent,
    required this.dnc,
    required this.bergaransi,
    required this.garansiSampai,
    required this.statusKlaim,
    required this.statusBayar,
    required this.sisaBayar,
    required this.unitDitinggal,
    required this.diambilAt,
  });

  final int id;
  final int unitId;
  final int customerId;
  final String noNota;
  final DateTime waktu;
  final String unitType;
  final String unitLabel;
  final String customerNama;
  final String nomorHp;
  final bool consent;
  final bool dnc;
  final bool bergaransi;
  final DateTime? garansiSampai;
  final String statusKlaim;
  final String statusBayar;
  final int sisaBayar;
  final bool unitDitinggal;
  final DateTime? diambilAt;

  DateTime get referenceDay {
    final taken = diambilAt;
    return startOfDay(taken ?? waktu);
  }
}

class _Source {
  _Source({
    required this.key,
    required this.jenis,
    required this.record,
    required this.due,
    required this.stage,
    required this.intervalBulan,
    required this.referenceDate,
  });

  final String key;
  final String jenis;
  final _ServiceRecordSource record;
  final DateTime due;
  final int stage;
  final int? intervalBulan;
  final DateTime referenceDate;
}

class _CustomerCounts {
  const _CustomerCounts({
    this.today = 0,
    this.month = 0,
    this.lastFollowup,
  });

  final int today;
  final int month;
  final DateTime? lastFollowup;
}

class FollowupService {
  FollowupService._();

  static final FollowupService instance = FollowupService._();

  void scheduleSync() {
    syncItems().catchError((Object _) {});
  }

  Future<FollowupSettings> loadSettings() async {
    final rows = await AppDatabase.instance.db.query(
      'app_meta',
      columns: ['key', 'value'],
      where: "key LIKE 'ops.%'",
    );
    final data = {
      for (final row in rows)
        (row['key'] as String).substring(4): row['value'] as String? ?? '',
    };
    int number(String key, int fallback, int low, int high) {
      final value = int.tryParse(data[key] ?? '');
      if (value == null) return fallback;
      return value < low ? low : (value > high ? high : value);
    }

    String clock(String key, String fallback) {
      final value = data[key] ?? '';
      return _parseClock(value) == null ? fallback : value;
    }

    return FollowupSettings(
      aktif: (data['followup_aktif'] ?? '1') != '0',
      jamMulai: clock('followup_jam_mulai', '08:00'),
      jamSelesai: clock('followup_jam_selesai', '20:00'),
      cooldownHari: number('cooldown_hari', 7, 0, 90),
      garansiAkanHabisHari: number('garansi_akan_habis_hari', 7, 1, 90),
      garansiArsipHari: number('garansi_arsip_hari', 7, 1, 90),
      servisBerkalaAwalHari:
          number('servis_berkala_awal_hari', 14, 1, 90),
      piutangJedaHari: number('piutang_jeda_hari', 14, 1, 90),
      prospekHari1: number('prospek_hari_1', 30, 7, 180),
      prospekHari2: number('prospek_hari_2', 60, 30, 365),
      prospekHari3: number('prospek_hari_3', 90, 60, 540),
      belumBisaHari: number('belum_bisa_hari', 14, 1, 60),
      maksPesanHari: number('maks_pesan_hari', 1, 1, 5),
      maksPesanBulan: number('maks_pesan_bulan', 2, 1, 20),
      jedaProspekServisHari:
          number('jeda_prospek_servis_hari', 7, 1, 90),
      maksTidakMerespons: number('maks_tidak_merespons', 3, 1, 10),
    );
  }

  Future<void> saveSettings(FollowupSettings settings) async {
    FeatureGate.require(featureFollowup);
    if (_parseClock(settings.jamMulai) == null ||
        _parseClock(settings.jamSelesai) == null) {
      throw ArgumentError('Jam follow up tidak valid.');
    }
    if (settings.maksPesanHari < 1 || settings.maksPesanBulan < 1) {
      throw ArgumentError('Batas pesan minimal 1.');
    }
    final values = <String, String>{
      'ops.followup_aktif': settings.aktif ? '1' : '0',
      'ops.followup_jam_mulai': settings.jamMulai,
      'ops.followup_jam_selesai': settings.jamSelesai,
      'ops.cooldown_hari': '${settings.cooldownHari}',
      'ops.garansi_akan_habis_hari': '${settings.garansiAkanHabisHari}',
      'ops.garansi_arsip_hari': '${settings.garansiArsipHari}',
      'ops.servis_berkala_awal_hari': '${settings.servisBerkalaAwalHari}',
      'ops.piutang_jeda_hari': '${settings.piutangJedaHari}',
      'ops.prospek_hari_1': '${settings.prospekHari1}',
      'ops.prospek_hari_2': '${settings.prospekHari2}',
      'ops.prospek_hari_3': '${settings.prospekHari3}',
      'ops.belum_bisa_hari': '${settings.belumBisaHari}',
      'ops.maks_pesan_hari': '${settings.maksPesanHari}',
      'ops.maks_pesan_bulan': '${settings.maksPesanBulan}',
      'ops.jeda_prospek_servis_hari': '${settings.jedaProspekServisHari}',
      'ops.maks_tidak_merespons': '${settings.maksTidakMerespons}',
    };
    final db = AppDatabase.instance.db;
    await db.transaction((txn) async {
      for (final entry in values.entries) {
        await txn.insert(
          'app_meta',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> syncItems({DateTime? now}) async {
    if (!FeatureGate.enabled(featureFollowup)) return;
    final moment = now ?? DateTime.now();
    final settings = await loadSettings();
    if (!settings.aktif) return;
    final records = await _loadRecords();
    final intervals = await _loadIntervals();
    final existing = await AppDatabase.instance.db.query('followup_items');
    final activeByKey = <String, Map<String, Object?>>{};
    final archivedByKey = <String, List<Map<String, Object?>>>{};
    for (final row in existing) {
      final key = row['item_key'] as String? ?? '';
      if ((row['status'] as String? ?? '') == 'ARSIP') {
        archivedByKey.putIfAbsent(key, () => []).add(row);
      } else {
        activeByKey[key] = row;
      }
    }

    final sources = _buildSources(
      records,
      intervals,
      activeByKey,
      settings,
      moment,
    );
    final db = AppDatabase.instance.db;
    await db.transaction((txn) async {
      for (final source in sources.values) {
        final active = activeByKey[source.key];
        if (active != null) {
          final previousRecord = active['service_record_id'] as int?;
          final previousDue = active['jatuh_tempo'] as String?;
          final status = active['status'] as String? ?? 'BARU';
          final changed =
              previousRecord != source.record.id ||
                  previousDue != _isoDay(source.due) ||
                  active['jenis'] != source.jenis;
          final payload = <String, Object?>{
            'jenis': source.jenis,
            'stage': source.stage,
            'interval_bulan': source.intervalBulan ?? 0,
            'reference_date': _isoDay(source.referenceDate),
            'jatuh_tempo': _isoDay(source.due),
            'customer_id': source.record.customerId,
            'unit_id': source.record.unitId,
            'service_record_id': source.record.id,
            'updated_at': _isoMoment(moment),
          };
          if (changed && closedFollowupStatuses.contains(status)) {
            payload.addAll({
              'status': 'BARU',
              'followup_terakhir': null,
              'janji_bayar': null,
              'tanggal_service': null,
              'tunda_sampai': null,
              'no_response_count': 0,
              'alasan_arsip': null,
            });
            await _addEvent(
              txn,
              active['id'] as int,
              'SIKLUS',
              'BARU',
              'Siklus baru dari nota terbaru.',
              moment,
            );
          }
          await txn.update(
            'followup_items',
            payload,
            where: 'id = ?',
            whereArgs: [active['id']],
          );
          continue;
        }
        final archived = archivedByKey[source.key] ?? const [];
        final manualArchived = archived.any(
          (row) =>
              row['service_record_id'] == source.record.id &&
              (row['alasan_arsip'] as String? ?? '') != autoArchiveReason,
        );
        if (manualArchived) continue;
        final id = await txn.insert('followup_items', {
          'sync_id': newSyncId(),
          'jenis': source.jenis,
          'item_key': source.key,
          'status': 'BARU',
          'stage': source.stage,
          'interval_bulan': source.intervalBulan ?? 0,
          'reference_date': _isoDay(source.referenceDate),
          'jatuh_tempo': _isoDay(source.due),
          'customer_id': source.record.customerId,
          'unit_id': source.record.unitId,
          'service_record_id': source.record.id,
          'created_at': _isoMoment(moment),
          'updated_at': _isoMoment(moment),
        });
        await _addEvent(
          txn,
          id,
          'BUAT',
          'BARU',
          'Pengingat baru.',
          moment,
        );
      }

      for (final row in existing) {
        final key = row['item_key'] as String? ?? '';
        if (sources.containsKey(key)) continue;
        if ((row['status'] as String? ?? '') == 'ARSIP') continue;
        await _archive(
          txn,
          row['id'] as int,
          autoArchiveReason,
          moment,
        );
      }
    });
  }

  Future<List<FollowupRow>> listItems({
    String filter = 'semua',
    String? jenis,
    DateTime? now,
  }) async {
    final moment = now ?? DateTime.now();
    final settings = await loadSettings();
    final today = startOfDay(moment);
    final conditions = <String>[];
    final args = <Object?>[];
    switch (filter) {
      case 'hari_ini':
        conditions.add(
          "f.status NOT IN ('ARSIP', 'SUDAH_BAYAR') AND f.jatuh_tempo = ?",
        );
        args.add(_isoDay(today));
      case 'terlambat':
        conditions.add(
          "f.status NOT IN ('ARSIP', 'SUDAH_BAYAR') AND f.jatuh_tempo < ? "
          "AND f.status <> 'AKAN_DATANG'",
        );
        args.add(_isoDay(today));
      case 'arsip':
        conditions.add("f.status IN ('ARSIP', 'SUDAH_BAYAR')");
      default:
        conditions.add("f.status NOT IN ('ARSIP', 'SUDAH_BAYAR')");
    }
    if (jenis != null && jenis.isNotEmpty) {
      conditions.add('f.jenis = ?');
      args.add(jenis);
    }
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT f.*, c.nama AS customer_nama, c.nomor_hp,
        c.wa_consent, c.do_not_contact,
        COALESCE(u.unit_type, 'MOBIL') AS unit_type,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '')), ''), 'Unit') AS unit_label,
        r.no_nota, r.status_bayar, r.sisa_bayar, r.unit_ditinggal,
        r.diambil_at
      FROM followup_items f
      LEFT JOIN customers c ON c.id = f.customer_id
      LEFT JOIN vehicle_or_units u ON u.id = f.unit_id
      LEFT JOIN service_records r ON r.id = f.service_record_id
      WHERE ${conditions.join(' AND ')}
      ORDER BY f.jatuh_tempo IS NULL, f.jatuh_tempo, f.id
      ''',
      args,
    );
    if (rows.isEmpty) return const [];
    final counts = await _messageCounts(moment);
    final openUnitCustomers = await _openUnitCustomers();
    final dueByCustomer = await _dueByCustomer(today);
    return rows.map((row) {
      return _toRow(
        row,
        settings,
        moment,
        counts[row['customer_id']] ?? const _CustomerCounts(),
        openUnitCustomers.contains(row['customer_id']),
        dueByCustomer,
      );
    }).toList();
  }

  Future<FollowupQuota> _localQuota() async {
    final premium = await LicenseService.instance.isPremium();
    final raw = await AppDatabase.instance.getSetting(_quotaKey) ?? '0';
    final parsed = int.tryParse(raw) ?? 0;
    return FollowupQuota(
      premium: premium,
      used: parsed < 0 ? 0 : parsed,
      limit: premium ? null : _freeQuotaLimit,
    );
  }

  Future<String> _quotaCode() async {
    final stored = await AppDatabase.instance.getSetting(_quotaCodeKey) ?? '';
    final decoded = _decodeCode(stored);
    if (decoded.isNotEmpty) return decoded;
    final code = 'S${newSyncId()}';
    await AppDatabase.instance.setSetting(_quotaCodeKey, _encodeCode(code));
    return code;
  }

  String _encodeCode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _decodeCode(String value) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(value)));
    } catch (_) {
      return '';
    }
  }

  Future<({int used, bool allowed})?> _syncQuota({
    required int localUsed,
    bool consume = false,
  }) async {
    if (!serviceConfigured) return null;
    final token = await SyncService.instance.relayDeviceToken();
    if (token == null || token.isEmpty) return null;
    try {
      final body = await RelayClient(
        baseUrl: normalizedServiceUrl,
        deviceToken: token,
      )
          .followupQuota(
            code: await _quotaCode(),
            used: localUsed,
            consume: consume,
          )
          .timeout(_quotaSyncTimeout);
      final used = (body['used'] as num?)?.toInt();
      if (used == null) return null;
      return (
        used: used.clamp(0, _freeQuotaLimit).toInt(),
        allowed: consume
            ? body['consumed'] == true
            : used < _freeQuotaLimit,
      );
    } catch (_) {
      return null;
    }
  }

  Future<FollowupQuota> quotaStatus() async {
    final quota = await _localQuota();
    if (quota.premium) return quota;
    final remote = await _syncQuota(localUsed: quota.used);
    if (remote == null) return quota;
    await AppDatabase.instance.setSetting(_quotaKey, '${remote.used}');
    return FollowupQuota(
      premium: false,
      used: remote.used,
      limit: _freeQuotaLimit,
    );
  }

  Future<FollowupAttempt> followUp(
    int itemId, {
    required Operator actor,
    String? catatan,
    DateTime? now,
  }) async {
    FeatureGate.require(featureFollowup);
    final moment = now ?? DateTime.now();
    final settings = await loadSettings();
    if (!settings.aktif) {
      throw StateError('Fitur follow up sedang dimatikan.');
    }
    if (!actor.isOwner) {
      Permissions.require(actor, 'followup');
      final roleSettings = await StoreSettingsService.instance.ensure();
      if (!roleSettings.roleAllows(actor.role, 'followup')) {
        throw StateError(
          'Peran ${actor.role} tidak berhak melakukan follow up.',
        );
      }
    }
    final quota = await _localQuota();
    if (quota.locked) {
      throw StateError(
        'Kuota Follow up gratis (20 kredit WhatsApp) sudah habis. '
        'Data lama tetap dapat dibaca dan diekspor.',
      );
    }
    final item = await _loadItem(itemId);
    if (item == null) throw StateError('Pengingat tidak ditemukan.');
    final counts = await _messageCounts(moment);
    final openUnits = await _openUnitCustomers();
    final customerId = item['customer_id'] as int? ?? 0;
    final row = _toRow(
      item,
      settings,
      moment,
      counts[customerId] ?? const _CustomerCounts(),
      openUnits.contains(customerId),
      await _dueByCustomer(startOfDay(moment)),
    );
    if (!row.bisaFollowup) {
      throw StateError(
        row.bisaAlasan.isEmpty ? 'Follow up belum siap.' : row.bisaAlasan,
      );
    }

    final group = await _mergeGroup(item, settings, moment);
    final storeName =
        await AppDatabase.instance.getSetting('bengkel.nama') ?? 'PusatkuPOS';
    final message = group.length > 1
        ? _groupMessage(group, moment, storeName)
        : _message(item, moment, storeName);
    final phone = item['nomor_hp'] as String? ?? '';
    final link = waMeLink(phone, message);
    final ids = group.map((row) => row['id'] as int).toList();
    var used = quota.used;
    final db = AppDatabase.instance.db;
    await db.transaction((txn) async {
      if (!quota.premium) {
        final currentRows = await txn.query(
          'app_meta',
          columns: ['value'],
          where: 'key = ?',
          whereArgs: [_quotaKey],
          limit: 1,
        );
        final current = currentRows.isEmpty
            ? 0
            : int.tryParse(currentRows.first['value'] as String? ?? '') ?? 0;
        if (current >= _freeQuotaLimit) {
          throw StateError(
            'Kuota Follow up gratis (20 kredit WhatsApp) sudah habis.',
          );
        }
        used = current + 1;
        await txn.insert(
          'app_meta',
          {'key': _quotaKey, 'value': '$used'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in group) {
        final currentStatus = row['status'] as String? ?? 'BARU';
        final status = openFollowupStatuses.contains(currentStatus)
            ? 'SUDAH_FOLLOWUP'
            : currentStatus;
        final count = (row['no_response_count'] as int? ?? 0) + 1;
        await txn.update(
          'followup_items',
          {
            'status': status,
            'followup_terakhir': _isoMoment(moment),
            'stage': (row['stage'] as int? ?? 0) + 1,
            'no_response_count': count,
            'updated_at': _isoMoment(moment),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await _addEvent(
          txn,
          row['id'] as int,
          'FOLLOWUP',
          status,
          (catatan ?? '').trim().isEmpty
              ? 'WhatsApp dibuka.'
              : 'WhatsApp dibuka: ${catatan!.trim()}',
          moment,
        );
        await txn.insert('wa_message_logs', {
          'sync_id': newSyncId(),
          'customer_id': row['customer_id'],
          'jenis': _waJenis(row['jenis'] as String? ?? ''),
          'status': 'DIBUKA',
          'nomor_masked': maskPhone(phone),
          'created_at': _isoMoment(moment),
          'updated_at': _isoMoment(moment),
        });
        final autoArchive = count >= settings.maksTidakMerespons &&
            row['jenis'] != 'piutang' &&
            !{'AKAN_DATANG', 'SELESAI', 'JANJI_BAYAR'}.contains(status);
        if (autoArchive) {
          await _archive(
            txn,
            row['id'] as int,
            'Tidak merespons ${settings.maksTidakMerespons} kali.',
            moment,
          );
        }
      }
    });
    if (!quota.premium) {
      // Konsumsi kuota remote setelah commit lokal: kegagalan transaksi
      // tidak lagi membuang kredit, dan laporan lokal akan disinkronkan
      // lewat GREATEST pada pemeriksaan berikutnya.
      final remote = await _syncQuota(localUsed: used, consume: true);
      if (remote != null) used = remote.used;
    }
    return FollowupAttempt(
      message: message,
      link: link,
      nomorMasked: maskPhone(phone),
      itemIds: ids,
      quota: FollowupQuota(
        premium: quota.premium,
        used: used,
        limit: quota.premium ? null : _freeQuotaLimit,
      ),
    );
  }

  Future<void> changeStatus(
    int itemId, {
    required String status,
    required Operator actor,
    String? alasan,
    DateTime? janjiBayar,
    DateTime? tanggalService,
    int? tundaHari,
    DateTime? now,
  }) async {
    FeatureGate.require(featureFollowup);
    final settings = await loadSettings();
    if (!actor.isOwner) {
      Permissions.require(actor, 'followup');
      final roleSettings = await StoreSettingsService.instance.ensure();
      if (!roleSettings.roleAllows(actor.role, 'followup')) {
        throw StateError(
          'Peran ${actor.role} tidak berhak mengubah status follow up.',
        );
      }
    }
    final moment = now ?? DateTime.now();
    final target = status.trim().toUpperCase();
    if (!followupStatuses.contains(target)) {
      throw ArgumentError('Status follow-up tidak dikenal.');
    }
    final item = await _loadItem(itemId);
    if (item == null) throw StateError('Pengingat tidak ditemukan.');
    final current = item['status'] as String? ?? 'BARU';
    final jenis = item['jenis'] as String? ?? '';
    if (current == 'ARSIP') {
      throw StateError('Item arsip tidak dapat diubah.');
    }
    final hadFollowup = item['followup_terakhir'] != null;
    final scheduled = jenis == 'servis_berkala' || jenis == 'garansi';
    if (scheduled) {
      if (!{
        'AKAN_DATANG',
        'MASIH_KENDALA',
        'TIDAK_DATANG',
        'SELESAI',
        'ARSIP',
      }.contains(target)) {
        throw ArgumentError(
          'Status servis berkala dan garansi hanya akan datang service, '
          'masih kendala, tidak akan datang service, selesai, atau arsip.',
        );
      }
      if (target == 'AKAN_DATANG' && tanggalService == null) {
        throw ArgumentError('Tanggal service wajib diisi.');
      }
      if (target != 'ARSIP' && !hadFollowup) {
        throw StateError(
          'Lakukan follow up WhatsApp dulu sebelum mengubah status.',
        );
      }
    } else if (jenis == 'prospek' || jenis == 'unit_selesai') {
      if (target != 'ARSIP' && !hadFollowup) {
        throw StateError(
          'Lakukan follow up WhatsApp dulu sebelum mengubah status.',
        );
      }
      if (target == 'AKAN_DATANG' && tanggalService == null) {
        throw ArgumentError('Tanggal kunjungan wajib diisi.');
      }
    } else if ({'AKAN_DATANG', 'TIDAK_DATANG'}.contains(target)) {
      throw ArgumentError(
        'Status akan/tidak datang service hanya untuk prospek, '
        'servis berkala, garansi, dan unit selesai.',
      );
    }
    if (target == 'SUDAH_BAYAR') {
      if (jenis != 'piutang') {
        throw ArgumentError('Sudah bayar hanya untuk piutang.');
      }
      final sisa = item['sisa_bayar'] as int? ?? 0;
      if (sisa > 0) {
        throw ArgumentError(
          'Sisa pembayaran belum lunas. Selesaikan pelunasan lebih dulu.',
        );
      }
    }
    if (jenis == 'piutang' && {'SELESAI', 'ARSIP'}.contains(target)) {
      throw ArgumentError(
        'Piutang hanya keluar dari daftar lewat pelunasan penuh atau void.',
      );
    }
    if (target == 'JANJI_BAYAR') {
      if (jenis != 'piutang') {
        throw ArgumentError('Janji bayar hanya untuk piutang.');
      }
      if (janjiBayar == null) {
        throw ArgumentError('Tanggal janji bayar wajib diisi.');
      }
    }
    if (target == 'ARSIP' && (alasan ?? '').trim().isEmpty) {
      throw ArgumentError('Alasan arsip wajib diisi.');
    }
    if (target == current && !(jenis == 'prospek' &&
        target == 'AKAN_DATANG' &&
        tanggalService != null)) {
      throw ArgumentError('Status item sudah sama.');
    }

    final tunda = target == 'MASIH_KENDALA'
        ? moment.add(Duration(days: tundaHari ?? settings.belumBisaHari))
        : null;
    await AppDatabase.instance.db.transaction((txn) async {
      await txn.update(
        'followup_items',
        {
          'status': target,
          // Tanggal lama dipertahankan; hanya diganti bila status baru
          // memang membutuhkan tanggal tersebut.
          'tanggal_service': target == 'AKAN_DATANG'
              ? _isoDay(tanggalService!)
              : item['tanggal_service'],
          'janji_bayar': target == 'JANJI_BAYAR'
              ? _isoDay(janjiBayar!)
              : item['janji_bayar'],
          'tunda_sampai': tunda == null ? item['tunda_sampai'] : _isoMoment(tunda),
          'no_response_count': {'AKAN_DATANG', 'SELESAI', 'JANJI_BAYAR'}
                  .contains(target)
              ? 0
              : item['no_response_count'],
          'alasan_arsip': target == 'ARSIP' || target == 'SUDAH_BAYAR'
              ? (target == 'SUDAH_BAYAR'
                  ? 'Sudah bayar.'
                  : (alasan ?? '').trim())
              : item['alasan_arsip'],
          'updated_at': _isoMoment(moment),
        },
        where: 'id = ?',
        whereArgs: [itemId],
      );
      await _addEvent(
        txn,
        itemId,
        'STATUS',
        target,
        (alasan ?? '').trim().isEmpty ? null : alasan!.trim(),
        moment,
      );
    });
  }

  Future<List<Map<String, Object?>>> events(int itemId) async {
    return AppDatabase.instance.db.query(
      'followup_events',
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'created_at, id',
    );
  }

  Future<Map<String, Set<int>>> _dueByCustomer(DateTime today) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT customer_id, jenis
      FROM followup_items
      WHERE status IN ('BARU', 'SUDAH_FOLLOWUP', 'MASIH_KENDALA', 'AKAN_DATANG')
        AND jatuh_tempo <= ?
      ''',
      [_isoDay(today)],
    );
    final result = <String, Set<int>>{};
    for (final row in rows) {
      final customerId = row['customer_id'] as int?;
      if (customerId == null) continue;
      result.putIfAbsent('${row['jenis']}', () => <int>{}).add(customerId);
    }
    return result;
  }

  Map<String, _Source> _buildSources(
    List<_ServiceRecordSource> records,
    Map<int, List<_IntervalRow>> intervals,
    Map<String, Map<String, Object?>> activeByKey,
    FollowupSettings settings,
    DateTime moment,
  ) {
    final today = startOfDay(moment);
    final sources = <String, _Source>{};
    final byUnit = <int, List<_ServiceRecordSource>>{};
    for (final record in records) {
      if (record.unitType == 'SPAREPART') continue;
      byUnit.putIfAbsent(record.unitId, () => []).add(record);
    }

    void add(
      String key,
      String jenis,
      _ServiceRecordSource record,
      DateTime due, {
      int stage = 0,
      int? intervalBulan,
      DateTime? referenceDate,
    }) {
      sources[key] = _Source(
        key: key,
        jenis: jenis,
        record: record,
        due: startOfDay(due),
        stage: stage,
        intervalBulan: intervalBulan,
        referenceDate: startOfDay(referenceDate ?? record.referenceDay),
      );
    }

    for (final entry in byUnit.entries) {
      final unitId = entry.key;
      final unitRecords = entry.value;
      if (unitRecords.isEmpty) continue;
      final latest = unitRecords.first;
      final key = 'unit:$unitId';
      final existing = activeByKey[key];
      final existingJenis = existing?['jenis'] as String?;
      final stage =
          existing != null && {'prospek', 'garansi'}.contains(existingJenis)
              ? existing['stage'] as int? ?? 0
              : 0;

      if (latest.unitDitinggal && latest.diambilAt == null) {
        add(key, 'unit_selesai', latest, today, referenceDate: latest.referenceDay);
      } else {
        final warranty = unitRecords.cast<_ServiceRecordSource?>().firstWhere(
              (record) =>
                  record != null &&
                  record.bergaransi &&
                  record.garansiSampai != null &&
                  record.statusKlaim != 'Sudah claim',
              orElse: () => null,
            );
        final milestones = [
          settings.prospekHari1,
          settings.prospekHari2,
          settings.prospekHari3,
        ];
        if (warranty != null) {
          final expiry =
              startOfDay(warranty.garansiSampai!);
          final h7 = expiry.subtract(
            Duration(days: settings.garansiAkanHabisHari),
          );
          final archiveAfter = expiry.add(
            Duration(days: settings.garansiArsipHari),
          );
          if (!today.isAfter(archiveAfter)) {
            if (!today.isBefore(h7)) {
              var due = today.isBefore(expiry) ? h7 : expiry;
              var nextStage = stage;
              if (today.isBefore(expiry)) {
                if (nextStage < 1) nextStage = 1;
              } else {
                if (nextStage < 2) nextStage = 2;
              }
              final followed = existing?['followup_terakhir'] != null &&
                  !startOfDay(localTime(existing!['followup_terakhir']))
                      .isBefore(h7);
              final promised = existing?['status'] == 'AKAN_DATANG' &&
                  existing?['tanggal_service'] != null &&
                  !startOfDay(localTime(existing!['tanggal_service']))
                      .isAfter(expiry);
              if (today.isAfter(expiry) && (followed || promised)) {
                due = expiry;
              }
              add(
                key,
                'garansi',
                warranty,
                due,
                stage: nextStage,
                referenceDate: warranty.referenceDay,
              );
            } else if (stage < milestones.length) {
              final due = addDays(
                latest.referenceDay,
                milestones[stage],
              );
              if (!due.isAfter(today)) {
                add(
                  key,
                  'prospek',
                  latest,
                  due,
                  stage: stage,
                  referenceDate: latest.referenceDay,
                );
              }
            }
          }
        } else if (stage < milestones.length) {
          final due = addDays(latest.referenceDay, milestones[stage]);
          if (!due.isAfter(today)) {
            add(
              key,
              'prospek',
              latest,
              due,
              stage: stage,
              referenceDate: latest.referenceDay,
            );
          }
        }
      }

      final seen = <String>{};
      for (final record in unitRecords) {
        final serviceDay = startOfDay(record.waktu);
        for (final row in intervals[record.id] ?? const <_IntervalRow>[]) {
          final identifier = row.identifier.isEmpty
              ? row.nama.trim().toLowerCase()
              : row.identifier;
          final shortKey =
              'servis:$unitId:${row.kind}:$identifier';
          if (seen.contains(shortKey)) continue;
          seen.add(shortKey);
          final existingServis = activeByKey[shortKey];
          final servisStage =
              existingServis != null &&
                  existingServis['service_record_id'] == record.id
              ? existingServis['stage'] as int? ?? 0
              : 0;
          final due = addMonths(
            serviceDay,
            row.intervalBulan * (servisStage + 1),
          );
          final horizon = today.add(
            Duration(days: settings.servisBerkalaAwalHari),
          );
          if (due.isAfter(horizon)) continue;
          sources[shortKey] = _Source(
            key: shortKey,
            jenis: 'servis_berkala',
            record: record,
            due: startOfDay(due),
            stage: servisStage,
            intervalBulan: row.intervalBulan,
            referenceDate: serviceDay,
          );
        }

        if (record.sisaBayar > 0 && record.statusBayar != 'LUNAS') {
          final due = addDays(
            record.referenceDay,
            settings.piutangJedaHari,
          );
          if (!due.isAfter(today)) {
            add(
              'piutang:record:${record.id}',
              'piutang',
              record,
              due,
              referenceDate: record.referenceDay,
            );
          }
        }
      }
    }
    return sources;
  }

  Future<List<_ServiceRecordSource>> _loadRecords() async {
    final rows = await AppDatabase.instance.db.rawQuery('''
      SELECT r.*, u.unit_type, u.customer_id,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '')), ''), 'Unit') AS unit_label,
        c.nama AS customer_nama, c.nomor_hp, c.wa_consent, c.do_not_contact
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE r.status <> 'VOID'
      ORDER BY r.waktu_service DESC, r.id DESC
    ''');
    return rows.map((row) {
      return _ServiceRecordSource(
        id: row['id'] as int,
        unitId: row['unit_id'] as int,
        customerId: row['customer_id'] as int,
        noNota: row['no_nota'] as String? ?? '',
        waktu: localTime(row['waktu_service']),
        unitType: row['unit_type'] as String? ?? 'MOBIL',
        unitLabel: row['unit_label'] as String? ?? 'Unit',
        customerNama: row['customer_nama'] as String? ?? '',
        nomorHp: normalizePhone(row['nomor_hp'] as String? ?? ''),
        consent: (row['wa_consent'] as int? ?? 1) == 1,
        dnc: (row['do_not_contact'] as int? ?? 0) == 1,
        bergaransi: (row['bergaransi'] as int? ?? 0) == 1,
        garansiSampai: _dateOrNull(row['garansi_sampai']),
        statusKlaim: row['status_klaim'] as String? ?? 'Belum claim',
        statusBayar: row['status_bayar'] as String? ?? 'LUNAS',
        sisaBayar: row['sisa_bayar'] as int? ?? 0,
        unitDitinggal: (row['unit_ditinggal'] as int? ?? 0) == 1,
        diambilAt: _dateTimeOrNull(row['diambil_at']),
      );
    }).toList();
  }

  Future<Map<int, List<_IntervalRow>>> _loadIntervals() async {
    final rows = await AppDatabase.instance.db.rawQuery('''
      SELECT service_record_id, deskripsi AS nama, harga_jasa_id AS ref,
        interval_servis_bulan, 'jasa' AS kind
      FROM service_jobs WHERE interval_servis_bulan > 0
      UNION ALL
      SELECT service_record_id, nama_part AS nama, stock_item_id AS ref,
        interval_servis_bulan, 'part' AS kind
      FROM service_parts WHERE interval_servis_bulan > 0
    ''');
    final result = <int, List<_IntervalRow>>{};
    for (final row in rows) {
      final recordId = row['service_record_id'] as int;
      result.putIfAbsent(recordId, () => []).add(
            _IntervalRow(
              nama: row['nama'] as String? ?? '',
              identifier: '${row['ref'] ?? ''}',
              intervalBulan: row['interval_servis_bulan'] as int? ?? 0,
              kind: row['kind'] as String? ?? 'jasa',
            ),
          );
    }
    return result;
  }

  Future<Map<int, _CustomerCounts>> _messageCounts(DateTime now) async {
    final startDay = startOfDay(now);
    final monthStart = startDay.subtract(const Duration(days: 30));
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT customer_id,
        SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END) AS today_count,
        SUM(CASE WHEN jenis = 'FOLLOWUP' AND created_at >= ?
          THEN 1 ELSE 0 END) AS month_count,
        MAX(CASE WHEN jenis = 'FOLLOWUP' THEN created_at END) AS last_at
      FROM wa_message_logs
      WHERE status = 'DIBUKA' AND customer_id IS NOT NULL
      GROUP BY customer_id
      ''',
      [
        isoStartOfDay(startDay),
        isoStartOfDay(monthStart),
      ],
    );
    return {
      for (final row in rows)
        row['customer_id'] as int: _CustomerCounts(
          today: row['today_count'] as int? ?? 0,
          month: row['month_count'] as int? ?? 0,
          lastFollowup: row['last_at'] == null
              ? null
              : localTime(row['last_at']),
        ),
    };
  }

  Future<Set<int>> _openUnitCustomers() async {
    final rows = await AppDatabase.instance.db.rawQuery('''
      SELECT DISTINCT u.customer_id
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      WHERE r.status <> 'VOID' AND r.unit_ditinggal = 1
        AND r.diambil_at IS NULL
    ''');
    return rows.map((row) => row['customer_id'] as int).toSet();
  }

  Future<Map<String, Object?>?> _loadItem(int id) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT f.*, c.nama AS customer_nama, c.nomor_hp,
        c.wa_consent, c.do_not_contact,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '')), ''), 'Unit') AS unit_label,
        r.no_nota, r.status_bayar, r.sisa_bayar, r.unit_ditinggal,
        r.diambil_at
      FROM followup_items f
      LEFT JOIN customers c ON c.id = f.customer_id
      LEFT JOIN vehicle_or_units u ON u.id = f.unit_id
      LEFT JOIN service_records r ON r.id = f.service_record_id
      WHERE f.id = ?
      LIMIT 1
      ''',
      [id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> _mergeGroup(
    Map<String, Object?> item,
    FollowupSettings settings,
    DateTime moment,
  ) async {
    final jenis = item['jenis'] as String? ?? '';
    final customerId = item['customer_id'];
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT f.*, c.nama AS customer_nama, c.nomor_hp,
        c.wa_consent, c.do_not_contact,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '')), ''), 'Unit') AS unit_label,
        r.no_nota, r.status_bayar, r.sisa_bayar, r.unit_ditinggal,
        r.diambil_at
      FROM followup_items f
      LEFT JOIN customers c ON c.id = f.customer_id
      LEFT JOIN vehicle_or_units u ON u.id = f.unit_id
      LEFT JOIN service_records r ON r.id = f.service_record_id
      WHERE f.customer_id = ? AND f.jenis = ? AND f.jatuh_tempo <= ?
        AND f.status IN ('BARU', 'SUDAH_FOLLOWUP', 'MASIH_KENDALA')
      ORDER BY f.jatuh_tempo, f.id
      ''',
      [customerId, jenis, _isoDay(startOfDay(moment))],
    );
    final filtered = rows.where((row) {
      final tunda = _dateTimeOrNull(row['tunda_sampai']);
      if (tunda != null && moment.isBefore(tunda)) return false;
      final last = _dateTimeOrNull(row['followup_terakhir']);
      if (last != null &&
          settings.cooldownHari > 0 &&
          moment.isBefore(
            last.add(Duration(days: settings.cooldownHari)),
          )) {
        return false;
      }
      if (jenis == 'piutang' && (row['sisa_bayar'] as int? ?? 0) <= 0) {
        return false;
      }
      return true;
    }).toList();
    if (filtered.every((row) => row['id'] != item['id'])) {
      filtered.add(item);
    }
    return filtered.isEmpty ? [item] : filtered;
  }

  FollowupRow _toRow(
    Map<String, Object?> row,
    FollowupSettings settings,
    DateTime moment,
    _CustomerCounts counts,
    bool openUnit,
    Map<String, Set<int>> dueByCustomer,
  ) {
    final jenis = row['jenis'] as String? ?? '';
    final due = _dateOnly(row['jatuh_tempo']) ?? startOfDay(moment);
    final today = startOfDay(moment);
    final customerId = row['customer_id'] as int? ?? 0;
    final phone = row['nomor_hp'] as String? ?? '';
    final status = row['status'] as String? ?? 'BARU';
    final consent = (row['wa_consent'] as int? ?? 1) == 1;
    final dnc = (row['do_not_contact'] as int? ?? 0) == 1;
    final last = _dateTimeOrNull(row['followup_terakhir']);
    final tunda = _dateTimeOrNull(row['tunda_sampai']);
    final janji = _dateOnly(row['janji_bayar']);
    final tanggalService = _dateOnly(row['tanggal_service']);
    final unitLabel = row['unit_label'] as String? ?? 'Unit';
    final noNota = row['no_nota'] as String? ?? '';
    final judul = switch (jenis) {
      'garansi' => 'Garansi $unitLabel berakhir ${_fmtDate(due)}',
      'servis_berkala' => 'Servis berkala $unitLabel',
      'piutang' => 'Piutang nota $noNota',
      'unit_selesai' => 'Unit siap diambil $unitLabel',
      _ => 'Follow up pasca servis $unitLabel',
    };

    String reason = '';
    final isClosed = closedFollowupStatuses.contains(status);
    if (!settings.aktif) {
      reason = 'Fitur follow up sedang dimatikan.';
    } else if (isClosed) {
      reason = status == 'ARSIP' ? 'Item sudah diarsipkan.' : 'Item sudah ditutup.';
    } else if (!consent) {
      reason = 'Pelanggan belum memberi izin menerima pesan WhatsApp.';
    } else if (dnc && jenis != 'piutang') {
      reason = 'Pelanggan meminta berhenti dihubungi (DNC).';
    } else if (!isValidWhatsApp(phone)) {
      reason = 'Nomor WhatsApp pelanggan belum valid.';
    } else if (last != null &&
        settings.cooldownHari > 0 &&
        moment.isBefore(last.add(Duration(days: settings.cooldownHari)))) {
      reason = 'Jeda follow up belum selesai.';
    } else if (tunda != null && moment.isBefore(tunda)) {
      reason = 'Follow up ditunda sampai ${_fmtDateTime(tunda)}.';
    } else if (!_withinWindow(settings, moment)) {
      reason =
          'Follow up hanya bisa dilakukan antara pukul ${settings.jamMulai} '
          '- ${settings.jamSelesai}.';
    } else if (counts.today >= settings.maksPesanHari) {
      reason = 'Batas pesan hari ini sudah tercapai. Coba lagi besok.';
    } else if ({'prospek', 'servis_berkala'}.contains(jenis) &&
        counts.month >= settings.maksPesanBulan) {
      reason = 'Batas ${settings.maksPesanBulan} pesan per bulan untuk '
          'prospek dan servis sudah tercapai.';
    } else if (jenis != 'piutang' &&
        (dueByCustomer['piutang']?.contains(customerId) ?? false)) {
      reason = 'Selesaikan pengingat piutang pelanggan ini lebih dulu.';
    } else if ({'prospek', 'servis_berkala'}.contains(jenis) &&
        (dueByCustomer['garansi']?.contains(customerId) ?? false)) {
      reason = 'Pengingat garansi pelanggan ini lebih utama.';
    } else if (jenis == 'prospek' &&
        (dueByCustomer['servis_berkala']?.contains(customerId) ?? false)) {
      reason = 'Pengingat servis berkala pelanggan ini lebih utama.';
    } else if (openUnit && jenis != 'unit_selesai') {
      reason =
          'Masih ada unit pelanggan di bengkel. Kabari pengambilan lebih dulu.';
    } else if (jenis == 'garansi' &&
        !today.isBefore(due) &&
        ((last != null &&
                !startOfDay(last).isBefore(
                  due.subtract(
                    Duration(days: settings.garansiAkanHabisHari),
                  ),
                )) ||
            (status == 'AKAN_DATANG' &&
                tanggalService != null &&
                !tanggalService.isAfter(due)))) {
      reason = 'Garansi H-7 sudah dibalas atau sudah ada janji datang.';
    }

    return FollowupRow(
      id: row['id'] as int,
      jenis: jenis,
      itemKey: row['item_key'] as String? ?? '',
      status: status,
      stage: row['stage'] as int? ?? 0,
      customerId: customerId,
      customerNama: row['customer_nama'] as String? ?? '',
      nomorHp: phone,
      nomorMasked: maskPhone(phone),
      unitId: row['unit_id'] as int? ?? 0,
      unitLabel: unitLabel,
      recordId: row['service_record_id'] as int?,
      noNota: noNota.isEmpty ? null : noNota,
      judul: judul,
      jatuhTempo: due,
      followupTerakhir: last,
      janjiBayar: janji,
      tanggalService: tanggalService,
      tundaSampai: tunda,
      noResponseCount: row['no_response_count'] as int? ?? 0,
      alasanArsip: row['alasan_arsip'] as String?,
      sisaHari: due.difference(today).inDays,
      terlambat: status != 'AKAN_DATANG' && due.isBefore(today),
      dnc: dnc,
      consent: consent,
      sisaBayar: row['sisa_bayar'] as int? ?? 0,
      bisaFollowup: reason.isEmpty,
      bisaAlasan: reason,
    );
  }

  String _message(
    Map<String, Object?> item,
    DateTime moment,
    String storeName,
  ) {
    final customer = item['customer_nama'] as String? ?? '';
    final jenis = item['jenis'] as String? ?? '';
    final unit = item['unit_label'] as String? ?? 'unit';
    final noNota = item['no_nota'] as String? ?? '';
    final due = _dateOnly(item['jatuh_tempo']) ?? startOfDay(moment);
    final sisa = item['sisa_bayar'] as int? ?? 0;
    final opening =
        '${_greeting(moment)} Bapak/Ibu $customer. Kami dari $storeName.';
    String body;
    switch (jenis) {
      case 'garansi':
        final days = due.difference(startOfDay(moment)).inDays;
        body = 'Kami ingin menginformasikan bahwa garansi servis $unit '
            'akan berakhir pada ${_fmtDate(due)}'
            '${days >= 0 ? ' ($days hari lagi)' : ''}. '
            'Bagaimana kondisi $unit saat ini? Apabila masih ada kendala, '
            'kami berharap Bapak/Ibu berkenan memeriksakan kembali sebelum '
            'masa garansi berakhir.';
      case 'servis_berkala':
        body = 'Kami ingin mengingatkan jadwal servis berkala untuk $unit '
            'sekitar ${_fmtDate(due)}. Kami berharap Bapak/Ibu berkenan '
            'menjadwalkan kedatangan ke bengkel kami.';
      case 'piutang':
        body = 'Kami ingin mengingatkan sisa pembayaran nota $noNota '
            'sebesar ${formatRupiah(sisa)} untuk $unit. Mohon kiranya '
            'pembayaran dapat diselesaikan. Apabila sudah dibayar, mohon '
            'abaikan pesan ini.';
      case 'unit_selesai':
        body = 'Kami ingin menginformasikan bahwa $unit sudah selesai '
            'dikerjakan dan siap diambil. Kami berharap Bapak/Ibu berkenan '
            'mengambil unit tersebut di bengkel kami.';
      default:
        body = 'Kami ingin menanyakan kondisi $unit setelah servis terakhir. '
            'Apakah masih ada kendala? Kami berharap Bapak/Ibu berkenan '
            'menghubungi kami apabila perlu dilakukan pemeriksaan ulang.';
    }
    return '$opening $body\n\nTerima kasih atas perhatian Bapak/Ibu.';
  }

  String _groupMessage(
    List<Map<String, Object?>> items,
    DateTime moment,
    String storeName,
  ) {
    final customer = items.first['customer_nama'] as String? ?? '';
    final lines = items.map((item) {
      final jenis = item['jenis'] as String? ?? '';
      final unit = item['unit_label'] as String? ?? 'unit';
      final noNota = item['no_nota'] as String? ?? '';
      final due = _dateOnly(item['jatuh_tempo']) ?? startOfDay(moment);
      final label = switch (jenis) {
        'garansi' => 'Garansi $unit',
        'servis_berkala' => 'Servis berkala $unit',
        'piutang' => 'Piutang nota $noNota '
            '(${formatRupiah(item['sisa_bayar'] as int? ?? 0)})',
        'unit_selesai' => 'Unit siap diambil $unit',
        _ => 'Follow up pasca servis $unit',
      };
      return '- $label (jadwal ${_fmtDate(due)})';
    }).join('\n');
    return '${_greeting(moment)} Bapak/Ibu $customer. Kami dari $storeName.\n\n'
        'Kami ingin menyampaikan beberapa pengingat berikut:\n$lines\n\n'
        'Apabila sudah ditindaklanjuti, mohon abaikan pesan ini.\n\n'
        'Terima kasih atas perhatian Bapak/Ibu.';
  }

  Future<void> _addEvent(
    DatabaseExecutor executor,
    int itemId,
    String jenis,
    String? status,
    String? catatan,
    DateTime moment,
  ) async {
    await executor.insert('followup_events', {
      'sync_id': newSyncId(),
      'item_id': itemId,
      'jenis': jenis,
      'status': status,
      'catatan': catatan,
      'created_at': _isoMoment(moment),
      'updated_at': _isoMoment(moment),
    });
  }

  Future<void> _archive(
    DatabaseExecutor executor,
    int itemId,
    String reason,
    DateTime moment,
  ) async {
    await executor.update(
      'followup_items',
      {
        'status': 'ARSIP',
        'alasan_arsip': reason,
        'updated_at': _isoMoment(moment),
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
    await _addEvent(executor, itemId, 'ARSIP', 'ARSIP', reason, moment);
  }

  String _waJenis(String jenis) => switch (jenis) {
        'garansi' => 'GARANSI',
        'piutang' => 'PIUTANG',
        _ => 'FOLLOWUP',
      };
}

class _IntervalRow {
  const _IntervalRow({
    required this.nama,
    required this.identifier,
    required this.intervalBulan,
    required this.kind,
  });

  final String nama;
  final String identifier;
  final int intervalBulan;
  final String kind;
}

bool _withinWindow(FollowupSettings settings, DateTime moment) {
  final start = _parseClock(settings.jamMulai) ?? 8 * 60;
  final end = _parseClock(settings.jamSelesai) ?? 20 * 60;
  if (start == end) return true;
  final minutes = moment.hour * 60 + moment.minute;
  if (start < end) return minutes >= start && minutes < end;
  return minutes >= start || minutes < end;
}

int? _parseClock(String value) {
  final match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(value);
  if (match == null) return null;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

DateTime addMonths(DateTime day, int months) {
  if (months == 0) return startOfDay(day);
  final total = day.month - 1 + months;
  final year = day.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  final targetDay = day.day > lastDay ? lastDay : day.day;
  return DateTime(year, month, targetDay);
}

DateTime addDays(DateTime day, int days) =>
    startOfDay(day).add(Duration(days: days));

DateTime? _dateOrNull(Object? value) {
  if (value == null) return null;
  final parsed = DateTime.tryParse('$value');
  return parsed == null ? null : startOfDay(parsed);
}

DateTime? _dateTimeOrNull(Object? value) {
  final parsed = value == null ? null : DateTime.tryParse('$value');
  return parsed?.toLocal();
}

DateTime? _dateOnly(Object? value) => _dateOrNull(value);

String _isoDay(DateTime day) => DateFormat('yyyy-MM-dd').format(day);

String _isoMoment(DateTime moment) => moment.toUtc().toIso8601String();

String _fmtDate(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}/'
    '${day.month.toString().padLeft(2, '0')}/${day.year}';

String _fmtDateTime(DateTime value) =>
    '${_fmtDate(value)} ${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _greeting(DateTime moment) {
  final hour = moment.hour;
  if (hour < 11) return 'Selamat pagi,';
  if (hour < 15) return 'Selamat siang,';
  if (hour < 18) return 'Selamat sore,';
  return 'Selamat malam,';
}
