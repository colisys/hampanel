const std = @import("std");

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Jail = struct {
    name: []const u8,
    currently_failed: usize,
    total_failed: usize,
    currently_banned: usize,
    total_banned: usize,
    maxretry: []const u8,
    bantime: []const u8,
    findtime: []const u8,
    banned_ips: []const []const u8,
};

pub const Status = struct {
    installed: bool,
    initialized: bool,
    active: bool,
    version: []const u8,
    jails: []const Jail,
    message: []const u8,
};

pub fn version(allocator: std.mem.Allocator) []const u8 {
    _ = allocator;
    return "";
}

pub fn isActive(allocator: std.mem.Allocator) bool {
    _ = allocator;
    return false;
}

pub fn isInitialized(allocator: std.mem.Allocator, data_dir: []const u8) bool {
    _ = allocator;
    _ = data_dir;
    return false;
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    _ = allocator;
    _ = data_dir;
    return .{
        .installed = false,
        .initialized = false,
        .active = false,
        .version = "",
        .jails = &.{},
        .message = "Fail2ban management is only available on Linux",
    };
}

pub fn ban(allocator: std.mem.Allocator, jail: []const u8, ip: []const u8) !Outcome {
    _ = allocator;
    _ = jail;
    _ = ip;
    return error.Unsupported;
}

pub fn unban(allocator: std.mem.Allocator, jail: []const u8, ip: []const u8) !Outcome {
    _ = allocator;
    _ = jail;
    _ = ip;
    return error.Unsupported;
}

pub fn setLimits(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    maxretry: u32,
    bantime: u32,
    findtime: u32,
) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = maxretry;
    _ = bantime;
    _ = findtime;
    return error.Unsupported;
}
