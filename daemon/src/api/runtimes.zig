const std = @import("std");
const context = @import("context.zig");
const catalog = @import("../runtime/catalog.zig");
const environments = @import("../runtime/environments.zig");
const docker_settings = @import("../runtime/docker_settings.zig");
const exec = @import("shared").exec;

const ExtensionView = struct { id: []const u8, label: []const u8 };
const ConfigView = struct { name: []const u8, container_path: []const u8 };
const RuntimeView = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    image: []const u8,
    tag: []const u8,
    workdir: []const u8,
    web_port: u16,
    recommended_tags: []const []const u8,
    extensions: []const ExtensionView,
    config_files: []const ConfigView,
};
const MirrorView = struct { id: []const u8, label: []const u8 };
const EnvironmentView = struct {
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

pub fn catalogIndex(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    var items = std.array_list.Managed(RuntimeView).init(a);
    for (&catalog.runtimes) |*runtime| {
        var extensions = std.array_list.Managed(ExtensionView).init(a);
        for (runtime.extensions) |extension| {
            try extensions.append(.{ .id = extension.id, .label = extension.label });
        }
        var configs = std.array_list.Managed(ConfigView).init(a);
        for (runtime.config_files) |config| {
            try configs.append(.{ .name = config.name, .container_path = config.container_path });
        }
        try items.append(.{
            .id = runtime.id,
            .name = runtime.name,
            .description = runtime.description,
            .image = runtime.image,
            .tag = runtime.tag,
            .workdir = runtime.workdir,
            .web_port = runtime.web_port,
            .recommended_tags = runtime.recommended_tags,
            .extensions = extensions.items,
            .config_files = configs.items,
        });
    }
    var mirrors = std.array_list.Managed(MirrorView).init(a);
    for (&catalog.mirror_presets) |*preset| {
        try mirrors.append(.{ .id = preset.id, .label = preset.label });
    }
    try ctx.json(.{ .runtimes = items.items, .mirrors = mirrors.items });
}

pub fn tags(ctx: *context.Context) anyerror!void {
    const id = ctx.param("runtime") orelse {
        ctx.fail(400, "bad_runtime", "missing runtime");
        return;
    };
    const runtime = catalog.find(id) orelse {
        ctx.fail(404, "not_found", "unknown runtime");
        return;
    };
    const repo = runtime.docker_repo orelse {
        try ctx.json(.{ .tags = runtime.recommended_tags, .source = "recommended" });
        return;
    };
    const url = try std.fmt.allocPrint(
        ctx.arena,
        "https://hub.docker.com/v2/repositories/{s}/tags?page_size=50&ordering=last_updated",
        .{repo},
    );
    const result = exec.run(ctx.arena, &.{
        "curl", "-fsSL",                 "--retry", "2", "--connect-timeout", "10", "--max-time", "20",
        "-H",   "User-Agent: hampaneld", url,
    }, 2 * 1024 * 1024) catch {
        try ctx.json(.{ .tags = runtime.recommended_tags, .source = "recommended", .error_message = "registry request failed" });
        return;
    };
    if (!result.ok()) {
        try ctx.json(.{ .tags = runtime.recommended_tags, .source = "recommended", .error_message = "registry request failed" });
        return;
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        try ctx.json(.{ .tags = runtime.recommended_tags, .source = "recommended", .error_message = "invalid registry response" });
        return;
    };
    var names = std.array_list.Managed([]const u8).init(ctx.arena);
    if (value == .object) {
        if (value.object.get("results")) |results| {
            if (results == .array) {
                for (results.array.items) |item| {
                    if (item == .object) {
                        if (item.object.get("name")) |name| {
                            if (name == .string) try names.append(name.string);
                        }
                    }
                }
            }
        }
    }
    if (names.items.len == 0) {
        try ctx.json(.{ .tags = runtime.recommended_tags, .source = "recommended" });
        return;
    }
    try ctx.json(.{ .tags = names.items, .source = "registry" });
}

pub fn index(ctx: *context.Context) anyerror!void {
    const list = environments.list(ctx.arena, ctx.app.db) catch |err| {
        ctx.fail(500, "db_failed", @errorName(err));
        return;
    };
    var items = std.array_list.Managed(EnvironmentView).init(ctx.arena);
    for (list) |environment| {
        const status = environments.liveStatus(ctx.arena, ctx.app.db, environment.id) catch environment.status;
        try items.append(viewOf(environment, status));
    }
    try ctx.json(.{ .environments = items.items });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
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
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name and runtime");
        return;
    };
    const result = environments.create(ctx.arena, ctx.app.db, ctx.app.config.data_dir, .{
        .name = body.name,
        .runtime = body.runtime,
        .image = body.image,
        .tag = body.tag,
        .port = body.port,
        .cpu = body.cpu,
        .memory_mb = body.memory_mb,
        .extensions = body.extensions,
        .pkg_mirror = body.pkg_mirror,
    }) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!result.ok) ctx.response.status = 502;
    try ctx.json(.{
        .ok = result.ok,
        .output = result.output,
        .environment = viewOf(result.environment, result.environment.status),
    });
}

