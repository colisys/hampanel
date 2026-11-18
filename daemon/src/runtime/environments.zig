const std = @import("std");
const compat = @import("compat");
const db = @import("../db.zig");
const exec = @import("shared").exec;
const catalog = @import("catalog.zig");
const images = @import("images.zig");
const engine_mod = @import("engine.zig");

pub const Environment = struct {
    id: []const u8,
    name: []const u8,
    runtime: []const u8,
    image: []const u8,
    tag: []const u8,
    status: []const u8,
    port: ?u16,
    cpu: ?f64,
    memory_mb: ?u32,
    volume: []const u8,
    extensions: []const []const u8,
    pkg_mirror: []const u8,
    config_version: u32,
    created_at: i64,
    updated_at: i64,
};

pub const CreateRequest = struct {
    name: []const u8,
    runtime: []const u8,
    image: []const u8 = "",
    tag: []const u8 = "",
    port: ?u16 = null,
    cpu: ?f64 = null,
    memory_mb: ?u32 = null,
    extensions: []const []const u8 = &.{},
    pkg_mirror: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const CreateResult = struct {
    ok: bool,
    output: []const u8,
    environment: Environment,
};

pub const ConfigEntry = struct {
    path: []const u8,
    content: []const u8,
};

const EngineCommand = struct {
    engine: engine_mod.Engine,
    socket: []const u8,
};

fn engineCommand(allocator: std.mem.Allocator, database: *db.Db) !EngineCommand {
    const socket = engine_mod.socketFromDb(allocator, database);
    const engine = try engine_mod.detect(allocator, socket);
    return .{ .engine = engine, .socket = socket };
}

const select_columns =
    "id, name, runtime, image, tag, status, port, cpu, memory_mb, volume, extensions, pkg_mirror, config_version, created_at, updated_at";

pub fn list(allocator: std.mem.Allocator, database: *db.Db) ![]Environment {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT " ++ select_columns ++ " FROM runtime_environments ORDER BY created_at DESC");
    defer statement.deinit();
    var items = std.array_list.Managed(Environment).init(allocator);
    while (try statement.step()) try items.append(try rowToEnvironment(allocator, &statement));
    return items.items;
}

pub fn get(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) !?Environment {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT " ++ select_columns ++ " FROM runtime_environments WHERE id = ?1");
    defer statement.deinit();
    try statement.bind(&.{.{ .text = id }});
    if (!(try statement.step())) return null;
    return try rowToEnvironment(allocator, &statement);
}

pub fn create(
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    request: CreateRequest,
) !CreateResult {
    const runtime = catalog.find(request.runtime) orelse return error.UnknownRuntime;
    if (!validName(request.name)) return error.InvalidName;
    if (try nameExists(database, request.name)) return error.NameExists;

    var image = request.image;
    var tag = request.tag;
    if (image.len == 0) image = runtime.image;
    if (tag.len == 0) tag = runtime.tag;
    if (std.mem.eql(u8, runtime.id, "custom") and image.len == 0) return error.ImageRequired;
    if (!validImage(image)) return error.InvalidImage;
    if (!validTag(tag)) return error.InvalidTag;
    if (!validMirror(request.pkg_mirror)) return error.InvalidMirror;

    for (request.extensions) |extension| {
        if (!validExtensionId(extension)) return error.InvalidExtension;
        if (!catalog.extensionAllowed(runtime, extension)) return error.InvalidExtension;
    }

    const port = request.port orelse runtime.web_port;
    if (port == 0) return error.InvalidPort;
    if (request.cpu) |cpu| if (cpu <= 0 or cpu > 64) return error.InvalidCpu;
    if (request.memory_mb) |memory| if (memory < 64 or memory > 262144) return error.InvalidMemory;

    const id = try randomId(allocator);
    const volume = try std.fmt.allocPrint(allocator, "hampanel-rt-{s}-data", .{id});
    const extensions_json = try encodeExtensions(allocator, request.extensions);
    const now = compat.timestamp();

    try database.execute(
        "INSERT INTO runtime_environments(id, name, runtime, image, tag, status, port, cpu, memory_mb, volume, extensions, pkg_mirror, config_version, created_at, updated_at) " ++
            "VALUES(?1, ?2, ?3, ?4, ?5, 'building', ?6, ?7, ?8, ?9, ?10, ?11, 1, ?12, ?12)",
        &.{
            .{ .text = id },
            .{ .text = request.name },
            .{ .text = runtime.id },
            .{ .text = image },
            .{ .text = tag },
            .{ .int = port },
            if (request.cpu) |cpu| .{ .float = cpu } else .{ .null = {} },
            if (request.memory_mb) |memory| .{ .int = memory } else .{ .null = {} },
            .{ .text = volume },
            .{ .text = extensions_json },
            .{ .text = request.pkg_mirror },
            .{ .int = now },
        },
    );

    try seedConfigs(allocator, database, data_dir, id, runtime);
    const environment = (try get(allocator, database, id)).?;
    const outcome = rebuildEnvironment(allocator, database, data_dir, environment, runtime) catch |err| {
        updateStatus(database, id, "error") catch {};
        return .{ .ok = false, .output = @errorName(err), .environment = environment };
    };
    const refreshed = (try get(allocator, database, id)).?;
    return .{ .ok = outcome.ok, .output = outcome.output, .environment = refreshed };
}

pub fn start(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) !Outcome {
    return simpleAction(allocator, database, id, "start", "running");
}

pub fn stop(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) !Outcome {
    return simpleAction(allocator, database, id, "stop", "stopped");
}

pub fn restart(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) !Outcome {
    return simpleAction(allocator, database, id, "restart", "running");
}

pub fn remove(allocator: std.mem.Allocator, database: *db.Db, id: []const u8, volumes: bool) !Outcome {
    const environment = (try get(allocator, database, id)) orelse return error.NotFound;
    const command = try engineCommand(allocator, database);
    const name = try containerName(allocator, id);
    const result = try engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "rm", "-f", name },
        .{ .max_output = 2 * 1024 * 1024 },
    );
    if (volumes) {
        _ = engine_mod.run(
            allocator,
            command.engine,
            command.socket,
            &.{ command.engine.name, "volume", "rm", environment.volume },
            .{ .max_output = 1024 * 1024 },
        ) catch {};
    }
    if (result.ok()) {
        try database.execute("DELETE FROM runtime_environments WHERE id = ?1", &.{.{ .text = id }});
    }
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn logs(allocator: std.mem.Allocator, database: *db.Db, id: []const u8, lines: usize) !Outcome {
    const command = try engineCommand(allocator, database);
    const name = try containerName(allocator, id);
    const tail = try std.fmt.allocPrint(allocator, "{d}", .{lines});
    const result = try engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "logs", "--tail", tail, name },
        .{ .max_output = 8 * 1024 * 1024 },
    );
    return .{
        .ok = result.ok(),
        .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }),
    };
}

