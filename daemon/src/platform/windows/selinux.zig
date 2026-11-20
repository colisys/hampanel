const std = @import("std");

/// SELinux is a Linux kernel feature; Windows has no equivalent, so every
/// operation reports it as absent instead of pretending to manage it.
pub const Status = struct {
    present: bool = false,
    enforcing: ?bool = null,
    configured: []const u8 = "",
    policy: []const u8 = "",
    tooling: bool = false,
    booleans: []const Boolean = &.{},
    message: []const u8 = "SELinux 仅存在于 Linux 主机",
};

pub const Boolean = struct {
    name: []const u8,
    enabled: bool,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    reboot_required: bool = false,
};

pub fn status(allocator: std.mem.Allocator) !Status {
    _ = allocator;
    return .{};
}

pub fn setMode(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    _ = allocator;
    _ = mode;
    return error.Unsupported;
}

pub fn setBoolean(allocator: std.mem.Allocator, name: []const u8, enabled: bool) !Outcome {
    _ = allocator;
    _ = name;
    _ = enabled;
    return error.Unsupported;
}

pub fn validBooleanName(name: []const u8) bool {
    _ = name;
    return false;
}
