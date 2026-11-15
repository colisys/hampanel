const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const log = @import("../log.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const limit_raw = try ctx.query("limit");
    var limit: usize = 200;
    if (limit_raw) |raw| {
        limit = std.fmt.parseInt(usize, raw, 10) catch 200;
        limit = @min(limit, 1000);
    }

    const list = platform.processes.list(ctx.arena, limit) catch |err| {
        ctx.fail(500, "processes_failed", @errorName(err));
        return;
    };
    try ctx.json(list);
}

pub fn detail(ctx: *context.Context) anyerror!void {
    const pid = requirePid(ctx) orelse return;
    const info = platform.processes.detail(ctx.arena, pid) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(info);
}

pub fn terminate(ctx: *context.Context) anyerror!void {
    const pid = requirePid(ctx) orelse return;
    const Body = struct { signal: []const u8 = "TERM" };
    var signal: []const u8 = "TERM";
    if (ctx.req.body.len > 0) {
        const body = ctx.requireJson(Body) catch {
            ctx.fail(400, "bad_request", "expected optional signal: TERM|KILL");
            return;
        };
        if (!std.mem.eql(u8, body.signal, "TERM") and !std.mem.eql(u8, body.signal, "KILL")) {
            ctx.fail(400, "bad_signal", "signal must be TERM or KILL");
            return;
        }
        signal = body.signal;
    }
    platform.processes.terminate(pid, signal) catch |err| {
        fail(ctx, err);
        return;
    };
    log.warn("processes: terminated pid={d} signal={s}", .{ pid, signal });
    try ctx.json(.{ .pid = pid, .signal = signal, .ok = true });
}

fn requirePid(ctx: *context.Context) ?u32 {
    const raw = ctx.param("pid") orelse {
        ctx.fail(400, "bad_pid", "missing pid");
        return null;
    };
    const pid = std.fmt.parseInt(u32, raw, 10) catch {
        ctx.fail(400, "bad_pid", "pid must be a positive integer");
        return null;
    };
    if (pid == 0) {
        ctx.fail(400, "bad_pid", "pid must be a positive integer");
        return null;
    }
    return pid;
}

fn fail(ctx: *context.Context, err: anyerror) void {
    switch (err) {
        error.NotFound => ctx.fail(404, "not_found", "process not found"),
        error.InvalidPid => ctx.fail(400, "bad_pid", "process cannot be signalled"),
        error.TerminateFailed => ctx.fail(502, "terminate_failed", "signal could not be delivered"),
        error.Unsupported => ctx.fail(501, "unsupported", "process control is not available on this platform"),
        else => ctx.fail(500, "processes_failed", @errorName(err)),
    }
}
