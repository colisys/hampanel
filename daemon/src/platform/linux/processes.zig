const std = @import("std");
const compat = @import("compat");

pub const Process = struct {
    pid: u32,
    ppid: u32,
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

pub fn list(allocator: std.mem.Allocator, limit: usize) !ProcessList {
    var items = std.array_list.Managed(Process).init(allocator);
    var total: usize = 0;

    var proc_dir = try compat.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc_dir.close();

    var it = proc_dir.iterate();
    while (try it.next()) |entry| {
        if (!isNumeric(entry.name)) continue;
        total += 1;
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const process = readProcess(allocator, pid) catch continue;
        try items.append(process);
    }

    std.sort.pdq(Process, items.items, {}, struct {
        fn lessThan(_: void, left: Process, right: Process) bool {
            return left.rss_bytes > right.rss_bytes;
        }
    }.lessThan);

    const trimmed = if (items.items.len > limit) items.items[0..limit] else items.items;
    return .{ .total = total, .processes = trimmed };
}

fn isNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

const StatInfo = struct {
    name: []const u8,
    state: []const u8,
    ppid: u32,
    threads: u32,
    utime: u64,
    stime: u64,
    rss_pages: i64,
    start_ticks: u64,
};

fn readStat(allocator: std.mem.Allocator, pid: u32) !StatInfo {
    const stat_path = try std.fmt.allocPrint(allocator, "/proc/{d}/stat", .{pid});
    const stat_raw = try compat.cwd().readFileAlloc(allocator, stat_path, 16 * 1024);

    const open_paren = std.mem.indexOfScalar(u8, stat_raw, '(') orelse return error.Malformed;
    const close_paren = std.mem.lastIndexOfScalar(u8, stat_raw, ')') orelse return error.Malformed;
    if (close_paren <= open_paren) return error.Malformed;
    const name = stat_raw[open_paren + 1 .. close_paren];

    const rest = std.mem.trimStart(u8, stat_raw[close_paren + 1 ..], " ");
    var fields = std.mem.tokenizeAny(u8, rest, " \t\n");
    var values: [24][]const u8 = undefined;
    var count: usize = 0;
    while (fields.next()) |field| {
        if (count >= values.len) break;
        values[count] = field;
        count += 1;
    }
    if (count < 22) return error.Malformed;

    return .{
        .name = name,
        .state = stateName(values[0]),
        .ppid = std.fmt.parseInt(u32, values[1], 10) catch 0,
        .threads = std.fmt.parseInt(u32, values[17], 10) catch 0,
        .utime = std.fmt.parseInt(u64, values[11], 10) catch 0,
        .stime = std.fmt.parseInt(u64, values[12], 10) catch 0,
        .rss_pages = std.fmt.parseInt(i64, values[21], 10) catch 0,
        .start_ticks = std.fmt.parseInt(u64, values[19], 10) catch 0,
    };
}

fn readCommand(allocator: std.mem.Allocator, pid: u32, fallback: []const u8) ![]const u8 {
    const cmd_path = try std.fmt.allocPrint(allocator, "/proc/{d}/cmdline", .{pid});
    const raw_cmd = compat.cwd().readFileAlloc(allocator, cmd_path, 64 * 1024) catch "";
    var command: []const u8 = try allocator.dupe(u8, raw_cmd);
    if (command.len > 0) {
        const mutable = @constCast(command);
        for (mutable) |*ch| {
            if (ch.* == 0) ch.* = ' ';
        }
        command = std.mem.trim(u8, mutable, " ");
    }
    if (command.len == 0) command = fallback;
    return command;
}

fn readProcess(allocator: std.mem.Allocator, pid: u32) !Process {
    const info = try readStat(allocator, pid);
    const rss_bytes: u64 = if (info.rss_pages > 0) @as(u64, @intCast(info.rss_pages)) * 4096 else 0;
    return .{
        .pid = pid,
        .ppid = info.ppid,
        .name = info.name,
        .state = info.state,
        .rss_bytes = rss_bytes,
        .cpu_ticks = info.utime + info.stime,
        .command = try readCommand(allocator, pid, info.name),
    };
}

fn stateName(code: []const u8) []const u8 {
    if (code.len == 0) return "unknown";
    return switch (code[0]) {
        'R' => "running",
        'S' => "sleeping",
        'D' => "disk sleep",
        'Z' => "zombie",
        'T' => "stopped",
        't' => "tracing",
        'I' => "idle",
        'X' => "dead",
        else => "unknown",
    };
}

fn readLinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    const target = compat.cwd().readLink(path, &buffer) catch return error.NotFound;
    return allocator.dupe(u8, target);
}

const Ids = struct { uid: u32, gid: u32 };

