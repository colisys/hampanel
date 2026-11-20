const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const errutil = @import("../util/errors.zig");
const update = @import("../update.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const entries = platform.cron.list(ctx.arena) catch |err| {
        ctx.fail(502, "cron_failed", @errorName(err));
        return;
    };
    try ctx.json(.{
        .available = true,
        .entries = entries,
        .panelJobs = platform.cron.panel_jobs,
    });
}

pub fn add(ctx: *context.Context) anyerror!void {
    const Body = struct {
        schedule: []const u8,
        command: []const u8,
        /// "panel" for curated jobs, "user" for free-form crontab entries.
        kind: []const u8 = "user",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected schedule and command");
        return;
    };

    if (!validSchedule(body.schedule)) {
        ctx.fail(400, "bad_schedule", "schedule must be a five-field cron expression or @macro");
        return;
    }
    if (body.command.len == 0 or body.command.len > 512 or hasControlChars(body.command)) {
        ctx.fail(400, "bad_command", "command is empty, too long, or contains control characters");
        return;
    }
    const is_panel = std.mem.eql(u8, body.kind, "panel");
    if (!is_panel and !std.mem.eql(u8, body.kind, "user")) {
        ctx.fail(400, "bad_kind", "kind must be panel or user");
        return;
    }
    if (is_panel and platform.cron.panelJobFor(body.command) == null) {
        ctx.fail(400, "bad_panel_job", "panel jobs must use a curated command");
        return;
    }
    if (std.mem.eql(u8, ctx.app.config.install_mode, "source") and update.isUpdateCommand(body.command)) {
        ctx.fail(400, "update_disabled", "source installs cannot schedule update checks");
        return;
    }

    const outcome = platform.cron.add(ctx.arena, body.schedule, body.command, body.kind) catch |err| {
        if (err == error.UnknownPanelJob) {
            ctx.fail(400, "bad_panel_job", "panel jobs must use a curated command");
        } else if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "scheduled jobs are not available on this platform");
        } else {
            ctx.fail(502, "cron_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var schedule_buf: [96]u8 = undefined;
    // The command is arbitrary shell text and can embed credentials, so only
    // the schedule is logged.
    if (outcome.ok) {
        log.info("cron: added schedule={s}", .{redact.text(&schedule_buf, body.schedule)});
    } else {
        log.warn("cron: add failed schedule={s}", .{redact.text(&schedule_buf, body.schedule)});
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn remove(ctx: *context.Context) anyerror!void {
    const Body = struct { id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected id");
        return;
    };
    if (body.id.len == 0 or body.id.len > 128 or hasControlChars(body.id)) {
        ctx.fail(400, "bad_id", "invalid id");
        return;
    }

    const outcome = platform.cron.remove(ctx.arena, body.id) catch |err| {
        if (errutil.isJobNotFound(err)) {
            ctx.fail(404, "not_found", "job not found");
        } else if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "scheduled jobs are not available on this platform");
        } else {
            ctx.fail(502, "cron_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var id_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("cron: removed id={s}", .{redact.text(&id_buf, body.id)});
    } else {
        log.warn("cron: remove failed id={s}", .{redact.text(&id_buf, body.id)});
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn validSchedule(schedule: []const u8) bool {
    if (schedule.len == 0 or schedule.len > 128) return false;

    var count: usize = 0;
    var macro = false;
    var it = std.mem.tokenizeAny(u8, schedule, " \t");
    while (it.next()) |token| {
        count += 1;
        if (token.len > 0 and token[0] == '@') macro = true;
        for (token) |ch| {
            if (std.ascii.isAlphanumeric(ch)) continue;
            if (ch == '*' or ch == ',' or ch == '/' or ch == '-' or ch == '?' or ch == '@') continue;
            return false;
        }
    }

    if (macro) return count == 1 and schedule[0] == '@';
    return count == 5;
}

fn hasControlChars(value: []const u8) bool {
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}
