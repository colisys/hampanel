const std = @import("std");
const db = @import("db.zig");
const compat = @import("compat");

pub const Migration = struct {
    version: i64,
    name: []const u8,
    sql: []const u8,
};

const schema_v1 =
    \\CREATE TABLE IF NOT EXISTS settings (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS runtime_environments (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    runtime TEXT NOT NULL,
    \\    image TEXT NOT NULL,
    \\    tag TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'created',
    \\    port INTEGER,
    \\    cpu REAL,
    \\    memory_mb INTEGER,
    \\    volume TEXT NOT NULL,
    \\    extensions TEXT NOT NULL DEFAULT '[]',
    \\    pkg_mirror TEXT NOT NULL DEFAULT '',
    \\    config_version INTEGER NOT NULL DEFAULT 1,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS runtime_config_files (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    environment_id TEXT NOT NULL REFERENCES runtime_environments(id) ON DELETE CASCADE,
    \\    path TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    updated_at INTEGER NOT NULL,
    \\    UNIQUE(environment_id, path)
    \\);
    \\CREATE TABLE IF NOT EXISTS audit_log (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    at TEXT NOT NULL,
    \\    peer TEXT NOT NULL,
    \\    method TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    status INTEGER NOT NULL,
    \\    duration_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS audit_log_id_desc ON audit_log(id DESC);
;

const schema_v2 =
    \\CREATE TABLE IF NOT EXISTS container_notes (
    \\    name TEXT PRIMARY KEY,
    \\    note TEXT NOT NULL DEFAULT '',
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS docker_registries (
    \\    id TEXT PRIMARY KEY,
    \\    engine TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    protocol TEXT NOT NULL DEFAULT 'https',
    \\    host TEXT NOT NULL,
    \\    username TEXT NOT NULL DEFAULT '',
    \\    secret TEXT NOT NULL DEFAULT '',
    \\    last_sync_at INTEGER,
    \\    last_sync_ok INTEGER,
    \\    last_sync_message TEXT NOT NULL DEFAULT '',
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS compose_projects (
    \\    name TEXT PRIMARY KEY,
    \\    dir TEXT NOT NULL,
    \\    source_dir TEXT NOT NULL DEFAULT '',
    \\    files TEXT NOT NULL DEFAULT '[]',
    \\    adopted INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
;

const schema_v3 =
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id TEXT PRIMARY KEY,
    \\    kind TEXT NOT NULL,
    \\    title TEXT NOT NULL,
    \\    status TEXT NOT NULL,
    \\    phase TEXT NOT NULL DEFAULT '',
    \\    progress INTEGER,
    \\    params TEXT NOT NULL DEFAULT '{}',
    \\    result TEXT NOT NULL DEFAULT '',
    \\    error TEXT NOT NULL DEFAULT '',
    \\    output_path TEXT NOT NULL,
    \\    output_base INTEGER NOT NULL DEFAULT 0,
    \\    output_bytes INTEGER NOT NULL DEFAULT 0,
    \\    output_truncated INTEGER NOT NULL DEFAULT 0,
    \\    exit_code INTEGER,
    \\    idempotency_key TEXT,
    \\    lock_key TEXT NOT NULL DEFAULT '',
    \\    owner_cn TEXT NOT NULL DEFAULT '',
    \\    created_at INTEGER NOT NULL,
    \\    started_at INTEGER,
    \\    finished_at INTEGER,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS tasks_idem ON tasks(kind, idempotency_key)
    \\    WHERE idempotency_key IS NOT NULL AND idempotency_key <> '';
    \\CREATE INDEX IF NOT EXISTS tasks_updated ON tasks(updated_at);
    \\CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status);
;

/// Append-only list: never rewrite an applied migration, only add new ones.
const migrations = [_]Migration{
    .{ .version = 1, .name = "core tables", .sql = schema_v1 },
    .{ .version = 2, .name = "docker management", .sql = schema_v2 },
    .{ .version = 3, .name = "tasks", .sql = schema_v3 },
};

/// `CREATE TABLE IF NOT EXISTS` cannot add columns, so databases created
/// before migration names were recorded keep the old `(version, applied_at)`
/// shape and every later insert fails. Add the column in place instead.
fn ensureSchemaMigrations(database: *db.Db) !void {
    try database.exec(
        "CREATE TABLE IF NOT EXISTS schema_migrations (" ++
            "version INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT ''," ++
            "applied_at INTEGER NOT NULL)",
    );
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("PRAGMA table_info(schema_migrations)");
    defer statement.deinit();
    var has_name = false;
    while (try statement.step()) {
        if (std.mem.eql(u8, statement.columnText(1), "name")) has_name = true;
    }
    if (has_name) return;
    try database.execUnlocked(
        "ALTER TABLE schema_migrations ADD COLUMN name TEXT NOT NULL DEFAULT ''",
    );
}

/// Runs every pending migration at startup. Before the first pending
/// migration a consistent snapshot of the database is written to
/// `<db dir>/backups/` so a failed migration can always be restored.
pub fn migrate(allocator: std.mem.Allocator, database: *db.Db) !void {
    return migrateList(allocator, database, &migrations);
}

pub fn migrateList(
    allocator: std.mem.Allocator,
    database: *db.Db,
    list: []const Migration,
) !void {
    try ensureSchemaMigrations(database);
    try database.exec(
        "INSERT INTO schema_migrations(version, name, applied_at) " ++
            "SELECT 0, 'baseline', 0 WHERE NOT EXISTS (SELECT 1 FROM schema_migrations)",
    );
    const from = try currentVersion(database);

    var pending: usize = 0;
    for (list) |migration| {
        if (migration.version > from) pending += 1;
    }
    if (pending == 0) return;
    const to = list[list.len - 1].version;

    try backupDatabase(allocator, database, from, to);

    for (list) |migration| {
        if (migration.version <= from) continue;
        database.lock();
        errdefer database.unlock();
        var begin = try database.prepareUnlocked("BEGIN IMMEDIATE");
        defer begin.deinit();
        _ = try begin.step();

        database.execUnlocked(migration.sql) catch |err| {
            var rollback = try database.prepareUnlocked("ROLLBACK");
            defer rollback.deinit();
            _ = rollback.step() catch {};
            database.unlock();
            return err;
        };
        var mark = try database.prepareUnlocked(
            "INSERT INTO schema_migrations(version, name, applied_at) VALUES(?1, ?2, ?3)",
        );
        defer mark.deinit();
        try mark.bind(&.{
            .{ .int = migration.version },
            .{ .text = migration.name },
            .{ .int = compat.timestamp() },
        });
        _ = try mark.step();
        var commit = try database.prepareUnlocked("COMMIT");
        defer commit.deinit();
        _ = try commit.step();
        database.unlock();
    }
}

/// `VACUUM INTO` produces a compact, consistent snapshot without extra
/// dependencies. Failures are logged but never block startup.
fn backupDatabase(
    allocator: std.mem.Allocator,
    database: *db.Db,
    from: i64,
    to: i64,
) !void {
    const db_path = database.path() orelse return;
    const dir_path = try std.fs.path.join(allocator, &.{
        std.fs.path.dirname(db_path) orelse ".",
        "backups",
    });
    defer allocator.free(dir_path);
    compat.cwd().makePath(dir_path) catch return;

    const stamp = compat.timestamp();
    const file_name = try std.fmt.allocPrint(
        allocator,
        "hampanel-pre-v{d}-v{d}-{d}.db",
        .{ from, to, stamp },
    );
    defer allocator.free(file_name);
    const target = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(target);

    const sql = try std.fmt.allocPrint(
        allocator,
        "VACUUM INTO '{s}'",
        .{target},
    );
    defer allocator.free(sql);
    const sql_z = try compat.dupeZ(allocator, sql);
    defer allocator.free(sql_z);
    database.exec(sql_z) catch |err| {
        std.debug.print("hampaneld: migration backup failed: {t}\n", .{err});
        return;
    };
    std.debug.print(
        "hampaneld: database backed up to {s}\n",
        .{target},
    );
}

pub fn currentVersion(database: *db.Db) !i64 {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
    );
    defer statement.deinit();
    if (!(try statement.step())) return 0;
    return statement.columnInt(0);
}

test "versioned migrations apply in order and back up first" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(path);

    var database = try db.Db.open(path);
    defer database.close();

    const list = [_]Migration{
        .{ .version = 1, .name = "one", .sql = "CREATE TABLE t1 (a INTEGER);" },
        .{ .version = 2, .name = "two", .sql = "CREATE TABLE t2 (b INTEGER);" },
    };
    try migrateList(allocator, &database, &list);
    try std.testing.expectEqual(@as(i64, 2), try currentVersion(&database));
    try migrateList(allocator, &database, &list);
    try std.testing.expectEqual(@as(i64, 2), try currentVersion(&database));

    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT COUNT(*) FROM schema_migrations WHERE version IN (1, 2)",
    );
    defer statement.deinit();
    try std.testing.expect(try statement.step());
    try std.testing.expectEqual(@as(i64, 2), statement.columnInt(0));

    const backup_dir = try std.fs.path.join(allocator, &.{ dir, "backups" });
    defer allocator.free(backup_dir);
    var backups = compat.openDirAbsolute(backup_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.BackupMissing,
        else => return err,
    };
    defer backups.close();
    var iterator = backups.iterate();
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "legacy schema_migrations table gains the name column" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(path);

    var database = try db.Db.open(path);
    defer database.close();
    try database.exec(
        "CREATE TABLE schema_migrations (" ++
            "version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)",
    );
    try database.exec("INSERT INTO schema_migrations(version, applied_at) VALUES(1, 0)");

    try migrate(allocator, &database);
    try std.testing.expectEqual(@as(i64, @intCast(migrations.len)), try currentVersion(&database));
}

test "sqlite core migrations create the schema" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(path);

    var database = try db.Db.open(path);
    defer database.close();
    try migrate(allocator, &database);
    try migrate(allocator, &database);

    try database.execute(
        "INSERT INTO settings(key, value, updated_at) VALUES(?1, ?2, ?3)",
        &.{ .{ .text = "k" }, .{ .text = "v" }, .{ .int = 1 } },
    );
    try database.execute(
        "INSERT INTO settings(key, value, updated_at) VALUES(?1, ?2, ?3) " ++
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        &.{ .{ .text = "k" }, .{ .text = "v2" }, .{ .int = 2 } },
    );

    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT value FROM settings WHERE key = 'k'");
    defer statement.deinit();
    try std.testing.expect(try statement.step());
    try std.testing.expectEqualStrings("v2", statement.columnText(0));
}
