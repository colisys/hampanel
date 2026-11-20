const std = @import("std");

/// Windows has no eBPF, SELinux or chattr. Every operation reports
/// `error.Unsupported` so the client can show an honest banner instead of an
/// empty list that looks like "nothing detected".
pub const ScanStatus = struct {
    ebpf: bool,
    kernel_bpf: bool,
    unprivileged_disabled: i64,
    scanner_installed: bool,
    scanner_running: bool,
    hits: []const Hit,
    banned: []const []const u8,
    message: []const u8,
};

pub const Hit = struct {
    at: i64,
    source: []const u8,
    target: []const u8,
    port: u16,
    count: u32,
    banned: bool,
};

pub fn scanStatus(allocator: std.mem.Allocator, data_dir: []const u8) !ScanStatus {
    _ = allocator;
    _ = data_dir;
    return .{
        .ebpf = false,
        .kernel_bpf = false,
        .unprivileged_disabled = -1,
        .scanner_installed = false,
        .scanner_running = false,
        .hits = &.{},
        .banned = &.{},
        .message = "扫描感知依赖 eBPF，仅 Linux 可用",
    };
}

pub fn recordBan(allocator: std.mem.Allocator, data_dir: []const u8, source: []const u8) !bool {
    _ = allocator;
    _ = data_dir;
    _ = source;
    return error.Unsupported;
}