pub fn liveStatus(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) ![]u8 {
    const command = engineCommand(allocator, database) catch return allocator.dupe(u8, "unknown");
    const name = try containerName(allocator, id);
    const result = engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "inspect", "--format", "{{.State.Status}}", name },
        .{ .max_output = 64 * 1024 },
    ) catch return allocator.dupe(u8, "unknown");
    if (!result.ok()) return allocator.dupe(u8, "missing");
    const status = std.mem.trim(u8, result.stdout, " \t\r\n");
    updateStatus(database, id, status) catch {};
    return allocator.dupe(u8, status);
}

pub fn configList(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) ![]ConfigEntry {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT path, content FROM runtime_config_files WHERE environment_id = ?1 ORDER BY id",
    );
    defer statement.deinit();
    try statement.bind(&.{.{ .text = id }});
    var items = std.array_list.Managed(ConfigEntry).init(allocator);
    while (try statement.step()) {
        try items.append(.{
            .path = try allocator.dupe(u8, statement.columnText(0)),
            .content = try allocator.dupe(u8, statement.columnText(1)),
        });
    }
    return items.items;
}

pub fn configSave(
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    id: []const u8,
    file_path: []const u8,
    content: []const u8,
) !Outcome {
    const environment = (try get(allocator, database, id)) orelse return error.NotFound;
    database.lock();
    var statement = try database.prepareUnlocked(
        "UPDATE runtime_config_files SET content = ?1, updated_at = ?2 WHERE environment_id = ?3 AND path = ?4",
    );
    defer statement.deinit();
    try statement.bind(&.{
        .{ .text = content },
        .{ .int = compat.timestamp() },
        .{ .text = id },
        .{ .text = file_path },
    });
    _ = try statement.step();
    const changed = database.changes();
    database.unlock();
    if (changed == 0) return error.ConfigNotFound;

    try writeConfigFile(allocator, data_dir, id, file_path, content);
    if (std.mem.eql(u8, environment.status, "running") or std.mem.eql(u8, environment.status, "restarting")) {
        const command = try engineCommand(allocator, database);
        const name = try containerName(allocator, id);
        const result = try engine_mod.run(
            allocator,
            command.engine,
            command.socket,
            &.{ command.engine.name, "restart", name },
            .{ .max_output = 2 * 1024 * 1024 },
        );
        return .{ .ok = result.ok(), .output = textOf(result) };
    }
    return .{ .ok = true, .output = "配置已保存" };
}

