const std = @import("std");
const context = @import("context.zig");
const catalog = @import("../store/catalog.zig");
const store = @import("../store/apps.zig");
const engine_mod = @import("../runtime/engine.zig");
const platform = @import("../platform/mod.zig");
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

const AppView = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    category: []const u8,
    icon: []const u8,
    installed: bool,
    running: bool,
    params: []const catalog.Param,
};

const ProjectHealth = struct {
    running: bool = false,
    stopped: bool = false,
};

pub fn apps(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    const engine_ctx = engineContext(ctx);
    var health = if (engine_ctx) |value|
        composeHealth(ctx, value.engine, value.socket) catch
            std.StringHashMap(ProjectHealth).init(ctx.arena)
    else
        std.StringHashMap(ProjectHealth).init(ctx.arena);

    var items = std.array_list.Managed(AppView).init(ctx.arena);
    for (&catalog.apps) |*app| {
        const project = try std.fmt.allocPrint(ctx.arena, "hampanel-{s}", .{app.slug});
        const state = health.get(project);
        try items.append(view(ctx.arena, data_dir, app, projectRunning(state)));
    }
    try ctx.json(.{ .apps = items.items });
}

/// One `ps` call annotates every installed app. A compose app counts as
/// running when it has a running container and none of its containers is
/// stopped or restarting.
fn composeHealth(
    ctx: *context.Context,
    engine: engine_mod.Engine,
    socket: []const u8,
) !std.StringHashMap(ProjectHealth) {
    const health = std.StringHashMap(ProjectHealth).init(ctx.arena);
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name,
        "ps",
        "-a",
        "--format",
        "{{.Label \"com.docker.compose.project\"}}\t{{.State}}",
    }, .{ .max_output = 4 * 1024 * 1024 }) catch return health;
    if (!result.ok()) return health;
    return parseComposeHealth(ctx.arena, result.stdout);
}

/// A compose app is running only when every container of its project is up.
fn projectRunning(state: ?ProjectHealth) bool {
    const value = state orelse return false;
    return value.running and !value.stopped;
}

