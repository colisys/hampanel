const std = @import("std");
const db = @import("db.zig");
const compat = @import("compat");

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

pub fn migrate(database: *db.Db) !void {
    try database.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)");
    const version = try currentVersion(database);
    if (version < 1) {
        try database.exec(schema_v1);
        try database.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES(1, ?1)",
            &.{.{ .int = compat.timestamp() }},
        );
    }
}

fn currentVersion(database: *db.Db) !i64 {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT COALESCE(MAX(version), 0) FROM schema_migrations");
    defer statement.deinit();
    if (!(try statement.step())) return 0;
    return statement.columnInt(0);
}

test "sqlite migrations create the schema" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(path);

    var database = try db.Db.open(path);
    defer database.close();
    try migrate(&database);
    try migrate(&database);

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
