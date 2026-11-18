const std = @import("std");
const compat = @import("compat");
const validate = @import("shared").validate;

pub const Tls = struct {
    enabled: bool = false,
    certificate: []const u8 = "",
    key: []const u8 = "",
    acme_email: []const u8 = "",
    redirect_http: bool = true,
    hsts: bool = false,
};

pub const RateLimit = struct {
    enabled: bool = false,
    rps: u32 = 10,
    burst: u32 = 20,
    connections: u32 = 0,
};

pub const BasicUser = struct {
    username: []const u8 = "",
    password_hash: []const u8 = "",
};

pub const BasicAuth = struct {
    enabled: bool = false,
    users: []const BasicUser = &.{},
};

pub const Cors = struct {
    enabled: bool = false,
    origins: []const []const u8 = &.{},
    methods: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},
    credentials: bool = false,
};

pub const Hotlink = struct {
    enabled: bool = false,
    allow_empty_referer: bool = true,
    extensions: []const []const u8 = &.{},
};

pub const Redirect = struct {
    from: []const u8 = "",
    to: []const u8 = "",
    code: u16 = 301,
};

pub const Rewrite = struct {
    pattern: []const u8 = "",
    replacement: []const u8 = "",
    flag: []const u8 = "last",
};

pub const Upstream = struct {
    address: []const u8 = "",
    weight: u32 = 1,
};

pub const Header = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const Proxy = struct {
    upstreams: []const Upstream = &.{},
    load_balance: []const u8 = "round_robin",
    websocket: bool = true,
    preserve_host: bool = true,
    headers: []const Header = &.{},
};

pub const RealIp = struct {
    enabled: bool = false,
    header: []const u8 = "X-Forwarded-For",
    trusted: []const []const u8 = &.{},
};

pub const Custom = struct {
    enabled: bool = false,
    content: []const u8 = "",
};

pub const Site = struct {
    name: []const u8 = "",
    kind: []const u8 = "static",
    enabled: bool = true,
    domains: []const []const u8 = &.{},
    listen: u16 = 80,
    ipv6: bool = true,
    root: []const u8 = "",
    run_dir: []const u8 = "",
    index: []const []const u8 = &.{},
    access_log: []const u8 = "",
    error_log: []const u8 = "",
    client_max_body_size: []const u8 = "",
    runtime_id: []const u8 = "",
    tls: Tls = .{},
    rate_limit: RateLimit = .{},
    basic_auth: BasicAuth = .{},
    cors: Cors = .{},
    hotlink: Hotlink = .{},
    redirects: []const Redirect = &.{},
    rewrites: []const Rewrite = &.{},
    proxy: Proxy = .{},
    real_ip: RealIp = .{},
    custom: Custom = .{},
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

pub fn sitesRoot(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "sites" });
}

pub fn siteDir(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) ![]const u8 {
    return compat.path.join(allocator, &.{ data_dir, "sites", name });
}

pub fn sitePath(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) ![]const u8 {
    const dir = try siteDir(allocator, data_dir, name);
    return compat.path.join(allocator, &.{ dir, "site.json" });
}

pub fn load(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) !Site {
    if (!validate.isSlug(name)) return error.InvalidSite;
    const path = try sitePath(allocator, data_dir, name);
    const raw = compat.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SiteNotFound,
        else => return err,
    };
    const site = std.json.parseFromSliceLeaky(Site, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidSite;
    if (site.name.len == 0) return error.InvalidSite;
    return site;
}

pub fn list(allocator: std.mem.Allocator, data_dir: []const u8) ![]const Site {
    const root = sitesRoot(allocator, data_dir) catch return &.{};
    var dir = compat.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();

    var sites = std.array_list.Managed(Site).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |item| {
        if (item.kind != .directory) continue;
        if (!validate.isSlug(item.name)) continue;
        const site = load(allocator, data_dir, item.name) catch continue;
        try sites.append(site);
    }
    std.sort.pdq(Site, sites.items, {}, struct {
        fn lessThan(_: void, left: Site, right: Site) bool {
            return std.ascii.lessThanIgnoreCase(left.name, right.name);
        }
    }.lessThan);
    return sites.items;
}

pub fn save(allocator: std.mem.Allocator, data_dir: []const u8, site_in: Site) !Site {
    if (!validate.isSlug(site_in.name)) return error.InvalidSite;
    var site = site_in;
    const now = compat.timestamp();
    if (site.created_at == 0) site.created_at = now;
    site.updated_at = now;

    const dir = try siteDir(allocator, data_dir, site.name);
    try compat.cwd().makePath(dir);
    const path = try sitePath(allocator, data_dir, site.name);
    const raw = try std.json.Stringify.valueAlloc(allocator, site, .{});
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(raw);
    return site;
}

pub fn delete(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) !void {
    if (!validate.isSlug(name)) return error.InvalidSite;
    const dir = try siteDir(allocator, data_dir, name);
    const path = try sitePath(allocator, data_dir, name);
    compat.deleteFileAbsolute(path) catch {};
    const cert = try compat.path.join(allocator, &.{ dir, "cert.pem" });
    const key = try compat.path.join(allocator, &.{ dir, "key.pem" });
    const htpasswd = try compat.path.join(allocator, &.{ dir, "htpasswd" });
    compat.deleteFileAbsolute(cert) catch {};
    compat.deleteFileAbsolute(key) catch {};
    compat.deleteFileAbsolute(htpasswd) catch {};
    compat.cwd().deleteTree(dir) catch {};
}
