const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const c = @import("libc_c");

/// translate-c cannot resolve musl's `struct statvfs` (it is only exposed
/// through `bits/alltypes.h`), so provide the layout explicitly there.
const Statvfs = if (builtin.abi == .musl)
    extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_favail: u64,
        f_fsid: c_ulong,
        f_flag: c_ulong,
        f_namemax: c_ulong,
        f_type: c_uint,
        __reserved: [5]c_int,
    }
else
    c.struct_statvfs;

pub const CpuMetrics = struct {
    usage_percent: f64,
    cores: u32,
    load1: f64,
    load5: f64,
    load15: f64,
};

pub const MemoryMetrics = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    percent: f64,
    swap_total_bytes: u64,
    swap_used_bytes: u64,
};

pub const DiskMetrics = struct {
    mount: []const u8,
    filesystem: []const u8,
    total_bytes: u64,
    used_bytes: u64,
    available_bytes: u64,
    percent: f64,
};

pub const NetworkMetrics = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    rx_rate_bps: f64,
    tx_rate_bps: f64,
};

pub const Metrics = struct {
    cpu: CpuMetrics,
    memory: MemoryMetrics,
    uptime_seconds: u64,
    disks: []DiskMetrics,
    network: NetworkMetrics,
};

pub const Sampler = struct {
    mutex: std.Io.Mutex = .init,
    prev_cpu_total: u64 = 0,
    prev_cpu_idle: u64 = 0,
    prev_rx: u64 = 0,
    prev_tx: u64 = 0,
    prev_at_ms: i64 = 0,
};

pub fn sample(allocator: std.mem.Allocator, sampler: *Sampler) !Metrics {
    sampler.mutex.lockUncancelable(compat.io());
    defer sampler.mutex.unlock(compat.io());

    const stat = try readFile(allocator, "/proc/stat");
    defer allocator.free(stat);
    const cpu = try parseCpu(stat);

    var cpu_delta_total = cpu.total;
    var cpu_delta_idle = cpu.idle;
    var usage: f64 = if (cpu.total > 0)
        (@as(f64, @floatFromInt(cpu.total - cpu.idle)) / @as(f64, @floatFromInt(cpu.total))) * 100.0
    else
        0.0;
    if (sampler.prev_cpu_total > 0 and cpu.total >= sampler.prev_cpu_total) {
        cpu_delta_total = cpu.total - sampler.prev_cpu_total;
        cpu_delta_idle = cpu.idle -| sampler.prev_cpu_idle;
        usage = if (cpu_delta_total > 0)
            (@as(f64, @floatFromInt(cpu_delta_total - cpu_delta_idle)) / @as(f64, @floatFromInt(cpu_delta_total))) * 100.0
        else
            0.0;
    }
    sampler.prev_cpu_total = cpu.total;
    sampler.prev_cpu_idle = cpu.idle;

    const load = try parseLoad(allocator);
    const uptime = try parseUptime(allocator);
    const memory = try parseMemory(allocator);
    const disks = try parseDisks(allocator);
    const net = try parseNetwork(allocator);

    const now = compat.milliTimestamp();
    var rx_rate: f64 = 0;
    var tx_rate: f64 = 0;
    if (sampler.prev_at_ms > 0) {
        const elapsed = @as(f64, @floatFromInt(now - sampler.prev_at_ms)) / 1000.0;
        if (elapsed > 0 and net.rx >= sampler.prev_rx and net.tx >= sampler.prev_tx) {
            rx_rate = @as(f64, @floatFromInt(net.rx - sampler.prev_rx)) / elapsed;
            tx_rate = @as(f64, @floatFromInt(net.tx - sampler.prev_tx)) / elapsed;
        }
    }
    sampler.prev_rx = net.rx;
    sampler.prev_tx = net.tx;
    sampler.prev_at_ms = now;

    return .{
        .cpu = .{
            .usage_percent = clampPercent(usage),
            .cores = cpu.cores,
            .load1 = load[0],
            .load5 = load[1],
            .load15 = load[2],
        },
        .memory = memory,
        .uptime_seconds = uptime,
        .disks = disks,
        .network = .{
            .rx_bytes = net.rx,
            .tx_bytes = net.tx,
            .rx_rate_bps = rx_rate,
            .tx_rate_bps = tx_rate,
        },
    };
}

fn clampPercent(value: f64) f64 {
    if (value < 0) return 0;
    if (value > 100) return 100;
    return value;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return compat.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
}

const CpuTimes = struct { total: u64, idle: u64, cores: u32 };

fn parseCpu(stat: []const u8) !CpuTimes {
    var result = CpuTimes{ .total = 0, .idle = 0, .cores = 0 };
    var lines = std.mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        if (line.len > 3 and line[3] == ' ') {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next();
            var values: [10]u64 = @splat(0);
            var idx: usize = 0;
            while (fields.next()) |field| : (idx += 1) {
                if (idx >= values.len) break;
                values[idx] = std.fmt.parseInt(u64, field, 10) catch 0;
            }
            result.total = values[0] + values[1] + values[2] + values[3] + values[4] + values[5] + values[6] + values[7];
            result.idle = values[3] + values[4];
        } else if (line.len > 3 and std.ascii.isDigit(line[3])) {
            result.cores += 1;
        }
    }
    return result;
}

