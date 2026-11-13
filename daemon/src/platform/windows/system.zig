const std = @import("std");
const types = @import("shared").types;
const common = @import("common.zig");
const c = common.c;
const builtin = @import("builtin");

pub fn info(allocator: std.mem.Allocator) !types.SystemInfo {
    var host_buf: [256]u16 = undefined;
    var host_len: c.DWORD = host_buf.len;
    const hostname = if (c.GetComputerNameExW(c.ComputerNameDnsHostname, &host_buf, &host_len) != 0)
        try common.fromW(allocator, host_buf[0..@intCast(host_len)])
    else
        try allocator.dupe(u8, "unknown");

    const version = osVersion();

    return .{
        .hostname = hostname,
        .os = try std.fmt.allocPrint(allocator, "Windows {d}.{d} (build {d})", .{
            version.major, version.minor, version.build,
        }),
        .kernel = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
            version.major, version.minor, version.build,
        }),
        .arch = @tagName(builtin.target.cpu.arch),
        .cpu_model = cpuModel(allocator) catch try allocator.dupe(u8, "unknown"),
        .cores = cpuCount(),
        .uptime_seconds = c.GetTickCount64() / 1000,
    };
}

const OsVersion = struct { major: u32, minor: u32, build: u32 };

fn osVersion() OsVersion {
    const ntdll = c.GetModuleHandleW(@ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll").ptr));
    if (ntdll) |module| {
        if (c.GetProcAddress(module, "RtlGetVersion")) |proc| {
            const RtlGetVersion = @as(*const fn (*c.OSVERSIONINFOW) callconv(.winapi) c.NTSTATUS, @ptrCast(proc));
            var version_info: c.OSVERSIONINFOW = std.mem.zeroes(c.OSVERSIONINFOW);
            version_info.dwOSVersionInfoSize = @sizeOf(c.OSVERSIONINFOW);
            if (RtlGetVersion(&version_info) == 0) {
                return .{
                    .major = version_info.dwMajorVersion,
                    .minor = version_info.dwMinorVersion,
                    .build = version_info.dwBuildNumber,
                };
            }
        }
    }
    return .{ .major = 0, .minor = 0, .build = 0 };
}

fn cpuCount() usize {
    var sys_info: c.SYSTEM_INFO = undefined;
    c.GetSystemInfo(&sys_info);
    return @intCast(sys_info.dwNumberOfProcessors);
}

fn cpuModel(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "PROCESSOR_IDENTIFIER") catch
        allocator.dupe(u8, "unknown");
}
