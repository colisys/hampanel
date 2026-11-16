const std = @import("std");
const compat = @import("compat");
const c = @import("terminal_c");

pub const Terminal = struct {
    master: std.posix.fd_t,
    pid: std.posix.pid_t,

    fn file(self: *Terminal) std.Io.File {
        return .{ .handle = self.master, .flags = .{ .nonblocking = false } };
    }

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        return self.file().readStreaming(compat.io(), &.{buffer}) catch error.Io;
    }

    pub fn writeAll(self: *Terminal, data: []const u8) !void {
        self.file().writeStreamingAll(compat.io(), data) catch return error.Io;
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) void {
        var winsize = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &winsize);
    }

    pub fn close(self: *Terminal) void {
        self.file().close(compat.io());
        _ = std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
        _ = std.c.waitpid(self.pid, null, 0);
    }
};

pub fn spawn(cols: u16, rows: u16) !Terminal {
    return spawnArgv(std.heap.page_allocator, &.{
        "/usr/bin/env",
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
        "/bin/bash",
        "-l",
    }, cols, rows);
}

pub fn spawnArgv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cols: u16,
    rows: u16,
) !Terminal {
    if (argv.len == 0) return error.ForkFailed;

    var winsize = c.struct_winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const args = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    defer allocator.free(args);
    const owned = try allocator.alloc([:0]u8, argv.len);
    defer allocator.free(owned);
    for (argv, 0..) |arg, index| {
        owned[index] = try allocator.dupeSentinel(u8, arg, 0);
        args[index] = owned[index].ptr;
    }
    defer for (owned) |arg| allocator.free(arg);
    args[argv.len] = null;

    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &winsize);
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = c.execvp(args[0].?, @ptrCast(args.ptr));
        c._exit(127);
    }

    return .{ .master = master, .pid = pid };
}
