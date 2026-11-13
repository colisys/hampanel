const std = @import("std");
const compat = @import("compat");
const common = @import("common.zig");
const c = common.c;

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
    if (raw.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
    if (!compat.path.isAbsolute(raw)) return error.InvalidPath;
    return compat.path.resolve(allocator, &.{raw});
}

pub fn stat(allocator: std.mem.Allocator, path: []const u8) !Meta {
    const wide = try common.toW(allocator, path);
    var data: c.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (c.GetFileAttributesExW(wide.ptr, c.GetFileExInfoStandard, &data) == 0) {
        return error.FileNotFound;
    }

    const attributes = data.dwFileAttributes;
    const is_dir = (attributes & c.FILE_ATTRIBUTE_DIRECTORY) != 0;
    const is_reparse = (attributes & c.FILE_ATTRIBUTE_REPARSE_POINT) != 0;

    return .{
        .size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow,
        .kind = if (is_dir) "dir" else if (is_reparse) "symlink" else "file",
        .mode = if (is_dir)
            try allocator.dupe(u8, "drwxrwxrwx")
        else if (is_reparse)
            try allocator.dupe(u8, "lrwxrwxrwx")
        else
            try allocator.dupe(u8, "-rw-rw-rw-"),
        .uid = 0,
        .gid = 0,
        .modified_ms = common.filetimeToMillis(data.ftLastWriteTime),
        .symlink = is_reparse,
    };
}

pub fn secureDir(path: []const u8) !void {
    _ = path;
}

pub fn secureFile(file: compat.File, mode: compat.File.Mode) !void {
    _ = file;
    _ = mode;
}
