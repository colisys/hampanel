const std = @import("std");

pub const Entry = struct {
    id: []const u8,
    original_path: []const u8,
    name: []const u8,
    kind: []const u8,
    size: u64,
    deleted_at: i64,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const Meta = struct {
    id: []const u8,
    original_path: []const u8,
    name: []const u8,
    kind: []const u8,
    size: u64,
    deleted_at: i64,
};

pub fn move(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Entry {
    if (isInside(allocator, data_dir, path)) return error.ReservedPath;

    const stat = std.fs.cwd().statFile(path) catch return error.NotFound;
    const is_dir = stat.kind == .directory;
    const kind = if (is_dir) "dir" else "file";
    const name = std.fs.path.basename(path);
    const id = try newId(allocator);
    const entry_dir = try std.fs.path.join(allocator, &.{ data_dir, "recycle", id });
    try std.fs.cwd().makePath(entry_dir);
    const payload = try std.fs.path.join(allocator, &.{ entry_dir, "payload" });

    movePath(allocator, path, payload, is_dir) catch |err| {
        std.fs.cwd().deleteTree(entry_dir) catch {};
        return err;
    };

    const meta = Meta{
        .id = id,
        .original_path = try allocator.dupe(u8, path),
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .size = if (is_dir) 0 else @intCast(stat.size),
        .deleted_at = std.time.milliTimestamp(),
    };
    writeMeta(allocator, entry_dir, meta) catch |err| {
        movePath(allocator, payload, path, is_dir) catch {};
        return err;
    };

    return .{
        .id = meta.id,
        .original_path = meta.original_path,
        .name = meta.name,
        .kind = meta.kind,
        .size = meta.size,
        .deleted_at = meta.deleted_at,
    };
}

pub fn list(allocator: std.mem.Allocator, data_dir: []const u8) ![]Entry {
    const root = try std.fs.path.join(allocator, &.{ data_dir, "recycle" });
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();

    var entries = std.ArrayList(Entry).init(allocator);
    var iterator = dir.iterate();
    while (try iterator.next()) |item| {
        if (item.kind != .directory) continue;
        const meta_path = try std.fs.path.join(allocator, &.{ root, item.name, "meta.json" });
        const raw = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024 * 1024) catch continue;
        const meta = std.json.parseFromSliceLeaky(Meta, allocator, raw, .{}) catch continue;
        try entries.append(.{
            .id = meta.id,
            .original_path = meta.original_path,
            .name = meta.name,
            .kind = meta.kind,
            .size = meta.size,
            .deleted_at = meta.deleted_at,
        });
    }

    std.sort.pdq(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.deleted_at > b.deleted_at;
        }
    }.lessThan);
    return entries.toOwnedSlice();
}

pub fn restore(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    if (!validId(id)) return error.InvalidId;
    const entry_dir = try std.fs.path.join(allocator, &.{ data_dir, "recycle", id });
    const meta = try readMeta(allocator, entry_dir);
    const payload = try std.fs.path.join(allocator, &.{ entry_dir, "payload" });
    const is_dir = std.mem.eql(u8, meta.kind, "dir");

    std.fs.cwd().access(meta.original_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.TargetExists,
    };

    const parent = std.fs.path.dirname(meta.original_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    movePath(allocator, payload, meta.original_path, is_dir) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    std.fs.cwd().deleteTree(entry_dir) catch {};
    return .{ .ok = true, .output = "已恢复到原路径" };
}

pub fn purge(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    if (!validId(id)) return error.InvalidId;
    const entry_dir = try std.fs.path.join(allocator, &.{ data_dir, "recycle", id });
    std.fs.cwd().access(entry_dir, .{}) catch return error.NotFound;
    try std.fs.cwd().deleteTree(entry_dir);
    return .{ .ok = true, .output = "已永久删除" };
}

pub fn empty(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const root = try std.fs.path.join(allocator, &.{ data_dir, "recycle" });
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = true, .output = "回收站为空" },
        else => return err,
    };
    defer dir.close();

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |item| {
        if (item.kind != .directory) continue;
        dir.deleteTree(item.name) catch continue;
        count += 1;
    }
    return .{ .ok = true, .output = try std.fmt.allocPrint(allocator, "已永久删除 {d} 项", .{count}) };
}

fn readMeta(allocator: std.mem.Allocator, entry_dir: []const u8) !Meta {
    const meta_path = try std.fs.path.join(allocator, &.{ entry_dir, "meta.json" });
    const raw = try std.fs.cwd().readFileAlloc(allocator, meta_path, 1024 * 1024);
    return std.json.parseFromSliceLeaky(Meta, allocator, raw, .{});
}

fn writeMeta(allocator: std.mem.Allocator, entry_dir: []const u8, meta: Meta) !void {
    const path = try std.fs.path.join(allocator, &.{ entry_dir, "meta.json" });
    const json = try std.json.stringifyAlloc(allocator, meta, .{ .whitespace = .indent_2 });
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

fn movePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8, is_dir: bool) !void {
    std.fs.renameAbsolute(from, to) catch {
        if (is_dir) {
            try copyTree(allocator, from, to);
            try std.fs.deleteTreeAbsolute(from);
        } else {
            try copyFile(from, to);
            try std.fs.deleteFileAbsolute(from);
        }
    };
}

fn copyTree(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    try std.fs.cwd().makePath(to);
    var dir = try std.fs.openDirAbsolute(from, .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |item| {
        const src = try std.fs.path.join(allocator, &.{ from, item.name });
        const dst = try std.fs.path.join(allocator, &.{ to, item.name });
        switch (item.kind) {
            .directory => try copyTree(allocator, src, dst),
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target = try dir.readLink(item.name, &buffer);
                try std.fs.symLinkAbsolute(target, dst, .{});
            },
            else => try copyFile(src, dst),
        }
    }
}

fn copyFile(from: []const u8, to: []const u8) !void {
    var src = try std.fs.openFileAbsolute(from, .{});
    defer src.close();
    const mode: std.fs.File.Mode = @intCast((try src.stat()).mode & 0o777);
    var dst = try std.fs.createFileAbsolute(to, .{ .truncate = true, .mode = mode });
    defer dst.close();
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = try src.read(&buffer);
        if (read == 0) break;
        try dst.writeAll(buffer[0..read]);
    }
}

fn isInside(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) bool {
    const normalized_dir = std.mem.trimRight(u8, data_dir, "/\\");
    if (!std.mem.startsWith(u8, path, normalized_dir)) return false;
    if (path.len == normalized_dir.len) return true;
    const next = path[normalized_dir.len];
    _ = allocator;
    return next == '/' or next == '\\';
}

fn newId(allocator: std.mem.Allocator) ![]const u8 {
    var random: [4]u8 = undefined;
    std.crypto.random.bytes(&random);
    return std.fmt.allocPrint(allocator, "{d}-{s}", .{ std.time.milliTimestamp(), std.fmt.bytesToHex(random, .lower) });
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}
