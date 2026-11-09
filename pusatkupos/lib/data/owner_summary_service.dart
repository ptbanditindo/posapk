import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import '../auth/operator.dart';
import '../core/dates.dart';
import '../sync/crypto.dart';
import 'app_database.dart';
import 'device_service.dart';
import 'license_service.dart';
import 'pin_service.dart';
import 'secure_store.dart';
import 'store_service.dart';

class OwnerSummaryService {
  OwnerSummaryService._();

  static final OwnerSummaryService instance = OwnerSummaryService._();

  Future<String> buildSignedSummary({required Operator actor}) async {
    if (!actor.isOwner) {
      throw StateError('Hanya pemilik yang dapat membuat ringkasan owner.');
    }
    final ownerId = await LicenseService.instance.ownerId();
    final ownerPublic = await LicenseService.instance.ownerPublicKey();
    final privateKey = await SecureStore.instance.read('owner.signing.private');
    if (ownerId == null || ownerPublic == null || privateKey == null) {
      throw StateError('Identitas owner belum tersedia.');
    }
    final status = await LicenseService.instance.status();
    final devices = await DeviceService.instance.listDevices();
    final financial = await AppDatabase.instance.reportSummary(
      DateTime(2000),
      DateTime(2100),
    );
    final storeName =
        await AppDatabase.instance.getSetting('bengkel.nama') ?? 'PusatkuPOS';
    List<Map<String, String>> stores;
    try {
      final records = await StoreService.instance.listStores();
      stores = records
          .map(
            (store) => {
              'store_id': store.storeId,
              'nama': store.nama,
            },
          )
          .toList();
    } catch (_) {
      stores = [
        {'store_id': 'utama', 'nama': storeName},
      ];
    }
    final payload = {
      'v': 1,
      'owner_id': ownerId,
      'plan': status['plan'],
      'period_end': status['period_end'],
      'store_limit': status['store_limit'],
      // Token lisensi penuh tidak ikut diekspor. Perangkat ringkasan
      // mendapatkannya lewat aktivasi Google/relay, bukan berkas ini.
      'license_token_present': '${status['token'] ?? ''}'.isNotEmpty,
      'store_id': AppDatabase.instance.activeStoreId ?? 'utama',
      'financial': {
        'basis': 'semua_data',
        'transaksi': financial.transaksi,
        'omzet_bruto_cents': financial.totalCents,
        'dibayar_cents': financial.dibayarCents,
        'piutang_cents': financial.piutangCents,
        'retur_ditagih_cents': financial.returDitagihCents,
        'omzet_neto_cents': financial.totalNetCents,
        'dpp_cents': financial.totalDppCents,
        'ppn_cents': financial.pajakCents,
        'ppn_diserap_cents': financial.pajakDiserapCents,
        'hpp_part_cents': financial.totalModalPartCents,
        'hpp_jasa_cents': financial.totalModalJasaCents,
        'laba_kotor_cents': financial.labaKotorCents,
        'laba_kotor_neto_cents': financial.labaKotorNetCents,
        'komisi_cents': financial.komisiCents,
        'gaji_cents': financial.gajiCents,
        'kas_per_metode_cents': financial.cashByMethod,
      },
      'stores': stores,
      'devices': devices
          .map(
            (device) => {
              'id': device['id'],
              'nama': device['nama'],
              'kind': device['kind'],
              'revoked_at': device['revoked_at'],
            },
          )
          .toList(),
      'generated_at': nowIso(),
    };
    final raw = canonicalJson(payload);
    final signature = await signPayload(privateKey, utf8.encode(raw));
    return jsonEncode({
      'payload': payload,
      'signature': signature,
      'public_key': ownerPublic,
    });
  }

  Future<String?> export({
    required Operator actor,
    required String pin,
  }) async {
    if (!actor.isOwner) {
      throw StateError('Hanya pemilik yang dapat mengekspor ringkasan');
    }
    final verification = await PinService.instance.verifyDetailed(pin);
    if (verification != PinVerification.ok) {
      throw StateError(
        'PIN pemilik wajib valid dan minimal 6 digit untuk mengekspor.',
      );
    }
    final summary = await buildSignedSummary(actor: actor);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Simpan ringkasan owner',
      fileName: 'pusatkupos_ringkasan_$stamp.json',
      bytes: utf8.encode(summary),
      mimeType: 'application/json',
    );
    return uri?.toString();
  }
}
