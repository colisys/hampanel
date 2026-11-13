const std = @import("std");

pub const ToolStatus = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    binary: []const u8,
    installed: bool,
};

pub const Status = struct {
    manager: []const u8,
    available: bool,
    tools: []const ToolStatus,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator) !Status {
    _ = allocator;
    return .{ .manager = "windows", .available = false, .tools = &.{} };
}

pub fn install(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    _ = allocator;
    _ = id;
    return error.Unsupported;
}

pub fn refresh(allocator: std.mem.Allocator) !Outcome {
    _ = allocator;
    return error.Unsupported;
}
