import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'config.dart';

class Database {
  Database(this._conn);

  final Connection _conn;

  static Future<Database> open(String url) async {
    final parts = DbParts.parse(url);
    final conn = await Connection.open(
      Endpoint(
        host: parts.host,
        port: parts.port,
        database: parts.database,
        username: parts.username,
        password: parts.password,
      ),
      settings: ConnectionSettings(
        sslMode: parts.sslMode == 'disable' ? SslMode.disable : SslMode.require,
      ),
    );
    final db = Database(conn);
    await db.migrate();
    return db;
  }

  Future<void> close() => _conn.close();

  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await _conn.execute(Sql.named(sql), parameters: params);
    return result.map((row) => row.toColumnMap()).toList();
  }

  Future<Map<String, Object?>?> one(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final rows = await query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await _conn.execute(Sql.named(sql), parameters: params);
    return result.affectedRows;
  }

  Future<T> tx<T>(Future<T> Function(DatabaseSession session) action) {
    return _conn.runTx((session) async {
      final wrapper = DatabaseSession(session);
      return action(wrapper);
    });
  }

  Future<void> migrate() async {
    const statements = [
      '''
CREATE TABLE IF NOT EXISTS server_keys (
  name TEXT PRIMARY KEY,
  private_key TEXT NOT NULL,
  public_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
''',
      '''
CREATE TABLE IF NOT EXISTS owners (
  owner_id TEXT PRIMARY KEY,
  owner_public_key TEXT NOT NULL DEFAULT '',
  license_plan TEXT NOT NULL DEFAULT 'premium',
  license_period_end TIMESTAMPTZ,
  license_device_limit INTEGER NOT NULL DEFAULT 5,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
''',
      '''
CREATE TABLE IF NOT EXISTS enroll_tokens (
  token TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
''',
      '''
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  nama TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'owner',
  employee_account_id TEXT,
  public_key TEXT NOT NULL,
  encryption_key TEXT NOT NULL,
  owner_public_key TEXT NOT NULL DEFAULT '',
  store_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  token_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
)
''',
      '''
CREATE TABLE IF NOT EXISTS store_keys (
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  store_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  wrapped_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, store_id, device_id)
)
''',
      '''
CREATE TABLE IF NOT EXISTS envelopes (
  id TEXT PRIMARY KEY,
  relay_seq BIGSERIAL UNIQUE NOT NULL,
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  store_id TEXT NOT NULL,
  sender_device_id TEXT NOT NULL,
  recipient_device_id TEXT NOT NULL DEFAULT '',
  seq INTEGER NOT NULL,
  hlc_wall BIGINT NOT NULL,
  hlc_counter INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  signature TEXT NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_id, store_id, sender_device_id, seq),
  UNIQUE (owner_id, idempotency_key)
)
''',
      'CREATE INDEX IF NOT EXISTS ix_envelopes_store_seq ON envelopes(owner_id, store_id, relay_seq)',
      '''
CREATE TABLE IF NOT EXISTS snapshots (
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  store_id TEXT NOT NULL,
  id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  store_seq BIGINT NOT NULL,
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  signature TEXT NOT NULL,
  checksum TEXT NOT NULL,
  hlc_wall BIGINT NOT NULL,
  hlc_counter INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, store_id)
)
''',
      '''
CREATE TABLE IF NOT EXISTS accounts (
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  sync_id TEXT NOT NULL,
  username TEXT NOT NULL,
  nama TEXT NOT NULL,
  role_base TEXT NOT NULL DEFAULT 'KASIR',
  extra_permissions JSONB NOT NULL DEFAULT '[]'::jsonb,
  store_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  password_hash TEXT NOT NULL DEFAULT '',
  password_salt TEXT NOT NULL DEFAULT '',
  password_iterations INTEGER NOT NULL DEFAULT 600000,
  aktif BOOLEAN NOT NULL DEFAULT true,
  permission_version INTEGER NOT NULL DEFAULT 1,
  permission_payload JSONB,
  permission_signature TEXT,
  permission_signer_public_key TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, sync_id),
  UNIQUE (owner_id, username)
)
''',
      '''
CREATE TABLE IF NOT EXISTS invites (
  code TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  account_sync_id TEXT NOT NULL,
  store_id TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  claimed_at TIMESTAMPTZ,
  claimed_device_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
''',
      '''
CREATE TABLE IF NOT EXISTS cursors (
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  store_id TEXT NOT NULL,
  last_seq BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, device_id, store_id)
)
''',
      '''
CREATE TABLE IF NOT EXISTS owner_identities (
  email TEXT PRIMARY KEY,
  subject TEXT UNIQUE,
  owner_id TEXT NOT NULL REFERENCES owners(owner_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
)
''',
      'ALTER TABLE owner_identities ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ',
    ];
    for (final statement in statements) {
      await _conn.execute(statement);
    }
  }
}

class DatabaseSession {
  DatabaseSession(this._session);

  final TxSession _session;

  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await _session.execute(Sql.named(sql), parameters: params);
    return result.map((row) => row.toColumnMap()).toList();
  }

  Future<Map<String, Object?>?> one(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final rows = await query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await _session.execute(Sql.named(sql), parameters: params);
    return result.affectedRows;
  }
}

/// PostgreSQL mengembalikan JSONB sebagai String pada driver ini.
List<String> stringList(Object? value) {
  if (value is List) return value.map((item) => '$item').toList();
  if (value is String && value.isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is List) return decoded.map((item) => '$item').toList();
  }
  return const [];
}

Map<String, Object?>? jsonMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  if (value is String && value.isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry('$key', item));
    }
  }
  return null;
}
