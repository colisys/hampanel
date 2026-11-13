const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const recycle = @import("../recycle.zig");
const versions = @import("../versions.zig");
const http_response = @import("../http/response.zig");

const Entry = struct {
    name: []const u8,
    path: []const u8,
    kind: []const u8,
    size: u64,
    mode: []const u8,
    uid: u32,
    gid: u32,
    modified_ms: i64,
    symlink: bool,
};

pub fn list(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const a = ctx.arena;

    var dir = compat.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        ctx.fail(404, "not_found", @errorName(err));
        return;
    };
    defer dir.close();

    var entries = std.array_list.Managed(Entry).init(a);
    var it = dir.iterate();
    while (try it.next()) |item| {
        if (entries.items.len >= 3000) break;
        const full = try compat.path.join(a, &.{ path, item.name });
        const meta = platform.files.stat(a, full) catch null;

        try entries.append(.{
            .name = try a.dupe(u8, item.name),
            .path = full,
            .kind = if (meta) |m| m.kind else kindName(item.kind),
            .size = if (meta) |m| m.size else 0,
            .mode = if (meta) |m| m.mode else "----------",
            .uid = if (meta) |m| m.uid else 0,
            .gid = if (meta) |m| m.gid else 0,
            .modified_ms = if (meta) |m| m.modified_ms else 0,
            .symlink = if (meta) |m| m.symlink else item.kind == .sym_link,
        });
    }

    std.sort.pdq(Entry, entries.items, {}, struct {
        fn lessThan(_: void, left: Entry, right: Entry) bool {
            const left_dir = std.mem.eql(u8, left.kind, "dir");
            const right_dir = std.mem.eql(u8, right.kind, "dir");
            if (left_dir != right_dir) return left_dir;
            return std.ascii.lessThanIgnoreCase(left.name, right.name);
        }
    }.lessThan);

    const Body = struct {
        path: []const u8,
        entries: []const Entry,
    };
    try ctx.json(Body{ .path = path, .entries = entries.items });
}

pub fn content(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const a = ctx.arena;

    var max_bytes: usize = 2 * 1024 * 1024;
    if (try ctx.query("max_bytes")) |raw| {
        max_bytes = std.fmt.parseInt(usize, raw, 10) catch max_bytes;
        max_bytes = @min(max_bytes, 16 * 1024 * 1024);
    }

    const meta = platform.files.stat(a, path) catch {
        ctx.fail(404, "not_found", "file not found");
        return;
    };
    if (std.mem.eql(u8, meta.kind, "dir")) {
        ctx.fail(400, "is_directory", "path is a directory");
        return;
    }

    const file = compat.openFileAbsolute(path, .{}) catch |err| {
        ctx.fail(404, "not_found", @errorName(err));
        return;
    };
    defer file.close();

    const to_read: usize = @intCast(@min(meta.size, max_bytes));
    const buffer = try a.alloc(u8, to_read);
    const read = file.readAll(buffer) catch {
        ctx.fail(500, "read_failed", "cannot read file");
        return;
    };

    const Body = struct {
        path: []const u8,
        size: u64,
        modified_ms: i64,
        encoding: []const u8,
        truncated: bool,
        content: []const u8,
    };

    if (std.unicode.utf8ValidateSlice(buffer[0..read])) {
        try ctx.json(Body{
            .path = path,
            .size = meta.size,
            .modified_ms = meta.modified_ms,
            .encoding = "utf8",
            .truncated = meta.size > read,
            .content = buffer[0..read],
        });
    } else {
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(read));
        _ = std.base64.standard.Encoder.encode(encoded, buffer[0..read]);
        try ctx.json(Body{
            .path = path,
            .size = meta.size,
            .modified_ms = meta.modified_ms,
            .encoding = "base64",
            .truncated = meta.size > read,
            .content = encoded,
        });
    }
}

pub fn write(ctx: *context.Context) anyerror!void {
    const Body = struct {
        path: []const u8,
        content: []const u8,
        encoding: []const u8 = "utf8",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and content");
        return;
    };

    const path = resolvePath(ctx, body.path) catch return;

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

    _ = versions.snapshot(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
        ctx.fail(500, "version_failed", @errorName(err));
        return;
    };

    var file = compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 }) catch |err| {
        ctx.fail(400, "write_failed", @errorName(err));
        return;
    };
    defer file.close();
    try file.writeAll(decoded);

    const Result = struct { path: []const u8, size: usize };
    try ctx.json(Result{ .path = path, .size = decoded.len });
}

pub fn mkdir(ctx: *context.Context) anyerror!void {
    const Body = struct {
        path: []const u8,
        recursive: bool = true,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path");
        return;
    };
    const path = resolvePath(ctx, body.path) catch return;

    if (body.recursive) {
        compat.cwd().makePath(path) catch |err| {
            ctx.fail(400, "mkdir_failed", @errorName(err));
            return;
        };
    } else {
        compat.makeDirAbsolute(path, 0o777) catch |err| {
            ctx.fail(400, "mkdir_failed", @errorName(err));
            return;
        };
    }
    const Result = struct { path: []const u8 };
    try ctx.json(Result{ .path = path });
}

