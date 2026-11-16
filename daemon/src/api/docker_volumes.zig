const std = @import("std");
const context = @import("context.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 4 * 1024 * 1024;

const Volume = struct {
    name: []const u8,
    driver: []const u8,
    scope: []const u8,
    mountpoint: []const u8,
    labels: []const []const u8,
    options: []const []const u8,
    created_at: []const u8,
};

pub fn index(ctx: *context.Context) anyerror!void {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const listing = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "volume", "ls", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!listing.ok()) {
        ctx.fail(502, "docker_failed", textOf(listing));
        return;
    }
    var names = std.array_list.Managed([]const u8).init(ctx.arena);
    var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, trimmed, .{}) catch continue;
        if (value != .object) continue;
        const name = field(value, "Name");
        if (name.len > 0) try names.append(name);
    }
    var inspected = std.StringHashMap(std.json.Value).init(ctx.arena);
    if (names.items.len > 0) {
        var argv = std.array_list.Managed([]const u8).init(ctx.arena);
        try argv.appendSlice(&.{ engine.name, "volume", "inspect" });
        try argv.appendSlice(names.items);
        const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch null;
        if (result) |value| {
            if (value.ok()) {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, value.stdout, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch null;
                if (parsed) |root| {
                    if (root == .array) {
                        for (root.array.items) |item| {
                            const name = field(item, "Name");
                            if (name.len > 0) try inspected.put(name, item);
                        }
                    }
                }
            }
        }
    }

    var volumes = std.array_list.Managed(Volume).init(ctx.arena);
    lines = std.mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, trimmed, .{}) catch continue;
        if (value != .object) continue;
        const name = field(value, "Name");
        var item = Volume{
            .name = name,
            .driver = field(value, "Driver"),
            .scope = field(value, "Scope"),
            .mountpoint = field(value, "Mountpoint"),
            .labels = &.{},
            .options = &.{},
            .created_at = "",
        };
        if (inspected.get(name)) |detail| {
            item.created_at = field(detail, "CreatedAt");
            item.mountpoint = field(detail, "Mountpoint");
            var labels = std.array_list.Managed([]const u8).init(ctx.arena);
            try collectMap(ctx.arena, detail, "Labels", &labels);
            item.labels = labels.items;
            var options = std.array_list.Managed([]const u8).init(ctx.arena);
            try collectMap(ctx.arena, detail, "Options", &options);
            item.options = options.items;
        }
        try volumes.append(item);
    }
    try ctx.json(.{ .available = true, .engine = engine.name, .volumes = volumes.items });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        driver: []const u8 = "local",
        labels: []const []const u8 = &.{},
        options: []const []const u8 = &.{},
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected volume configuration");
        return;
    };
    if (!validate.isVolumeName(body.name)) {
        ctx.fail(400, "bad_name", "invalid volume name");
        return;
    }
    if (!validToken(body.driver)) {
        ctx.fail(400, "bad_driver", "invalid volume driver");
        return;
    }
    for (body.labels) |entry| {
        if (!validKeyValue(entry)) {
            ctx.fail(400, "bad_label", "invalid label");
            return;
        }
    }
    for (body.options) |entry| {
        if (!validKeyValue(entry)) {
            ctx.fail(400, "bad_option", "invalid option");
            return;
        }
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "volume", "create", "--driver", body.driver });
    for (body.labels) |entry| try argv.appendSlice(&.{ "--label", entry });
    for (body.options) |entry| try argv.appendSlice(&.{ "--opt", entry });
    try argv.append(body.name);
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: volume created name={s}", .{body.name});
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .name = body.name });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing volume name");
        return;
    };
    if (!validate.isVolumeName(name)) {
        ctx.fail(400, "bad_name", "invalid volume name");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "volume", "rm", name }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: volume removed name={s}", .{name});
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .name = name });
}

pub fn prune(ctx: *context.Context) anyerror!void {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "volume", "prune", "-f" }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result) });
}

fn collectMap(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    out: *std.array_list.Managed([]const u8),
) !void {
    if (value != .object) return;
    const map = value.object.get(key) orelse return;
    if (map != .object) return;
    var iterator = map.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try out.append(try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
    }
}

fn field(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const entry = value.object.get(key) orelse return "";
    return if (entry == .string) entry.string else "";
}

fn validToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn validKeyValue(value: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse return false;
    return separator > 0 and value.len <= 1024;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
