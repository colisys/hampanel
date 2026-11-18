const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const update = @import("../update.zig");
const version = @import("../version.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    try indexUnlocked(ctx);
}

fn indexUnlocked(ctx: *context.Context) anyerror!void {
    const cfg = ctx.app.config;
    const state = update.loadState(ctx.arena, ctx.app.db);
    try ctx.json(.{
        .install_mode = cfg.install_mode,
        .channel = cfg.update_channel,
        .current_version = version.version,
        .latest_version = state.latest_version,
        .update_available = state.update_available,
        .checked_at = state.checked_at,
        .error_message = state.error_message,
        .scheduled = update.scheduleInstalled(ctx.arena),
        .updatable = cfg.updatesEnabled(),
        .github_mirror = cfg.github_mirror,
    });
}

pub fn configure(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    const Body = struct {
        channel: ?[]const u8 = null,
        github_mirror: ?[]const u8 = null,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected channel or github_mirror");
        return;
    };

    var candidate = ctx.app.config;
    if (body.channel) |channel| {
        if (!std.mem.eql(u8, channel, "stable") and
            !std.mem.eql(u8, channel, "nightly") and
            !std.mem.eql(u8, channel, "latest"))
        {
            ctx.fail(400, "bad_channel", "channel must be stable or nightly");
            return;
        }
        candidate.update_channel = channel;
    }

    if (body.github_mirror) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
        const valid = trimmed.len == 0 or
            (trimmed.len <= 200 and
                (std.mem.startsWith(u8, trimmed, "https://") or
                    std.mem.startsWith(u8, trimmed, "http://")));
        if (!valid) {
            ctx.fail(400, "bad_mirror", "mirror must be an http(s) URL");
            return;
        }
        candidate.github_mirror = trimmed;
    }

    ctx.app.saveUpdateConfig(ctx.arena, candidate) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    var mirror_buf: [96]u8 = undefined;
    log.info("update: config channel={s} mirror={s}", .{
        ctx.app.config.update_channel,
        redact.text(&mirror_buf, ctx.app.config.github_mirror),
    });
    try indexUnlocked(ctx);
}

pub fn check(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    const state = update.check(ctx.arena, ctx.app.db, ctx.app.config);
    log.info("update: checked current={s} latest={s} available={}", .{
        state.current_version,
        state.latest_version,
        state.update_available,
    });
    try ctx.json(.{
        .current_version = state.current_version,
        .latest_version = state.latest_version,
        .update_available = state.update_available,
        .checked_at = state.checked_at,
        .error_message = state.error_message,
    });
}

pub fn apply(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    const outcome = update.apply(ctx.arena, ctx.app.db, ctx.app.config) catch |err| switch (err) {
        error.UpdateDisabled => {
            ctx.fail(409, "update_disabled", "update channel is disabled for source installs");
            return;
        },
        error.NothingToDo => {
            ctx.fail(409, "up_to_date", "already running the latest version");
            return;
        },
        error.UnsupportedPlatform => {
            ctx.fail(501, "unsupported", "automatic updates are not supported on this platform");
            return;
        },
        else => {
            ctx.fail(502, "update_failed", @errorName(err));
            return;
        },
    };
    var message_buf: [96]u8 = undefined;
    log.info("update: applied updated={} message={s}", .{
        outcome.updated,
        redact.text(&message_buf, outcome.message),
    });
    try ctx.json(.{ .ok = outcome.updated, .message = outcome.message });
}

pub fn schedule(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    const self_exe = try compat.selfExePathAlloc(ctx.arena);
    const outcome = update.installSchedule(
        ctx.arena,
        ctx.app.config,
        self_exe,
        ctx.app.config_path,
    ) catch |err| switch (err) {
        error.UpdateDisabled => {
            ctx.fail(409, "update_disabled", "source installs cannot schedule update checks");
            return;
        },
        else => {
            ctx.fail(502, "schedule_failed", @errorName(err));
            return;
        },
    };
    if (!outcome.installed) {
        ctx.fail(502, "schedule_failed", outcome.message);
        return;
    }
    log.info("update: schedule installed", .{});
    try ctx.json(.{ .ok = true, .scheduled = true, .message = outcome.message });
}

pub fn unschedule(ctx: *context.Context) anyerror!void {
    ctx.app.update_mutex.lockUncancelable(compat.io());
    defer ctx.app.update_mutex.unlock(compat.io());
    const outcome = update.removeSchedule(ctx.arena) catch |err| {
        ctx.fail(502, "schedule_failed", @errorName(err));
        return;
    };
    log.info("update: schedule removed", .{});
    try ctx.json(.{ .ok = true, .scheduled = false, .message = outcome.message });
}

test "configure rejects partial changes and preserves config on save failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app: @import("../app.zig").App = undefined;
    app.allocator = std.testing.allocator;
    app.config = .{};
    app.update_mutex = .init;
    app.owned_update_channel = null;
    app.owned_github_mirror = null;
    defer app.deinitUpdateConfig();
    var ctx: context.Context = undefined;
    ctx.app = &app;
    ctx.arena = arena.allocator();
    ctx.response = .{};
    ctx.req.body = "{\"channel\":\"nightly\",\"github_mirror\":\"invalid\"}";
    try configure(&ctx);
    try std.testing.expectEqual(@as(u16, 400), ctx.response.status);
    try std.testing.expectEqualStrings("stable", app.config.update_channel);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    app.config_path = dir;
    ctx.req.body = "{\"channel\":\"nightly\"}";
    try configure(&ctx);
    try std.testing.expectEqual(@as(u16, 500), ctx.response.status);
    try std.testing.expectEqualStrings("stable", app.config.update_channel);
    try std.testing.expect(app.owned_update_channel == null);
}
