const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const update = @import("../update.zig");
const version = @import("../version.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
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
    });
}

pub fn check(ctx: *context.Context) anyerror!void {
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
    const outcome = update.removeSchedule(ctx.arena) catch |err| {
        ctx.fail(502, "schedule_failed", @errorName(err));
        return;
    };
    log.info("update: schedule removed", .{});
    try ctx.json(.{ .ok = true, .scheduled = false, .message = outcome.message });
}
