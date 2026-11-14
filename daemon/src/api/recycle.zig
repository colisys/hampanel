const std = @import("std");
const context = @import("context.zig");
const recycle = @import("../recycle.zig");
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn list(ctx: *context.Context) anyerror!void {
    const entries = recycle.list(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(.{ .entries = entries });
}

pub fn restore(ctx: *context.Context) anyerror!void {
    const Body = struct { id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected id");
        return;
    };
    const outcome = recycle.restore(ctx.arena, ctx.app.config.data_dir, body.id) catch |err| {
        fail(ctx, err);
        return;
    };
    var id_buf: [96]u8 = undefined;
    log.info("recycle: restored id={s}", .{redact.text(&id_buf, body.id)});
    try ctx.json(outcome);
}

pub fn purge(ctx: *context.Context) anyerror!void {
    const Body = struct { id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected id");
        return;
    };
    const outcome = recycle.purge(ctx.arena, ctx.app.config.data_dir, body.id) catch |err| {
        fail(ctx, err);
        return;
    };
    var id_buf: [96]u8 = undefined;
    log.info("recycle: purged id={s}", .{redact.text(&id_buf, body.id)});
    try ctx.json(outcome);
}

pub fn empty(ctx: *context.Context) anyerror!void {
    const outcome = recycle.empty(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    log.info("recycle: emptied", .{});
    try ctx.json(outcome);
}

fn fail(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidId") or errutil.named(err, "InvalidPath") or errutil.named(err, "ReservedPath")) {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "TargetExists")) {
        ctx.fail(409, "target_exists", "原路径已存在同名文件或目录");
    } else if (errutil.named(err, "NotFound")) {
        ctx.fail(404, "not_found", "回收站项目不存在");
    } else {
        ctx.fail(500, "recycle_failed", @errorName(err));
    }
}
