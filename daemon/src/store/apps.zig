const std = @import("std");
const catalog = @import("catalog.zig");
const exec = @import("shared").exec;

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
    return std.fs.path.join(allocator, &.{ data_dir, "apps", app.slug, "compose.yml" });
}

pub fn installed(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) bool {
    const path = composePath(allocator, data_dir, app) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn composeCommand(allocator: std.mem.Allocator) ![]const []const u8 {
    if (exec.run(allocator, &.{ "docker", "compose", "version" }, 64 * 1024) catch null) |result| {
        if (result.ok()) return &.{ "docker", "compose" };
    }
    if (exec.run(allocator, &.{ "docker-compose", "version" }, 64 * 1024) catch null) |result| {
        if (result.ok()) return &.{"docker-compose"};
    }
    return error.ComposeUnavailable;
}

fn composeArgs(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    app: *const catalog.App,
    extra: []const []const u8,
) ![]const []const u8 {
    const path = try composePath(allocator, data_dir, app);
    std.fs.cwd().access(path, .{}) catch return error.NotInstalled;
    const project = try std.fmt.allocPrint(allocator, "hampanel-{s}", .{app.slug});

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.appendSlice(try composeCommand(allocator));
    try argv.appendSlice(&.{ "-f", path, "-p", project });
    try argv.appendSlice(extra);
    return argv.items;
}

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, data_dir, app, &.{"ps"});
    var result = exec.run(allocator, argv, 2 * 1024 * 1024) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn deploy(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    app: *const catalog.App,
    provided: *const std.StringHashMap([]const u8),
) !DeployResult {
    var values = std.StringHashMap([]const u8).init(allocator);
    var applied = std.ArrayList(AppliedParam).init(allocator);

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

    const rendered = try render(allocator, app.compose, app.params, &values);
    const path = try composePath(allocator, data_dir, app);
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(rendered);

    const argv = try composeArgs(allocator, data_dir, app, &.{ "up", "-d" });
    var result = exec.run(allocator, argv, 4 * 1024 * 1024) catch return error.ComposeUnavailable;

    return .{
        .ok = result.ok(),
        .output = textOf(result),
        .path = path,
        .params = applied.items,
    };
}

pub fn start(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, data_dir, app, &.{"start"});
    var result = exec.run(allocator, argv, 2 * 1024 * 1024) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App) !Outcome {
    const argv = try composeArgs(allocator, data_dir, app, &.{"stop"});
    var result = exec.run(allocator, argv, 2 * 1024 * 1024) catch return error.ComposeUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn logs(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App, lines: usize) !Outcome {
    const tail = try std.fmt.allocPrint(allocator, "{d}", .{lines});
    const argv = try composeArgs(allocator, data_dir, app, &.{ "logs", "--tail", tail });
    var result = exec.run(allocator, argv, 4 * 1024 * 1024) catch return error.ComposeUnavailable;
    return .{
        .ok = result.ok(),
        .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }),
    };
}

pub fn remove(allocator: std.mem.Allocator, data_dir: []const u8, app: *const catalog.App, volumes: bool) !Outcome {
    const extra: []const []const u8 = if (volumes) &.{ "down", "-v" } else &.{"down"};
    const argv = try composeArgs(allocator, data_dir, app, extra);
    var result = exec.run(allocator, argv, 2 * 1024 * 1024) catch return error.ComposeUnavailable;
    const ok = result.ok();

    if (ok) {
        const path = try composePath(allocator, data_dir, app);
        std.fs.deleteFileAbsolute(path) catch {};
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.deleteTreeAbsolute(dir) catch {};
        }
    }

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
    var out = std.ArrayList(u8).init(allocator);
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
    std.crypto.random.bytes(&raw);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
