const std = @import("std");
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
