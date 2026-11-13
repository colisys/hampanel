const std = @import("std");

pub const Version = struct {
    id: []const u8,
    created_at: i64,
    size: u64,
};

pub const Content = struct {
    bytes: []const u8,
    size: u64,
    truncated: bool,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const Meta = struct {
    path: []const u8,
    versions: []const Version,
};

const max_versions = 20;

var mutex: std.Thread.Mutex = .{};

pub fn snapshot(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !?Version {
    mutex.lock();
    defer mutex.unlock();
    return snapshotLocked(allocator, data_dir, path);
}

fn snapshotLocked(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !?Version {
    var source = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.IsDir => return null,
        else => return err,
    };
    defer source.close();
    const stat = try source.stat();

    const dir = try versionDir(allocator, data_dir, path);
    try std.fs.cwd().makePath(dir);

    const meta = loadMeta(allocator, dir) catch Meta{
        .path = try allocator.dupe(u8, path),
        .versions = &.{},
    };

    var random: [3]u8 = undefined;
    std.crypto.random.bytes(&random);
    const id = try std.fmt.allocPrint(allocator, "{d}-{s}", .{ std.time.milliTimestamp(), std.fmt.bytesToHex(random, .lower) });
    const blob_path = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.blob", .{id}) });
    try copyFileTo(path, blob_path, 0o600);

    var versions = std.ArrayList(Version).init(allocator);
    try versions.appendSlice(meta.versions);
    try versions.append(.{
        .id = id,
        .created_at = std.time.milliTimestamp(),
        .size = @intCast(stat.size),
    });

    if (versions.items.len > max_versions) {
        const remove_count = versions.items.len - max_versions;
        for (versions.items[0..remove_count]) |old| {
            const old_blob = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.blob", .{old.id}) });
            std.fs.deleteFileAbsolute(old_blob) catch {};
        }
        const kept = try allocator.dupe(Version, versions.items[remove_count..]);
        versions.deinit();
        try writeMeta(allocator, dir, path, kept);
        return kept[kept.len - 1];
    }

    try writeMeta(allocator, dir, path, versions.items);
    return versions.items[versions.items.len - 1];
}

pub fn list(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) ![]Version {
    mutex.lock();
    defer mutex.unlock();

    const dir = try versionDir(allocator, data_dir, path);
    const meta = loadMeta(allocator, dir) catch return &.{};
    var result = try allocator.alloc(Version, meta.versions.len);
    for (meta.versions, 0..) |version, index| {
        result[meta.versions.len - 1 - index] = version;
    }
    return result;
}

pub fn read(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    path: []const u8,
    id: []const u8,
    max_bytes: usize,
) !Content {
    if (!validId(id)) return error.InvalidVersion;
    mutex.lock();
    defer mutex.unlock();

    const dir = try versionDir(allocator, data_dir, path);
    const meta = try loadMeta(allocator, dir);
    var found: ?Version = null;
    for (meta.versions) |version| {
        if (std.mem.eql(u8, version.id, id)) {
            found = version;
            break;
        }
    }
    const version = found orelse return error.VersionNotFound;

    const blob_path = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.blob", .{id}) });
    var file = std.fs.openFileAbsolute(blob_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.VersionNotFound,
        else => return err,
    };
    defer file.close();
    const to_read: usize = @intCast(@min(version.size, max_bytes));
    const bytes = try allocator.alloc(u8, to_read);
    const read_count = try file.readAll(bytes);
    return .{
        .bytes = bytes[0..read_count],
        .size = version.size,
        .truncated = version.size > read_count,
    };
}

pub fn restore(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8, id: []const u8) !Outcome {
    if (!validId(id)) return error.InvalidVersion;

    mutex.lock();
    defer mutex.unlock();

    const dir = try versionDir(allocator, data_dir, path);
    const meta = try loadMeta(allocator, dir);
    var found: ?Version = null;
    for (meta.versions) |version| {
        if (std.mem.eql(u8, version.id, id)) {
            found = version;
            break;
        }
    }
    _ = found orelse return error.VersionNotFound;

    _ = snapshotLocked(allocator, data_dir, path) catch null;

    const blob_path = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.blob", .{id}) });
    const mode = blk: {
        const existing = std.fs.cwd().statFile(path) catch break :blk @as(std.fs.File.Mode, 0o644);
        break :blk @as(std.fs.File.Mode, @intCast(existing.mode & 0o777));
    };

    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var source = try std.fs.openFileAbsolute(blob_path, .{});
    defer source.close();
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.hampanel-version.tmp", .{path});
    {
        var target = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true, .mode = mode });
        defer target.close();
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const read_count = try source.read(&buffer);
            if (read_count == 0) break;
            try target.writeAll(buffer[0..read_count]);
        }
        target.chmod(mode) catch {};
    }
    std.fs.renameAbsolute(temp_path, path) catch |err| {
        std.fs.deleteFileAbsolute(temp_path) catch {};
        return err;
    };

    return .{ .ok = true, .output = "已恢复历史版本（恢复前的文件内容已保存为新版本）" };
}

fn versionDir(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fs.path.join(allocator, &.{ data_dir, "versions", &hex });
}

fn loadMeta(allocator: std.mem.Allocator, dir: []const u8) !Meta {
    const path = try std.fs.path.join(allocator, &.{ dir, "meta.json" });
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.VersionNotFound,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Meta, allocator, raw, .{});
}

fn writeMeta(allocator: std.mem.Allocator, dir: []const u8, path: []const u8, versions: []const Version) !void {
    const meta_path = try std.fs.path.join(allocator, &.{ dir, "meta.json" });
    const meta = Meta{ .path = path, .versions = versions };
    const json = try std.json.stringifyAlloc(allocator, meta, .{ .whitespace = .indent_2 });
    var file = try std.fs.createFileAbsolute(meta_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

fn copyFileTo(source_path: []const u8, target_path: []const u8, mode: std.fs.File.Mode) !void {
    var source = try std.fs.openFileAbsolute(source_path, .{});
    defer source.close();
    var target = try std.fs.createFileAbsolute(target_path, .{ .truncate = true, .mode = mode });
    defer target.close();
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = try source.read(&buffer);
        if (read_count == 0) break;
        try target.writeAll(buffer[0..read_count]);
    }
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}
