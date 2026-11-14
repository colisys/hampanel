const std = @import("std");
const context = @import("context.zig");
const notify = @import("../notify.zig");
const platform = @import("../platform/mod.zig");
const validate = @import("shared").validate;
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const services = platform.services.list(ctx.arena) catch |err| {
        ctx.fail(502, "services_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .services = services, .count = services.len });
}

pub fn action(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };

    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }

    const allowed = [_][]const u8{ "start", "stop", "restart", "reload", "enable", "disable" };
    var valid = false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, action_name, candidate)) valid = true;
    }
    if (!valid) {
        ctx.fail(400, "bad_action", "unsupported action");
        return;
    }

    const outcome = platform.services.action(ctx.arena, unit, action_name) catch |err| {
        ctx.fail(502, "services_failed", @errorName(err));
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var unit_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("services: {s} unit={s}", .{ action_name, redact.text(&unit_buf, unit) });
    } else {
        log.warn("services: {s} failed unit={s}", .{ action_name, redact.text(&unit_buf, unit) });
    }
    if (std.mem.eql(u8, action_name, "restart") and outcome.ok) {
        const body = std.fmt.allocPrint(ctx.arena, "服务 {s} 已重启", .{unit}) catch "服务已重启";
        notify.emit(ctx.app.db, .service_restart, "服务重启", body);
    }
    try ctx.json(.{
        .unit = unit,
        .action = action_name,
        .ok = outcome.ok,
        .output = outcome.output,
    });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }

    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    const text = platform.services.logs(ctx.arena, unit, lines) catch |err| {
        ctx.fail(502, "logs_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .unit = unit, .lines = text });
}
