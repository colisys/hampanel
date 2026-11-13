const std = @import("std");

pub const Entry = struct {
    at: []const u8,
    peer: []const u8,
    method: []const u8,
    path: []const u8,
    status: u16,
    duration_ms: u64,
};

pub const Log = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Log {
        try std.fs.cwd().makePath(dir);
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn append(self: *Log, entry: Entry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file_path = std.fs.path.join(self.allocator, &.{ self.dir, "audit.jsonl" }) catch return;
        defer self.allocator.free(file_path);

        const line = std.json.stringifyAlloc(self.allocator, entry, .{}) catch return;
        defer self.allocator.free(line);

        var file = std.fs.cwd().createFile(file_path, .{ .mode = 0o600, .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch {};
        file.writeAll(line) catch return;
        file.writeAll("\n") catch {};
    }

    pub fn path(self: *Log, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "audit.jsonl" });
    }
};
