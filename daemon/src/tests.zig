const std = @import("std");
const compat = @import("compat");

test {
    _ = @import("config.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows) _ = @import("app.zig");
    _ = @import("api/docker_images.zig");
    _ = @import("api/docker_addresses.zig");
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
    _ = @import("tasks.zig");
    _ = @import("task_handlers.zig");
    _ = @import("api/tasks.zig");
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
        .ipv6 = true,
        .access_log = "/var/log/nginx/demo.access.log",
        .error_log = "/var/log/nginx/demo.error.log",
        .client_max_body_size = "16m",
        .tls = .{ .enabled = true, .certificate = "/tmp/demo/cert.pem", .key = "/tmp/demo/key.pem", .hsts = true },
        .rate_limit = .{ .enabled = true, .rps = 20, .burst = 40, .connections = 5 },
        .basic_auth = .{ .enabled = true, .users = &.{.{ .username = "admin", .password_hash = "$apr1$hash" }} },
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"}, .credentials = true },
        .hotlink = .{ .enabled = true, .allow_empty_referer = false, .extensions = &.{ "png", "jpg" } },
        .real_ip = .{ .enabled = true, .header = "X-Real-IP", .trusted = &.{"10.0.0.0/8"} },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
        .rewrites = &.{.{ .pattern = "^/legacy/(.*)$", .replacement = "/$1", .flag = "last" }},
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "rewrite ^/legacy/(.*)$ /$1 last;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Access-Control-Allow-Origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "listen [::]:443 ssl http2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "return 301 https://$host$request_uri;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Strict-Transport-Security") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "access_log /var/log/nginx/demo.access.log;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error_log /var/log/nginx/demo.error.log;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "client_max_body_size 16m;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "limit_req zone=hampanel_req_demo burst=40 nodelay;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "limit_conn hampanel_conn_demo 5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "set_real_ip_from 10.0.0.0/8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "real_ip_header X-Real-IP;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "auth_basic \"Restricted\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "auth_basic_user_file /tmp/demo/htpasswd;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "valid_referers server_names;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Access-Control-Allow-Credentials \"true\" always;") != null);

    const custom_site = site_store.Site{
        .name = "custom",
        .kind = "static",
        .domains = &.{"custom.example.com"},
        .custom = .{ .enabled = true, .content = "server { listen 8082; server_name custom.example.com; }\n" },
    };
    const custom_out = try site_nginx.render(allocator, custom_site, "/tmp/custom");
    try std.testing.expectEqualStrings(custom_site.custom.content, custom_out);

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

    try site_store.delete(allocator, data_dir, "proxy");
    const after_delete = try site_store.list(allocator, data_dir);
    try std.testing.expectEqual(@as(usize, 1), after_delete.len);
    try site_store.delete(allocator, data_dir, "demo");
    const empty = try site_store.list(allocator, data_dir);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}


