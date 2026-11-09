import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../core/dates.dart';
import '../sync/crypto.dart';
import '../sync/shamir.dart';
import '../sync/sync_secrets.dart';
import '../sync/sync_service.dart';
import 'app_database.dart';
import 'audit_service.dart';
import 'google_drive_escrow.dart';
import 'license_service.dart';
import 'recovery_words.dart';
import 'secure_store.dart';
import 'store_registry.dart';

const String _bundleSecret = 'recovery.escrow_bundle';
const String _phraseSecret = 'recovery.escrow_phrase';
const String _sharesSecret = 'recovery.escrow_shares';
const String _verifiedSetting = 'recovery.escrow_verified';
const String _createdSetting = 'recovery.escrow_created_at';
const String _ownerSetting = 'recovery.escrow_owner_id';
const String _driveFileSetting = 'recovery.escrow_drive_file';
const String _bundleKind = 'pusatkupos.escrow';
const int _bundleVersion = 1;
const int _maxBundleChars = 64 * 1024;
const int _argonMemory = 64 * 1024;
const int _argonIterations = 3;
const int _argonParallelism = 2;

class EscrowException implements Exception {
  EscrowException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EscrowCreateResult {
  const EscrowCreateResult({
    required this.phrase,
    required this.shares,
    required this.bundle,
  });

  final String phrase;
  final List<String> shares;
  final Map<String, Object?> bundle;
}

class EscrowRestoreResult {
  const EscrowRestoreResult({
    required this.ownerId,
    required this.storeId,
    required this.storeIds,
  });

  final String ownerId;
  final String storeId;
  final List<String> storeIds;
}

/// Escrow kunci toko dan kunci owner.
///
/// Jalur utama memakai frasa pemulihan 12 kata + Argon2id. Master key acak
/// membungkus kunci owner dan setiap store key diturunkan per toko dengan
/// HKDF(master, store_id). Master yang sama dibagi Shamir 2-dari-3 untuk tiga
/// admin, sehingga satu admin tidak dapat membuka escrow sendirian.
class EscrowService {
  EscrowService._();

  static final EscrowService instance = EscrowService._();

  Future<bool> isVerified() async =>
      (await AppDatabase.instance.getSetting(_verifiedSetting)) == '1';

  Future<DateTime?> createdAt() async => DateTime.tryParse(
        await AppDatabase.instance.getSetting(_createdSetting) ?? '',
      );

  Future<String?> driveFileId() async =>
      AppDatabase.instance.getSetting(_driveFileSetting);

  Future<bool> hasLocalBundle() async {
    final raw = await SyncSecrets.instance.read(_bundleSecret);
    return raw != null && raw.trim().isNotEmpty;
  }

  Future<String?> pendingPhraseOnce() =>
      SyncSecrets.instance.read(_phraseSecret);

  Future<List<String>> pendingSharesOnce() async {
    final raw = await SyncSecrets.instance.read(_sharesSecret);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (_) {}
    return const [];
  }

  Future<void> clearPendingPhrase() =>
      SyncSecrets.instance.delete(_phraseSecret);

  Future<void> clearPendingShares() =>
      SyncSecrets.instance.delete(_sharesSecret);

