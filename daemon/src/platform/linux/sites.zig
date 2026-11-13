const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const validate = @import("shared").validate;

const conf_dir = "/etc/nginx/conf.d/hampanel";
const max_output = 2 * 1024 * 1024;

pub const Site = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    domains: []const []const u8,
    root: []const u8,
    listen: []const u8,
};

pub const SiteList = struct {
    available: bool,
    dir: []const u8,
    sites: []const Site,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8 = "",
};

pub fn list(allocator: std.mem.Allocator) !SiteList {
    var sites = std.array_list.Managed(Site).init(allocator);

    var dir = compat.openDirAbsolute(conf_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            return .{ .available = nginxAvailable(allocator), .dir = conf_dir, .sites = sites.items };
        },
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |item| {
        if (item.kind != .file) continue;
        const enabled = std.mem.endsWith(u8, item.name, ".conf");
        const disabled = std.mem.endsWith(u8, item.name, ".conf.disabled");
        if (!enabled and !disabled) continue;

        const name = if (enabled)
            item.name[0 .. item.name.len - ".conf".len]
        else
            item.name[0 .. item.name.len - ".conf.disabled".len];
        if (name.len == 0 or !validate.isSlug(name)) continue;

        const full = try compat.path.join(allocator, &.{ conf_dir, item.name });
        const contents = compat.cwd().readFileAlloc(allocator, full, 512 * 1024) catch continue;
        const parsed = parseConfig(allocator, contents) catch continue;

        try sites.append(.{
            .name = name,
            .path = full,
            .enabled = enabled,
            .domains = parsed.domains,
            .root = parsed.root,
            .listen = parsed.listen,
        });
    }

    std.sort.pdq(Site, sites.items, {}, struct {
        fn lessThan(_: void, left: Site, right: Site) bool {
            return std.ascii.lessThanIgnoreCase(left.name, right.name);
        }
    }.lessThan);

    return .{ .available = nginxAvailable(allocator), .dir = conf_dir, .sites = sites.items };
}

pub fn create(
    allocator: std.mem.Allocator,
    name: []const u8,
    domains: []const []const u8,
    root: []const u8,
    port: u16,
) !Outcome {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ conf_dir, name });
    try compat.cwd().makePath(conf_dir);

    const previous: ?[]u8 = compat.cwd().readFileAlloc(allocator, path, 512 * 1024) catch null;

    var config: std.Io.Writer.Allocating = .init(allocator);
    defer config.deinit();
    const writer = &config.writer;
    try writer.print("# Managed by Hampanel. Manual edits may be overwritten.\n", .{});
    try writer.print("server {{\n", .{});
    try writer.print("    listen {d};\n", .{port});
    try writer.print("    listen [::]:{d};\n", .{port});
    try writer.print("    server_name", .{});
    for (domains) |domain| try writer.print(" {s}", .{domain});
    try writer.print(";\n", .{});
    try writer.print("    root {s};\n", .{root});
    try writer.print("    index index.html index.htm;\n", .{});
    try writer.print("    location / {{\n", .{});
    try writer.print("        try_files $uri $uri/ =404;\n", .{});
    try writer.print("    }}\n", .{});
    try writer.print("}}\n", .{});

    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(config.written());

    const check = nginxTest(allocator);
    if (!check.ok) {
        if (previous) |contents| {
            writeRaw(path, contents) catch {};
        } else {
            compat.deleteFileAbsolute(path) catch {};
        }
        return .{ .ok = false, .output = check.output };
    }

    const reload_result = try reload(allocator);
    return .{ .ok = reload_result.ok, .output = reload_result.output };
}

pub fn toggle(allocator: std.mem.Allocator, name: []const u8, enabled: bool) !Outcome {
    const enabled_path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ conf_dir, name });
    const disabled_path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf.disabled", .{ conf_dir, name });

    if (enabled) {
        if (!fileExists(disabled_path)) return error.SiteNotFound;
        try compat.renameAbsolute(disabled_path, enabled_path);
    } else {
        if (!fileExists(enabled_path)) return error.SiteNotFound;
        try compat.renameAbsolute(enabled_path, disabled_path);
    }

    const check = nginxTest(allocator);
    if (!check.ok) {
        if (enabled) {
            compat.renameAbsolute(enabled_path, disabled_path) catch {};
        } else {
            compat.renameAbsolute(disabled_path, enabled_path) catch {};
        }
        return .{ .ok = false, .output = check.output };
    }

    return reload(allocator);
}

pub fn destroy(allocator: std.mem.Allocator, name: []const u8) !Outcome {
    const enabled_path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf", .{ conf_dir, name });
    const disabled_path = try std.fmt.allocPrint(allocator, "{s}/{s}.conf.disabled", .{ conf_dir, name });

    var removed = false;
    if (fileExists(enabled_path)) {
        try compat.deleteFileAbsolute(enabled_path);
        removed = true;
    }
    if (fileExists(disabled_path)) {
        try compat.deleteFileAbsolute(disabled_path);
        removed = true;
    }
    if (!removed) return error.SiteNotFound;

    return reload(allocator);
}

pub fn reload(allocator: std.mem.Allocator) !Outcome {
    const result = exec.run(allocator, &.{ "systemctl", "reload", "nginx" }, max_output) catch {
        return .{ .ok = false, .output = "unable to execute systemctl" };
    };
    return .{ .ok = result.ok(), .output = textOf(result) };
}

const TestResult = struct {
    ok: bool,
    output: []const u8 = "",
};

fn nginxTest(allocator: std.mem.Allocator) TestResult {
    const result = exec.run(allocator, &.{ "nginx", "-t" }, max_output) catch {
        return .{ .ok = false, .output = "nginx is not installed" };
    };
    return .{ .ok = result.ok(), .output = if (result.ok()) "" else textOf(result) };
}

fn parseConfig(allocator: std.mem.Allocator, contents: []const u8) !struct {
    domains: []const []const u8,
    root: []const u8,
    listen: []const u8,
} {
    var domains = std.array_list.Managed([]const u8).init(allocator);
    var root: []const u8 = "";
    var listen: []const u8 = "";

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (std.mem.indexOfScalar(u8, line, '#')) |idx| line = line[0..idx];
        line = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.endsWith(u8, line, ";")) continue;
        line = line[0 .. line.len - 1];

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const directive = tokens.next() orelse continue;

        if (std.mem.eql(u8, directive, "server_name")) {
            while (tokens.next()) |token| try domains.append(token);
        } else if (std.mem.eql(u8, directive, "root")) {
            if (tokens.next()) |token| root = token;
        } else if (std.mem.eql(u8, directive, "listen")) {
            if (listen.len == 0) {
                if (tokens.next()) |token| listen = token;
            }
        }
    }

    return .{ .domains = domains.items, .root = root, .listen = listen };
}

fn nginxAvailable(allocator: std.mem.Allocator) bool {
    const result = exec.run(allocator, &.{ "nginx", "-v" }, 4096) catch return false;
    return result.exit_code == 0;
}

fn fileExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeRaw(path: []const u8, data: []const u8) !void {
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(data);
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
