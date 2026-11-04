import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/app_config.dart';
import '../sync/relay_client.dart';
import 'app_database.dart';
import 'license_service.dart';

class GoogleAuthException implements Exception {
  GoogleAuthException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class GoogleAuthService {
  GoogleAuthService._();

  static final GoogleAuthService instance = GoogleAuthService._();

  /// Diisi lewat `--dart-define=PUSATKU_GOOGLE_CLIENT_ID=...`.
  static const String clientId = String.fromEnvironment(
    'PUSATKU_GOOGLE_CLIENT_ID',
  );

  bool get configured => clientId.trim().isNotEmpty;

  bool get supported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  bool _initialized = false;

  Future<String> _idToken() async {
    if (!configured) {
      throw GoogleAuthException(
        'Login Google belum dikonfigurasi. Isi PUSATKU_GOOGLE_CLIENT_ID '
        'saat membangun aplikasi.',
        code: 'not_configured',
      );
    }
    if (!supported) {
      throw GoogleAuthException(
        'Login Google hanya tersedia di Android, iOS, macOS, dan web. '
        'Di perangkat ini gunakan token lisensi manual.',
        code: 'unsupported_platform',
      );
    }
    final signIn = GoogleSignIn.instance;
    if (!_initialized) {
      await signIn.initialize(
        clientId: kIsWeb ? clientId : null,
        serverClientId: clientId,
      );
      _initialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await signIn.authenticate();
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw GoogleAuthException('Masuk dengan Google dibatalkan.');
      }
      throw GoogleAuthException(
        'Gagal masuk dengan Google: '
        '${error.description ?? error.code.name}',
        code: error.code.name,
      );
    }
    final token = account.authentication.idToken;
    if (token == null || token.isEmpty) {
      throw GoogleAuthException(
        'Google tidak mengembalikan ID token. Periksa konfigurasi client ID '
        'dan SHA-1 aplikasi.',
      );
    }
    return token;
  }

  /// Meminta lisensi dari layanan tanpa menulis apa pun ke database.
  /// Dipakai mode ringkasan agar database tujuan bisa dipilih lebih dulu.
  Future<Map<String, Object?>> signIn() async {
    if (!serviceConfigured) {
      throw GoogleAuthException(
        'Layanan akun belum siap. Hubungi penjual.',
        code: 'service_unavailable',
      );
    }
    final idToken = await _idToken();
    final url = normalizedServiceUrl;
    final result = await RelayClient(baseUrl: url).googleLogin(
      idToken: idToken,
    );
    final ownerId = '${result['owner_id'] ?? ''}';
    final licenseToken = '${result['license_token'] ?? ''}';
    if (ownerId.isEmpty || licenseToken.isEmpty) {
      throw GoogleAuthException('Akun premium tidak mengembalikan lisensi.');
    }
    return result;
  }

  /// Menyimpan hasil [signIn] ke database yang sedang terbuka.
  Future<void> install(Map<String, Object?> result) async {
    final ownerId = '${result['owner_id'] ?? ''}';
    final licenseToken = '${result['license_token'] ?? ''}';
    await LicenseService.instance.installRemoteOwner(
      ownerId: ownerId,
      publicKey: '${result['owner_public_key'] ?? ''}',
    );
    await LicenseService.instance.installToken(
      licenseToken,
      expectedOwnerId: ownerId,
    );
    await AppDatabase.instance.setSetting(
      'sync.relay_url',
      normalizedServiceUrl,
    );
    await AppDatabase.instance.setSetting(
      'license.email',
      '${result['email'] ?? ''}',
    );
    await AppDatabase.instance.setSetting('license.provider', 'google');
  }

  Future<Map<String, Object?>> activate() async {
    final result = await signIn();
    await install(result);
    return result;
  }
}
