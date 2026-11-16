const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 1024 * 1024;

pub const Registry = struct {
    id: []const u8,
    engine: []const u8,
    name: []const u8,
    protocol: []const u8,
    host: []const u8,
    username: []const u8,
    secret: []const u8,
    last_sync_at: ?i64 = null,
    last_sync_ok: ?bool = null,
    last_sync_message: []const u8 = "",
};

pub fn index(ctx: *context.Context) anyerror!void {
    const View = struct {
        id: []const u8,
        engine: []const u8,
        name: []const u8,
        protocol: []const u8,
        host: []const u8,
        username: []const u8,
        has_secret: bool,
        last_sync_at: ?i64,
        last_sync_ok: ?bool,
        last_sync_message: []const u8,
    };
    var list = std.array_list.Managed(View).init(ctx.arena);
    const database = ctx.app.db;
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT id, engine, name, protocol, host, username, secret, last_sync_at, last_sync_ok, last_sync_message " ++
            "FROM docker_registries ORDER BY name",
    );
    defer statement.deinit();
    while (try statement.step()) {
        try list.append(.{
            .id = try statement.dupeColumnText(ctx.arena, 0),
            .engine = try statement.dupeColumnText(ctx.arena, 1),
            .name = try statement.dupeColumnText(ctx.arena, 2),
            .protocol = try statement.dupeColumnText(ctx.arena, 3),
            .host = try statement.dupeColumnText(ctx.arena, 4),
            .username = try statement.dupeColumnText(ctx.arena, 5),
            .has_secret = statement.columnText(6).len > 0,
            .last_sync_at = if (statement.columnIsNull(7)) null else statement.columnInt(7),
            .last_sync_ok = if (statement.columnIsNull(8)) null else statement.columnInt(8) != 0,
            .last_sync_message = try statement.dupeColumnText(ctx.arena, 9),
        });
    }
    try ctx.json(.{ .registries = list.items });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        engine: []const u8 = "docker",
        name: []const u8,
        protocol: []const u8 = "https",
        host: []const u8,
        username: []const u8 = "",
        secret: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected registry fields");
        return;
    };
    if (!validBody(ctx, body)) return;
    var random: [8]u8 = undefined;
    compat.randomBytes(&random);
    const id = try std.fmt.allocPrint(ctx.arena, "{s}", .{std.fmt.bytesToHex(random, .lower)});
    ctx.app.db.execute(
        "INSERT INTO docker_registries(id, engine, name, protocol, host, username, secret, created_at, updated_at) " ++
            "VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        &.{
            .{ .text = id },
            .{ .text = body.engine },
            .{ .text = body.name },
            .{ .text = body.protocol },
            .{ .text = body.host },
            .{ .text = body.username },
            .{ .text = body.secret },
            .{ .int = compat.timestamp() },
            .{ .int = compat.timestamp() },
        },
    ) catch |err| {
        ctx.fail(500, "db_failed", @errorName(err));
        return;
    };
    log.info("docker: registry source added name={s}", .{body.name});
    try ctx.jsonStatus(201, .{ .ok = true, .id = id });
}

pub fn update(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const existing = (try load(ctx, id)) orelse {
        ctx.fail(404, "not_found", "registry not found");
        return;
    };
    const Body = struct {
        engine: []const u8 = "",
        name: []const u8 = "",
        protocol: []const u8 = "",
        host: []const u8 = "",
        username: []const u8 = "",
        secret: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected registry fields");
        return;
    };
    const merged = struct {
        engine: []const u8,
        name: []const u8,
        protocol: []const u8,
        host: []const u8,
        username: []const u8,
        secret: []const u8,
    }{
        .engine = if (body.engine.len > 0) body.engine else existing.engine,
        .name = if (body.name.len > 0) body.name else existing.name,
        .protocol = if (body.protocol.len > 0) body.protocol else existing.protocol,
        .host = if (body.host.len > 0) body.host else existing.host,
        .username = body.username,
        .secret = if (body.secret.len > 0) body.secret else existing.secret,
    };
    if (!validBody(ctx, merged)) return;
    try ctx.app.db.execute(
        "UPDATE docker_registries SET engine=?1, name=?2, protocol=?3, host=?4, username=?5, secret=?6, updated_at=?7 WHERE id=?8",
        &.{
            .{ .text = merged.engine },
            .{ .text = merged.name },
            .{ .text = merged.protocol },
            .{ .text = merged.host },
            .{ .text = merged.username },
            .{ .text = merged.secret },
            .{ .int = compat.timestamp() },
            .{ .text = id },
        },
    );
    try ctx.json(.{ .ok = true, .id = id });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    try ctx.app.db.execute(
        "DELETE FROM docker_registries WHERE id = ?1",
        &.{.{ .text = id }},
    );
    try ctx.json(.{ .ok = true, .id = id });
}

