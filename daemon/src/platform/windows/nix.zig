const std = @import("std");

pub const Target = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Status = struct {
    available: bool,
    version: []const u8,
    flakes: bool,
    targets: []const Target,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn status(allocator: std.mem.Allocator) !Status {
    _ = allocator;
    return .{ .available = false, .version = "", .flakes = false, .targets = &.{} };
}

pub fn build(
    allocator: std.mem.Allocator,
    target: []const u8,
    substituters: []const u8,
) !Outcome {
    _ = allocator;
    _ = target;
    _ = substituters;
    return error.Unsupported;
}

pub fn run(
    allocator: std.mem.Allocator,
    target: []const u8,
    args: []const []const u8,
    substituters: []const u8,
) !Outcome {
    _ = allocator;
    _ = target;
    _ = args;
    _ = substituters;
    return error.Unsupported;
}
