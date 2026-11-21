// Compatibility helpers that keep the daemon's file-system call sites close to
// their pre-0.17 shape while the underlying operations use the new `std.Io` API.
const std = @import("std");
const builtin = @import("builtin");

pub const path = std.Io.Dir.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;

pub const FileMode = u32;

/// Old `std.fs.File.Mode` was a plain integer. The new API uses an enum-backed
/// permissions type, so helpers translate between them.
pub const Mode = FileMode;

var global_io: std.Io = undefined;
var io_initialized = false;
var environ_map: ?*const std.process.Environ.Map = null;

pub fn setEnviron(map: *const std.process.Environ.Map) void {
    environ_map = map;
}

pub fn getEnv(name: []const u8) ?[]const u8 {
    // Tests run without an environ map (`zig build test` passes none), and a
    // missing PATH would make every command lookup fail silently. Searching the
    // standard locations is the same fallback a shell would use.
    if (environ_map) |map| {
        if (map.get(name)) |value| return value;
    }
    if (std.mem.eql(u8, name, "PATH")) return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    return null;
}

pub fn cloneEnv(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    const source = environ_map orelse return map;
    const keys = source.keys();
    const values = source.values();
    for (keys, values) |key, value| try map.put(key, value);
    return map;
}

pub fn setIo(value: std.Io) void {
    global_io = value;
    io_initialized = true;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    std.debug.assert(io_initialized);
    return global_io;
}

pub const CreateOptions = struct {
    mode: Mode = 0o666,
    truncate: bool = true,
    read: bool = false,
    exclusive: bool = false,
    lock: std.Io.File.Lock = .none,
};

pub const OpenOptions = struct {
    mode: std.Io.Dir.OpenFileOptions.Mode = .read_only,
    allow_directory: bool = true,
    path_only: bool = false,
    lock: std.Io.File.Lock = .none,
};

pub const Stat = struct {
    size: u64,
    mode: Mode,
    kind: std.Io.File.Kind,
};