test "site caddy and stream renderers" {
    const site_store = @import("runtime/site_store.zig");
    const site_nginx = @import("runtime/site_nginx.zig");
    const site_caddy = @import("runtime/site_caddy.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const caddy_site = site_store.Site{
        .name = "caddy",
        .kind = "reverse_proxy",
        .domains = &.{"caddy.example.com"},
        .listen = 8443,
        .tls = .{ .enabled = true, .certificate = "/tmp/cert.pem", .key = "/tmp/key.pem", .hsts = true },
        .access_log = "/var/log/caddy/caddy.log",
        .client_max_body_size = "16m",
        .basic_auth = .{ .enabled = true, .users = &.{.{ .username = "admin", .password_hash = "$2a$14$hash" }} },
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"}, .methods = &.{"GET"} },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
        .rewrites = &.{.{ .pattern = "^/legacy/(.*)$", .replacement = "/$1", .flag = "last" }},
        .proxy = .{ .upstreams = &.{.{ .address = "127.0.0.1:3000" }}, .load_balance = "least_conn" },
    };
    const caddy_out = try site_caddy.render(allocator, caddy_site, "/tmp/caddy");
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "https://caddy.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "tls /tmp/cert.pem /tmp/key.pem") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "reverse_proxy 127.0.0.1:3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "lb_policy least_conn") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "basicauth") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "redir /old /new 301") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "@rewrite_0 path_regexp ^/legacy/(.*)$") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "rewrite @rewrite_0 /{re.rewrite_0.1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "Access-Control-Allow-Origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "log {") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "output file /var/log/caddy/caddy.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "request_body {") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "max_size 16m") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy_out, "Strict-Transport-Security") != null);

    var caddy_bad = caddy_site;
    caddy_bad.rate_limit.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, site_caddy.render(allocator, caddy_bad, "/tmp/caddy"));
    var caddy_hotlink = caddy_site;
    caddy_hotlink.hotlink.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, site_caddy.render(allocator, caddy_hotlink, "/tmp/caddy"));
    var caddy_realip = caddy_site;
    caddy_realip.real_ip.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, site_caddy.render(allocator, caddy_realip, "/tmp/caddy"));
    var caddy_errlog = caddy_site;
    caddy_errlog.error_log = "/var/log/caddy/error.log";
    try std.testing.expectError(error.UnsupportedFeature, site_caddy.render(allocator, caddy_errlog, "/tmp/caddy"));

    const caddy_custom = site_store.Site{
        .name = "caddy-custom",
        .kind = "static",
        .domains = &.{"custom.example.com"},
        .custom = .{ .enabled = true, .content = "http://custom.example.com { respond \"ok\" }\n" },
    };
    try std.testing.expectEqualStrings(caddy_custom.custom.content, try site_caddy.render(allocator, caddy_custom, "/tmp/caddy-custom"));

    const tcp_site = site_store.Site{
        .name = "tcp",
        .kind = "tcp_proxy",
        .listen = 9001,
        .proxy = .{ .upstreams = &.{.{ .address = "127.0.0.1:9000" }} },
    };
    const tcp_out = try site_nginx.render(allocator, tcp_site, "/tmp/tcp");
    try std.testing.expect(std.mem.indexOf(u8, tcp_out, "listen 9001;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tcp_out, "proxy_pass 127.0.0.1:9000;") != null);

    const udp_site = site_store.Site{
        .name = "udp",
        .kind = "udp_proxy",
        .listen = 9003,
        .proxy = .{ .upstreams = &.{.{ .address = "127.0.0.1:9002" }} },
    };
    const udp_out = try site_nginx.render(allocator, udp_site, "/tmp/udp");
    try std.testing.expect(std.mem.indexOf(u8, udp_out, "listen 9003 udp;") != null);
}

test "site validation covers all engines and rejects unsafe config" {
    const sites_api = @import("api/sites.zig");
    const store = @import("runtime/site_store.zig");

    const valid = store.Site{
        .name = "valid-site",
        .kind = "static",
        .domains = &.{"example.com"},
        .root = "/var/www/example",
        .listen = 8080,
        .access_log = "/var/log/nginx/example.access.log",
        .error_log = "/var/log/nginx/example.error.log",
        .client_max_body_size = "16m",
        .tls = .{ .enabled = true, .certificate = "/etc/ssl/example.crt", .key = "/etc/ssl/example.key", .hsts = true },
        .rate_limit = .{ .enabled = true, .rps = 20, .burst = 40, .connections = 5 },
        .basic_auth = .{ .enabled = true, .users = &.{.{ .username = "admin", .password_hash = "$apr1$hash" }} },
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"}, .methods = &.{"GET"}, .headers = &.{"Content-Type"}, .credentials = true },
        .hotlink = .{ .enabled = true, .allow_empty_referer = false, .extensions = &.{ "png", "jpg" } },
        .real_ip = .{ .enabled = true, .header = "X-Real-IP", .trusted = &.{"10.0.0.0/8"} },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
        .rewrites = &.{.{ .pattern = "^/legacy/(.*)$", .replacement = "/$1", .flag = "last" }},
    };
    try sites_api.validateForTest(valid, "nginx");

    var caddy_valid = valid;
    caddy_valid.error_log = "";
    caddy_valid.rate_limit.enabled = false;
    caddy_valid.hotlink.enabled = false;
    caddy_valid.real_ip.enabled = false;
    caddy_valid.basic_auth.users = &.{.{ .username = "admin", .password_hash = "$2a$14$hash" }};
    try sites_api.validateForTest(caddy_valid, "caddy");

    var bad = valid;
    bad.name = "Bad Name";
    try std.testing.expectError(error.InvalidName, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.kind = "nope";
    try std.testing.expectError(error.InvalidKind, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.domains = &.{};
    try std.testing.expectError(error.InvalidDomains, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.root = "relative/path";
    try std.testing.expectError(error.InvalidRoot, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.listen = 0;
    try std.testing.expectError(error.InvalidPort, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.tls.key = "";
    try std.testing.expectError(error.MissingCertificate, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.proxy = .{};
    bad.kind = "reverse_proxy";
    try std.testing.expectError(error.MissingUpstream, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.basic_auth.users = &.{.{ .username = "admin", .password_hash = "" }};
    try std.testing.expectError(error.InvalidUser, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.cors.origins = &.{"javascript:alert(1)"};
    try std.testing.expectError(error.InvalidCors, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.rewrites = &.{.{ .pattern = "a;b", .replacement = "/x", .flag = "last" }};
    try std.testing.expectError(error.InvalidRewrite, sites_api.validateForTest(bad, "nginx"));
    bad = valid;
    bad.real_ip.header = "X;Real";
    try std.testing.expectError(error.InvalidRealIp, sites_api.validateForTest(bad, "nginx"));

    const tcp = store.Site{
        .name = "tcp-site",
        .kind = "tcp_proxy",
        .listen = 9001,
        .proxy = .{ .upstreams = &.{.{ .address = "127.0.0.1:9000" }} },
    };
    try sites_api.validateForTest(tcp, "nginx");
    var tcp_bad = tcp;
    tcp_bad.proxy.upstreams = &.{};
    try std.testing.expectError(error.MissingUpstream, sites_api.validateForTest(tcp_bad, "nginx"));
    try std.testing.expectError(error.UnsupportedKind, sites_api.validateForTest(tcp, "caddy"));

    var caddy_rate = caddy_valid;
    caddy_rate.rate_limit.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, sites_api.validateForTest(caddy_rate, "caddy"));
    var caddy_hotlink = caddy_valid;
    caddy_hotlink.hotlink.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, sites_api.validateForTest(caddy_hotlink, "caddy"));
    var caddy_realip = caddy_valid;
    caddy_realip.real_ip.enabled = true;
    try std.testing.expectError(error.UnsupportedFeature, sites_api.validateForTest(caddy_realip, "caddy"));
    var caddy_errlog = caddy_valid;
    caddy_errlog.error_log = "/var/log/caddy/error.log";
    try std.testing.expectError(error.UnsupportedFeature, sites_api.validateForTest(caddy_errlog, "caddy"));
    std.debug.print("site validation matrix passed\n", .{});
}

fn writeTestFile(path: []const u8, data: []const u8) !void {
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(data);
}

test "generated nginx config is accepted by nginx -t" {
    if (compat.getEnv("HAMPANEL_TEST_ENGINE") == null) return error.SkipZigTest;
    const exec = @import("shared").exec;
    const site_store = @import("runtime/site_store.zig");
    const site_nginx = @import("runtime/site_nginx.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nginx_bin = if (exec.commandExists(a, "nginx")) "nginx" else if (exec.commandExists(a, "/usr/sbin/nginx")) "/usr/sbin/nginx" else "";
    const openssl_bin = if (exec.commandExists(a, "openssl")) "openssl" else if (exec.commandExists(a, "/usr/bin/openssl")) "/usr/bin/openssl" else "";
    std.debug.print("nginx engine test: nginx={s} openssl={s}\n", .{ nginx_bin, openssl_bin });
    if (nginx_bin.len == 0 or openssl_bin.len == 0) {
        std.debug.print("skip nginx engine test: nginx or openssl not found (PATH={s})\n", .{compat.getEnv("PATH") orelse ""});
        return error.SkipZigTest;
    }

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const dir = try std.fmt.allocPrint(a, "/tmp/hampanel-nginx-check-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer compat.cwd().deleteTree(dir) catch {};
    try compat.cwd().makePath(dir);

    const cert = try std.fmt.allocPrint(a, "{s}/cert.pem", .{dir});
    const key = try std.fmt.allocPrint(a, "{s}/key.pem", .{dir});
    const ssl = exec.run(a, &.{ openssl_bin, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=example.com", "-keyout", key, "-out", cert, "-days", "1" }, 1024 * 1024) catch {
        std.debug.print("skip nginx engine test: openssl spawn failed\n", .{});
        return error.SkipZigTest;
    };
    if (!ssl.ok()) {
        std.debug.print("skip nginx engine test: openssl failed: {s}\n", .{ssl.stderr});
        return error.SkipZigTest;
    }

    const site_dir = try std.fmt.allocPrint(a, "{s}/site", .{dir});
    try compat.cwd().makePath(site_dir);
    try writeTestFile(try std.fmt.allocPrint(a, "{s}/htpasswd", .{site_dir}), "admin:$apr1$test$hash\n");

    const site = site_store.Site{
        .name = "check",
        .kind = "static",
        .domains = &.{"example.com"},
        .root = "/var/www/example",
        .listen = 8080,
        .ipv6 = true,
        .access_log = try std.fmt.allocPrint(a, "{s}/access.log", .{dir}),
        .error_log = try std.fmt.allocPrint(a, "{s}/error.log", .{dir}),
        .client_max_body_size = "16m",
        .tls = .{ .enabled = true, .certificate = cert, .key = key, .hsts = true },
        .rate_limit = .{ .enabled = true, .rps = 20, .burst = 40, .connections = 5 },
        .basic_auth = .{ .enabled = true, .users = &.{.{ .username = "admin", .password_hash = "$apr1$test$hash" }} },
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"}, .methods = &.{ "GET", "POST" }, .headers = &.{"Content-Type"}, .credentials = true },
        .hotlink = .{ .enabled = true, .allow_empty_referer = false, .extensions = &.{ "png", "jpg" } },
        .real_ip = .{ .enabled = true, .header = "X-Real-IP", .trusted = &.{"10.0.0.0/8"} },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
        .rewrites = &.{.{ .pattern = "^/legacy/(.*)$", .replacement = "/$1", .flag = "last" }},
    };
    const rendered = try site_nginx.render(a, site, site_dir);
    try writeTestFile(try std.fmt.allocPrint(a, "{s}/site.conf", .{dir}), rendered);
    const main = try std.fmt.allocPrint(a, "pid {s}/nginx.pid;\nerror_log {s}/main-error.log;\nevents {{}}\nhttp {{\n    include {s}/site.conf;\n}}\n", .{ dir, dir, dir });
    try writeTestFile(try std.fmt.allocPrint(a, "{s}/nginx.conf", .{dir}), main);
    const result = try exec.run(a, &.{ nginx_bin, "-t", "-c", try std.fmt.allocPrint(a, "{s}/nginx.conf", .{dir}) }, 2 * 1024 * 1024);
    if (!result.ok()) {
        std.debug.print("nginx -t output:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
    }
    try std.testing.expect(result.ok());
    std.debug.print("nginx -t accepted generated site config\n", .{});
}

test "generated caddy config is accepted by caddy validate" {
    if (compat.getEnv("HAMPANEL_TEST_ENGINE") == null) return error.SkipZigTest;
    const exec = @import("shared").exec;
    const site_store = @import("runtime/site_store.zig");
    const site_caddy = @import("runtime/site_caddy.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caddy_bin = if (exec.commandExists(a, "caddy")) "caddy" else if (exec.commandExists(a, "/usr/bin/caddy")) "/usr/bin/caddy" else if (exec.commandExists(a, "/usr/local/bin/caddy")) "/usr/local/bin/caddy" else "";
    std.debug.print("caddy engine test: caddy={s}\n", .{caddy_bin});
    if (caddy_bin.len == 0) {
        std.debug.print("skip caddy engine test: caddy not found (PATH={s})\n", .{compat.getEnv("PATH") orelse ""});
        return error.SkipZigTest;
    }

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const dir = try std.fmt.allocPrint(a, "/tmp/hampanel-caddy-check-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer compat.cwd().deleteTree(dir) catch {};
    try compat.cwd().makePath(dir);

    const site = site_store.Site{
        .name = "check-caddy",
        .kind = "reverse_proxy",
        .domains = &.{"caddy.example.com"},
        .listen = 8099,
        .access_log = try std.fmt.allocPrint(a, "{s}/access.log", .{dir}),
        .client_max_body_size = "16m",
        .cors = .{ .enabled = true, .origins = &.{"https://app.example.com"}, .methods = &.{"GET"}, .headers = &.{"Content-Type"} },
        .redirects = &.{.{ .from = "/old", .to = "/new", .code = 301 }},
        .rewrites = &.{.{ .pattern = "^/legacy/(.*)$", .replacement = "/$1", .flag = "last" }},
        .proxy = .{ .upstreams = &.{.{ .address = "127.0.0.1:3000" }}, .load_balance = "least_conn" },
    };
    const rendered = try site_caddy.render(a, site, dir);
    const path = try std.fmt.allocPrint(a, "{s}/Caddyfile", .{dir});
    try writeTestFile(path, rendered);
    const result = try exec.run(a, &.{ caddy_bin, "validate", "--config", path, "--adapter", "caddyfile" }, 2 * 1024 * 1024);
    if (!result.ok()) {
        std.debug.print("caddy validate output:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
    }
    try std.testing.expect(result.ok());
    std.debug.print("caddy validate accepted generated site config\n", .{});
}
