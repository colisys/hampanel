const std = @import("std");
const context = @import("context.zig");
const catalog = @import("../store/catalog.zig");
const store = @import("../store/apps.zig");
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
    params: []const catalog.Param,
};

pub fn apps(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    var items = std.array_list.Managed(AppView).init(ctx.arena);
    for (&catalog.apps) |*app| {
        try items.append(view(ctx.arena, data_dir, app));
    }
    try ctx.json(.{ .apps = items.items });
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

    const status = store.status(ctx.arena, ctx.app.config.data_dir, app) catch null;
    try ctx.json(.{
        .app = view(ctx.arena, ctx.app.config.data_dir, app),
        .status = if (status) |value| value.output else "",
        .running = if (status) |value| std.mem.indexOf(u8, value.output, "Up ") != null else false,
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

    const result = store.deploy(ctx.arena, data_dir, app, &values) catch |err| {
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
    const outcome = if (start_app)
        store.start(ctx.arena, data_dir, app) catch |err| {
            failStore(ctx, err);
            return;
        }
    else
        store.stop(ctx.arena, data_dir, app) catch |err| {
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

    const outcome = store.logs(ctx.arena, ctx.app.config.data_dir, app, lines) catch |err| {
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

    const outcome = store.remove(ctx.arena, ctx.app.config.data_dir, app, volumes) catch |err| {
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
    const Body = struct { target: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected target");
        return;
    };
    const outcome = platform.nix.build(ctx.arena, body.target) catch |err| {
        failNix(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("nix: build target={s} ok={}", .{ body.target, outcome.ok });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn nixRun(ctx: *context.Context) anyerror!void {
    const Body = struct {
        target: []const u8,
        args: []const []const u8 = &.{},
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected target");
        return;
    };
    const outcome = platform.nix.run(ctx.arena, body.target, body.args) catch |err| {
        failNix(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("nix: run target={s} args={d} ok={}", .{ body.target, body.args.len, outcome.ok });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn view(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) AppView {
    return .{
        .slug = app.slug,
        .name = app.name,
        .description = app.description,
        .category = app.category,
        .icon = app.icon,
        .installed = store.installed(allocator, data_dir, app),
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
        ctx.fail(502, "compose_unavailable", "docker compose is not available");
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
