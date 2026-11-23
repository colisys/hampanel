const std = @import("std");
const db = @import("db.zig");
const compat = @import("compat");
const exec = @import("shared").exec;
const engine_mod = @import("runtime/engine.zig");

pub const settings_key = "databases.instances";

pub const Engine = enum {
    mysql,
    mariadb,
    postgres,
    mongo,
    redis,
    sqlite,

    pub fn label(self: Engine) []const u8 {
        return switch (self) {
            .mysql => "MySQL",
            .mariadb => "MariaDB",
            .postgres => "PostgreSQL",
            .mongo => "MongoDB",
            .redis => "Redis",
            .sqlite => "SQLite",
        };
    }

    pub fn isManaged(self: Engine) bool {
        return self != .redis and self != .sqlite;
    }

    pub fn fromString(value: []const u8) ?Engine {
        inline for (@typeInfo(Engine).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @fromBackingInt(@intCast(field.value));
        }
        return null;
    }
};

pub const Mode = enum {
    host,
    container,

    pub fn fromString(value: []const u8) ?Mode {
        inline for (@typeInfo(Mode).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @fromBackingInt(@intCast(field.value));
        }
        return null;
    }
};

pub const Instance = struct {
    id: []const u8,
    name: []const u8,
    engine: Engine,
    mode: Mode,
    host: []const u8 = "localhost",
    port: u16 = 3306,
    user: []const u8 = "root",
    password: []const u8 = "",
    container: []const u8 = "",
    socket: []const u8 = "",
    path: []const u8 = "",
};

pub const Catalog = struct {
    instances: []Instance = &.{},
};

pub fn load(allocator: std.mem.Allocator, database: *db.Db) !Catalog {
    const raw = try database.getSetting(allocator, settings_key);
    const text = raw orelse return .{};
    return std.json.parseFromSliceLeaky(Catalog, allocator, text, .{
        .ignore_unknown_fields = true,
    });
}

pub fn save(allocator: std.mem.Allocator, database: *db.Db, catalog: Catalog) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, catalog, .{ .whitespace = .indent_2 });
    try database.setSetting(settings_key, body);
}

pub fn find(catalog: Catalog, id: []const u8) ?Instance {
    for (catalog.instances) |instance| {
        if (std.mem.eql(u8, instance.id, id)) return instance;
    }
    return null;
}

pub fn upsert(allocator: std.mem.Allocator, catalog: *Catalog, instance: Instance) !void {
    var list = std.array_list.Managed(Instance).init(allocator);
    var replaced = false;
    for (catalog.instances) |existing| {
        if (std.mem.eql(u8, existing.id, instance.id)) {
            try list.append(instance);
            replaced = true;
        } else {
            try list.append(existing);
        }
    }
    if (!replaced) try list.append(instance);
    catalog.instances = try list.toOwnedSlice();
}

pub fn remove(allocator: std.mem.Allocator, catalog: *Catalog, id: []const u8) !bool {
    var list = std.array_list.Managed(Instance).init(allocator);
    var removed = false;
    for (catalog.instances) |existing| {
        if (std.mem.eql(u8, existing.id, id)) {
            removed = true;
            continue;
        }
        try list.append(existing);
    }
    catalog.instances = try list.toOwnedSlice();
    return removed;
}

pub fn validate(instance: Instance) ?[]const u8 {
    if (!isInstanceId(instance.id)) return "id must be 1..64 chars of letters, digits, - or _";
    if (instance.name.len == 0 or instance.name.len > 64) return "name must be 1..64 chars";
    if (instance.engine == .sqlite) {
        if (instance.mode != .host or !compat.path.isAbsolute(instance.path) or instance.path.len > 4096 or std.mem.indexOfScalar(u8, instance.path, 0) != null) return "SQLite requires an absolute host file path";
        return null;
    }
    if (instance.host.len == 0 or instance.host.len > 253) return "host must be 1..253 chars";
    for (instance.host) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-:_", c) == null) return "invalid host";
    if (std.mem.indexOfScalar(u8, instance.password, 0) != null) return "invalid password";
    if (instance.port == 0) return "port must be 1..65535";
    if (!(instance.engine == .redis and instance.user.len == 0) and !isIdentifier(instance.user)) return "user must be a valid account name";
    if (instance.password.len > 256) return "password too long";
    switch (instance.mode) {
        .host => {
            if (instance.container.len != 0) return "container must be empty for host mode";
        },
        .container => {
            if (!validContainer(instance.container)) return "container must be a valid name or id";
        },
    }
    if (instance.socket.len > 0) {
        if (!std.mem.startsWith(u8, instance.socket, "/") or instance.socket.len > 256) return "socket must be an absolute path";
        for (instance.socket) |ch| {
            if (ch == '\n' or ch == 0 or ch == '"' or ch == '`' or ch == '$') return "socket path contains invalid characters";
        }
    }
    return null;
}

