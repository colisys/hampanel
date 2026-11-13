const std = @import("std");
const compat = @import("compat");

const cmd_argv = [_][]const u8{ "C:\\Windows\\System32\\cmd.exe", "/Q" };

pub const Terminal = struct {
    child: std.process.Child,

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        const stdout = self.child.stdout orelse return error.Io;
        return stdout.readStreaming(compat.io(), &.{buffer}) catch error.Io;
    }

    pub fn writeAll(self: *Terminal, data: []const u8) !void {
        const stdin = self.child.stdin orelse return error.Io;
        stdin.writeStreamingAll(compat.io(), data) catch return error.Io;
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) void {
        _ = self;
        _ = cols;
        _ = rows;
    }

    pub fn close(self: *Terminal) void {
        self.child.kill(compat.io());
        _ = self.child.wait(compat.io()) catch {};
    }
};

pub fn spawn(cols: u16, rows: u16) !Terminal {
    _ = cols;
    _ = rows;

    const child = try std.process.spawn(compat.io(), .{
        .argv = &cmd_argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    return .{ .child = child };
}
