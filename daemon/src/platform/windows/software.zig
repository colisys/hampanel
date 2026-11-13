const std = @import("std");

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    installed: bool,
    initialized: bool,
    needs_initialization: bool,
    active: bool,
    version: []const u8,
    service: []const u8,
    manage_hint: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator, data_dir: []const u8) ![]Item {
    _ = allocator;
    _ = data_dir;
    return &.{};
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = id;
    return error.Unsupported;
}
