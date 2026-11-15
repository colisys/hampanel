const std = @import("std");
const compat = @import("compat");
const common = @import("common.zig");
const c = common.c;
const net = @import("windows_c");

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

pub const InterfaceMetrics = struct {
    name: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_rate_bps: f64,
    tx_rate_bps: f64,
};

pub const NetworkMetrics = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    rx_rate_bps: f64,
    tx_rate_bps: f64,
    interfaces: []InterfaceMetrics,
};

pub const Metrics = struct {
    cpu: CpuMetrics,
    memory: MemoryMetrics,
    uptime_seconds: u64,
    disks: []DiskMetrics,
    network: NetworkMetrics,
};

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    prev_rx: u64 = 0,
    prev_tx: u64 = 0,
    prev_at_ms: i64 = 0,
};

pub fn sample(allocator: std.mem.Allocator, state: *State) !Metrics {
    state.mutex.lockUncancelable(compat.io());
    defer state.mutex.unlock(compat.io());

    var idle_time: c.FILETIME = undefined;
    var kernel_time: c.FILETIME = undefined;
    var user_time: c.FILETIME = undefined;
    var usage: f64 = 0;
    if (c.GetSystemTimes(&idle_time, &kernel_time, &user_time) != 0) {
        const idle = filetimeTicks(idle_time);
        const total = filetimeTicks(kernel_time) + filetimeTicks(user_time);
        if (state.prev_total > 0 and total > state.prev_total) {
            const delta_total = total - state.prev_total;
            const delta_idle = idle -| state.prev_idle;
            usage = (@as(f64, @floatFromInt(delta_total -| delta_idle)) / @as(f64, @floatFromInt(delta_total))) * 100.0;
        }
        state.prev_idle = idle;
        state.prev_total = total;
    }

    const memory = memoryInfo();
    const network = networkInfo(allocator) catch NetCounters{ .rx = 0, .tx = 0 };

    const now = compat.milliTimestamp();
    var rx_rate: f64 = 0;
    var tx_rate: f64 = 0;
    if (state.prev_at_ms > 0) {
        const elapsed = @as(f64, @floatFromInt(now - state.prev_at_ms)) / 1000.0;
        if (elapsed > 0 and network.rx >= state.prev_rx and network.tx >= state.prev_tx) {
            rx_rate = @as(f64, @floatFromInt(network.rx - state.prev_rx)) / elapsed;
            tx_rate = @as(f64, @floatFromInt(network.tx - state.prev_tx)) / elapsed;
        }
    }
    state.prev_rx = network.rx;
    state.prev_tx = network.tx;
    state.prev_at_ms = now;

    return .{
        .cpu = .{
            .usage_percent = clampPercent(usage),
            .cores = cpuCount(),
            .load1 = 0,
            .load5 = 0,
            .load15 = 0,
        },
        .memory = memory,
        .uptime_seconds = c.GetTickCount64() / 1000,
        .disks = try diskInfo(allocator),
        .network = .{
            .rx_bytes = network.rx,
            .tx_bytes = network.tx,
            .rx_rate_bps = rx_rate,
            .tx_rate_bps = tx_rate,
            .interfaces = &.{},
        },
    };
}

fn clampPercent(value: f64) f64 {
    if (value < 0) return 0;
    if (value > 100) return 100;
    return value;
}

fn filetimeTicks(value: c.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn cpuCount() u32 {
    var info: c.SYSTEM_INFO = undefined;
    c.GetSystemInfo(&info);
    return info.dwNumberOfProcessors;
}

fn memoryInfo() MemoryMetrics {
    var status: c.MEMORYSTATUSEX = std.mem.zeroes(c.MEMORYSTATUSEX);
    status.dwLength = @sizeOf(c.MEMORYSTATUSEX);
    if (c.GlobalMemoryStatusEx(&status) == 0) {
        return .{
            .total_bytes = 0,
            .available_bytes = 0,
            .used_bytes = 0,
            .percent = 0,
            .swap_total_bytes = 0,
            .swap_used_bytes = 0,
        };
    }
    const used = status.ullTotalPhys -| status.ullAvailPhys;
    return .{
        .total_bytes = status.ullTotalPhys,
        .available_bytes = status.ullAvailPhys,
        .used_bytes = used,
        .percent = if (status.ullTotalPhys > 0)
            (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(status.ullTotalPhys))) * 100.0
        else
            0,
        .swap_total_bytes = status.ullTotalPageFile,
        .swap_used_bytes = status.ullTotalPageFile -| status.ullAvailPageFile,
    };
}

const NetCounters = struct { rx: u64, tx: u64 };

fn networkInfo(allocator: std.mem.Allocator) !NetCounters {
    var size: c.ULONG = 0;
    _ = net.GetIfTable(null, &size, 0);
    if (size == 0) return .{ .rx = 0, .tx = 0 };

    const buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.of(net.MIB_IFROW), size);
    const table: *net.MIB_IFTABLE = @ptrCast(@alignCast(buffer.ptr));
    if (net.GetIfTable(table, &size, 0) != 0) return error.NetworkInfo;

    var counters = NetCounters{ .rx = 0, .tx = 0 };
    var index: usize = 0;
    while (index < table.dwNumEntries) : (index += 1) {
        const row = table.table[index];
        if (row.dwType == 24) continue;
        if (row.dwOperStatus != 1) continue;
        counters.rx += row.dwInOctets;
        counters.tx += row.dwOutOctets;
    }
    return counters;
}

fn diskInfo(allocator: std.mem.Allocator) ![]DiskMetrics {
    var buffer: [512]u16 = undefined;
    const length = c.GetLogicalDriveStringsW(buffer.len, &buffer);
    if (length == 0) return &.{};

    var disks = std.array_list.Managed(DiskMetrics).init(allocator);
    var offset: usize = 0;
    while (offset < length and offset < buffer.len) {
        const start = offset;
        while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
        if (offset >= buffer.len) break;
        const root_slice = buffer[start..offset];
        offset += 1;
        if (root_slice.len == 0) continue;

        var root_z: [64]u16 = undefined;
        if (root_slice.len + 1 > root_z.len) continue;
        @memcpy(root_z[0..root_slice.len], root_slice);
        root_z[root_slice.len] = 0;

        const drive_type = c.GetDriveTypeW(&root_z);
        if (drive_type != c.DRIVE_FIXED) continue;

        var free_available: c.ULARGE_INTEGER = undefined;
        var total: c.ULARGE_INTEGER = undefined;
        var total_free: c.ULARGE_INTEGER = undefined;
        if (c.GetDiskFreeSpaceExW(&root_z, &free_available, &total, &total_free) == 0) continue;

        var fs_buffer: [64]u16 = undefined;
        _ = c.GetVolumeInformationW(&root_z, null, 0, null, null, null, &fs_buffer, fs_buffer.len);

        const total_bytes = total.QuadPart;
        const free_bytes = total_free.QuadPart;
        if (total_bytes == 0) continue;
        const used = total_bytes -| free_bytes;

        try disks.append(.{
            .mount = try common.fromW(allocator, root_slice),
            .filesystem = common.fromW(allocator, std.mem.sliceTo(&fs_buffer, 0)) catch "NTFS",
            .total_bytes = total_bytes,
            .used_bytes = used,
            .available_bytes = free_available.QuadPart,
            .percent = (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total_bytes))) * 100.0,
        });
    }
    return disks.items;
}