fn parseLoad(allocator: std.mem.Allocator) ![3]f64 {
    const raw = try readFile(allocator, "/proc/loadavg");
    defer allocator.free(raw);
    var result = [3]f64{ 0, 0, 0 };
    var it = std.mem.tokenizeAny(u8, raw, " \t\n");
    var i: usize = 0;
    while (it.next()) |token| : (i += 1) {
        if (i >= 3) break;
        result[i] = std.fmt.parseFloat(f64, token) catch 0;
    }
    return result;
}

fn parseUptime(allocator: std.mem.Allocator) !u64 {
    const raw = try readFile(allocator, "/proc/uptime");
    defer allocator.free(raw);
    var it = std.mem.tokenizeAny(u8, raw, " \t\n");
    const first = it.next() orelse return 0;
    const seconds = std.fmt.parseFloat(f64, first) catch 0;
    return @intFromFloat(seconds);
}

fn parseMemory(allocator: std.mem.Allocator) !MemoryMetrics {
    const raw = try readFile(allocator, "/proc/meminfo");
    defer allocator.free(raw);

    var total: u64 = 0;
    var free_mem: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const value_raw = fields.next() orelse continue;
        const value_kb = std.fmt.parseInt(u64, value_raw, 10) catch continue;
        const bytes = value_kb * 1024;

        if (std.mem.eql(u8, key, "MemTotal")) total = bytes;
        if (std.mem.eql(u8, key, "MemFree")) free_mem = bytes;
        if (std.mem.eql(u8, key, "MemAvailable")) available = bytes;
        if (std.mem.eql(u8, key, "Buffers")) buffers = bytes;
        if (std.mem.eql(u8, key, "Cached")) cached = bytes;
        if (std.mem.eql(u8, key, "SwapTotal")) swap_total = bytes;
        if (std.mem.eql(u8, key, "SwapFree")) swap_free = bytes;
    }

    if (available == 0) available = free_mem + buffers + cached;
    const used = total -| available;
    return .{
        .total_bytes = total,
        .available_bytes = available,
        .used_bytes = used,
        .percent = if (total > 0) (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total))) * 100.0 else 0,
        .swap_total_bytes = swap_total,
        .swap_used_bytes = swap_total -| swap_free,
    };
}

const ignored_fs = [_][]const u8{
    "proc",       "sysfs",  "devtmpfs",   "devpts",     "tmpfs",   "cgroup",
    "cgroup2",    "pstore", "securityfs", "debugfs",    "tracefs", "configfs",
    "fusectl",    "mqueue", "hugetlbfs",  "bpf",        "autofs",  "binfmt_misc",
    "rpc_pipefs", "nsfs",   "efivarfs",   "fuse.lxcfs", "ramfs",   "squashfs",
};

fn ignoredFsType(fs: []const u8) bool {
    for (ignored_fs) |entry| {
        if (std.mem.eql(u8, fs, entry)) return true;
    }
    return false;
}

fn parseDisks(allocator: std.mem.Allocator) ![]DiskMetrics {
    const raw = try readFile(allocator, "/proc/mounts");
    defer allocator.free(raw);

    var disks = std.array_list.Managed(DiskMetrics).init(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const device_raw = fields.next() orelse continue;
        const mount_raw = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        if (ignoredFsType(fstype)) continue;
        if (std.mem.startsWith(u8, mount_raw, "/proc") or std.mem.startsWith(u8, mount_raw, "/sys") or std.mem.startsWith(u8, mount_raw, "/dev")) continue;

        const mount = try decodeMount(allocator, mount_raw);
        const device = try decodeMount(allocator, device_raw);

        var duplicate = false;
        for (disks.items) |existing| {
            if (std.mem.eql(u8, existing.mount, mount)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        const mount_z = try compat.dupeZ(allocator, mount);
        defer allocator.free(mount_z);
        var stat: Statvfs = undefined;
        if (c.statvfs(mount_z.ptr, @ptrCast(&stat)) != 0) continue;

        const frsize: u64 = @intCast(stat.f_frsize);
        const total = @as(u64, @intCast(stat.f_blocks)) * frsize;
        const free = @as(u64, @intCast(stat.f_bfree)) * frsize;
        const avail = @as(u64, @intCast(stat.f_bavail)) * frsize;
        const used = total -| free;
        if (total == 0) continue;

        try disks.append(.{
            .mount = mount,
            .filesystem = device,
            .total_bytes = total,
            .used_bytes = used,
            .available_bytes = avail,
            .percent = (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total))) * 100.0,
        });
    }
    return disks.toOwnedSlice();
}

fn decodeMount(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return allocator.dupe(u8, raw);
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 3 < raw.len) {
            const decoded = std.fmt.parseInt(u8, raw[i + 1 .. i + 4], 8) catch {
                try out.append(raw[i]);
                i += 1;
                continue;
            };
            try out.append(decoded);
            i += 4;
        } else {
            try out.append(raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

const NetCounters = struct { rx: u64, tx: u64 };

fn parseNetwork(allocator: std.mem.Allocator) !NetCounters {
    const raw = try readFile(allocator, "/proc/net/dev");
    defer allocator.free(raw);

    var rx: u64 = 0;
    var tx: u64 = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, iface, "lo")) continue;
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var values: [16]u64 = @splat(0);
        var idx: usize = 0;
        while (fields.next()) |field| : (idx += 1) {
            if (idx >= values.len) break;
            values[idx] = std.fmt.parseInt(u64, field, 10) catch 0;
        }
        rx += values[0];
        tx += values[8];
    }
    return .{ .rx = rx, .tx = tx };
}
