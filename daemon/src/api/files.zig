const std = @import("std");
const http_validate = @import("../http/validate.zig");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const recycle = @import("../recycle.zig");
const versions = @import("../versions.zig");
const http_response = @import("../http/response.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");
const accounts_util = @import("../util/accounts.zig");
const exec = @import("shared").exec;

const Entry = struct {
    name: []const u8,
    path: []const u8,
    kind: []const u8,
    size: u64,
    mode: []const u8,
    owner: []const u8,
    group: []const u8,
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

    const accounts = accounts_util.load(a) catch null;
    var entries = std.array_list.Managed(Entry).init(a);
    var it = dir.iterate();
    while (try it.next()) |item| {
        if (entries.items.len >= 3000) break;
        const full = try compat.path.join(a, &.{ path, item.name });
        const meta = platform.files.stat(a, full) catch null;
        const uid = if (meta) |m| m.uid else 0;
        const gid = if (meta) |m| m.gid else 0;
        const owner = if (!platform.is_windows)
            if (accounts) |acc| (acc.user(uid) orelse try std.fmt.allocPrint(a, "{d}", .{uid})) else try std.fmt.allocPrint(a, "{d}", .{uid})
        else
            "";
        const group = if (!platform.is_windows)
            if (accounts) |acc| (acc.group(gid) orelse try std.fmt.allocPrint(a, "{d}", .{gid})) else try std.fmt.allocPrint(a, "{d}", .{gid})
        else
            "";

        try entries.append(.{
            .name = try a.dupe(u8, item.name),
            .path = full,
            .kind = if (meta) |m| m.kind else kindName(item.kind),
            .size = if (meta) |m| m.size else 0,
            .mode = if (meta) |m| m.mode else "----------",
            .owner = owner,
            .group = group,
            .uid = uid,
            .gid = gid,
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
    var path_buf: [96]u8 = undefined;
    log.info("files: wrote path={s} bytes={d}", .{
        redact.text(&path_buf, path),
        decoded.len,
    });
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
    var path_buf: [96]u8 = undefined;
    log.info("files: mkdir path={s}", .{redact.text(&path_buf, path)});
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
    var from_buf: [96]u8 = undefined;
    var to_buf: [96]u8 = undefined;
    log.info("files: renamed from={s} to={s}", .{
        redact.text(&from_buf, from),
        redact.text(&to_buf, to),
    });
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

    var moved: usize = 0;
    for (results.items) |entry| {
        if (entry.ok) moved += 1;
    }
    log.info("files: delete moved={d} failed={d}", .{ moved, results.items.len - moved });

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
    const disposition = try http_validate.contentDisposition(ctx.arena, name);
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

    var temp = parent_dir.createFile(temp_name, .{ .exclusive = true, .mode = 0o644 }) catch |err| {
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

    var path_buf: [96]u8 = undefined;
    log.info("files: uploaded path={s} bytes={d}", .{
        redact.text(&path_buf, path),
        ctx.req.body.len,
    });
    try ctx.json(.{ .path = path, .size = ctx.req.body.len });
}

/// File metadata for the permission editor. Runs `file(1)` to decide whether
/// the target is text; an unknown/binary type makes `text` false.
pub fn fileMeta(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const a = ctx.arena;
    const info = platform.files.stat(a, path) catch {
        ctx.fail(404, "not_found", "file not found");
        return;
    };
    const account_lookup = accounts_util.load(a) catch null;
    var owner_buf: [24]u8 = undefined;
    var group_buf: [24]u8 = undefined;
    const owner = if (account_lookup) |acc|
        (acc.user(info.uid) orelse std.fmt.bufPrint(&owner_buf, "{d}", .{info.uid}) catch "?")
    else
        std.fmt.bufPrint(&owner_buf, "{d}", .{info.uid}) catch "?";
    const group = if (account_lookup) |acc|
        (acc.group(info.gid) orelse std.fmt.bufPrint(&group_buf, "{d}", .{info.gid}) catch "?")
    else
        std.fmt.bufPrint(&group_buf, "{d}", .{info.gid}) catch "?";
    const mime = fileMime(a, path) catch "";
    const is_dir = std.mem.eql(u8, info.kind, "dir");
    const text = is_dir or mime.len == 0 or isTextMime(mime);
    try ctx.json(.{
        .path = path,
        .size = info.size,
        .kind = info.kind,
        .mode = info.mode,
        .mode_bits = info.mode_bits,
        .uid = info.uid,
        .gid = info.gid,
        .owner = owner,
        .group = group,
        .mime = mime,
        .text = text,
        .symlink = info.symlink,
    });
}

pub fn fileAccounts(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    const lookup = accounts_util.load(a) catch {
        ctx.fail(500, "accounts_failed", "cannot read system accounts");
        return;
    };
    const AccountEntry = struct {
        id: u32,
        name: []const u8,

        fn lessThan(_: void, left: @This(), right: @This()) bool {
            return left.id < right.id;
        }
    };
    var users = std.array_list.Managed(AccountEntry).init(a);
    var user_it = lookup.users.iterator();
    while (user_it.next()) |entry| {
        try users.append(.{ .id = entry.key_ptr.*, .name = entry.value_ptr.* });
    }
    var groups = std.array_list.Managed(AccountEntry).init(a);
    var group_it = lookup.groups.iterator();
    while (group_it.next()) |entry| {
        try groups.append(.{ .id = entry.key_ptr.*, .name = entry.value_ptr.* });
    }
    std.mem.sort(AccountEntry, users.items, {}, struct {
        fn lt(_: void, left: AccountEntry, right: AccountEntry) bool {
            return left.id < right.id;
        }
    }.lt);
    std.mem.sort(AccountEntry, groups.items, {}, struct {
        fn lt(_: void, left: AccountEntry, right: AccountEntry) bool {
            return left.id < right.id;
        }
    }.lt);
    try ctx.json(.{ .users = users.items, .groups = groups.items });
}

pub fn permissions(ctx: *context.Context) anyerror!void {
    const Body = struct {
        path: []const u8,
        mode: u32,
        uid: ?u32 = null,
        gid: ?u32 = null,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and mode");
        return;
    };
    const path = resolvePath(ctx, body.path) catch return;
    if (body.mode > 0o7777) {
        ctx.fail(400, "bad_mode", "mode must fit in 0o7777");
        return;
    }
    if (body.uid == null and body.gid == null and body.mode == 0) {
        ctx.fail(400, "bad_request", "nothing to change");
        return;
    }
    const current = platform.files.stat(ctx.arena, path) catch {
        ctx.fail(404, "not_found", "file not found");
        return;
    };
    const file = compat.openFileAbsolute(path, .{ .allow_directory = true }) catch {
        ctx.fail(404, "not_found", "file not found");
        return;
    };
    defer file.close();
    file.chmod(body.mode) catch |err| {
        ctx.fail(403, "chmod_failed", @errorName(err));
        return;
    };
    // Only chown when the owner actually changes: a needless chown fails for
    // non-root daemons and is a no-op on most files anyway.
    const uid_changed = body.uid != null and body.uid.? != current.uid;
    const gid_changed = body.gid != null and body.gid.? != current.gid;
    if (uid_changed or gid_changed) {
        const uid: ?std.Io.File.Uid = if (uid_changed) @intCast(body.uid.?) else null;
        const gid: ?std.Io.File.Gid = if (gid_changed) @intCast(body.gid.?) else null;
        file.chown(uid, gid) catch |err| {
            ctx.fail(403, "chown_failed", @errorName(err));
            return;
        };
    }
    log.info("files: permissions mode={o} path updated", .{body.mode});
    try ctx.json(.{
        .ok = true,
        .path = path,
        .mode = body.mode,
        .uid = body.uid,
        .gid = body.gid,
    });
}

fn fileMime(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const result = exec.run(allocator, &.{ "file", "-b", "--mime-type", "--", path }, 4096) catch return "";
    if (!result.ok()) return "";
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

fn isTextMime(mime: []const u8) bool {
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    const allowed = [_][]const u8{
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-shellscript",
        "application/x-yaml",
        "application/yaml",
        "application/toml",
        "application/x-empty",
        "inode/x-empty",
    };
    for (allowed) |candidate| {
        if (std.mem.eql(u8, mime, candidate)) return true;
    }
    return false;
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
