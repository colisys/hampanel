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

pub fn parseJsonObjects(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]const std.json.Value {
    var list = std.array_list.Managed(std.json.Value).init(allocator);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return try list.toOwnedSlice();
    if (std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{})) |value| {
        switch (value) {
            .array => {
                try list.appendSlice(value.array.items);
                return try list.toOwnedSlice();
            },
            .object => {
                try list.append(value);
                return try list.toOwnedSlice();
            },
            else => {},
        }
    } else |_| {}
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch continue;
        if (value == .object) try list.append(value);
    }
    return try list.toOwnedSlice();
}

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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) {
            return true;
        }
    }
    return false;
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
    try env.put(hostVariable(engine, argv), socket);
    return exec.runWith(allocator, argv, .{
        .environ_map = &env,
        .stdin = options.stdin,
        .max_output = options.max_output,
    });
}

pub fn restartSupported(a: std.mem.Allocator, engine: Engine, socket: []const u8) !void {
    const os = @import("builtin").os.tag;
    if (os != .linux and os != .windows) return error.UnsupportedPlatform;
    var endpoint = socket;
    if (endpoint.len == 0) endpoint = compat.getEnv(if (engine.podman) "CONTAINER_HOST" else "DOCKER_HOST") orelse "";
    if (endpoint.len == 0 and !engine.podman) {
        const probe = try exec.run(a, &.{ "docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}" }, 4096);
        if (!probe.ok()) return error.UnknownEndpoint;
        endpoint = std.mem.trim(u8, probe.stdout, " \r\n\t");
    }
    if (!localServiceEndpoint(engine.podman, os == .windows, endpoint)) return error.UnsupportedEndpoint;
    const info = try run(a, engine, endpoint, &.{ engine.name, "info", "--format", if (engine.podman) "{{.Host.Security.Rootless}}" else "{{json .SecurityOptions}}" }, .{});
    if (!info.ok()) return error.UnknownRootlessState;
    const security = std.mem.trim(u8, info.stdout, " \r\n\t");
    if (engine.podman) {
        if (!std.mem.eql(u8, security, "false")) return error.UnsupportedRootless;
    } else {
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, security, .{}) catch return error.UnknownRootlessState;
        if (value != .array) return error.UnknownRootlessState;
        for (value.array.items) |item| {
            if (item != .string) return error.UnknownRootlessState;
            if (containsIgnoreCase(item.string, "rootless")) return error.UnsupportedRootless;
        }
    }
    const service = if (os == .windows)
        try exec.run(a, &.{ "powershell.exe", "-NoProfile", "-Command", "Get-Service docker -ErrorAction Stop | Out-Null" }, 4096)
    else
        try exec.run(a, &.{ "systemctl", "show", "--property=LoadState", "--value", if (engine.podman) "podman.service" else "docker.service" }, 4096);
    if (!service.ok() or (os != .windows and !std.mem.eql(u8, std.mem.trim(u8, service.stdout, " \r\n\t"), "loaded"))) return error.UnsupportedServiceManager;
}

pub fn localServiceEndpoint(podman: bool, windows: bool, endpoint: []const u8) bool {
    if (windows) return !podman and std.mem.eql(u8, endpoint, "npipe:////./pipe/docker_engine");
    if (podman) return std.mem.eql(u8, endpoint, "unix:///run/podman/podman.sock");
    return std.mem.eql(u8, endpoint, "unix:///var/run/docker.sock") or std.mem.eql(u8, endpoint, "unix:///run/docker.sock");
}

pub fn restart(a: std.mem.Allocator, engine: Engine, socket: []const u8) !exec.Result {
    try restartSupported(a, engine, socket);
    return if (@import("builtin").os.tag == .windows)
        exec.run(a, &.{ "powershell.exe", "-NoProfile", "-Command", "Restart-Service docker -ErrorAction Stop" }, 1024 * 1024)
    else
        exec.run(a, &.{ "systemctl", "restart", if (engine.podman) "podman.service" else "docker.service" }, 1024 * 1024);
}

test "restart rejects remote rootless and unknown endpoints" {
    try std.testing.expect(localServiceEndpoint(false, false, "unix:///var/run/docker.sock"));
    try std.testing.expect(localServiceEndpoint(true, false, "unix:///run/podman/podman.sock"));
    try std.testing.expect(localServiceEndpoint(false, true, "npipe:////./pipe/docker_engine"));
    for ([_][]const u8{ "", "tcp://remote:2375", "ssh://host", "unix:///run/user/1000/docker.sock" }) |endpoint| {
        try std.testing.expect(!localServiceEndpoint(false, false, endpoint));
        try std.testing.expect(!localServiceEndpoint(true, false, endpoint));
    }
}

pub fn composeCommand(
    allocator: std.mem.Allocator,
    engine: Engine,
    socket: []const u8,
) ![]const []const u8 {
    // Prefer the standalone Podman provider first. Some Podman 4.x builds
    // expose a `podman compose` stub that exits 0 while printing
    // "unrecognized command", so exit status alone is not enough.
    const candidates: []const []const []const u8 = if (engine.podman)
        &.{
            &.{"podman-compose"},
            &.{"docker-compose"},
            &.{ engine.name, "compose" },
        }
    else
        &.{
            &.{ engine.name, "compose" },
            &.{"docker-compose"},
        };
    for (candidates) |base| {
        var probe = std.array_list.Managed([]const u8).init(allocator);
        try probe.appendSlice(base);
        try probe.append("version");
        const result = run(allocator, engine, socket, probe.items, .{ .max_output = 64 * 1024 }) catch continue;
        if (result.ok() and !probeIndicatesUnsupported(result)) {
            const out = try allocator.alloc([]const u8, base.len);
            @memcpy(out, base);
            return out;
        }
    }
    return error.ComposeUnavailable;
}

fn probeIndicatesUnsupported(result: exec.Result) bool {
    const needles = [_][]const u8{
        "unrecognized command",
        "unknown command",
        "not a podman command",
        "is not a docker command",
        "error: unrecognized",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(result.stdout, needle)) return true;
        if (containsIgnoreCase(result.stderr, needle)) return true;
    }
    return false;
}

pub fn hostVariable(engine: Engine, argv: []const []const u8) []const u8 {
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "docker-compose")) return "DOCKER_HOST";
    return if (engine.podman) "CONTAINER_HOST" else "DOCKER_HOST";
}

test "compose provider selects endpoint variable" {
    const podman = Engine{ .name = "podman", .podman = true };
    try std.testing.expectEqualStrings("DOCKER_HOST", hostVariable(podman, &.{"docker-compose"}));
    try std.testing.expectEqualStrings("CONTAINER_HOST", hostVariable(podman, &.{"podman-compose"}));
}
