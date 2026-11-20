const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Immutable-attribute protection for critical paths.
///
/// `chattr +i` is the enforcement: files and directories carrying it cannot be
/// modified, renamed or deleted even by root until the attribute is cleared.
/// The panel keeps a manifest so it can report what it protected and restore
/// protection after maintenance.
pub const Entry = struct {
    path: []const u8,
    /// Raw `lsattr` flags, e.g. "----i---------e------".
    attributes: []const u8,
    immutable: bool,
    /// Whether the path still exists.
    present: bool,
};

pub const Status = struct {
    available: bool,
    /// chattr/lsattr resolved from PATH.
    tooling: bool,
    entries: []const Entry,
    message: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const manifest_name = "tamper-manifest.txt";

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const tooling = exec.commandExists(allocator, "chattr") and exec.commandExists(allocator, "lsattr");
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);

    const raw = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch "";
    defer if (raw.len > 0) allocator.free(raw);

    var entries = std.array_list.Managed(Entry).init(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \r\t");
        if (path.len == 0) continue;
        try entries.append(.{
            .path = try allocator.dupe(u8, path),
            .attributes = try readAttributes(allocator, path),
            .immutable = false,
            .present = exists(path),
        });
        const last = &entries.items[entries.items.len - 1];
        last.immutable = std.mem.indexOfScalar(u8, last.attributes, 'i') != null;
    }

    return .{
        .available = tooling and entries.items.len > 0,
        .tooling = tooling,
        .entries = entries.items,
        .message = if (!tooling)
            "缺少 chattr/lsattr，无法进行不可变保护"
        else if (entries.items.len == 0)
            "尚未保护任何路径"
        else
            "",
    };
}

pub fn protect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    if (!exec.commandExists(allocator, "chattr")) return error.ChattrUnavailable;
    // A directory needs -R: attaching +i to the directory alone still allows
    // creating and rewriting entries inside it, and only the recursive form
    // stops new files from appearing under a protected path.
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("chattr");
    if (try isDirectory(allocator, path)) try argv.append("-R");
    try argv.append("+i");
    try argv.append(path);

    const result = exec.run(allocator, argv.items, 256 * 1024) catch
        return error.ChattrUnavailable;
    // `textOf` borrows from the buffers, so the failure output is copied before
    // they are released.
    if (!result.ok()) {
        const output = try allocator.dupe(u8, textOf(result));
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .ok = false, .output = output };
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Persist only after the attribute was actually applied.
    try appendManifest(allocator, data_dir, path);
    return .{ .ok = true, .output = "" };
}

pub fn unprotect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    if (!exec.commandExists(allocator, "chattr")) return error.ChattrUnavailable;
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("chattr");
    if (try isDirectory(allocator, path)) try argv.append("-R");
    try argv.append("-i");
    try argv.append(path);

    const result = exec.run(allocator, argv.items, 256 * 1024) catch
        return error.ChattrUnavailable;
    if (!result.ok()) {
        const output = try allocator.dupe(u8, textOf(result));
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .ok = false, .output = output };
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    try removeFromManifest(allocator, data_dir, path);
    return .{ .ok = true, .output = "" };
}

/// Re-applies every manifest entry after a reboot: +i survives on most
/// filesystems, but a mount, image rebuild or fsck can drop it, and silent loss
/// of protection is exactly what this feature exists to prevent.
pub fn restoreAll(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    const raw = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch return 0;
    defer allocator.free(raw);

    var restored: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \r\t");
        if (path.len == 0 or !exists(path)) continue;
        const attributes = readAttributes(allocator, path) catch "";
        defer allocator.free(attributes);
        if (std.mem.indexOfScalar(u8, attributes, 'i') != null) continue;
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("chattr");
        if (try isDirectory(allocator, path)) try argv.append("-R");
        try argv.append("+i");
        try argv.append(path);
        const result = exec.run(allocator, argv.items, 256 * 1024) catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.ok()) restored += 1;
    }
    return restored;
}

fn isDirectory(allocator: std.mem.Allocator, path: []const u8) !bool {
    _ = allocator;
    var dir = std.Io.Dir.openDirAbsolute(compat.io(), path, .{ .iterate = false }) catch return false;
    dir.close(compat.io());
    return true;
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn manifestPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    const root = try compat.path.join(allocator, &.{ data_dir, "security" });
    defer allocator.free(root);
    return compat.path.join(allocator, &.{ root, manifest_name });
}

fn readAttributes(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!exec.commandExists(allocator, "lsattr")) return try allocator.dupe(u8, "");
    const result = exec.run(allocator, &.{ "lsattr", "-d", path }, 64 * 1024) catch
        return try allocator.dupe(u8, "");
    // Copy the first field before the buffers are released: `first` borrows
    // from `result.stdout`.
    const owned = blk: {
        if (!result.ok()) break :blk try allocator.dupe(u8, "");
        var tokens = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
        const first = tokens.next() orelse break :blk try allocator.dupe(u8, "");
        break :blk try allocator.dupe(u8, first);
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return owned;
}

fn appendManifest(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !void {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    if (compat.path.dirname(manifest)) |dir| compat.cwd().makePath(dir) catch {};

    const existing = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), path)) return;
    }

    const updated = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ existing, path });
    defer allocator.free(updated);
    var file = try compat.createFileAbsolute(manifest, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(updated);
}

fn removeFromManifest(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !void {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    const existing = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch return;
    defer allocator.free(existing);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, path)) continue;
        try out.writer.print("{s}\n", .{text});
    }
    var file = try compat.createFileAbsolute(manifest, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(out.written());
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
