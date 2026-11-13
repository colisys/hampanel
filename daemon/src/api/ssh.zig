const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const errutil = @import("../util/errors.zig");

pub fn status(ctx: *context.Context) anyerror!void {
    const value = platform.ssh.status(ctx.arena) catch |err| {
        ctx.fail(500, "ssh_failed", @errorName(err));
        return;
    };
    try ctx.json(value);
}

pub fn apply(ctx: *context.Context) anyerror!void {
    const Body = struct {
        port: u16,
        permit_root_login: []const u8,
        password_authentication: bool,
        pubkey_authentication: bool,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected port, permit_root_login and auth flags");
        return;
    };

    const outcome = platform.ssh.apply(
        ctx.arena,
        body.port,
        body.permit_root_login,
        body.password_authentication,
        body.pubkey_authentication,
    ) catch |err| {
        fail(ctx, err);
        return;
    };

    try ctx.json(outcome);
}

pub fn listKeys(ctx: *context.Context) anyerror!void {
    const user = (try ctx.query("user")) orelse "root";
    const keys = platform.ssh.listKeys(ctx.arena, user) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(.{ .user = user, .keys = keys });
}

pub fn addKey(ctx: *context.Context) anyerror!void {
    const Body = struct {
        user: []const u8,
        key: []const u8,
        comment: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected user and key");
        return;
    };

    const outcome = platform.ssh.addKey(ctx.arena, body.user, body.key, body.comment) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 400;
    try ctx.json(outcome);
}

pub fn removeKey(ctx: *context.Context) anyerror!void {
    const Body = struct { user: []const u8, index: usize };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected user and index");
        return;
    };

    const outcome = platform.ssh.removeKey(ctx.arena, body.user, body.index) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 400;
    try ctx.json(outcome);
}

pub fn logging(ctx: *context.Context) anyerror!void {
    const logging_status = platform.ssh.loggingStatus(ctx.arena) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(logging_status);
}

pub fn setLogging(ctx: *context.Context) anyerror!void {
    const Body = struct { mode: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected mode: syslog or file");
        return;
    };
    const outcome = platform.ssh.setLogging(ctx.arena, body.mode) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(outcome);
}

pub fn logs(ctx: *context.Context) anyerror!void {
    var source = (try ctx.query("source")) orelse "auto";
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    if (std.mem.eql(u8, source, "auto")) {
        if (platform.ssh.loggingStatus(ctx.arena)) |current| {
            if (std.mem.eql(u8, current.mode, "file")) {
                source = "file";
            } else if (current.journal_available) {
                source = "journal";
            } else if (current.auth_log_path.len > 0) {
                source = "auth";
            } else {
                source = "journal";
            }
        } else |_| {
            source = "journal";
        }
    }

    const log_result = platform.ssh.logs(ctx.arena, source, lines) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(log_result);
}

fn fail(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidPort") or errutil.named(err, "InvalidRootLogin") or errutil.named(err, "InvalidKey")) {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "UserNotFound")) {
        ctx.fail(404, "user_not_found", "user not found");
    } else if (errutil.named(err, "KeyNotFound")) {
        ctx.fail(404, "key_not_found", "authorized key not found");
    } else if (errutil.named(err, "InvalidMode") or errutil.named(err, "InvalidSource")) {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "RsyslogUnavailable")) {
        ctx.fail(501, "rsyslog_unavailable", "未安装 rsyslog，无法启用文件日志模式");
    } else if (errutil.named(err, "LogSourceUnavailable")) {
        ctx.fail(404, "log_source_unavailable", "日志来源不可用");
    } else if (errutil.named(err, "SshUnavailable")) {
        ctx.fail(502, "ssh_unavailable", "sshd is not installed or cannot be read");
    } else if (errutil.named(err, "AccessDenied")) {
        ctx.fail(403, "permission_denied", "需要 root 权限修改 SSH 配置");
    } else if (errutil.isUnsupported(err)) {
        ctx.fail(501, "unsupported", "SSH management is not available on this platform");
    } else {
        ctx.fail(500, "ssh_failed", @errorName(err));
    }
}
