const std = @import("std");
const compat = @import("compat");
const types = @import("shared").types;

pub fn info(allocator: std.mem.Allocator) !types.SystemInfo {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&host_buf) catch "unknown";
    const uts = std.posix.uname();

    return .{
        .hostname = try allocator.dupe(u8, hostname),
        .os = readOsPretty(allocator) catch try allocator.dupe(u8, "Linux"),
        .kernel = try allocator.dupe(u8, std.mem.sliceTo(&uts.release, 0)),
        .arch = try allocator.dupe(u8, std.mem.sliceTo(&uts.machine, 0)),
        .cpu_model = readCpuModel(allocator) catch try allocator.dupe(u8, "unknown"),
        .cores = std.Thread.getCpuCount() catch 1,
        .uptime_seconds = readUptime(allocator) catch 0,
    };
}

fn readOsPretty(allocator: std.mem.Allocator) ![]const u8 {
    const raw = try compat.cwd().readFileAlloc(allocator, "/etc/os-release", 64 * 1024);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const prefix = "PRETTY_NAME=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var value = std.mem.trim(u8, line[prefix.len..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return "Linux";
}

fn readCpuModel(allocator: std.mem.Allocator) ![]const u8 {
    const raw = try compat.cwd().readFileAlloc(allocator, "/proc/cpuinfo", 1024 * 1024);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const key = std.mem.trim(u8, line[0..colon], " \t");
            if (std.mem.eql(u8, key, "model name") or std.mem.eql(u8, key, "Hardware") or std.mem.eql(u8, key, "Model")) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
            }
        }
    }
    return "unknown";
}

fn readUptime(allocator: std.mem.Allocator) !u64 {
    const raw = try compat.cwd().readFileAlloc(allocator, "/proc/uptime", 4096);
    var it = std.mem.tokenizeAny(u8, raw, " \t\n");
    const first = it.next() orelse return 0;
    const seconds = std.fmt.parseFloat(f64, first) catch 0;
    return @intFromFloat(seconds);
}
