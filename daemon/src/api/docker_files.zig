const std = @import("std");
const http_validate = @import("../http/validate.zig");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const http_response = @import("../http/response.zig");
const log = @import("../log.zig");

const EngineCtx = struct {
    engine: engine_mod.Engine,
    socket: []const u8,
};

const Entry = struct {
    name: []const u8,
    kind: []const u8,
    mode: []const u8,
    size: u64,
    modified: []const u8,
    symlink: bool,
};

const max_output = 4 * 1024 * 1024;

pub fn list(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const path = requirePath(ctx) orelse return;
    const ec = detect(ctx) orelse return;

    const result = runInContainer(ctx, ec, id, &.{
        "sh", "-c", "LC_ALL=C ls -la -- \"$1\"", "sh", path,
    }, max_output) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }

    var entries = std.array_list.Managed(Entry).init(ctx.arena);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (try parseLsLine(ctx.arena, line)) |entry| try entries.append(entry);
    }

    try ctx.json(.{
        .path = path,
        .entries = entries.items,
        .raw = result.stdout,
    });
}

pub fn content(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const path = requirePath(ctx) orelse return;
    const ec = detect(ctx) orelse return;

    const result = runInContainer(ctx, ec, id, &.{ "cat", "--", path }, 2 * 1024 * 1024) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(404, "not_found", textOf(result));
        return;
    }

    if (std.unicode.utf8ValidateSlice(result.stdout)) {
        try ctx.json(.{
            .path = path,
            .encoding = "utf8",
            .content = result.stdout,
        });
        return;
    }

    const encoded = try ctx.arena.alloc(u8, std.base64.standard.Encoder.calcSize(result.stdout.len));
    _ = std.base64.standard.Encoder.encode(encoded, result.stdout);
    try ctx.json(.{
        .path = path,
        .encoding = "base64",
        .content = encoded,
    });
}

pub fn write(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const Body = struct {
        path: []const u8,
        content: []const u8,
        encoding: []const u8 = "utf8",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and content");
        return;
    };
    if (!validPath(body.path)) {
        ctx.fail(400, "bad_path", "invalid container path");
        return;
    }
    var decoded: []u8 = undefined;
    if (std.mem.eql(u8, body.encoding, "base64")) {
        const size = std.base64.standard.Decoder.calcSizeForSlice(body.content) catch {
            ctx.fail(400, "bad_base64", "invalid base64 content");
            return;
        };
        decoded = try ctx.arena.alloc(u8, size);
        std.base64.standard.Decoder.decode(decoded, body.content) catch {
            ctx.fail(400, "bad_base64", "invalid base64 content");
            return;
        };
    } else {
        decoded = @constCast(body.content);
    }

    const ec = detect(ctx) orelse return;
    const temp = try writeTemp(ctx, decoded);
    defer compat.deleteFileAbsolute(temp) catch {};
    const target = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ id, body.path });
    const result = engine_mod.run(ctx.arena, ec.engine, ec.socket, &.{ ec.engine.name, "cp", temp, target }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: wrote container file id={s} path={s}", .{ id, body.path });
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .path = body.path });
}

pub fn mkdir(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const Body = struct { path: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path");
        return;
    };
    if (!validPath(body.path)) {
        ctx.fail(400, "bad_path", "invalid container path");
        return;
    }
    const ec = detect(ctx) orelse return;
    const result = runInContainer(ctx, ec, id, &.{ "mkdir", "-p", "--", body.path }, 1024 * 1024) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .path = body.path });
}

pub fn rename(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const Body = struct { from: []const u8, to: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected from and to");
        return;
    };
    if (!validPath(body.from) or !validPath(body.to)) {
        ctx.fail(400, "bad_path", "invalid container path");
        return;
    }
    const ec = detect(ctx) orelse return;
    const result = runInContainer(ctx, ec, id, &.{ "mv", "--", body.from, body.to }, 1024 * 1024) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .from = body.from, .to = body.to });
}

pub fn delete(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const Body = struct { paths: []const []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected paths");
        return;
    };
    if (body.paths.len == 0 or body.paths.len > 128) {
        ctx.fail(400, "bad_request", "invalid path count");
        return;
    }
    const ec = detect(ctx) orelse return;
    const Result = struct { path: []const u8, ok: bool, output: []const u8 };
    var results = std.array_list.Managed(Result).init(ctx.arena);
    for (body.paths) |path| {
        if (!validPath(path) or std.mem.eql(u8, path, "/")) {
            try results.append(.{ .path = path, .ok = false, .output = "invalid path" });
            continue;
        }
        const result = runInContainer(ctx, ec, id, &.{ "rm", "-rf", "--", path }, 1024 * 1024) catch {
            try results.append(.{ .path = path, .ok = false, .output = "engine unavailable" });
            continue;
        };
        try results.append(.{ .path = path, .ok = result.ok(), .output = textOf(result) });
    }
    try ctx.json(.{ .results = results.items });
}

