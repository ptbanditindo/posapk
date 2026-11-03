import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import '../core/dates.dart';
import '../sync/crypto.dart';
import 'app_database.dart';
import 'device_service.dart';
import 'license_service.dart';
import 'secure_store.dart';

class OwnerSummaryService {
  OwnerSummaryService._();

  static final OwnerSummaryService instance = OwnerSummaryService._();

  Future<String> buildSignedSummary() async {
    final ownerId = await LicenseService.instance.ownerId();
    final ownerPublic = await LicenseService.instance.ownerPublicKey();
    final privateKey = await SecureStore.instance.read('owner.signing.private');
    if (ownerId == null || ownerPublic == null || privateKey == null) {
      throw StateError('Identitas owner belum tersedia.');
    }
    final status = await LicenseService.instance.status();
    final devices = await DeviceService.instance.listDevices();
    final storeName =
        await AppDatabase.instance.getSetting('bengkel.nama') ?? 'PusatkuPOS';
    final payload = {
      'v': 1,
      'owner_id': ownerId,
      'plan': status['plan'],
      'period_end': status['period_end'],
      'device_limit': status['device_limit'],
      'stores': [
        {'store_id': 'utama', 'nama': storeName},
      ],
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

  Future<String?> export() async {
    final summary = await buildSignedSummary();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Simpan ringkasan owner',
      fileName: 'pusatkupos_owner_$stamp.json',
      bytes: utf8.encode(summary),
      mimeType: 'application/json',
    );
    return uri?.toString();
  }
}
