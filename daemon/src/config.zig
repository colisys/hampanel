const std = @import("std");
const compat = @import("compat");
const builtin = @import("builtin");

pub const default_dir = if (builtin.os.tag == .windows) "C:\\ProgramData\\hampanel" else "/etc/hampanel";
pub const default_path = if (builtin.os.tag == .windows) "C:\\ProgramData\\hampanel\\config.json" else "/etc/hampanel/config.json";
pub const default_tls_dir = if (builtin.os.tag == .windows) "C:\\ProgramData\\hampanel\\tls" else "/etc/hampanel/tls";
pub const default_data_dir = if (builtin.os.tag == .windows) "C:\\ProgramData\\hampanel\\data" else "/var/lib/hampanel";
pub const default_enroll_file = if (builtin.os.tag == .windows) "C:\\ProgramData\\hampanel\\enroll.json" else "/etc/hampanel/enroll.json";

pub const Config = struct {
    listen: []const u8 = "0.0.0.0",
    port: u16 = 8443,
    data_dir: []const u8 = default_data_dir,
    tls_dir: []const u8 = default_tls_dir,
    enroll_file: []const u8 = default_enroll_file,
    log_level: []const u8 = "info",
    client_cn_prefix: []const u8 = "hampanel-client",
    entry_prefix: []const u8 = "",
    audit_limit: usize = 500,
    max_body_bytes: usize = 256 * 1024 * 1024,
    max_connections: usize = 256,
    install_mode: []const u8 = "source",
    update_channel: []const u8 = "stable",
    update_repo: []const u8 = "colisys/hampanel",
    github_mirror: []const u8 = "",
    update_auto: bool = false,
    service_name: []const u8 = "hampanel",

    pub fn updatesEnabled(self: Config) bool {
        return std.mem.eql(u8, self.install_mode, "binary");
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = compat.cwd().openFile(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return Config{},
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1024 * 1024);
        return std.json.parseFromSliceLeaky(Config, allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn save(self: Config, allocator: std.mem.Allocator, path: []const u8) !void {
        if (compat.path.dirname(path)) |dir| {
            try compat.cwd().makePath(dir);
        }
        const body = try std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
        defer allocator.free(body);
        var file = try compat.cwd().createFile(path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(body);
        try file.writeAll("\n");
    }
};
