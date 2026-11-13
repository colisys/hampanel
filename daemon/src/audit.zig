const std = @import("std");
const compat = @import("compat");

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
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Log {
        try compat.cwd().makePath(dir);
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn append(self: *Log, entry: Entry) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());

        const file_path = compat.path.join(self.allocator, &.{ self.dir, "audit.jsonl" }) catch return;
        defer self.allocator.free(file_path);

        const line = std.json.Stringify.valueAlloc(self.allocator, entry, .{}) catch return;
        defer self.allocator.free(line);

        var file = compat.cwd().createFile(file_path, .{ .mode = 0o600, .truncate = false }) catch return;
        defer file.close();
        const size = file.length() catch return;
        file.writePositionalAll(line, size) catch return;
        file.writePositionalAll("\n", size + line.len) catch {};
    }

    pub fn path(self: *Log, allocator: std.mem.Allocator) ![]u8 {
        return compat.path.join(allocator, &.{ self.dir, "audit.jsonl" });
    }
};
