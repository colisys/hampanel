const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const validate = @import("shared").validate;
const errutil = @import("../util/errors.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const list = platform.sites.list(ctx.arena) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    try ctx.json(list);
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        domains: []const []const u8,
        root: []const u8,
        port: u16 = 80,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name, domains and root");
        return;
    };

    if (!validate.isSlug(body.name)) {
        ctx.fail(400, "bad_name", "site name must be a short slug");
        return;
    }
    if (body.domains.len == 0 or body.domains.len > 32) {
        ctx.fail(400, "bad_domains", "provide between 1 and 32 domains");
        return;
    }
    for (body.domains) |domain| {
        if (!validate.isHostname(domain)) {
            ctx.fail(400, "bad_domains", "invalid domain name");
            return;
        }
    }
    if (!isSafeRoot(body.root)) {
        ctx.fail(400, "bad_root", "root must be an absolute path without control characters");
        return;
    }
    if (body.port == 0) {
        ctx.fail(400, "bad_port", "port must be between 1 and 65535");
        return;
    }

    const outcome = platform.sites.create(ctx.arena, body.name, body.domains, body.root, body.port) catch |err| {
        if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "site management is not available on this platform");
        } else {
            ctx.fail(500, "sites_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 400;
    var name_buf: [96]u8 = undefined;
    const safe_name = redact.text(&name_buf, body.name);
    if (outcome.ok) {
        log.info("sites: created name={s} domains={d}", .{ safe_name, body.domains.len });
    } else {
        log.warn("sites: create failed name={s}", .{safe_name});
    }
    try ctx.json(.{
        .name = body.name,
        .ok = outcome.ok,
        .output = outcome.output,
    });
}

pub fn toggle(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return;
    }

    const Body = struct { enabled: bool };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected enabled boolean");
        return;
    };

    const outcome = platform.sites.toggle(ctx.arena, name, body.enabled) catch |err| {
        if (errutil.isSiteNotFound(err)) {
            ctx.fail(404, "not_found", "site not found");
        } else if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "site management is not available on this platform");
        } else {
            ctx.fail(500, "sites_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 400;
    var name_buf: [96]u8 = undefined;
    const safe_name = redact.text(&name_buf, name);
    if (outcome.ok) {
        log.info("sites: toggle name={s} enabled={}", .{ safe_name, body.enabled });
    } else {
        log.warn("sites: toggle failed name={s} enabled={}", .{ safe_name, body.enabled });
    }
    try ctx.json(.{ .name = name, .enabled = body.enabled, .ok = outcome.ok, .output = outcome.output });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return;
    }

    const outcome = platform.sites.destroy(ctx.arena, name) catch |err| {
        if (errutil.isSiteNotFound(err)) {
            ctx.fail(404, "not_found", "site not found");
        } else if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "site management is not available on this platform");
        } else {
            ctx.fail(500, "sites_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 400;
    var name_buf: [96]u8 = undefined;
    const safe_name = redact.text(&name_buf, name);
    if (outcome.ok) {
        log.info("sites: removed name={s}", .{safe_name});
    } else {
        log.warn("sites: destroy failed name={s}", .{safe_name});
    }
    try ctx.json(.{ .name = name, .removed = true, .ok = outcome.ok, .output = outcome.output });
}

pub fn reload(ctx: *context.Context) anyerror!void {
    const outcome = platform.sites.reload(ctx.arena) catch |err| {
        if (errutil.isUnsupported(err)) {
            ctx.fail(501, "unsupported", "site management is not available on this platform");
        } else {
            ctx.fail(500, "sites_failed", @errorName(err));
        }
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    if (outcome.ok) {
        log.info("sites: reloaded", .{});
    } else {
        log.warn("sites: reload failed", .{});
    }
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn isSafeRoot(root: []const u8) bool {
    if (root.len == 0) return false;
    if (!compat.path.isAbsolute(root)) return false;
    for (root) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}
