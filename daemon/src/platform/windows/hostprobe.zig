const std = @import("std");

/// Active scanning needs raw sockets and nmap, so the Windows backend reports
/// it as unavailable instead of pretending to scan.
pub const Port = struct {
    port: u16 = 0,
    protocol: []const u8 = "",
    state: []const u8 = "",
    service: []const u8 = "",
    product: []const u8 = "",
    version: []const u8 = "",
};

pub const Intel = struct {
    ports: []const u16 = &.{},
    hostnames: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    vulns: []const []const u8 = &.{},
};

pub const Report = struct {
    target: []const u8 = "",
    os_guess: []const u8 = "",
    os_accuracy: u8 = 0,
    ports: []const Port = &.{},
    hostnames: []const []const u8 = &.{},
    intel: ?Intel = null,
    nmap_available: bool = false,
    message: []const u8 = "主机探测仅支持 Linux 远端",
};

pub const Options = struct {
    intensity: []const u8 = "fast",
    os_detection: bool = true,
    service_detection: bool = true,
};

pub fn isSafeTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > 253) return false;
    return false;
}

pub fn probe(allocator: std.mem.Allocator, target: []const u8, options: Options) !Report {
    _ = allocator;
    _ = options;
    if (!isSafeTarget(target)) return error.InvalidTarget;
    return error.Unsupported;
}