pub fn sync(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const record = (try load(ctx, id)) orelse {
        ctx.fail(404, "not_found", "registry not found");
        return;
    };
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    if (record.username.len == 0 or record.secret.len == 0) {
        ctx.fail(400, "missing_credentials", "同步需要用户名和密码");
        return;
    }
    const result = login(ctx, engine, socket, record) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute engine login");
        return;
    };
    const ok = result.ok();
    const message = if (ok) "" else textOf(result);
    try ctx.app.db.execute(
        "UPDATE docker_registries SET last_sync_at=?1, last_sync_ok=?2, last_sync_message=?3, updated_at=?4 WHERE id=?5",
        &.{
            .{ .int = compat.timestamp() },
            .{ .int = if (ok) 1 else 0 },
            .{ .text = message },
            .{ .int = compat.timestamp() },
            .{ .text = id },
        },
    );
    try ctx.json(.{ .ok = ok, .output = message, .id = id });
}

pub fn find(ctx: *context.Context, id: []const u8) !?Registry {
    return load(ctx, id);
}

pub fn loginById(
    ctx: *context.Context,
    engine: engine_mod.Engine,
    socket: []const u8,
    id: []const u8,
) !bool {
    const record = (try load(ctx, id)) orelse return false;
    if (record.username.len == 0 or record.secret.len == 0) return false;
    const result = try login(ctx, engine, socket, record);
    return result.ok();
}

fn login(
    ctx: *context.Context,
    engine: engine_mod.Engine,
    socket: []const u8,
    record: Registry,
) !exec.Result {
    return engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "login", record.host, "-u", record.username, "--password-stdin",
    }, .{ .stdin = record.secret, .max_output = max_output });
}

fn load(ctx: *context.Context, id: []const u8) !?Registry {
    const database = ctx.app.db;
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT id, engine, name, protocol, host, username, secret, last_sync_at, last_sync_ok, last_sync_message " ++
            "FROM docker_registries WHERE id = ?1",
    );
    defer statement.deinit();
    try statement.bind(&.{.{ .text = id }});
    if (!(try statement.step())) return null;
    return .{
        .id = try statement.dupeColumnText(ctx.arena, 0),
        .engine = try statement.dupeColumnText(ctx.arena, 1),
        .name = try statement.dupeColumnText(ctx.arena, 2),
        .protocol = try statement.dupeColumnText(ctx.arena, 3),
        .host = try statement.dupeColumnText(ctx.arena, 4),
        .username = try statement.dupeColumnText(ctx.arena, 5),
        .secret = try statement.dupeColumnText(ctx.arena, 6),
        .last_sync_at = if (statement.columnIsNull(7)) null else statement.columnInt(7),
        .last_sync_ok = if (statement.columnIsNull(8)) null else statement.columnInt(8) != 0,
        .last_sync_message = try statement.dupeColumnText(ctx.arena, 9),
    };
}

fn validBody(ctx: *context.Context, body: anytype) bool {
    if (!std.mem.eql(u8, body.engine, "docker") and
        !std.mem.eql(u8, body.engine, "podman") and
        !std.mem.eql(u8, body.engine, "both"))
    {
        ctx.fail(400, "bad_engine", "engine must be docker, podman or both");
        return false;
    }
    if (!std.mem.eql(u8, body.protocol, "https") and !std.mem.eql(u8, body.protocol, "http")) {
        ctx.fail(400, "bad_protocol", "protocol must be https or http");
        return false;
    }
    if (body.name.len == 0 or body.name.len > 128 or !safeText(body.name)) {
        ctx.fail(400, "bad_name", "invalid registry name");
        return false;
    }
    if (!validate.isRegistryHost(body.host)) {
        ctx.fail(400, "bad_host", "invalid registry host");
        return false;
    }
    if (body.username.len > 256 or !safeText(body.username)) {
        ctx.fail(400, "bad_username", "invalid registry username");
        return false;
    }
    if (body.secret.len > 4096 or std.mem.indexOfScalar(u8, body.secret, 0) != null) {
        ctx.fail(400, "bad_secret", "invalid registry secret");
        return false;
    }
    return true;
}

fn safeText(value: []const u8) bool {
    for (value) |ch| {
        if (ch < 0x20 and ch != '\t') return false;
    }
    return true;
}

fn requireId(ctx: *context.Context) ?[]const u8 {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing registry id");
        return null;
    };
    if (id.len == 0 or id.len > 64) {
        ctx.fail(400, "bad_id", "invalid registry id");
        return null;
    }
    return id;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
