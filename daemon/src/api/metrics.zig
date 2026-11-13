const context = @import("context.zig");
const platform = @import("../platform/mod.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const metrics = platform.metrics.sample(ctx.arena, &ctx.app.metrics) catch |err| {
        ctx.fail(500, "metrics_failed", @errorName(err));
        return;
    };
    try ctx.json(metrics);
}
