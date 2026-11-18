const std = @import("std");
const compat = @import("compat");

test {
    _ = @import("config.zig");
    _ = @import("compat");
    _ = @import("db.zig");
    _ = @import("migrations.zig");
    _ = @import("notify.zig");
    _ = @import("runtime/images.zig");
    _ = @import("runtime/environments.zig");
    _ = @import("runtime/docker_settings.zig");
    _ = @import("runtime/engine.zig");
    _ = @import("runtime/site_store.zig");
    _ = @import("runtime/site_nginx.zig");
    _ = @import("api/sites.zig");
    _ = @import("jobs.zig");
    _ = @import("api/runtimes.zig");
    _ = @import("log.zig");
    _ = @import("openssl.zig");
    _ = @import("tls.zig");
    _ = @import("pki.zig");
    _ = @import("enroll.zig");
    _ = @import("update.zig");
    _ = @import("versions.zig");
    _ = @import("util/redact.zig");
    _ = @import("util/time.zig");
    _ = @import("util/url.zig");
    _ = @import("shared").validate;
    _ = @import("api/mod.zig");
    _ = @import("store/catalog.zig");
    _ = @import("store/apps.zig");
}

test "config defaults survive empty file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = "{}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cfg = try @import("config.zig").Config.load(arena.allocator(), path);
    try std.testing.expectEqual(@as(u16, 8443), cfg.port);
    try std.testing.expectEqualStrings("hampanel-client", cfg.client_cn_prefix);
}

