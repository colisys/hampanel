const std = @import("std");
const compat = @import("compat");
const app_mod = @import("app.zig");
const notify = @import("notify.zig");
const Conn = @import("net/conn.zig").Conn;
const tls = @import("tls.zig");
const http_request = @import("http/request.zig");
const http_response = @import("http/response.zig");
const router = @import("http/router.zig");
const api = @import("api/mod.zig");
const context = @import("api/context.zig");
const audit = @import("audit.zig");
const log = @import("log.zig");
const timeutil = @import("util/time.zig");
const prefix = @import("util/prefix.zig");
const validate = @import("http/validate.zig");
const socket_timeout = @import("net/socket_timeout.zig");
const redact = @import("util/redact.zig");

pub fn serve(app: *app_mod.App) !void {
    const io = compat.io();
    var address = try std.Io.net.IpAddress.parse(app.config.listen, app.config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    log.info("hampaneld listening on {s}:{d} with mutual TLS", .{ app.config.listen, app.config.port });

    while (true) {
        const connection = listener.accept(io) catch |err| {
            log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };

        const active = app.active_connections.fetchAdd(1, .monotonic) + 1;
        if (active > app.config.max_connections) {
            _ = app.active_connections.fetchSub(1, .monotonic);
            log.warn("connection limit reached, dropping {f}", .{connection.socket.address});
            connection.close(io);
            continue;
        }

        const thread = std.Thread.spawn(.{}, handleConnection, .{ app, connection }) catch {
            _ = app.active_connections.fetchSub(1, .monotonic);
            connection.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(app: *app_mod.App, connection: std.Io.net.Stream) void {
    const io = compat.io();
    defer _ = app.active_connections.fetchSub(1, .monotonic);
    defer connection.close(io);

    socket_timeout.set(connection.socket.handle, 30_000, 60_000);
    const ssl = app.tls.accept(connection.socket.handle) catch return;
    var conn = Conn.init(ssl);
    defer conn.close();

    var identity = tls.peerIdentity(ssl) catch {
        log.warn("client without a usable certificate from {f}", .{connection.socket.address});
        return;
    };
    if (!std.mem.startsWith(u8, identity.cn(), app.config.client_cn_prefix)) {
        log.warn("client certificate CN rejected: {s}", .{identity.cn()});
        return;
    }

    log.debug("client {s} connected from {f}", .{ identity.cn(), connection.socket.address });
    {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "来自 {f} 的客户端已通过 mTLS 认证（{s}）",
            .{ connection.socket.address, identity.cn() },
        ) catch "客户端已通过 mTLS 认证";
        notify.emit(app.db, .login, "面板登录", body);
    }

    var served: usize = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const started_ms = compat.milliTimestamp();
        const req = http_request.read(&conn, allocator, app.config.max_body_bytes) catch |err| {
            switch (err) {
                error.EndOfStream, error.Io, error.WouldBlock => return,
                error.BodyTooLarge => {
                    log.warn("oversized request from {s}", .{identity.cn()});
                    sendPlain(&conn, 413, "payload too large");
                },
                error.HeaderTooLarge, error.LineTooLong => {
                    log.warn("oversized headers from {s}", .{identity.cn()});
                    sendPlain(&conn, 400, "header too large");
                },
                else => {
                    log.warn("malformed request from {s}: {s}", .{ identity.cn(), @errorName(err) });
                    sendPlain(&conn, 400, "malformed request");
                },
            }
            return;
        };

        const route_path = prefix.strip(app.config.entry_prefix, req.path) orelse {
            // Never log the raw path: the entry prefix is a secret.
            log.warn("request rejected for {s}: entry prefix mismatch", .{identity.cn()});
            sendNotFound(&conn);
            return;
        };
        if (!validate.safeRoutePath(route_path)) {
            log.warn("unsafe request path from {s}", .{identity.cn()});
            sendPlain(&conn, 400, "invalid path");
            return;
        }
        served += 1;

        var ctx = context.Context{
            .app = app,
            .conn = &conn,
            .req = req,
            .params = &.{},
            .arena = allocator,
            .peer_cn = identity.cn(),
        };

        const routed = router.match(allocator, &api.routes, req.method, route_path) catch |err| blk: {
            log.err("route match failed: {s}", .{@errorName(err)});
            break :blk router.Result{ .not_found = {} };
        };

        switch (routed) {
            .found => |matched| {
                ctx.params = matched.params;
                matched.handler(&ctx) catch |err| {
                    if (!ctx.hijacked and !ctx.sent) {
                        log.err("handler {s} {s} failed: {s}", .{ @tagName(req.method), route_path, @errorName(err) });
                        ctx.fail(500, "internal", @errorName(err));
                    }
                };
            },
            .method_not_allowed => ctx.fail(405, "method_not_allowed", "method not allowed for this route"),
            .not_found => ctx.fail(404, "not_found", "route not found"),
        }

        const elapsed = sinceMs(started_ms);

        if (ctx.hijacked) {
            logRequest(identity.cn(), req.method, route_path, 101, elapsed);
            return;
        }

        const keep_alive =
            req.keep_alive and !ctx.response.close and served < 1000;
        if (!ctx.sent) {
            http_response.write(
                &conn,
                ctx.response,
                keep_alive,
                req.method == .HEAD,
            ) catch return;
            ctx.sent = true;
        }

        recordAudit(app, ctx, connection, elapsed, route_path, allocator);
        notify.afterRequest(app.db, @tagName(req.method), route_path, ctx.response.status);
        // Unmatched paths are client-controlled noise; keep them out of the
        // access log so log lines cannot be forged or leak probed paths.
        const logged_target = switch (routed) {
            .not_found => "-",
            else => route_path,
        };
        logRequest(identity.cn(), req.method, logged_target, ctx.response.status, elapsed);

        if (ctx.req.header("x-hampanel-ai") != null and isMutation(ctx.req.method)) {
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "{s} {s} → {d}",
                .{ @tagName(ctx.req.method), route_path, ctx.response.status },
            ) catch "AI 触发了变更操作";
            notify.emit(app.db, .ai_command, "AI 执行操作", body);
        }

        if (!keep_alive) return;
    }
}

fn recordAudit(
    app: *app_mod.App,
    ctx: context.Context,
    connection: std.Io.net.Stream,
    elapsed: u64,
    route_path: []const u8,
    allocator: std.mem.Allocator,
) void {
    var ts_buf: [32]u8 = undefined;
    const peer = std.fmt.allocPrint(allocator, "{f}", .{connection.socket.address}) catch "unknown";
    app.audit.append(audit.Entry{
        .at = timeutil.nowIso(&ts_buf),
        .peer = peer,
        .method = @tagName(ctx.req.method),
        .path = route_path,
        .status = ctx.response.status,
        .duration_ms = elapsed,
    });
}

fn sinceMs(started_ms: i64) u64 {
    const now = compat.milliTimestamp();
    return if (now >= started_ms) @intCast(now - started_ms) else 0;
}

/// Access log for every routed call. Only the method, the confirmed route
/// path, the status and the duration are recorded: request bodies, query
/// strings and headers can carry credentials and never reach the log.
fn logRequest(
    peer_cn: []const u8,
    method: http_request.Method,
    target: []const u8,
    status: u16,
    duration_ms: u64,
) void {
    const level: log.Level = if (status >= 500)
        .err
    else if (status == 404)
        .debug
    else if (status >= 400)
        .warn
    else if (isMutation(method))
        .info
    else
        .debug;
    var cn_buf: [96]u8 = undefined;
    var target_buf: [96]u8 = undefined;
    log.write(
        level,
        "{s} {s} {s} -> {d} ({d} ms)",
        .{
            redact.text(&cn_buf, peer_cn),
            @tagName(method),
            redact.text(&target_buf, target),
            status,
            duration_ms,
        },
    );
}

fn sendNotFound(conn: *Conn) void {
    const body = "{\"code\":\"not_found\",\"message\":\"not found\"}";
    http_response.write(conn, .{ .status = 404, .body = body }, false, false) catch {};
}

fn sendPlain(conn: *Conn, status: u16, message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buffer,
        "{{\"code\":\"bad_request\",\"message\":\"{s}\"}}",
        .{message},
    ) catch return;
    http_response.write(conn, .{ .status = status, .body = body }, false, false) catch {};
}

fn isMutation(method: http_request.Method) bool {
    return switch (method) {
        .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
}
