const std = @import("std");
const context = @import("context.zig");
const notify = @import("../notify.zig");
const exec = @import("shared").exec;
const validate = @import("shared").validate;
const log = @import("../log.zig");

const max_output = 8 * 1024 * 1024;

const Engine = struct {
    name: []const u8,
    podman: bool,
};

/// Prefer Docker, fall back to Podman, whose CLI is Docker-compatible for the
/// commands this panel runs. The result is cached per request arena.
fn detectEngine(allocator: std.mem.Allocator) !Engine {
    const candidates = [_][]const u8{ "docker", "podman" };
    for (candidates) |name| {
        const result = exec.run(allocator, &.{ name, "version", "--format", "{{.Client.Version}}" }, 64 * 1024) catch continue;
        if (result.ok()) return .{ .name = name, .podman = std.mem.eql(u8, name, "podman") };
    }
    return error.EngineUnavailable;
}

fn unavailable(ctx: *context.Context) void {
    ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
}

const Container = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    state: []const u8,
    status: []const u8,
    ports: []const u8,
    created_at: []const u8,
};

const Image = struct {
    id: []const u8,
    repository: []const u8,
    tag: []const u8,
    size: []const u8,
    created_at: []const u8,
};

pub fn containers(ctx: *context.Context) anyerror!void {
    const engine = detectEngine(ctx.arena) catch {
        unavailable(ctx);
        return;
    };
    const result = exec.run(ctx.arena, &.{
        engine.name, "ps", "-a", "--no-trunc", "--format", "{{json .}}",
    }, max_output) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }

    var items = std.array_list.Managed(Container).init(ctx.arena);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, trimmed, .{}) catch continue;
        if (value != .object) continue;
        try items.append(.{
            .id = stringField(value, "ID"),
            .name = stringField(value, "Names"),
            .image = stringField(value, "Image"),
            .state = stringField(value, "State"),
            .status = stringField(value, "Status"),
            .ports = stringField(value, "Ports"),
            .created_at = stringField(value, "CreatedAt"),
        });
    }

    try ctx.json(.{
        .available = true,
        .engine = engine.name,
        .podman = engine.podman,
        .containers = items.items,
    });
}

pub fn images(ctx: *context.Context) anyerror!void {
    const engine = detectEngine(ctx.arena) catch {
        unavailable(ctx);
        return;
    };
    const result = exec.run(ctx.arena, &.{
        engine.name, "images", "--format", "{{json .}}",
    }, max_output) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }

    var items = std.array_list.Managed(Image).init(ctx.arena);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, trimmed, .{}) catch continue;
        if (value != .object) continue;
        try items.append(.{
            .id = stringField(value, "ID"),
            .repository = stringField(value, "Repository"),
            .tag = stringField(value, "Tag"),
            .size = stringField(value, "Size"),
            .created_at = stringField(value, "CreatedSince"),
        });
    }

    try ctx.json(.{
        .available = true,
        .engine = engine.name,
        .podman = engine.podman,
        .images = items.items,
    });
}

pub fn action(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return;
    };
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return;
    }

    const allowed = [_][]const u8{ "start", "stop", "restart", "pause", "unpause", "rm" };
    var valid = false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, action_name, candidate)) valid = true;
    }
    if (!valid) {
        ctx.fail(400, "bad_action", "unsupported action");
        return;
    }

    const engine = detectEngine(ctx.arena) catch {
        unavailable(ctx);
        return;
    };
    const argv = if (std.mem.eql(u8, action_name, "rm"))
        &[_][]const u8{ engine.name, "rm", "-f", id }
    else
        &[_][]const u8{ engine.name, action_name, id };

    const result = exec.run(ctx.arena, argv, 1024 * 1024) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };

    const Body = struct {
        id: []const u8,
        action: []const u8,
        ok: bool,
        output: []const u8,
    };
    if (!result.ok()) ctx.response.status = 502;
    if (result.ok()) {
        log.info("docker: {s} container={s}", .{ action_name, id });
    } else {
        log.warn("docker: {s} failed container={s}", .{ action_name, id });
    }
    if (std.mem.eql(u8, action_name, "restart") and result.ok()) {
        const body = std.fmt.allocPrint(ctx.arena, "容器 {s} 已重启", .{id}) catch "容器已重启";
        notify.emit(ctx.app.db, .docker_restart, "容器重启", body);
    }
    try ctx.json(Body{ .id = id, .action = action_name, .ok = result.ok(), .output = textOf(result) });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return;
    }

    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }
    const tail = try std.fmt.allocPrint(ctx.arena, "{d}", .{lines});

    const engine = detectEngine(ctx.arena) catch {
        unavailable(ctx);
        return;
    };
    const result = exec.run(ctx.arena, &.{ engine.name, "logs", "--tail", tail, id }, max_output) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };

    const output = try std.mem.concat(ctx.arena, u8, &.{ result.stdout, result.stderr });
    try ctx.json(.{ .id = id, .ok = result.ok(), .output = output });
}

fn stringField(value: std.json.Value, key: []const u8) []const u8 {
    const entry = value.object.get(key) orelse return "";
    return switch (entry) {
        .string => |text| text,
        else => "",
    };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
