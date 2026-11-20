const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const store = @import("site_store.zig");
const engine_mod = @import("engine.zig");

const max_output = 2 * 1024 * 1024;

pub const project = "hampanel-nginx";

pub const Sync = struct {
    ok: bool,
    recreated: bool = false,
    output: []const u8 = "",
};

pub fn appsDir(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "apps/nginx" });
}

pub fn streamDir(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "apps/nginx/sites-stream.d" });
}

pub fn mainConfigPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "apps/nginx/nginx.conf" });
}

const main_config =
    \\user  nginx;
    \\worker_processes  auto;
    \\
    \\error_log  /var/log/nginx/error.log notice;
    \\pid        /var/run/nginx.pid;
    \\
    \\events {
    \\    worker_connections  1024;
    \\}
    \\
    \\http {
    \\    include       /etc/nginx/mime.types;
    \\    default_type  application/octet-stream;
    \\
    \\    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
    \\                      '$status $body_bytes_sent "$http_referer" '
    \\                      '"$http_user_agent" "$http_x_forwarded_for"';
    \\
    \\    access_log  /var/log/nginx/access.log  main;
    \\
    \\    sendfile        on;
    \\    keepalive_timeout  65;
    \\
    \\    include /etc/nginx/conf.d/*.conf;
    \\}
    \\
    \\stream {
    \\    include /etc/nginx/stream.d/hampanel/*.conf;
    \\}
    \\
;

pub fn prepare(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const apps = try appsDir(allocator, data_dir);
    try compat.cwd().makePath(apps);
    try compat.cwd().makePath(try streamDir(allocator, data_dir));
    try writeRaw(try mainConfigPath(allocator, data_dir), main_config);
}

const Bind = struct {
    source: []const u8,
    writable: bool,
};

fn covered(path: []const u8, roots: []const []const u8) bool {
    for (roots) |root| {
        if (root.len == 0) continue;
        if (std.mem.eql(u8, path, root)) return true;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return true;
    }
    return false;
}

fn addBind(list: *std.array_list.Managed(Bind), path: []const u8, writable: bool, roots: []const []const u8) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return;
    if (std.mem.eql(u8, path, "/")) return;
    if (covered(path, roots)) return;
    for (list.items) |item| if (std.mem.eql(u8, item.source, path)) return;
    try list.append(.{ .source = path, .writable = writable });
}

fn compareBind(_: void, left: Bind, right: Bind) bool {
    return std.mem.lessThan(u8, left.source, right.source);
}

pub fn renderOverride(allocator: std.mem.Allocator, data_dir: []const u8, sites: []const store.Site) ![]const u8 {
    const apps = try appsDir(allocator, data_dir);
    const sites_root = try compat.path.join(allocator, &.{ data_dir, "sites" });
    const roots = [_][]const u8{ sites_root, apps, "/proc", "/sys", "/dev" };

    var list = std.array_list.Managed(Bind).init(allocator);
    try list.append(.{ .source = sites_root, .writable = false });

    for (sites) |site| {
        if (site.root.len > 0) try addBind(&list, site.root, true, &roots);
        if (site.run_dir.len > 0) try addBind(&list, site.run_dir, true, &roots);
        for ([_][]const u8{ site.access_log, site.error_log }) |log_path| {
            if (log_path.len == 0) continue;
            const parent = compat.path.dirname(log_path) orelse continue;
            try addBind(&list, parent, true, &roots);
        }
    }
    std.mem.sort(Bind, list.items, {}, compareBind);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("services:\n  web:\n    volumes:\n", .{});
    for (list.items) |bind| {
        try w.print("      - \"{s}:{s}:{s}\"\n", .{ bind.source, bind.source, if (bind.writable) "rw" else "ro" });
    }
    return allocator.dupe(u8, out.written());
}

pub fn sync(allocator: std.mem.Allocator, data_dir: []const u8, socket: []const u8) !Sync {
    try prepare(allocator, data_dir);
    const apps = try appsDir(allocator, data_dir);
    const compose = try compat.path.join(allocator, &.{ apps, "compose.yml" });
    compat.cwd().access(compose, .{}) catch return .{ .ok = true };

    const sites = store.list(allocator, data_dir) catch &[_]store.Site{};
    const rendered = try renderOverride(allocator, data_dir, sites);
    const override = try compat.path.join(allocator, &.{ apps, "compose.override.yml" });
    const previous = compat.cwd().readFileAlloc(allocator, override, 1024 * 1024) catch null;
    if (previous) |content| {
        if (std.mem.eql(u8, content, rendered)) return .{ .ok = true };
    }

    try writeRaw(override, rendered);
    const engine = engine_mod.detect(allocator, socket) catch |err| {
        restore(override, previous);
        return .{ .ok = false, .output = @errorName(err) };
    };
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(try engine_mod.composeCommand(allocator, engine, socket));
    try argv.appendSlice(&.{ "-f", compose, "-f", override, "-p", project, "up", "-d" });
    const result = engine_mod.run(allocator, engine, socket, argv.items, .{ .max_output = 4 * 1024 * 1024 }) catch {
        restore(override, previous);
        return .{ .ok = false, .output = "compose provider unavailable while applying site mounts" };
    };
    if (!result.ok()) {
        restore(override, previous);
        return .{ .ok = false, .output = textOf(result) };
    }
    return .{ .ok = true, .recreated = true, .output = textOf(result) };
}

fn restore(path: []const u8, previous: ?[]const u8) void {
    if (previous) |content| {
        writeRaw(path, content) catch {};
    } else {
        compat.deleteFileAbsolute(path) catch {};
    }
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

test "override mounts site roots and log directories at identical paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sites = [_]store.Site{
        .{ .name = "alpha", .root = "/srv/alpha", .access_log = "/var/log/nginx/alpha.log" },
        .{ .name = "beta", .root = "/data/data1/hampanel/sites/beta", .error_log = "/var/log/nginx/beta.err" },
    };
    const rendered = try renderOverride(a, "/data/data1/hampanel", &sites);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"/srv/alpha:/srv/alpha:rw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"/var/log/nginx:/var/log/nginx:rw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/data/data1/hampanel/sites:/data/data1/hampanel/sites:ro") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"/:/:/") == null);
}

test "override skips paths already covered by the site directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sites = [_]store.Site{
        .{ .name = "inner", .root = "/data/data1/hampanel/sites/inner/public" },
    };
    const rendered = try renderOverride(a, "/data/data1/hampanel", &sites);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "sites/inner/public") == null);
}

test "override is stable regardless of site order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]store.Site{ .{ .name = "a", .root = "/srv/a" }, .{ .name = "b", .root = "/srv/b" } };
    const two = [_]store.Site{ .{ .name = "b", .root = "/srv/b" }, .{ .name = "a", .root = "/srv/a" } };
    const left = try renderOverride(a, "/data", &one);
    const right = try renderOverride(a, "/data", &two);
    try std.testing.expectEqualStrings(left, right);
}
