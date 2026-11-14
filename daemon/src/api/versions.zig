const std = @import("std");
const context = @import("context.zig");
const versions = @import("../versions.zig");
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn list(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const items = versions.list(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(.{ .path = path, .versions = items });
}

pub fn content(ctx: *context.Context) anyerror!void {
    const path = try requirePath(ctx);
    const id = (try ctx.query("id")) orelse {
        ctx.fail(400, "bad_request", "missing id");
        return;
    };
    var max_bytes: usize = 2 * 1024 * 1024;
    if (try ctx.query("max_bytes")) |raw| {
        max_bytes = std.fmt.parseInt(usize, raw, 10) catch max_bytes;
        max_bytes = std.math.clamp(max_bytes, 1, 8 * 1024 * 1024);
    }

    const result = versions.read(ctx.arena, ctx.app.config.data_dir, path, id, max_bytes) catch |err| {
        fail(ctx, err);
        return;
    };

    const Body = struct {
        path: []const u8,
        id: []const u8,
        size: u64,
        encoding: []const u8,
        truncated: bool,
        content: []const u8,
    };

    if (std.unicode.utf8ValidateSlice(result.bytes)) {
        try ctx.json(Body{
            .path = path,
            .id = id,
            .size = result.size,
            .encoding = "utf8",
            .truncated = result.truncated,
            .content = result.bytes,
        });
    } else {
        const encoded = try ctx.arena.alloc(u8, std.base64.standard.Encoder.calcSize(result.bytes.len));
        _ = std.base64.standard.Encoder.encode(encoded, result.bytes);
        try ctx.json(Body{
            .path = path,
            .id = id,
            .size = result.size,
            .encoding = "base64",
            .truncated = result.truncated,
            .content = encoded,
        });
    }
}

pub fn restore(ctx: *context.Context) anyerror!void {
    const Body = struct { path: []const u8, id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and id");
        return;
    };
    const outcome = versions.restore(ctx.arena, ctx.app.config.data_dir, body.path, body.id) catch |err| {
        fail(ctx, err);
        return;
    };
    var path_buf: [96]u8 = undefined;
    var id_buf: [96]u8 = undefined;
    log.info("versions: restored path={s} id={s}", .{
        redact.text(&path_buf, body.path),
        redact.text(&id_buf, body.id),
    });
    try ctx.json(outcome);
}

fn requirePath(ctx: *context.Context) ![]const u8 {
    const raw = (try ctx.query("path")) orelse {
        ctx.fail(400, "bad_request", "missing path");
        return error.BadPath;
    };
    return @import("../platform/mod.zig").files.resolve(ctx.arena, raw) catch {
        ctx.fail(400, "bad_path", "path must be absolute");
        return error.BadPath;
    };
}

fn fail(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidVersion") or errutil.named(err, "InvalidPath")) {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "VersionNotFound")) {
        ctx.fail(404, "version_not_found", "历史版本不存在");
    } else {
        ctx.fail(500, "version_failed", @errorName(err));
    }
}
