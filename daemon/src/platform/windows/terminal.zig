const std = @import("std");

const cmd_argv = [_][]const u8{ "C:\\Windows\\System32\\cmd.exe", "/Q" };

pub const Terminal = struct {
    child: std.process.Child,

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        const stdout = self.child.stdout orelse return error.Io;
        return stdout.read(buffer) catch error.Io;
    }

    pub fn writeAll(self: *Terminal, data: []const u8) !void {
        const stdin = self.child.stdin orelse return error.Io;
        stdin.writeAll(data) catch return error.Io;
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) void {
        _ = self;
        _ = cols;
        _ = rows;
    }

    pub fn close(self: *Terminal) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }
};

pub fn spawn(cols: u16, rows: u16) !Terminal {
    _ = cols;
    _ = rows;

    var child = std.process.Child.init(&cmd_argv, std.heap.c_allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    return .{ .child = child };
}
