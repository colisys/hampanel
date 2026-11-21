const std = @import("std");

/// Windows has no eBPF, SELinux or chattr. Every operation reports
/// `error.Unsupported` so the client can show an honest banner instead of an
/// empty list that looks like "nothing detected".
pub const Observation = struct {
    source: []const u8,
    port: u16,
    count: u32,
};

pub const ScanStatus = struct {
    ebpf: bool = false,
    kernel_bpf: bool = false,
    unprivileged_disabled: i64 = -1,
    bpftrace_available: bool = false,
    scanner_installed: bool = false,
    scanner_running: bool = false,
    hits: []const Observation = &.{},
    banned: []const []const u8 = &.{},
    max_targets: u32 = 12,
    message: []const u8 = "扫描感知依赖 eBPF，仅 Linux 可用",
};

pub const FirewallEntry = struct {
    ok: bool,
    output: []const u8,
};

pub fn scanStatus(allocator: std.mem.Allocator, data_dir: []const u8) !ScanStatus {
    _ = allocator;
    _ = data_dir;
    return .{};
}

pub fn resumeScan(allocator: std.mem.Allocator, data_dir: []const u8) !bool {
    _ = allocator;
    _ = data_dir;
    return false;
}

pub fn installScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}

pub fn startScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}

pub fn stopScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}

pub fn ingest(allocator: std.mem.Allocator, data_dir: []const u8, line: []const u8) !void {
    _ = allocator;
    _ = data_dir;
    _ = line;
    return error.Unsupported;
}

pub fn isRoot() bool {
    return false;
}

pub fn unban(allocator: std.mem.Allocator, data_dir: []const u8, source: []const u8) !void {
    _ = allocator;
    _ = data_dir;
    _ = source;
    return error.Unsupported;
}