fn parseComposeHealth(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !std.StringHashMap(ProjectHealth) {
    var health = std.StringHashMap(ProjectHealth).init(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const project = std.mem.trim(u8, line[0..tab], " \r");
        if (project.len == 0) continue;
        const state = std.mem.trim(u8, line[tab + 1 ..], " \r");
        const entry = try health.getOrPut(project);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (std.mem.eql(u8, state, "running")) {
            entry.value_ptr.running = true;
        } else {
            entry.value_ptr.stopped = true;
        }
    }
    return health;
}

test "compose health marks partially stopped projects" {
    const raw =
        "hampanel-redis\trunning\n" ++
        "hampanel-gitea\trunning\n" ++
        "hampanel-gitea\texited\n" ++
        "hampanel-minio\texited\n" ++
        "\trunning\n";
    var health = try parseComposeHealth(std.testing.allocator, raw);
    defer health.deinit();

    try std.testing.expect(projectRunning(health.get("hampanel-redis")));
    try std.testing.expect(!projectRunning(health.get("hampanel-gitea")));
    try std.testing.expect(health.get("hampanel-gitea").?.running);
    try std.testing.expect(health.get("hampanel-gitea").?.stopped);
    try std.testing.expect(!projectRunning(health.get("hampanel-minio")));
    try std.testing.expect(!projectRunning(health.get("hampanel-absent")));
}

pub fn appDetail(ctx: *context.Context) anyerror!void {
    const slug = ctx.param("slug") orelse {
        ctx.fail(400, "bad_slug", "missing app slug");
        return;
    };
    const app = catalog.find(slug) orelse {
        ctx.fail(404, "not_found", "app not found");
        return;
    };

    const engine_ctx = engineContext(ctx);
    const status = if (engine_ctx) |value|
        store.status(ctx.arena, value.engine, value.socket, ctx.app.config.data_dir, app) catch null
    else
        null;
    var running = false;
    if (engine_ctx) |value| {
        var health = composeHealth(ctx, value.engine, value.socket) catch null;
        if (health) |*map| {
            const project = try std.fmt.allocPrint(ctx.arena, "hampanel-{s}", .{app.slug});
            running = projectRunning(map.get(project));
        }
    }
    try ctx.json(.{
        .app = view(ctx.arena, ctx.app.config.data_dir, app, running),
        .status = if (status) |value| value.output else "",
        .running = running,
    });
}

pub fn deploy(ctx: *context.Context) anyerror!void {
    const app = try requireApp(ctx);
    const data_dir = ctx.app.config.data_dir;

    var values = std.StringHashMap([]const u8).init(ctx.arena);
    if (ctx.req.body.len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, ctx.req.body, .{}) catch {
            ctx.fail(400, "bad_params", "params must be a JSON object");
            return;
        };
        if (root == .object) {
            if (root.object.get("params")) |params_value| {
                if (params_value != .object) {
                    ctx.fail(400, "bad_params", "params must be a JSON object");
                    return;
                }
                var iterator = params_value.object.iterator();
                while (iterator.next()) |entry| {
                    const value = entry.value_ptr.*;
                    if (value != .string) {
                        ctx.fail(400, "bad_params", "param values must be strings");
                        return;
                    }
                    try values.put(entry.key_ptr.*, value.string);
                }
            }
        }
    }

    const engine_ctx = engineContext(ctx) orelse {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    const result = store.deploy(
        ctx.arena,
        engine_ctx.engine,
        engine_ctx.socket,
        data_dir,
        app,
        &values,
    ) catch |err| {
        failStore(ctx, err);
        return;
    };

    if (!result.ok) ctx.response.status = 502;
    // Deployment params can carry passwords and API keys; they are never logged.
    if (result.ok) {
        log.info("store: deployed slug={s}", .{app.slug});
    } else {
        log.warn("store: deploy failed slug={s}", .{app.slug});
    }
    try ctx.json(.{
        .ok = result.ok,
        .output = result.output,
        .path = result.path,
        .params = result.params,
    });
}

pub fn start(ctx: *context.Context) anyerror!void {
    try simpleAction(ctx, true);
}

pub fn stop(ctx: *context.Context) anyerror!void {
    try simpleAction(ctx, false);
}

fn simpleAction(ctx: *context.Context, start_app: bool) !void {
    const app = try requireApp(ctx);
    const data_dir = ctx.app.config.data_dir;
    const engine_ctx = engineContext(ctx) orelse {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    const outcome = if (start_app)
        store.start(ctx.arena, engine_ctx.engine, engine_ctx.socket, data_dir, app) catch |err| {
            failStore(ctx, err);
            return;
        }
    else
        store.stop(ctx.arena, engine_ctx.engine, engine_ctx.socket, data_dir, app) catch |err| {
            failStore(ctx, err);
            return;
        };

    if (!outcome.ok) ctx.response.status = 502;
    if (outcome.ok) {
        log.info("store: {s} slug={s}", .{ if (start_app) "started" else "stopped", app.slug });
    } else {
        log.warn("store: {s} failed slug={s}", .{ if (start_app) "start" else "stop", app.slug });
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const app = try requireApp(ctx);
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    const engine_ctx = engineContext(ctx) orelse {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    const outcome = store.logs(
        ctx.arena,
        engine_ctx.engine,
        engine_ctx.socket,
        ctx.app.config.data_dir,
        app,
        lines,
    ) catch |err| {
        failStore(ctx, err);
        return;
    };
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn remove(ctx: *context.Context) anyerror!void {
    const app = try requireApp(ctx);
    var volumes = false;
    if (try ctx.query("volumes")) |raw| {
        volumes = std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1");
    }

    const engine_ctx = engineContext(ctx) orelse {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    const outcome = store.remove(
        ctx.arena,
        engine_ctx.engine,
        engine_ctx.socket,
        ctx.app.config.data_dir,
        app,
        volumes,
    ) catch |err| {
        failStore(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    if (outcome.ok) {
        log.info("store: removed slug={s} volumes={}", .{ app.slug, volumes });
    } else {
        log.warn("store: remove failed slug={s}", .{app.slug});
    }
    try ctx.json(.{ .ok = outcome.ok, .removed = outcome.ok, .output = outcome.output });
}

pub fn packages(ctx: *context.Context) anyerror!void {
    const status = platform.packages.list(ctx.arena) catch |err| {
        if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "package management is not available on this platform");
        } else {
            ctx.fail(500, "packages_failed", @errorName(err));
        }
        return;
    };
    try ctx.json(status);
}

pub fn installPackage(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing tool id");
        return;
    };
    const outcome = platform.packages.install(ctx.arena, id) catch |err| {
        failPackage(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("store: package install id={s} ok={}", .{ id, outcome.ok });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn installCustom(ctx: *context.Context) anyerror!void {
    const Body = struct { name: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected package name");
        return;
    };
    const outcome = platform.packages.installCustom(ctx.arena, body.name) catch |err| {
        if (errutil.named(err, "InvalidPackage")) {
            ctx.fail(400, "bad_package", "包名不合法");
        } else {
            failPackage(ctx, err);
        }
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    var name_buf: [96]u8 = undefined;
    log.info("store: custom package install name={s} ok={}", .{
        redact.text(&name_buf, body.name),
        outcome.ok,
    });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn refreshPackages(ctx: *context.Context) anyerror!void {
    const outcome = platform.packages.refresh(ctx.arena) catch |err| {
        failPackage(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("store: package index refreshed ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn nixStatus(ctx: *context.Context) anyerror!void {
    const status = platform.nix.status(ctx.arena) catch |err| {
        if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "Nix is not available on this platform");
        } else {
            ctx.fail(500, "nix_failed", @errorName(err));
        }
        return;
    };
    try ctx.json(status);
}

pub fn nixBuild(ctx: *context.Context) anyerror!void {
    const Body = struct {
        target: []const u8,
        substituters: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected target");
        return;
    };
    if (!validSubstituters(body.substituters)) {
        ctx.fail(400, "bad_substituters", "substituters must be http(s) URLs");
        return;
    }
    const outcome = platform.nix.build(ctx.arena, body.target, body.substituters) catch |err| {
        failNix(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("nix: build target={s} custom_mirror={} ok={}", .{
        body.target,
        body.substituters.len > 0,
        outcome.ok,
    });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn nixRun(ctx: *context.Context) anyerror!void {
    const Body = struct {
        target: []const u8,
        args: []const []const u8 = &.{},
        substituters: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected target");
        return;
    };
    if (!validSubstituters(body.substituters)) {
        ctx.fail(400, "bad_substituters", "substituters must be http(s) URLs");
        return;
    }
    const outcome = platform.nix.run(
        ctx.arena,
        body.target,
        body.args,
        body.substituters,
    ) catch |err| {
        failNix(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("nix: run target={s} args={d} custom_mirror={} ok={}", .{
        body.target,
        body.args.len,
        body.substituters.len > 0,
        outcome.ok,
    });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn validSubstituters(value: []const u8) bool {
    if (value.len > 2048) return false;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        count += 1;
        if (count > 16) return false;
        if (!(std.mem.startsWith(u8, token, "https://") or
            std.mem.startsWith(u8, token, "http://"))) return false;
        for (token) |ch| {
            if (ch < 0x21 or ch == 0x7f) return false;
        }
    }
    return true;
}

const EngineContext = struct {
    engine: engine_mod.Engine,
    socket: []const u8,
};

fn engineContext(ctx: *context.Context) ?EngineContext {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch return null;
    return .{ .engine = engine, .socket = socket };
}

fn view(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    app: *const catalog.App,
    running: bool,
) AppView {
    return .{
        .slug = app.slug,
        .name = app.name,
        .description = app.description,
        .category = app.category,
        .icon = app.icon,
        .installed = store.installed(allocator, data_dir, app),
        .running = running,
        .params = app.params,
    };
}

fn requireApp(ctx: *context.Context) !*const catalog.App {
    const slug = ctx.param("slug") orelse {
        ctx.fail(400, "bad_slug", "missing app slug");
        return error.BadSlug;
    };
    return catalog.find(slug) orelse {
        ctx.fail(404, "not_found", "app not found");
        return error.NotFound;
    };
}

fn failStore(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidParam") or errutil.named(err, "MissingParam") or errutil.named(err, "TemplateError")) {
        ctx.fail(400, "bad_params", "invalid or missing parameter");
    } else if (errutil.named(err, "NotInstalled")) {
        ctx.fail(404, "not_installed", "app is not installed");
    } else if (errutil.named(err, "ComposeUnavailable")) {
        ctx.fail(502, "compose_unavailable", "compose provider is not available; install podman-compose (Podman) or docker compose (Docker)");
    } else {
        ctx.fail(500, "store_failed", @errorName(err));
    }
}

fn failPackage(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "UnknownTool")) {
        ctx.fail(404, "unknown_tool", "unknown tool");
    } else if (errutil.named(err, "ManagerUnavailable")) {
        ctx.fail(501, "manager_unavailable", "no supported package manager detected");
    } else if (errutil.isUnsupported(err)) {
        ctx.fail(501, "unsupported", "package management is not available on this platform");
    } else {
        ctx.fail(500, "packages_failed", @errorName(err));
    }
}

fn failNix(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidTarget")) {
        ctx.fail(400, "bad_target", "target is not in the curated Nix catalog");
    } else if (errutil.named(err, "NixUnavailable")) {
        ctx.fail(502, "nix_unavailable", "nix is not available");
    } else if (errutil.isUnsupported(err)) {
        ctx.fail(501, "unsupported", "Nix is not available on this platform");
    } else {
        ctx.fail(500, "nix_failed", @errorName(err));
    }
}
