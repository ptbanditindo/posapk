import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/app_config.dart';
import '../core/dates.dart';
import '../data/app_database.dart';
import '../data/license_service.dart';
import '../data/license_verifier.dart';
import '../data/receipt_service.dart';
import 'archive_client.dart';
import 'crypto.dart';
import 'relay_client.dart';
import 'sync_service.dart';

/// Arsip nota: bundel kanonik per nota dienkripsi store key lalu diunggah
/// setelah commit. Server hanya menyimpan ciphertext, hash, metadata minimal,
/// dan token indeks HMAC. Tidak ada endpoint hapus arsip.
class ArchiveService {
  ArchiveService._();

  static final ArchiveService instance = ArchiveService._();

  static const String docTypeNota = 'nota';
  static const String _scanCursorKey = 'archive.scan_cursor';

  bool _running = false;

  Future<String?> _baseUrl() async {
    final archive = archiveBaseUrl.trim();
    if (archive.isNotEmpty) return archive;
    return SyncService.instance.relayUrl();
  }

  /// Memproses antrean arsip dengan prioritas rendah: memindai nota yang
  /// berubah, membuat bundel yang belum ada, lalu mengunggah yang tertunda.
  /// Kegagalan arsip tidak pernah menggagalkan penjualan atau sinkronisasi.
  Future<void> processPending({
    int scanLimit = 10,
    int backlogLimit = 10,
    int uploadLimit = 10,
  }) async {
    if (_running) return;
    _running = true;
    try {
      if (!await LicenseService.instance.isPremium()) return;
      final baseUrl = await _baseUrl();
      if (baseUrl == null || baseUrl.isEmpty) return;
      final token = await SyncService.instance.relayDeviceToken();
      if (token == null || token.isEmpty) return;
      final storeKey = await SyncService.instance.existingStoreKey();
      if (storeKey == null) return;
      final storeId = await SyncService.instance.storeId();
      final searchKey = await deriveSearchKey(storeKey);
      await _scanChangedNotes(
        storeId: storeId,
        storeKey: storeKey,
        searchKey: searchKey,
        limit: scanLimit,
      );
      await _queueMissingNotes(
        storeId: storeId,
        storeKey: storeKey,
        searchKey: searchKey,
        limit: backlogLimit,
      );
      await _uploadPending(
        baseUrl: baseUrl,
        token: token,
        storeId: storeId,
        limit: uploadLimit,
      );
    } catch (_) {
      // Arsip adalah layanan tambahan; status kegagalan disimpan per dokumen.
    } finally {
      _running = false;
    }
  }

