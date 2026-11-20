const std = @import("std");
const nginx = @import("site_nginx.zig");
const engine = @import("engine.zig");
const Db = @import("../db.zig").Db;

fn storeNginxInstalled(a: std.mem.Allocator, data_dir: []const u8) bool {
    return @import("../store/apps.zig").installed(a, data_dir, @import("../store/catalog.zig").find("nginx").?);
}

pub fn nginxTarget(a: std.mem.Allocator, data_dir: []const u8, db: *Db) !?nginx.Container {
    if (nginx.available(a) or !storeNginxInstalled(a, data_dir)) return null;
    return try nginx.resolveContainer(a, data_dir, engine.socketFromDb(a, db));
}

pub fn webServer(a: std.mem.Allocator, data_dir: []const u8, configured: []const u8) []const u8 {
    if (configured.len > 0) return configured;
    if (nginx.available(a) or storeNginxInstalled(a, data_dir)) return "nginx";
    if (@import("shared").exec.commandExists(a, "caddy")) return "caddy";
    return "";
}
