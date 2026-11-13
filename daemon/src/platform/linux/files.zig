const std = @import("std");
const compat = @import("compat");

pub const Meta = struct {
    size: u64,
    kind: []const u8,
    mode: []const u8,
    uid: u32,
    gid: u32,
    modified_ms: i64,
    symlink: bool,
};

pub fn resolve(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or raw[0] != '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
    return compat.path.resolve(allocator, &.{raw});
}

pub fn stat(allocator: std.mem.Allocator, path: []const u8) !Meta {
    const path_z = try compat.dupeZ(allocator, path);
    defer allocator.free(path_z);

    var st: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path_z.ptr,
        std.os.linux.AT.SYMLINK_NOFOLLOW,
        std.os.linux.STATX.BASIC_STATS,
        &st,
    );
    if (std.os.linux.errno(rc) != .SUCCESS) return error.StatFailed;

    const mode: u32 = st.mode;
    var mode_buf: [10]u8 = undefined;
    formatMode(mode, &mode_buf);

    return .{
        .size = @intCast(st.size),
        .kind = kindName(mode),
        .mode = try allocator.dupe(u8, &mode_buf),
        .uid = st.uid,
        .gid = st.gid,
        .modified_ms = @as(i64, @intCast(st.mtime.sec)) * 1000 + @divTrunc(@as(i64, @intCast(st.mtime.nsec)), 1_000_000),
        .symlink = (mode & 0o170000) == 0o120000,
    };
}

pub fn secureDir(path: []const u8) !void {
    try compat.setFilePermissions(path, 0o700);
}

pub fn secureFile(file: compat.File, mode: compat.File.Mode) !void {
    try file.chmod(mode);
}

fn kindName(mode: u32) []const u8 {
    return switch (mode & 0o170000) {
        0o040000 => "dir",
        0o120000 => "symlink",
        0o060000 => "block",
        0o020000 => "char",
        0o010000 => "pipe",
        0o140000 => "socket",
        else => "file",
    };
}

fn formatMode(mode: u32, buf: *[10]u8) void {
    buf[0] = switch (mode & 0o170000) {
        0o040000 => 'd',
        0o120000 => 'l',
        0o060000 => 'b',
        0o020000 => 'c',
        0o010000 => 'p',
        0o140000 => 's',
        else => '-',
    };
    const bits = [_]u32{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const chars = [_]u8{ 'r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x' };
    for (bits, 0..) |bit, i| {
        buf[i + 1] = if ((mode & bit) != 0) chars[i] else '-';
    }
}
