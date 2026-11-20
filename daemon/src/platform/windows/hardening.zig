const std = @import("std");

/// Windows has no sysctl, pam_umask, at/cron or a sudoers file; the whole
/// surface reports absence rather than pretending to configure it.
pub const Dangling = struct {
    path: []const u8,
    target: []const u8,
};

pub const UmaskStatus = struct {
    login_defs: []const u8 = "",
    configured: []const u8 = "",
    pam_umask: bool = false,
};

pub const AccessStatus = struct {
    cron_allow: bool = false,
    cron_deny: bool = false,
    at_allow: bool = false,
    at_deny: bool = false,
    cron_allowed_users: []const []const u8 = &.{},
};

pub const SudoStatus = struct {
    mode: u32 = 0,
    insecure: []const []const u8 = &.{},
    pwfeedback: bool = false,
    use_pty: bool = false,
};

pub const KernelParam = struct {
    key: []const u8,
    value: []const u8 = "",
    recommended: []const u8 = "",
    description: []const u8 = "",
    hardened: bool = false,
};

pub const Status = struct {
    dangling: []const Dangling = &.{},
    umask: UmaskStatus = .{},
    cron: AccessStatus = .{},
    sudo: SudoStatus = .{},
    kernel: []const KernelParam = &.{},
    sysctl_available: bool = false,
    message: []const u8 = "主机加固项（sysctl / umask / at / cron / sudo）仅适用于 Linux",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Request = struct {
    key: []const u8,
    value: []const u8,
};

pub const AccessTool = enum {
    cron,
    at,

    pub fn fromString(value: []const u8) ?AccessTool {
        if (std.mem.eql(u8, value, "cron")) return .cron;
        if (std.mem.eql(u8, value, "at")) return .at;
        return null;
    }

    pub fn name(self: AccessTool) []const u8 {
        return @tagName(self);
    }
};

pub fn status(allocator: std.mem.Allocator) !Status {
    _ = allocator;
    return .{};
}

pub fn pruneDangling(allocator: std.mem.Allocator, paths: []const []const u8) !Outcome {
    _ = allocator;
    _ = paths;
    return error.Unsupported;
}

pub fn setUmask(allocator: std.mem.Allocator, value: []const u8) !Outcome {
    _ = allocator;
    _ = value;
    return error.Unsupported;
}

pub fn restrictScheduler(
    allocator: std.mem.Allocator,
    tool: AccessTool,
    users: []const []const u8,
    enabled: bool,
) !Outcome {
    _ = allocator;
    _ = tool;
    _ = users;
    _ = enabled;
    return error.Unsupported;
}

pub fn hardenSudo(allocator: std.mem.Allocator) !Outcome {
    _ = allocator;
    return error.Unsupported;
}

pub fn setKernel(allocator: std.mem.Allocator, requests: []const Request) !Outcome {
    _ = allocator;
    _ = requests;
    return error.Unsupported;
}

pub fn validUmask(value: []const u8) bool {
    _ = value;
    return false;
}

pub fn validUserName(name: []const u8) bool {
    _ = name;
    return false;
}
