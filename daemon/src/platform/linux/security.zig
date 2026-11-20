const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Passive scan sensing. eBPF needs CAP_BPF/CAP_SYS_ADMIN plus a kernel with
/// BPF syscalls enabled, so every capability is probed instead of assumed.
pub const ScanStatus = struct {
    ebpf: bool,
    /// Kernel feature probe result, shown even when eBPF is unavailable.
    kernel_bpf: bool,
    unprivileged_disabled: i64,
    scanner_installed: bool,
    scanner_running: bool,
    /// Recent connection observations collected passively.
    hits: []const Hit,
    banned: []const []const u8,
    message: []const u8,
};

pub const Hit = struct {
    at: i64,
    source: []const u8,
    target: []const u8,
    port: u16,
    /// How many connection attempts this source made in the window.
    count: u32,
    banned: bool,
};

pub const FirewallEntry = struct {
    ok: bool,
    output: []const u8,
};

pub fn scanStatus(allocator: std.mem.Allocator, data_dir: []const u8) !ScanStatus {
    const kernel_bpf = bpfSyscallAvailable(allocator);
    const unprivileged = readInt(allocator, "/proc/sys/kernel/unprivileged_bpf_disabled") orelse -1;
    const scanner = try scannerPaths(allocator, data_dir);
    defer {
        allocator.free(scanner.binary);
        allocator.free(scanner.pid);
        allocator.free(scanner.hits);
        allocator.free(scanner.banned);
    }

    const installed = exists(scanner.binary);
    const running = if (installed) pidAlive(allocator, scanner.pid) else false;
    const hits = try readHits(allocator, scanner.hits);
    const banned = try readBanned(allocator, scanner.banned);

    var message: []const u8 = "";
    if (!kernel_bpf) {
        message = "内核未启用 BPF syscall 或缺少 BTF，无法被动采集";
    } else if (unprivileged == 2 or unprivileged == 1) {
        message = "内核禁止非特权 BPF；扫描感知需要 daemon 以 root 运行";
    } else if (!installed) {
        message = "尚未构建扫描感知探针";
    }

    return .{
        .ebpf = kernel_bpf and unprivileged == 0,
        .kernel_bpf = kernel_bpf,
        .unprivileged_disabled = unprivileged,
        .scanner_installed = installed,
        .scanner_running = running,
        .hits = hits,
        .banned = banned,
        .message = message,
    };
}

const ScannerPaths = struct {
    binary: []u8,
    pid: []u8,
    hits: []u8,
    banned: []u8,
};

fn scannerPaths(allocator: std.mem.Allocator, data_dir: []const u8) !ScannerPaths {
    const root = try compat.path.join(allocator, &.{ data_dir, "security" });
    defer allocator.free(root);
    return .{
        .binary = try compat.path.join(allocator, &.{ root, "scan-sensor" }),
        .pid = try compat.path.join(allocator, &.{ root, "scan-sensor.pid" }),
        .hits = try compat.path.join(allocator, &.{ root, "scan-hits.jsonl" }),
        .banned = try compat.path.join(allocator, &.{ root, "scan-banned.txt" }),
    };
}

fn bpfSyscallAvailable(allocator: std.mem.Allocator) bool {
    // BTF is required to generate vmlinux.h for the sensor at build time.
    if (!exists("/sys/kernel/btf/vmlinux")) return false;
    const probe = exec.run(allocator, &.{ "bpftool", "feature", "probe", "kernel" }, 64 * 1024) catch return false;
    return probe.ok();
}

fn intField(value: std.json.Value, key: []const u8) i64 {
    const field = value.object.get(key) orelse return 0;
    return if (field == .integer) field.integer else 0;
}

fn boolField(value: std.json.Value, key: []const u8) bool {
    const field = value.object.get(key) orelse return false;
    return field == .bool and field.bool;
}

fn readInt(allocator: std.mem.Allocator, path: []const u8) ?i64 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 64) catch return null;
    defer allocator.free(raw);
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \r\n\t"), 10) catch null;
}

fn readHits(allocator: std.mem.Allocator, path: []const u8) ![]const Hit {
    const raw = compat.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return &.{};
    var list = std.array_list.Managed(Hit).init(allocator);
    defer list.deinit();
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            text,
            .{},
        ) catch continue;
        if (parsed != .object) continue;
        const source = parsed.object.get("source");
        const target = parsed.object.get("target");
        try list.append(.{
            .at = intField(parsed, "at"),
            .source = if (source) |value| if (value == .string) try allocator.dupe(u8, value.string) else "" else "",
            .target = if (target) |value| if (value == .string) try allocator.dupe(u8, value.string) else "" else "",
            .port = @intCast(@max(intField(parsed, "port"), 0)),
            .count = @intCast(@max(intField(parsed, "count"), 0)),
            .banned = boolField(parsed, "banned"),
        });
    }
    return try allocator.dupe(Hit, list.items);
}

pub fn readBanned(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return &.{};
    defer allocator.free(raw);
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (list.items) |entry| allocator.free(entry);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        try list.append(try allocator.dupe(u8, text));
    }
    const owned = try allocator.dupe([]const u8, list.items);
    list.deinit();
    return owned;
}

pub fn recordBan(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    source: []const u8,
) !bool {
    const root = try compat.path.join(allocator, &.{ data_dir, "security" });
    defer allocator.free(root);
    compat.cwd().makePath(root) catch {};
    const path = try compat.path.join(allocator, &.{ root, "scan-banned.txt" });
    defer allocator.free(path);

    // One source per line: no nested allocations, ids compare by exact line.
    const existing = compat.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), source)) return false;
    }

    const updated = try std.fmt.allocPrint(
        allocator,
        "{s}{s}\n",
        .{ existing, source },
    );
    defer allocator.free(updated);
    try writeFile(path, updated);
    return true;
}

pub fn pidAlive(allocator: std.mem.Allocator, pid_path: []const u8) bool {
    const raw = compat.cwd().readFileAlloc(allocator, pid_path, 32) catch return false;
    defer allocator.free(raw);
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch return false;
    if (pid == 0) return false;
    var buffer: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return false;
    return exists(dir);
}

pub fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    if (compat.path.dirname(path)) |dir| compat.cwd().makePath(dir) catch {};
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
}