  /// Membuat escrow baru untuk toko aktif. Escrow lama (bila ada) diganti;
  /// pemilik harus menyimpan frasa dan share baru.
  Future<EscrowCreateResult> create() async {
    final owner = await LicenseService.instance.owner();
    final ownerPrivate =
        await SecureStore.instance.read('owner.signing.private');
    final ownerId = '${owner?['owner_id'] ?? ''}';
    if (ownerId.isEmpty || ownerPrivate == null || ownerPrivate.isEmpty) {
      throw EscrowException(
        'Identitas owner belum lengkap. Selesaikan onboarding owner lebih '
        'dulu sebelum membuat escrow.',
      );
    }
    final ownerPublic = '${owner?['public_key'] ?? ''}';
    final storeId = await SyncService.instance.storeId();
    final activeKey = await SyncService.instance.ensureStoreKey();
    final activeKeyId = keyIdFor(activeKey);
    final master = _randomBytes(32);
    final storeCiphers = <String, Object?>{};
    for (final store in await StoreRegistry.instance.stores()) {
      if (store.storeId == storeId) continue;
      final ring = await SyncService.instance.storeKeyRing(
        storeId: store.storeId,
      );
      if (ring == null) continue;
      final key = ring.active;
      final keyId = keyIdFor(key);
      storeCiphers[store.storeId] = {
        ...await _encrypt(
          await deriveEscrowStoreKey(master, store.storeId),
          key,
          aad: utf8.encode('store:${store.storeId}:$keyId'),
        ),
        'key_id': keyId,
      };
    }
    storeCiphers[storeId] = {
      ...await _encrypt(
        await deriveEscrowStoreKey(master, storeId),
        activeKey,
        aad: utf8.encode('store:$storeId:$activeKeyId'),
      ),
      'key_id': activeKeyId,
    };
    final phrase = generateRecoveryPhrase(_randomBytes(recoveryWordCount));
    final salt = _randomBytes(16);
    final createdAtIso = nowIso();
    final argon = <String, Object?>{
      'alg': 'argon2id',
      'salt': b64e(salt),
      'memory': _argonMemory,
      'iterations': _argonIterations,
      'parallelism': _argonParallelism,
      'length': 32,
    };
    final header = <String, Object?>{
      'v': _bundleVersion,
      'kind': _bundleKind,
      'owner_id': ownerId,
      'created_at': createdAtIso,
      'argon': argon,
    };
    final phraseKey = await _derivePhraseKey(phrase, salt, argon);
    final phraseWrap = await _encrypt(
      phraseKey,
      master,
      aad: utf8.encode(canonicalJson(header)),
    );
    final payload = await _encrypt(
      master,
      utf8.encode(
        jsonEncode({
          'owner_private': ownerPrivate,
          'owner_public': ownerPublic,
        }),
      ),
      aad: utf8.encode('payload'),
    );
    final bundle = <String, Object?>{
      ...header,
      'phrase_wrap': phraseWrap,
      'payload': payload,
      'stores': storeCiphers,
    };
    final shares = splitSecret(master, threshold: 2, shareCount: 3)
        .map((share) => share.encode())
        .toList();
    await SyncSecrets.instance.write(_bundleSecret, jsonEncode(bundle));
    await SyncSecrets.instance.write(_phraseSecret, phrase);
    await SyncSecrets.instance.write(_sharesSecret, jsonEncode(shares));
    await AppDatabase.instance.setSetting(_verifiedSetting, '0');
    await AppDatabase.instance.setSetting(_createdSetting, createdAtIso);
    await AppDatabase.instance.setSetting(_ownerSetting, ownerId);
    await AppDatabase.instance.deleteSetting(_driveFileSetting);
    await AuditService.instance.recordNow(
      aksi: 'escrow.create',
      entity: 'escrow',
      entityId: ownerId,
      aktor: 'pemilik',
      after: {'store_id': storeId, 'key_id': activeKeyId},
    );
    return EscrowCreateResult(phrase: phrase, shares: shares, bundle: bundle);
  }

  /// Memverifikasi frasa terhadap escrow lokal. Bila cocok, escrow ditandai
  /// terverifikasi sehingga gate purge terpenuhi.
  Future<EscrowRestoreResult> verifyPhrase(String phrase) async {
    final bundle = await _loadBundle();
    final material = await _openBundle(bundle, phrase: phrase);
    await _markVerified('escrow.verify', material.ownerId);
    return material;
  }

  Future<EscrowRestoreResult> verifyShares(List<String> shares) async {
    final bundle = await _loadBundle();
    final material = await _openBundle(bundle, shares: shares);
    await _markVerified('escrow.verify', material.ownerId);
    return material;
  }

  Future<EscrowRestoreResult> restoreWithPhrase(
    String phrase, {
    Map<String, Object?>? bundle,
  }) async {
    final target = bundle ?? await _loadBundle();
    final material = await _openBundle(target, phrase: phrase);
    await _installMaterial(target, material);
    await SyncSecrets.instance.write(_bundleSecret, jsonEncode(target));
    await _markVerified('escrow.restore', material.ownerId);
    return material;
  }

