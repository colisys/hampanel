const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const c2 = @import("windows_c");

pub const Process = struct {
    pid: u32,
    name: []const u8,
    state: []const u8,
    rss_bytes: u64,
    cpu_ticks: u64,
    command: []const u8,
};

pub const ProcessList = struct {
    total: usize,
    processes: []const Process,
};

pub fn list(allocator: std.mem.Allocator, limit: usize) !ProcessList {
    const snapshot = c2.CreateToolhelp32Snapshot(c2.TH32CS_SNAPPROCESS, 0);
    if (snapshot == c2.INVALID_HANDLE_VALUE) return error.Snapshot;
    defer _ = c.CloseHandle(snapshot);

    var entry: c2.PROCESSENTRY32W = std.mem.zeroes(c2.PROCESSENTRY32W);
    entry.dwSize = @sizeOf(c2.PROCESSENTRY32W);
    if (c2.Process32FirstW(snapshot, &entry) == 0) return .{ .total = 0, .processes = &.{} };

    var items = std.array_list.Managed(Process).init(allocator);
    var total: usize = 0;

    while (true) {
        total += 1;
        if (items.items.len < limit * 2) {
            const process = readProcess(allocator, entry.th32ProcessID, std.mem.sliceTo(&entry.szExeFile, 0)) catch null;
            if (process) |value| try items.append(value);
        }
        if (c2.Process32NextW(snapshot, &entry) == 0) break;
    }

    std.sort.pdq(Process, items.items, {}, struct {
        fn lessThan(_: void, left: Process, right: Process) bool {
            return left.rss_bytes > right.rss_bytes;
        }
    }.lessThan);

    const trimmed = if (items.items.len > limit) items.items[0..limit] else items.items;
    return .{ .total = total, .processes = trimmed };
}

fn readProcess(allocator: std.mem.Allocator, pid: u32, name_wide: []const u16) !Process {
    const name = try common.fromW(allocator, name_wide);
    var rss: u64 = 0;
    var cpu_ticks: u64 = 0;
    var command: []const u8 = name;

    const handle = c.OpenProcess(0x0410, 0, pid);
    if (handle) |process_handle| {
        defer _ = c.CloseHandle(process_handle);

        var counters: c2.PROCESS_MEMORY_COUNTERS = std.mem.zeroes(c2.PROCESS_MEMORY_COUNTERS);
        counters.cb = @sizeOf(c2.PROCESS_MEMORY_COUNTERS);
        if (c2.GetProcessMemoryInfo(process_handle, &counters, counters.cb) != 0) {
            rss = counters.WorkingSetSize;
        }

        var creation: c.FILETIME = undefined;
        var exit_time: c.FILETIME = undefined;
        var kernel_time: c.FILETIME = undefined;
        var user_time: c.FILETIME = undefined;
        if (c.GetProcessTimes(process_handle, &creation, &exit_time, &kernel_time, &user_time) != 0) {
            const kernel = (@as(u64, kernel_time.dwHighDateTime) << 32) | kernel_time.dwLowDateTime;
            const user = (@as(u64, user_time.dwHighDateTime) << 32) | user_time.dwLowDateTime;
            cpu_ticks = kernel + user;
        }

        var path_buffer: [1024]u16 = undefined;
        var path_len: c.DWORD = path_buffer.len;
        if (c.QueryFullProcessImageNameW(process_handle, 0, &path_buffer, &path_len) != 0) {
            command = common.fromW(allocator, path_buffer[0..@intCast(path_len)]) catch name;
        }
    }

    return .{
        .pid = pid,
        .name = name,
        .state = "running",
        .rss_bytes = rss,
        .cpu_ticks = cpu_ticks,
        .command = command,
    };
}

pub const Port = struct {
    protocol: []const u8,
    local_port: u16,
    state: []const u8,
};

pub const Detail = struct {
    pid: u32,
    ppid: u32,
    name: []const u8,
    state: []const u8,
    command: []const u8,
    exe: []const u8,
    cwd: []const u8,
    uid: u32,
    gid: u32,
    threads: u32,
    rss_bytes: u64,
    cpu_ticks: u64,
    open_files: []const []const u8,
    ports: []const Port,
};

pub fn detail(_: std.mem.Allocator, _: u32) !Detail {
    return error.Unsupported;
}

pub fn terminate(_: u32, _: []const u8) !void {
    return error.Unsupported;
}
