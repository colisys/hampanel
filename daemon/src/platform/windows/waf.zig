const std = @import("std");

pub const GeoRule = struct {
    tag: []const u8,
    action: []const u8 = "deny",
};

pub const Route = struct {
    name: []const u8,
    hosts: []const []const u8,
    upstream_host: []const u8,
    upstream_port: u16,
    mode: []const u8 = "inherit",
};

pub const Config = struct {
    mode: []const u8 = "off",
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8088,
    upstream_host: []const u8 = "127.0.0.1",
    upstream_port: u16 = 80,
    risk_enabled: bool = false,
    risk_port: u16 = 18092,
    typesafe_enabled: bool = false,
    typesafe_endpoint: []const u8 = "",
    typesafe_model: []const u8 = "",
    typesafe_threshold: f64 = 0.85,
    typesafe_timeout_ms: u16 = 800,
    typesafe_fail_open: bool = true,
    geoip_rules: []const GeoRule = &.{},
    geosite_rules: []const GeoRule = &.{},
    routes: []const Route = &.{},
    tls_enabled: bool = false,
    tls_mode: []const u8 = "internal",
    tls_email: []const u8 = "",
};

pub const Status = struct {
    installed: bool = false,
    running: bool = false,
    version: []const u8 = "",
    mode: []const u8 = "off",
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 0,
    upstream_host: []const u8 = "",
    upstream_port: u16 = 0,
    binary: []const u8 = "",
    config_path: []const u8 = "",
    log_path: []const u8 = "",
    go_available: bool = false,
    crs: []const u8 = "",
    message: []const u8 = "WAF 边缘仅支持 Linux 远端",
    risk_enabled: bool = false,
    risk_running: bool = false,
    risk_port: u16 = 0,
    risk_binary: []const u8 = "",
    risk_log_path: []const u8 = "",
    typesafe_enabled: bool = false,
    typesafe_endpoint: []const u8 = "",
    typesafe_model: []const u8 = "",
    typesafe_threshold: f64 = 0.85,
    typesafe_timeout_ms: u16 = 800,
    typesafe_fail_open: bool = true,
    typesafe_key_configured: bool = false,
    geoip_rules: []const GeoRule = &.{},
    geosite_rules: []const GeoRule = &.{},
};

pub const Outcome = struct { ok: bool, output: []const u8 };
pub const Logs = struct { path: []const u8, content: []const u8, truncated: bool };
pub const Country = struct { code: []const u8, name: []const u8 };
pub const GeoSiteService = struct { id: []const u8, name: []const u8, category: []const u8, src: []const u8 };
pub const GeoCatalog = struct { countries: []Country, geosite: []GeoSiteService, updated_at: []const u8 };

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    _ = allocator;
    _ = data_dir;
    return .{};
}
pub fn install(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}
pub fn configure(allocator: std.mem.Allocator, data_dir: []const u8, config: Config) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = config;
    return error.Unsupported;
}
pub fn start(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}
pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}
pub fn logs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    _ = allocator;
    _ = data_dir;
    _ = lines;
    return error.Unsupported;
}
pub fn auditLogs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    _ = allocator;
    _ = data_dir;
    _ = lines;
    return error.Unsupported;
}
pub fn riskLogs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    _ = allocator;
    _ = data_dir;
    _ = lines;
    return error.Unsupported;
}
pub fn setTypesafeKey(allocator: std.mem.Allocator, data_dir: []const u8, key: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = key;
    return error.Unsupported;
}
pub fn clearTypesafeKey(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    _ = allocator;
    _ = data_dir;
    return error.Unsupported;
}
pub fn geoCatalog(allocator: std.mem.Allocator, data_dir: []const u8, refresh: bool) !GeoCatalog {
    _ = allocator;
    _ = data_dir;
    _ = refresh;
    return error.Unsupported;
}
pub fn downloadGeoRules(allocator: std.mem.Allocator, data_dir: []const u8, geoip: []const GeoRule, geosite: []const GeoRule) !Outcome {
    _ = allocator;
    _ = data_dir;
    _ = geoip;
    _ = geosite;
    return error.Unsupported;
}
