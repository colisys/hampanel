const std = @import("std");
const compat = @import("compat");
const db = @import("../db.zig");
const exec = @import("shared").exec;

pub const Engine = struct {
    name: []const u8,
    podman: bool,
};

pub const Options = struct {
    stdin: ?[]const u8 = null,
    max_output: usize = 1024 * 1024,
};

pub fn socketFromDb(allocator: std.mem.Allocator, database: *db.Db) []const u8 {
    const value = database.getSetting(allocator, "docker.socket_path") catch null;
    return value orelse "";
}

var preferred_name: []const u8 = "";

pub fn setPreferred(name: []const u8) void {
    preferred_name = name;
}

pub fn detect(allocator: std.mem.Allocator, socket: []const u8) !Engine {
    if (preferred_name.len > 0) {
        if (!std.mem.eql(u8, preferred_name, "docker") and !std.mem.eql(u8, preferred_name, "podman")) {
            return error.InvalidEngine;
        }
        if (!exec.commandExists(allocator, preferred_name)) return error.EngineUnavailable;
        return .{ .name = preferred_name, .podman = std.mem.eql(u8, preferred_name, "podman") };
    }
    return autoDetect(allocator, socket);
}

pub fn autoDetect(allocator: std.mem.Allocator, socket: []const u8) !Engine {
    const candidates = [_]struct { name: []const u8, podman: bool }{
        .{ .name = "docker", .podman = false },
        .{ .name = "podman", .podman = true },
    };
    for (candidates) |candidate| {
        const engine = Engine{ .name = candidate.name, .podman = candidate.podman };
        const argv = [_][]const u8{ candidate.name, "version", "--format", "{{.Client.Version}}" };
        const result = run(allocator, engine, socket, &argv, .{ .max_output = 64 * 1024 }) catch continue;
        if (result.ok()) return engine;
    }
    return error.EngineUnavailable;
}

pub fn run(
    allocator: std.mem.Allocator,
    engine: Engine,
    socket: []const u8,
    argv: []const []const u8,
    options: Options,
) !exec.Result {
    if (socket.len == 0) {
        return exec.runWith(allocator, argv, .{
            .stdin = options.stdin,
            .max_output = options.max_output,
        });
    }

    var env = try compat.cloneEnv(allocator);
    defer env.deinit();
    try env.put(if (engine.podman) "CONTAINER_HOST" else "DOCKER_HOST", socket);
    return exec.runWith(allocator, argv, .{
        .environ_map = &env,
        .stdin = options.stdin,
        .max_output = options.max_output,
    });
}

pub fn composeCommand(
    allocator: std.mem.Allocator,
    engine: Engine,
    socket: []const u8,
) ![]const []const u8 {
    const candidates = [_][]const []const u8{
        &.{ engine.name, "compose" },
        if (engine.podman) &.{"podman-compose"} else &.{"docker-compose"},
    };
    for (candidates) |base| {
        var probe = std.array_list.Managed([]const u8).init(allocator);
        try probe.appendSlice(base);
        try probe.append("version");
        const result = run(allocator, engine, socket, probe.items, .{ .max_output = 64 * 1024 }) catch continue;
        if (result.ok()) {
            const out = try allocator.alloc([]const u8, base.len);
            @memcpy(out, base);
            return out;
        }
    }
    return error.ComposeUnavailable;
}