pub fn extensionsSet(
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    id: []const u8,
    extensions: []const []const u8,
) !Outcome {
    const environment = (try get(allocator, database, id)) orelse return error.NotFound;
    const runtime = catalog.find(environment.runtime) orelse return error.UnknownRuntime;
    for (extensions) |extension| {
        if (!validExtensionId(extension) or !catalog.extensionAllowed(runtime, extension)) {
            return error.InvalidExtension;
        }
    }
    const encoded = try encodeExtensions(allocator, extensions);
    try database.execute(
        "UPDATE runtime_environments SET extensions = ?1, updated_at = ?2 WHERE id = ?3",
        &.{ .{ .text = encoded }, .{ .int = compat.timestamp() }, .{ .text = id } },
    );
    return rebuild(allocator, database, data_dir, id);
}

pub fn rebuild(allocator: std.mem.Allocator, database: *db.Db, data_dir: []const u8, id: []const u8) !Outcome {
    const environment = (try get(allocator, database, id)) orelse return error.NotFound;
    const runtime = catalog.find(environment.runtime) orelse return error.UnknownRuntime;
    return rebuildEnvironment(allocator, database, data_dir, environment, runtime);
}

pub fn processes(allocator: std.mem.Allocator, database: *db.Db, id: []const u8) !Outcome {
    const command = engineCommand(allocator, database) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    const name = try containerName(allocator, id);
    const result = engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "exec", name, "supervisorctl", "-c", "/etc/hampanel/supervisord.conf", "status" },
        .{ .max_output = 1024 * 1024 },
    ) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    return .{
        .ok = result.ok(),
        .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }),
    };
}

pub fn processAction(
    allocator: std.mem.Allocator,
    database: *db.Db,
    id: []const u8,
    process: []const u8,
    action: []const u8,
) !Outcome {
    if (!validProcessName(process)) return error.InvalidProcess;
    const allowed = [_][]const u8{ "start", "stop", "restart" };
    var valid = false;
    for (allowed) |candidate| if (std.mem.eql(u8, candidate, action)) {
        valid = true;
    };
    if (!valid) return error.InvalidAction;
    const command = engineCommand(allocator, database) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    const name = try containerName(allocator, id);
    const result = engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "exec", name, "supervisorctl", "-c", "/etc/hampanel/supervisord.conf", action, process },
        .{ .max_output = 1024 * 1024 },
    ) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    return .{
        .ok = result.ok(),
        .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }),
    };
}