fn readIds(allocator: std.mem.Allocator, pid: u32) !Ids {
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/status", .{pid});
    const raw = try compat.cwd().readFileAlloc(allocator, path, 64 * 1024);
    var uid: u32 = 0;
    var gid: u32 = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        if (std.mem.eql(u8, key, "Uid:")) uid = std.fmt.parseInt(u32, value, 10) catch 0;
        if (std.mem.eql(u8, key, "Gid:")) gid = std.fmt.parseInt(u32, value, 10) catch 0;
    }
    return .{ .uid = uid, .gid = gid };
}

fn tcpState(code: []const u8) []const u8 {
    const value = std.fmt.parseInt(u8, code, 16) catch return "unknown";
    return switch (value) {
        0x01 => "established",
        0x02 => "syn_sent",
        0x03 => "syn_recv",
        0x04 => "fin_wait1",
        0x05 => "fin_wait2",
        0x06 => "time_wait",
        0x07 => "close",
        0x08 => "close_wait",
        0x09 => "last_ack",
        0x0a => "listen",
        0x0b => "closing",
        else => "unknown",
    };
}

fn scanNetFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    protocol: []const u8,
    sockets: *const std.AutoHashMap(u64, void),
    ports: *std.array_list.Managed(Port),
) !void {
    const raw = compat.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        var index: usize = 0;
        var inode_text: []const u8 = "";
        while (fields.next()) |field| : (index += 1) {
            if (index == 5) inode_text = field;
        }
        if (inode_text.len == 0) continue;
        const inode = std.fmt.parseInt(u64, inode_text, 10) catch continue;
        if (!sockets.contains(inode)) continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        try ports.append(.{
            .protocol = protocol,
            .local_port = port,
            .state = if (std.mem.eql(u8, protocol, "udp")) "unconn" else tcpState(state),
        });
    }
}

fn collectPorts(
    allocator: std.mem.Allocator,
    sockets: *const std.AutoHashMap(u64, void),
) ![]const Port {
    var ports = std.array_list.Managed(Port).init(allocator);
    try scanNetFile(allocator, "/proc/net/tcp", "tcp", sockets, &ports);
    try scanNetFile(allocator, "/proc/net/tcp6", "tcp6", sockets, &ports);
    try scanNetFile(allocator, "/proc/net/udp", "udp", sockets, &ports);
    try scanNetFile(allocator, "/proc/net/udp6", "udp6", sockets, &ports);
    return ports.items;
}

pub fn detail(allocator: std.mem.Allocator, pid: u32) !Detail {
    if (pid == 0) return error.InvalidPid;
    const info = readStat(allocator, pid) catch return error.NotFound;
    const ids = readIds(allocator, pid) catch Ids{ .uid = 0, .gid = 0 };

    const fd_path = try std.fmt.allocPrint(allocator, "/proc/{d}/fd", .{pid});
    var files = std.array_list.Managed([]const u8).init(allocator);
    var sockets = std.AutoHashMap(u64, void).init(allocator);
    if (compat.openDirAbsolute(fd_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (files.items.len >= 200) break;
            const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fd_path, entry.name });
            const target = readLinkAlloc(allocator, link_path) catch continue;
            try files.append(target);
            if (std.mem.startsWith(u8, target, "socket:[")) {
                const close = std.mem.indexOfScalar(u8, target, ']') orelse continue;
                const inode = std.fmt.parseInt(u64, target[8..close], 10) catch continue;
                sockets.put(inode, {}) catch {};
            }
        }
    } else |_| {}

    const exe = readLinkAlloc(allocator, try std.fmt.allocPrint(allocator, "/proc/{d}/exe", .{pid})) catch "";
    const cwd = readLinkAlloc(allocator, try std.fmt.allocPrint(allocator, "/proc/{d}/cwd", .{pid})) catch "";
    const command = try readCommand(allocator, pid, info.name);
    const rss_bytes: u64 = if (info.rss_pages > 0) @as(u64, @intCast(info.rss_pages)) * 4096 else 0;

    return .{
        .pid = pid,
        .ppid = info.ppid,
        .name = info.name,
        .state = info.state,
        .command = command,
        .exe = exe,
        .cwd = cwd,
        .uid = ids.uid,
        .gid = ids.gid,
        .threads = info.threads,
        .rss_bytes = rss_bytes,
        .cpu_ticks = info.utime + info.stime,
        .open_files = files.items,
        .ports = try collectPorts(allocator, &sockets),
    };
}

pub fn terminate(pid: u32, signal: []const u8) !void {
    if (pid <= 1) return error.InvalidPid;
    if (pid == @as(u32, @intCast(std.os.linux.getpid()))) return error.InvalidPid;
    const sig = if (std.mem.eql(u8, signal, "KILL")) std.posix.SIG.KILL else std.posix.SIG.TERM;
    std.posix.kill(@intCast(pid), sig) catch return error.TerminateFailed;
}
