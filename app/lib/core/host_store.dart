import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'app_paths.dart';
import 'enrollment.dart';
import 'format.dart';

/// A managed daemon host: alias + full enrollment bundle.
class HostRecord {
  const HostRecord({
    required this.id,
    required this.alias,
    required this.enrollment,
    required this.createdAt,
    required this.updatedAt,
    required this.caPin,
    required this.serverPin,
  });

  final String id;
  final String alias;
  final Enrollment enrollment;
  final String createdAt;
  final String updatedAt;
  final String caPin;
  final String serverPin;

  String get identity => '${enrollment.endpoint}|${enrollment.entryPrefix}';
}

/// Local SQLite store for multi-host management. Every enrollment lives in
/// the database; the legacy single `enrollment.json` is imported once and
/// retired.
class HostStore {
  HostStore._(this._db, this.directory);

  static HostStore? _instance;

  final Database _db;
  final Directory directory;

  String? _activeId;

  static Future<HostStore> open({Directory? directory}) async {
    final instance = _instance;
    if (instance != null) return instance;
    final dir = directory ?? Enrollment.configDirectory();
    dir.createSync(recursive: true);
    final dbPath = '${dir.path}${Platform.pathSeparator}hosts.db';
    final db = sqlite3.open(dbPath);
    final store = HostStore._(db, dir)
      .._migrate()
      .._migrateLegacyEnrollment();
    // The DB stores client private keys; keep it and the WAL owner-only.
    await restrictToOwner(File(dbPath));
    for (final suffix in const ['-wal', '-shm']) {
      final extra = File('$dbPath$suffix');
      if (extra.existsSync()) await restrictToOwner(extra);
    }
    _instance = store;
    return store;
  }

  String? get activeId => _activeId;