pub fn rename(ctx: *context.Context) anyerror!void {
    const Body = struct {
        from: []const u8,
        to: []const u8,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected from and to");
        return;
    };
    const from = resolvePath(ctx, body.from) catch return;
    const to = resolvePath(ctx, body.to) catch return;

    compat.renameAbsolute(from, to) catch |err| {
        ctx.fail(400, "rename_failed", @errorName(err));
        return;
    };
    const Result = struct { from: []const u8, to: []const u8 };
    try ctx.json(Result{ .from = from, .to = to });
}

pub fn delete(ctx: *context.Context) anyerror!void {
    const Body = struct { paths: []const []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected paths array");
        return;
    };
    if (body.paths.len == 0) {
        ctx.fail(400, "bad_request", "paths array is empty");
        return;
    }
    if (body.paths.len > 256) {
        ctx.fail(400, "bad_request", "too many paths in one request");
        return;
    }

    const Result = struct { path: []const u8, ok: bool, message: []const u8, recycle_id: ?[]const u8 = null };
    var results = std.array_list.Managed(Result).init(ctx.arena);

    for (body.paths) |raw| {
        const path = resolvePath(ctx, raw) catch {
            try results.append(.{ .path = raw, .ok = false, .message = "invalid path" });
            continue;
        };
        const entry = recycle.move(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
            try results.append(.{ .path = path, .ok = false, .message = @errorName(err) });
            continue;
        };
        try results.append(.{
            .path = path,
            .ok = true,
            .message = "moved to recycle bin",
            .recycle_id = entry.id,
        });
    }

    try ctx.json(.{ .results = results.items });
}

pub fn download(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const meta = platform.files.stat(ctx.arena, path) catch {
        ctx.fail(404, "not_found", "file not found");
        return;
    };
    if (std.mem.eql(u8, meta.kind, "dir")) {
        ctx.fail(400, "is_directory", "cannot download a directory");
        return;
    }

    const name = compat.path.basename(path);
    const disposition = try std.fmt.allocPrint(ctx.arena, "attachment; filename=\"{s}\"", .{name});
    const headers = try ctx.arena.alloc(http_response.Header, 1);
    headers[0] = .{ .name = "Content-Disposition", .value = disposition };

    ctx.response = .{
        .status = 200,
        .content_type = "application/octet-stream",
        .file_path = path,
        .extra = headers,
    };
}

pub fn upload(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    if (ctx.req.body.len == 0) {
        ctx.fail(400, "bad_request", "empty body");
        return;
    }
    const parent = compat.path.dirname(path) orelse {
        ctx.fail(400, "bad_path", "path has no parent directory");
        return;
    };
    var parent_dir = compat.openDirAbsolute(parent, .{}) catch {
        ctx.fail(404, "not_found", "parent directory does not exist");
        return;
    };
    defer parent_dir.close();

    _ = versions.snapshot(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
        ctx.fail(500, "version_failed", @errorName(err));
        return;
    };

    var random: [6]u8 = undefined;
    compat.randomBytes(&random);
    const temp_name = try std.fmt.allocPrint(ctx.arena, ".hampanel-upload-{s}", .{std.fmt.bytesToHex(random, .lower)});

    var temp = parent_dir.createFile(temp_name, .{ .truncate = true, .mode = 0o644 }) catch |err| {
        ctx.fail(400, "write_failed", @errorName(err));
        return;
    };
    temp.writeAll(ctx.req.body) catch |err| {
        temp.close();
        parent_dir.deleteFile(temp_name) catch {};
        ctx.fail(500, "write_failed", @errorName(err));
        return;
    };
    temp.close();

    compat.renameAbsolute(try compat.path.join(ctx.arena, &.{ parent, temp_name }), path) catch |err| {
        parent_dir.deleteFile(temp_name) catch {};
        ctx.fail(400, "rename_failed", @errorName(err));
        return;
    };

    try ctx.json(.{ .path = path, .size = ctx.req.body.len });
}

fn requirePath(ctx: *context.Context) ![]const u8 {
    const raw = (try ctx.query("path")) orelse {
        ctx.fail(400, "bad_path", "missing path query parameter");
        return error.BadPath;
    };
    return resolvePath(ctx, raw);
}

fn resolvePath(ctx: *context.Context, raw: []const u8) ![]const u8 {
    return platform.files.resolve(ctx.arena, raw) catch {
        ctx.fail(400, "bad_path", "path must be absolute and free of null bytes");
        return error.BadPath;
    };
}

fn kindName(kind: compat.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "dir",
        .sym_link => "symlink",
        .file => "file",
        .block_device => "block",
        .character_device => "char",
        .named_pipe => "pipe",
        .unix_domain_socket => "socket",
        else => "other",
    };
}