fn isInstanceId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn validContainer(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 63) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '$' and ch != '-') return false;
    }
    return true;
}

pub fn isDatabaseName(value: []const u8) bool {
    if (value.len == 0 or value.len > 63 or !std.ascii.isAlphanumeric(value[0]) and value[0] != '_') return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '$') return false;
    }
    return true;
}

pub fn isTableName(value: []const u8) bool {
    return isIdentifier(value);
}

pub fn defaultPort(engine: Engine) u16 {
    return switch (engine) {
        .mysql, .mariadb => 3306,
        .postgres => 5432,
        .mongo => 27017,
        .redis => 6379,
        .sqlite => 0,
    };
}

pub fn defaultUser(engine: Engine) []const u8 {
    return switch (engine) {
        .mysql, .mariadb => "root",
        .postgres => "postgres",
        .mongo => "admin",
        .redis, .sqlite => "",
    };
}

pub const Backup = struct { name: []const u8, database: []const u8, created_at: i64, size: u64 };
pub const Action = enum { query, backup, restore };

pub fn sqliteTables(a: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const c = @import("sqlite_c");
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2((try compat.dupeZ(a, path)).ptr, &handle, c.SQLITE_OPEN_READONLY, null);
    defer if (handle) |h| {
        _ = c.sqlite3_close(h);
    };
    if (rc != c.SQLITE_OK) return error.InvalidSqliteFile;
    var external = db.Db{ .handle = handle.? };
    var stmt = external.prepareUnlocked("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT GLOB 'sqlite_*' ORDER BY name") catch return error.InvalidSqliteFile;
    defer stmt.deinit();
    var names = std.array_list.Managed([]const u8).init(a);
    while (stmt.step() catch return error.InvalidSqliteFile) try names.append(try stmt.dupeColumnText(a, 0));
    return names.items;
}

