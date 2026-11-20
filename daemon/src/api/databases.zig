const std = @import("std");
const compat = @import("compat");
const db = @import("../database.zig");
const Ctx = @import("context.zig").Context;
const S = []const u8;
const eq = std.mem.eql;
var mutex: std.Io.Mutex = .init;

pub const Op = enum { list, register, update, remove, overview, tables, create, drop, user, password, backup, backups, download, restore };
pub fn handler(comptime op: Op) *const fn (*Ctx) anyerror!void {
    return struct {
        fn handle(ctx: *Ctx) anyerror!void {
            mutex.lockUncancelable(compat.io());
            defer mutex.unlock(compat.io());
            dispatch(ctx, op) catch |err| switch (err) {
                error.SqlUnsupported => ctx.fail(400, "sql_unsupported", "Redis instances support terminal access only"),
                error.BadInput => ctx.fail(400, "invalid_request", "Invalid name, connection parameters, password or confirmation"),
                error.NotFound => ctx.fail(404, "not_found", "Instance or backup not found"),
                error.ClientFailed, error.SpawnFailed, error.EngineUnavailable => ctx.fail(502, "client_failed", "Database client unavailable or operation failed"),
                else => ctx.fail(500, "database_error", @errorName(err)),
            };
        }
    }.handle;
}
const View = struct { id: S, name: S, engine: db.Engine, mode: db.Mode, host: S, port: u16, user: S, container: S };
const Input = struct { name: S, engine: db.Engine, mode: db.Mode, host: S = "localhost", port: ?u16 = null, user: ?S = null, password: S = "", container: S = "", socket: ?S = null };
fn body(ctx: *Ctx, comptime T: type) !T {
    return ctx.requireJson(T) catch error.BadInput;
}
fn rows(ctx: *Ctx, i: db.Instance, schema: ?S, sql: S) ![]const S {
    const text = try run(ctx, i, schema, sql, .query, null);
    if (i.engine == .mongo) return std.json.parseFromSliceLeaky([]const S, ctx.arena, std.mem.trim(u8, text, " \r\n"), .{}) catch error.ClientFailed;
    return split(ctx, text);
}
fn split(ctx: *Ctx, text: S) ![]const S {
    var list = std.array_list.Managed(S).init(ctx.arena);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| try list.append(std.mem.trimEnd(u8, line, "\r"));
    return list.items;
}
fn tmpDir(ctx: *Ctx) !S {
    return compat.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "database-backups", ".tmp" });
}
fn run(ctx: *Ctx, i: db.Instance, schema: ?S, script: S, action: db.Action, file: ?compat.File) !S {
    const payload = if (i.engine == .mongo and action == .query) try db.mongoScript(ctx.arena, i, script) else script;
    return db.run(ctx.arena, ctx.app.db, i, schema, payload, action, file, try tmpDir(ctx));
}
fn literal(a: std.mem.Allocator, password: S) !S {
    if (password.len == 0 or password.len > 256) return error.BadInput;
    for (password) |ch| if (ch < 32 or ch == 127 or ch == '\\') return error.BadInput;
    return std.mem.replaceOwned(u8, a, password, "'", "''");
}
fn dispatch(ctx: *Ctx, op: Op) !void {
    const a = ctx.arena;
    const store = ctx.app.db;
    var cat = try db.load(a, store);
    if (op == .list) {
        var items = std.array_list.Managed(View).init(a);
        for (cat.instances) |i| try items.append(.{ .id = i.id, .name = i.name, .engine = i.engine, .mode = i.mode, .host = i.host, .port = i.port, .user = i.user, .container = i.container });
        return ctx.json(.{ .items = items.items });
    }
    const id = ctx.param("id") orelse try db.token(a);
    const old = db.find(cat, id);
    if (op != .register and old == null) return error.NotFound;
    if (op == .register or op == .update) {
        const b = try body(ctx, Input);
        const i: db.Instance = .{ .id = id, .name = b.name, .engine = b.engine, .mode = b.mode, .host = b.host, .port = b.port orelse db.defaultPort(b.engine), .user = b.user orelse db.defaultUser(b.engine), .password = if (b.password.len == 0 and old != null) old.?.password else b.password, .container = b.container, .socket = b.socket orelse if (old) |item| item.socket else "" };
        if (db.validate(i) != null) return error.BadInput;
        try db.upsert(a, &cat, i);
        try db.save(a, store, cat);
        return ctx.json(.{ .id = id });
    }
    if (op == .remove) {
        _ = try db.remove(a, &cat, id);
        try db.save(a, store, cat);
        return ctx.empty(204);
    }
    var i = old.?;
    if (i.engine == .redis) return error.SqlUnsupported;
    const pg = i.engine == .postgres;
    const mongo = i.engine == .mongo;
    if (op == .overview) return ctx.json(.{
        .databases = try rows(ctx, i, null, if (mongo) "return client.getDB('admin').runCommand({listDatabases: 1}).databases.map(d => d.name);" else if (pg) "SELECT datname FROM pg_database ORDER BY 1" else "SHOW DATABASES"),
        .users = try rows(ctx, i, null, if (mongo) "return client.getDB('admin').runCommand({usersInfo: {forAllDBs: true}}).users.map(u => u.user + '@' + u.db);" else if (pg) "SELECT rolname FROM pg_roles ORDER BY 1" else "SELECT CONCAT(User,'@',Host) FROM mysql.user ORDER BY 1"),
    });
    if (op == .password or op == .user) {
        const b = try body(ctx, struct { name: S = "", password: S });
        if (op == .user and !db.isIdentifier(b.name)) return error.BadInput;
        const sql = if (mongo) blk: {
            if (b.password.len == 0 or b.password.len > 256 or std.mem.indexOfScalar(u8, b.password, 0) != null) return error.BadInput;
            const pw = try std.json.Stringify.valueAlloc(a, b.password, .{});
            const username = try std.json.Stringify.valueAlloc(a, if (op == .user) b.name else i.user, .{});
            break :blk if (op == .user) try std.fmt.allocPrint(a, "client.getDB('admin').createUser({{user: {s}, pwd: {s}, roles: [{{role: 'readWriteAnyDatabase', db: 'admin'}}]}}); return [];", .{ username, pw }) else try std.fmt.allocPrint(a, "client.getDB('admin').changeUserPassword({s}, {s}); return [];", .{ username, pw });
        } else blk: {
            const pw = try literal(a, b.password);
            break :blk if (pg) try std.fmt.allocPrint(a, "SET standard_conforming_strings=on;\n{s} \"{s}\" WITH LOGIN PASSWORD '{s}';", .{ if (op == .user) "CREATE ROLE" else "ALTER ROLE", if (op == .user) b.name else i.user, pw }) else if (op == .user) try std.fmt.allocPrint(a, "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';\nCREATE USER '{s}'@'%' IDENTIFIED BY '{s}';", .{ b.name, pw }) else try std.fmt.allocPrint(a, "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';\nALTER USER CURRENT_USER() IDENTIFIED BY '{s}';", .{pw});
        };
        _ = try run(ctx, i, null, sql, .query, null);
        if (op == .password) {
            i.password = b.password;
            try db.upsert(a, &cat, i);
            try db.save(a, store, cat);
        }
        return ctx.empty(204);
    }
    const name = if (op == .create) (try body(ctx, struct { name: S })).name else if (ctx.param("name")) |raw| try @import("../util/url.zig").decode(a, raw) else "";
    if (op != .backups and op != .download and !db.isDatabaseName(name)) return error.BadInput;
    if (op == .tables) return ctx.json(.{ .tables = try rows(ctx, i, name, if (mongo) try std.fmt.allocPrint(a, "return client.getDB({s}).getCollectionNames();", .{try std.json.Stringify.valueAlloc(a, name, .{})}) else if (pg) "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1" else "SHOW TABLES") });
    if (db.protected(name) or (mongo and (eq(u8, name, "admin") or eq(u8, name, "local") or eq(u8, name, "config")))) return error.BadInput;
    if (op == .create or op == .drop) {
        if (op == .drop and !eq(u8, name, (try ctx.query("confirm")) orelse "")) return error.BadInput;
        const sql = if (mongo) try std.fmt.allocPrint(a, "client.getDB({s}).{s}; return [];", .{ try std.json.Stringify.valueAlloc(a, name, .{}), if (op == .create) "createCollection('hampanel_init')" else "dropDatabase()" }) else blk: {
            const q: u8 = if (pg) '"' else '`';
            break :blk try std.fmt.allocPrint(a, "{s} DATABASE {c}{s}{c};", .{ if (op == .drop) "DROP" else "CREATE", q, name, q });
        };
        _ = try run(ctx, i, null, sql, .query, null);
        return ctx.empty(204);
    }
    const key = try std.fmt.allocPrint(a, "databases.backups.{s}", .{id});
    const raw = try store.getSetting(a, key);
    const items: []const db.Backup = if (raw) |text| try std.json.parseFromSliceLeaky([]db.Backup, a, text, .{}) else &.{};
    if (op == .backups) return ctx.json(.{ .items = items });
    const dir = try compat.path.join(a, &.{ ctx.app.config.data_dir, "database-backups", id });
    if (op == .backup) {
        const filename = try std.fmt.allocPrint(a, "{s}.{s}", .{ try db.token(a), if (mongo) "archive" else if (pg) "dump" else "sql" });
        const path = try compat.path.join(a, &.{ dir, filename });
        try compat.cwd().makePath(dir);
        const file = try compat.createFileAbsolute(path, .{ .mode = 0o600, .exclusive = true });
        errdefer compat.deleteFileAbsolute(path) catch {};
        defer file.close();
        _ = try run(ctx, i, name, "", .backup, file);
        var updated = std.array_list.Managed(db.Backup).init(a);
        try updated.append(.{ .name = filename, .database = name, .created_at = compat.milliTimestamp(), .size = (try file.stat()).size });
        try updated.appendSlice(items);
        try store.setSetting(key, try std.json.Stringify.valueAlloc(a, updated.items, .{}));
        return ctx.json(.{ .name = filename });
    }
    const requested = if (op == .download) ctx.param("backup").? else blk: {
        const b = try body(ctx, struct { backup: S, confirm: S });
        if (!eq(u8, name, b.confirm)) return error.BadInput;
        break :blk b.backup;
    };
    for (items) |item| {
        if (!eq(u8, item.name, requested) or (op == .restore and !eq(u8, item.database, name))) continue;
        if (op == .restore and !std.mem.endsWith(u8, item.name, if (mongo) ".archive" else if (pg) ".dump" else ".sql")) return error.BadInput;
        const path = try compat.path.join(a, &.{ dir, item.name });
        if (op == .download) {
            ctx.response = .{ .file_path = path, .content_type = "application/octet-stream" };
            return;
        }
        const file = try compat.openFileAbsolute(path, .{});
        defer file.close();
        _ = try run(ctx, i, name, "", .restore, file);
        return ctx.empty(204);
    }
    return error.NotFound;
}

