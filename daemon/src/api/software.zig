const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn list(ctx: *context.Context) anyerror!void {
    const items = platform.software.list(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "software_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .items = items });
}

pub fn initialize(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing software id");
        return;
    };
    const outcome = platform.software.initialize(ctx.arena, ctx.app.config.data_dir, id) catch |err| {
        fail(ctx, err);
        return;
    };
    var id_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("software: initialized id={s}", .{redact.text(&id_buf, id)});
    } else {
        log.warn("software: initialize failed id={s}", .{redact.text(&id_buf, id)});
    }
    try ctx.json(outcome);
}

pub fn fail2banStatus(ctx: *context.Context) anyerror!void {
    const status = platform.fail2ban.status(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(status);
}

pub fn fail2banBan(ctx: *context.Context) anyerror!void {
    const Body = struct { jail: []const u8, ip: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected jail and ip");
        return;
    };
    const outcome = platform.fail2ban.ban(ctx.arena, body.jail, body.ip) catch |err| {
        fail(ctx, err);
        return;
    };
    var jail_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("fail2ban: ban jail={s} ip={s}", .{ redact.text(&jail_buf, body.jail), body.ip });
    } else {
        log.warn("fail2ban: ban failed jail={s} ip={s}", .{ redact.text(&jail_buf, body.jail), body.ip });
    }
    try ctx.json(outcome);
}

pub fn fail2banUnban(ctx: *context.Context) anyerror!void {
    const Body = struct { jail: []const u8, ip: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected jail and ip");
        return;
    };
    const outcome = platform.fail2ban.unban(ctx.arena, body.jail, body.ip) catch |err| {
        fail(ctx, err);
        return;
    };
    var jail_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("fail2ban: unban jail={s} ip={s}", .{ redact.text(&jail_buf, body.jail), body.ip });
    } else {
        log.warn("fail2ban: unban failed jail={s} ip={s}", .{ redact.text(&jail_buf, body.jail), body.ip });
    }
    try ctx.json(outcome);
}

pub fn fail2banLimits(ctx: *context.Context) anyerror!void {
    const Body = struct {
        maxretry: u32,
        bantime: u32,
        findtime: u32,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected maxretry, bantime and findtime");
        return;
    };
    const outcome = platform.fail2ban.setLimits(
        ctx.arena,
        ctx.app.config.data_dir,
        body.maxretry,
        body.bantime,
        body.findtime,
    ) catch |err| {
        fail(ctx, err);
        return;
    };
    log.info("fail2ban: limits maxretry={d} bantime={d} findtime={d}", .{
        body.maxretry,
        body.bantime,
        body.findtime,
    });
    try ctx.json(outcome);
}

fn fail(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "NotInstalled")) {
        ctx.fail(400, "not_installed", "软件尚未安装");
    } else if (errutil.named(err, "UnknownSoftware")) {
        ctx.fail(404, "unknown_software", "unsupported software");
    } else if (errutil.named(err, "NotInitialized")) {
        ctx.fail(409, "not_initialized", "请先完成初始化");
    } else if (errutil.named(err, "InvalidJail") or errutil.named(err, "InvalidIP") or errutil.named(err, "InvalidLimits")) {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "Fail2banUnavailable")) {
        ctx.fail(502, "fail2ban_unavailable", "fail2ban-client 不可用");
    } else if (errutil.isUnsupported(err)) {
        ctx.fail(501, "unsupported", "该功能在当前平台不可用");
    } else {
        ctx.fail(500, "software_failed", @errorName(err));
    }
}