pub fn protected(name: []const u8) bool {
    inline for (.{ "postgres", "template0", "template1", "mysql", "performance_schema", "information_schema", "sys" }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return false;
}

pub fn token(a: std.mem.Allocator) ![]const u8 {
    var random: [16]u8 = undefined;
    compat.randomBytes(&random);
    return a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
}

pub fn run(a: std.mem.Allocator, database: *db.Db, i: Instance, schema: ?[]const u8, sql: []const u8, action: Action, file: ?compat.File, tmp_dir: []const u8) ![]const u8 {
    if (!i.engine.isManaged()) return error.SqlUnsupported;
    if (validate(i) != null or (schema != null and !isDatabaseName(schema.?))) return error.InvalidInstance;
    if (i.engine == .mongo) return runMongo(a, i, schema, sql, action, file, tmp_dir);
    const pg = i.engine == .postgres;
    const secret = if (pg) "PGPASSWORD" else "MYSQL_PWD";
    var env = try compat.cloneEnv(a);
    defer env.deinit();
    try env.put(secret, i.password);
    var argv = std.array_list.Managed([]const u8).init(a);
    if (i.mode == .container) {
        const socket = engine_mod.socketFromDb(a, database);
        const runtime = try engine_mod.detect(a, socket);
        try argv.appendSlice(&.{ runtime.name, "exec", "-i", "-e", secret, i.container });
        if (socket.len != 0) try env.put(engine_mod.hostVariable(runtime, argv.items), socket);
    }
    const exe: []const u8 = switch (i.engine) {
        .redis, .sqlite => unreachable,
        .postgres => switch (action) {
            .query => "psql",
            .backup => "pg_dump",
            .restore => "pg_restore",
        },
        .mysql => if (action == .backup) "mysqldump" else "mysql",
        .mariadb => if (action == .backup) "mariadb-dump" else "mariadb",
        .mongo => unreachable,
    };
    try argv.append(exe);
    if (!pg) try argv.append("--no-defaults");
    try argv.appendSlice(&.{ try std.fmt.allocPrint(a, "--host={s}", .{if (pg and i.socket.len > 0) i.socket else i.host}), try std.fmt.allocPrint(a, "--port={d}", .{i.port}), try std.fmt.allocPrint(a, "--{s}={s}", .{ if (pg) "username" else "user", i.user }) });
    if (pg) {
        try argv.append("--no-password");
        try argv.append(try std.fmt.allocPrint(a, "--dbname={s}", .{schema orelse "postgres"}));
        switch (action) {
            .query => try argv.appendSlice(&.{ "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1" }),
            .backup => try argv.append("--format=custom"),
            .restore => try argv.appendSlice(&.{ "--single-transaction", "--clean", "--if-exists", "--no-owner", "--no-acl" }),
        }
    } else {
        if (i.socket.len > 0) {
            try argv.append("--protocol=SOCKET");
            try argv.append(try std.fmt.allocPrint(a, "--socket={s}", .{i.socket}));
        } else try argv.append("--protocol=TCP");
        if (action == .backup) try argv.appendSlice(&.{ "--single-transaction", "--hex-blob" }) else try argv.appendSlice(&.{ "--binary-mode", "--batch", "--skip-column-names", "--local-infile=0", "--default-character-set=utf8mb4" });
        if (schema) |name| try argv.append(name);
    }
    if (action == .query) {
        const result = try exec.runWith(a, argv.items, .{ .environ_map = &env, .stdin = sql });
        if (!result.ok()) return error.ClientFailed;
        return result.stdout;
    }
    const io = compat.io();
    var child = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = &env, .stdin = if (action == .restore) .{ .file = file.?.inner } else .ignore, .stdout = if (action == .backup) .{ .file = file.?.inner } else .ignore, .stderr = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.ClientFailed;
    return "";
}

test "database operation guards" {
    for ([_][]const u8{ "-a", "a/b", "a'", "a`", "x=1", "." }) |name| try std.testing.expect(!isDatabaseName(name));
    try std.testing.expect(protected("MySQL"));
    try std.testing.expect(isDatabaseName("example-db"));
}

pub const mongo_secret = "HAMPANEL_MONGO_PASSWORD";

pub fn mongoUri(a: std.mem.Allocator, i: Instance) ![]const u8 {
    return std.fmt.allocPrint(a, "mongodb://{s}:{d}/", .{ i.host, i.port });
}

pub fn mongoArgv(a: std.mem.Allocator, i: Instance, action: Action, config_path: []const u8, schema: ?[]const u8) ![]const []const u8 {
    if (i.engine != .mongo or validate(i) != null) return error.InvalidInstance;
    var argv = std.array_list.Managed([]const u8).init(a);
    switch (action) {
        .query => try argv.appendSlice(&.{ "mongosh", "--quiet", "--norc", "--nodb", "--file", "/dev/stdin" }),
        .backup, .restore => {
            try argv.append(if (action == .backup) "mongodump" else "mongorestore");
            if (action == .backup) try argv.appendSlice(&.{ "--archive", "--gzip" }) else try argv.appendSlice(&.{ "--archive=/dev/stdin", "--gzip", "--drop" });
            try argv.appendSlice(&.{ "--config", config_path, "--username", i.user, "--authenticationDatabase", "admin" });
            if (action == .backup) if (schema) |name| try argv.appendSlice(&.{ "--db", name });
            if (action == .restore) if (schema) |name| try argv.append(try std.fmt.allocPrint(a, "--nsInclude={s}.*", .{name}));
        },
    }
    return argv.items;
}

fn mongoConfig(a: std.mem.Allocator, i: Instance) ![]const u8 {
    const uri = try mongoUri(a, i);
    const password = try std.json.Stringify.valueAlloc(a, i.password, .{});
    return std.fmt.allocPrint(a, "uri: {s}\npassword: {s}\n", .{ uri, password });
}

pub fn mongoScript(a: std.mem.Allocator, i: Instance, body: []const u8) ![]const u8 {
    const uri = try mongoUri(a, i);
    const user = try std.json.Stringify.valueAlloc(a, i.user, .{});
    const address = try std.json.Stringify.valueAlloc(a, uri, .{});
    return std.fmt.allocPrint(a,
        \\const address = {s};
        \\const user = {s};
        \\const password = process.env.{s};
        \\const uri = address.replace("mongodb://", "mongodb://" + encodeURIComponent(user) + ":" + encodeURIComponent(password) + "@");
        \\const client = new Mongo(uri + "admin?authSource=admin");
        \\const out = (() => {{
        \\{s}
        \\}})();
        \\print(JSON.stringify(out));
        \\
    , .{ address, user, mongo_secret, body });
}

fn runMongo(a: std.mem.Allocator, i: Instance, schema: ?[]const u8, script: []const u8, action: Action, file: ?compat.File, tmp_dir: []const u8) ![]const u8 {
    var env = try compat.cloneEnv(a);
    defer env.deinit();
    var config_path: ?[]const u8 = null;
    defer if (config_path) |path| compat.deleteFileAbsolute(path) catch {};
    var argv: []const []const u8 = undefined;
    if (action == .query) {
        try env.put(mongo_secret, i.password);
        argv = try mongoArgv(a, i, .query, "", schema);
    } else {
        try compat.cwd().makePath(tmp_dir);
        const path = try compat.path.join(a, &.{ tmp_dir, try std.fmt.allocPrint(a, "mongo-{s}.yml", .{try token(a)}) });
        {
            const config = try compat.createFileAbsolute(path, .{ .mode = 0o600, .exclusive = true });
            defer config.close();
            try config.writeAll(try mongoConfig(a, i));
        }
        config_path = path;
        argv = try mongoArgv(a, i, action, path, schema);
    }
    if (action == .query) {
        const result = try exec.runWith(a, argv, .{ .environ_map = &env, .stdin = script });
        if (!result.ok()) return error.ClientFailed;
        return result.stdout;
    }
    const io = compat.io();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env, .stdin = if (action == .restore) .{ .file = file.?.inner } else .ignore, .stdout = if (action == .backup) .{ .file = file.?.inner } else .ignore, .stderr = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.ClientFailed;
    return "";
}

test "MongoDB connection options keep credentials off argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const i: Instance = .{ .id = "m", .name = "MongoDB", .engine = .mongo, .mode = .host, .host = "localhost", .port = defaultPort(.mongo), .user = defaultUser(.mongo), .password = "secret-value" };
    try std.testing.expectEqualStrings("mongodb://localhost:27017/", try mongoUri(a, i));
    const script = try mongoScript(a, i, "return []; ");
    try std.testing.expect(std.mem.indexOf(u8, script, "secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "encodeURIComponent(password)") != null);
    const argv = try mongoArgv(a, i, .backup, "/secure/config.yml", "sample");
    const joined = try std.mem.join(a, " ", argv);
    try std.testing.expect(std.mem.indexOf(u8, joined, "secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--db sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, try std.mem.join(a, " ", try mongoArgv(a, i, .restore, "/secure/config.yml", "sample")), "--nsInclude=sample.*") != null);
    try std.testing.expectEqualStrings("mongosh --quiet --norc --nodb --file /dev/stdin", try std.mem.join(a, " ", try mongoArgv(a, i, .query, "", null)));
}

pub fn redisArgv(a: std.mem.Allocator, i: Instance, runtime: ?engine_mod.Engine) ![]const []const u8 {
    if (i.engine != .redis or validate(i) != null) return error.InvalidInstance;
    var args = std.array_list.Managed([]const u8).init(a);
    try args.append("/usr/bin/env");
    if (i.mode == .container) {
        const r = runtime orelse return error.EngineUnavailable;
        try args.appendSlice(&.{ r.name, "exec", "-it" });
        if (i.password.len != 0) try args.appendSlice(&.{ "-e", "REDISCLI_AUTH" });
        try args.append(i.container);
    }
    try args.append("redis-cli");
    if (i.socket.len != 0) try args.appendSlice(&.{ "-s", i.socket }) else try args.appendSlice(&.{ "-h", i.host, "-p", try std.fmt.allocPrint(a, "{d}", .{i.port}) });
    if (i.user.len != 0) try args.appendSlice(&.{ "--user", i.user });
    return args.items;
}

test "Redis registration defaults and credential-free terminal argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var i: Instance = .{ .id = "r", .name = "redis", .engine = .redis, .mode = .host, .port = defaultPort(.redis), .user = defaultUser(.redis), .password = "not-public" };
    try std.testing.expectEqualStrings("/usr/bin/env redis-cli -h localhost -p 6379", try std.mem.join(a, " ", try redisArgv(a, i, null)));
    i.mode = .container;
    i.container = "cache";
    i.user = "reader";
    try std.testing.expectEqualStrings("/usr/bin/env podman exec -it -e REDISCLI_AUTH cache redis-cli -h localhost -p 6379 --user reader", try std.mem.join(a, " ", try redisArgv(a, i, .{ .name = "podman", .podman = true })));
}
