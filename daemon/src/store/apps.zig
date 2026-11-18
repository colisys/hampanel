const std = @import("std");
const compat = @import("compat");
const catalog = @import("catalog.zig");
const exec = @import("shared").exec;
const engine_mod = @import("../runtime/engine.zig");

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const AppliedParam = struct {
    key: []const u8,
    value: []const u8,
    secret: bool,
};

pub const DeployResult = struct {
    ok: bool,
    output: []const u8,
    path: []const u8,
    params: []const AppliedParam,
};

pub fn composePath(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "apps", app.slug, "compose.yml" });
}

pub fn installed(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) bool {
    const path = composePath(allocator, data_dir, app) catch return false;
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn cleanupComposeFiles(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) void {
    const path = composePath(allocator, data_dir, app) catch return;
    compat.deleteFileAbsolute(path) catch {};
    if (compat.path.dirname(path)) |dir| {
        compat.deleteTreeAbsolute(dir) catch {};
    }
}

fn composeArgs(
    allocator: std.mem.Allocator,
    engine: engine_mod.Engine,
    socket: []const u8,
    data_dir: []const u8,
    app: *const catalog.App,
    extra: []const []const u8,
) ![]const []const u8 {
    const path = try composePath(allocator, data_dir, app);
    compat.cwd().access(path, .{}) catch return error.NotInstalled;
    const project = try std.fmt.allocPrint(allocator, "hampanel-{s}", .{app.slug});

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(try engine_mod.composeCommand(allocator, engine, socket));
    try argv.appendSlice(&.{ "-f", path, "-p", project });
    try argv.appendSlice(extra);
    return argv.items;
}

pub fn status(allocator: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, engine, socket, data_dir, app, &.{"ps"});
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 2 * 1024 * 1024 }) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn deploy(
    allocator: std.mem.Allocator,
    engine: engine_mod.Engine,
    socket: []const u8,
    data_dir: []const u8,
    app: *const catalog.App,
    provided: *const std.StringHashMap([]const u8),
) !DeployResult {
    var values = std.StringHashMap([]const u8).init(allocator);
    var applied = std.array_list.Managed(AppliedParam).init(allocator);

    for (app.params) |param| {
        var value = provided.get(param.key) orelse "";
        if (value.len == 0) value = param.default;
        if (value.len == 0 and param.kind == .password) {
            value = try randomPassword(allocator);
        }
        if (value.len == 0) return error.MissingParam;
        try validateValue(param, value);
        try values.put(param.key, value);
        try applied.append(.{ .key = param.key, .value = value, .secret = param.secret });
    }

    // Resolve the compose provider before creating files. A failed deploy used
    // to leave compose.yml behind, making the app look installed forever.
    _ = engine_mod.composeCommand(allocator, engine, socket) catch return error.ComposeUnavailable;

    const wasInstalled = installed(allocator, data_dir, app);
    const rendered = try render(allocator, app.compose, app.params, &values);
    const path = try composePath(allocator, data_dir, app);
    if (compat.path.dirname(path)) |dir| {
        try compat.cwd().makePath(dir);
    }

    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(rendered);

    const argv = try composeArgs(allocator, engine, socket, data_dir, app, &.{ "up", "-d" });
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 4 * 1024 * 1024 }) catch {
        if (!wasInstalled) cleanupComposeFiles(allocator, data_dir, app);
        return error.ComposeUnavailable;
    };

    // podman-compose can exit 0 even when image resolution or container
    // startup failed. Only report success when compose actually has a
    // running container; otherwise the app would look installed forever.
    var ok = result.ok();
    var output = textOf(result);
    if (ok) {
        if (status(allocator, engine, socket, data_dir, app) catch null) |probe| {
            if (!probe.ok or std.mem.indexOf(u8, probe.output, "Up ") == null) {
                ok = false;
                if (probe.output.len > 0) {
                    output = try std.mem.concat(allocator, u8, &.{ output, "\n", probe.output });
                }
            }
        } else {
            ok = false;
        }
    }
    if (!ok and !wasInstalled) {
        cleanupComposeFiles(allocator, data_dir, app);
    }

    return .{
        .ok = ok,
        .output = output,
        .path = path,
        .params = applied.items,
    };
}

pub fn start(allocator: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, engine, socket, data_dir, app, &.{"start"});
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 2 * 1024 * 1024 }) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn stop(allocator: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, engine, socket, data_dir, app, &.{"stop"});
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 2 * 1024 * 1024 }) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn logs(allocator: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App, lines: usize) !Outcome {
    const tail = try std.fmt.allocPrint(allocator, "{d}", .{lines});
    const argv = try composeArgs(allocator, engine, socket, data_dir, app, &.{ "logs", "--tail", tail });
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 4 * 1024 * 1024 }) catch return error.ComposeUnavailable;
    return .{
        .ok = result.ok(),
        .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }),
    };
}

pub fn remove(allocator: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App, volumes: bool) !Outcome {
    const extra: []const []const u8 = if (volumes) &.{ "down", "-v" } else &.{"down"};
    const argv = composeArgs(allocator, engine, socket, data_dir, app, extra) catch |err| {
        if (err == error.ComposeUnavailable or err == error.NotInstalled) {
            cleanupComposeFiles(allocator, data_dir, app);
            return .{
                .ok = true,
                .output = "compose provider unavailable; removed the managed compose file",
            };
        }
        return err;
    };
    var result = engine_mod.run(allocator, engine, socket, argv, .{ .max_output = 2 * 1024 * 1024 }) catch |err| {
        if (err == error.ComposeUnavailable) {
            // A provider may disappear between install checks. The managed
            // file is the only durable state for the app, so clean it up.
            cleanupComposeFiles(allocator, data_dir, app);
            return .{
                .ok = true,
                .output = "compose provider unavailable; removed the managed compose file",
            };
        }
        return err;
    };
    const ok = result.ok();

    if (ok) cleanupComposeFiles(allocator, data_dir, app);
    return .{ .ok = ok, .output = textOf(result) };
}

fn render(
    allocator: std.mem.Allocator,
    template: []const u8,
    params: []const catalog.Param,
    values: *const std.StringHashMap([]const u8),
) ![]u8 {
    var output = try allocator.dupe(u8, template);
    for (params) |param| {
        const value = values.get(param.key) orelse return error.MissingParam;
        const needle = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{param.key});
        output = try replaceAll(allocator, output, needle, value);
    }
    if (std.mem.indexOf(u8, output, "{{") != null) return error.TemplateError;
    return output;
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, input, cursor, needle)) |index| {
        try out.appendSlice(input[cursor..index]);
        try out.appendSlice(replacement);
        cursor = index + needle.len;
    }
    try out.appendSlice(input[cursor..]);
    return out.toOwnedSlice();
}

fn validateValue(param: catalog.Param, value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidParam;
    switch (param.kind) {
        .port => {
            const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidParam;
            if (port == 0) return error.InvalidParam;
        },
        .text, .password => {
            for (value) |ch| {
                if (safeValueChar(ch)) continue;
                return error.InvalidParam;
            }
        },
    }
}

fn safeValueChar(ch: u8) bool {
    if (std.ascii.isAlphanumeric(ch)) return true;
    return std.mem.indexOfScalar(u8, "-_.~!@#%^&*+=:@,", ch) != null;
}

fn randomPassword(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [16]u8 = undefined;
    compat.randomBytes(&raw);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