test "instance CRUD hides and preserves the credential and rejects destructive requests before spawning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try @import("../db.zig").Db.open(":memory:");
    defer store.close();
    try store.exec("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    var app: @import("../app.zig").App = undefined;
    app.db = &store;
    app.config.data_dir = "/unused";
    var ctx: Ctx = undefined;
    ctx.arena = a;
    ctx.app = &app;
    ctx.params = &.{};
    ctx.response = .{};
    ctx.req.body = "{\"name\":\"first\",\"engine\":\"postgres\",\"mode\":\"host\",\"password\":\"not-public\"}";
    try dispatch(&ctx, .register);
    const id = (try std.json.parseFromSliceLeaky(struct { id: S }, a, ctx.response.body, .{})).id;
    try dispatch(&ctx, .list);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "not-public") == null);
    ctx.params = &.{ .{ .name = "id", .value = id }, .{ .name = "name", .value = "sample" }, .{ .name = "backup", .value = "../elsewhere" } };
    ctx.req.body = "{\"name\":\"updated\",\"engine\":\"postgres\",\"mode\":\"host\",\"password\":\"\"}";
    try dispatch(&ctx, .update);
    try std.testing.expectEqualStrings("not-public", db.find(try db.load(a, &store), id).?.password);
    ctx.req.query = "confirm=Sample";
    try std.testing.expectError(error.BadInput, dispatch(&ctx, .drop));
    ctx.req.body = "{\"backup\":\"../elsewhere\",\"confirm\":\"sample\"}";
    try std.testing.expectError(error.NotFound, dispatch(&ctx, .restore));
    try std.testing.expectError(error.NotFound, dispatch(&ctx, .download));
    ctx.req.body = "{\"name\":\"cache\",\"engine\":\"redis\",\"mode\":\"host\"}";
    try dispatch(&ctx, .update);
    try std.testing.expectError(error.SqlUnsupported, dispatch(&ctx, .overview));
    ctx.req.body = "{\"name\":\"document\",\"engine\":\"mongo\",\"mode\":\"host\",\"password\":\"mongo-secret\"}";
    try dispatch(&ctx, .update);
    const mongo = db.find(try db.load(a, &store), id).?;
    try std.testing.expectEqual(@as(u16, 27017), mongo.port);
    try std.testing.expectEqualStrings("admin", mongo.user);
    try dispatch(&ctx, .list);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "mongo-secret") == null);
    ctx.req.query = "confirm=other";
    try std.testing.expectError(error.BadInput, dispatch(&ctx, .drop));
    try dispatch(&ctx, .remove);
    try std.testing.expect(db.find(try db.load(a, &store), id) == null);
}