  /// Ringkasan antrean arsip untuk permukaan kesehatan. Hanya membaca
  /// metadata lokal; tidak menghubungi relay.
  Future<Map<String, Object?>> status() async {
    final storeId = await SyncService.instance.storeId();
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
SELECT COUNT(*) AS total,
       SUM(CASE WHEN archived_at IS NOT NULL THEN 1 ELSE 0 END) AS archived,
       SUM(CASE WHEN archived_at IS NULL THEN 1 ELSE 0 END) AS pending,
       SUM(CASE WHEN archived_at IS NULL AND upload_error <> ''
                THEN 1 ELSE 0 END) AS failed,
       MAX(archived_at) AS last_at,
       MAX(upload_error) AS last_error
FROM archive_documents
WHERE store_id = ?
''',
      [storeId],
    );
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    int count(String key) => (row[key] as num?)?.toInt() ?? 0;
    return {
      'total': count('total'),
      'archived': count('archived'),
      'pending': count('pending'),
      'failed': count('failed'),
      'last_at': '${row['last_at'] ?? ''}',
      'last_error': '${row['last_error'] ?? ''}',
    };
  }

  /// Membuat bundel arsip untuk satu nota. Dipanggil langsung setelah commit
  /// bila pemanggil ingin arsip tidak menunggu putaran scheduler.
  Future<void> enqueueNota(int recordId) async {
    final rows = await AppDatabase.instance.db.query(
      'service_records',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [recordId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final storeKey = await SyncService.instance.existingStoreKey();
    if (storeKey == null) return;
    final storeId = await SyncService.instance.storeId();
    await _archiveRow(
      record: rows.first,
      storeId: storeId,
      storeKey: storeKey,
      searchKey: await deriveSearchKey(storeKey),
      onlyIfChanged: false,
    );
  }

  Future<void> _scanChangedNotes({
    required String storeId,
    required List<int> storeKey,
    required List<int> searchKey,
    required int limit,
  }) async {
    final cursor =
        await AppDatabase.instance.getSetting(_scanCursorKey) ?? '';
    final rows = await AppDatabase.instance.db.query(
      'service_records',
      where: 'deleted_at IS NULL AND updated_at > ?',
      whereArgs: [cursor],
      orderBy: 'updated_at, id',
      limit: limit,
    );
    for (final row in rows) {
      await _archiveRow(
        record: row,
        storeId: storeId,
        storeKey: storeKey,
        searchKey: searchKey,
        onlyIfChanged: true,
      );
      await AppDatabase.instance.setSetting(
        _scanCursorKey,
        '${row['updated_at'] ?? ''}',
      );
    }
  }

  Future<void> _queueMissingNotes({
    required String storeId,
    required List<int> storeKey,
    required List<int> searchKey,
    required int limit,
  }) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
SELECT r.* FROM service_records r
LEFT JOIN archive_documents a
  ON a.store_id = ? AND a.doc_type = ? AND a.doc_id = r.sync_id
WHERE r.deleted_at IS NULL AND a.doc_id IS NULL
ORDER BY r.waktu_service DESC, r.id DESC LIMIT ?
''',
      [storeId, docTypeNota, limit],
    );
    for (final row in rows) {
      await _archiveRow(
        record: row,
        storeId: storeId,
        storeKey: storeKey,
        searchKey: searchKey,
        onlyIfChanged: false,
      );
    }
  }

  Future<void> _archiveRow({
    required Map<String, Object?> record,
    required String storeId,
    required List<int> storeKey,
    required List<int> searchKey,
    required bool onlyIfChanged,
  }) async {
    final syncId = '${record['sync_id'] ?? ''}';
    if (syncId.isEmpty) return;
    final bundle = await _buildBundle(record, storeId: storeId);
    final canonical = utf8.encode(canonicalJson(bundle));
    final contentHash = sha256Hex(canonical);
    final db = AppDatabase.instance.db;
    final existing = await db.query(
      'archive_documents',
      columns: ['content_hash'],
      where: 'store_id = ? AND doc_type = ? AND doc_id = ? AND content_hash = ?',
      whereArgs: [storeId, docTypeNota, syncId, contentHash],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    if (onlyIfChanged) {
      final latest = await db.query(
        'archive_documents',
        columns: ['content_hash'],
        where: 'store_id = ? AND doc_type = ? AND doc_id = ?',
        whereArgs: [storeId, docTypeNota, syncId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (latest.isNotEmpty &&
          latest.first['content_hash'] == contentHash) {
        return;
      }
    }
    final (ciphertext, nonce) = await encryptPayload(storeKey, canonical);
    final now = nowIso();
    final keyId = keyIdFor(storeKey);
    final keyVersion =
        (await SyncService.instance.storeKeyRing())?.versionForKeyId(keyId) ??
            1;
    final tokens = _indexTokens(bundle, searchKey);
    await db.transaction((txn) async {
      await txn.insert(
        'archive_documents',
        {
          'store_id': storeId,
          'doc_type': docTypeNota,
          'doc_id': syncId,
          'no_nota': '${record['no_nota'] ?? ''}',
          'tanggal': '${record['waktu_service'] ?? ''}',
          'schema_version': AppDatabase.schemaVersion,
          'key_id': keyId,
          'key_version': keyVersion,
          'content_hash': contentHash,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'receipt_json': '',
          'receipt_signature': '',
          'archived_at': null,
          'upload_error': '',
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      for (final token in tokens) {
        await txn.insert(
          'archive_index_tokens',
          {
            'store_id': storeId,
            'doc_type': docTypeNota,
            'doc_id': syncId,
            'content_hash': contentHash,
            'token': token['token'],
            'kind': token['kind'],
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  List<Map<String, String>> _indexTokens(
    Map<String, Object?> bundle,
    List<int> searchKey,
  ) {
    final record = Map<String, Object?>.from(
      bundle['record'] as Map? ?? const {},
    );
    final values = <({String kind, String value})>[
      (kind: 'nota', value: '${record['no_nota'] ?? ''}'),
      (kind: 'nopol', value: '${record['unit_nopol'] ?? ''}'),
    ];
    final nama = '${record['customer_nama'] ?? ''}';
    for (final word in nama.split(RegExp(r'\s+'))) {
      values.add((kind: 'nama', value: word));
    }
    final tokens = <Map<String, String>>[];
    final seen = <String>{};
    for (final entry in values) {
      final token = searchToken(searchKey, entry.kind, entry.value);
      if (token.isEmpty || !seen.add(token)) continue;
      tokens.add({'token': token, 'kind': entry.kind});
    }
    return tokens;
  }

  Future<Map<String, Object?>> _buildBundle(
    Map<String, Object?> record, {
    required String storeId,
  }) async {
    final db = AppDatabase.instance.db;
    final id = (record['id'] as num?)?.toInt() ?? 0;
    final syncId = '${record['sync_id'] ?? ''}';
    final jobs = await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final parts = await db.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final payments = await db.query(
      'service_payments',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final mechanics = await db.query(
      'service_record_mechanics',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'urutan, id',
    );
    final commissions = await db.query(
      'service_record_commissions',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    final adjustments = await db.query(
      'nota_adjustments',
      where: 'nota_sync_id = ? AND deleted_at IS NULL',
      whereArgs: [syncId],
      orderBy: 'id',
    );
    final returRows = await db.query(
      'sale_returns',
      where: 'service_record_id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      orderBy: 'id',
    );
    final returns = <Map<String, Object?>>[];
    for (final retur in returRows) {
      final returnId = (retur['id'] as num?)?.toInt() ?? 0;
      final items = await db.query(
        'sale_return_items',
        where: 'return_id = ? AND deleted_at IS NULL',
        whereArgs: [returnId],
        orderBy: 'id',
      );
      final reversals = await db.query(
        'sale_return_reversals',
        where: 'return_id = ? AND deleted_at IS NULL',
        whereArgs: [returnId],
        orderBy: 'id',
      );
      returns.add({...retur, 'items': items, 'reversals': reversals});
    }
    final customerId = (record['customer_id'] as num?)?.toInt();
    final unitId = (record['unit_id'] as num?)?.toInt();
    Map<String, Object?> customer = {};
    Map<String, Object?> unit = {};
    if (unitId != null) {
      final unitRows = await db.query(
        'vehicle_or_units',
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (unitRows.isNotEmpty) unit = unitRows.first;
    }
    final resolvedCustomer =
        customerId ?? (unit['customer_id'] as num?)?.toInt();
    if (resolvedCustomer != null) {
      final customerRows = await db.query(
        'customers',
        where: 'id = ?',
        whereArgs: [resolvedCustomer],
        limit: 1,
      );
      if (customerRows.isNotEmpty) customer = customerRows.first;
    }
    var strukText = '';
    var strukWidth = 32;
    try {
      final struk = await ReceiptService.instance.build(id);
      strukText = struk.text;
      strukWidth = struk.width;
    } catch (_) {
      // Struk dapat dirender ulang dari data nota bila pengaturan belum ada.
    }
    return {
      'v': 1,
      'doc_type': docTypeNota,
      'doc_id': syncId,
      'store_id': storeId,
      'schema_version': AppDatabase.schemaVersion,
      'app_version': appVersion,
      'generated_at': nowIso(),
      'record': record,
      'customer': customer,
      'unit': unit,
      'jobs': jobs,
      'parts': parts,
      'payments': payments,
      'mechanics': mechanics,
      'commissions': commissions,
      'adjustments': adjustments,
      'returns': returns,
      'pajak': {
        'mode': record['pajak_mode'],
        'persen_bp': record['pajak_persen_bp'],
        'penanggung': record['pajak_penanggung'],
        'dpp': record['pajak_dpp'],
        'pajak': record['pajak'],
        'diserap': record['pajak_diserap'],
        'snapshot_json': record['pajak_snapshot_json'],
      },
      'struk': {'width': strukWidth, 'text': strukText},
    };
  }

  Future<void> _uploadPending({
    required String baseUrl,
    required String token,
    required String storeId,
    required int limit,
  }) async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
      'archive_documents',
      where: 'store_id = ? AND doc_type = ? AND archived_at IS NULL',
      whereArgs: [storeId, docTypeNota],
      orderBy: 'created_at, doc_id',
      limit: limit,
    );
    if (rows.isEmpty) return;
    final client = ArchiveClient(baseUrl: baseUrl, deviceToken: token);
    for (final row in rows) {
      final docId = '${row['doc_id']}';
      final contentHash = '${row['content_hash']}';
      try {
        final tokens = await db.query(
          'archive_index_tokens',
          columns: ['token', 'kind'],
          where: 'store_id = ? AND doc_type = ? AND doc_id = ? '
              'AND content_hash = ?',
          whereArgs: [storeId, docTypeNota, docId, contentHash],
        );
        final response = await client.putDocument({
          'store_id': storeId,
          'doc_type': docTypeNota,
          'doc_id': docId,
          'no_nota': row['no_nota'],
          'tanggal': row['tanggal'],
          'schema_version': row['schema_version'],
          'key_id': row['key_id'],
          'key_version': row['key_version'] ?? 1,
          'content_hash': contentHash,
          'ciphertext': row['ciphertext'],
          'nonce': row['nonce'],
          'indexes': [
            for (final token in tokens)
              {'token': token['token'], 'kind': token['kind']},
          ],
        });
        final receipt = await _verifyReceipt(
          response,
          storeId: storeId,
          docId: docId,
          contentHash: contentHash,
        );
        final payload = receipt['payload'] as Map<String, Object?>;
        final signature = '${receipt['signature']}';
        final archivedAt = '${payload['archived_at'] ?? nowIso()}';
        final objectId = '${payload['object_id'] ?? ''}';
        final now = nowIso();
        await db.transaction((txn) async {
          await txn.update(
            'archive_documents',
            {
              'receipt_json': canonicalJson(payload),
              'receipt_signature': signature,
              'archived_at': archivedAt,
              'upload_error': '',
              'updated_at': now,
            },
            where: 'store_id = ? AND doc_type = ? AND doc_id = ? '
                'AND content_hash = ?',
            whereArgs: [storeId, docTypeNota, docId, contentHash],
          );
          await txn.insert(
            'archive_receipts',
            {
              'store_id': storeId,
              'doc_id': docId,
              'content_hash': contentHash,
              'object_id': objectId,
              'archived_at': archivedAt,
              'signature': signature,
              'synced_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        });
      } on RelayException catch (error) {
        await _markUploadError(
          storeId: storeId,
          docId: docId,
          contentHash: contentHash,
          message: error.message,
        );
      } catch (error) {
        await _markUploadError(
          storeId: storeId,
          docId: docId,
          contentHash: contentHash,
          message: '$error',
        );
      }
    }
  }

  Future<void> _markUploadError({
    required String storeId,
    required String docId,
    required String contentHash,
    required String message,
  }) async {
    await AppDatabase.instance.db.update(
      'archive_documents',
      {'upload_error': message, 'updated_at': nowIso()},
      where: 'store_id = ? AND doc_type = ? AND doc_id = ? AND content_hash = ?',
      whereArgs: [storeId, docTypeNota, docId, contentHash],
    );
  }

  Future<Map<String, Object?>> _verifyReceipt(
    Map<String, Object?> response, {
    required String storeId,
    required String docId,
    required String contentHash,
  }) async {
    final raw = response['receipt'];
    if (raw is! Map) {
      throw StateError('Arsip tidak mengirim receipt bertanda tangan.');
    }
    final payload = raw.map((key, value) => MapEntry('$key', value));
    final signature = '${response['signature'] ?? ''}';
    final publicKey = '${response['public_key'] ?? ''}';
    final trusted = serverLicensePublicKey.trim();
    if (trusted.isEmpty) {
      throw StateError(
        'Kunci lisensi server belum tersedia; receipt arsip tidak dapat '
        'diverifikasi. Bangun ulang dengan PUSATKU_LICENSE_PUBLIC_KEY.',
      );
    }
    if (publicKey != trusted) {
      throw StateError('Receipt arsip ditandatangani kunci tak dikenal.');
    }
    final valid = await verifyPayload(
      trusted,
      utf8.encode(canonicalJson(payload)),
      signature,
    );
    if (!valid) {
      throw StateError('Tanda tangan receipt arsip tidak valid.');
    }
    final matches = '${payload['store_id'] ?? ''}' == storeId &&
        '${payload['doc_id'] ?? ''}' == docId &&
        '${payload['content_hash'] ?? ''}' == contentHash;
    if (!matches) {
      throw StateError('Receipt arsip tidak cocok dengan dokumen lokal.');
    }
    return {'payload': payload, 'signature': signature};
  }

  /// Memverifikasi receipt tersimpan. Purge wajib memanggil ini sebelum
  /// menghapus salinan lokal; tanpa receipt valid dokumen dipertahankan.
  Future<bool> verifyStoredReceipt({
    required String storeId,
    required String docId,
  }) async {
    final rows = await AppDatabase.instance.db.query(
      'archive_documents',
      columns: ['content_hash', 'receipt_json', 'receipt_signature'],
      where: 'store_id = ? AND doc_type = ? AND doc_id = ? '
          "AND receipt_json <> ''",
      whereArgs: [storeId, docTypeNota, docId],
      orderBy: 'archived_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final payloadRaw = '${rows.first['receipt_json'] ?? ''}';
    final signature = '${rows.first['receipt_signature'] ?? ''}';
    if (payloadRaw.isEmpty || signature.isEmpty) return false;
    try {
      final decoded = jsonDecode(payloadRaw);
      if (decoded is! Map) return false;
      final payload = decoded.map((key, value) => MapEntry('$key', value));
      final trusted = serverLicensePublicKey.trim();
      if (trusted.isEmpty) return false;
      final valid = await verifyPayload(
        trusted,
        utf8.encode(canonicalJson(payload)),
        signature,
      );
      return valid &&
          '${payload['store_id'] ?? ''}' == storeId &&
          '${payload['doc_id'] ?? ''}' == docId &&
          '${payload['content_hash'] ?? ''}' == rows.first['content_hash'];
    } catch (_) {
      return false;
    }
  }

  /// Mencari nota di server memakai token HMAC. Kata kunci dicoba sebagai
  /// nomor nota, setiap kata nama pelanggan, dan nopol. Hasil didekripsi
  /// hanya saat dibuka.
  Future<List<Map<String, Object?>>> search({
    required String query,
    String dari = '',
    String sampai = '',
    int limit = 50,
  }) async {
    final baseUrl = await _baseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('Alamat arsip belum dikonfigurasi.');
    }
    final token = await SyncService.instance.relayDeviceToken();
    if (token == null || token.isEmpty) {
      throw StateError('Perangkat belum terhubung ke relay.');
    }
    final storeKey = await SyncService.instance.existingStoreKey();
    if (storeKey == null) {
      throw StateError('Kunci toko belum tersedia di perangkat ini.');
    }
    final storeId = await SyncService.instance.storeId();
    final searchKey = await deriveSearchKey(storeKey);
    final normalized = query.trim();
    final candidates = <String>[];
    void addCandidate(String kind, String value) {
      final valueToken = searchToken(searchKey, kind, value);
      if (valueToken.isEmpty || candidates.contains(valueToken)) return;
      candidates.add(valueToken);
    }

    if (normalized.isNotEmpty) {
      addCandidate('nota', normalized);
      addCandidate('nopol', normalized);
      for (final word in normalized.split(RegExp(r'\s+'))) {
        addCandidate('nama', word);
      }
    }
    if (candidates.isEmpty && dari.isEmpty && sampai.isEmpty) {
      throw StateError('Masukkan nomor nota, nama, nopol, atau rentang tanggal.');
    }
    final client = ArchiveClient(baseUrl: baseUrl, deviceToken: token);
    final found = <String, Map<String, Object?>>{};
    final attempts = candidates.isEmpty ? <String>[''] : candidates;
    for (final candidate in attempts) {
      final response = await client.search(
        storeId: storeId,
        token: candidate,
        dari: dari,
        sampai: sampai,
        limit: limit,
      );
      final docs = response['documents'];
      if (docs is! List) continue;
      for (final doc in docs.whereType<Map>()) {
        final metadata = doc.map((key, value) => MapEntry('$key', value));
        final docId = '${metadata['doc_id'] ?? ''}';
        if (docId.isEmpty) continue;
        final existing = found[docId];
        if (existing == null ||
            '${metadata['archived_at'] ?? ''}'
                .compareTo('${existing['archived_at'] ?? ''}') >
                0) {
          found[docId] = metadata;
        }
      }
    }
    final results = found.values.toList()
      ..sort((a, b) => '${b['tanggal'] ?? ''}'.compareTo(
            '${a['tanggal'] ?? ''}',
          ));
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  /// Mengunduh dan mendekripsi satu dokumen arsip. Dipakai tampilan struk dan
  /// "Buka dari arsip"; server tidak pernah melihat plaintext.
  Future<Map<String, Object?>> open({
    required String docId,
    String contentHash = '',
  }) async {
    final baseUrl = await _baseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('Alamat arsip belum dikonfigurasi.');
    }
    final token = await SyncService.instance.relayDeviceToken();
    if (token == null || token.isEmpty) {
      throw StateError('Perangkat belum terhubung ke relay.');
    }
    final storeKey = await SyncService.instance.existingStoreKey();
    if (storeKey == null) {
      throw StateError('Kunci toko belum tersedia di perangkat ini.');
    }
    final storeKeys =
        (await SyncService.instance.ensureStoreKeyRing()).byKeyId();
    final storeId = await SyncService.instance.storeId();
    final client = ArchiveClient(baseUrl: baseUrl, deviceToken: token);
    final doc = await client.getDocument(
      storeId: storeId,
      docType: docTypeNota,
      docId: docId,
      contentHash: contentHash,
    );
    return _decryptDocument(doc, storeKeys: storeKeys);
  }

  Future<Map<String, Object?>> _decryptDocument(
    Map<String, Object?> doc, {
    required Map<String, List<int>> storeKeys,
  }) async {
    final keyId = '${doc['key_id'] ?? ''}';
    final storeKey = storeKeys[keyId];
    if (storeKey == null) {
      throw StateError(
        'Dokumen diarsipkan dengan versi kunci lain. Kunci lama harus '
        'tersedia di perangkat ini untuk membukanya.',
      );
    }
    final plain = await decryptPayload(
      storeKey,
      '${doc['ciphertext'] ?? ''}',
      '${doc['nonce'] ?? ''}',
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) {
      throw StateError('Isi arsip tidak valid.');
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  /// Mengunduh seluruh arsip dan mendekripsi secara lokal. Hasil dikembalikan
  /// sebagai dokumen JSON siap simpan; server tidak melakukan dekripsi.
  Future<Map<String, Object?>> exportArchive({String since = ''}) async {
    final baseUrl = await _baseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('Alamat arsip belum dikonfigurasi.');
    }
    final token = await SyncService.instance.relayDeviceToken();
    if (token == null || token.isEmpty) {
      throw StateError('Perangkat belum terhubung ke relay.');
    }
    final storeKey = await SyncService.instance.existingStoreKey();
    if (storeKey == null) {
      throw StateError('Kunci toko belum tersedia di perangkat ini.');
    }
    final storeKeys =
        (await SyncService.instance.ensureStoreKeyRing()).byKeyId();
    final storeId = await SyncService.instance.storeId();
    final client = ArchiveClient(baseUrl: baseUrl, deviceToken: token);
    final documents = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      final response = await client.export(
        storeId: storeId,
        since: since,
        limit: 500,
        offset: offset,
      );
      final rows = response['documents'];
      if (rows is! List || rows.isEmpty) break;
      for (final row in rows.whereType<Map>()) {
        final metadata = row.map((key, value) => MapEntry('$key', value));
        final payload = await _decryptDocument(metadata, storeKeys: storeKeys);
        documents.add({
          'metadata': {
            'doc_id': metadata['doc_id'],
            'doc_type': metadata['doc_type'],
            'no_nota': metadata['no_nota'],
            'tanggal': metadata['tanggal'],
            'schema_version': metadata['schema_version'],
            'key_id': metadata['key_id'],
            'key_version': metadata['key_version'] ?? 1,
            'content_hash': metadata['content_hash'],
            'archived_at': metadata['archived_at'],
          },
          'document': payload,
        });
      }
      if (response['has_more'] != true) break;
      final next = (response['next_offset'] as num?)?.toInt() ?? 0;
      if (next <= offset) break;
      offset = next;
    }
    return {
      'version': 1,
      'schema_version': AppDatabase.schemaVersion,
      'exported_at': nowIso(),
      'store_id': storeId,
      'documents': documents,
    };
  }
}