fn rebuildEnvironment(
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    environment: Environment,
    runtime: *const catalog.Runtime,
) !Outcome {
    updateStatus(database, environment.id, "building") catch {};
    const command = try engineCommand(allocator, database);
    const config_version = environment.config_version + 1;
    const dockerfile = try images.renderDockerfile(
        allocator,
        runtime,
        environment.image,
        environment.tag,
        environment.extensions,
        environment.pkg_mirror,
    );
    const dir = try envDir(allocator, data_dir, environment.id);
    try compat.cwd().makePath(dir);
    try writeFileAbsolute(allocator, dir, "Dockerfile", dockerfile);

    const image_tag = try imageTag(allocator, environment.id, config_version);
    const build = try engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "build", "-t", image_tag, dir },
        .{ .max_output = 16 * 1024 * 1024 },
    );
    if (!build.ok()) {
        updateStatus(database, environment.id, "error") catch {};
        return .{ .ok = false, .output = textOf(build) };
    }

    const name = try containerName(allocator, environment.id);
    _ = engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, "rm", "-f", name },
        .{ .max_output = 1024 * 1024 },
    ) catch {};

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ command.engine.name, "run", "-d", "--name", name, "--restart", "unless-stopped", "--label" });
    try argv.append(try std.fmt.allocPrint(allocator, "hampanel.runtime={s}", .{environment.id}));
    if (environment.memory_mb) |memory| {
        try argv.appendSlice(&.{ "--memory", try std.fmt.allocPrint(allocator, "{d}m", .{memory}) });
    }
    if (environment.cpu) |cpu| {
        try argv.appendSlice(&.{ "--cpus", try std.fmt.allocPrint(allocator, "{d}", .{cpu}) });
    }
    if (environment.port) |port| {
        const mapping = try std.fmt.allocPrint(allocator, "{d}:{d}", .{ port, runtime.web_port });
        try argv.appendSlice(&.{ "-p", mapping });
    }
    const volume_mount = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ environment.volume, runtime.workdir });
    try argv.appendSlice(&.{ "-v", volume_mount });

    const configs = try configList(allocator, database, environment.id);
    const config_root = try configDir(allocator, data_dir, environment.id);
    for (configs) |config| {
        const container_path = configContainerPath(runtime, config.path) orelse continue;
        const host = try std.fs.path.join(allocator, &.{ config_root, config.path });
        const mount = try std.fmt.allocPrint(allocator, "{s}:{s}:ro", .{ host, container_path });
        try argv.appendSlice(&.{ "-v", mount });
    }
    try argv.append(image_tag);

    const run = try engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        argv.items,
        .{ .max_output = 8 * 1024 * 1024 },
    );
    if (!run.ok()) {
        updateStatus(database, environment.id, "error") catch {};
        return .{ .ok = false, .output = textOf(run) };
    }

    try database.execute(
        "UPDATE runtime_environments SET status = 'running', config_version = ?1, updated_at = ?2 WHERE id = ?3",
        &.{ .{ .int = config_version }, .{ .int = compat.timestamp() }, .{ .text = environment.id } },
    );
    return .{ .ok = true, .output = "镜像已重建并启动" };
}

fn simpleAction(allocator: std.mem.Allocator, database: *db.Db, id: []const u8, action: []const u8, status: []const u8) !Outcome {
    const command = try engineCommand(allocator, database);
    const name = try containerName(allocator, id);
    const result = try engine_mod.run(
        allocator,
        command.engine,
        command.socket,
        &.{ command.engine.name, action, name },
        .{ .max_output = 2 * 1024 * 1024 },
    );
    if (result.ok()) updateStatus(database, id, status) catch {};
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn seedConfigs(
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    id: []const u8,
    runtime: *const catalog.Runtime,
) !void {
    const dir = try configDir(allocator, data_dir, id);
    try compat.cwd().makePath(dir);
    for (runtime.config_files) |config| {
        try database.execute(
            "INSERT INTO runtime_config_files(environment_id, path, content, updated_at) VALUES(?1, ?2, ?3, ?4)",
            &.{ .{ .text = id }, .{ .text = config.name }, .{ .text = config.content }, .{ .int = compat.timestamp() } },
        );
        try writeConfigFile(allocator, data_dir, id, config.name, config.content);
    }
}

fn writeConfigFile(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8, name: []const u8, content: []const u8) !void {
    const dir = try configDir(allocator, data_dir, id);
    try compat.cwd().makePath(dir);
    try writeFileAbsolute(allocator, dir, name, content);
}

fn writeFileAbsolute(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
}

fn containerName(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "hampanel-rt-{s}", .{id});
}

