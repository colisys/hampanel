const std = @import("std");
const compat = @import("compat");
const db = @import("db.zig");

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
    database: *db.Db,

    pub fn init(allocator: std.mem.Allocator, database: *db.Db) !Log {
        return .{ .allocator = allocator, .database = database };
    }

    pub fn append(self: *Log, entry: Entry) void {
        self.database.execute(
            "INSERT INTO audit_log(at, peer, method, path, status, duration_ms) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            &.{
                .{ .text = entry.at },
                .{ .text = entry.peer },
                .{ .text = entry.method },
                .{ .text = entry.path },
                .{ .int = entry.status },
                .{ .int = @intCast(entry.duration_ms) },
            },
        ) catch return;
    }

    pub fn recent(self: *Log, allocator: std.mem.Allocator, limit: usize) ![]Entry {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(
            "SELECT at, peer, method, path, status, duration_ms FROM audit_log ORDER BY id DESC LIMIT ?1",
        );
        defer statement.deinit();
        try statement.bind(&.{.{ .int = @intCast(limit) }});

        var items = std.array_list.Managed(Entry).init(allocator);
        while (try statement.step()) {
            try items.append(.{
                .at = try allocator.dupe(u8, statement.columnText(0)),
                .peer = try allocator.dupe(u8, statement.columnText(1)),
                .method = try allocator.dupe(u8, statement.columnText(2)),
                .path = try allocator.dupe(u8, statement.columnText(3)),
                .status = @intCast(statement.columnInt(4)),
                .duration_ms = @intCast(statement.columnInt(5)),
            });
        }
        return items.items;
    }
};
