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
    try argv.appendSlice(&.{ "-f", path });
    if (compat.path.dirname(path)) |app_dir| {
        const override = try compat.path.join(allocator, &.{ app_dir, "compose.override.yml" });
        if (compat.cwd().access(override, .{})) |_| {
            try argv.appendSlice(&.{ "-f", override });
        } else |_| {}
    }
    try argv.appendSlice(&.{ "-p", project });
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

    const redeploy_hasura = std.mem.eql(u8, app.slug, "hasura") and installed(allocator, data_dir, app);
    for (app.params) |param| {
        var value = provided.get(param.key) orelse "";
        if (value.len == 0) value = param.default;
        if (value.len == 0 and param.kind == .password) {
            if (redeploy_hasura) return error.MissingParam;
            value = try randomPassword(allocator);
        }
        if (value.len == 0) return error.MissingParam;
        try validateValue(param, value);
        if (std.mem.eql(u8, app.slug, "hasura") and std.mem.eql(u8, param.key, "db_password")) {
            for (value) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_.~", ch) == null) return error.InvalidParam;
            }
        }
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
        if (std.mem.eql(u8, app.slug, "nginx")) {
            try compat.cwd().makePath(try compat.path.join(allocator, &.{ dir, "sites-conf" }));
            const include = try compat.path.join(allocator, &.{ dir, "sites-include.conf" });
            var snippet = try compat.createFileAbsolute(include, .{ .truncate = true, .mode = 0o644 });
            defer snippet.close();
            try snippet.writeAll("include /etc/nginx/hampanel/*.conf;\n");
            try @import("../runtime/site_nginx_container.zig").prepare(allocator, data_dir);
        }
        if (std.mem.eql(u8, app.slug, "comfyui")) {
            const dockerfile = try compat.path.join(allocator, &.{ dir, "Dockerfile" });
            var build_file = try compat.createFileAbsolute(dockerfile, .{ .truncate = true, .mode = 0o644 });
            defer build_file.close();
            try build_file.writeAll(@embedFile("catalog/comfyui.Dockerfile"));
        }
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

const legacy_nginx = @embedFile("catalog/nginx-legacy.yml");

fn legacyPort(raw: []const u8) ![]const u8 {
    const marker = "{{port}}";
    const at = comptime std.mem.indexOf(u8, legacy_nginx, marker).?;
    const suffix = legacy_nginx[at + marker.len ..];
    if (raw.len <= at + suffix.len or !std.mem.startsWith(u8, raw, legacy_nginx[0..at]) or !std.mem.endsWith(u8, raw, suffix)) return error.NotLegacyCatalogLayout;
    const port = raw[at .. raw.len - suffix.len];
    for (port) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidParam;
    if ((std.fmt.parseInt(u16, port, 10) catch return error.InvalidParam) == 0) return error.InvalidParam;
    return port;
}

