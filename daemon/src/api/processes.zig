const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const limit_raw = try ctx.query("limit");
    var limit: usize = 200;
    if (limit_raw) |raw| {
        limit = std.fmt.parseInt(usize, raw, 10) catch 200;
        limit = @min(limit, 1000);
    }

    const list = platform.processes.list(ctx.arena, limit) catch |err| {
        ctx.fail(500, "processes_failed", @errorName(err));
        return;
    };
    try ctx.json(list);
}
