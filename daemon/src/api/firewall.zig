const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const validate = @import("shared").validate;
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const status = platform.firewall.status(ctx.arena) catch |err| {
        ctx.fail(502, "firewall_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn add(ctx: *context.Context) anyerror!void {
    const Body = struct {
        action: []const u8 = "allow",
        port: []const u8,
        from: []const u8 = "",
        comment: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected port");
        return;
    };

    if (!std.mem.eql(u8, body.action, "allow") and
        !std.mem.eql(u8, body.action, "deny") and
        !std.mem.eql(u8, body.action, "limit"))
    {
        ctx.fail(400, "bad_action", "action must be allow, deny or limit");
        return;
    }
    if (!validate.isPortSpec(body.port)) {
        ctx.fail(400, "bad_port", "port must look like 80 or 80/tcp");
        return;
    }
    if (body.from.len > 0 and !validate.isIpOrCidr(body.from)) {
        ctx.fail(400, "bad_source", "from must be an IP address or CIDR");
        return;
    }
    if (hasControlChars(body.comment) or body.comment.len > 128) {
        ctx.fail(400, "bad_comment", "comment is too long or contains control characters");
        return;
    }

    const outcome = platform.firewall.add(ctx.arena, body.action, body.port, body.from, body.comment) catch |err| {
        ctx.fail(502, "firewall_failed", @errorName(err));
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var source_buf: [96]u8 = undefined;
    const source = if (body.from.len == 0) "any" else redact.text(&source_buf, body.from);
    if (outcome.ok) {
        log.info("firewall: added action={s} port={s} source={s}", .{ body.action, body.port, source });
    } else {
        log.warn("firewall: add failed action={s} port={s}", .{ body.action, body.port });
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn remove(ctx: *context.Context) anyerror!void {
    const Body = struct { id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected rule id");
        return;
    };
    if (body.id.len == 0 or body.id.len > 256 or hasControlChars(body.id)) {
        ctx.fail(400, "bad_id", "invalid rule id");
        return;
    }

    const outcome = platform.firewall.remove(ctx.arena, body.id) catch |err| {
        if (errutil.isInvalidRuleId(err)) {
            ctx.fail(400, "bad_id", "invalid rule id");
        } else {
            ctx.fail(502, "firewall_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var id_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("firewall: removed id={s}", .{redact.text(&id_buf, body.id)});
    } else {
        log.warn("firewall: remove failed id={s}", .{redact.text(&id_buf, body.id)});
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn hasControlChars(value: []const u8) bool {
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}
