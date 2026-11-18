const std = @import("std");
const compat = @import("compat");
const config = @import("config.zig");
const db = @import("db.zig");
const tls = @import("tls.zig");
const pki = @import("pki.zig");
const audit = @import("audit.zig");
const platform = @import("platform/mod.zig");
const tasks = @import("tasks.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    update_mutex: std.Io.Mutex = .init,
    owned_update_channel: ?[]const u8 = null,
    owned_github_mirror: ?[]const u8 = null,

    config_path: []const u8 = config.default_path,
    db: *db.Db,
    started_at: i64,
    tls: tls.Context,
    pki: pki.Paths,
    audit: audit.Log,
    tasks: *tasks.Manager,
    metrics: platform.MetricsState = .{},
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    sse_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stream_clients: StreamClients = .{ .counts = std.StringHashMap(usize).init(std.heap.page_allocator) },
    task_limits: TaskLimits = .{ .entries = std.StringHashMap(Window).init(std.heap.page_allocator) },

    pub const Window = struct {
        started_at: i64,
        count: u32,
    };

    pub const TaskLimits = struct {
        mutex: std.Io.Mutex = .init,
        entries: std.StringHashMap(Window),

        /// Returns false once `limit` submissions happened inside `window_ms`.
        pub fn allow(
            self: *TaskLimits,
            allocator: std.mem.Allocator,
            cn: []const u8,
            limit: u32,
            window_ms: i64,
            now: i64,
        ) !bool {
            self.mutex.lockUncancelable(compat.io());
            defer self.mutex.unlock(compat.io());
            const entry = self.entries.getEntry(cn) orelse {
                const key = try allocator.dupe(u8, cn);
                try self.entries.put(key, .{ .started_at = now, .count = 1 });
                return true;
            };
            if (now - entry.value_ptr.started_at >= window_ms) {
                entry.value_ptr.* = .{ .started_at = now, .count = 1 };
                return true;
            }
            if (entry.value_ptr.count >= limit) return false;
            entry.value_ptr.count += 1;
            return true;
        }

        pub fn deinit(self: *TaskLimits, allocator: std.mem.Allocator) void {
            self.mutex.lockUncancelable(compat.io());
            defer self.mutex.unlock(compat.io());
            var it = self.entries.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            self.entries.deinit();
        }
    };

    pub const StreamClients = struct {
        mutex: std.Io.Mutex = .init,
        counts: std.StringHashMap(usize),

        pub fn acquire(self: *StreamClients, allocator: std.mem.Allocator, cn: []const u8, limit: usize) !bool {
            self.mutex.lockUncancelable(compat.io());
            defer self.mutex.unlock(compat.io());
            const entry = self.counts.getEntry(cn) orelse {
                const key = allocator.dupe(u8, cn) catch return error.OutOfMemory;
                self.counts.put(key, 1) catch return error.OutOfMemory;
                return true;
            };
            if (entry.value_ptr.* >= limit) return false;
            entry.value_ptr.* += 1;
            return true;
        }

        pub fn release(self: *StreamClients, allocator: std.mem.Allocator, cn: []const u8) void {
            self.mutex.lockUncancelable(compat.io());
            defer self.mutex.unlock(compat.io());
            const entry = self.counts.getEntry(cn) orelse return;
            if (entry.value_ptr.* <= 1) {
                // `remove` may swap entries, so the key slice must be copied
                // before the map is mutated.
                const key = entry.key_ptr.*;
                _ = self.counts.remove(cn);
                allocator.free(key);
            } else {
                entry.value_ptr.* -= 1;
            }
        }

        pub fn deinit(self: *StreamClients, allocator: std.mem.Allocator) void {
            self.mutex.lockUncancelable(compat.io());
            defer self.mutex.unlock(compat.io());
            var it = self.counts.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            self.counts.deinit();
        }
    };

    pub fn saveUpdateConfig(self: *App, allocator: std.mem.Allocator, candidate: config.Config) !void {
        const channel = try self.allocator.dupe(u8, candidate.update_channel);
        errdefer self.allocator.free(channel);
        const mirror = try self.allocator.dupe(u8, candidate.github_mirror);
        errdefer self.allocator.free(mirror);
        var saved = candidate;
        saved.update_channel = channel;
        saved.github_mirror = mirror;
        try saved.save(allocator, self.config_path);
        self.deinitUpdateConfig();
        self.owned_update_channel = channel;
        self.owned_github_mirror = mirror;
        self.config.update_channel = channel;
        self.config.github_mirror = mirror;
    }

    pub fn deinitUpdateConfig(self: *App) void {
        if (self.owned_update_channel) |value| self.allocator.free(value);
        if (self.owned_github_mirror) |value| self.allocator.free(value);
    }
};

test "update config owns request strings and replaces saved values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var app: App = undefined;
    app.allocator = std.testing.allocator;
    app.config = .{};
    app.config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{dir});
    app.owned_update_channel = null;
    app.owned_github_mirror = null;
    defer app.deinitUpdateConfig();
    {
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_arena.deinit();
        var candidate = app.config;
        candidate.update_channel = try request_arena.allocator().dupe(u8, "nightly");
        candidate.github_mirror = try request_arena.allocator().dupe(u8, "https://example.com");
        try app.saveUpdateConfig(a, candidate);
    }
    try std.testing.expectEqualStrings("nightly", app.config.update_channel);
    try std.testing.expectEqualStrings("https://example.com", app.config.github_mirror);
    var candidate = app.config;
    candidate.update_channel = "stable";
    try app.saveUpdateConfig(a, candidate);
    const saved = try config.Config.load(a, app.config_path);
    try std.testing.expectEqualStrings("stable", saved.update_channel);
    try std.testing.expectEqualStrings("https://example.com", saved.github_mirror);
}

test "task submission windows reset and are per client" {
    var limits: App.TaskLimits = .{ .entries = std.StringHashMap(App.Window).init(std.testing.allocator) };
    defer limits.deinit(std.testing.allocator);
    const now = 1_000_000;

    try std.testing.expect(try limits.allow(std.testing.allocator, "cn-a", 2, 60_000, now));
    try std.testing.expect(try limits.allow(std.testing.allocator, "cn-a", 2, 60_000, now + 10));
    try std.testing.expect(!(try limits.allow(std.testing.allocator, "cn-a", 2, 60_000, now + 20)));
    try std.testing.expect(try limits.allow(std.testing.allocator, "cn-b", 2, 60_000, now + 20));
    try std.testing.expect(try limits.allow(std.testing.allocator, "cn-a", 2, 60_000, now + 60_000));
}

test "stream accounting enforces a per client cap" {
    var clients: App.StreamClients = .{ .counts = std.StringHashMap(usize).init(std.testing.allocator) };
    defer clients.deinit(std.testing.allocator);

    try std.testing.expect(try clients.acquire(std.testing.allocator, "cn-a", 2));
    try std.testing.expect(try clients.acquire(std.testing.allocator, "cn-a", 2));
    try std.testing.expect(!(try clients.acquire(std.testing.allocator, "cn-a", 2)));
    try std.testing.expect(try clients.acquire(std.testing.allocator, "cn-b", 2));
    clients.release(std.testing.allocator, "cn-a");
    try std.testing.expect(try clients.acquire(std.testing.allocator, "cn-a", 2));
}
