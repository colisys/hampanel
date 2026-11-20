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
    const objects = try engine_mod.parseJsonObjects(ctx.arena, listing.stdout);
    var names = std.array_list.Managed([]const u8).init(ctx.arena);
    for (objects) |value| {
        if (value != .object) continue;
        const name = fieldAny(value, &.{ "Name", "name" });
        if (name.len > 0) try names.append(name);
    }
    var inspected = std.StringHashMap(std.json.Value).init(ctx.arena);
    if (names.items.len > 0) {
        var argv = std.array_list.Managed([]const u8).init(ctx.arena);
        try argv.appendSlice(&.{ engine.name, "volume", "inspect" });
        try argv.appendSlice(names.items);
        const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch {
            ctx.fail(502, "docker_unavailable", "unable to inspect volumes");
            return;
        };
        if (!result.ok() and !onlyMissingVolumes(result.stderr, names.items)) {
            ctx.fail(502, "volume_inspect_failed", textOf(result));
            return;
        }
        for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |item| {
            try inspected.put(fieldAny(item, &.{ "Name", "name" }), item);
        }
        for (names.items) |name| {
            if (!inspected.contains(name) and !missingVolume(result.stderr, name)) {
                ctx.fail(502, "volume_inspect_failed", "incomplete volume inspection");
                return;
            }
        }
    }

    var volumes = std.array_list.Managed(Volume).init(ctx.arena);
    for (objects) |value| {
        if (value != .object) continue;
        const name = fieldAny(value, &.{ "Name", "name" });
        if (!inspected.contains(name)) continue; // removed after ls
        var item = Volume{
            .name = name,
            .driver = fieldAny(value, &.{ "Driver", "driver" }),
            .scope = fieldAny(value, &.{ "Scope", "scope" }),
            .mountpoint = fieldAny(value, &.{ "Mountpoint", "mountpoint" }),
            .labels = &.{},
            .options = &.{},
            .created_at = "",
        };
        if (inspected.get(name)) |detail| {
            item.created_at = fieldAny(detail, &.{ "CreatedAt", "created" });
            item.mountpoint = fieldAny(detail, &.{ "Mountpoint", "mountpoint" });
            var labels = std.array_list.Managed([]const u8).init(ctx.arena);
            try collectMap(ctx.arena, detail, "Labels", &labels);
            if (labels.items.len == 0) try collectMap(ctx.arena, detail, "labels", &labels);
            item.labels = labels.items;
            var options = std.array_list.Managed([]const u8).init(ctx.arena);
            try collectMap(ctx.arena, detail, "Options", &options);
            if (options.items.len == 0) try collectMap(ctx.arena, detail, "options", &options);
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

fn fieldAny(value: std.json.Value, keys: []const []const u8) []const u8 {
    for (keys) |key| {
        const text = field(value, key);
        if (text.len > 0) return text;
    }
    return "";
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

// Docker emits the surviving inspect objects on stdout and a diagnostic per
// vanished name on stderr. Never mask unrelated permission or engine failures.
fn missingLine(line: []const u8, name: []const u8) bool {
    const prefix = "Error response from daemon: get ";
    const suffix = ": no such volume";
    return line.len == prefix.len + name.len + suffix.len and std.mem.startsWith(u8, line, prefix) and std.mem.endsWith(u8, line, suffix) and std.mem.eql(u8, line[prefix.len..][0..name.len], name);
}

fn missingVolume(stderr: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, stderr, "\r\n");
    while (lines.next()) |line| if (missingLine(line, name)) return true;
    return false;
}

fn onlyMissingVolumes(stderr: []const u8, names: []const []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, stderr, "\r\n");
    var found = false;
    while (lines.next()) |line| {
        for (names) |name| {
            if (missingLine(line, name)) break;
        } else return false;
        found = true;
    }
    return found;
}

test "docker partial inspect skips only reported missing volumes" {
    const msg = "Error response from daemon: get gone: no such volume\n";
    try std.testing.expect(onlyMissingVolumes(msg, &.{ "live", "gone" }));
    try std.testing.expect(!missingVolume(msg, "live"));
    try std.testing.expect(!onlyMissingVolumes(msg ++ "permission denied", &.{"gone"}));
    try std.testing.expect(!onlyMissingVolumes(msg, &.{"other"}));
}
