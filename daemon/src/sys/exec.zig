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
    StreamTooLong,
};

pub const Options = struct {
    environ_map: ?*const std.process.Environ.Map = null,
    stdin: ?[]const u8 = null,
    max_output: usize = 1024 * 1024,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) RunError!Result {
    return runWith(allocator, argv, .{ .max_output = max_output });
}

pub fn runWith(allocator: std.mem.Allocator, argv: []const []const u8, options: Options) RunError!Result {
    const io = compat.io();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = options.environ_map,
        .stdin = if (options.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer child.kill(io);

    if (options.stdin) |input| {
        const stdin = child.stdin orelse return error.SpawnFailed;
        stdin.writeStreamingAll(io, input) catch return error.SpawnFailed;
        stdin.close(io);
        child.stdin = null;
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);
    while (multi.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > options.max_output) return error.StreamTooLong;
        if (stderr_reader.buffered().len > options.max_output) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.SpawnFailed,
    }
    multi.checkAnyError() catch return error.SpawnFailed;

    const term = child.wait(io) catch return error.SpawnFailed;
    const stdout = multi.toOwnedSlice(0) catch return error.OutOfMemory;
    errdefer allocator.free(stdout);
    const stderr = multi.toOwnedSlice(1) catch return error.OutOfMemory;

    const code: u8 = switch (term) {
        .exited => |exit_code| exit_code,
        else => 255,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = code,
    };
}
