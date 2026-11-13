const std = @import("std");
const context = @import("context.zig");
const websocket = @import("../http/websocket.zig");
const Conn = @import("../net/conn.zig").Conn;
const platform = @import("../platform/mod.zig");
const log = @import("../log.zig");

const Session = struct {
    term: *platform.Terminal,
    conn: *Conn,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_lock: std.Thread.Mutex = .{},
};

pub fn ws(ctx: *context.Context) anyerror!void {
    if (!websocket.isUpgrade(ctx.req)) {
        ctx.fail(400, "websocket_required", "this endpoint requires a WebSocket upgrade");
        return;
    }

    const cols = parseDimension(try ctx.query("cols"), 120, 20, 500);
    const rows = parseDimension(try ctx.query("rows"), 32, 5, 200);

    var term = platform.spawnTerminal(cols, rows) catch |err| {
        log.err("terminal spawn failed: {s}", .{@errorName(err)});
        ctx.fail(500, "terminal_failed", "unable to start a shell");
        return;
    };

    websocket.writeUpgrade(ctx.conn, ctx.req, ctx.arena) catch {
        term.close();
        ctx.fail(400, "upgrade_failed", "websocket handshake failed");
        return;
    };
    ctx.hijacked = true;

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
                session.write_lock.lock();
                defer session.write_lock.unlock();
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
        session.write_lock.lock();
        defer session.write_lock.unlock();
        websocket.writeBinary(session.conn, buffer[0..n]) catch break;
    }

    session.stopped.store(true, .release);
    session.write_lock.lock();
    defer session.write_lock.unlock();
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
        const cols = std.math.clamp(parsed.value.cols, 20, 500);
        const rows = std.math.clamp(parsed.value.rows, 5, 200);
        term.resize(cols, rows);
        return;
    }

    try term.writeAll(payload);
}

fn parseDimension(raw: ?[]const u8, default: u16, min: u16, max: u16) u16 {
    const text = raw orelse return default;
    const value = std.fmt.parseInt(u16, text, 10) catch return default;
    return std.math.clamp(value, min, max);
}
