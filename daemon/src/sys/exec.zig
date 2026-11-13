const std = @import("std");
const compat = @import("compat");

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn ok(self: Result) bool {
        return self.exit_code == 0;
    }
};

pub const RunError = error{
    SpawnFailed,
    OutOfMemory,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) RunError!Result {
    const res = std.process.run(allocator, compat.io(), .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };

    const code: u8 = switch (res.term) {
        .exited => |exit_code| exit_code,
        else => 255,
    };

    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = code,
    };
}
