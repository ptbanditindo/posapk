import 'dart:io';

class RelayConfig {
  RelayConfig({
    required this.host,
    required this.port,
    required this.databaseUrl,
    required this.adminToken,
    this.googleClientId = '',
  });

  final String host;
  final int port;
  final String databaseUrl;
  final String adminToken;
  final String googleClientId;

  factory RelayConfig.fromEnv() {
    final fileEnv = _readDotEnv();
    String? read(String key) {
      final value = Platform.environment[key] ?? fileEnv[key];
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    }

    final databaseUrl = read('RELAY_DATABASE_URL');
    final adminToken = read('RELAY_ADMIN_TOKEN');
    if (databaseUrl == null) {
      throw StateError(
        'RELAY_DATABASE_URL belum diatur. Salin relay/.env.example ke '
        'relay/.env lalu isi nilainya.',
      );
    }
    if (adminToken == null) {
      throw StateError(
        'RELAY_ADMIN_TOKEN belum diatur. Salin relay/.env.example ke '
        'relay/.env lalu isi nilainya.',
      );
    }
    return RelayConfig(
      host: read('RELAY_HOST') ?? '0.0.0.0',
      port: int.tryParse(read('RELAY_PORT') ?? '') ?? 8787,
      databaseUrl: databaseUrl,
      adminToken: adminToken,
      googleClientId: read('RELAY_GOOGLE_CLIENT_ID') ?? '',
    );
  }
}

Map<String, String> _readDotEnv() {
  final file = File('.env');
  if (!file.existsSync()) return const {};
  final values = <String, String>{};
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    var value = line.substring(separator + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    values[key] = value;
  }
  return values;
}

class DbParts {
  const DbParts({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.sslMode,
  });

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String sslMode;

  factory DbParts.parse(String raw) {
    final uri = Uri.parse(raw);
    if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
      throw ArgumentError('RELAY_DATABASE_URL harus postgresql://...');
    }
    return DbParts(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.path.replaceFirst('/', ''),
      username: uri.userInfo.split(':').first,
      password: uri.userInfo.contains(':')
          ? uri.userInfo.substring(uri.userInfo.indexOf(':') + 1)
          : '',
      sslMode: uri.queryParameters['sslmode'] ?? 'disable',
    );
  }
}