pub fn download(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const path = requirePath(ctx) orelse return;
    const ec = detect(ctx) orelse return;
    const temp = try tempPath(ctx, "download");
    const source = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ id, path });
    const result = engine_mod.run(ctx.arena, ec.engine, ec.socket, &.{ ec.engine.name, "cp", source, temp }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        compat.deleteFileAbsolute(temp) catch {};
        ctx.fail(404, "not_found", textOf(result));
        return;
    }

    const name = compat.path.basename(path);
    const disposition = try http_validate.contentDisposition(ctx.arena, name);
    const headers = try ctx.arena.alloc(http_response.Header, 1);
    headers[0] = .{ .name = "Content-Disposition", .value = disposition };
    ctx.response = .{
        .status = 200,
        .content_type = "application/octet-stream",
        .file_path = temp,
        .delete_after_send = true,
        .extra = headers,
    };
}

pub fn upload(ctx: *context.Context) anyerror!void {
    if (unsupported(ctx)) return;
    const id = requireId(ctx) orelse return;
    const path = requirePath(ctx) orelse return;
    if (ctx.req.body.len == 0) {
        ctx.fail(400, "bad_request", "empty body");
        return;
    }
    const ec = detect(ctx) orelse return;
    const temp = try writeTemp(ctx, ctx.req.body);
    defer compat.deleteFileAbsolute(temp) catch {};
    const target = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ id, path });
    const result = engine_mod.run(ctx.arena, ec.engine, ec.socket, &.{ ec.engine.name, "cp", temp, target }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: uploaded container file id={s} path={s}", .{ id, path });
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .path = path, .size = ctx.req.body.len });
}

fn unsupported(ctx: *context.Context) bool {
    if (platform.is_windows) {
        ctx.fail(501, "unsupported", "容器文件浏览器仅在 Linux 上可用");
        return true;
    }
    return false;
}

fn detect(ctx: *context.Context) ?EngineCtx {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return null;
    };
    return .{ .engine = engine, .socket = socket };
}

fn runInContainer(
    ctx: *context.Context,
    ec: EngineCtx,
    id: []const u8,
    args: []const []const u8,
    max: usize,
) !exec.Result {
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.append(ec.engine.name);
    try argv.append("exec");
    try argv.append(id);
    try argv.appendSlice(args);
    return engine_mod.run(ctx.arena, ec.engine, ec.socket, argv.items, .{ .max_output = max });
}

fn requireId(ctx: *context.Context) ?[]const u8 {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return null;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return null;
    }
    return id;
}

fn requirePath(ctx: *context.Context) ?[]const u8 {
    const maybe_path = ctx.query("path") catch {
        ctx.fail(400, "bad_path", "missing path query parameter");
        return null;
    };
    const path = maybe_path orelse {
        ctx.fail(400, "bad_path", "missing path query parameter");
        return null;
    };
    if (!validPath(path)) {
        ctx.fail(400, "bad_path", "invalid container path");
        return null;
    }
    return path;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096) return false;
    return std.mem.indexOfScalar(u8, path, 0) == null;
}

fn tempPath(ctx: *context.Context, prefix: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "tmp" });
    compat.cwd().makePath(dir) catch {};
    var random: [6]u8 = undefined;
    compat.randomBytes(&random);
    return std.fmt.allocPrint(ctx.arena, "{s}/{s}-{s}", .{ dir, prefix, std.fmt.bytesToHex(random, .lower) });
}

fn writeTemp(ctx: *context.Context, bytes: []const u8) ![]const u8 {
    const path = try tempPath(ctx, "upload");
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(bytes);
    return path;
}

fn parseLsLine(allocator: std.mem.Allocator, line: []const u8) !?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "total ")) return null;

    var fields: [8][]const u8 = undefined;
    var index: usize = 0;
    var count: usize = 0;
    while (count < 8) {
        while (index < trimmed.len and (trimmed[index] == ' ' or trimmed[index] == '\t')) index += 1;
        if (index >= trimmed.len) return null;
        const start = index;
        while (index < trimmed.len and trimmed[index] != ' ' and trimmed[index] != '\t') index += 1;
        fields[count] = trimmed[start..index];
        count += 1;
    }
    while (index < trimmed.len and (trimmed[index] == ' ' or trimmed[index] == '\t')) index += 1;
    if (index >= trimmed.len) return null;

    var name = trimmed[index..];
    var symlink = false;
    if (std.mem.indexOf(u8, name, " -> ")) |arrow| {
        name = name[0..arrow];
        symlink = true;
    }
    const mode = fields[0];
    const kind = switch (mode[0]) {
        'd' => "dir",
        'l' => "symlink",
        '-' => "file",
        'b' => "block",
        'c' => "char",
        'p' => "pipe",
        's' => "socket",
        else => "other",
    };
    const modified = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ fields[5], fields[6], fields[7] });
    return .{
        .name = name,
        .kind = kind,
        .mode = mode,
        .size = std.fmt.parseInt(u64, fields[4], 10) catch 0,
        .modified = modified,
        .symlink = symlink,
    };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
