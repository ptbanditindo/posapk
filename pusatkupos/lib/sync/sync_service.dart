import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/app_config.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import '../core/quantity.dart';
import '../core/relay_url.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/device_service.dart';
import '../data/feature_flags.dart';
import '../data/license_service.dart';
import '../data/license_verifier.dart';
import '../data/models.dart';
import '../data/note_sync.dart';
import '../data/nota_adjustment_service.dart';
import '../data/opname_service.dart';
import '../data/opening_balance_service.dart';
import '../data/purchase_service.dart';
import '../data/store_settings.dart';
import '../data/secure_store.dart';
import 'crypto.dart';
import 'protocol.dart';
import 'relay_client.dart';
import 'snapshot_sync.dart';
import 'sync_conflict_rules.dart';
import 'sync_secrets.dart';

class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  Future<String?> _setting(String key) => AppDatabase.instance.getSetting(key);

  Future<String?> setting(String key) => _setting(key);

  Future<void> _requirePremium() async {
    if (!await LicenseService.instance.isPremium()) {
      throw StateError(
        'Lisensi server yang valid diperlukan untuk sinkronisasi dan '
        'multi-toko. Kasir offline tetap dapat dipakai.',
      );
    }
  }

  Future<void> configure({
    required String relayUrl,
    required String enrollToken,
    required String storeId,
  }) async {
    await AppDatabase.instance.setSetting(
      'sync.relay_url',
      normalizeRelayUrl(relayUrl),
    );
    final enroll = enrollToken.trim();
    if (enroll.isEmpty) {
      await SecureStore.instance.delete('sync.enroll_token');
    } else {
      await SecureStore.instance.write('sync.enroll_token', enroll);
    }
    await AppDatabase.instance.deleteSetting('sync.enroll_token');
    await AppDatabase.instance.setSetting(
      'sync.store_id',
      storeId.trim().isEmpty ? 'utama' : storeId.trim(),
    );
  }

  Future<String?> relayUrl() async {
    if (serviceConfigured) return normalizedServiceUrl;
    return _setting('sync.relay_url');
  }

  Future<String?> enrollToken() async {
    final stored = await SecureStore.instance.read('sync.enroll_token');
    if (stored != null && stored.isNotEmpty) return stored;
    final legacy = await _setting('sync.enroll_token');
    if (legacy == null || legacy.isEmpty) return null;
    await SecureStore.instance.write('sync.enroll_token', legacy);
    await AppDatabase.instance.deleteSetting('sync.enroll_token');
    return legacy;
  }

  Future<String> storeId() async =>
      (await _setting('sync.store_id')) ?? 'utama';

  Future<String?> relayDeviceId() => _setting('sync.relay_device_id');

  Future<String?> relayDeviceToken() async {
    final stored = await SyncSecrets.instance.read('sync.relay_device_token');
    if (stored != null && stored.isNotEmpty) return stored;
    final legacy = await _setting('sync.relay_device_token');
    if (legacy == null || legacy.isEmpty) return null;
    await SyncSecrets.instance.write('sync.relay_device_token', legacy);
    await AppDatabase.instance.deleteSetting('sync.relay_device_token');
    return legacy;
  }

  Future<List<int>?> existingStoreKey() async {
    final stored = await SyncSecrets.instance.read('sync.store_key');
    if (stored == null || stored.isEmpty) return null;
    return b64d(stored);
  }

  Future<List<int>> ensureStoreKey() async {
    final stored = await existingStoreKey();
    if (stored != null) return stored;
    final secureRandom = Random.secure();
    final random = List<int>.generate(32, (_) => secureRandom.nextInt(256));
    await SyncSecrets.instance.write('sync.store_key', b64e(random));
    return random;
  }

  Future<String> pinnedOwnerPublicKey() async {
    final rows = await AppDatabase.instance.db.query(
      'owner_identity',
      columns: ['public_key'],
      limit: 1,
    );
    final key = rows.isEmpty ? '' : rows.first['public_key'] as String? ?? '';
    if (key.isEmpty) {
      throw StateError(
        'Kunci publik owner belum dipin. Impor ringkasan owner atau '
        'lakukan pairing terlebih dahulu.',
      );
    }
    return key;
  }

  Future<void> _verifyKeyWrap({
    required String store,
    required String deviceId,
    required String wrapped,
    required String signature,
  }) async {
    if (signature.isEmpty) {
      throw StateError(
        'Relay tidak mengirim tanda tangan key-wrap. Perubahan relay '
        'diperlukan sebelum kunci toko dapat dipercaya.',
      );
    }
    final ownerKey = await pinnedOwnerPublicKey();
    final valid = await verifyPayload(
      ownerKey,
      utf8.encode(
        canonicalJson({
          'store_id': store,
          'device_id': deviceId,
          'wrapped_key': wrapped,
        }),
      ),
      signature,
    );
    if (!valid) {
      throw StateError(
        'Tanda tangan key-wrap tidak cocok dengan kunci owner yang dipin.',
      );
    }
  }

  Future<bool> refreshStoreKey() async {
    final url = await relayUrl();
    final relayId = await relayDeviceId();
    final localId = await _setting('sync.local_device_id');
    final token = await relayDeviceToken();
    if (url == null ||
        url.isEmpty ||
        relayId == null ||
        localId == null ||
        token == null ||
        token.isEmpty) {
      return (await existingStoreKey()) != null;
    }
    final store = await storeId();
    final boot = await RelayClient(baseUrl: url, deviceToken: token)
        .bootstrap(store);
    final wrapped = boot['wrapped_key'] as String? ?? '';
    if (wrapped.isEmpty) return (await existingStoreKey()) != null;
    await _verifyKeyWrap(
      store: store,
      deviceId: relayId,
      wrapped: wrapped,
      signature: boot['wrapped_key_signature'] as String? ?? '',
    );
    final encryptionPrivate =
        await DeviceService.instance.encryptionPrivateKey(localId);
    if (encryptionPrivate == null) {
      throw StateError('Kunci enkripsi perangkat tidak tersedia.');
    }
    final storeKey = await unwrapStoreKey(encryptionPrivate, wrapped);
    await SyncSecrets.instance.write('sync.store_key', b64e(storeKey));
    return true;
  }

  Future<void> wrapStoreKeyForDevice({
    required String targetRelayDeviceId,
    required String targetEncryptionKey,
  }) async {
    await _requirePremium();
    final url = await relayUrl();
    final token = await relayDeviceToken();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      throw StateError('Daftarkan perangkat ini ke relay terlebih dahulu.');
    }
    final ownerPrivate =
        await SecureStore.instance.read('owner.signing.private');
    if (ownerPrivate == null) throw StateError('Kunci owner tidak tersedia.');
    final storeKey = await ensureStoreKey();
    final wrapped = await wrapStoreKey(targetEncryptionKey, storeKey);
    final signature = await signPayload(
      ownerPrivate,
      utf8.encode(
        canonicalJson({
          'store_id': await storeId(),
          'device_id': targetRelayDeviceId,
          'wrapped_key': wrapped,
        }),
      ),
    );
    await RelayClient(baseUrl: url, deviceToken: token).putKeyWrap(
      storeId: await storeId(),
      deviceId: targetRelayDeviceId,
      wrappedKey: wrapped,
      signature: signature,
    );
  }

  Future<List<Map<String, Object?>>> relayDevices() async {
    final url = await relayUrl();
    final token = await relayDeviceToken();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      throw StateError('Daftarkan perangkat ini ke relay terlebih dahulu.');
    }
    return RelayClient(baseUrl: url, deviceToken: token).devices();
  }

  /// Membuat kode pairing karyawan yang berlaku 10 menit dan sekali pakai.
  Future<Map<String, Object?>> createPairingInvite({
    required String accountSyncId,
    String? storeId,
    int ttlMinutes = 10,
  }) async {
    await _requirePremium();
    final url = await relayUrl();
    final token = await relayDeviceToken();
    final ownerId = await LicenseService.instance.ownerId();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      throw StateError('Perangkat ini belum terhubung ke server akun.');
    }
    if (ownerId == null || ownerId.isEmpty) {
      throw StateError('Identitas pemilik belum tersedia.');
    }
    final targetStore = (storeId == null || storeId.trim().isEmpty)
        ? await this.storeId()
        : storeId.trim();
    return RelayClient(baseUrl: url, deviceToken: token).createInvite(
      ownerId: ownerId,
      accountSyncId: accountSyncId,
      storeId: targetStore,
      ttlMinutes: ttlMinutes,
    );
  }

  Future<void> revokeRelayDevice(String relayDeviceId) async {
    final url = await relayUrl();
    final token = await relayDeviceToken();
    final ownerId = await LicenseService.instance.ownerId();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      throw StateError('Perangkat ini belum terhubung ke server akun.');
    }
    if (ownerId == null || ownerId.isEmpty) {
      throw StateError('Identitas pemilik belum tersedia.');
    }
    await RelayClient(baseUrl: url, deviceToken: token).revokeManagedDevice(
      ownerId: ownerId,
      deviceId: relayDeviceId,
    );
  }

  /// Cabut perangkat ini di relay (bila memungkinkan) lalu hapus seluruh
  /// rahasia sinkronisasi lokal. Data toko tidak disentuh.
  Future<void> purgeDeviceIdentity({bool revokeOnRelay = true}) async {
    final relayId = await relayDeviceId();
    final token = await relayDeviceToken();
    final localId = await _setting('sync.local_device_id');
    if (revokeOnRelay &&
        relayId != null &&
        relayId.isNotEmpty &&
        token != null &&
        token.isNotEmpty) {
      try {
        await revokeRelayDevice(relayId);
      } catch (_) {
        // Relay mungkin tidak terjangkau; rahasia lokal tetap harus dibuang.
      }
    }
    final deviceRows = await AppDatabase.instance.db.query(
      'devices',
      columns: ['id'],
    );
    for (final row in deviceRows) {
      final id = '${row['id'] ?? ''}';
      if (id.isEmpty) continue;
      await SecureStore.instance.delete('device.$id.sign');
      await SecureStore.instance.delete('device.$id.encrypt');
      await SecureStore.instance.delete('device.$id.token');
    }
    await SyncSecrets.instance.delete('device.current_token');
    await SyncSecrets.instance.delete('sync.relay_device_token');
    await SyncSecrets.instance.delete('sync.store_key');
    await AppDatabase.instance.deleteSetting('device.current_id');
    await AppDatabase.instance.deleteSetting('sync.local_device_id');
    await AppDatabase.instance.deleteSetting('sync.relay_device_id');
    await AppDatabase.instance.deleteSetting('sync.relay_device_token');
    await AppDatabase.instance.deleteSetting('sync.last_success_at');
    await AppDatabase.instance.deleteSetting('sync.last_error');
    for (final device in [relayId, localId]) {
      if (device == null || device.isEmpty) continue;
      await AppDatabase.instance.db.delete(
        'sync_cursor',
        where: 'device_id = ?',
        whereArgs: [device],
      );
    }
  }

  Future<Map<String, Object?>> bootstrapNow() async {
    await _requirePremium();
    final url = await relayUrl();
    final relayId = await relayDeviceId();
    final token = await relayDeviceToken();
    if (url == null ||
        url.isEmpty ||
        relayId == null ||
        token == null ||
        token.isEmpty) {
      throw StateError('Daftarkan perangkat ini ke relay terlebih dahulu.');
    }
    final keyReady = await refreshStoreKey();
    if (!keyReady) {
      throw StateError('Kunci toko belum tersedia.');
    }
    final storeKey = (await existingStoreKey())!;
    final store = await storeId();
    final client = RelayClient(baseUrl: url, deviceToken: token);
    final boot = await client.bootstrap(store);
    final cursor = (boot['cursor'] as num?)?.toInt() ?? 0;
    final rawSnapshot = boot['snapshot'];
    if (rawSnapshot is! Map) {
      return {
        'applied': false,
        'snapshot': false,
        'cursor': cursor,
        'snapshot_required': boot['snapshot_required'] == true,
      };
    }
    final snapshot = Map<String, Object?>.from(rawSnapshot);
    final snapshotSeq = (snapshot['store_seq'] as num?)?.toInt() ?? 0;
    final localCursor = await _cursor(store, relayId);
    final snapshotRequired = boot['snapshot_required'] == true;
    if (!snapshotRequired && snapshotSeq <= localCursor) {
      // Perangkat sudah melewati snapshot terakhir. Menerapkannya justru
      // akan menggulung data lokal yang lebih baru.
      return {
        'applied': false,
        'snapshot': true,
        'skipped': true,
        'cursor': localCursor,
        'snapshot_required': false,
      };
    }
    final sender = snapshot['device_id'] as String? ?? '';
    final devices = await client.devices();
    String? senderKey;
    for (final device in devices) {
      if (device['id'] == sender) {
        senderKey = device['public_key'] as String?;
      }
    }
    if (senderKey == null) {
      throw StateError('Kunci publik pengirim snapshot tidak ditemukan.');
    }
    final result = await AppDatabase.instance.applySnapshotPayload(
      snapshot,
      senderPublicKey: senderKey,
      storeKey: storeKey,
      storeId: store,
      deviceId: relayId,
    );
    if (result['applied'] != true) {
      return {
        'applied': false,
        'snapshot': true,
        'stale': result['stale'] == true,
        'duplicate': result['duplicate'] == true,
        'cursor': localCursor,
        'snapshot_required': false,
      };
    }
    final seq = (result['store_seq'] as num?)?.toInt() ?? snapshotSeq;
    await client.ack(storeId: store, lastSeq: seq);
    await _setCursor(store, relayId, seq);
    await AppDatabase.instance.deleteSetting(
      'sync.restore_requires_bootstrap',
    );
    return {
      'applied': true,
      'snapshot': true,
      'cursor': seq,
      'snapshot_required': false,
    };
  }

  Future<void> _ackOpenRound(
    RelayClient client, {
    required String store,
    required int lastSeq,
  }) async {
    final open = await client.openSyncRound(store);
    final raw = open['round'];
    if (raw is! Map) return;
    final round = Map<String, Object?>.from(raw);
    final id = '${round['id'] ?? ''}';
    if (id.isEmpty) return;
    await client.ackSyncRound(
      roundId: id,
      storeId: store,
      lastSeq: lastSeq,
      pending: await pendingCount(),
    );
  }

  Future<void> _cacheRoundStatus(Map<String, Object?> round) async {
    final devices = round['devices'];
    if (devices is! List) return;
    final stamp = nowIso();
    await AppDatabase.instance.db.transaction((txn) async {
      await txn.delete('device_sync_status');
      for (final raw in devices.whereType<Map>()) {
        final id = '${raw['id'] ?? ''}';
        if (id.isEmpty) continue;
        await txn.insert(
          'device_sync_status',
          {
            'device_id': id,
            'nama': '${raw['nama'] ?? 'Perangkat'}',
            'kind': '${raw['kind'] ?? 'owner'}',
            'state': '${raw['state'] ?? 'pending'}',
            'last_seq': (raw['last_seq'] as num?)?.toInt() ?? 0,
            'pending': (raw['pending'] as num?)?.toInt() ?? 0,
            'updated_at': stamp,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<Map<String, Object?>>> cachedDeviceSyncStatus() async {
    return AppDatabase.instance.db.query(
      'device_sync_status',
      orderBy: 'kind DESC, nama COLLATE NOCASE',
    );
  }

  /// Membuka pemeriksaan kelengkapan. Unggahan hanya boleh dilakukan setelah
  /// semua perangkat tulis pada toko ini mengaku sudah sinkron.
  Future<Map<String, Object?>> startUploadCheck() async {
    await _requirePremium();
    final url = await relayUrl();
    final relayId = await relayDeviceId();
    final token = await relayDeviceToken();
    if (url == null ||
        url.isEmpty ||
        relayId == null ||
        token == null ||
        token.isEmpty) {
      throw StateError('Daftarkan perangkat ini terlebih dahulu.');
    }
    final store = await storeId();
    await _requireCleanBeforeUpload();
    final keyReady = await refreshStoreKey();
    if (!keyReady) throw StateError('Kunci toko belum tersedia.');
    final client = RelayClient(baseUrl: url, deviceToken: token);
    final boot = await client.bootstrap(store);
    final latest = (boot['latest_seq'] as num?)?.toInt() ?? 0;
    final localCursor = await _cursor(store, relayId);
    if (latest > localCursor) {
      throw StateError('Sinkronkan perangkat ini sebelum membuat cadangan.');
    }
    final round = await client.createSyncRound(store);
    final id = '${round['id'] ?? ''}';
    if (id.isEmpty) throw StateError('Pemeriksaan perangkat gagal dibuat.');
    final roundLatest = (round['latest_seq'] as num?)?.toInt() ?? 0;
    if (roundLatest != latest) {
      throw StateError(
        'Ada data baru masuk saat pemeriksaan. Ulangi pemeriksaan.',
      );
    }
    await client.ackSyncRound(
      roundId: id,
      storeId: store,
      lastSeq: latest,
      pending: 0,
    );
    final status = await client.syncRound(id);
    await _cacheRoundStatus(status);
    return status;
  }

  Future<Map<String, Object?>> refreshUploadCheck(String roundId) async {
    await _requirePremium();
    final url = await relayUrl();
    final token = await relayDeviceToken();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      throw StateError('Daftarkan perangkat ini terlebih dahulu.');
    }
    final client = RelayClient(baseUrl: url, deviceToken: token);
    final status = await client.syncRound(roundId);
    await _cacheRoundStatus(status);
    return status;
  }

  Future<Map<String, Object?>> uploadSnapshot({required String roundId}) async {
    await _requirePremium();
    final url = await relayUrl();
    final relayId = await relayDeviceId();
    final localId = await _setting('sync.local_device_id');
    final token = await relayDeviceToken();
    if (url == null ||
        url.isEmpty ||
        relayId == null ||
        localId == null ||
        token == null ||
        token.isEmpty) {
      throw StateError('Daftarkan perangkat ini ke relay terlebih dahulu.');
    }
    final privateKey = await DeviceService.instance.privateKey(localId);
    if (privateKey == null) throw StateError('Kunci perangkat tidak tersedia.');
    final keyReady = await refreshStoreKey();
    if (!keyReady) {
      throw StateError('Kunci toko belum tersedia.');
    }
    final storeKey = (await existingStoreKey())!;
    final store = await storeId();
    await _requireCleanBeforeUpload();
    final client = RelayClient(baseUrl: url, deviceToken: token);
    final status = await client.syncRound(roundId);
    await _cacheRoundStatus(status);
    if (status['complete'] != true) {
      throw StateError(
        'Cadangan belum lengkap: masih ada perangkat yang belum sinkron.',
      );
    }
    final latest = (status['latest_seq'] as num?)?.toInt() ?? 0;
    final localCursor = await _cursor(store, relayId);
    if (latest > localCursor) {
      throw StateError('Sinkronkan perangkat ini sebelum membuat snapshot.');
    }
    final snapshot = await AppDatabase.instance.createSnapshotPayload(
      storeId: store,
      deviceId: relayId,
      devicePrivateKey: privateKey,
      storeKey: storeKey,
      storeSeq: latest,
    );
    return client.createSnapshot({
      'store_id': store,
      'store_seq': latest,
      'round_id': roundId,
      'ciphertext': snapshot['ciphertext'],
      'nonce': snapshot['nonce'],
      'signature': snapshot['signature'],
      'checksum': snapshot['checksum'],
      'hlc_wall': snapshot['hlc_wall'],
      'hlc_counter': snapshot['hlc_counter'],
    });
  }

  Future<Map<String, Object?>> registerRelayDevice({
    required String nama,
    bool viewer = false,
  }) async {
    await _requirePremium();
    final url = await relayUrl();
    final enroll = await enrollToken();
    final ownerId = await LicenseService.instance.ownerId();
    final ownerPublic = await LicenseService.instance.ownerPublicKey();
    final ownerPrivate = await SecureStore.instance.read('owner.signing.private');
    if (url == null || url.isEmpty || enroll == null || enroll.isEmpty) {
      throw StateError('Alamat relay dan token pendaftaran wajib diisi.');
    }
    if (ownerId == null || ownerPublic == null) {
      throw StateError('Impor ringkasan owner terlebih dahulu.');
    }
    if (!viewer && ownerPrivate == null) {
      throw StateError('Aktifkan premium dan identitas owner terlebih dahulu.');
    }
    var device = await DeviceService.instance.currentDevice();
    if (device == null) {
      await DeviceService.instance.registerDevice(
        nama: nama,
        kind: 'owner',
        makeCurrent: true,
      );
      device = await DeviceService.instance.currentDevice();
    }
    if (device == null) throw StateError('Perangkat lokal belum terdaftar.');
    final client = RelayClient(baseUrl: url);
    final response = await client.enroll(
      enrollToken: enroll,
      ownerId: ownerId,
      nama: nama,
      publicKey: device['public_key'] as String,
      encryptionKey: device['encryption_key'] as String,
      ownerPublicKey: ownerPublic,
      storeIds: [await storeId()],
      kind: viewer ? 'viewer' : 'owner',
    );
    final relayDevice = response['device'] as Map<String, Object?>? ?? const {};
    final relayId = relayDevice['id'] as String? ?? '';
    final token = response['token'] as String? ?? '';
    if (relayId.isEmpty || token.isEmpty) {
      throw StateError('Relay tidak mengembalikan perangkat/token.');
    }
    await AppDatabase.instance.setSetting('sync.relay_device_id', relayId);
    await AppDatabase.instance.setSetting('sync.local_device_id', device['id'] as String);
    await SyncSecrets.instance.write('sync.relay_device_token', token);
    await AppDatabase.instance.deleteSetting('sync.relay_device_token');
    await AppDatabase.instance.deleteSetting(
      'sync.restore_requires_bootstrap',
    );
    final clientWithToken = RelayClient(baseUrl: url, deviceToken: token);
    final boot = await clientWithToken.bootstrap(await storeId());
    final wrappedExisting = boot['wrapped_key'] as String? ?? '';
    var keyPending = false;
    if (wrappedExisting.isNotEmpty) {
      await _verifyKeyWrap(
        store: await storeId(),
        deviceId: relayId,
        wrapped: wrappedExisting,
        signature: boot['wrapped_key_signature'] as String? ?? '',
      );
      final encryptionPrivate = await DeviceService.instance
          .encryptionPrivateKey(device['id'] as String);
      if (encryptionPrivate == null) {
        throw StateError('Kunci enkripsi perangkat tidak tersedia.');
      }
      final storeKey = await unwrapStoreKey(encryptionPrivate, wrappedExisting);
      await SyncSecrets.instance.write('sync.store_key', b64e(storeKey));
    } else if (viewer) {
      keyPending = (await existingStoreKey()) == null;
    } else if (boot['store_key_exists'] != true) {
      final storeKey = await ensureStoreKey();
      final wrapped = await wrapStoreKey(
        device['encryption_key'] as String,
        storeKey,
      );
      final signature = await signPayload(
        ownerPrivate!,
        utf8.encode(
          canonicalJson({
            'store_id': await storeId(),
            'device_id': relayId,
            'wrapped_key': wrapped,
          }),
        ),
      );
      await clientWithToken.putKeyWrap(
        storeId: await storeId(),
        deviceId: relayId,
        wrappedKey: wrapped,
        signature: signature,
      );
    } else {
      keyPending = (await existingStoreKey()) == null;
    }
    return {
      'relay_device_id': relayId,
      'local_device_id': device['id'],
      'key_pending': keyPending,
    };
  }

  Future<int> pendingCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_outbox WHERE status = 'pending'",
    );
    return rows.first['total'] as int? ?? 0;
  }

  Future<int> pendingInboxCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_inbox WHERE status = 'pending'",
    );
    return rows.first['total'] as int? ?? 0;
  }

  Future<int> failedInboxCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_inbox WHERE status = 'failed'",
    );
    return rows.first['total'] as int? ?? 0;
  }

  Future<int> openConflictCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_conflicts "
      "WHERE resolved_at IS NULL AND status != 'ignored'",
    );
    return rows.first['total'] as int? ?? 0;
  }

  /// Konflik yang masih menghalangi unggahan: delta belum diterapkan atau
  /// konflik permanen yang belum diselesaikan pengguna. Konflik `review`
  /// tidak menghalangi karena datanya sudah diterapkan.
  Future<int> blockingConflictCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS total FROM sync_conflicts "
      "WHERE resolved_at IS NULL AND ("
      "status IN ('failed', 'retrying') "
      "OR (status = 'open' AND reason != 'versi_lokal_lebih_baru' "
      "AND reason NOT LIKE 'peran_tidak_berhak%' "
      "AND reason NOT IN ('peran_viewer_hanya_baca', 'hanya_owner', "
      "'harga_dikunci_owner', 'hapus_order_hanya_owner'))"
      ")",
    );
    return rows.first['total'] as int? ?? 0;
  }

  Future<List<Map<String, Object?>>> conflicts() async {
    return AppDatabase.instance.db.query(
      'sync_conflicts',
      orderBy: 'resolved_at IS NOT NULL, created_at DESC',
    );
  }

  /// Coba terapkan ulang amplop yang tertahan. Konflik tetap terlihat sampai
  /// hasil berikutnya benar-benar berhasil.
  Future<void> retryConflict(int conflictId) async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'sync_conflicts',
      where: 'id = ?',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final inboxId = rows.first['inbox_id'] as int?;
    final stamp = nowIso();
    if (inboxId == null) {
      // Konflik lama tanpa amplop tersimpan (mis. versi lokal lebih baru)
      // tidak dapat diputar ulang. Tandai selesai agar tidak menggantung.
      await db.update(
        'sync_conflicts',
        {'status': 'ignored', 'resolved_at': stamp, 'last_error': ''},
        where: 'id = ?',
        whereArgs: [conflictId],
      );
      return;
    }
    await db.transaction((txn) async {
      await txn.update(
        'sync_conflicts',
        {
          'status': 'retrying',
          'retry_count': 0,
          'resolved_at': null,
          'last_error': '',
        },
        where: 'id = ?',
        whereArgs: [conflictId],
      );
      await txn.update(
        'sync_inbox',
        {
          'status': 'pending',
          'retry_count': 0,
          'next_retry_at': stamp,
          'updated_at': stamp,
        },
        where: 'id = ?',
        whereArgs: [inboxId],
      );
    });
  }

  /// Tandai konflik selesai atas pilihan pengguna. Baris konflik tidak
  /// dihapus; amplop yang diabaikan juga ditandai agar tidak diterapkan ulang.
  Future<void> ignoreConflict(int conflictId) async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'sync_conflicts',
      where: 'id = ?',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final conflict = rows.first;
    final inboxId = conflict['inbox_id'] as int?;
    final stamp = nowIso();
    await db.transaction((txn) async {
      await txn.update(
        'sync_conflicts',
        {'status': 'ignored', 'resolved_at': stamp},
        where: 'id = ?',
        whereArgs: [conflictId],
      );
      if (inboxId == null) return;
      final inbox = await txn.query(
        'sync_inbox',
        where: 'id = ?',
        whereArgs: [inboxId],
        limit: 1,
      );
      await txn.update(
        'sync_inbox',
        {'status': 'ignored', 'updated_at': stamp},
        where: 'id = ?',
        whereArgs: [inboxId],
      );
      if (inbox.isEmpty) return;
      final idem = inbox.first['idempotency_key'] as String? ?? '';
      if (idem.isEmpty) return;
      await txn.insert(
        'applied_deltas',
        {
          'idempotency_key': idem,
          'store_id': '${inbox.first['store_id'] ?? ''}',
          'envelope_id': inbox.first['envelope_id'] ?? '',
          'entity': inbox.first['entity'] ?? '',
          'entity_id': inbox.first['entity_id'] ?? '',
          'applied_at': stamp,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  Future<void> _requireCleanBeforeUpload() async {
    if (await pendingCount() > 0) {
      throw StateError('Kirim perubahan lokal sebelum membuat cadangan.');
    }
    if (await pendingInboxCount() > 0) {
      throw StateError(
        'Masih ada perubahan dari perangkat lain yang belum diterapkan. '
        'Sinkronkan ulang sebelum membuat cadangan.',
      );
    }
    if (await failedInboxCount() > 0 || await blockingConflictCount() > 0) {
      throw StateError(
        'Masih ada konflik sinkronisasi yang belum diselesaikan. '
        'Buka daftar konflik sebelum membuat cadangan.',
      );
    }
  }

  Future<Map<String, Object?>> status() async {
    final cursorRows = await AppDatabase.instance.db.query(
      'sync_cursor',
      where: 'store_id = ? AND device_id = ?',
      whereArgs: [await storeId(), await relayDeviceId() ?? ''],
      limit: 1,
    );
    final lastSuccess = await _setting('sync.last_success_at');
    final lastError = await _setting('sync.last_error');
    final lastAttempt = await _setting('sync.last_attempt_at');
    final pending = await pendingCount();
    final warnHours =
        int.tryParse(await _setting('sync.warn_after_hours') ?? '') ?? 6;
    final age = lastSuccess == null
        ? null
        : DateTime.now().difference(DateTime.parse(lastSuccess));
    final storageUsed =
        int.tryParse(await _setting('sync.storage_used_bytes') ?? '') ?? 0;
    final storageLimit =
        int.tryParse(await _setting('sync.storage_limit_bytes') ?? '') ?? 0;
    return {
      'relay_url': await relayUrl() ?? '',
      'store_id': await storeId(),
      'relay_device_id': await relayDeviceId() ?? '',
      'pending': pending,
      'inbox': await pendingInboxCount(),
      'failed': await failedInboxCount(),
      'conflicts': await openConflictCount(),
      'blocking': await blockingConflictCount(),
      'last_success_at': lastSuccess ?? '',
      'last_error': lastError ?? '',
      'last_attempt_at': lastAttempt ?? '',
      'syncing': _inflight != null,
      'stale': pending > 0 && (age == null || age.inHours >= warnHours),
      'pending_warn_hours': warnHours,
      'cursor': cursorRows.isEmpty ? 0 : cursorRows.first['last_seq'] ?? 0,
      'storage_used_bytes': storageUsed,
      'storage_limit_bytes': storageLimit,
      'storage_warning':
          (await _setting('sync.storage_warning') ?? '0') == '1',
    };
  }

  Future<void> enqueue({
    required String entity,
    required String action,
    required String entityId,
    required Map<String, Object?> payload,
    DatabaseExecutor? txn,
    int? hlcWall,
    int? hlcCounter,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final deviceRows = await executor.query(
      'app_settings',
      columns: ['key', 'value'],
      where: "key IN ('sync.relay_device_id', 'device.current_id')",
    );
    final deviceSettings = {
      for (final row in deviceRows) '${row['key']}': '${row['value']}',
    };
    final deviceId = deviceSettings['sync.relay_device_id'] ??
        deviceSettings['device.current_id'] ??
        'local';
    final last = await executor.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS seq, '
      'COALESCE(MAX(hlc_wall), 0) AS wall, '
      'COALESCE(MAX(hlc_counter), 0) AS counter '
      'FROM sync_outbox WHERE device_id = ?',
      [deviceId],
    );
    final floorRows = await executor.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['device.seq_floor'],
      limit: 1,
    );
    final floor = floorRows.isEmpty
        ? 0
        : int.tryParse(floorRows.first['value'] as String? ?? '') ?? 0;
    final maxSeq = (last.first['seq'] as int?) ?? 0;
    final seq = (maxSeq > floor ? maxSeq : floor) + 1;
    final storedWall = hlcWall ?? (last.first['wall'] as int?) ?? 0;
    final storedCounter = hlcCounter ?? (last.first['counter'] as int?) ?? 0;
    final hlc = nextHlc(Hlc(storedWall, storedCounter));
    await executor.insert('sync_outbox', {
      'device_id': deviceId,
      'seq': seq,
      'hlc_wall': hlcWall ?? hlc.wall,
      'hlc_counter': hlcCounter ?? hlc.counter,
      'idempotency_key': newSyncId(),
      'entity': entity,
      'entity_id': entityId,
      'action': action,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'created_at': nowIso(),
    });
  }

  Future<void> enqueueCustomer(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'customers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'customer',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'nama': row['nama'],
        'nomor_hp': row['nomor_hp'],
        'alamat': row['alamat'],
        'wa_consent': row['wa_consent'] ?? 1,
        'do_not_contact': row['do_not_contact'] ?? 0,
        'created_at': row['created_at'],
        'deleted_at': row['deleted_at'],
      },
    );
  }

  Future<void> enqueueUnit(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'vehicle_or_units',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final customer = await executor.query(
      'customers',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [row['customer_id']],
      limit: 1,
    );
    await enqueue(
      txn: txn,
      entity: 'unit',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'customer_sync_id':
            customer.isEmpty ? '' : customer.first['sync_id'],
        'unit_type': row['unit_type'],
        'nopol': row['nopol'],
        'merek': row['merek'],
        'tipe': row['tipe'],
        'jenis_mobil': row['jenis_mobil'],
        'tahun_mobil': row['tahun_mobil'],
        'no_rangka': row['no_rangka'],
        'no_mesin': row['no_mesin'],
        'km_terakhir': row['km_terakhir'],
        'tipe_radiator': row['tipe_radiator'],
        'label_radiator': row['label_radiator'],
        'created_at': row['created_at'],
        'deleted_at': row['deleted_at'],
      },
    );
  }

  Future<void> enqueueStock(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'stock_items',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'stock',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'kode': row['kode'],
        'nama': row['nama'],
        'harga_modal': row['harga_modal'],
        'harga_jual': row['harga_jual'],
        'stok_minimum': row['stok_minimum'],
        'satuan': row['satuan'] ?? 'pcs',
        'desimal': row['desimal'] ?? 0,
        'deleted_at': row['deleted_at'],
      },
    );
  }

  Future<void> enqueueNote(int id, {DatabaseExecutor? txn}) async {
    await _enqueueNoteState(id, 'upsert', txn: txn);
  }

  Future<void> enqueueNoteReturn(int id, {DatabaseExecutor? txn}) async {
    await _enqueueNoteState(id, 'retur', txn: txn);
  }

  Future<void> enqueueNoteVoid(int id, {DatabaseExecutor? txn}) async {
    await _enqueueNoteState(id, 'void', txn: txn);
  }

  Future<void> enqueueNoteWarranty(int id, {DatabaseExecutor? txn}) async {
    await _enqueueNoteState(id, 'warranty', txn: txn);
  }

  Future<void> enqueueNoteTaken(int id, {DatabaseExecutor? txn}) async {
    await _enqueueNoteState(id, 'taken', txn: txn);
  }

  Future<void> _enqueueNoteState(
    int id,
    String action, {
    DatabaseExecutor? txn,
  }) async {
    final payload = await AppDatabase.instance.noteSyncPayload(
      id,
      executor: txn,
    );
    final record = payload['record'] as Map<String, Object?>? ?? const {};
    final syncId = record['sync_id'] as String? ?? '';
    if (syncId.isEmpty) return;
    await enqueue(
      txn: txn,
      entity: 'nota',
      action: action,
      entityId: syncId,
      payload: payload,
    );
  }

  Future<void> enqueueStockMovement(
    int movementId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.rawQuery(
      '''
      SELECT m.*, s.sync_id AS stock_sync_id, r.sync_id AS record_sync_id
      FROM stock_movements m
      LEFT JOIN stock_items s ON s.id = m.stock_item_id
      LEFT JOIN service_records r ON r.id = m.service_record_id
      WHERE m.id = ?
      LIMIT 1
      ''',
      [movementId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final syncId = row['sync_id'] as String? ?? '';
    final stockSync = row['stock_sync_id'] as String? ?? '';
    if (syncId.isEmpty || stockSync.isEmpty) return;
    final movementWall = (row['sync_hlc_wall'] as num?)?.toInt() ?? 0;
    final movementCounter = (row['sync_hlc_counter'] as num?)?.toInt() ?? 0;
    await enqueue(
      txn: txn,
      entity: 'stock_movement',
      action: 'upsert',
      entityId: syncId,
      hlcWall: movementWall > 0 ? movementWall : null,
      hlcCounter: movementWall > 0 ? movementCounter : null,
      payload: {
        'sync_id': syncId,
        'stock_sync_id': stockSync,
        'nama_item': row['nama_item'],
        'jenis': row['jenis'],
        'jumlah_milli': row['jumlah_milli'] ?? (row['jumlah'] as int? ?? 0) * 1000,
        'stok_sebelum_milli': row['stok_sebelum_milli'],
        'stok_sesudah_milli': row['stok_sesudah_milli'],
        'opname_absolut_milli': row['opname_absolut_milli'],
        'sumber_entity': row['sumber_entity'],
        'sumber_sync_id': row['sumber_sync_id'],
        'operator': row['operator'],
        'alasan': row['alasan'],
        'created_at': row['created_at'],
        'record_sync_id': row['record_sync_id'],
      },
    );
  }

  Future<void> enqueueCatalog(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'harga_jasa',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'harga_jasa',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'nama': row['nama'],
        'harga_jual': row['harga_jual'],
        'harga_modal': row['harga_modal'],
        'interval_servis_bulan': row['interval_servis_bulan'] ?? 0,
        'created_at': row['created_at'],
        'deleted_at': row['deleted_at'],
      },
    );
  }

  Future<void> enqueueSupplier(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'suppliers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final mappingRows = await executor.rawQuery(
      '''
      SELECT st.sync_id FROM supplier_items i
      JOIN stock_items st ON st.id = i.stock_item_id
      WHERE i.supplier_id = ? AND i.deleted_at IS NULL
      ''',
      [id],
    );
    await enqueue(
      txn: txn,
      entity: 'supplier',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'nama': row['nama'],
        'nomor_hp': row['nomor_hp'],
        'alamat': row['alamat'],
        'catatan': row['catatan'],
        'aktif': row['aktif'] ?? 1,
        'created_at': row['created_at'],
        'deleted_at': row['deleted_at'],
        'stock_sync_ids':
            mappingRows.map((item) => '${item['sync_id']}').toList(),
      },
    );
  }

  Future<void> enqueueSupplierFollowup({
    required int supplierId,
    required int stockItemId,
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.rawQuery(
      '''
      SELECT f.*, s.sync_id AS supplier_sync_id,
        st.sync_id AS stock_sync_id
      FROM supplier_followups f
      JOIN suppliers s ON s.id = f.supplier_id
      JOIN stock_items st ON st.id = f.stock_item_id
      WHERE f.supplier_id = ? AND f.stock_item_id = ?
        AND f.deleted_at IS NULL
      LIMIT 1
      ''',
      [supplierId, stockItemId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'supplier_followup',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'supplier_sync_id': row['supplier_sync_id'],
        'stock_sync_id': row['stock_sync_id'],
        'status': row['status'],
        'catatan': row['catatan'],
        'updated_at': row['updated_at'],
      },
    );
  }

  Future<void> enqueueCommission(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.rawQuery(
      '''
      SELECT c.*, r.sync_id AS record_sync_id
      FROM service_record_commissions c
      JOIN service_records r ON r.id = c.service_record_id
      WHERE c.id = ?
      LIMIT 1
      ''',
      [id],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'commission',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'record_sync_id': row['record_sync_id'],
        'employee_sync_id': row['employee_sync_id'],
        'employee_nama_snapshot': row['employee_nama_snapshot'],
        'mode_snapshot': row['mode_snapshot'],
        'nilai_snapshot': row['nilai_snapshot'],
        'dasar_jasa': row['dasar_jasa'],
        'dasar_barang': row['dasar_barang'],
        'nominal': row['nominal'],
        'nominal_override': row['nominal_override'],
        'status': row['status'],
        'voided_at': row['voided_at'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
    );
  }

  Future<void> enqueueDebt(String syncId, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'employee_debts',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'debt',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'employee_sync_id': row['employee_sync_id'],
        'nominal': row['nominal'],
        'terbayar': row['terbayar'] ?? 0,
        'catatan': row['catatan'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueueEmployee(String syncId, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'employee_accounts',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'employee',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'username': row['username'],
        'nama': row['nama'],
        'aktif': row['aktif'] ?? 1,
        // Peran/izin/toko ikut disebar tanpa kredensial apa pun.
        'role_base': row['role_base'],
        'extra_permissions_json': row['extra_permissions_json'],
        'store_ids_json': row['store_ids_json'],
        'permissions_explicit': row['permissions_explicit'] ?? 0,
        'permission_version': row['permission_version'] ?? 1,
        'jenis_imbalan': row['jenis_imbalan'],
        'gaji_bulanan': row['gaji_bulanan'],
        'komisi_mode': row['komisi_mode'],
        'komisi_barang_nilai': row['komisi_barang_nilai'],
        'komisi_jasa_nilai': row['komisi_jasa_nilai'],
        'payroll_period': row['payroll_period'],
        'payroll_tanggal': row['payroll_tanggal'],
        'payroll_hari': row['payroll_hari'],
        'bank_nama': row['bank_nama'],
        'bank_nomor': row['bank_nomor'],
        'bank_pemilik': row['bank_pemilik'],
        'tanggal_masuk': row['tanggal_masuk'],
        'updated_at': row['updated_at'],
      },
    );
  }

  Future<void> enqueueSalary(String syncId, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'salary_payments',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final debts = await executor.query(
      'employee_debts',
      columns: ['sync_id', 'terbayar'],
      where: 'employee_sync_id = ?',
      whereArgs: [row['employee_sync_id']],
    );
    await enqueue(
      txn: txn,
      entity: 'salary',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        ...row,
        'debt_updates': debts
            .map(
              (debt) => {
                'sync_id': debt['sync_id'],
                'terbayar': debt['terbayar'] ?? 0,
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enqueueNotePayment(
    int recordId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'service_records',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final payload = await AppDatabase.instance.noteSyncPayload(
      recordId,
      executor: txn,
    );
    final payments = (payload['payments'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    await enqueue(
      txn: txn,
      entity: 'nota',
      action: 'payment',
      entityId: rows.first['sync_id'] as String,
      payload: {
        'record_sync_id': rows.first['sync_id'],
        'payments': payments,
        'record': payload['record'],
      },
    );
  }

  Future<void> enqueueStoreSettings(
    String syncId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'store_settings',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'store_settings',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'types': _jsonObject(row['transaction_types_json']),
        'stages': _jsonObject(row['order_stages_json']),
        'simpan_estimasi_lepas':
            ((row['simpan_estimasi_lepas'] as num?)?.toInt() ?? 1) == 1,
        'role_permissions': _jsonObject(row['role_permissions_json']),
        'preset': row['preset'],
        'updated_at': row['updated_at'],
      },
    );
  }

  Future<void> enqueueEstimate(
    String syncId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'estimates',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final items = await executor.query(
      'estimate_items',
      where: 'estimate_sync_id = ?',
      whereArgs: [syncId],
      orderBy: 'id',
    );
    await enqueue(
      txn: txn,
      entity: 'estimate',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'device_id': row['device_id'],
        'nomor_estimasi': row['nomor_estimasi'],
        'work_order_sync_id': row['work_order_sync_id'],
        'customer_sync_id': row['customer_sync_id'],
        'unit_sync_id': row['unit_sync_id'],
        'versi': row['versi'],
        'revisi_dari_sync_id': row['revisi_dari_sync_id'],
        'alasan_revisi': row['alasan_revisi'],
        'masa_berlaku': row['masa_berlaku'],
        'total': row['total'],
        'status': row['status'],
        'disetujui_oleh': row['disetujui_oleh'],
        'disetujui_at': row['disetujui_at'],
        'mode_saat_dibuat': _jsonObject(row['mode_saat_dibuat_json']),
        'converted_nota_sync_id': row['converted_nota_sync_id'],
        'total_estimasi_terakhir': row['total_estimasi_terakhir'],
        'dibuat_oleh': row['dibuat_oleh'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'items': items
            .map(
              (item) => {
                'sync_id': item['sync_id'],
                'jenis': item['jenis'],
                'stock_sync_id': item['stock_sync_id'],
                'deskripsi': item['deskripsi'],
                'jumlah': item['jumlah'],
                'jumlah_milli': item['jumlah_milli'] ??
                    ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000,
                'harga_jual_terdaftar': item['harga_jual_terdaftar'],
                'harga_batas_saat_transaksi':
                    item['harga_batas_saat_transaksi'],
                'harga_final': item['harga_final'],
                'harga_modal': item['harga_modal'],
                'diskon_alokasi': item['diskon_alokasi'],
                'interval_servis_bulan': item['interval_servis_bulan'] ?? 0,
                'subtotal': item['subtotal'],
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enqueueWorkOrder(
    String syncId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'work_orders',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'work_order',
      action: row['deleted_at'] == null ? 'upsert' : 'delete',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'device_id': row['device_id'],
        'nomor_order': row['nomor_order'],
        'nomor_antrian': row['nomor_antrian'],
        'customer_sync_id': row['customer_sync_id'],
        'unit_sync_id': row['unit_sync_id'],
        'keluhan': row['keluhan'],
        'status': row['status'],
        'mekanik_sync_id': row['mekanik_sync_id'],
        'mekanik_nama': row['mekanik_nama'],
        'waktu_masuk': row['waktu_masuk'],
        'waktu_selesai': row['waktu_selesai'],
        'nota_sync_id': row['nota_sync_id'],
        'mode_saat_dibuat': _jsonObject(row['mode_saat_dibuat_json']),
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'deleted_at': row['deleted_at'],
      },
    );
  }

  Future<void> enqueueWorkOrderStatus(
    String syncId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'work_order_status_log',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'work_order_status',
      action: 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'work_order_sync_id': row['work_order_sync_id'],
        'status': row['status'],
        'waktu': row['waktu'],
        'pembuat': row['pembuat'],
        'perangkat': row['perangkat'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueueNotaAdjustment(
    int id, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'nota_adjustments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'nota_adjustment',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'nota_sync_id': row['nota_sync_id'],
        'nilai_selisih': row['nilai_selisih'],
        'nilai_baru': row['nilai_baru'],
        'nominal_jasa': row['nominal_jasa'],
        'nominal_part': row['nominal_part'],
        'diskon': row['diskon'],
        'alasan': row['alasan'],
        'dibuat_oleh': row['dibuat_oleh'],
        'disetujui_oleh': row['disetujui_oleh'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueueDayDigest(
    String syncId, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'day_digests',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'day_digest',
      action: 'upsert',
      entityId: syncId,
      payload: {
        'sync_id': syncId,
        'source_device_id': row['source_device_id'],
        'tanggal': row['tanggal'],
        'data_type': row['data_type'],
        'jumlah': row['jumlah'],
        'hash': row['hash'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueuePurchase(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'supplier_purchases',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    if (row['deleted_at'] != null) return;
    final items = await executor.query(
      'supplier_purchase_items',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    final payments = await executor.query(
      'supplier_payments',
      where: 'purchase_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    await enqueue(
      txn: txn,
      entity: 'supplier_purchase',
      action: '${row['status']}' == 'VOID' ? 'void' : 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'origin_device_id': row['origin_device_id'],
        'no_pembelian': row['no_pembelian'],
        'request_id': row['request_id'],
        'supplier_sync_id': row['supplier_sync_id'],
        'supplier_nama_snapshot': row['supplier_nama_snapshot'],
        'tanggal': row['tanggal'],
        'jatuh_tempo': row['jatuh_tempo'],
        'termin_hari': row['termin_hari'],
        'jenis_bayar': row['jenis_bayar'],
        'status': row['status'],
        'subtotal': row['subtotal'],
        'diskon': row['diskon'],
        'ongkir': row['ongkir'],
        'ppn': row['ppn'],
        'total': row['total'],
        'total_dibayar': row['total_dibayar'],
        'sisa_utang': row['sisa_utang'],
        'catatan': row['catatan'],
        'created_by': row['created_by'],
        'void_reason': row['void_reason'],
        'voided_at': row['voided_at'],
        'voided_by': row['voided_by'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'items': items
            .map(
              (item) => {
                'sync_id': item['sync_id'],
                'stock_sync_id': item['stock_sync_id'],
                'nama_snapshot': item['nama_snapshot'],
                'satuan': item['satuan'],
                'jumlah_milli': item['jumlah_milli'],
                'harga_satuan': item['harga_satuan'],
                'subtotal': item['subtotal'],
                'diskon_alokasi': item['diskon_alokasi'],
                'ongkir_alokasi': item['ongkir_alokasi'],
                'harga_pokok_satuan': item['harga_pokok_satuan'],
              },
            )
            .toList(),
        'payments': payments
            .map(
              (payment) => {
                'sync_id': payment['sync_id'],
                'store_id': payment['store_id'],
                'device_id': payment['device_id'],
                'request_id': payment['request_id'],
                'jenis': payment['jenis'],
                'metode': payment['metode'],
                'nominal': payment['nominal'],
                'waktu': payment['waktu'],
                'operator': payment['operator'],
                'catatan': payment['catatan'],
                'created_at': payment['created_at'],
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enqueuePurchasePayment(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'supplier_payments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final purchase = await executor.query(
      'supplier_purchases',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [row['purchase_id']],
      limit: 1,
    );
    if (purchase.isEmpty) return;
    await enqueue(
      txn: txn,
      entity: 'supplier_payment',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'purchase_sync_id': purchase.first['sync_id'],
        'request_id': row['request_id'],
        'jenis': row['jenis'],
        'metode': row['metode'],
        'nominal': row['nominal'],
        'waktu': row['waktu'],
        'operator': row['operator'],
        'catatan': row['catatan'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueuePurchaseReturn(int id, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'supplier_purchase_returns',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final items = await executor.query(
      'supplier_purchase_return_items',
      where: 'return_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    await enqueue(
      txn: txn,
      entity: 'supplier_purchase_return',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'origin_device_id': row['origin_device_id'],
        'purchase_sync_id': row['purchase_sync_id'],
        'no_retur': row['no_retur'],
        'request_id': row['request_id'],
        'status': row['status'],
        'total': row['total'],
        'total_modal_kembali': row['total_modal_kembali'],
        'total_kas_kembali': row['total_kas_kembali'],
        'alasan': row['alasan'],
        'dibuat_oleh': row['dibuat_oleh'],
        'created_at': row['created_at'],
        'items': items
            .map(
              (item) => {
                'sync_id': item['sync_id'],
                'purchase_item_sync_id': item['purchase_item_sync_id'],
                'nama_snapshot': item['nama_snapshot'],
                'jumlah_milli': item['jumlah_milli'],
                'harga_satuan': item['harga_satuan'],
                'subtotal': item['subtotal'],
                'modal_satuan': item['modal_satuan'],
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enqueueOpeningBalance(String syncId, {DatabaseExecutor? txn}) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'opening_balances',
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final items = await executor.query(
      'opening_balance_items',
      where: 'opening_id = ? AND deleted_at IS NULL',
      whereArgs: [row['id']],
      orderBy: 'id',
    );
    await enqueue(
      txn: txn,
      entity: 'opening_balance',
      action: '${row['status']}' == 'VOID' ? 'void' : 'upsert',
      entityId: syncId,
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': syncId,
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'origin_device_id': row['origin_device_id'],
        'status': row['status'],
        'posted_at': row['posted_at'],
        'posted_by': row['posted_by'],
        'catatan': row['catatan'],
        'void_reason': row['void_reason'],
        'voided_at': row['voided_at'],
        'created_at': row['created_at'],
        'items': items
            .map(
              (item) => {
                'sync_id': item['sync_id'],
                'jenis': item['jenis'],
                'ref_sync_id': item['ref_sync_id'],
                'ref_nama_snapshot': item['ref_nama_snapshot'],
                'jumlah_milli': item['jumlah_milli'],
                'nominal': item['nominal'],
                'catatan': item['catatan'],
              },
            )
            .toList(),
      },
    );
  }

  Future<void> enqueueStoreFeature(
    String featureKey, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final storeId = AppDatabase.instance.activeStoreId ?? 'utama';
    final rows = await executor.query(
      'store_features',
      where: 'store_id = ? AND feature_key = ?',
      whereArgs: [storeId, featureKey],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'store_feature',
      action: 'upsert',
      entityId: '${row['sync_id']}',
      hlcWall: (row['sync_hlc_wall'] as num?)?.toInt(),
      hlcCounter: (row['sync_hlc_counter'] as num?)?.toInt(),
      payload: {
        'sync_id': row['sync_id'],
        'store_id': row['store_id'],
        'device_id': row['device_id'],
        'feature_key': row['feature_key'],
        'enabled': (row['enabled'] as num?)?.toInt() == 1,
        'version': row['version'],
        'updated_by': row['updated_by'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
    );
  }

  Future<void> enqueueDataRequest({
    required String tanggal,
    required String dataType,
    required String alasan,
    required String targetDeviceId,
    Duration ttl = const Duration(days: 3),
    DatabaseExecutor? txn,
  }) async {
    final syncId = newSyncId();
    await enqueue(
      txn: txn,
      entity: 'data_request',
      action: 'upsert',
      entityId: syncId,
      payload: {
        'sync_id': syncId,
        'target_device_id': targetDeviceId,
        'tanggal': tanggal,
        'data_type': dataType,
        'alasan': alasan,
        'expires_at': DateTime.now().add(ttl).toIso8601String(),
        'created_at': nowIso(),
      },
    );
  }

  Future<void> enqueueDataResponse({
    required String requestSyncId,
    required List<Map<String, Object?>> envelopes,
    DatabaseExecutor? txn,
  }) async {
    final syncId = newSyncId();
    await enqueue(
      txn: txn,
      entity: 'data_response',
      action: 'upsert',
      entityId: syncId,
      payload: {
        'sync_id': syncId,
        'request_sync_id': requestSyncId,
        'envelopes': envelopes,
        'created_at': nowIso(),
      },
    );
  }

  Future<void> refreshEmployeePermission() async {
    final device = await DeviceService.instance.currentDevice();
    if (device == null || device['kind'] != 'employee') return;
    final url = await relayUrl();
    final token = await relayDeviceToken();
    if (url == null || url.isEmpty || token == null || token.isEmpty) return;
    final data = await RelayClient(baseUrl: url, deviceToken: token)
        .permissionsMe();
    final account = Map<String, Object?>.from(
      data['account'] as Map? ?? const {},
    );
    final permission = Map<String, Object?>.from(
      data['permission'] as Map? ?? const {},
    );
    final payload = Map<String, Object?>.from(
      permission['payload'] as Map? ?? const {},
    );
    final signer = permission['signer_public_key'] as String? ?? '';
    final signature = permission['signature'] as String? ?? '';
    final pinned = await pinnedOwnerPublicKey();
    if (!isTrustedPermissionSigner(signer, pinned)) {
      throw StateError(
        'Penandatangan izin bukan kunci owner yang dipin. '
        'Izin karyawan ditolak.',
      );
    }
    final valid = await verifyPayload(
      signer,
      utf8.encode(canonicalJson(payload)),
      signature,
    );
    if (!valid) {
      throw StateError('Tanda tangan izin karyawan tidak valid.');
    }
    await AccountService.instance.applyRemotePermissions(account);
  }

  Future<Map<String, Object?>>? _inflight;

  bool get isSyncing => _inflight != null;

  /// Satu sinkronisasi per proses. Pemanggil kedua menunggu hasil yang sama
  /// agar dua putaran tidak menerapkan delta yang sama secara bersamaan.
  Future<Map<String, Object?>> syncNow() {
    final running = _inflight;
    if (running != null) return running;
    final future = _runSync();
    _inflight = future.whenComplete(() => _inflight = null);
    return _inflight!;
  }

  Future<Map<String, Object?>> _runSync() async {
    await AppDatabase.instance.setSetting('sync.last_attempt_at', nowIso());
    try {
      return await _syncNow();
    } catch (error) {
      await AppDatabase.instance.setSetting('sync.last_error', '$error');
      rethrow;
    }
  }

  Future<Map<String, Object?>> _syncNow() async {
    await _requirePremium();
    final url = await relayUrl();
    if (url == null || url.isEmpty) {
      throw StateError('Alamat relay belum diatur.');
    }
    final deviceId = await relayDeviceId();
    final localId = await _setting('sync.local_device_id');
    if (deviceId == null || localId == null) {
      throw StateError('Daftarkan perangkat ke relay terlebih dahulu.');
    }
    final token = await relayDeviceToken();
    if (token == null || token.isEmpty) {
      throw StateError('Token relay perangkat tidak tersedia.');
    }
    if (await _setting('sync.restore_requires_bootstrap') == '1') {
      throw StateError(
        'Perangkat baru saja dipulihkan dari backup. Jalankan "Ambil '
        'snapshot"/bootstrap sebelum sinkronisasi agar nomor nota dan '
        'urutan delta tidak bentrok.',
      );
    }
    final client = RelayClient(baseUrl: url, deviceToken: token);
    await refreshEmployeePermission();
    final keyReady = await refreshStoreKey();
    if (!keyReady) {
      throw StateError(
        'Kunci toko belum tersedia. Minta pemilik mengirim kunci toko.',
      );
    }
    final storeKey = (await existingStoreKey())!;
    final privateKey = await DeviceService.instance.privateKey(localId);
    if (privateKey == null) throw StateError('Kunci perangkat tidak tersedia.');
    final store = await storeId();
    var sent = 0;
    final now = nowIso();
    final pending = await AppDatabase.instance.db.query(
      'sync_outbox',
      where: "status = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [now],
      orderBy: 'seq',
    );
    if (pending.isNotEmpty) {
      final envelopes = <Map<String, Object?>>[];
      final rows = <Map<String, Object?>>[];
      for (final item in pending) {
        try {
          final payload = jsonDecode(item['payload_json'] as String)
              as Map<String, Object?>;
          envelopes.add(
            await buildEnvelope(
              devicePrivateKey: privateKey,
              storeKey: storeKey,
              storeId: store,
              senderDeviceId: deviceId,
              recipientDeviceId: '',
              seq: item['seq'] as int,
              hlcWall: item['hlc_wall'] as int,
              hlcCounter: item['hlc_counter'] as int,
              idempotencyKey: item['idempotency_key'] as String,
              entity: item['entity'] as String,
              action: item['action'] as String,
              entityId: item['entity_id'] as String,
              payload: payload,
            ),
          );
          rows.add(item);
        } catch (error) {
          await _failOutbox(item, error);
        }
      }
      sent = await _sendBatches(
        client: client,
        storeId: store,
        envelopes: envelopes,
        rows: rows,
      );
    }
    final devices = await client.devices();
    var keys = _senderKeys(devices);
    var profiles = _senderProfiles(devices);
    final inbox = await _retryInbox(
      store: store,
      deviceId: deviceId,
      storeKey: storeKey,
      keys: keys,
      profiles: profiles,
    );
    var applied = inbox.applied;
    var conflictCount = inbox.failed;
    var cursor = await _cursor(store, deviceId);
    int? blockedSeq = inbox.blockedSeq;
    var blockedError = inbox.lastError;
    if (blockedSeq != null) {
      // Ada amplop yang belum dapat diterapkan. Cursor tetap di urutan
      // sebelum amplop itu, tetapi amplop independen sesudahnya tetap
      // diterapkan dan diakui sejauh aman; pengakuan penuh menunggu celah
      // terisi.
      final halt = blockedSeq > 0 ? blockedSeq - 1 : cursor;
      if (halt > cursor) {
        cursor = halt;
        await client.ack(storeId: store, lastSeq: halt);
        await _setCursor(store, deviceId, halt);
      }
      await _ackOpenRound(client, store: store, lastSeq: halt);
    }
    var next = cursor;
    var pageCursor = cursor;
    var refreshedDevices = false;
    while (true) {
      final feed = await client.feed(storeId: store, sinceSeq: pageCursor);
      final logStart = (feed['log_start_seq'] as num?)?.toInt() ?? 0;
      final prunedThrough = (feed['pruned_through'] as num?)?.toInt();
      if (feed['snapshot_required'] != true &&
          relayHistoryPruned(
            cursor: pageCursor,
            logStart: logStart,
            prunedThrough: prunedThrough,
          )) {
        final boundary = prunedThrough != null && prunedThrough > 0
            ? prunedThrough
            : logStart;
        throw StateError(
          'Riwayat relay sudah dipangkas sampai urutan $boundary, sedangkan '
          'perangkat ini baru berada di urutan $pageCursor. Minta pemilik '
          'mengunggah snapshot dari perangkat yang datanya lengkap.',
        );
      }
      if (feed['snapshot_required'] == true) {
        final boot = await client.bootstrap(store);
        final rawSnapshot = boot['snapshot'];
        if (rawSnapshot is Map) {
          final snapshot = Map<String, Object?>.from(rawSnapshot);
          final sender = snapshot['device_id'] as String? ?? '';
          final senderKey = keys[sender];
          if (senderKey == null) {
            throw StateError('Kunci publik pengirim snapshot tidak ditemukan.');
          }
          final result = await AppDatabase.instance.applySnapshotPayload(
            snapshot,
            senderPublicKey: senderKey,
            storeKey: storeKey,
            storeId: store,
            deviceId: deviceId,
          );
          if (result['applied'] == true) {
            final seq = (result['store_seq'] as num?)?.toInt() ?? 0;
            await client.ack(storeId: store, lastSeq: seq);
            await _setCursor(store, deviceId, seq);
            await AppDatabase.instance.setSetting(
              'sync.last_success_at',
              nowIso(),
            );
            await _ackOpenRound(client, store: store, lastSeq: seq);
            return {
              'sent': sent,
              'applied': 0,
              'cursor': seq,
              'snapshot_required': false,
              'snapshot_applied': true,
            };
          }
          if (result['stale'] == true || result['duplicate'] == true) {
            // Snapshot sudah pernah diterapkan atau lebih lama dari cursor
            // lokal. Lanjutkan dari cursor yang ada tanpa meng-ack mundur.
            final local = await _cursor(store, deviceId);
            await _ackOpenRound(client, store: store, lastSeq: local);
            return {
              'sent': sent,
              'applied': 0,
              'cursor': local,
              'snapshot_required': false,
              'snapshot_applied': false,
            };
          }
        }
        return {
          'sent': sent,
          'applied': 0,
          'cursor': pageCursor,
          'snapshot_required': true,
        };
      }
      for (final raw in (feed['envelopes'] as List? ?? const [])) {
        final envelope = (raw as Map).map(
          (key, value) => MapEntry('$key', value),
        );
        final sender = envelope['sender_device_id'] as String? ?? '';
        final relaySeq = (envelope['relay_seq'] as num?)?.toInt() ??
            (envelope['seq'] as num?)?.toInt() ??
            0;
        if (sender == deviceId) {
          continue;
        }
        if (relaySeq <= pageCursor) continue;
        // Amplop ini sudah dicoba lewat inbox pada siklus yang sama; jangan
        // mengulang percobaan hingga jadwal backoff berikutnya.
        if (inbox.attempted.contains(relaySeq)) continue;
        var key = keys[sender];
        if (key == null && !refreshedDevices) {
          refreshedDevices = true;
          final fresh = await client.devices();
          keys = _senderKeys(fresh);
          profiles = _senderProfiles(fresh);
          key = keys[sender];
        }
        if (key == null) {
          blockedSeq = blockedSeq == null || relaySeq < blockedSeq
              ? relaySeq
              : blockedSeq;
          blockedError = sender.isEmpty
              ? 'Amplop tanpa pengirim.'
              : 'Amplop dari perangkat "$sender" tidak dikenal.';
          // Amplop lain dari pengirim yang dikenal tetap diterapkan; hanya
          // amplop ini yang menunggu kuncinya tersedia.
          continue;
        }
        try {
          final didApply = await _applyOnce(
            envelope: envelope,
            senderKey: key,
            senderKind: profiles[sender]?.kind ?? 'unknown',
            senderProfile: profiles[sender],
            storeKey: storeKey,
            storeId: store,
          );
          if (didApply) applied++;
        } catch (error) {
          final attempts = await _rememberFailure(
            storeId: store,
            deviceId: deviceId,
            relaySeq: relaySeq,
            envelope: envelope,
            error: error,
          );
          conflictCount++;
          // Baik masih dapat dicoba ulang maupun sudah habis percobaan,
          // cursor tidak boleh melewati amplop ini. Pengguna dapat memilih
          // "coba lagi" atau "abaikan" dari layar konflik.
          if (blockedSeq == null || relaySeq < blockedSeq) {
            blockedSeq = relaySeq;
            blockedError = attempts >= SyncConflictRules.maxRetries
                ? 'Percobaan habis: $error'
                : '$error';
          }
        }
      }
      final latest = (feed['latest_seq'] as num?)?.toInt() ?? 0;
      final advance = feed['next_seq'] as int? ?? pageCursor;
      if (advance <= pageCursor) break;
      pageCursor = advance;
      if (pageCursor >= latest) break;
    }
    // Pengakuan hanya sampai sebelum amplop pertama yang tertahan. Amplop
    // sesudahnya sudah diterapkan secara idempoten dan akan diakui pada
    // siklus berikutnya setelah celah terisi, sehingga satu konflik tidak
    // menghentikan data independen.
    final ackSeq = blockedSeq != null
        ? (blockedSeq > 0 ? blockedSeq - 1 : cursor)
        : pageCursor;
    if (ackSeq > 0) {
      next = ackSeq;
      await client.ack(storeId: store, lastSeq: next);
      await _setCursor(store, deviceId, next);
    }
    await _ackOpenRound(client, store: store, lastSeq: next);
    await cleanupSyncHistory();
    if (blockedSeq == null) {
      await AppDatabase.instance.setSetting('sync.last_success_at', nowIso());
      await AppDatabase.instance.deleteSetting('sync.last_error');
    }
    if (blockedSeq != null) {
      throw StateError(
        'Sinkronisasi tertahan pada urutan $blockedSeq. '
        '${blockedError.isEmpty ? 'Amplop belum dapat diterapkan.' : blockedError} '
        'Perangkat lain tidak kehilangan data; percobaan ulang dijadwalkan.',
      );
    }
    await OpnameService.instance.processPending(
      enqueueMovement: (txn, movementId) =>
          enqueueStockMovement(movementId, txn: txn),
    );
    return {
      'sent': sent,
      'applied': applied,
      'conflicts': conflictCount,
      'cursor': next,
      'snapshot_required': false,
    };
  }

  Future<void> _failOutbox(Map<String, Object?> row, Object error) async {
    final attempts = ((row['retry_count'] as num?)?.toInt() ?? 0) + 1;
    if (error is RelayException &&
        error.statusCode == 409 &&
        '$error'.toLowerCase().contains('seq')) {
      final deviceId = '${row['device_id'] ?? ''}';
      final maxRows = await AppDatabase.instance.db.rawQuery(
        'SELECT COALESCE(MAX(seq), 0) AS seq FROM sync_outbox '
        'WHERE device_id = ?',
        [deviceId],
      );
      final next = ((maxRows.first['seq'] as num?)?.toInt() ?? 0) + 1;
      await AppDatabase.instance.db.update(
        'sync_outbox',
        {'seq': next},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      row['seq'] = next;
    }
    await AppDatabase.instance.db.update(
      'sync_outbox',
      {
        'retry_count': attempts,
        'error': '$error',
        'next_retry_at': DateTime.now()
            .add(SyncConflictRules.backoffFor(attempts))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [row['id']],
    );
    await AppDatabase.instance.setSetting('sync.last_error', '$error');
  }

  /// Kirim outbox secara bertahap. Ukuran batch diturunkan saat relay sibuk
  /// dan dinaikkan perlahan saat lancar; batas atas mengikuti `max_batch`
  /// yang dihitung relay dari beban nyata, bukan dari isi payload.
  Future<int> _sendBatches({
    required RelayClient client,
    required String storeId,
    required List<Map<String, Object?>> envelopes,
    required List<Map<String, Object?>> rows,
  }) async {
    if (envelopes.isEmpty) return 0;
    var countLimit =
        (int.tryParse(await _setting('sync.batch_size') ?? '') ?? 5)
            .clamp(1, 100);
    var bytesLimit =
        (int.tryParse(await _setting('sync.batch_bytes') ?? '') ?? 262144)
            .clamp(16384, 4 * 1024 * 1024);
    var index = 0;
    var sent = 0;
    while (index < envelopes.length) {
      final start = index;
      final batch = <Map<String, Object?>>[];
      final batchRows = <Map<String, Object?>>[];
      var bytes = 0;
      while (index < envelopes.length && batch.length < countLimit) {
        final size = utf8.encode(jsonEncode(envelopes[index])).length;
        if (batch.isNotEmpty && bytes + size > bytesLimit) break;
        batch.add(envelopes[index]);
        batchRows.add(rows[index]);
        bytes += size;
        index++;
      }
      try {
        final response = await client.submitEnvelopes(
          storeId: storeId,
          envelopes: batch,
        );
        final storage = response['storage'];
        if (storage is Map) {
          final used = (storage['used_bytes'] as num?)?.toInt() ?? 0;
          final limit = (storage['limit_bytes'] as num?)?.toInt() ?? 0;
          await AppDatabase.instance
              .setSetting('sync.storage_used_bytes', '$used');
          await AppDatabase.instance
              .setSetting('sync.storage_limit_bytes', '$limit');
          await AppDatabase.instance.setSetting(
            'sync.storage_warning',
            storage['warning'] == true ? '1' : '0',
          );
        }
        final stamp = nowIso();
        await AppDatabase.instance.db.transaction((txn) async {
          for (final row in batchRows) {
            await txn.update(
              'sync_outbox',
              {
                'status': 'sent',
                'sent_at': stamp,
                'error': '',
                'next_retry_at': null,
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        });
        sent += batch.length;
        countLimit = _nextCountLimit(response, countLimit);
        bytesLimit = _nextBytesLimit(response, bytesLimit);
        await AppDatabase.instance.setSetting('sync.batch_size', '$countLimit');
        await AppDatabase.instance
            .setSetting('sync.batch_bytes', '$bytesLimit');
      } on RelayException catch (error) {
        if (error.busy) {
          countLimit = max(1, countLimit ~/ 2);
          await AppDatabase.instance
              .setSetting('sync.batch_size', '$countLimit');
          final retry = (error.retryAfterSeconds ?? 60).clamp(5, 900);
          final nextTry = DateTime.now().add(Duration(seconds: retry));
          for (final row in rows.sublist(start)) {
            await AppDatabase.instance.db.update(
              'sync_outbox',
              {
                'next_retry_at': nextTry.toIso8601String(),
                'error': '$error',
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
          await AppDatabase.instance.setSetting('sync.last_error', '$error');
          break;
        }
        if (error.statusCode >= 400 &&
            error.statusCode < 500 &&
            error.statusCode != 408 &&
            batch.length > 1) {
          // Relay menolak batch secara keseluruhan. Kirim ulang satu per satu
          // agar hanya amplop bermasalah yang ditandai gagal.
          sent += await _sendIndividually(
            client: client,
            envelopes: batch,
            rows: batchRows,
          );
        } else {
          await _failOutbox(batchRows.first, error);
        }
        break;
      } catch (error) {
        await _failOutbox(batchRows.first, error);
        break;
      }
    }
    return sent;
  }

  Future<int> _sendIndividually({
    required RelayClient client,
    required List<Map<String, Object?>> envelopes,
    required List<Map<String, Object?>> rows,
  }) async {
    var sent = 0;
    for (var index = 0; index < envelopes.length; index++) {
      try {
        await client.submitEnvelope(envelopes[index]);
        await AppDatabase.instance.db.update(
          'sync_outbox',
          {
            'status': 'sent',
            'sent_at': nowIso(),
            'error': '',
            'next_retry_at': null,
          },
          where: 'id = ?',
          whereArgs: [rows[index]['id']],
        );
        sent++;
      } catch (error) {
        await _failOutbox(rows[index], error);
      }
    }
    return sent;
  }

  int _nextCountLimit(Map<String, Object?> response, int current) {
    final limits = response['max_batch'];
    final maxCount = limits is Map ? (limits['count'] as num?)?.toInt() : null;
    var next = current + max(1, current ~/ 2);
    if (maxCount != null && maxCount > 0) next = min(next, maxCount);
    return next.clamp(1, 100).toInt();
  }

  int _nextBytesLimit(Map<String, Object?> response, int current) {
    final limits = response['max_batch'];
    final maxBytes = limits is Map ? (limits['bytes'] as num?)?.toInt() : null;
    if (maxBytes == null || maxBytes <= 0) return current;
    return maxBytes.clamp(16384, 4 * 1024 * 1024).toInt();
  }

  Future<bool> _applyOnce({
    required Map<String, Object?> envelope,
    required String senderKey,
    required String senderKind,
    SenderProfile? senderProfile,
    required List<int> storeKey,
    required String storeId,
  }) async {
    final data = await verifyEnvelope(
      envelope: envelope,
      senderPublicKey: senderKey,
      storeKey: storeKey,
    );
    final idem = envelope['idempotency_key'] as String? ?? '';
    if (idem.isEmpty) {
      throw StateError('Amplop tanpa idempotency key.');
    }
    var applied = false;
    try {
      await AppDatabase.instance.db.transaction((txn) async {
        final existing = await txn.query(
          'applied_deltas',
          columns: ['idempotency_key'],
          where: 'idempotency_key = ?',
          whereArgs: [idem],
          limit: 1,
        );
        if (existing.isNotEmpty) return;
        final markerRows = await txn.rawQuery(
          'SELECT COALESCE(MAX(id), 0) AS max_id FROM sync_conflicts',
        );
        final conflictFloor = (markerRows.first['max_id'] as num?)?.toInt() ?? 0;
        await _apply(
          txn,
          data,
          envelope['id'] as String? ?? '',
          storeId: storeId,
          senderProfile: senderProfile ?? SenderProfile.legacy(senderKind),
          senderDeviceId: envelope['sender_device_id'] as String? ?? '',
        );
        final conflicts = await txn.query(
          'sync_conflicts',
          columns: ['reason'],
          where: 'id > ?',
          whereArgs: [conflictFloor],
        );
        final reasons = conflicts.map((row) => '${row['reason'] ?? ''}');
        final rejected = reasons.where(
          (reason) =>
              !SyncConflictRules.supersededReasons.contains(reason) &&
              !SyncConflictRules.reviewReasons.contains(reason) &&
              !SyncConflictRules.isFinal(reason),
        );
        if (rejected.isNotEmpty) {
          // Delta ditolak: batalkan seluruh perubahan agar tidak ada data
          // setengah jadi, jangan tandai sudah diterapkan, dan minta ulang.
          throw _ApplyRejected(rejected.first);
        }
        await txn.insert(
          'applied_deltas',
          {
            'idempotency_key': idem,
            'store_id': storeId,
            'envelope_id': envelope['id'] as String? ?? '',
            'entity': data['entity'] ?? '',
            'entity_id': data['entity_id'] ?? '',
            'applied_at': nowIso(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await AppDatabase.instance.noteRemoteHlc(
          txn,
          (envelope['hlc_wall'] as num?)?.toInt() ?? 0,
          (envelope['hlc_counter'] as num?)?.toInt() ?? 0,
        );
        await txn.insert(
          'app_settings',
          {'key': 'sync.last_success_at', 'value': nowIso()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        applied = true;
      });
    } on _ApplyRejected catch (error) {
      throw RetryableSyncException(
        'Perubahan dari perangkat lain ditolak (${error.reason}) '
        'dan akan dicoba lagi.',
        code: error.reason,
      );
    }
    return applied;
  }

  Future<
      ({
        int? blockedSeq,
        int applied,
        int failed,
        String lastError,
        Set<int> attempted,
      })> _retryInbox({
    required String store,
    required String deviceId,
    required List<int> storeKey,
    required Map<String, String?> keys,
    required Map<String, SenderProfile> profiles,
  }) async {
    final rows = await AppDatabase.instance.db.query(
      'sync_inbox',
      where: "status = 'pending'",
      orderBy: 'relay_seq',
    );
    final permanentRows = await AppDatabase.instance.db.query(
      'sync_inbox',
      columns: ['relay_seq', 'last_error'],
      where: "status = 'failed'",
      orderBy: 'relay_seq',
      limit: 1,
    );
    int? blockedSeq;
    var applied = 0;
    var failed = 0;
    var lastError = '';
    final attempted = <int>{};
    if (permanentRows.isNotEmpty) {
      // Amplop permanen yang belum diselesaikan pengguna tetap menahan ack
      // agar relay tidak menganggapnya sudah diterima.
      blockedSeq = (permanentRows.first['relay_seq'] as num?)?.toInt() ?? 1;
      lastError = permanentRows.first['last_error'] as String? ?? '';
    }
    final now = DateTime.now();
    for (final row in rows) {
      final relaySeq = (row['relay_seq'] as num?)?.toInt() ?? 0;
      final dueText = row['next_retry_at'] as String?;
      final due = dueText == null || dueText.isEmpty
          ? now
          : DateTime.tryParse(dueText) ?? now;
      if (due.isAfter(now)) {
        // Masih dalam backoff: jangan diambil ulang dari feed pada siklus ini.
        attempted.add(relaySeq);
        blockedSeq ??= relaySeq;
        lastError = row['last_error'] as String? ?? lastError;
        continue;
      }
      attempted.add(relaySeq);
      final raw = jsonDecode(row['envelope_json'] as String);
      if (raw is! Map) {
        blockedSeq ??= relaySeq;
        continue;
      }
      final envelope = raw.map((key, value) => MapEntry('$key', value));
      final sender = envelope['sender_device_id'] as String? ?? '';
      final key = keys[sender];
      if (key == null) {
        blockedSeq ??= relaySeq;
        lastError = 'Kunci pengirim belum tersedia.';
        continue;
      }
      try {
        final didApply = await _applyOnce(
          envelope: envelope,
          senderKey: key,
          senderKind: profiles[sender]?.kind ?? 'unknown',
          senderProfile: profiles[sender],
          storeKey: storeKey,
          storeId: store,
        );
        if (didApply) applied++;
        await AppDatabase.instance.db.update(
          'sync_inbox',
          {
            'status': 'applied',
            'last_error': '',
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      } catch (error) {
        final attempts = ((row['retry_count'] as num?)?.toInt() ?? 0) + 1;
        final permanent = attempts >= SyncConflictRules.maxRetries;
        await AppDatabase.instance.db.update(
          'sync_inbox',
          {
            'retry_count': attempts,
            'last_error': '$error',
            'next_retry_at': permanent
                ? null
                : DateTime.now()
                    .add(SyncConflictRules.backoffFor(attempts))
                    .toIso8601String(),
            'status': permanent ? 'failed' : 'pending',
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await _upsertConflictForInbox(
          inboxId: row['id'] as int,
          entity: '${row['entity'] ?? envelope['entity'] ?? ''}',
          entityId: '${row['entity_id'] ?? envelope['entity_id'] ?? ''}',
          error: error,
          attempts: attempts,
          permanent: permanent,
          relaySeq: relaySeq,
          envelope: envelope,
        );
        if (permanent) {
          failed++;
        }
        blockedSeq ??= relaySeq;
        lastError = '$error';
      }
    }
    return (
      blockedSeq: blockedSeq,
      applied: applied,
      failed: failed,
      lastError: lastError,
      attempted: attempted,
    );
  }

  Future<int> _rememberFailure({
    required String storeId,
    required String deviceId,
    required int relaySeq,
    required Map<String, Object?> envelope,
    required Object error,
  }) async {
    final envelopeId = envelope['id'] as String? ?? '';
    final idem = envelope['idempotency_key'] as String? ?? '';
    final existing = await AppDatabase.instance.db.query(
      'sync_inbox',
      where: 'envelope_id = ? OR idempotency_key = ?',
      whereArgs: [envelopeId, idem],
      limit: 1,
    );
    final attempts = existing.isEmpty
        ? 1
        : ((existing.first['retry_count'] as num?)?.toInt() ?? 0) + 1;
    final permanent = attempts >= SyncConflictRules.maxRetries;
    final stamp = nowIso();
    int inboxId;
    if (existing.isEmpty) {
      inboxId = await AppDatabase.instance.db.insert('sync_inbox', {
        'store_id': storeId,
        'device_id': deviceId,
        'relay_seq': relaySeq,
        'envelope_id': envelopeId,
        'idempotency_key': idem,
        'entity': '${envelope['entity'] ?? ''}',
        'entity_id': '${envelope['entity_id'] ?? ''}',
        'envelope_json': jsonEncode(envelope),
        'last_error': '$error',
        'retry_count': attempts,
        'next_retry_at': permanent
            ? null
            : DateTime.now()
                .add(SyncConflictRules.backoffFor(attempts))
                .toIso8601String(),
        'status': permanent ? 'failed' : 'pending',
        'created_at': stamp,
        'updated_at': stamp,
      });
    } else {
      inboxId = existing.first['id'] as int;
      await AppDatabase.instance.db.update(
        'sync_inbox',
        {
          'relay_seq': relaySeq,
          'envelope_json': jsonEncode(envelope),
          'last_error': '$error',
          'retry_count': attempts,
          'next_retry_at': permanent
              ? null
              : DateTime.now()
                  .add(SyncConflictRules.backoffFor(attempts))
                  .toIso8601String(),
          'status': permanent ? 'failed' : 'pending',
          'updated_at': stamp,
        },
        where: 'id = ?',
        whereArgs: [inboxId],
      );
    }
    await _upsertConflictForInbox(
      inboxId: inboxId,
      entity: '${envelope['entity'] ?? ''}',
      entityId: '${envelope['entity_id'] ?? ''}',
      error: error,
      attempts: attempts,
      permanent: permanent,
      relaySeq: relaySeq,
      envelope: envelope,
    );
    return attempts;
  }

  Future<void> _upsertConflictForInbox({
    required int inboxId,
    required String entity,
    required String entityId,
    required Object error,
    required int attempts,
    required bool permanent,
    required int relaySeq,
    required Map<String, Object?> envelope,
  }) async {
    final existing = await AppDatabase.instance.db.query(
      'sync_conflicts',
      columns: ['id'],
      where: 'inbox_id = ? AND resolved_at IS NULL',
      whereArgs: [inboxId],
      limit: 1,
    );
    final reason = SyncConflictRules.reasonFor(error);
    final detail = jsonEncode({
      'seq': relaySeq,
      'envelope_id': envelope['id'],
      'sender_device_id': envelope['sender_device_id'],
      'error': '$error',
      'retryable': SyncConflictRules.isRetryable(error),
      'permanent': permanent,
    });
    if (existing.isEmpty) {
      await AppDatabase.instance.db.insert('sync_conflicts', {
        'entity': entity,
        'entity_id': entityId,
        'reason': reason,
        'detail_json': detail,
        'status': permanent ? 'failed' : 'retrying',
        'retry_count': attempts,
        'last_error': '$error',
        'inbox_id': inboxId,
        'created_at': nowIso(),
      });
      return;
    }
    await AppDatabase.instance.db.update(
      'sync_conflicts',
      {
        'reason': reason,
        'detail_json': detail,
        'status': permanent ? 'failed' : 'retrying',
        'retry_count': attempts,
        'last_error': '$error',
      },
      where: 'id = ?',
      whereArgs: [existing.first['id']],
    );
  }

  Map<String, String?> _senderKeys(List<Map<String, Object?>> devices) {
    return {
      for (final device in devices)
        if (device['id'] != null)
          '${device['id']}': device['public_key'] as String?,
    };
  }

  Map<String, SenderProfile> _senderProfiles(
    List<Map<String, Object?>> devices,
  ) {
    return {
      for (final device in devices)
        if (device['id'] != null)
          '${device['id']}': SenderProfile(
            kind: '${device['kind'] ?? ''}',
            roleBase: '${device['role_base'] ?? ''}',
            extraPermissions: ((device['extra_permissions'] as List?) ?? const [])
                .map((item) => '$item')
                .toSet(),
            permissionsExplicit: device['permissions_explicit'] == true,
            storeIds: ((device['store_ids'] as List?) ?? const [])
                .map((item) => '$item')
                .toList(),
            revoked: '${device['revoked_at'] ?? ''}'.trim().isNotEmpty,
            accountActive: device['akun_aktif'] != false,
            employeeSyncId: '${device['employee_account_id'] ?? ''}',
          ),
    };
  }

  /// Aturan master: HLC terbesar menang; HLC sama berarti versi lokal
  /// dipertahankan. Baris lama tanpa HLC (0,0) menerima versi pertama.
  Future<bool> _remoteWins(
    DatabaseExecutor txn, {
    required String table,
    required String syncId,
    required int wall,
    required int counter,
  }) async {
    final rows = await txn.query(
      table,
      columns: ['sync_hlc_wall', 'sync_hlc_counter'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return true;
    final localWall = (rows.first['sync_hlc_wall'] as num?)?.toInt() ?? 0;
    final localCounter =
        (rows.first['sync_hlc_counter'] as num?)?.toInt() ?? 0;
    if (wall != localWall) return wall > localWall;
    if (counter != localCounter) return counter > localCounter;
    return localWall == 0 && localCounter == 0;
  }

  Future<String> _uniqueStockCode(
    DatabaseExecutor txn,
    String kode,
  ) async {
    var suffix = 2;
    while (true) {
      final candidate = '$kode-$suffix';
      final rows = await txn.query(
        'stock_items',
        columns: ['id'],
        where: 'kode = ? AND deleted_at IS NULL',
        whereArgs: [candidate],
        limit: 1,
      );
      if (rows.isEmpty) return candidate;
      suffix++;
    }
  }

  Future<void> _recordConflict(
    DatabaseExecutor txn, {
    required String entity,
    required String entityId,
    required String reason,
    required Map<String, Object?> detail,
    String status = 'open',
  }) async {
    final effective =
        status == 'open' && SyncConflictRules.isFinal(reason)
            ? 'rejected'
            : status;
    final existing = await txn.query(
      'sync_conflicts',
      columns: ['id'],
      where: "entity = ? AND entity_id = ? AND reason = ? "
          "AND status IN ('open', 'review')",
      whereArgs: [entity, entityId, reason],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      // Konflik yang sama berulang hanya memperbarui rinciannya; indeks unik
      // parsial menjaga satu baris tertunda per entitas+alasan.
      await txn.update(
        'sync_conflicts',
        {
          'detail_json': jsonEncode(detail),
          'last_error': '${detail['error'] ?? ''}',
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return;
    }
    await txn.insert('sync_conflicts', {
      'entity': entity,
      'entity_id': entityId,
      'reason': reason,
      'detail_json': jsonEncode(detail),
      'status': effective,
      'retry_count': 0,
      'last_error': '${detail['error'] ?? ''}',
      'created_at': nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _apply(
    DatabaseExecutor txn,
    Map<String, Object?> data,
    String envelopeId, {
    required String storeId,
    SenderProfile senderProfile = const SenderProfile.legacy('unknown'),
    String senderDeviceId = '',
  }) async {
    final senderKind = senderProfile.kind;
    final entity = data['entity'] as String? ?? '';
    final action = data['action'] as String? ?? '';
    final payload = data['payload'] as Map<String, Object?>? ?? const {};
    final wall = (data['hlc_wall'] as num?)?.toInt() ?? 0;
    final counter = (data['hlc_counter'] as num?)?.toInt() ?? 0;
    final hlc = {'sync_hlc_wall': wall, 'sync_hlc_counter': counter};
    final violation = SyncConflictRules.senderViolation(
      sender: senderProfile,
      entity: entity,
      action: action,
    );
    if (violation != null) {
      await _recordConflict(
        txn,
        entity: entity,
        entityId: '${data['entity_id'] ?? payload['sync_id'] ?? ''}',
        reason: violation,
        detail: {
          'envelope_id': envelopeId,
          'sender_kind': senderKind,
          'sender_device_id': senderDeviceId,
          'sender_account': senderProfile.employeeSyncId,
          'action': action,
          'error': '',
        },
      );
      return;
    }
    if (entity == 'customer') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'customers',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {
            'envelope_id': envelopeId,
            'hlc_wall': wall,
            'hlc_counter': counter,
            'error': '',
          },
        );
        return;
      }
      final values = {
        'nama': payload['nama'] ?? '',
        'nomor_hp': payload['nomor_hp'] ?? '',
        'alamat': payload['alamat'],
        'wa_consent': payload['wa_consent'] ?? 1,
        'do_not_contact': payload['do_not_contact'] ?? 0,
        'deleted_at':
            action == 'delete' ? (payload['deleted_at'] ?? nowIso()) : null,
        ...hlc,
        'updated_at': payload['updated_at'] ?? nowIso(),
      };
      final rows = await txn.query(
        'customers',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('customers', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'customers',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'unit') {
      final syncId = payload['sync_id'] as String? ?? '';
      final customerSync = payload['customer_sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      int? customerId;
      if (customerSync.isNotEmpty) {
        final customer = await txn.query(
          'customers',
          columns: ['id'],
          where: 'sync_id = ?',
          whereArgs: [customerSync],
          limit: 1,
        );
        if (customer.isEmpty) {
          throw RetryableSyncException(
            'Unit menunggu data pelanggan ($customerSync) diterapkan.',
            code: 'unit_butuh_customer',
          );
        }
        customerId = customer.first['id'] as int;
      }
      if (!await _remoteWins(
        txn,
        table: 'vehicle_or_units',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      final values = {
        'customer_id': customerId,
        'unit_type': payload['unit_type'] ?? 'MOBIL',
        'nopol': payload['nopol'],
        'merek': payload['merek'],
        'tipe': payload['tipe'],
        'jenis_mobil': payload['jenis_mobil'],
        'tahun_mobil': payload['tahun_mobil'],
        'no_rangka': payload['no_rangka'],
        'no_mesin': payload['no_mesin'],
        'km_terakhir': payload['km_terakhir'],
        'tipe_radiator': payload['tipe_radiator'],
        'label_radiator': payload['label_radiator'],
        'deleted_at':
            action == 'delete' ? (payload['deleted_at'] ?? nowIso()) : null,
        ...hlc,
        'updated_at': payload['updated_at'] ?? nowIso(),
      };
      final rows = await txn.query(
        'vehicle_or_units',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('vehicle_or_units', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'vehicle_or_units',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'stock') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final rows = await txn.query(
        'stock_items',
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (!await _remoteWins(
        txn,
        table: 'stock_items',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      int cents(Object? value) => (value as num?)?.toInt() ?? 0;
      final hargaModal = cents(payload['harga_modal']);
      final hargaJual = cents(payload['harga_jual']);
      final stokMinimum = cents(payload['stok_minimum']);
      if (hargaModal < 0 || hargaJual < 0 || stokMinimum < 0) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'harga_tidak_valid',
          detail: {
            'envelope_id': envelopeId,
            'nama': payload['nama'],
            'harga_modal': payload['harga_modal'],
            'harga_jual': payload['harga_jual'],
            'stok_minimum': payload['stok_minimum'],
            'error': '',
          },
          status: 'review',
        );
        return;
      }
      if (!senderProfile.isOwner && rows.isNotEmpty) {
        final current = rows.first;
        final priceChanged =
            (payload.containsKey('harga_jual') &&
                cents(payload['harga_jual']) !=
                    cents(current['harga_jual'])) ||
            (payload.containsKey('harga_modal') &&
                cents(payload['harga_modal']) !=
                    cents(current['harga_modal']));
        if (priceChanged) {
          await _recordConflict(
            txn,
            entity: entity,
            entityId: syncId,
            reason: 'harga_dikunci_owner',
            detail: {
              'envelope_id': envelopeId,
              'sender_kind': senderKind,
              'action': action,
              'error': '',
            },
          );
          return;
        }
      }
      final values = {
        'kode': payload['kode'],
        'nama': payload['nama'],
        'harga_modal': hargaModal,
        'harga_jual': hargaJual,
        'stok_minimum': stokMinimum,
        'satuan': payload['satuan'] ?? 'pcs',
        'desimal': payload['desimal'] ?? 0,
        // Tombstone tidak boleh dibatalkan oleh amplop edit yang datang
        // belakangan; hanya amplop delete yang boleh menulis `deleted_at`.
        if (action == 'delete') 'deleted_at': payload['deleted_at'] ?? nowIso(),
        ...hlc,
        'updated_at': payload['updated_at'] ?? nowIso(),
      };
      if (rows.isEmpty) {
        final kode = '${payload['kode'] ?? ''}'.trim();
        if (kode.isEmpty) {
          await _recordConflict(
            txn,
            entity: entity,
            entityId: syncId,
            reason: 'kode_barang_kosong',
            detail: {
              'envelope_id': envelopeId,
              'nama': payload['nama'],
              'sender_kind': senderKind,
              'error': '',
            },
            status: 'review',
          );
          return;
        }
        // Kode barang unik per toko. Barang dari perangkat lain dengan kode
        // yang sama tidak boleh memblokir antrean, jadi diberi kode turunan
        // dan pemilik mendapat konflik untuk menggabungkan/mengganti kode.
        var insertedKode = kode;
        final clash = await txn.query(
          'stock_items',
          columns: ['id', 'sync_id', 'nama'],
          where: 'kode = ? AND deleted_at IS NULL',
          whereArgs: [kode],
          limit: 1,
        );
        if (clash.isNotEmpty) {
          insertedKode = await _uniqueStockCode(txn, kode);
          await _recordConflict(
            txn,
            entity: entity,
            entityId: syncId,
            reason: 'kode_barang_bentrok',
            detail: {
              'kode_asal': kode,
              'kode_baru': insertedKode,
              'barang_lama_sync_id': clash.first['sync_id'],
              'barang_lama_nama': clash.first['nama'],
              'barang_masuk_nama': payload['nama'],
              'envelope_id': envelopeId,
              'error': '',
            },
            status: 'review',
          );
        }
        final milli = (payload['jumlah_milli'] as num?)?.toInt() ??
            ((payload['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        if (milli < 0) {
          // Barang baru tidak boleh lahir dengan saldo negatif; saldo hanya
          // berubah lewat pergerakan yang dapat diaudit.
          await _recordConflict(
            txn,
            entity: entity,
            entityId: syncId,
            reason: 'stok_negatif',
            detail: {
              'envelope_id': envelopeId,
              'nama': payload['nama'],
              'jumlah_milli': milli,
              'sender_kind': senderKind,
              'sender_device_id': senderDeviceId,
              'error': '',
            },
            status: 'review',
          );
          return;
        }
        await txn.insert('stock_items', {
          'sync_id': syncId,
          ...values,
          'kode': insertedKode,
          'jumlah': wholeQuantity(milli),
          'jumlah_milli': milli,
          'created_at': nowIso(),
        });
      } else {
        await txn.update(
          'stock_items',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'stock_movement') {
      final syncId = payload['sync_id'] as String? ?? '';
      final stockSync = payload['stock_sync_id'] as String? ?? '';
      if (syncId.isEmpty || stockSync.isEmpty) return;
      final existing = await txn.query(
        'stock_movements',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      final stock = await txn.query(
        'stock_items',
        where: 'sync_id = ?',
        whereArgs: [stockSync],
        limit: 1,
      );
      if (stock.isEmpty) {
        throw RetryableSyncException(
          'Pergerakan stok menunggu barang ($stockSync).',
          code: 'gerakan_tanpa_barang',
        );
      }
      final recordSync = payload['record_sync_id'] as String? ?? '';
      int? recordId;
      if (recordSync.isNotEmpty) {
        final record = await txn.query(
          'service_records',
          columns: ['id'],
          where: 'sync_id = ?',
          whereArgs: [recordSync],
          limit: 1,
        );
        recordId = record.isEmpty ? null : record.first['id'] as int;
      }
      final qtyMilli = (payload['jumlah_milli'] as num?)?.toInt() ?? 0;
      final absoluteMilli =
          (payload['opname_absolut_milli'] as num?)?.toInt();
      if (absoluteMilli != null && absoluteMilli < 0) {
        await _recordConflict(
          txn,
          entity: 'stock',
          entityId: stockSync,
          reason: 'stok_negatif',
          detail: {
            'movement_sync_id': syncId,
            'opname_absolut_milli': absoluteMilli,
            'error': '',
          },
          status: 'review',
        );
        return;
      }
      final before = StockItem.fromRow(stock.first);
      final localWall = (stock.first['sync_hlc_wall'] as num?)?.toInt() ?? 0;
      final localCounter =
          (stock.first['sync_hlc_counter'] as num?)?.toInt() ?? 0;
      final isNewer = wall > localWall ||
          (wall == localWall && counter > localCounter);
      // Opname adalah nilai absolut: hanya berlaku bila HLC-nya lebih baru.
      // Pergerakan delta tetap dijumlahkan karena perubahan bersifat aditif.
      final applyQuantity = absoluteMilli == null || isNewer;
      final nextMilli = absoluteMilli ?? before.jumlahMilli + qtyMilli;
      final stockHlcWall = wall > localWall ? wall : localWall;
      final stockHlcCounter = wall > localWall
          ? counter
          : (wall == localWall && counter > localCounter
              ? counter
              : localCounter);
      await txn.insert('stock_movements', {
        'sync_id': syncId,
        'stock_item_id': stock.first['id'],
        'stock_sync_id': stockSync,
        'nama_item': payload['nama_item'] ?? stock.first['nama'],
        'jenis': payload['jenis'] ?? 'KOREKSI',
        'jumlah': absoluteMilli == null
            ? wholeQuantity(qtyMilli)
            : wholeQuantity(nextMilli - before.jumlahMilli),
        'jumlah_milli': absoluteMilli == null
            ? qtyMilli
            : nextMilli - before.jumlahMilli,
        'stok_sebelum_milli': before.jumlahMilli,
        'stok_sesudah_milli': nextMilli,
        'opname_absolut_milli': absoluteMilli,
        'sumber_entity': payload['sumber_entity'] ??
            (recordId == null ? 'stock_adjustment' : 'service_record'),
        'sumber_sync_id': payload['sumber_sync_id'] ?? syncId,
        'operator': payload['operator'],
        'alasan': payload['alasan'],
        'service_record_id': recordId,
        'sync_hlc_wall': wall,
        'sync_hlc_counter': counter,
        'created_at': payload['created_at'] ?? nowIso(),
        'updated_at': payload['updated_at'] ?? nowIso(),
      });
      if (!applyQuantity) {
        await _recordConflict(
          txn,
          entity: 'stock',
          entityId: stockSync,
          reason: 'versi_lokal_lebih_baru',
          detail: {
            'envelope_id': envelopeId,
            'movement_sync_id': syncId,
            'opname_absolut_milli': absoluteMilli,
            'hlc_wall': wall,
            'hlc_counter': counter,
            'lokal_hlc_wall': localWall,
            'lokal_hlc_counter': localCounter,
            'error': '',
          },
        );
        return;
      }
      await txn.update(
        'stock_items',
        {
          'jumlah': wholeQuantity(nextMilli),
          'jumlah_milli': nextMilli,
          'sync_hlc_wall': stockHlcWall,
          'sync_hlc_counter': stockHlcCounter,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [stock.first['id']],
      );
      if (nextMilli < 0) {
        await _recordConflict(
          txn,
          entity: 'stock',
          entityId: stockSync,
          reason: 'stok_negatif',
          detail: {
            'movement_sync_id': syncId,
            'record_sync_id': recordSync,
            'nama_item': payload['nama_item'] ?? stock.first['nama'],
            'stok_sebelum_milli': before.jumlahMilli,
            'stok_sesudah_milli': nextMilli,
            'sumber_entity': payload['sumber_entity'] ?? '',
            'error': '',
          },
          status: 'review',
        );
      }
    } else if (entity == 'harga_jasa') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'harga_jasa',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      final hargaJual = (payload['harga_jual'] as num?)?.toInt() ?? 0;
      final hargaModal = (payload['harga_modal'] as num?)?.toInt() ?? 0;
      if (hargaJual < 0 || hargaModal < 0) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'harga_tidak_valid',
          detail: {
            'envelope_id': envelopeId,
            'nama': payload['nama'],
            'harga_jual': payload['harga_jual'],
            'harga_modal': payload['harga_modal'],
            'error': '',
          },
          status: 'review',
        );
        return;
      }
      final values = {
        'nama': payload['nama'] ?? '',
        'harga_jual': hargaJual,
        'harga_modal': hargaModal,
        'interval_servis_bulan': payload['interval_servis_bulan'] ?? 0,
        'deleted_at':
            action == 'delete' ? (payload['deleted_at'] ?? nowIso()) : null,
        ...hlc,
        'updated_at': payload['updated_at'] ?? nowIso(),
      };
      final rows = await txn.query(
        'harga_jasa',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('harga_jasa', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'harga_jasa',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'supplier') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'suppliers',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      final values = {
        'nama': payload['nama'] ?? '',
        'nomor_hp': payload['nomor_hp'],
        'alamat': payload['alamat'],
        'catatan': payload['catatan'],
        'aktif': payload['aktif'] ?? 1,
        // Tombstone hanya boleh ditulis oleh aksi delete; amplop edit yang
        // datang belakangan tidak menghidupkan supplier yang sudah dihapus.
        if (action == 'delete') 'deleted_at': payload['deleted_at'] ?? nowIso(),
        ...hlc,
      };
      final rows = await txn.query(
        'suppliers',
        columns: ['id', 'deleted_at'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      final supplierDeleted = action == 'delete' ||
          (rows.isNotEmpty && rows.first['deleted_at'] != null);
      final int supplierId;
      if (rows.isEmpty) {
        supplierId = await txn.insert('suppliers', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': payload['updated_at'] ?? nowIso(),
        });
      } else {
        supplierId = rows.first['id'] as int;
        await txn.update(
          'suppliers',
          {...values, 'updated_at': payload['updated_at'] ?? nowIso()},
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
      if (supplierDeleted) {
        // Relasi mengikuti tombstone supplier tanpa menghapus riwayatnya,
        // sehingga perangkat lain dan payload yang telat tetap konsisten.
        final now = nowIso();
        await txn.update(
          'supplier_items',
          {'deleted_at': now, 'updated_at': now},
          where: 'supplier_id = ? AND deleted_at IS NULL',
          whereArgs: [supplierId],
        );
        await txn.update(
          'supplier_followups',
          {'deleted_at': now, 'updated_at': now},
          where: 'supplier_id = ? AND deleted_at IS NULL',
          whereArgs: [supplierId],
        );
      } else if (payload['stock_sync_ids'] is List) {
        // Payload supplier membawa penggantian penuh daftar barang; relasi
        // yang tidak lagi disebut ditandai tombstone, yang disebut kembali
        // memakai baris lama agar tidak menumpuk duplikat.
        final stockIds = <int>{};
        for (final raw in payload['stock_sync_ids'] as List) {
          final stockSync = '$raw';
          if (stockSync.isEmpty) continue;
          final stock = await txn.query(
            'stock_items',
            columns: ['id'],
            where: 'sync_id = ?',
            whereArgs: [stockSync],
            limit: 1,
          );
          if (stock.isNotEmpty) stockIds.add(stock.first['id'] as int);
        }
        final now = nowIso();
        final current = await txn.query(
          'supplier_items',
          columns: ['id', 'stock_item_id'],
          where: 'supplier_id = ? AND deleted_at IS NULL',
          whereArgs: [supplierId],
        );
        for (final row in current) {
          if (stockIds.contains(row['stock_item_id'])) continue;
          await txn.update(
            'supplier_items',
            {'deleted_at': now, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
        for (final stockId in stockIds) {
          final previous = await txn.query(
            'supplier_items',
            columns: ['id'],
            where: 'supplier_id = ? AND stock_item_id = ?',
            whereArgs: [supplierId, stockId],
            orderBy: 'id DESC',
            limit: 1,
          );
          if (previous.isEmpty) {
            await txn.insert('supplier_items', {
              'sync_id': newSyncId(),
              'supplier_id': supplierId,
              'stock_item_id': stockId,
              'created_at': now,
              'updated_at': now,
            });
          } else {
            await txn.update(
              'supplier_items',
              {'deleted_at': null, 'updated_at': now},
              where: 'id = ?',
              whereArgs: [previous.first['id']],
            );
          }
        }
      }
    } else if (entity == 'supplier_followup') {
      final supplierSync = payload['supplier_sync_id'] as String? ?? '';
      final stockSync = payload['stock_sync_id'] as String? ?? '';
      final supplier = await txn.query(
        'suppliers',
        columns: ['id', 'deleted_at'],
        where: 'sync_id = ?',
        whereArgs: [supplierSync],
        limit: 1,
      );
      final stock = await txn.query(
        'stock_items',
        columns: ['id', 'deleted_at'],
        where: 'sync_id = ?',
        whereArgs: [stockSync],
        limit: 1,
      );
      if (supplier.isEmpty || stock.isEmpty) {
        throw RetryableSyncException(
          'Follow-up supplier menunggu supplier/barang.',
          code: 'followup_supplier_butuh_induk',
        );
      }
      if (supplier.first['deleted_at'] != null ||
          stock.first['deleted_at'] != null) {
        return;
      }
      if (!await _remoteWins(
        txn,
        table: 'supplier_followups',
        syncId: payload['sync_id'] as String? ?? '',
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: payload['sync_id'] as String? ?? '',
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      final values = {
        'status': payload['status'] ?? 'BELUM',
        'catatan': payload['catatan'],
        'deleted_at': null,
        'updated_at': payload['updated_at'] ?? nowIso(),
        ...hlc,
      };
      final rows = await txn.query(
        'supplier_followups',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [payload['sync_id'] ?? ''],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('supplier_followups', {
          'sync_id': payload['sync_id'] ?? newSyncId(),
          'supplier_id': supplier.first['id'],
          'stock_item_id': stock.first['id'],
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'supplier_followups',
          {
            ...values,
            'supplier_id': supplier.first['id'],
            'stock_item_id': stock.first['id'],
          },
          where: 'id = ?',
          whereArgs: [rows.first['id']],
        );
      }
    } else if (entity == 'commission') {
      final recordSync = payload['record_sync_id'] as String? ?? '';
      final record = await txn.query(
        'service_records',
        columns: ['id', 'status', 'voided_at'],
        where: 'sync_id = ?',
        whereArgs: [recordSync],
        limit: 1,
      );
      if (record.isEmpty) {
        throw RetryableSyncException(
          'Komisi menunggu nota ($recordSync).',
          code: 'komisi_tanpa_nota',
        );
      }
      if (!await _remoteWins(
        txn,
        table: 'service_record_commissions',
        syncId: payload['sync_id'] as String? ?? '',
        wall: wall,
        counter: counter,
      )) {
        return;
      }
      final recordVoid = record.first['voided_at'] != null ||
          '${record.first['status']}' == 'VOID';
      final values = {
        'employee_nama_snapshot': payload['employee_nama_snapshot'],
        'mode_snapshot': payload['mode_snapshot'] ?? 'PERSEN',
        'nilai_snapshot': payload['nilai_snapshot'] ?? 0,
        'dasar_jasa': payload['dasar_jasa'] ?? 0,
        'dasar_barang': payload['dasar_barang'] ?? 0,
        'nominal': recordVoid ? 0 : (payload['nominal'] ?? 0),
        'nominal_override': recordVoid ? null : payload['nominal_override'],
        'status': recordVoid ? 'VOID' : (payload['status'] ?? 'AKTIF'),
        'voided_at': recordVoid
            ? (payload['voided_at'] ?? nowIso())
            : payload['voided_at'],
        ...hlc,
      };
      final rows = await txn.query(
        'service_record_commissions',
        columns: ['id'],
        where: 'service_record_id = ? AND employee_sync_id = ?',
        whereArgs: [record.first['id'], payload['employee_sync_id']],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('service_record_commissions', {
          'sync_id': payload['sync_id'] ?? newSyncId(),
          'service_record_id': record.first['id'],
          'employee_sync_id': payload['employee_sync_id'] ?? '',
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': payload['updated_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'service_record_commissions',
          values,
          where: 'id = ?',
          whereArgs: [rows.first['id']],
        );
      }
    } else if (entity == 'employee') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final local = await txn.query(
        'employee_accounts',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      // Akun belum pernah dipasangkan di perangkat ini; tidak ada yang
      // diperbarui dan tidak perlu ditahan sebagai konflik.
      if (local.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'employee_accounts',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        return;
      }
      final localRow = await txn.query(
        'employee_accounts',
        columns: ['permission_version'],
        where: 'id = ?',
        whereArgs: [local.first['id']],
        limit: 1,
      );
      final localVersion =
          (localRow.isEmpty ? 0 : (localRow.first['permission_version'] as num?)?.toInt()) ??
              0;
      final incomingVersion =
          (payload['permission_version'] as num?)?.toInt() ?? 0;
      final applyPermissions = incomingVersion >= localVersion;
      await txn.update(
        'employee_accounts',
        {
          'nama': payload['nama'],
          'aktif': payload['aktif'] ?? 1,
          if (payload['username'] != null)
            'username': payload['username'],
          if (applyPermissions && payload['role_base'] != null)
            'role_base': payload['role_base'],
          if (applyPermissions && payload['extra_permissions_json'] != null)
            'extra_permissions_json': payload['extra_permissions_json'],
          if (applyPermissions && payload['store_ids_json'] != null)
            'store_ids_json': payload['store_ids_json'],
          if (applyPermissions && payload['permissions_explicit'] != null)
            'permissions_explicit': payload['permissions_explicit'],
          if (applyPermissions && incomingVersion > 0)
            'permission_version': incomingVersion,
          'jenis_imbalan': payload['jenis_imbalan'],
          'gaji_bulanan': payload['gaji_bulanan'],
          'komisi_mode': payload['komisi_mode'],
          'komisi_barang_nilai': payload['komisi_barang_nilai'],
          'komisi_jasa_nilai': payload['komisi_jasa_nilai'],
          'payroll_period': payload['payroll_period'],
          'payroll_tanggal': payload['payroll_tanggal'],
          'payroll_hari': payload['payroll_hari'],
          'bank_nama': payload['bank_nama'],
          'bank_nomor': payload['bank_nomor'],
          'bank_pemilik': payload['bank_pemilik'],
          'tanggal_masuk': payload['tanggal_masuk'],
          ...hlc,
          'updated_at': payload['updated_at'] ?? nowIso(),
        },
        where: 'id = ?',
        whereArgs: [local.first['id']],
      );
      if (applyPermissions) {
        await AccountService.syncStoreAccess(
          txn,
          employeeSyncId: syncId,
          role: '${payload['role_base'] ?? 'KASIR'}',
          extraPermissions: _jsonList(payload['extra_permissions_json']),
          explicit: payload['permissions_explicit'] == 1,
          aktif: payload['aktif'] != 0,
          storeIds: _jsonList(payload['store_ids_json']),
          version: incomingVersion,
        );
      }
    } else if (entity == 'debt') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'employee_debts',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        return;
      }
      final values = {
        'employee_sync_id': payload['employee_sync_id'] ?? '',
        'nominal': payload['nominal'] ?? 0,
        'terbayar': payload['terbayar'] ?? 0,
        'catatan': payload['catatan'],
        ...hlc,
      };
      final rows = await txn.query(
        'employee_debts',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('employee_debts', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': payload['updated_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'employee_debts',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'salary') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final employeeSync = payload['employee_sync_id'] ?? '';
      final cycleStart = payload['cycle_start'] ?? '';
      final nominal = (payload['nominal'] as num?)?.toInt() ?? 0;
      final potongan = (payload['potongan_hutang'] as num?)?.toInt() ?? 0;
      final kasKeluar =
          (payload['kas_keluar'] as num?)?.toInt() ?? (nominal - potongan);
      final rows = await txn.query(
        'salary_payments',
        columns: ['id', 'sync_id', 'nominal'],
        where: 'employee_sync_id = ? AND cycle_start = ?',
        whereArgs: [employeeSync, cycleStart],
        limit: 1,
      );
      if (rows.isNotEmpty && '${rows.first['sync_id']}' != syncId) {
        // Satu siklus hanya dibayar sekali. Pembayaran kedua dari perangkat
        // lain tidak menimpa baris yang sudah ada; nominalnya dicatat sebagai
        // konflik agar pemilik dapat meninjau dan mengembalikan uangnya.
        final existing = await txn.query(
          'sync_conflicts',
          columns: ['id'],
          where: "entity = 'salary' AND entity_id = ? AND reason = ? "
              "AND status IN ('open', 'review')",
          whereArgs: [syncId, 'gaji_ganda'],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('sync_conflicts', {
            'entity': 'salary',
            'entity_id': syncId,
            'reason': 'gaji_ganda',
            'detail_json': jsonEncode({
              'employee_sync_id': employeeSync,
              'employee_nama': payload['employee_nama_snapshot'],
              'cycle_start': cycleStart,
              'cycle_end': payload['cycle_end'] ?? cycleStart,
              'tanggal': payload['tanggal'] ?? cycleStart,
              'gaji_tersimpan_sync_id': rows.first['sync_id'],
              'gaji_masuk_sync_id': syncId,
              'nominal_tersimpan': rows.first['nominal'],
              'nominal_masuk': nominal,
              'potongan_hutang': potongan,
              'kas_keluar': kasKeluar,
              'metode': payload['metode'] ?? 'CASH',
            }),
            'status': 'review',
            'retry_count': 0,
            'last_error': '',
            'created_at': nowIso(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          await txn.update(
            'salary_payments',
            {'konflik_sync_id': syncId, 'updated_at': nowIso()},
            where: 'id = ?',
            whereArgs: [rows.first['id']],
          );
        }
        // Uang benar-benar keluar di perangkat asal. Catat arus kasnya agar
        // laporan kas tidak kehilangan pembayaran kedua meski baris gaji
        // hanya boleh satu per siklus.
        if (kasKeluar > 0) {
          await txn.insert(
            'cash_ledger',
            {
              'sync_id': newSyncId(),
              'waktu': payload['tanggal'] ?? nowIso(),
              'kategori': 'GAJI',
              'sumber_entity': 'salary_payment',
              'sumber_sync_id': syncId,
              'nominal': -kasKeluar,
              'metode': payload['metode'] ?? 'CASH',
              'operator': payload['employee_nama_snapshot'],
              'catatan': 'Gaji ganda ${payload['periode'] ?? ''}',
              'created_at': nowIso(),
              'updated_at': nowIso(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        return;
      }
      if (!await _remoteWins(
        txn,
        table: 'salary_payments',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        return;
      }
      final values = {
        'employee_sync_id': employeeSync,
        'employee_nama_snapshot': payload['employee_nama_snapshot'],
        'periode': payload['periode'] ?? 'BULANAN',
        'cycle_start': cycleStart,
        'cycle_end': payload['cycle_end'] ?? cycleStart,
        'cycle_key': payload['cycle_key'] ?? '$employeeSync|$cycleStart',
        'tanggal': payload['tanggal'] ?? cycleStart,
        'nominal': nominal,
        'potongan_hutang': potongan,
        'cicilan_hutang':
            payload['cicilan_hutang'] ?? payload['potongan_hutang'] ?? 0,
        'bonus': payload['bonus'] ?? 0,
        'komisi_total': payload['komisi_total'] ?? 0,
        'kas_keluar': kasKeluar,
        'metode': payload['metode'] ?? 'CASH',
        'status': payload['status'] ?? 'AKTIF',
        'catatan': payload['catatan'],
        ...hlc,
      };
      if (rows.isEmpty) {
        await txn.insert('salary_payments', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': payload['updated_at'] ?? nowIso(),
        });
        if (kasKeluar > 0) {
          await txn.insert(
            'cash_ledger',
            {
              'sync_id': newSyncId(),
              'waktu': payload['tanggal'] ?? nowIso(),
              'kategori': 'GAJI',
              'sumber_entity': 'salary_payment',
              'sumber_sync_id': syncId,
              'nominal': -kasKeluar,
              'metode': payload['metode'] ?? 'CASH',
              'operator': payload['employee_nama_snapshot'],
              'catatan': 'Gaji ${payload['periode'] ?? ''}',
              'created_at': nowIso(),
              'updated_at': nowIso(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      } else {
        await txn.update(
          'salary_payments',
          values,
          where: 'id = ?',
          whereArgs: [rows.first['id']],
        );
      }
      for (final raw in (payload['debt_updates'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final debtSync = '${raw['sync_id'] ?? ''}';
        final paid = (raw['terbayar'] as num?)?.toInt() ?? 0;
        if (debtSync.isEmpty) continue;
        final debt = await txn.query(
          'employee_debts',
          columns: ['id', 'terbayar'],
          where: 'sync_id = ?',
          whereArgs: [debtSync],
          limit: 1,
        );
        if (debt.isEmpty) continue;
        final localPaid = (debt.first['terbayar'] as num?)?.toInt() ?? 0;
        if (paid <= localPaid) continue;
        await txn.update(
          'employee_debts',
          {
            'terbayar': paid,
            'sync_hlc_wall': wall,
            'sync_hlc_counter': counter,
          },
          where: 'id = ?',
          whereArgs: [debt.first['id']],
        );
      }
    } else if (entity == 'nota') {
      final conflictRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(id), 0) AS max_id FROM sync_conflicts',
      );
      final conflictFloor = (conflictRows.first['max_id'] as num?)?.toInt() ?? 0;
      final noteResult = await AppDatabase.instance.applyNotePayloadTx(
        txn,
        payload,
        action: action,
        enqueueCommission: (txn2, commissionId) =>
            enqueueCommission(commissionId, txn: txn2),
      );
      final autoCancelled = noteResult == 'auto_cancelled';
      final record = payload['record'] as Map<String, Object?>? ?? const {};
      final recordSync = '${record['sync_id'] ?? ''}';
      final estimateSync = '${record['estimate_sync_id'] ?? ''}'.trim();
      if (!autoCancelled &&
          recordSync.isNotEmpty &&
          estimateSync.isNotEmpty) {
        await txn.update(
          'estimates',
          {
            'status': 'dikonversi',
            'converted_nota_sync_id': recordSync,
            'total_estimasi_terakhir':
                record['total_estimasi_terakhir'],
            'updated_at': nowIso(),
          },
          where: 'sync_id = ?',
          whereArgs: [estimateSync],
        );
      }
      final orderSync = '${record['work_order_sync_id'] ?? ''}'.trim();
      if (!autoCancelled && recordSync.isNotEmpty && orderSync.isNotEmpty) {
        await txn.update(
          'work_orders',
          {'nota_sync_id': recordSync, 'updated_at': nowIso()},
          where: 'sync_id = ?',
          whereArgs: [orderSync],
        );
      }
      if (recordSync.isNotEmpty) {
        if (!autoCancelled) {
          for (final key in const ['jobs', 'parts']) {
            for (final raw in (payload[key] as List? ?? const [])) {
              if (raw is! Map) continue;
              final finalPrice = (raw['harga_final'] as num?)?.toInt() ??
                  (raw['harga'] as num?)?.toInt() ??
                  0;
              final batas =
                  (raw['harga_batas_saat_transaksi'] as num?)?.toInt() ?? 0;
              if (finalPrice >= batas) continue;
              final approver = '${raw['disetujui_oleh'] ?? ''}'.trim();
              if (approver.isNotEmpty) continue;
              await _recordConflict(
                txn,
                entity: 'nota',
                entityId: recordSync,
                reason: 'harga_di_bawah_batas',
                detail: {
                  'baris': key,
                  'deskripsi': raw['deskripsi'],
                  'harga_final': finalPrice,
                  'harga_batas': batas,
                  'error': '',
                },
                status: 'review',
              );
            }
          }
        }
        final renumbered = await txn.query(
          'sync_conflicts',
          columns: ['id'],
          where: "id > ? AND reason = 'no_nota_bentrok'",
          whereArgs: [conflictFloor],
          limit: 1,
        );
        if (renumbered.isNotEmpty && action == 'upsert') {
          final local = await txn.query(
            'service_records',
            columns: ['no_nota'],
            where: 'sync_id = ?',
            whereArgs: [recordSync],
            limit: 1,
          );
          final localNoNota =
              local.isEmpty ? '' : '${local.first['no_nota'] ?? ''}';
          if (localNoNota.isNotEmpty) {
            // Umumkan nomor hasil renumbering agar perangkat lain ikut
            // memakai nomor yang sama.
            await enqueue(
              txn: txn,
              entity: 'nota',
              action: 'upsert',
              entityId: recordSync,
              payload: {
                'record': {
                  'sync_id': recordSync,
                  'no_nota': localNoNota,
                },
              },
            );
          }
        }
      }
    } else if (entity == 'supplier_purchase') {
      final createdAt = '${payload['created_at'] ?? ''}';
      final allowed =
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featureSupplierHub,
            createdAt,
          ) &&
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featurePurchaseDebt,
            createdAt,
          );
      if (!allowed) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: '${payload['sync_id'] ?? ''}',
          reason: 'fitur_nonaktif',
          detail: {
            'no_pembelian': payload['no_pembelian'],
            'created_at': createdAt,
          },
          status: 'review',
        );
        return;
      }
      await PurchaseService.instance.applyPurchaseRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
        action: action,
      );
    } else if (entity == 'supplier_payment') {
      final createdAt = '${payload['created_at'] ?? ''}';
      final allowed =
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featureSupplierHub,
            createdAt,
          ) &&
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featurePurchaseDebt,
            createdAt,
          );
      if (!allowed) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: '${payload['sync_id'] ?? ''}',
          reason: 'fitur_nonaktif',
          detail: {'purchase_sync_id': payload['purchase_sync_id']},
          status: 'review',
        );
        return;
      }
      await PurchaseService.instance.applyPaymentRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
      );
    } else if (entity == 'supplier_purchase_return') {
      final createdAt = '${payload['created_at'] ?? ''}';
      final allowed =
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featureSupplierHub,
            createdAt,
          ) &&
          await FeatureFlagsService.instance.acceptsRemoteAt(
            txn,
            featurePurchaseDebt,
            createdAt,
          );
      if (!allowed) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: '${payload['sync_id'] ?? ''}',
          reason: 'fitur_nonaktif',
          detail: {'purchase_sync_id': payload['purchase_sync_id']},
          status: 'review',
        );
        return;
      }
      await PurchaseService.instance.applyReturnRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
      );
    } else if (entity == 'opening_balance') {
      await OpeningBalanceService.instance.applyRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
        action: action,
      );
    } else if (entity == 'store_feature') {
      await FeatureFlagsService.instance.applyRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
      );
    } else if (entity == 'store_settings') {
      await StoreSettingsService.instance.applyRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
      );
    } else if (entity == 'estimate') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final rows = await txn.query(
        'estimates',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      final items = (payload['items'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, Object?>.from(item))
          .toList();
      if (rows.isEmpty) {
        await txn.insert('estimates', {
          'sync_id': syncId,
          'device_id': payload['device_id'] ?? '',
          'nomor_estimasi': payload['nomor_estimasi'] ?? '',
          'work_order_sync_id': payload['work_order_sync_id'],
          'customer_sync_id': payload['customer_sync_id'],
          'unit_sync_id': payload['unit_sync_id'],
          'versi': payload['versi'] ?? 1,
          'revisi_dari_sync_id': payload['revisi_dari_sync_id'],
          'alasan_revisi': payload['alasan_revisi'],
          'masa_berlaku': payload['masa_berlaku'],
          'total': payload['total'] ?? 0,
          'status': payload['status'] ?? 'aktif',
          'disetujui_oleh': payload['disetujui_oleh'],
          'disetujui_at': payload['disetujui_at'],
          'mode_saat_dibuat_json':
              jsonEncode(payload['mode_saat_dibuat'] ?? const {}),
          'converted_nota_sync_id': payload['converted_nota_sync_id'],
          'total_estimasi_terakhir': payload['total_estimasi_terakhir'],
          'dibuat_oleh': payload['dibuat_oleh'],
          ...hlc,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': payload['updated_at'] ?? nowIso(),
        });
        await _insertEstimateItems(
          txn,
          syncId: syncId,
          items: items,
          createdAt: payload['created_at'],
        );
      } else {
        if (!await _remoteWins(
          txn,
          table: 'estimates',
          syncId: syncId,
          wall: wall,
          counter: counter,
        )) {
          return;
        }
        final local = await txn.query(
          'estimates',
          columns: ['versi'],
          where: 'sync_id = ?',
          whereArgs: [syncId],
          limit: 1,
        );
        final localVersi = local.isEmpty
            ? 0
            : (local.first['versi'] as num?)?.toInt() ?? 0;
        final remoteVersi =
            (payload['versi'] as num?)?.toInt() ?? localVersi;
        final values = <String, Object?>{
          'status': payload['status'] ?? 'aktif',
          'disetujui_oleh': payload['disetujui_oleh'],
          'disetujui_at': payload['disetujui_at'],
          'converted_nota_sync_id': payload['converted_nota_sync_id'],
          'total_estimasi_terakhir': payload['total_estimasi_terakhir'],
          ...hlc,
          'updated_at': payload['updated_at'] ?? nowIso(),
        };
        if (remoteVersi > localVersi) {
          values.addAll({
            'device_id': payload['device_id'] ?? '',
            'nomor_estimasi': payload['nomor_estimasi'] ?? '',
            'work_order_sync_id': payload['work_order_sync_id'],
            'customer_sync_id': payload['customer_sync_id'],
            'unit_sync_id': payload['unit_sync_id'],
            'versi': remoteVersi,
            'revisi_dari_sync_id': payload['revisi_dari_sync_id'],
            'alasan_revisi': payload['alasan_revisi'],
            'masa_berlaku': payload['masa_berlaku'],
            'total': payload['total'] ?? 0,
            'mode_saat_dibuat_json':
                jsonEncode(payload['mode_saat_dibuat'] ?? const {}),
            'dibuat_oleh': payload['dibuat_oleh'],
          });
        }
        await txn.update(
          'estimates',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
        if (remoteVersi > localVersi) {
          // Revisi lebih tinggi menggantikan seluruh baris lama.
          await txn.delete(
            'estimate_items',
            where: 'estimate_sync_id = ?',
            whereArgs: [syncId],
          );
          await _insertEstimateItems(
            txn,
            syncId: syncId,
            items: items,
            createdAt: payload['created_at'],
          );
        }
      }
      for (final item in items) {
        final finalPrice = (item['harga_final'] as num?)?.toInt() ?? 0;
        final batas =
            (item['harga_batas_saat_transaksi'] as num?)?.toInt() ?? 0;
        final approved = '${payload['disetujui_oleh'] ?? ''}'.trim();
        if (finalPrice < batas && approved.isEmpty) {
          await _recordConflict(
            txn,
            entity: 'estimate',
            entityId: syncId,
            reason: 'harga_di_bawah_batas',
            detail: {
              'item': item['deskripsi'],
              'harga_final': finalPrice,
              'harga_batas': batas,
              'error': '',
            },
            status: 'review',
          );
        }
      }
    } else if (entity == 'work_order') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      if (!await _remoteWins(
        txn,
        table: 'work_orders',
        syncId: syncId,
        wall: wall,
        counter: counter,
      )) {
        await _recordConflict(
          txn,
          entity: entity,
          entityId: syncId,
          reason: 'versi_lokal_lebih_baru',
          detail: {'envelope_id': envelopeId, 'hlc_wall': wall, 'error': ''},
        );
        return;
      }
      final rows = await txn.query(
        'work_orders',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      final values = {
        'device_id': payload['device_id'] ?? '',
        'nomor_order': payload['nomor_order'],
        'nomor_antrian': payload['nomor_antrian'],
        'customer_sync_id': payload['customer_sync_id'],
        'unit_sync_id': payload['unit_sync_id'],
        'keluhan': payload['keluhan'] ?? '',
        'status': payload['status'] ?? 'antri',
        'mekanik_sync_id': payload['mekanik_sync_id'],
        'mekanik_nama': payload['mekanik_nama'],
        'waktu_masuk': payload['waktu_masuk'] ?? nowIso(),
        'waktu_selesai': payload['waktu_selesai'],
        'nota_sync_id': payload['nota_sync_id'],
        'mode_saat_dibuat_json':
            jsonEncode(payload['mode_saat_dibuat'] ?? const {}),
        'deleted_at':
            action == 'delete' ? (payload['deleted_at'] ?? nowIso()) : null,
        ...hlc,
        'updated_at': payload['updated_at'] ?? nowIso(),
      };
      if (rows.isEmpty) {
        await txn.insert('work_orders', {
          'sync_id': syncId,
          ...values,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'work_orders',
          values,
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
      await _refreshWorkOrderStatus(txn, syncId);
    } else if (entity == 'work_order_status') {
      final syncId = payload['sync_id'] as String? ?? '';
      final orderSync = payload['work_order_sync_id'] as String? ?? '';
      final status = payload['status'] as String? ?? '';
      if (syncId.isEmpty || orderSync.isEmpty || status.isEmpty) return;
      final order = await txn.query(
        'work_orders',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [orderSync],
        limit: 1,
      );
      if (order.isEmpty) {
        throw RetryableSyncException(
          'Status order menunggu order ($orderSync).',
          code: 'status_tanpa_order',
        );
      }
      final existing = await txn.query(
        'work_order_status_log',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await _refreshWorkOrderStatus(txn, orderSync);
        return;
      }
      final previous = await txn.query(
        'work_order_status_log',
        columns: ['status'],
        where: 'work_order_sync_id = ?',
        whereArgs: [orderSync],
        orderBy:
            'sync_hlc_wall DESC, sync_hlc_counter DESC, id DESC',
        limit: 1,
      );
      final from =
          previous.isEmpty ? null : previous.first['status'] as String?;
      if (from != null &&
          !senderProfile.isOwner &&
          !allowedWorkOrderTransitions(from).contains(status)) {
        await _recordConflict(
          txn,
          entity: 'work_order_status',
          entityId: orderSync,
          reason: 'transisi_status_dilarang',
          detail: {'dari': from, 'ke': status, 'error': ''},
          status: 'review',
        );
        return;
      }
      await txn.insert('work_order_status_log', {
        'sync_id': syncId,
        'work_order_sync_id': orderSync,
        'status': status,
        'waktu': payload['waktu'] ?? nowIso(),
        'pembuat': payload['pembuat'],
        'perangkat': payload['perangkat'],
        ...hlc,
        'created_at': payload['created_at'] ?? nowIso(),
        'updated_at': nowIso(),
      });
      await _refreshWorkOrderStatus(txn, orderSync);
    } else if (entity == 'nota_adjustment') {
      final syncId = payload['sync_id'] as String? ?? '';
      final notaSync = payload['nota_sync_id'] as String? ?? '';
      if (syncId.isEmpty || notaSync.isEmpty) return;
      final record = await txn.query(
        'service_records',
        columns: ['id', 'status', 'voided_at'],
        where: 'sync_id = ?',
        whereArgs: [notaSync],
        limit: 1,
      );
      if (record.isEmpty) {
        throw RetryableSyncException(
          'Koreksi menunggu nota asal ($notaSync).',
          code: 'koreksi_tanpa_nota',
        );
      }
      if (record.first['voided_at'] != null ||
          '${record.first['status']}' == 'VOID') {
        // Koreksi tidak dapat diterapkan ke nota VOID, tetapi tidak boleh
        // dibuang diam-diam. Konflik menandai koreksi yang tidak terpakai.
        await _recordConflict(
          txn,
          entity: 'nota_adjustment',
          entityId: syncId,
          reason: 'koreksi_pada_nota_void',
          detail: {
            'nota_sync_id': notaSync,
            'nilai_baru': payload['nilai_baru'],
            'error': '',
          },
          status: 'review',
        );
        return;
      }
      await NotaAdjustmentService.instance.applyRemote(
        txn,
        payload,
        wall: wall,
        counter: counter,
      );
      final modal = await txn.rawQuery(
        'SELECT ${AppDatabase.recordModalSql} AS modal',
        [record.first['id'], record.first['id']],
      );
      final modalTotal = (modal.first['modal'] as num?)?.toInt() ?? 0;
      final nilaiBaru = (payload['nilai_baru'] as num?)?.toInt() ?? 0;
      final approver = '${payload['disetujui_oleh'] ?? ''}'.trim();
      if (nilaiBaru < modalTotal && approver.isEmpty) {
        await _recordConflict(
          txn,
          entity: 'nota_adjustment',
          entityId: syncId,
          reason: 'koreksi_di_bawah_batas',
          detail: {
            'nota_sync_id': notaSync,
            'nilai_baru': nilaiBaru,
            'modal': modalTotal,
            'error': '',
          },
          status: 'review',
        );
      }
    } else if (entity == 'day_digest') {
      final tanggal = payload['tanggal'] as String? ?? '';
      final dataType = payload['data_type'] as String? ?? 'nota';
      final source = payload['source_device_id'] as String? ?? '';
      if (tanggal.isEmpty || source.isEmpty) return;
      final syncId = payload['sync_id'] as String? ?? newSyncId();
      // Ringkasan koreksi dari perangkat yang sama harus menimpa ringkasan
      // lama, bukan diabaikan.
      await txn.insert(
        'day_digests',
        {
          'sync_id': syncId,
          'store_id': storeId,
          'device_id': payload['device_id'] ?? source,
          'source_device_id': source,
          'tanggal': tanggal,
          'data_type': dataType,
          'jumlah': payload['jumlah'] ?? 0,
          'hash': payload['hash'] ?? '',
          ...hlc,
          'created_at': payload['created_at'] ?? nowIso(),
          'updated_at': nowIso(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final local = await _localDayDigest(txn, tanggal, dataType);
      final remoteHash = '${payload['hash'] ?? ''}';
      if (local != null && remoteHash.isNotEmpty && local != remoteHash) {
        final localDevice = await _localRelayDeviceId(txn);
        final isOwner =
            await SecureStore.instance.read('owner.signing.private') != null;
        final requestSync = newSyncId();
        await txn.insert(
          'reconciliation_requests',
          {
            'sync_id': requestSync,
            'target_device_id': source,
            'tanggal': tanggal,
            'data_type': dataType,
            'alasan': 'Ringkasan harian berbeda',
            'expires_at': DateTime.now()
                .add(const Duration(days: 3))
                .toIso8601String(),
            'status': isOwner ? 'sent' : 'open',
            'created_at': nowIso(),
            'updated_at': nowIso(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (isOwner && localDevice.isNotEmpty) {
          await enqueueDataRequest(
            tanggal: tanggal,
            dataType: dataType,
            alasan: 'Ringkasan harian berbeda',
            targetDeviceId: source,
            txn: txn,
          );
        }
        await _recordConflict(
          txn,
          entity: 'day_digest',
          entityId: syncId,
          reason: 'rekonsiliasi_beda',
          detail: {
            'tanggal': tanggal,
            'data_type': dataType,
            'lokal': local,
            'remote': remoteHash,
            'source_device_id': source,
            'error': '',
          },
          status: 'review',
        );
      }
    } else if (entity == 'data_request') {
      final target = payload['target_device_id'] as String? ?? '';
      final localDevice = await _localRelayDeviceId(txn);
      if (target.isEmpty || target != localDevice) return;
      final expires = DateTime.tryParse('${payload['expires_at'] ?? ''}');
      if (expires != null && expires.isBefore(DateTime.now())) return;
      final receipts = await _buildReconciliationResponse(
        txn,
        tanggal: payload['tanggal'] as String? ?? '',
        dataType: payload['data_type'] as String? ?? 'nota',
        requestSyncId: payload['sync_id'] as String? ?? '',
      );
      await enqueueDataResponse(
        requestSyncId: payload['sync_id'] as String? ?? '',
        envelopes: receipts,
        txn: txn,
      );
    } else if (entity == 'data_response') {
      for (final raw in (payload['envelopes'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry('$key', value));
        final nestedEntity = '${item['entity'] ?? ''}';
        if (nestedEntity.isEmpty) continue;
        await _apply(
          txn,
          {
            'entity': nestedEntity,
            'action': '${item['action'] ?? 'upsert'}',
            'payload': item['payload'] ?? const {},
            'hlc_wall': item['hlc_wall'] ?? 0,
            'hlc_counter': item['hlc_counter'] ?? 0,
          },
          '$envelopeId#response',
          storeId: storeId,
          senderProfile: senderProfile,
        );
      }
    } else {
      await _recordConflict(
        txn,
        entity: entity,
        entityId: '${data['entity_id'] ?? ''}',
        reason: 'entity_belum_didukung',
        detail: {'envelope_id': envelopeId, 'data': data, 'error': ''},
      );
    }
  }

  Future<void> _insertEstimateItems(
    DatabaseExecutor txn, {
    required String syncId,
    required List<Map<String, Object?>> items,
    Object? createdAt,
  }) async {
    for (final item in items) {
      final itemSync = item['sync_id'] as String? ?? '';
      if (itemSync.isEmpty) continue;
      await txn.insert(
        'estimate_items',
        {
          'sync_id': itemSync,
          'estimate_sync_id': syncId,
          'jenis': item['jenis'] ?? 'jasa',
          'stock_sync_id': item['stock_sync_id'],
          'deskripsi': item['deskripsi'] ?? '',
          'jumlah': item['jumlah'] ?? 0,
          'jumlah_milli': item['jumlah_milli'] ??
              ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000,
          'harga_jual_terdaftar': item['harga_jual_terdaftar'] ?? 0,
          'harga_batas_saat_transaksi':
              item['harga_batas_saat_transaksi'] ?? 0,
          'harga_final': item['harga_final'] ?? 0,
          'harga_modal': item['harga_modal'] ?? 0,
          'diskon_alokasi': item['diskon_alokasi'] ?? 0,
          'interval_servis_bulan': item['interval_servis_bulan'] ?? 0,
          'subtotal': item['subtotal'] ?? 0,
          'created_at': createdAt ?? nowIso(),
          'updated_at': nowIso(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _refreshWorkOrderStatus(
    DatabaseExecutor txn,
    String orderSync,
  ) async {
    final rows = await txn.query(
      'work_order_status_log',
      columns: ['status'],
      where: 'work_order_sync_id = ?',
      whereArgs: [orderSync],
      orderBy: 'sync_hlc_wall DESC, sync_hlc_counter DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    await txn.update(
      'work_orders',
      {'status': rows.first['status']},
      where: 'sync_id = ?',
      whereArgs: [orderSync],
    );
  }

  Future<String> _localRelayDeviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync.relay_device_id'],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['value'] as String? ?? '';
  }

  Future<String?> _localDayDigest(
    DatabaseExecutor txn,
    String tanggal,
    String dataType,
  ) async {
    final rows = await txn.query(
      'day_digests',
      columns: ['hash'],
      where:
          'tanggal = ? AND data_type = ? AND source_device_id = ?',
      whereArgs: [tanggal, dataType, await _localRelayDeviceId(txn)],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['hash'] as String?;
    return null;
  }

  Future<List<Map<String, Object?>>> _buildReconciliationResponse(
    DatabaseExecutor txn, {
    required String tanggal,
    required String dataType,
    required String requestSyncId,
  }) async {
    if (tanggal.isEmpty) return const [];
    final start = DateTime.parse('${tanggal}T00:00:00').toUtc();
    final end = start.add(const Duration(days: 1));
    final rows = await txn.query(
      'service_records',
      columns: ['id', 'sync_id', 'waktu_service'],
      where: 'waktu_service >= ? AND waktu_service < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'id',
      limit: 300,
    );
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      final payload = await AppDatabase.instance.noteSyncPayload(
        row['id'] as int,
        executor: txn,
      );
      final record = payload['record'] as Map<String, Object?>? ?? const {};
      result.add({
        'entity': 'nota',
        'action': 'upsert',
        'hlc_wall': (record['sync_hlc_wall'] as num?)?.toInt() ?? 0,
        'hlc_counter': (record['sync_hlc_counter'] as num?)?.toInt() ?? 0,
        'payload': payload,
      });
    }
    if (dataType != 'semua') return result;
    final estimates = await txn.query(
      'estimates',
      where: 'substr(created_at, 1, 10) = ?',
      whereArgs: [tanggal],
      limit: 100,
    );
    for (final row in estimates) {
      final items = await txn.query(
        'estimate_items',
        where: 'estimate_sync_id = ?',
        whereArgs: [row['sync_id']],
      );
      result.add({
        'entity': 'estimate',
        'action': 'upsert',
        'hlc_wall': (row['sync_hlc_wall'] as num?)?.toInt() ?? 0,
        'hlc_counter': (row['sync_hlc_counter'] as num?)?.toInt() ?? 0,
        'payload': {
          'sync_id': row['sync_id'],
          'nomor_estimasi': row['nomor_estimasi'],
          'versi': row['versi'],
          'total': row['total'],
          'status': row['status'],
          'created_at': row['created_at'],
          'items': items
              .map(
                (item) => {
                  'sync_id': item['sync_id'],
                  'jenis': item['jenis'],
                  'deskripsi': item['deskripsi'],
                  'jumlah': item['jumlah'],
                  'jumlah_milli': item['jumlah_milli'] ??
                      ((item['jumlah'] as num?)?.toInt() ?? 0) * 1000,
                  'harga_jual_terdaftar': item['harga_jual_terdaftar'],
                  'harga_batas_saat_transaksi':
                      item['harga_batas_saat_transaksi'],
                  'harga_final': item['harga_final'],
                  'harga_modal': item['harga_modal'],
                  'diskon_alokasi': item['diskon_alokasi'],
                  'subtotal': item['subtotal'],
                },
              )
              .toList(),
        },
      });
    }
    return result;
  }

  Future<void> cleanupSyncHistory() async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 90))
        .toIso8601String();
    await AppDatabase.instance.db.transaction((txn) async {
      // Nomor seq harus tetap monoton walau baris lama dihapus.
      final deviceRows = await txn.query(
        'app_settings',
        columns: ['key', 'value'],
        where: "key IN ('sync.relay_device_id', 'device.current_id')",
      );
      final deviceSettings = {
        for (final row in deviceRows) '${row['key']}': '${row['value']}',
      };
      final deviceId = deviceSettings['sync.relay_device_id'] ??
          deviceSettings['device.current_id'];
      if (deviceId != null && deviceId.isNotEmpty) {
        final maxRows = await txn.rawQuery(
          'SELECT COALESCE(MAX(seq), 0) AS seq FROM sync_outbox '
          'WHERE device_id = ?',
          [deviceId],
        );
        final maxSeq = (maxRows.first['seq'] as num?)?.toInt() ?? 0;
        final floorRows = await txn.query(
          'app_settings',
          columns: ['value'],
          where: 'key = ?',
          whereArgs: ['device.seq_floor'],
          limit: 1,
        );
        final floor = floorRows.isEmpty
            ? 0
            : int.tryParse(floorRows.first['value'] as String? ?? '') ?? 0;
        if (maxSeq > floor) {
          await txn.insert(
            'app_settings',
            {'key': 'device.seq_floor', 'value': '$maxSeq'},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await txn.delete(
        'sync_outbox',
        where: "status = 'sent' AND sent_at IS NOT NULL AND sent_at < ?",
        whereArgs: [cutoff],
      );
      await txn.delete(
        'applied_deltas',
        where: 'applied_at < ?',
        whereArgs: [cutoff],
      );
      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS total FROM applied_deltas',
      );
      final total = countRows.first['total'] as int? ?? 0;
      if (total > 20000) {
        final excess = total - 20000;
        await txn.rawDelete(
          'DELETE FROM applied_deltas WHERE idempotency_key IN '
          '(SELECT idempotency_key FROM applied_deltas '
          'ORDER BY applied_at ASC LIMIT ?)',
          [excess],
        );
      }
    });
  }

  Future<int> _cursor(String store, String device) async {
    final rows = await AppDatabase.instance.db.query(
      'sync_cursor',
      where: 'store_id = ? AND device_id = ?',
      whereArgs: [store, device],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.first['last_seq'] as int? ?? 0;
  }

  Future<void> _setCursor(String store, String device, int seq) async {
    await AppDatabase.instance.db.insert(
      'sync_cursor',
      {
        'store_id': store,
        'device_id': device,
        'last_seq': seq,
        'updated_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// Sinyal internal agar transaksi penerapan amplop dibatalkan seluruhnya.
class _ApplyRejected implements Exception {
  const _ApplyRejected(this.reason);

  final String reason;
}

List<String> _jsonList(Object? raw) {
  if (raw is List) return raw.map((item) => '$item').toList();
  try {
    final decoded = jsonDecode('${raw ?? '[]'}');
    if (decoded is List) return decoded.map((item) => '$item').toList();
  } catch (_) {}
  return const [];
}

Map<String, Object?> _jsonObject(Object? raw) {
  if (raw is Map) {
    return {for (final entry in raw.entries) '${entry.key}': entry.value};
  }
  try {
    final decoded = jsonDecode('${raw ?? '{}'}');
    if (decoded is Map) {
      return {for (final entry in decoded.entries) '${entry.key}': entry.value};
    }
  } catch (_) {}
  return {};
}