test "pki issues a verifiable chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = try @import("pki.zig").initialize(a, dir, "127.0.0.1:8443", &.{ "panel.example.com", "10.0.0.5" }, false);
    try std.testing.expectEqual(@as(usize, 64), meta.ca_fingerprint.len);
    try std.testing.expectEqual(@as(usize, 64), meta.server_fingerprint.len);

    const p = try @import("pki.zig").paths(a, dir);
    const bundle = try @import("enroll.zig").build(a, meta, p, null, "/test-prefix");
    try std.testing.expect(std.mem.indexOf(u8, bundle.client_key_pem, "PRIVATE KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.ca_pem, "CERTIFICATE") != null);
    try std.testing.expectEqualStrings("/test-prefix", bundle.entry_prefix);

    const again = try @import("pki.zig").initialize(a, dir, "ignored:1", &.{}, false);
    try std.testing.expectEqualStrings(meta.client_cn, again.client_cn);
}

test "url decoding and query lookup" {
    const allocator = std.testing.allocator;
    const decoded = try @import("util/url.zig").decode(allocator, "a%20b%2Fc+d");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a b/c d", decoded);

    const value = (try @import("util/url.zig").value(allocator, "x=1&path=%2Fetc%2Fnginx", "path")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("/etc/nginx", value);
}

test "validation helpers" {
    const validate = @import("shared").validate;
    try std.testing.expect(validate.isSlug("site_1.example"));
    try std.testing.expect(!validate.isSlug("../etc"));
    try std.testing.expect(validate.isUnitName("nginx.service"));
    try std.testing.expect(validate.isContainerId("a1b2c3"));
    try std.testing.expect(validate.isPortSpec("8080/tcp"));
    try std.testing.expect(!validate.isPortSpec("8080/sctp"));
    try std.testing.expect(validate.isIpOrCidr("10.0.0.0/8"));
    try std.testing.expect(!validate.isIpOrCidr("10.0.0.0/64"));
    try std.testing.expect(validate.isHostname("panel.example.com"));
    try std.testing.expect(validate.isPackageName("nodejs"));
    try std.testing.expect(validate.isPackageName("python3.12-dev"));
    try std.testing.expect(validate.isPackageName("pkg=1:2.0+git"));
    try std.testing.expect(!validate.isPackageName("rm -rf /"));
    try std.testing.expect(!validate.isPackageName("a/b"));
    try std.testing.expect(validate.isEntryPrefix("/a1b2c3d4"));
    try std.testing.expect(validate.isEntryPrefix(""));
    try std.testing.expect(!validate.isEntryPrefix("a1b2"));
    try std.testing.expect(!validate.isEntryPrefix("/a/b"));
    try std.testing.expect(!validate.isEntryPrefix("/../etc"));
}

test "container engine JSON list parser" {
    const engine_mod = @import("runtime/engine.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const podman = try engine_mod.parseJsonObjects(
        allocator,
        "[{\"State\":\"running\"},{\"State\":\"exited\"}]",
    );
    try std.testing.expectEqual(@as(usize, 2), podman.len);
    try std.testing.expectEqualStrings("running", podman[0].object.get("State").?.string);

    const docker = try engine_mod.parseJsonObjects(
        allocator,
        "{\"State\":\"running\"}\n{\"State\":\"paused\"}\n",
    );
    try std.testing.expectEqual(@as(usize, 2), docker.len);
    try std.testing.expectEqualStrings("paused", docker[1].object.get("State").?.string);
}

test "site store and nginx renderer round trip" {
    const site_store = @import("runtime/site_store.zig");
    const site_nginx = @import("runtime/site_nginx.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/hampanel-site-test-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer compat.cwd().deleteTree(data_dir) catch {};
    try compat.cwd().makePath(data_dir);

    const static_site = site_store.Site{
        .name = "demo",
        .kind = "static",
        .domains = &.{"example.com"},
        .root = "/var/www/demo",
        .listen = 8080,
        .tls = .{ .enabled = true, .certificate = "/tmp/demo/cert.pem", .key = "/tmp/demo/key.pem" },
        .rate_limit = .{ .enabled = true, .rps = 20, .burst = 40, .connections = 5 },
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"} },
        .hotlink = .{ .enabled = true, .extensions = &.{ "png", "jpg" } },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
    };
    _ = try site_store.save(allocator, data_dir, static_site);
    const loaded = try site_store.load(allocator, data_dir, "demo");
    try std.testing.expectEqualStrings("example.com", loaded.domains[0]);
    try std.testing.expectEqual(@as(u16, 8080), loaded.listen);
    const all = try site_store.list(allocator, data_dir);
    try std.testing.expectEqual(@as(usize, 1), all.len);

    const rendered = try site_nginx.render(allocator, loaded, "/tmp/demo");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "server_name example.com;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "listen 443 ssl http2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "limit_req_zone") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "location ~* \\.(png|jpg)$") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "location = /old") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Access-Control-Allow-Origin") != null);

    const plain_site = site_store.Site{ .name = "plain", .kind = "static", .domains = &.{"plain.local"}, .root = "/tmp/plain" };
    try std.testing.expect(!plain_site.tls.enabled);
    _ = try site_nginx.render(allocator, plain_site, "/tmp/plain");

    const proxy_site = site_store.Site{
        .name = "proxy",
        .kind = "reverse_proxy",
        .domains = &.{"api.example.com"},
        .listen = 8081,
        .proxy = .{
            .upstreams = &.{ .{ .address = "127.0.0.1:3000" }, .{ .address = "127.0.0.1:3001", .weight = 2 } },
            .load_balance = "least_conn",
            .websocket = true,
            .preserve_host = true,
        },
    };
    _ = try site_store.save(allocator, data_dir, proxy_site);
    const proxy_loaded = try site_store.load(allocator, data_dir, "proxy");
    const proxy_rendered = try site_nginx.render(allocator, proxy_loaded, "/tmp/proxy");
    try std.testing.expect(std.mem.indexOf(u8, proxy_rendered, "upstream hampanel_proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, proxy_rendered, "least_conn;") != null);
    try std.testing.expect(std.mem.indexOf(u8, proxy_rendered, "proxy_pass http://hampanel_proxy;") != null);
    try std.testing.expect(std.mem.indexOf(u8, proxy_rendered, "map $http_upgrade $hampanel_upgrade_proxy") != null);
}

