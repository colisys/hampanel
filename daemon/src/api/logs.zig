const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");

pub fn sources(ctx: *context.Context) anyerror!void {
    const list = platform.logs.sources(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "logs_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .sources = list });
}

pub fn tail(ctx: *context.Context) anyerror!void {
    const id = (try ctx.query("source")) orelse "audit";
    const list = platform.logs.sources(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "logs_failed", @errorName(err));
        return;
    };

    for (list) |source| {
        if (std.mem.eql(u8, source.id, id)) {
            try tailPath(ctx, source.path);
            return;
        }
    }
    ctx.fail(404, "unknown_source", "unknown log source");
}

pub fn audit(ctx: *context.Context) anyerror!void {
    const path = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "audit.jsonl" });
    try tailPath(ctx, path);
}

fn tailPath(ctx: *context.Context, path: []const u8) !void {
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    var file = std.fs.openFileAbsolute(path, .{}) catch {
        ctx.fail(404, "not_found", "log file not found");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        ctx.fail(500, "stat_failed", "cannot stat log file");
        return;
    };
    const size: u64 = @intCast(stat.size);
    const window: u64 = @min(size, 512 * 1024);

    var content: []const u8 = "";
    var truncated = size > window;

    if (window > 0) {
        file.seekFromEnd(-@as(i64, @intCast(window))) catch {
            ctx.fail(500, "seek_failed", "cannot seek log file");
            return;
        };
        const buffer = try ctx.arena.alloc(u8, @intCast(window));
        const read = file.readAll(buffer) catch {
            ctx.fail(500, "read_failed", "cannot read log file");
            return;
        };

        var collected = std.ArrayList([]const u8).init(ctx.arena);
        var it = std.mem.splitScalar(u8, buffer[0..read], '\n');
        while (it.next()) |line| try collected.append(line);

        const start = if (collected.items.len > lines) collected.items.len - lines else 0;
        if (start > 0) truncated = true;
        content = try std.mem.join(ctx.arena, "\n", collected.items[start..]);
    }

    try ctx.json(.{
        .path = path,
        .lines = lines,
        .truncated = truncated,
        .content = content,
    });
}
