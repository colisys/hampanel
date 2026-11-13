const std = @import("std");
const compat = @import("compat");

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

fn readProcess(allocator: std.mem.Allocator, pid: u32) !Process {
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

    const state = stateName(values[0]);
    const utime = std.fmt.parseInt(u64, values[11], 10) catch 0;
    const stime = std.fmt.parseInt(u64, values[12], 10) catch 0;
    const rss_pages = std.fmt.parseInt(i64, values[21], 10) catch 0;
    const rss_bytes: u64 = if (rss_pages > 0) @as(u64, @intCast(rss_pages)) * 4096 else 0;

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
    if (command.len == 0) command = name;

    return .{
        .pid = pid,
        .name = name,
        .state = state,
        .rss_bytes = rss_bytes,
        .cpu_ticks = utime + stime,
        .command = command,
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
