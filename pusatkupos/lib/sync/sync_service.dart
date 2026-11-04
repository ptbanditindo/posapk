import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/relay_url.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/device_service.dart';
import '../data/license_service.dart';
import '../data/models.dart';
import '../data/note_sync.dart';
import '../data/secure_store.dart';
import 'crypto.dart';
import 'protocol.dart';
import 'relay_client.dart';
import 'snapshot_sync.dart';

class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  Future<String?> _setting(String key) => AppDatabase.instance.getSetting(key);

  Future<void> _requirePremium() async {
    if (!await LicenseService.instance.isPremium()) {
      throw StateError(
        'Lisensi server yang valid diperlukan untuk sinkronisasi dan '
        'multi-perangkat. Kasir offline tetap dapat dipakai.',
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
    await AppDatabase.instance.setSetting(
      'sync.enroll_token',
      enrollToken.trim(),
    );
    await AppDatabase.instance.setSetting(
      'sync.store_id',
      storeId.trim().isEmpty ? 'utama' : storeId.trim(),
    );
  }

  Future<String?> relayUrl() => _setting('sync.relay_url');

  Future<String?> enrollToken() => _setting('sync.enroll_token');

  Future<String> storeId() async =>
      (await _setting('sync.store_id')) ?? 'utama';

  Future<String?> relayDeviceId() => _setting('sync.relay_device_id');

  Future<String?> relayDeviceToken() async {
    final stored = await SecureStore.instance.read('sync.relay_device_token');
    return stored ?? _setting('sync.relay_device_token');
  }

  Future<List<int>?> existingStoreKey() async {
    final stored = await SecureStore.instance.read('sync.store_key');
    if (stored == null || stored.isEmpty) return null;
    return b64d(stored);
  }

  Future<List<int>> ensureStoreKey() async {
    final stored = await existingStoreKey();
    if (stored != null) return stored;
    final secureRandom = Random.secure();
    final random = List<int>.generate(32, (_) => secureRandom.nextInt(256));
    await SecureStore.instance.write('sync.store_key', b64e(random));
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
    await SecureStore.instance.write('sync.store_key', b64e(storeKey));
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
    final rawSnapshot = boot['snapshot'];
    if (rawSnapshot is! Map) {
      return {
        'applied': false,
        'snapshot': false,
        'cursor': (boot['cursor'] as num?)?.toInt() ?? 0,
        'snapshot_required': boot['snapshot_required'] == true,
      };
    }
    final snapshot = Map<String, Object?>.from(rawSnapshot);
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
    final seq = (result['store_seq'] as num?)?.toInt() ?? 0;
    if (result['applied'] == true) {
      await client.ack(storeId: store, lastSeq: seq);
      await _setCursor(store, relayId, seq);
      await AppDatabase.instance.deleteSetting(
        'sync.restore_requires_bootstrap',
      );
    }
    return {
      'applied': result['applied'] == true,
      'snapshot': true,
      'cursor': seq,
      'snapshot_required': false,
    };
  }

  Future<Map<String, Object?>> uploadSnapshot() async {
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
    if (await pendingCount() > 0) {
      throw StateError('Kirim perubahan lokal sebelum membuat snapshot.');
    }
    final client = RelayClient(baseUrl: url, deviceToken: token);
    final boot = await client.bootstrap(store);
    final latest = (boot['latest_seq'] as num?)?.toInt() ?? 0;
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
    );
    final relayDevice = response['device'] as Map<String, Object?>? ?? const {};
    final relayId = relayDevice['id'] as String? ?? '';
    final token = response['token'] as String? ?? '';
    if (relayId.isEmpty || token.isEmpty) {
      throw StateError('Relay tidak mengembalikan perangkat/token.');
    }
    await AppDatabase.instance.setSetting('sync.relay_device_id', relayId);
    await AppDatabase.instance.setSetting('sync.local_device_id', device['id'] as String);
    await SecureStore.instance.write('sync.relay_device_token', token);
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
      await SecureStore.instance.write('sync.store_key', b64e(storeKey));
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

  Future<Map<String, Object?>> status() async {
    final cursorRows = await AppDatabase.instance.db.query(
      'sync_cursor',
      where: 'store_id = ? AND device_id = ?',
      whereArgs: [await storeId(), await relayDeviceId() ?? ''],
      limit: 1,
    );
    return {
      'relay_url': await relayUrl() ?? '',
      'store_id': await storeId(),
      'relay_device_id': await relayDeviceId() ?? '',
      'pending': await pendingCount(),
      'cursor': cursorRows.isEmpty ? 0 : cursorRows.first['last_seq'] ?? 0,
    };
  }

  Future<void> enqueue({
    required String entity,
    required String action,
    required String entityId,
    required Map<String, Object?> payload,
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final deviceId = await relayDeviceId() ??
        await AppDatabase.instance.getSetting('device.current_id') ??
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
    final hlc = nextHlc(
      Hlc(
        (last.first['wall'] as int?) ?? 0,
        (last.first['counter'] as int?) ?? 0,
      ),
    );
    await executor.insert('sync_outbox', {
      'device_id': deviceId,
      'seq': seq,
      'hlc_wall': hlc.wall,
      'hlc_counter': hlc.counter,
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
      action: 'upsert',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'nama': row['nama'],
        'nomor_hp': row['nomor_hp'],
        'alamat': row['alamat'],
        'wa_consent': row['wa_consent'] ?? 1,
        'do_not_contact': row['do_not_contact'] ?? 0,
        'created_at': row['created_at'],
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
      action: 'upsert',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'customer_sync_id':
            customer.isEmpty ? '' : customer.first['sync_id'],
        'unit_type': row['unit_type'],
        'nopol': row['nopol'],
        'jenis_mobil': row['jenis_mobil'],
        'tahun_mobil': row['tahun_mobil'],
        'tipe_radiator': row['tipe_radiator'],
        'label_radiator': row['label_radiator'],
        'created_at': row['created_at'],
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
      action: 'upsert',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'kode': row['kode'],
        'nama': row['nama'],
        'harga_modal': row['harga_modal'],
        'harga_jual': row['harga_jual'],
        'stok_minimum': row['stok_minimum'],
        'satuan': row['satuan'] ?? 'pcs',
        'desimal': row['desimal'] ?? 0,
      },
    );
  }

  Future<void> enqueueStockDelta(
    int stockItemId,
    int qty, {
    int? qtyMilli,
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppDatabase.instance.db;
    final rows = await executor.query(
      'stock_items',
      where: 'id = ?',
      whereArgs: [stockItemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      txn: txn,
      entity: 'stock',
      action: 'delta',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'qty_milli': qtyMilli ?? qty * 1000,
      },
    );
  }

  Future<void> enqueueNote(int id, {DatabaseExecutor? txn}) async {
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
      action: 'upsert',
      entityId: syncId,
      payload: payload,
    );
  }

  Future<void> enqueueNoteVoid(int id, {DatabaseExecutor? txn}) async {
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
      action: 'void',
      entityId: syncId,
      payload: payload,
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
    if (signer.isEmpty || signer != pinned) {
      throw StateError(
        'Penandatangan izin bukan kunci owner yang dipin. '
        'Izin karyawan ditolak.',
      );
    }
    final valid = await verifyPayload(
      pinned,
      utf8.encode(canonicalJson(payload)),
      signature,
    );
    if (!valid) {
      throw StateError('Tanda tangan izin karyawan tidak valid.');
    }
    await AccountService.instance.applyRemotePermissions(account);
  }

  Future<Map<String, Object?>> syncNow() async {
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
    final pending = await AppDatabase.instance.db.query(
      'sync_outbox',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'seq',
    );
    for (final item in pending) {
      final payload = jsonDecode(item['payload_json'] as String)
          as Map<String, Object?>;
      final envelope = await buildEnvelope(
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
      );
      await client.submitEnvelope(envelope);
      await AppDatabase.instance.db.update(
        'sync_outbox',
        {'status': 'sent', 'sent_at': nowIso()},
        where: 'id = ?',
        whereArgs: [item['id']],
      );
      sent++;
    }
    final devices = await client.devices();
    var keys = _senderKeys(devices);
    final cursor = await _cursor(store, deviceId);
    final feed = await client.feed(storeId: store, sinceSeq: cursor);
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
        final seq = (result['store_seq'] as num?)?.toInt() ?? 0;
        if (result['applied'] == true) {
          await client.ack(storeId: store, lastSeq: seq);
          await _setCursor(store, deviceId, seq);
        }
        return {
          'sent': sent,
          'applied': 0,
          'cursor': seq,
          'snapshot_required': false,
          'snapshot_applied': result['applied'] == true,
        };
      }
      return {
        'sent': sent,
        'applied': 0,
        'cursor': cursor,
        'snapshot_required': true,
      };
    }
    var applied = 0;
    var conflictCount = 0;
    int? haltedSeq;
    String? unknownSender;
    var refreshedDevices = false;
    for (final raw in (feed['envelopes'] as List? ?? const [])) {
      final envelope = (raw as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final sender = envelope['sender_device_id'] as String? ?? '';
      final seq = (envelope['seq'] as num?)?.toInt() ?? 0;
      if (sender == deviceId) continue;
      var key = keys[sender];
      if (key == null && !refreshedDevices) {
        refreshedDevices = true;
        keys = _senderKeys(await client.devices());
        key = keys[sender];
      }
      if (key == null) {
        haltedSeq = seq;
        unknownSender = sender;
        break;
      }
      final idem = envelope['idempotency_key'] as String? ?? '';
      final existing = await AppDatabase.instance.db.query(
        'applied_deltas',
        where: 'idempotency_key = ?',
        whereArgs: [idem],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      try {
        final data = await verifyEnvelope(
          envelope: envelope,
          senderPublicKey: key,
          storeKey: storeKey,
        );
        await AppDatabase.instance.db.transaction((txn) async {
          await _apply(txn, data, envelope['id'] as String? ?? '');
          await txn.insert(
            'applied_deltas',
            {
              'idempotency_key': idem,
              'envelope_id': envelope['id'] as String? ?? '',
              'entity': data['entity'] ?? '',
              'entity_id': data['entity_id'] ?? '',
              'applied_at': nowIso(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        });
        applied++;
      } catch (error) {
        conflictCount++;
        await AppDatabase.instance.db.insert('sync_conflicts', {
          'entity': envelope['entity'] as String? ?? 'unknown',
          'entity_id': envelope['entity_id'] as String? ?? '',
          'reason': _conflictReason(error),
          'detail_json': jsonEncode({
            'seq': seq,
            'envelope_id': envelope['id'],
            'sender_device_id': sender,
            'error': '$error',
          }),
          'created_at': nowIso(),
        });
      }
    }
    if (haltedSeq != null) {
      final haltCursor = haltedSeq > 0 ? haltedSeq - 1 : cursor;
      if (haltCursor > cursor) {
        await client.ack(storeId: store, lastSeq: haltCursor);
        await _setCursor(store, deviceId, haltCursor);
      }
      throw StateError(
        'Amplop dari perangkat "${unknownSender ?? '-'}" tidak dikenal '
        'pada urutan $haltedSeq. Sinkronisasi dihentikan sebelum amplop itu; '
        'periksa daftar perangkat di relay.',
      );
    }
    final next = feed['next_seq'] as int? ?? cursor;
    if (next > 0) {
      await client.ack(storeId: store, lastSeq: next);
      await _setCursor(store, deviceId, next);
    }
    await cleanupSyncHistory();
    return {
      'sent': sent,
      'applied': applied,
      'conflicts': conflictCount,
      'cursor': next,
      'snapshot_required': feed['snapshot_required'] == true,
    };
  }

  Map<String, String?> _senderKeys(List<Map<String, Object?>> devices) {
    return {
      for (final device in devices)
        if (device['id'] != null)
          '${device['id']}': device['public_key'] as String?,
    };
  }

  String _conflictReason(Object error) {
    final text = '$error'.toLowerCase();
    if (text.contains('tanda tangan')) return 'tanda_tangan_tidak_valid';
    if (text.contains('dekripsi')) return 'dekripsi_gagal';
    if (text.contains('unique') || text.contains('constraint')) {
      return 'konflik_unik';
    }
    return 'gagal_terapkan';
  }

  Future<void> cleanupSyncHistory() async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 90))
        .toIso8601String();
    await AppDatabase.instance.db.transaction((txn) async {
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

  Future<void> _apply(
    DatabaseExecutor txn,
    Map<String, Object?> data,
    String envelopeId,
  ) async {
    final entity = data['entity'] as String? ?? '';
    final action = data['action'] as String? ?? '';
    final payload = data['payload'] as Map<String, Object?>? ?? const {};
    if (entity == 'customer') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
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
          'nama': payload['nama'] ?? '',
          'nomor_hp': payload['nomor_hp'] ?? '',
          'alamat': payload['alamat'],
          'wa_consent': payload['wa_consent'] ?? 1,
          'do_not_contact': payload['do_not_contact'] ?? 0,
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await txn.update(
          'customers',
          {
            'nama': payload['nama'],
            'nomor_hp': payload['nomor_hp'],
            'alamat': payload['alamat'],
            'wa_consent': payload['wa_consent'] ?? 1,
            'do_not_contact': payload['do_not_contact'] ?? 0,
          },
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'unit') {
      final syncId = payload['sync_id'] as String? ?? '';
      final customerSync = payload['customer_sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final customer = await txn.query(
        'customers',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [customerSync],
        limit: 1,
      );
      if (customer.isEmpty) return;
      final rows = await txn.query(
        'vehicle_or_units',
        columns: ['id'],
        where: 'sync_id = ?',
        whereArgs: [syncId],
        limit: 1,
      );
      final values = {
        'customer_id': customer.first['id'],
        'unit_type': payload['unit_type'] ?? 'MOBIL',
        'nopol': payload['nopol'],
        'jenis_mobil': payload['jenis_mobil'],
        'tahun_mobil': payload['tahun_mobil'],
        'tipe_radiator': payload['tipe_radiator'],
        'label_radiator': payload['label_radiator'],
      };
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
      if (rows.isEmpty) {
        if (action == 'delta') {
          throw StateError(
            'Delta stok diterima sebelum metadata barang ($syncId).',
          );
        }
        if ((payload['kode'] as String? ?? '').isEmpty) {
          throw StateError('Barang tanpa kode.');
        }
        final milli = (payload['jumlah_milli'] as num?)?.toInt() ??
            ((payload['jumlah'] as num?)?.toInt() ?? 0) * 1000;
        await txn.insert('stock_items', {
          'sync_id': syncId,
          'kode': payload['kode'],
          'nama': payload['nama'] ?? '',
          'harga_modal': payload['harga_modal'] ?? 0,
          'harga_jual': payload['harga_jual'] ?? 0,
          'jumlah': milli ~/ 1000,
          'jumlah_milli': milli,
          'satuan': payload['satuan'] ?? 'pcs',
          'desimal': payload['desimal'] ?? 0,
          'stok_minimum': payload['stok_minimum'] ?? 0,
          'created_at': nowIso(),
        });
      } else if (action == 'delta') {
        final delta = (payload['qty_milli'] as num?)?.toInt() ??
            ((payload['qty'] as num?)?.toInt() ?? 0) * 1000;
        final before = StockItem.fromRow(rows.first);
        final next = before.jumlahMilli + delta;
        await txn.update(
          'stock_items',
          {'jumlah': next ~/ 1000, 'jumlah_milli': next},
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      } else {
        await txn.update(
          'stock_items',
          {
            'kode': payload['kode'],
            'nama': payload['nama'],
            'harga_modal': payload['harga_modal'],
            'harga_jual': payload['harga_jual'],
            'stok_minimum': payload['stok_minimum'],
            'satuan': payload['satuan'] ?? 'pcs',
            'desimal': payload['desimal'] ?? 0,
          },
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'nota') {
      await AppDatabase.instance.applyNotePayloadTx(
        txn,
        payload,
        action: action,
      );
    } else {
      await txn.insert('sync_conflicts', {
        'entity': entity,
        'entity_id': data['entity_id'] ?? '',
        'reason': 'entity_belum_didukung',
        'detail_json': jsonEncode(data),
        'created_at': nowIso(),
      });
    }
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
