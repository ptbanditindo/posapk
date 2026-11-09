import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'google_auth_service.dart';

class DriveEscrowException implements Exception {
  DriveEscrowException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Akses berkas escrow di Google Drive `appDataFolder`. Folder ini privat
/// untuk aplikasi dan akun owner, tidak terlihat di Drive biasa. Isi berkas
/// tetap ciphertext; Drive hanya menyimpan blob.
class GoogleDriveEscrow {
  GoogleDriveEscrow._();

  static final GoogleDriveEscrow instance = GoogleDriveEscrow._();

  static const String scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const String fileName = 'pusatkupos-escrow.json';

  bool get configured => GoogleAuthService.instance.configured;

  bool get supported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  bool _initialized = false;

  Future<GoogleSignInAccount> _account() async {
    if (!configured) {
      throw DriveEscrowException(
        'Google Drive belum dikonfigurasi. Isi PUSATKU_GOOGLE_CLIENT_ID '
        'saat membangun aplikasi, atau pakai ekspor berkas escrow.',
        code: 'not_configured',
      );
    }
    if (!supported) {
      throw DriveEscrowException(
        'Google Drive hanya tersedia di Android, iOS, macOS, dan web. '
        'Di perangkat ini pakai ekspor/impor berkas escrow.',
        code: 'unsupported_platform',
      );
    }
    final signIn = GoogleSignIn.instance;
    if (!_initialized) {
      await signIn.initialize(
        clientId: kIsWeb ? GoogleAuthService.clientId : null,
        serverClientId: GoogleAuthService.clientId,
      );
      _initialized = true;
    }
    try {
      final cached = await signIn.attemptLightweightAuthentication();
      if (cached != null) return cached;
      return await signIn.authenticate(scopeHint: const [scope]);
    } on GoogleSignInException catch (error) {
      throw DriveEscrowException(
        error.code == GoogleSignInExceptionCode.canceled
            ? 'Masuk dengan Google dibatalkan.'
            : 'Gagal masuk dengan Google: '
                '${error.description ?? error.code.name}',
        code: error.code.name,
      );
    }
  }

  Future<Map<String, String>> _headers() async {
    final account = await _account();
    final authorization =
        await account.authorizationClient.authorizationForScopes(const [scope]);
    final token = authorization?.accessToken ??
        (await account.authorizationClient
                .authorizeScopes(const [scope]))
            .accessToken;
    if (token.isEmpty) {
      throw DriveEscrowException(
        'Google Drive tidak memberikan izin akses.',
        code: 'no_token',
      );
    }
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
  }

  Future<String?> findFileId() async {
    final headers = await _headers();
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'spaces': 'appDataFolder',
      'q': "name = '$fileName' and trashed = false",
      'fields': 'files(id,name,modifiedTime)',
      'orderBy': 'modifiedTime desc',
      'pageSize': '1',
    });
    final response = await http.get(uri, headers: headers).timeout(
          const Duration(seconds: 30),
        );
    final body = _decode(response);
    final files = body['files'];
    if (files is List && files.isNotEmpty) {
      return '${(files.first as Map)['id'] ?? ''}';
    }
    return null;
  }

  Future<String> upload(String content, {String? fileId}) async {
    final headers = await _headers();
    if (fileId != null && fileId.isNotEmpty) {
      final uri = Uri.https(
        'www.googleapis.com',
        '/upload/drive/v3/files/$fileId',
        {'uploadType': 'media', 'fields': 'id'},
      );
      final response = await http
          .patch(
            uri,
            headers: {...headers, 'Content-Type': 'application/json'},
            body: content,
          )
          .timeout(const Duration(seconds: 60));
      final body = _decode(response);
      final id = '${body['id'] ?? ''}';
      if (id.isEmpty) {
        throw DriveEscrowException('Google Drive tidak mengembalikan ID berkas.');
      }
      return id;
    }
    final boundary = 'pusatku-escrow-${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName,
      'parents': ['appDataFolder'],
      'mimeType': 'application/json',
    });
    final bodyText = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json\r\n\r\n'
        '$content\r\n'
        '--$boundary--\r\n';
    final uri = Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
      'uploadType': 'multipart',
      'fields': 'id',
    });
    final response = await http
        .post(
          uri,
          headers: {
            ...headers,
            'Content-Type': 'multipart/related; boundary=$boundary',
          },
          body: bodyText,
        )
        .timeout(const Duration(seconds: 60));
    final body = _decode(response);
    final id = '${body['id'] ?? ''}';
    if (id.isEmpty) {
      throw DriveEscrowException('Google Drive tidak mengembalikan ID berkas.');
    }
    return id;
  }

  Future<String> download({String? fileId}) async {
    final headers = await _headers();
    final id = fileId ?? await findFileId();
    if (id == null || id.isEmpty) {
      throw DriveEscrowException(
        'Escrow belum ada di Google Drive akun ini.',
        code: 'not_found',
      );
    }
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files/$id', {
      'alt': 'media',
    });
    final response = await http.get(uri, headers: headers).timeout(
          const Duration(seconds: 60),
        );
    if (response.statusCode >= 400) {
      _throw(response);
    }
    return utf8.decode(response.bodyBytes);
  }

  Map<String, Object?> _decode(http.Response response) {
    if (response.statusCode >= 400) _throw(response);
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
    return const {};
  }

  Never _throw(http.Response response) {
    var message = response.reasonPhrase ?? 'Permintaan Drive gagal';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && '${error['message'] ?? ''}'.isNotEmpty) {
          message = '${error['message']}';
        }
      }
    } catch (_) {}
    throw DriveEscrowException(
      'Google Drive ${response.statusCode}: $message',
      code: 'drive_${response.statusCode}',
    );
  }
}