// Only called by an explicit Store task. Never run down or change the project.
pub fn upgradeNginx(a: std.mem.Allocator, engine: engine_mod.Engine, socket: []const u8, data_dir: []const u8, app: *const catalog.App) !Outcome {
    if (!std.mem.eql(u8, app.slug, "nginx")) return error.InvalidParams;
    const argv = try composeArgs(a, engine, socket, data_dir, app, &.{ "up", "-d" });
    const path = try composePath(a, data_dir, app);
    const dir = compat.path.dirname(path).?;
    const backup = try compat.path.join(a, &.{ dir, "compose.pre-upgrade.yml" });
    const old = try compat.cwd().readFileAlloc(a, path, 16384);
    const port = try legacyPort(old);
    const updated = try replaceAll(a, app.compose, "{{port}}", port);
    // Do not adopt a same-name Compose project from another checkout or
    // silently replace a drifted HTML mount / host port. Fail closed when a
    // provider cannot attest the working directory and legacy runtime layout.
    const lookup = try engine_mod.run(a, engine, socket, &.{ engine.name, "ps", "-a", "--no-trunc", "--filter", "label=com.docker.compose.project=hampanel-nginx", "--format", "{{.ID}}" }, .{});
    const id = std.mem.trim(u8, lookup.stdout, " \t\r\n");
    if (!lookup.ok() or id.len != 64) return error.LegacyContainerMismatch;
    for (id) |ch| if (!std.ascii.isHex(ch)) return error.LegacyContainerMismatch;
    const format = "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}\n{{index .Config.Labels \"com.docker.compose.service\"}}\n{{.Config.Image}}\n{{.HostConfig.Privileged}}\n{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}\n{{end}}{{range $p, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{$p}} {{.HostIp}} {{.HostPort}}\n{{end}}{{end}}";
    const inspected = try engine_mod.run(a, engine, socket, &.{ engine.name, "inspect", "--format", format, id }, .{});
    if (!inspected.ok() or !legacyRuntime(inspected.stdout, dir, port)) return error.LegacyContainerMismatch;
    // Exclusive files: refuse to overwrite backups or load pre-existing site snippets.
    try writeNew(backup, old, 0o600);
    errdefer compat.deleteFileAbsolute(backup) catch {};
    const sites = try compat.path.join(a, &.{ dir, "sites-conf" });
    try compat.makeDirAbsolute(sites, 0o755);
    errdefer std.Io.Dir.cwd().deleteDir(compat.io(), sites) catch {};
    const snippet = try compat.path.join(a, &.{ dir, "sites-include.conf" });
    try writeNew(snippet, "include /etc/nginx/hampanel/*.conf;\n", 0o644);
    errdefer compat.deleteFileAbsolute(snippet) catch {};
    const stage = try compat.path.join(a, &.{ dir, "compose.upgrading.yml" });
    try writeNew(stage, updated, 0o600);
    defer compat.deleteFileAbsolute(stage) catch {};
    try compat.renameAbsolute(stage, path);
    try @import("../runtime/site_nginx_container.zig").prepare(a, data_dir);
    // Once Compose has started, a provider failure can mean a partial apply.
    // Keep both manifests and mounts for explicit recovery; don't auto-recreate again.
    var result = engine_mod.run(a, engine, socket, argv, .{ .max_output = 4 * 1024 * 1024 }) catch return .{ .ok = false, .output = "Compose failed; review compose.yml and compose.pre-upgrade.yml" };
    if (!result.ok()) return .{ .ok = false, .output = textOf(result) };
    _ = @import("../runtime/site_nginx.zig").resolveContainer(a, data_dir, socket) catch return .{ .ok = false, .output = "Updated mounts not verified; review compose.yml and compose.pre-upgrade.yml" };
    return .{ .ok = true, .output = textOf(result) };
}

fn legacyRuntime(raw: []const u8, dir: []const u8, port: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    for ([_][]const u8{ dir, "web", "docker.io/library/nginx:1.27-alpine", "false", "volume hampanel-nginx_html /usr/share/nginx/html true" }) |expected| {
        if (!std.mem.eql(u8, lines.next() orelse return false, expected)) return false;
    }
    const binding = lines.next() orelse return false;
    const prefix = "80/tcp  "; // no host-IP override
    return std.mem.startsWith(u8, binding, prefix) and std.mem.eql(u8, binding[prefix.len..], port) and lines.next() == null;
}

test "legacy runtime must match the project directory, volume and published binding" {
    const layout = "/apps/nginx\nweb\ndocker.io/library/nginx:1.27-alpine\nfalse\nvolume hampanel-nginx_html /usr/share/nginx/html true\n80/tcp  49101\n";
    try std.testing.expect(legacyRuntime(layout, "/apps/nginx", "49101"));
    try std.testing.expect(!legacyRuntime(layout, "/other/nginx", "49101"));
    try std.testing.expect(!legacyRuntime(layout, "/apps/nginx", "8080"));
    try std.testing.expect(!legacyRuntime(layout ++ "80/tcp 127.0.0.1 8080", "/apps/nginx", "49101"));
}

fn writeNew(path: []const u8, data: []const u8, mode: compat.File.Mode) !void {
    var f = try compat.createFileAbsolute(path, .{ .exclusive = true, .mode = mode });
    errdefer compat.deleteFileAbsolute(path) catch {};
    defer f.close();
    try f.writeAll(data);
}

test "nginx upgrade accepts only the exact legacy layout and preserves published port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try replaceAll(a, legacy_nginx, "{{port}}", "49101");
    try std.testing.expectEqualStrings("49101", try legacyPort(old));
    try std.testing.expectError(error.NotLegacyCatalogLayout, legacyPort(try replaceAll(a, old, "html:", "custom:")));
    try std.testing.expectError(error.InvalidParam, legacyPort(try replaceAll(a, old, "49101", "65536")));
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
