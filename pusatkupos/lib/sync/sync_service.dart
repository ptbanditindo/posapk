import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../data/account_service.dart';
import '../data/app_database.dart';
import '../data/device_service.dart';
import '../data/license_service.dart';
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

  Future<void> configure({
    required String relayUrl,
    required String enrollToken,
    required String storeId,
  }) async {
    await AppDatabase.instance.setSetting(
      'sync.relay_url',
      relayUrl.trim(),
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
    final boot = await RelayClient(baseUrl: url, deviceToken: token)
        .bootstrap(await storeId());
    final wrapped = boot['wrapped_key'] as String? ?? '';
    if (wrapped.isEmpty) return (await existingStoreKey()) != null;
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
    }
    return {
      'applied': result['applied'] == true,
      'snapshot': true,
      'cursor': seq,
      'snapshot_required': false,
    };
  }

  Future<Map<String, Object?>> uploadSnapshot() async {
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
    final clientWithToken = RelayClient(baseUrl: url, deviceToken: token);
    final boot = await clientWithToken.bootstrap(await storeId());
    final wrappedExisting = boot['wrapped_key'] as String? ?? '';
    var keyPending = false;
    if (wrappedExisting.isNotEmpty) {
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
  }) async {
    final deviceId = await relayDeviceId() ??
        await AppDatabase.instance.getSetting('device.current_id') ??
        'local';
    final last = await AppDatabase.instance.db.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS seq, '
      'COALESCE(MAX(hlc_wall), 0) AS wall, '
      'COALESCE(MAX(hlc_counter), 0) AS counter '
      'FROM sync_outbox WHERE device_id = ?',
      [deviceId],
    );
    final seq = ((last.first['seq'] as int?) ?? 0) + 1;
    final hlc = nextHlc(
      Hlc(
        (last.first['wall'] as int?) ?? 0,
        (last.first['counter'] as int?) ?? 0,
      ),
    );
    await AppDatabase.instance.db.insert('sync_outbox', {
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

  Future<void> enqueueCustomer(int id) async {
    final rows = await AppDatabase.instance.db.query(
      'customers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      entity: 'customer',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'nama': row['nama'],
        'nomor_hp': row['nomor_hp'],
        'alamat': row['alamat'],
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueueUnit(int id) async {
    final rows = await AppDatabase.instance.db.query(
      'vehicle_or_units',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final customer = await AppDatabase.instance.db.query(
      'customers',
      columns: ['sync_id'],
      where: 'id = ?',
      whereArgs: [row['customer_id']],
      limit: 1,
    );
    await enqueue(
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
        'created_at': row['created_at'],
      },
    );
  }

  Future<void> enqueueStock(int id) async {
    final rows = await AppDatabase.instance.db.query(
      'stock_items',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      entity: 'stock',
      action: 'upsert',
      entityId: row['sync_id'] as String,
      payload: {
        'sync_id': row['sync_id'],
        'kode': row['kode'],
        'nama': row['nama'],
        'harga_modal': row['harga_modal'],
        'harga_jual': row['harga_jual'],
        'jumlah': row['jumlah'],
        'stok_minimum': row['stok_minimum'],
      },
    );
  }

  Future<void> enqueueStockDelta(int stockItemId, int qty) async {
    final rows = await AppDatabase.instance.db.query(
      'stock_items',
      where: 'id = ?',
      whereArgs: [stockItemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    await enqueue(
      entity: 'stock',
      action: 'delta',
      entityId: row['sync_id'] as String,
      payload: {'sync_id': row['sync_id'], 'qty': qty},
    );
  }

  Future<void> enqueueNote(int id) async {
    final payload = await AppDatabase.instance.noteSyncPayload(id);
    final record = payload['record'] as Map<String, Object?>? ?? const {};
    final syncId = record['sync_id'] as String? ?? '';
    if (syncId.isEmpty) return;
    await enqueue(
      entity: 'nota',
      action: 'upsert',
      entityId: syncId,
      payload: payload,
    );
  }

  Future<void> enqueueNoteVoid(int id) async {
    final payload = await AppDatabase.instance.noteSyncPayload(id);
    final record = payload['record'] as Map<String, Object?>? ?? const {};
    final syncId = record['sync_id'] as String? ?? '';
    if (syncId.isEmpty) return;
    await enqueue(
      entity: 'nota',
      action: 'void',
      entityId: syncId,
      payload: payload,
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

  Future<Map<String, Object?>> syncNow() async {
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
    final keys = {
      for (final device in devices)
        if (device['id'] != null) device['id']: device['public_key'],
    };
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
          senderPublicKey: senderKey as String,
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
    for (final raw in (feed['envelopes'] as List? ?? const [])) {
      final envelope = (raw as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      if (envelope['sender_device_id'] == deviceId) continue;
      final key = keys[envelope['sender_device_id']];
      if (key == null) continue;
      final data = await verifyEnvelope(
        envelope: envelope,
        senderPublicKey: key as String,
        storeKey: storeKey,
      );
      final idem = envelope['idempotency_key'] as String? ?? '';
      final existing = await AppDatabase.instance.db.query(
        'applied_deltas',
        where: 'idempotency_key = ?',
        whereArgs: [idem],
        limit: 1,
      );
      if (existing.isEmpty) {
        await _apply(data, envelope['id'] as String? ?? '');
        applied++;
      }
    }
    final next = feed['next_seq'] as int? ?? cursor;
    if (next > 0) {
      await client.ack(storeId: store, lastSeq: next);
      await _setCursor(store, deviceId, next);
    }
    return {
      'sent': sent,
      'applied': applied,
      'cursor': next,
      'snapshot_required': feed['snapshot_required'] == true,
    };
  }

  Future<void> _apply(Map<String, Object?> data, String envelopeId) async {
    final entity = data['entity'] as String? ?? '';
    final action = data['action'] as String? ?? '';
    final payload = data['payload'] as Map<String, Object?>? ?? const {};
    final idem = data['idempotency_key'] as String? ?? '';
    final db = AppDatabase.instance.db;
    if (entity == 'customer') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final rows = await db.query('customers',
          columns: ['id'], where: 'sync_id = ?', whereArgs: [syncId], limit: 1);
      if (rows.isEmpty) {
        await db.insert('customers', {
          'sync_id': syncId,
          'nama': payload['nama'] ?? '',
          'nomor_hp': payload['nomor_hp'] ?? '',
          'alamat': payload['alamat'],
          'created_at': payload['created_at'] ?? nowIso(),
        });
      } else {
        await db.update(
          'customers',
          {
            'nama': payload['nama'],
            'nomor_hp': payload['nomor_hp'],
            'alamat': payload['alamat'],
          },
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'unit') {
      final syncId = payload['sync_id'] as String? ?? '';
      final customerSync = payload['customer_sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final customer = await db.query('customers',
          columns: ['id'],
          where: 'sync_id = ?',
          whereArgs: [customerSync],
          limit: 1);
      if (customer.isEmpty) return;
      final rows = await db.query('vehicle_or_units',
          columns: ['id'], where: 'sync_id = ?', whereArgs: [syncId], limit: 1);
      if (rows.isEmpty) {
        await db.insert('vehicle_or_units', {
          'sync_id': syncId,
          'customer_id': customer.first['id'],
          'unit_type': payload['unit_type'] ?? 'MOBIL',
          'nopol': payload['nopol'],
          'jenis_mobil': payload['jenis_mobil'],
          'tahun_mobil': payload['tahun_mobil'],
          'tipe_radiator': payload['tipe_radiator'],
          'created_at': payload['created_at'] ?? nowIso(),
        });
      }
    } else if (entity == 'stock') {
      final syncId = payload['sync_id'] as String? ?? '';
      if (syncId.isEmpty) return;
      final rows = await db.query('stock_items',
          columns: ['id', 'jumlah'],
          where: 'sync_id = ?',
          whereArgs: [syncId],
          limit: 1);
      if (rows.isEmpty) {
        if ((payload['kode'] as String? ?? '').isEmpty) return;
        await db.insert('stock_items', {
          'sync_id': syncId,
          'kode': payload['kode'],
          'nama': payload['nama'] ?? '',
          'harga_modal': payload['harga_modal'] ?? 0,
          'harga_jual': payload['harga_jual'] ?? 0,
          'jumlah': payload['jumlah'] ?? 0,
          'stok_minimum': payload['stok_minimum'] ?? 0,
          'created_at': nowIso(),
        });
      } else if (action == 'delta') {
        await db.rawUpdate(
          'UPDATE stock_items SET jumlah = jumlah + ? WHERE sync_id = ?',
          [payload['qty'] ?? 0, syncId],
        );
      } else {
        await db.update(
          'stock_items',
          {
            'nama': payload['nama'],
            'harga_modal': payload['harga_modal'],
            'harga_jual': payload['harga_jual'],
            'jumlah': payload['jumlah'],
            'stok_minimum': payload['stok_minimum'],
          },
          where: 'sync_id = ?',
          whereArgs: [syncId],
        );
      }
    } else if (entity == 'nota') {
      await AppDatabase.instance.applyNotePayload(
        db,
        payload,
        action: action,
      );
    } else {
      await db.insert('sync_conflicts', {
        'entity': entity,
        'entity_id': data['entity_id'] ?? '',
        'reason': 'entity_belum_didukung',
        'detail_json': jsonEncode(data),
        'created_at': nowIso(),
      });
    }
    await db.insert(
      'applied_deltas',
      {
        'idempotency_key': idem,
        'envelope_id': envelopeId,
        'entity': entity,
        'entity_id': data['entity_id'] ?? '',
        'applied_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
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