pub fn start(ctx: *context.Context) anyerror!void {
    try action(ctx, "start");
}
pub fn stop(ctx: *context.Context) anyerror!void {
    try action(ctx, "stop");
}
pub fn restart(ctx: *context.Context) anyerror!void {
    try action(ctx, "restart");
}

fn action(ctx: *context.Context, name: []const u8) !void {
    const id = requireId(ctx) orelse return;
    const outcome = switch (name[0]) {
        's' => if (std.mem.eql(u8, name, "start"))
            environments.start(ctx.arena, ctx.app.db, id) catch |err| {
                failRuntime(ctx, err);
                return;
            }
        else
            environments.stop(ctx.arena, ctx.app.db, id) catch |err| {
                failRuntime(ctx, err);
                return;
            },
        'r' => environments.restart(ctx.arena, ctx.app.db, id) catch |err| {
            failRuntime(ctx, err);
            return;
        },
        else => unreachable,
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn rebuild(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const outcome = environments.rebuild(ctx.arena, ctx.app.db, ctx.app.config.data_dir, id) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn remove(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    var volumes = false;
    if (try ctx.query("volumes")) |raw| {
        volumes = std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1");
    }
    const outcome = environments.remove(ctx.arena, ctx.app.db, id, volumes) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .removed = outcome.ok, .output = outcome.output });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }
    const outcome = environments.logs(ctx.arena, ctx.app.db, id, lines) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn configIndex(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const files = environments.configList(ctx.arena, ctx.app.db, id) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    try ctx.json(.{ .files = files });
}

pub fn configSave(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const Body = struct { file: []const u8, content: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected file and content");
        return;
    };
    if (body.file.len == 0 or body.file.len > 128 or body.content.len > 1024 * 1024) {
        ctx.fail(400, "bad_request", "invalid file or content size");
        return;
    }
    if (std.mem.indexOfScalar(u8, body.content, 0) != null) {
        ctx.fail(400, "bad_content", "content must not contain NUL");
        return;
    }
    const outcome = environments.configSave(
        ctx.arena,
        ctx.app.db,
        ctx.app.config.data_dir,
        id,
        body.file,
        body.content,
    ) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn extensionsIndex(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const environment = (environments.get(ctx.arena, ctx.app.db, id) catch |err| {
        failRuntime(ctx, err);
        return;
    }) orelse {
        ctx.fail(404, "not_found", "environment not found");
        return;
    };
    try ctx.json(.{ .extensions = environment.extensions, .runtime = environment.runtime });
}

pub fn extensionsSave(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const Body = struct { extensions: []const []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected extensions");
        return;
    };
    const outcome = environments.extensionsSet(
        ctx.arena,
        ctx.app.db,
        ctx.app.config.data_dir,
        id,
        body.extensions,
    ) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn processesIndex(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const outcome = environments.processes(ctx.arena, ctx.app.db, id) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn processAction(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_process", "missing process name");
        return;
    };
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };
    const outcome = environments.processAction(
        ctx.arena,
        ctx.app.db,
        id,
        name,
        action_name,
    ) catch |err| {
        failRuntime(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn dockerSettings(ctx: *context.Context) anyerror!void {
    const settings = docker_settings.read(ctx.arena) catch |err| {
        ctx.fail(500, "docker_settings_failed", @errorName(err));
        return;
    };
    const stored = ctx.app.db.getSetting(ctx.arena, "docker.settings") catch null;
    try ctx.json(.{
        .path = docker_settings.configPath(),
        .settings = settings,
        .registry_mirrors = settings.registry_mirrors,
        .ipv6 = settings.ipv6,
        .experimental = settings.experimental,
        .fixed_cidr_v6 = settings.fixed_cidr_v6,
        .snapshot = stored,
    });
}

pub fn dockerSettingsSave(ctx: *context.Context) anyerror!void {
    const Body = struct {
        registry_mirrors: []const []const u8 = &.{},
        ipv6: bool = false,
        experimental: bool = false,
        fixed_cidr_v6: []const u8 = "",
        restart: bool = true,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected docker settings");
        return;
    };
    const settings = docker_settings.Settings{
        .registry_mirrors = body.registry_mirrors,
        .ipv6 = body.ipv6,
        .experimental = body.experimental,
        .fixed_cidr_v6 = body.fixed_cidr_v6,
    };
    const outcome = docker_settings.apply(ctx.arena, settings, body.restart) catch |err| {
        if (err == error.InvalidMirror or err == error.InvalidCidr) {
            ctx.fail(400, "bad_settings", @errorName(err));
        } else {
            ctx.fail(500, "docker_settings_failed", @errorName(err));
        }
        return;
    };
    const snapshot = std.json.Stringify.valueAlloc(ctx.arena, body, .{}) catch "";
    ctx.app.db.setSetting("docker.settings", snapshot) catch {};
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(.{
        .ok = outcome.ok,
        .output = outcome.output,
        .restart_required = outcome.restart_required,
    });
}

fn requireId(ctx: *context.Context) ?[]const u8 {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing environment id");
        return null;
    };
    if (id.len == 0 or id.len > 64) {
        ctx.fail(400, "bad_id", "invalid environment id");
        return null;
    }
    return id;
}

fn viewOf(environment: environments.Environment, status: []const u8) EnvironmentView {
    return .{
        .id = environment.id,
        .name = environment.name,
        .runtime = environment.runtime,
        .image = environment.image,
        .tag = environment.tag,
        .status = status,
        .port = environment.port,
        .cpu = environment.cpu,
        .memory_mb = environment.memory_mb,
        .volume = environment.volume,
        .extensions = environment.extensions,
        .pkg_mirror = environment.pkg_mirror,
        .config_version = environment.config_version,
        .created_at = environment.created_at,
        .updated_at = environment.updated_at,
    };
}

fn failRuntime(ctx: *context.Context, err: anyerror) void {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "NotFound")) {
        ctx.fail(404, "not_found", "environment not found");
    } else if (std.mem.eql(u8, name, "NameExists")) {
        ctx.fail(409, "name_exists", "environment name already exists");
    } else if (std.mem.eql(u8, name, "UnknownRuntime")) {
        ctx.fail(400, "bad_runtime", "unknown runtime");
    } else if (std.mem.eql(u8, name, "InvalidName") or std.mem.eql(u8, name, "InvalidImage") or
        std.mem.eql(u8, name, "InvalidTag") or std.mem.eql(u8, name, "InvalidPort") or
        std.mem.eql(u8, name, "InvalidCpu") or std.mem.eql(u8, name, "InvalidMemory") or
        std.mem.eql(u8, name, "InvalidExtension") or std.mem.eql(u8, name, "InvalidMirror") or
        std.mem.eql(u8, name, "ImageRequired"))
    {
        ctx.fail(400, "bad_request", name);
    } else if (std.mem.eql(u8, name, "ConfigNotFound")) {
        ctx.fail(404, "config_not_found", "config file not found");
    } else if (std.mem.eql(u8, name, "InvalidProcess")) {
        ctx.fail(400, "bad_process", "invalid process name");
    } else if (std.mem.eql(u8, name, "InvalidAction")) {
        ctx.fail(400, "bad_action", "unsupported process action");
    } else {
        ctx.fail(502, "runtime_failed", name);
    }
}
