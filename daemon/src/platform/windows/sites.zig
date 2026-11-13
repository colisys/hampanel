const std = @import("std");

pub const Site = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    domains: []const []const u8,
    root: []const u8,
    listen: []const u8,
};

pub const SiteList = struct {
    available: bool,
    dir: []const u8,
    sites: []const Site,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8 = "",
};

pub fn list(allocator: std.mem.Allocator) !SiteList {
    _ = allocator;
    return .{ .available = false, .dir = "", .sites = &.{} };
}

pub fn create(
    allocator: std.mem.Allocator,
    name: []const u8,
    domains: []const []const u8,
    root: []const u8,
    port: u16,
) !Outcome {
    _ = allocator;
    _ = name;
    _ = domains;
    _ = root;
    _ = port;
    return error.Unsupported;
}

pub fn toggle(allocator: std.mem.Allocator, name: []const u8, enabled: bool) !Outcome {
    _ = allocator;
    _ = name;
    _ = enabled;
    return error.Unsupported;
}

pub fn destroy(allocator: std.mem.Allocator, name: []const u8) !Outcome {
    _ = allocator;
    _ = name;
    return error.Unsupported;
}

pub fn reload(allocator: std.mem.Allocator) !Outcome {
    _ = allocator;
    return error.Unsupported;
}