pub const File = struct {
    pub const Mode = FileMode;
    pub const Kind = std.Io.File.Kind;
    inner: std.Io.File,

    pub fn close(self: File) void {
        self.inner.close(io());
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.inner.writeStreamingAll(io(), bytes);
    }

    /// Streaming writes only reach the OS page cache; without this a manifest
    /// written and read back immediately can still look empty.
    pub fn sync(self: File) !void {
        try self.inner.sync(io());
    }

    pub fn write(self: File, bytes: []const u8) !usize {
        return self.inner.writeStreaming(io(), &.{}, &.{bytes}, 1);
    }

    pub fn read(self: File, buf: []u8) !usize {
        // Zig 0.17 signals EOF with error.EndOfStream; every caller here uses
        // the old `0 == EOF` contract, so normalize it in one place.
        return self.inner.readStreaming(io(), &.{buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }

    pub fn readAll(self: File, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max: usize) ![]u8 {
        var buffer: [4096]u8 = undefined;
        var reader = self.inner.reader(io(), &buffer);
        return reader.interface.allocRemaining(allocator, .limited(max));
    }

    pub fn stat(self: File) !Stat {
        return statOf(try self.inner.stat(io()));
    }

    pub fn chmod(self: File, mode: FileMode) !void {
        try self.inner.setPermissions(io(), @fromBackingInt(@intCast(mode)));
    }

    pub fn chown(self: File, uid: ?std.Io.File.Uid, gid: ?std.Io.File.Gid) !void {
        try self.inner.setOwner(io(), uid, gid);
    }

    pub fn length(self: File) !u64 {
        return self.inner.length(io());
    }

    pub fn writePositionalAll(self: File, bytes: []const u8, offset: u64) !void {
        try self.inner.writePositionalAll(io(), bytes, offset);
    }

    pub fn readPositionalAll(self: File, buffer: []u8, offset: u64) !usize {
        return self.inner.readPositionalAll(io(), buffer, offset);
    }

    pub fn setLength(self: File, size: u64) !void {
        try self.inner.setLength(io(), size);
    }
};

pub const Dir = struct {
    inner: std.Io.Dir,

    pub fn close(self: Dir) void {
        self.inner.close(io());
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8, max: usize) ![]u8 {
        // Streaming read: virtual files (procfs/sysfs) report size 0, and the
        // size-based allocation path then returns empty content.
        var file = try self.inner.openFile(io(), sub_path, .{});
        defer file.close(io());
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.readerStreaming(io(), &buffer);
        return reader.interface.allocRemaining(allocator, .limited(max));
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDirPath(io(), sub_path);
    }

    pub fn access(self: Dir, sub_path: []const u8, _: anytype) !void {
        try self.inner.access(io(), sub_path, .{});
    }

    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateOptions) !File {
        return .{ .inner = try self.inner.createFile(io(), sub_path, .{
            .read = options.read,
            .truncate = options.truncate,
            .exclusive = options.exclusive,
            .lock = options.lock,
            .permissions = @fromBackingInt(@intCast(options.mode)),
        }) };
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenOptions) !File {
        return .{ .inner = try self.inner.openFile(io(), sub_path, .{
            .mode = options.mode,
            .allow_directory = options.allow_directory,
            .path_only = options.path_only,
            .lock = options.lock,
        }) };
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteFile(io(), sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteTree(io(), sub_path);
    }

    pub fn statFile(self: Dir, sub_path: []const u8, _: anytype) !Stat {
        return statOf(try self.inner.statFile(io(), sub_path, .{}));
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) !void {
        try std.Io.Dir.rename(self.inner, old_sub_path, self.inner, new_sub_path, io());
    }

    pub fn copyFile(self: Dir, source_path: []const u8, dest_dir: Dir, dest_path: []const u8, _: anytype) !void {
        try std.Io.Dir.copyFile(self.inner, source_path, dest_dir.inner, dest_path, io(), .{ .replace = true });
    }

    pub fn chmod(self: Dir, mode: Mode) !void {
        try self.inner.setPermissions(io(), @fromBackingInt(@intCast(mode)));
    }

    pub fn chown(self: Dir, uid: std.Io.File.Uid, gid: std.Io.File.Gid) !void {
        try self.inner.setOwner(io(), uid, gid);
    }

    pub fn readLink(self: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
        const n = try std.Io.Dir.readLink(self.inner, io(), sub_path, buffer);
        return buffer[0..n];
    }
};

pub const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

pub const Iterator = struct {
    inner: std.Io.Dir.Iterator,

    pub fn next(self: *Iterator) !?Entry {
        const entry = try self.inner.next(io()) orelse return null;
        return .{ .name = entry.name, .kind = entry.kind };
    }
};

pub fn cwd() Dir {
    return .{ .inner = .cwd() };
}

/// Opens a file whose path may be absolute or relative to the working
/// directory. The *Absolute helpers assert on relative input, which turns a
/// relative `data_dir` into a panic instead of an error.
pub fn openFileAny(sub_path: []const u8, options: OpenOptions) !File {
    if (std.Io.Dir.path.isAbsolute(sub_path)) return openFileAbsolute(sub_path, options);
    return .{ .inner = try std.Io.Dir.cwd().openFile(io(), sub_path, .{
        .mode = options.mode,
        .allow_directory = options.allow_directory,
        .path_only = options.path_only,
        .lock = options.lock,
    }) };
}

pub fn createFileAny(sub_path: []const u8, options: CreateOptions) !File {
    if (std.Io.Dir.path.isAbsolute(sub_path)) return createFileAbsolute(sub_path, options);
    return .{ .inner = try std.Io.Dir.cwd().createFile(io(), sub_path, .{
        .read = options.read,
        .truncate = options.truncate,
        .exclusive = options.exclusive,
        .lock = options.lock,
        .permissions = @fromBackingInt(@intCast(options.mode)),
    }) };
}

pub fn openDirAny(sub_path: []const u8, iterate: bool) !Dir {
    if (std.Io.Dir.path.isAbsolute(sub_path)) return openDirAbsolute(sub_path, .{ .iterate = iterate });
    return .{ .inner = try std.Io.Dir.cwd().openDir(io(), sub_path, .{
        .access_sub_paths = true,
        .iterate = iterate,
        .follow_symlinks = true,
    }) };
}

pub fn createFileAbsolute(sub_path: []const u8, options: CreateOptions) !File {
    return .{ .inner = try std.Io.Dir.createFileAbsolute(io(), sub_path, .{
        .read = options.read,
        .truncate = options.truncate,
        .exclusive = options.exclusive,
        .lock = options.lock,
        .permissions = @fromBackingInt(@intCast(options.mode)),
    }) };
}

pub fn openFileAbsolute(sub_path: []const u8, options: OpenOptions) !File {
    return .{ .inner = try std.Io.Dir.openFileAbsolute(io(), sub_path, .{
        .mode = options.mode,
        .allow_directory = options.allow_directory,
        .path_only = options.path_only,
        .lock = options.lock,
    }) };
}

pub fn openDirAbsolute(sub_path: []const u8, options: anytype) !Dir {
    const iterate = if (@hasField(@TypeOf(options), "iterate")) options.iterate else false;
    return .{ .inner = try std.Io.Dir.openDirAbsolute(io(), sub_path, .{
        .access_sub_paths = true,
        .iterate = iterate,
        .follow_symlinks = true,
    }) };
}

pub fn deleteFileAbsolute(sub_path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(io(), sub_path);
}

pub fn deleteTreeAbsolute(sub_path: []const u8) !void {
    try std.Io.Dir.deleteTree(.cwd(), io(), sub_path);
}

pub fn makeDirAbsolute(sub_path: []const u8, mode: Mode) !void {
    try std.Io.Dir.createDirAbsolute(io(), sub_path, @fromBackingInt(@intCast(mode)));
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    try std.Io.Dir.renameAbsolute(old_path, new_path, io());
}

pub fn symLinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    try std.Io.Dir.symLinkAbsolute(io(), target_path, sym_link_path, flags);
}

pub fn copyFileAbsolute(source_path: []const u8, dest_path: []const u8, _: anytype) !void {
    try std.Io.Dir.copyFileAbsolute(source_path, dest_path, io(), .{ .replace = true });
}

pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(io(), allocator);
}

pub fn timestamp() i64 {
    return std.Io.Clock.now(.real, io()).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.now(.real, io()).toMilliseconds();
}

pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

pub fn setFilePermissions(sub_path: []const u8, mode: Mode) !void {
    try std.Io.Dir.setFilePermissions(.cwd(), io(), sub_path, @fromBackingInt(@intCast(mode)), .{});
}

pub fn randomBytes(buffer: []u8) void {
    std.Io.random(io(), buffer);
}

pub fn writeOut(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io(), bytes);
}

pub fn printOut(comptime format: []const u8, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io(), &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn dupeZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(out[0..value.len], value);
    return out;
}

fn statOf(value: std.Io.File.Stat) Stat {
    return .{
        .size = value.size,
        .mode = permissionsToMode(value.permissions),
        .kind = value.kind,
    };
}

fn permissionsToMode(value: std.Io.File.Permissions) Mode {
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        return @intCast(value.toMode());
    }
    return @intCast(@backingInt(value));
}