  Future<EscrowRestoreResult> restoreWithShares(
    List<String> shares, {
    Map<String, Object?>? bundle,
  }) async {
    final target = bundle ?? await _loadBundle();
    final material = await _openBundle(target, shares: shares);
    await _installMaterial(target, material);
    await SyncSecrets.instance.write(_bundleSecret, jsonEncode(target));
    await _markVerified('escrow.restore', material.ownerId);
    return material;
  }

  Future<String> exportBundleText() async {
    final raw = await SyncSecrets.instance.read(_bundleSecret);
    if (raw == null || raw.isEmpty) {
      throw EscrowException('Escrow belum dibuat di perangkat ini.');
    }
    return raw;
  }

  Future<Map<String, Object?>> importBundleText(String raw) async {
    final bundle = _parseBundle(raw);
    await SyncSecrets.instance.write(_bundleSecret, jsonEncode(bundle));
    await AppDatabase.instance.setSetting(
      _createdSetting,
      '${bundle['created_at'] ?? ''}',
    );
    await AppDatabase.instance.setSetting(
      _ownerSetting,
      '${bundle['owner_id'] ?? ''}',
    );
    return bundle;
  }

  Future<String> uploadToDrive() async {
    final text = await exportBundleText();
    final existing = await driveFileId();
    final id = await GoogleDriveEscrow.instance.upload(
      text,
      fileId: existing,
    );
    await AppDatabase.instance.setSetting(_driveFileSetting, id);
    await AuditService.instance.recordNow(
      aksi: 'escrow.upload',
      entity: 'escrow',
      entityId: id,
      aktor: 'pemilik',
      after: {'provider': 'google_drive'},
    );
    return id;
  }

  Future<Map<String, Object?>> downloadFromDrive() async {
    final text = await GoogleDriveEscrow.instance.download(
      fileId: await driveFileId(),
    );
    final bundle = await importBundleText(text);
    await AppDatabase.instance.setSetting(
      _verifiedSetting,
      '0',
    );
    return bundle;
  }

  Future<Map<String, Object?>> _loadBundle() async {
    final raw = await SyncSecrets.instance.read(_bundleSecret);
    if (raw == null || raw.trim().isEmpty) {
      throw EscrowException(
        'Escrow belum tersedia di perangkat ini. Unduh dari Drive atau impor '
        'berkas escrow terlebih dahulu.',
      );
    }
    return _parseBundle(raw);
  }

  Map<String, Object?> _parseBundle(String raw) {
    if (raw.length > _maxBundleChars) {
      throw EscrowException('Berkas escrow terlalu besar.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw EscrowException('Berkas escrow bukan JSON yang valid.');
    }
    if (decoded is! Map) {
      throw EscrowException('Isi berkas escrow tidak dikenal.');
    }
    final bundle = decoded.map((key, value) => MapEntry('$key', value));
    if (bundle['v'] != _bundleVersion || bundle['kind'] != _bundleKind) {
      throw EscrowException('Versi escrow tidak didukung.');
    }
    if ('${bundle['owner_id'] ?? ''}'.isEmpty) {
      throw EscrowException('Escrow tidak memuat identitas owner.');
    }
    if (bundle['argon'] is! Map ||
        bundle['phrase_wrap'] is! Map ||
        bundle['payload'] is! Map ||
        bundle['stores'] is! Map) {
      throw EscrowException('Struktur escrow tidak lengkap.');
    }
    final stores = bundle['stores'] as Map;
    if (stores.isEmpty) {
      throw EscrowException('Escrow tidak memuat kunci toko.');
    }
    return bundle;
  }

  Future<_EscrowMaterial> _openBundle(
    Map<String, Object?> bundle, {
    String? phrase,
    List<String>? shares,
  }) async {
    if ((phrase == null) == (shares == null)) {
      throw ArgumentError('Pilih satu jalur pembukaan escrow.');
    }
    final master = phrase != null
        ? await _unwrapWithPhrase(bundle, phrase)
        : await _unwrapWithShares(bundle, shares!);
    final material = await _decryptMaterial(bundle, master);
    if (material.ownerPrivate.isEmpty) {
      throw EscrowException('Escrow tidak memuat kunci privat owner.');
    }
    return material;
  }

  Future<List<int>> _unwrapWithPhrase(
    Map<String, Object?> bundle,
    String phrase,
  ) async {
    final normalized = normalizeRecoveryPhrase(phrase);
    if (!isRecoveryPhraseShape(normalized)) {
      throw EscrowException(
        'Frasa pemulihan minimal $recoveryMinWords kata.',
      );
    }
    final argon = (bundle['argon'] as Map).map(
      (key, value) => MapEntry('$key', value),
    );
    final salt = b64d('${argon['salt'] ?? ''}');
    final key = await _derivePhraseKey(normalized, salt, argon);
    try {
      return await _decrypt(
        key,
        (bundle['phrase_wrap'] as Map).map(
          (key, value) => MapEntry('$key', value),
        ),
        aad: utf8.encode(canonicalJson(_header(bundle))),
      );
    } catch (_) {
      throw EscrowException(
        'Frasa pemulihan tidak cocok dengan escrow ini.',
      );
    }
  }

  Future<List<int>> _unwrapWithShares(
    Map<String, Object?> bundle,
    List<String> rawShares,
  ) async {
    final selected = <ShamirShare>[];
    for (final raw in rawShares) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      try {
        selected.add(ShamirShare.decode(text));
      } catch (error) {
        throw EscrowException('Share admin tidak valid: $error');
      }
    }
    if (selected.length < 2) {
      throw EscrowException(
        'Masukkan minimal dua share admin dari pemegang berbeda.',
      );
    }
    try {
      return combineShares(selected);
    } catch (error) {
      throw EscrowException('Share admin tidak dapat digabungkan: $error');
    }
  }

