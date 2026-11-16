const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const websocket = @import("../http/websocket.zig");
const Conn = @import("../net/conn.zig").Conn;
const platform = @import("../platform/mod.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const log = @import("../log.zig");

const Session = struct {
    term: *platform.Terminal,
    conn: *Conn,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_lock: std.Io.Mutex = .init,
};

pub fn ws(ctx: *context.Context) anyerror!void {
    if (!websocket.isUpgrade(ctx.req)) {
        ctx.fail(400, "websocket_required", "this endpoint requires a WebSocket upgrade");
        return;
    }
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return;
    }
    const shell = (try ctx.query("shell")) orelse "/bin/sh";
    if (!validShell(shell)) {
        ctx.fail(400, "bad_shell", "unsupported shell");
        return;
    }

    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    const running = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "inspect", "--format", "{{.State.Running}}", id,
    }, .{ .max_output = 64 * 1024 }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!running.ok() or !std.mem.eql(u8, std.mem.trim(u8, running.stdout, " \t\r\n"), "true")) {
        ctx.fail(409, "not_running", "容器未在运行");
        return;
    }

    const cols = parseDimension(try ctx.query("cols"), 120, 20, 500);
    const rows = parseDimension(try ctx.query("rows"), 32, 5, 200);

    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "exec", "-it", id, shell });

    var term = platform.spawnTerminalArgv(ctx.arena, argv.items, cols, rows) catch |err| {
        if (err == error.Unsupported) {
            ctx.fail(501, "unsupported", "容器终端仅在 Linux 上可用");
        } else {
            log.err("container terminal spawn failed: {s}", .{@errorName(err)});
            ctx.fail(500, "terminal_failed", "unable to start a container shell");
        }
        return;
    };

    websocket.writeUpgrade(ctx.conn, ctx.req, ctx.arena) catch {
        term.close();
        ctx.fail(400, "upgrade_failed", "websocket handshake failed");
        return;
    };
    ctx.hijacked = true;
    log.info("docker: terminal opened container={s} shell={s}", .{ id, shell });

    var session = Session{ .term = &term, .conn = ctx.conn };
    const reader = std.Thread.spawn(.{}, readFromTerminal, .{&session}) catch {
        term.close();
        return;
    };

    defer {
        session.stopped.store(true, .release);
        term.close();
        reader.join();
    }

    while (!session.stopped.load(.acquire)) {
        const maybe_frame = websocket.readFrame(ctx.conn, ctx.arena, 1024 * 1024) catch return;
        const frame = maybe_frame orelse return;
        switch (frame.opcode) {
            .binary => term.writeAll(frame.payload) catch return,
            .text => handleText(&term, frame.payload) catch return,
            .close => return,
            .ping => {
                session.write_lock.lockUncancelable(compat.io());
                defer session.write_lock.unlock(compat.io());
                websocket.writeFrame(ctx.conn, .pong, frame.payload) catch return;
            },
            else => {},
        }
    }
}

fn readFromTerminal(session: *Session) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (!session.stopped.load(.acquire)) {
        const n = session.term.read(&buffer) catch break;
        if (n == 0) break;
        session.write_lock.lockUncancelable(compat.io());
        defer session.write_lock.unlock(compat.io());
        websocket.writeBinary(session.conn, buffer[0..n]) catch break;
    }

    session.stopped.store(true, .release);
    session.write_lock.lockUncancelable(compat.io());
    defer session.write_lock.unlock(compat.io());
    websocket.writeClose(session.conn, 1000, "shell exited");
}

fn handleText(term: *platform.Terminal, payload: []const u8) !void {
    const Control = struct {
        type: []const u8 = "",
        cols: u16 = 0,
        rows: u16 = 0,
    };
    const parsed = std.json.parseFromSlice(Control, std.heap.page_allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        try term.writeAll(payload);
        return;
    };
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "resize")) {
        term.resize(
            std.math.clamp(parsed.value.cols, 20, 500),
            std.math.clamp(parsed.value.rows, 5, 200),
        );
        return;
    }
    try term.writeAll(payload);
}

fn validShell(shell: []const u8) bool {
    const allowed = [_][]const u8{ "sh", "bash", "/bin/sh", "/bin/bash", "/bin/ash", "ash" };
    for (allowed) |candidate| {
        if (std.mem.eql(u8, shell, candidate)) return true;
    }
    return false;
}

fn parseDimension(raw: ?[]const u8, default: u16, min: u16, max: u16) u16 {
    const text = raw orelse return default;
    const value = std.fmt.parseInt(u16, text, 10) catch return default;
    return std.math.clamp(value, min, max);
}
