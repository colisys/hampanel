const std = @import("std");
const builtin = @import("builtin");

/// Bounds blocking TLS reads/writes so a stalled client cannot pin a thread.
/// The values are per syscall, not per request.
pub fn set(handle: std.posix.fd_t, read_ms: u32, write_ms: u32) void {
    if (builtin.os.tag == .windows) {
        const ws2 = struct {
            extern "ws2_32" fn setsockopt(
                s: usize,
                level: i32,
                optname: i32,
                optval: [*]const u8,
                optlen: i32,
            ) c_int;
        };
        var r: u32 = read_ms;
        var w: u32 = write_ms;
        const socket: usize = @intCast(handle);
        _ = ws2.setsockopt(socket, 0xffff, 4102, std.mem.asBytes(&r).ptr, 4);
        _ = ws2.setsockopt(socket, 0xffff, 4101, std.mem.asBytes(&w).ptr, 4);
        return;
    }

    setPosix(handle, std.posix.SO.RCVTIMEO, read_ms);
    setPosix(handle, std.posix.SO.SNDTIMEO, write_ms);
}

fn setPosix(fd: std.posix.fd_t, option: u32, ms: u32) void {
    const value = std.posix.timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        option,
        std.mem.asBytes(&value),
    ) catch {};
}
