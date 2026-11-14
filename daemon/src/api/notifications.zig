const std = @import("std");
const context = @import("context.zig");
const notify = @import("../notify.zig");
const log = @import("../log.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const config = notify.load(ctx.arena, ctx.app.db);
    try ctx.json(config);
}

pub fn update(ctx: *context.Context) anyerror!void {
    const body = ctx.requireJson(notify.Config) catch {
        ctx.fail(400, "bad_request", "expected notification config");
        return;
    };
    if (notify.validate(body)) |message| {
        ctx.fail(400, "bad_config", message);
        return;
    }
    notify.save(ctx.arena, ctx.app.db, body) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    // Provider secrets (Bark key, ntfy token) stay out of the log; only the
    // enabled flags are recorded.
    log.info("notifications: updated bark={} ntfy={}", .{ body.bark_enabled, body.ntfy_enabled });
    try ctx.json(body);
}

pub fn testSend(ctx: *context.Context) anyerror!void {
    const Body = struct { provider: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected provider: bark|ntfy");
        return;
    };
    const provider: notify.Provider = if (std.mem.eql(u8, body.provider, "bark"))
        .bark
    else if (std.mem.eql(u8, body.provider, "ntfy"))
        .ntfy
    else {
        ctx.fail(400, "bad_provider", "provider must be bark or ntfy");
        return;
    };
    const config = notify.load(ctx.arena, ctx.app.db);
    const outcome = notify.sendProvider(
        ctx.arena,
        config,
        provider,
        "Hampanel 测试通知",
        "这是一条来自 Hampanel 的测试推送。",
    );
    log.info("notifications: test provider={s} ok={}", .{ body.provider, outcome.ok });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}
