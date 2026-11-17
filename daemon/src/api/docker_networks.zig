const std = @import("std");
const context = @import("context.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 4 * 1024 * 1024;

const Network = struct {
    id: []const u8,
    name: []const u8,
    driver: []const u8,
    scope: []const u8,
    subnet: []const u8,
    gateway: []const u8,
    labels: []const []const u8,
    created_at: []const u8,
};

pub fn index(ctx: *context.Context) anyerror!void {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const listing = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "network", "ls", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!listing.ok()) {
        ctx.fail(502, "docker_failed", textOf(listing));
        return;
    }
    const objects = try engine_mod.parseJsonObjects(ctx.arena, listing.stdout);
    var ids = std.array_list.Managed([]const u8).init(ctx.arena);
    for (objects) |value| {
        if (value != .object) continue;
        const id = fieldAny(value, &.{ "ID", "Id", "id" });
        if (id.len > 0) try ids.append(id);
    }
    var inspected = std.StringHashMap(std.json.Value).init(ctx.arena);
    if (ids.items.len > 0) {
        var argv = std.array_list.Managed([]const u8).init(ctx.arena);
        try argv.appendSlice(&.{ engine.name, "network", "inspect" });
        try argv.appendSlice(ids.items);
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
                            const id = fieldAny(item, &.{ "Id", "ID", "id" });
                            if (id.len > 0) try inspected.put(id, item);
                        }
                    }
                }
            }
        }
    }

    var networks = std.array_list.Managed(Network).init(ctx.arena);
    for (objects) |value| {
        if (value != .object) continue;
        const id = fieldAny(value, &.{ "ID", "Id", "id" });
        var item = Network{
            .id = id,
            .name = fieldAny(value, &.{ "Name", "name" }),
            .driver = fieldAny(value, &.{ "Driver", "driver" }),
            .scope = fieldAny(value, &.{ "Scope", "scope" }),
            .subnet = "",
            .gateway = "",
            .labels = &.{},
            .created_at = "",
        };
        if (inspected.get(id)) |detail| {
            item.created_at = fieldAny(detail, &.{ "Created", "created" });
            var labels = std.array_list.Managed([]const u8).init(ctx.arena);
            try collectMap(ctx.arena, detail, "Labels", &labels);
            if (labels.items.len == 0) try collectMap(ctx.arena, detail, "labels", &labels);
            item.labels = labels.items;
            if (detail.object.get("IPAM")) |ipam| {
                if (ipam == .object) {
                    if (ipam.object.get("Config")) |config| {
                        if (config == .array and config.array.items.len > 0) {
                            item.subnet = field(config.array.items[0], "Subnet");
                            item.gateway = field(config.array.items[0], "Gateway");
                        }
                    }
                }
            }
        }
        if (item.subnet.len == 0) {
            if (value.object.get("subnets")) |subnets| {
                if (subnets == .array and subnets.array.items.len > 0) {
                    const first = subnets.array.items[0];
                    item.subnet = fieldAny(first, &.{ "subnet", "Subnet" });
                    item.gateway = fieldAny(first, &.{ "gateway", "Gateway" });
                }
            }
        }
        try networks.append(item);
    }
    try ctx.json(.{ .available = true, .engine = engine.name, .networks = networks.items });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        driver: []const u8 = "bridge",
        subnet: []const u8 = "",
        gateway: []const u8 = "",
        labels: []const []const u8 = &.{},
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected network configuration");
        return;
    };
    if (!validate.isNetworkName(body.name)) {
        ctx.fail(400, "bad_name", "invalid network name");
        return;
    }
    if (!validToken(body.driver, 32) or !validCidr(body.subnet) or !validCidr(body.gateway)) {
        ctx.fail(400, "bad_network", "invalid driver or address");
        return;
    }
    for (body.labels) |entry| {
        if (!validKeyValue(entry)) {
            ctx.fail(400, "bad_label", "invalid label");
            return;
        }
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "network", "create", "--driver", body.driver });
    if (body.subnet.len > 0) try argv.appendSlice(&.{ "--subnet", body.subnet });
    if (body.gateway.len > 0) try argv.appendSlice(&.{ "--gateway", body.gateway });
    for (body.labels) |entry| try argv.appendSlice(&.{ "--label", entry });
    try argv.append(body.name);
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: network created name={s}", .{body.name});
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .name = body.name });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing network name");
        return;
    };
    if (!validate.isNetworkName(name)) {
        ctx.fail(400, "bad_name", "invalid network name");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "network", "rm", name }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: network removed name={s}", .{name});
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .name = name });
}

pub fn prune(ctx: *context.Context) anyerror!void {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "network", "prune", "-f" }, .{ .max_output = max_output }) catch {
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

fn validToken(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn validCidr(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isHex(ch) and ch != ':' and ch != '.' and ch != '/') return false;
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
