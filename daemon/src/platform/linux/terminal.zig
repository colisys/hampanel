const std = @import("std");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
});

pub const Terminal = struct {
    master: std.posix.fd_t,
    pid: std.posix.pid_t,

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        return std.posix.read(self.master, buffer) catch error.Io;
    }

    pub fn writeAll(self: *Terminal, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = std.posix.write(self.master, data[offset..]) catch return error.Io;
            if (n == 0) return error.Io;
            offset += n;
        }
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
        std.posix.close(self.master);
        _ = std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
        _ = std.posix.waitpid(self.pid, 0);
    }
};

pub fn spawn(cols: u16, rows: u16) !Terminal {
    var winsize = c.struct_winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &winsize);
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        var argv = [_:null]?[*:0]const u8{
            "/usr/bin/env",
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "/bin/bash",
            "-l",
        };
        _ = c.execvp("/usr/bin/env", @ptrCast(&argv));
        c._exit(127);
    }

    return .{ .master = master, .pid = pid };
}