  Future<_EscrowMaterial> _decryptMaterial(
    Map<String, Object?> bundle,
    List<int> master,
  ) async {
    final payloadRaw = await _decrypt(
      master,
      (bundle['payload'] as Map).map(
        (key, value) => MapEntry('$key', value),
      ),
      aad: utf8.encode('payload'),
    );
    final payload =
        jsonDecode(utf8.decode(payloadRaw)) as Map<String, Object?>;
    final ownerPrivate = '${payload['owner_private'] ?? ''}';
    final ownerPublic = '${payload['owner_public'] ?? ''}';
    final stores = (bundle['stores'] as Map).map(
      (key, value) => MapEntry('$key', value),
    );
    final storeKeys = <String, List<int>>{};
    final storeIds = <String>[];
    for (final entry in stores.entries) {
      final storeId = entry.key;
      final data = (entry.value as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final keyId = '${data['key_id'] ?? ''}';
      final key = await _decrypt(
        await deriveEscrowStoreKey(master, storeId),
        data,
        aad: utf8.encode('store:$storeId:$keyId'),
      );
      if (keyId.isNotEmpty && keyId != keyIdFor(key)) {
        throw EscrowException('Penanda kunci toko $storeId tidak cocok.');
      }
      storeKeys[storeId] = key;
      storeIds.add(storeId);
    }
    if (storeKeys.isEmpty) {
      throw EscrowException('Escrow tidak membuka kunci toko apa pun.');
    }
    final currentStore = await SyncService.instance.storeId();
    final targetStore =
        storeKeys.containsKey(currentStore) ? currentStore : storeIds.first;
    return _EscrowMaterial(
      ownerId: '${bundle['owner_id'] ?? ''}',
      ownerPrivate: ownerPrivate,
      ownerPublic: ownerPublic,
      storeId: targetStore,
      storeIds: storeIds,
      storeKeys: storeKeys,
    );
  }

  Future<void> _installMaterial(
    Map<String, Object?> bundle,
    _EscrowMaterial typed,
  ) async {
    final existing = await LicenseService.instance.owner();
    final existingOwnerId = '${existing?['owner_id'] ?? ''}';
    if (existingOwnerId.isNotEmpty && existingOwnerId != typed.ownerId) {
      throw EscrowException(
        'Escrow ini milik owner ${typed.ownerId}, sedangkan perangkat ini '
        'memakai owner $existingOwnerId. Gunakan escrow milik owner ini.',
      );
    }
    final existingPublic = '${existing?['public_key'] ?? ''}';
    if (existingPublic.isNotEmpty &&
        typed.ownerPublic.isNotEmpty &&
        existingPublic != typed.ownerPublic) {
      throw EscrowException(
        'Kunci publik owner di escrow berbeda dengan yang dipin perangkat. '
        'Minta admin memeriksa escrow sebelum memulihkan.',
      );
    }
    if (existing == null) {
      await LicenseService.instance.installRemoteOwner(
        ownerId: typed.ownerId,
        publicKey: typed.ownerPublic,
      );
    } else if (existingPublic.isEmpty && typed.ownerPublic.isNotEmpty) {
      await AppDatabase.instance.db.update(
        'owner_identity',
        {'public_key': typed.ownerPublic},
        where: 'id = ?',
        whereArgs: [1],
      );
    }
    await SecureStore.instance.write(
      'owner.signing.private',
      typed.ownerPrivate,
    );
    for (final entry in typed.storeKeys.entries) {
      await SyncService.instance.installRecoveredStoreKey(
        storeId: entry.key,
        key: entry.value,
      );
    }
    await AppDatabase.instance.setSetting(_ownerSetting, typed.ownerId);
    await AppDatabase.instance.setSetting(
      _createdSetting,
      '${bundle['created_at'] ?? ''}',
    );
  }

  Future<void> _markVerified(String aksi, String ownerId) async {
    await AppDatabase.instance.setSetting(_verifiedSetting, '1');
    await AuditService.instance.recordNow(
      aksi: aksi,
      entity: 'escrow',
      entityId: ownerId,
      aktor: 'pemilik',
    );
  }

  Map<String, Object?> _header(Map<String, Object?> bundle) => {
        'v': bundle['v'],
        'kind': bundle['kind'],
        'owner_id': bundle['owner_id'],
        'created_at': bundle['created_at'],
        'argon': bundle['argon'],
      };

  Future<List<int>> _derivePhraseKey(
    String phrase,
    List<int> salt,
    Map<String, Object?> argon,
  ) async {
    final memory = (argon['memory'] as num?)?.toInt() ?? _argonMemory;
    final iterations =
        (argon['iterations'] as num?)?.toInt() ?? _argonIterations;
    final parallelism =
        (argon['parallelism'] as num?)?.toInt() ?? _argonParallelism;
    final length = (argon['length'] as num?)?.toInt() ?? 32;
    if (memory < 8 * 1024 ||
        memory > 512 * 1024 ||
        iterations < 1 ||
        iterations > 20 ||
        parallelism < 1 ||
        parallelism > 8 ||
        length < 16 ||
        length > 64) {
      throw EscrowException('Parameter Argon2id escrow tidak wajar.');
    }
    final key = await Argon2id(
      parallelism: parallelism,
      memory: memory,
      iterations: iterations,
      hashLength: length,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(phrase)),
      nonce: salt,
      associatedData: utf8.encode('pusatkupos-escrow-phrase-v1'),
    );
    return key.extractBytes();
  }

  Future<Map<String, Object?>> _encrypt(
    List<int> key,
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return {
      'nonce': b64e(box.nonce),
      'ct': b64e([...box.cipherText, ...box.mac.bytes]),
    };
  }

  Future<List<int>> _decrypt(
    List<int> key,
    Map<String, Object?> wrapped, {
    List<int> aad = const [],
  }) async {
    final raw = b64d('${wrapped['ct'] ?? ''}');
    if (raw.length <= 16) throw EscrowException('Ciphertext escrow rusak.');
    final box = SecretBox(
      raw.sublist(0, raw.length - 16),
      nonce: b64d('${wrapped['nonce'] ?? ''}'),
      mac: Mac(raw.sublist(raw.length - 16)),
    );
    return AesGcm.with256bits().decrypt(
      box,
      secretKey: SecretKey(key),
      aad: aad,
    );
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

class _EscrowMaterial extends EscrowRestoreResult {
  const _EscrowMaterial({
    required super.ownerId,
    required super.storeId,
    required super.storeIds,
    required this.ownerPrivate,
    required this.ownerPublic,
    required this.storeKeys,
  });

  final String ownerPrivate;
  final String ownerPublic;
  final Map<String, List<int>> storeKeys;
}
