const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const sensor = @import("scansensor.zig");

/// Passive scan sensing. eBPF needs CAP_BPF/CAP_SYS_ADMIN plus a kernel with
/// BPF syscalls enabled, so every capability is probed instead of assumed.
pub const ScanStatus = struct {
    ebpf: bool,
    /// Kernel feature probe result, shown even when eBPF is unavailable.
    kernel_bpf: bool,
    unprivileged_disabled: i64,
    bpftrace_available: bool,
    scanner_installed: bool,
    scanner_running: bool,
    /// Recent connection observations collected passively, newest last.
    hits: []const sensor.Observation,
    banned: []const []const u8,
    max_targets: u32,
    message: []const u8,
};

pub const FirewallEntry = struct {
    ok: bool,
    output: []const u8,
};

pub fn scanStatus(allocator: std.mem.Allocator, data_dir: []const u8) !ScanStatus {
    const kernel_bpf = bpfSyscallAvailable(allocator);
    const unprivileged = readInt(allocator, "/proc/sys/kernel/unprivileged_bpf_disabled") orelse -1;
    const scanner = try sensor.buildPaths(allocator, data_dir);
    defer scanner.deinit(allocator);

    const installed = sensor.exists(scanner.script);
    const running = if (installed) blk: {
        const pid = sensor.readPid(allocator, scanner.pid) orelse break :blk false;
        break :blk sensor.pidAlive(pid);
    } else false;
    const hits = try sensor.readHits(allocator, scanner.hits, 200);
    const banned = try sensor.readBanned(allocator, data_dir);
    const bpftrace_available = sensor.bpftraceAvailable(allocator);
    const default_limits: sensor.Limits = .{};
    // `unprivileged_bpf_disabled` only gates non-root users; root is always
    // allowed to load probes, and the daemon runs as root in production.
    const privileged = isRoot();

    var message: []const u8 = "";
    if (!kernel_bpf) {
        message = "内核未启用 BPF syscall 或缺少 BTF，无法被动采集";
    } else if (!privileged and (unprivileged == 2 or unprivileged == 1)) {
        message = "内核禁止非特权 BPF；扫描感知需要 daemon 以 root 运行";
    } else if (!bpftrace_available) {
        message = "服务器未安装 bpftrace，无法加载被动采集探针";
    } else if (!installed) {
        message = "尚未安装扫描感知探针";
    } else if (!running) {
        message = "探针已安装但未运行";
    }

    return .{
        .ebpf = kernel_bpf and (privileged or unprivileged == 0),
        .kernel_bpf = kernel_bpf,
        .unprivileged_disabled = unprivileged,
        .bpftrace_available = bpftrace_available,
        .scanner_installed = installed,
        .scanner_running = running,
        .hits = hits,
        .banned = banned,
        .max_targets = default_limits.max_targets,
        .message = message,
    };
}

/// Restarts an already-installed probe after a daemon restart. A probe that
/// was never installed is left alone, so this cannot silently start collecting.
pub fn resumeScan(allocator: std.mem.Allocator, data_dir: []const u8) !bool {
    const scanner = try sensor.buildPaths(allocator, data_dir);
    defer scanner.deinit(allocator);
    if (!sensor.exists(scanner.script)) return false;
    try sensor.start(allocator, data_dir);
    return true;
}

/// Installs the probe script (no process is started).
pub fn installScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    if (!sensor.bpftraceAvailable(allocator)) return error.BpftraceUnavailable;
    const paths = try sensor.install(allocator, data_dir);
    paths.deinit(allocator);
}

pub fn startScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    if (!sensor.bpftraceAvailable(allocator)) return error.BpftraceUnavailable;
    try sensor.start(allocator, data_dir);
}

pub fn stopScan(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    try sensor.stop(allocator, data_dir);
}

/// Ingests one probe flush and applies automatic bans.
pub fn ingest(allocator: std.mem.Allocator, data_dir: []const u8, line: []const u8) !void {
    try sensor.handleFromLine(allocator, data_dir, line, .{});
}

/// Records a ban without denying it in the firewall; used by the sensor and by
/// tests that only exercise the manifest.
pub fn recordBan(allocator: std.mem.Allocator, data_dir: []const u8, source: []const u8) !bool {
    return sensor.recordBan(allocator, data_dir, source);
}

pub fn unban(allocator: std.mem.Allocator, data_dir: []const u8, source: []const u8) !void {
    const paths = try sensor.buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    const existing = compat.cwd().readFileAlloc(allocator, paths.banned, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var updated = std.array_list.Managed(u8).init(allocator);
    defer updated.deinit();
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        // Bans are recorded in expanded form (2001:db8::1 vs 2001:db8:0:0:0:0:0:1),
        // so entries are compared as addresses, not as text.
        if (text.len == 0 or sameAddress(text, source)) continue;
        try updated.appendSlice(text);
        try updated.append('\n');
    }
    try sensor.writeFile(paths.banned, updated.items);
    _ = @import("firewall.zig").allowSource(allocator, source) catch {};
}

pub fn isRoot() bool {
    return std.os.linux.geteuid() == 0;
}

fn sameAddress(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const left = std.Io.net.IpAddress.parse(a, 0) catch return false;
    const right = std.Io.net.IpAddress.parse(b, 0) catch return false;
    return left.eql(&right);
}

fn bpfSyscallAvailable(allocator: std.mem.Allocator) bool {
    // BTF is required before a kprobe can be typed against kernel structures.
    if (!sensor.exists("/sys/kernel/btf/vmlinux")) return false;
    var probe = exec.run(allocator, &.{ "bpftool", "feature", "probe", "kernel" }, 64 * 1024) catch return false;
    // exec.run hands back owned buffers; callers own them. Freed even on the
    // early-return paths below.
    defer {
        allocator.free(probe.stdout);
        allocator.free(probe.stderr);
    }
    if (!probe.ok()) return false;
    return std.mem.indexOf(u8, probe.stdout, "CONFIG_BPF_SYSCALL is set to y") != null and
        std.mem.indexOf(u8, probe.stdout, "CONFIG_BPF is set to y") != null;
}

fn readInt(allocator: std.mem.Allocator, path: []const u8) ?i64 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 64) catch return null;
    defer allocator.free(raw);
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \r\n\t"), 10) catch null;
}
