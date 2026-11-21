const std = @import("std");

/// SELinux is a Linux kernel feature; Windows has no equivalent, so every
/// operation reports it as absent instead of pretending to manage it.
pub const Context = struct {
    path: []const u8,
    kind: []const u8,
    file_type: []const u8,
};

pub const PortType = struct {
    port: u16,
    protocol: []const u8,
    kind: []const u8,
};

pub const Module = struct {
    name: []const u8,
    version: []const u8,
};

pub const Denial = struct {
    at: []const u8,
    source: []const u8,
    target: []const u8,
    object_type: []const u8,
    tclass: []const u8,
    permission: []const u8,
    path: []const u8,
};

pub const Status = struct {
    present: bool = false,
    enforcing: ?bool = null,
    configured: []const u8 = "",
    policy: []const u8 = "",
    tooling: bool = false,
    semanage: bool = false,
    booleans: []const Boolean = &.{},
    contexts: []const Context = &.{},
    ports: []const PortType = &.{},
    modules: []const Module = &.{},
    denials: []const Denial = &.{},
    policy_store: bool = false,
    relabelled: bool = false,
    managed_paths: u32 = 0,
    managed_total: u32 = 0,
    reboot_allowed: bool = true,
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

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    _ = allocator;
    _ = data_dir;
    return .{};
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}

pub fn setMode(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    _ = allocator;
    _ = mode;
    return error.Unsupported;
}

pub fn setContext(allocator: std.mem.Allocator, spec: Context, remove: bool) !Outcome {
    _ = allocator;
    _ = spec;
    _ = remove;
    return error.Unsupported;
}

pub fn setPort(allocator: std.mem.Allocator, entry: PortType, remove: bool) !Outcome {
    _ = allocator;
    _ = entry;
    _ = remove;
    return error.Unsupported;
}

pub fn validContextPath(path: []const u8) bool {
    _ = path;
    return false;
}

pub fn validTypeName(name: []const u8) bool {
    _ = name;
    return false;
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

/// Windows has no SELinux, so nothing here can make a reboot unsafe.
pub fn isRebootUnit(unit: []const u8) bool {
    _ = unit;
    return false;
}

pub fn rebootAllowed(allocator: std.mem.Allocator) bool {
    _ = allocator;
    return true;
}