fn imageTag(allocator: std.mem.Allocator, id: []const u8, version: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "hampanel-rt-{s}:cfg{d}", .{ id, version });
}

fn envDir(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, "runtimes", id });
}

fn configDir(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) ![]u8 {
    const dir = try envDir(allocator, data_dir, id);
    return std.fs.path.join(allocator, &.{ dir, "config" });
}

fn configContainerPath(runtime: *const catalog.Runtime, name: []const u8) ?[]const u8 {
    for (runtime.config_files) |config| {
        if (std.mem.eql(u8, config.name, name)) return config.container_path;
    }
    return null;
}

fn updateStatus(database: *db.Db, id: []const u8, status: []const u8) !void {
    try database.execute(
        "UPDATE runtime_environments SET status = ?1, updated_at = ?2 WHERE id = ?3",
        &.{ .{ .text = status }, .{ .int = compat.timestamp() }, .{ .text = id } },
    );
}

fn nameExists(database: *db.Db, name: []const u8) !bool {
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT 1 FROM runtime_environments WHERE name = ?1");
    defer statement.deinit();
    try statement.bind(&.{.{ .text = name }});
    return try statement.step();
}

fn randomId(allocator: std.mem.Allocator) ![]u8 {
    var raw: [8]u8 = undefined;
    compat.randomBytes(&raw);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn encodeExtensions(allocator: std.mem.Allocator, extensions: []const []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, extensions, .{});
}

fn rowToEnvironment(allocator: std.mem.Allocator, statement: *db.Statement) !Environment {
    const extensions_raw = statement.columnText(10);
    const extensions = std.json.parseFromSliceLeaky([]const []const u8, allocator, extensions_raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch &.{};
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0)),
        .name = try allocator.dupe(u8, statement.columnText(1)),
        .runtime = try allocator.dupe(u8, statement.columnText(2)),
        .image = try allocator.dupe(u8, statement.columnText(3)),
        .tag = try allocator.dupe(u8, statement.columnText(4)),
        .status = try allocator.dupe(u8, statement.columnText(5)),
        .port = if (statement.columnIsNull(6)) null else @intCast(statement.columnInt(6)),
        .cpu = if (statement.columnIsNull(7)) null else statement.columnFloat(7),
        .memory_mb = if (statement.columnIsNull(8)) null else @intCast(statement.columnInt(8)),
        .volume = try allocator.dupe(u8, statement.columnText(9)),
        .extensions = extensions,
        .pkg_mirror = try allocator.dupe(u8, statement.columnText(11)),
        .config_version = @intCast(statement.columnInt(12)),
        .created_at = statement.columnInt(13),
        .updated_at = statement.columnInt(14),
    };
}

pub fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 48) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn validImage(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (std.mem.indexOfScalar(u8, "./:_@-", ch) != null) continue;
        return false;
    }
    return true;
}

fn validTag(value: []const u8) bool {
    if (value.len > 128) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (std.mem.indexOfScalar(u8, "._-", ch) != null) continue;
        return false;
    }
    return true;
}

fn validMirror(value: []const u8) bool {
    if (value.len == 0) return true;
    if (catalog.mirrorPreset(value) != null) return true;
    if (std.mem.startsWith(u8, value, "custom:")) {
        const url = value["custom:".len..];
        return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    }
    return false;
}

fn validExtensionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn validProcessName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}

test "runtime validation helpers" {
    try std.testing.expect(validName("node-api_1"));
    try std.testing.expect(!validName("bad name"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(validImage("node"));
    try std.testing.expect(validImage("mcr.microsoft.com/dotnet/aspnet"));
    try std.testing.expect(!validImage("node;rm -rf /"));
    try std.testing.expect(validTag("24-bookworm-slim"));
    try std.testing.expect(!validTag("24 bookworm"));
    try std.testing.expect(validMirror("aliyun"));
    try std.testing.expect(validMirror("custom:https://mirror.example.com"));
    try std.testing.expect(!validMirror("custom:file:///etc"));
    try std.testing.expect(validExtensionId("pdo_mysql"));
    try std.testing.expect(!validExtensionId("a b"));
}
