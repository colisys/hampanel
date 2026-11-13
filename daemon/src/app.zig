const std = @import("std");
const config = @import("config.zig");
const tls = @import("tls.zig");
const pki = @import("pki.zig");
const audit = @import("audit.zig");
const platform = @import("platform/mod.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    config_path: []const u8 = config.default_path,
    started_at: i64,
    tls: tls.Context,
    pki: pki.Paths,
    audit: audit.Log,
    metrics: platform.MetricsState = .{},
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};
