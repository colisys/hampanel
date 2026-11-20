const std = @import("std");

/// The honeypot needs KVM and QEMU user-mode networking; Windows has no
/// equivalent here, so every operation is reported as unsupported.
pub const Mode = enum {
    ssh,
    web,
    both,

    pub fn fromString(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "ssh")) return .ssh;
        if (std.mem.eql(u8, value, "web")) return .web;
        if (std.mem.eql(u8, value, "both")) return .both;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const Profile = struct {
    cpu_model: []const u8 = "",
    cpu_cores: u16 = 0,
    memory_mb: u32 = 0,
    disk_gb: u16 = 0,
    vendor: []const u8 = "",
    product: []const u8 = "",
    board: []const u8 = "",
    serial: []const u8 = "",
    mac: []const u8 = "",
};

pub const Session = struct {
    id: []const u8,
    mode: []const u8,
    running: bool,
    port: u16,
    started_at: i64,
    console_path: []const u8,
    isolation: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    session_id: ?[]const u8 = null,
    port: u16 = 0,
};

pub const Status = struct {
    qemu: bool = false,
    kvm: bool = false,
    kernel: []const u8 = "",
    image: []const u8 = "",
    image_ready: bool = false,
    profile: Profile = .{},
    sessions: []const Session = &.{},
    message: []const u8 = "蜜罐依赖 KVM，仅 Linux 主机可用",
};

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    _ = allocator;
    _ = data_dir;
    return .{};
}

pub fn buildImage(allocator: std.mem.Allocator, data_dir: []const u8, mode: Mode) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = mode;
    return error.Unsupported;
}

pub fn start(allocator: std.mem.Allocator, data_dir: []const u8, mode: Mode, port: u16) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = mode;
    _ = port;
    return error.Unsupported;
}

pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = id;
    return error.Unsupported;
}

pub fn validId(id: []const u8) bool {
    _ = id;
    return false;
}