  /// Schema bootstrap only. Versioned migrations live exclusively in the
  /// Zig daemon (`daemon/src/migrations.zig`); the client never migrates,
  /// it just creates its tables idempotently on first run.
  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS hosts ('
      'id TEXT PRIMARY KEY,'
      'alias TEXT NOT NULL,'
      'endpoint TEXT NOT NULL,'
      'entry_prefix TEXT NOT NULL DEFAULT "",'
      'bundle TEXT NOT NULL,'
      "ca_sha256 TEXT NOT NULL DEFAULT '',"
      "server_sha256 TEXT NOT NULL DEFAULT '',"
      'created_at TEXT NOT NULL,'
      'updated_at TEXT NOT NULL)',
    );
    _db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS hosts_identity '
      'ON hosts (endpoint, entry_prefix)',
    );
    final columns = _db
        .select('PRAGMA table_info(hosts)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('ca_sha256')) {
      _db.execute(
        "ALTER TABLE hosts ADD COLUMN ca_sha256 TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!columns.contains('server_sha256')) {
      _db.execute(
        "ALTER TABLE hosts ADD COLUMN server_sha256 TEXT NOT NULL DEFAULT ''",
      );
    }
    _backfillPins();
    _db.execute(
      'CREATE TABLE IF NOT EXISTS settings ('
      'key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    _activeId = _setting('active_host').isEmpty
        ? null
        : _setting('active_host');
  }

  /// Imports the pre-multihost `enrollment.json` exactly once.
  void _migrateLegacyEnrollment() {
    final file = File('${directory.path}/enrollment.json');
    if (!file.existsSync()) return;
    final backup = File('${file.path}.migrated');
    try {
      if (list().isEmpty) {
        final enrollment = Enrollment.fromText(file.readAsStringSync());
        final host = add(
          alias: _defaultAlias(enrollment),
          enrollment: enrollment,
          activate: true,
        );
        _activeId = host.id;
      }
    } catch (_) {
      // Unreadable legacy file: keep it around untouched.
      return;
    } finally {
      try {
        if (backup.existsSync()) backup.deleteSync();
        file.renameSync(backup.path);
      } catch (_) {}
    }
  }

  /// Old rows predate fingerprint pinning; seed them from their bundle.
  void _backfillPins() {
    final rows = _db.select(
      'SELECT id, bundle FROM hosts '
      "WHERE ca_sha256 = '' OR server_sha256 = ''",
    );
    for (final row in rows) {
      try {
        final enrollment = Enrollment.fromText(row['bundle'] as String);
        _writePins(row['id'] as String, enrollment);
      } catch (_) {
        // Leave unreadable bundles untouched; they fail on activation.
      }
    }
  }

  void _writePins(String id, Enrollment enrollment) {
    _db.execute(
      'UPDATE hosts SET ca_sha256 = ?, server_sha256 = ? WHERE id = ?',
      [
        normalizeFingerprint(enrollment.caSha256),
        normalizeFingerprint(enrollment.serverSha256),
        id,
      ],
    );
  }

  String _setting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? '' : rows.first['value'] as String;
  }

  void _setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  HostRecord _rowToHost(Map<String, Object?> row) => HostRecord(
    id: row['id'] as String,
    alias: row['alias'] as String,
    enrollment: Enrollment.fromText(row['bundle'] as String),
    createdAt: row['created_at'] as String,
    updatedAt: row['updated_at'] as String,
    caPin: row['ca_sha256'] as String? ?? '',
    serverPin: row['server_sha256'] as String? ?? '',
  );

  List<HostRecord> list() {
    final rows = _db.select(
      'SELECT * FROM hosts ORDER BY created_at ASC, id ASC',
    );
    return [for (final row in rows) _rowToHost(row)];
  }

  HostRecord? byId(String id) {
    final rows = _db.select('SELECT * FROM hosts WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToHost(rows.first);
  }

  HostRecord? active() {
    final id = _activeId;
    if (id == null) return null;
    final host = byId(id);
    if (host == null) {
      _activeId = null;
      _setSetting('active_host', '');
      return null;
    }
    return host;
  }

  HostRecord add({
    required String? alias,
    required Enrollment enrollment,
    bool activate = false,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final id =
        DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
        enrollment.endpoint.hashCode.toRadixString(36);
    final name = (alias == null || alias.trim().isEmpty)
        ? _defaultAlias(enrollment)
        : alias.trim();
    _db.execute(
      'INSERT INTO hosts(id, alias, endpoint, entry_prefix, bundle, '
      'ca_sha256, server_sha256, created_at, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        name,
        enrollment.endpoint,
        enrollment.entryPrefix,
        jsonEncode(enrollment.toJson()),
        normalizeFingerprint(enrollment.caSha256),
        normalizeFingerprint(enrollment.serverSha256),
        now,
        now,
      ],
    );
    if (activate) _setActive(id);
    return byId(id)!;
  }

  /// Adds the enrollment unless a host with the same endpoint + prefix
  /// already exists; in that case the stored bundle is refreshed instead.
  HostRecord upsert({
    required String? alias,
    required Enrollment enrollment,
    bool activate = false,
  }) {
    final rows = _db.select(
      'SELECT id FROM hosts WHERE endpoint = ? AND entry_prefix = ?',
      [enrollment.endpoint, enrollment.entryPrefix],
    );
    if (rows.isEmpty) {
      return add(alias: alias, enrollment: enrollment, activate: activate);
    }
    final id = rows.first['id'] as String;
    updateEnrollment(id, enrollment, alias: alias);
    _writePins(id, enrollment);
    if (activate) _setActive(id);
    return byId(id)!;
  }

  void updateAlias(String id, String alias) {
    _db.execute('UPDATE hosts SET alias = ?, updated_at = ? WHERE id = ?', [
      alias.trim(),
      DateTime.now().toUtc().toIso8601String(),
      id,
    ]);
  }

  void updateEnrollment(String id, Enrollment enrollment, {String? alias}) {
    final name = (alias == null || alias.trim().isEmpty) ? null : alias.trim();
    _db.execute(
      'UPDATE hosts SET bundle = ?, endpoint = ?, entry_prefix = ?, '
      'alias = COALESCE(?, alias), updated_at = ? WHERE id = ?',
      [
        jsonEncode(enrollment.toJson()),
        enrollment.endpoint,
        enrollment.entryPrefix,
        name,
        DateTime.now().toUtc().toIso8601String(),
        id,
      ],
    );
  }

  /// Returns a human-readable warning when the bundle in the database no
  /// longer matches the fingerprints pinned when the host was trusted.
  String? pinMismatch(HostRecord host) {
    final ca = normalizeFingerprint(host.caPin);
    final server = normalizeFingerprint(host.serverPin);
    final wantCa = normalizeFingerprint(host.enrollment.caSha256);
    final wantServer = normalizeFingerprint(host.enrollment.serverSha256);
    final changed = <String>[];
    if (ca.isNotEmpty && wantCa.isNotEmpty && ca != wantCa) {
      changed.add(
        'CA 证书\n本机记录：${formatFingerprint(ca)}\n当前凭据：${formatFingerprint(wantCa)}',
      );
    }
    if (server.isNotEmpty && wantServer.isNotEmpty && server != wantServer) {
      changed.add(
        '服务端证书\n本机记录：${formatFingerprint(server)}\n当前凭据：${formatFingerprint(wantServer)}',
      );
    }
    if (changed.isEmpty) return null;
    return '本机保存的注册凭据中的证书指纹与首次信任时不一致。\n\n'
        '${changed.join('\n\n')}\n\n'
        '请通过带外渠道核对新指纹；确认无误后再更新本机指纹。';
  }

  void trustPins(String id, Enrollment enrollment) =>
      _writePins(id, enrollment);

  void delete(String id) {
    _db.execute('DELETE FROM hosts WHERE id = ?', [id]);
    if (_activeId == id) _setActive(null);
  }

  void setActive(String? id) => _setActive(id);

  void _setActive(String? id) {
    _activeId = id;
    _setSetting('active_host', id ?? '');
  }

  String _defaultAlias(Enrollment enrollment) {
    final raw = enrollment.endpoint.trim();
    final colon = raw.lastIndexOf(':');
    final host = colon > 0 ? raw.substring(0, colon) : raw;
    return host.isEmpty ? 'Hampanel' : host;
  }

  void close() {
    _db.close();
    if (identical(_instance, this)) _instance = null;
  }
}
