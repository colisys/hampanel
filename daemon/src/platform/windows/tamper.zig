const std = @import("std");

/// Windows has no chattr; tamper protection relies on ACLs, which are not part
/// of this module. Report the feature as unavailable rather than pretending.
pub const Entry = struct {
    path: []const u8,
    attributes: []const u8,
    immutable: bool,
    present: bool,
};

pub const Status = struct {
    available: bool,
    tooling: bool,
    ebpf_detection: bool = false,
    ebpf_reason: []const u8 = "LinuxOnly",
    entries: []const Entry,
    message: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn restoreAll(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    _ = allocator;
    _ = data_dir;
    return 0;
}

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    _ = allocator;
    _ = data_dir;
    return .{
        .available = false,
        .tooling = false,
        .entries = &.{},
        .message = "chattr 不可变保护仅 Linux 可用",
    };
}

pub fn lsm(_: std.mem.Allocator, _: []const u8, _: []const u8) ![]const u8 {
    return error.Unsupported;
}

pub fn detectWrites(_: std.mem.Allocator, _: []const u8) !u64 {
    return error.Unsupported;
}

pub fn protect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = path;
    return error.Unsupported;
}

pub fn unprotect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = path;
    return error.Unsupported;
}
