const std = @import("std");
const exec = @import("shared").exec;

pub const c = @import("windows_c");

pub const PROCESS_QUERY_LIMITED_INFORMATION: c.DWORD = 0x1000;

pub fn toW(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
}

pub fn fromW(allocator: std.mem.Allocator, value: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, value);
}

pub fn fromWZ(allocator: std.mem.Allocator, value: [*:0]const u16) ![]u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return std.unicode.utf16LeToUtf8Alloc(allocator, value[0..len]);
}

pub fn powershell(allocator: std.mem.Allocator, script: []const u8, max_output: usize) !exec.Result {
    return exec.run(allocator, &.{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
    }, max_output);
}

pub fn filetimeToMillis(filetime: c.FILETIME) i64 {
    const ticks = (@as(u64, filetime.dwHighDateTime) << 32) | filetime.dwLowDateTime;
    if (ticks == 0) return 0;
    // 100ns ticks since 1601-01-01 -> ms since Unix epoch
    const unix_ticks: i128 = @as(i128, ticks) - 116444736000000000;
    return @intCast(@divTrunc(unix_ticks, 10000));
}

pub fn quotePowerShell(value: []const u8, buffer: []u8) []const u8 {
    var index: usize = 0;
    if (index >= buffer.len) return "";
    buffer[index] = '\'';
    index += 1;
    for (value) |ch| {
        if (ch == '\'') {
            if (index + 2 >= buffer.len) break;
            buffer[index] = '\'';
            buffer[index + 1] = '\'';
            index += 2;
        } else {
            if (index + 1 >= buffer.len) break;
            buffer[index] = ch;
            index += 1;
        }
    }
    if (index + 1 < buffer.len) {
        buffer[index] = '\'';
        index += 1;
    }
    return buffer[0..index];
}
