const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const exec = @import("shared").exec;
const validate = @import("shared").validate;
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");
const store = @import("../runtime/site_store.zig");
const nginx = @import("../runtime/site_nginx.zig");
const caddy = @import("../runtime/site_caddy.zig");
const environments = @import("../runtime/environments.zig");

const webserver_nginx = "nginx";
const webserver_caddy = "caddy";

const Outcome = struct { ok: bool, output: []const u8 };

pub fn index(ctx: *context.Context) anyerror!void {
    const server = webServer(ctx);
    const sites = store.list(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (std.mem.eql(u8, server, webserver_caddy)) {
        try ctx.json(.{
            .available = caddy.available(ctx.arena),
            .supported = true,
            .webserver = server,
            .dir = caddy.conf_dir,
            .sites = sites,
        });
        return;
    }
    try ctx.json(.{
        .available = nginx.available(ctx.arena),
        .supported = true,
        .webserver = server,
        .dir = "/etc/nginx/conf.d",
        .sites = sites,
    });
}

pub fn show(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    const site = loadSite(ctx, name) orelse return;
    const site_dir = store.siteDir(ctx.arena, ctx.app.config.data_dir, name) catch "";
    var config: []const u8 = "";
    var config_error: []const u8 = "";
    if (std.mem.eql(u8, webServer(ctx), webserver_nginx)) {
        config = nginx.render(ctx.arena, site, site_dir) catch |err| blk: {
            config_error = @errorName(err);
            break :blk "";
        };
    } else if (std.mem.eql(u8, webServer(ctx), webserver_caddy)) {
        config = caddy.render(ctx.arena, site, site_dir) catch |err| blk: {
            config_error = @errorName(err);
            break :blk "";
        };
    }
    try ctx.json(.{
        .site = site,
        .config = config,
        .config_error = config_error,
        .webserver = webServer(ctx),
    });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        kind: []const u8 = "static",
        domains: []const []const u8 = &.{},
        root: []const u8 = "",
        listen: u16 = 0,
        port: u16 = 0,
        proxy_target: []const u8 = "",
        runtime_id: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name, domains and root");
        return;
    };
    if (!validate.isSlug(body.name)) {
        ctx.fail(400, "bad_name", "site name must be a short slug");
        return;
    }
    if (store.load(ctx.arena, ctx.app.config.data_dir, body.name)) |_| {
        ctx.fail(409, "exists", "site already exists");
        return;
    } else |_| {}

    var site = store.Site{
        .name = body.name,
        .kind = body.kind,
        .domains = body.domains,
        .root = body.root,
        .listen = if (body.listen > 0) body.listen else if (body.port > 0) body.port else 80,
        .runtime_id = body.runtime_id,
    };
    if (body.proxy_target.len > 0) {
        const upstreams = try ctx.arena.alloc(store.Upstream, 1);
        upstreams[0] = .{ .address = body.proxy_target };
        site.proxy.upstreams = upstreams;
    }
    prepareRuntime(ctx, &site) catch |err| {
        failForValidation(ctx, err);
        return;
    };

    validateSite(site) catch |err| {
        failForValidation(ctx, err);
        return;
    };
    validateServerFeatures(ctx, site) catch |err| {
        failForValidation(ctx, err);
        return;
    };

    const saved = store.save(ctx.arena, ctx.app.config.data_dir, site) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    const outcome = applySite(ctx, saved) catch |err| {
        store.delete(ctx.arena, ctx.app.config.data_dir, saved.name) catch {};
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) {
        store.delete(ctx.arena, ctx.app.config.data_dir, saved.name) catch {};
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output, .site = saved });
        return;
    }

    try ctx.json(.{ .ok = true, .output = outcome.output, .site = saved });
}

pub fn update(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return;
    }
    const old = loadSite(ctx, name) orelse return;
    var site = ctx.requireJson(store.Site) catch {
        ctx.fail(400, "bad_request", "expected site configuration");
        return;
    };
    site.name = name;
    site.created_at = old.created_at;
    prepareRuntime(ctx, &site) catch |err| {
        failForValidation(ctx, err);
        return;
    };
    validateSite(site) catch |err| {
        failForValidation(ctx, err);
        return;
    };
    validateServerFeatures(ctx, site) catch |err| {
        failForValidation(ctx, err);
        return;
    };

    const saved = store.save(ctx.arena, ctx.app.config.data_dir, site) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    const outcome = applySite(ctx, saved) catch |err| {
        _ = store.save(ctx.arena, ctx.app.config.data_dir, old) catch {};
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) {
        _ = store.save(ctx.arena, ctx.app.config.data_dir, old) catch {};
        _ = applySite(ctx, old) catch null;
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output, .site = old });
        return;
    }

    var name_buf: [96]u8 = undefined;
    log.info("sites: updated name={s}", .{redact.text(&name_buf, saved.name)});
    try ctx.json(.{ .ok = true, .output = outcome.output, .site = saved });
}

pub fn toggle(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return;
    }
    const Body = struct { enabled: bool };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected enabled boolean");
        return;
    };
    const old = loadSite(ctx, name) orelse return;
    var site = old;
    site.enabled = body.enabled;
    validateSite(site) catch |err| {
        failForValidation(ctx, err);
        return;
    };
    validateServerFeatures(ctx, site) catch |err| {
        failForValidation(ctx, err);
        return;
    };
    const saved = store.save(ctx.arena, ctx.app.config.data_dir, site) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    const outcome = applySite(ctx, saved) catch |err| {
        _ = store.save(ctx.arena, ctx.app.config.data_dir, old) catch {};
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) {
        _ = store.save(ctx.arena, ctx.app.config.data_dir, old) catch {};
        _ = applySite(ctx, old) catch null;
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output, .site = old });
        return;
    }
    try ctx.json(.{ .ok = true, .output = outcome.output, .site = saved });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return;
    }
    const site = loadSite(ctx, name) orelse return;
    const outcome: Outcome = if (std.mem.eql(u8, webServer(ctx), webserver_caddy)) blk: {
        const result = caddy.remove(ctx.arena, site.name) catch |err| {
            ctx.fail(500, "sites_failed", @errorName(err));
            return;
        };
        break :blk .{ .ok = result.ok, .output = result.output };
    } else blk: {
        const result = nginx.remove(ctx.arena, site.name) catch |err| {
            ctx.fail(500, "sites_failed", @errorName(err));
            return;
        };
        break :blk .{ .ok = result.ok, .output = result.output };
    };
    if (!outcome.ok) {
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output });
        return;
    }
    store.delete(ctx.arena, ctx.app.config.data_dir, name) catch {};
    try ctx.json(.{ .ok = true, .removed = true, .output = outcome.output });
}

pub fn reload(ctx: *context.Context) anyerror!void {
    const outcome: Outcome = if (std.mem.eql(u8, webServer(ctx), webserver_caddy)) blk: {
        const result = caddy.reload(ctx.arena) catch |err| {
            ctx.fail(500, "sites_failed", @errorName(err));
            return;
        };
        break :blk .{ .ok = result.ok, .output = result.output };
    } else blk: {
        const result = nginx.reload(ctx.arena) catch |err| {
            ctx.fail(500, "sites_failed", @errorName(err));
            return;
        };
        break :blk .{ .ok = result.ok, .output = result.output };
    };
    try ctx.jsonStatus(if (outcome.ok) 200 else 502, .{ .ok = outcome.ok, .output = outcome.output });
}

pub fn uploadCertificate(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    const old = loadSite(ctx, name) orelse return;
    const kind = (try ctx.query("kind")) orelse "cert";
    if (!std.mem.eql(u8, kind, "cert") and !std.mem.eql(u8, kind, "key")) {
        ctx.fail(400, "bad_kind", "kind must be cert or key");
        return;
    }
    if (ctx.req.body.len == 0 or ctx.req.body.len > 1024 * 1024) {
        ctx.fail(400, "bad_certificate", "certificate body is empty or too large");
        return;
    }
    const dir = store.siteDir(ctx.arena, ctx.app.config.data_dir, name) catch {
        ctx.fail(500, "sites_failed", "unable to resolve site directory");
        return;
    };
    const filename = if (std.mem.eql(u8, kind, "cert")) "cert.pem" else "key.pem";
    const path = compat.path.join(ctx.arena, &.{ dir, filename }) catch {
        ctx.fail(500, "sites_failed", "unable to resolve certificate path");
        return;
    };
    const caddy_server = std.mem.eql(u8, webServer(ctx), webserver_caddy);
    const mode: u32 = if (std.mem.eql(u8, kind, "key"))
        (if (caddy_server) 0o640 else 0o600)
    else
        0o644;
    var file = compat.createFileAbsolute(path, .{ .truncate = true, .mode = mode }) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    defer file.close();
    file.writeAll(ctx.req.body) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (caddy_server and std.mem.eql(u8, kind, "key")) {
        const group = exec.run(ctx.arena, &.{ "chgrp", "caddy", path }, 64 * 1024) catch null;
        if (group == null or !group.?.ok()) {
            // Caddy must be able to read the private key; fall back to world-read
            // only when the host does not expose a caddy group.
            _ = exec.run(ctx.arena, &.{ "chmod", "0644", path }, 64 * 1024) catch {};
        }
    }

    var site = old;
    site.tls.enabled = true;
    if (std.mem.eql(u8, kind, "cert")) site.tls.certificate = path else site.tls.key = path;
    const saved = store.save(ctx.arena, ctx.app.config.data_dir, site) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    if (saved.tls.certificate.len == 0 or saved.tls.key.len == 0) {
        try ctx.json(.{ .ok = true, .output = "已保存，请继续上传证书或私钥后再启用 HTTPS", .site = saved });
        return;
    }
    const outcome = applySite(ctx, saved) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) {
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output, .site = saved });
        return;
    }
    try ctx.json(.{ .ok = true, .output = outcome.output, .site = saved });
}

pub fn updateBasicAuth(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    const old = loadSite(ctx, name) orelse return;
    const User = struct { username: []const u8, password: []const u8 };
    const Body = struct { users: []const User = &.{}, enabled: bool = true };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected users");
        return;
    };
    if (body.users.len > 64) {
        ctx.fail(400, "bad_users", "too many users");
        return;
    }
    const server = webServer(ctx);
    const use_caddy = std.mem.eql(u8, server, webserver_caddy);
    const hash_tool = if (use_caddy) "caddy" else "openssl";
    if (!exec.commandExists(ctx.arena, hash_tool)) {
        ctx.fail(501, "hash_tool_missing", "password hashing tool is not installed");
        return;
    }
    var users = std.array_list.Managed(store.BasicUser).init(ctx.arena);
    for (body.users) |user| {
        if (!validUser(user.username)) {
            ctx.fail(400, "bad_users", "invalid username");
            return;
        }
        if (user.password.len == 0 or user.password.len > 256) {
            ctx.fail(400, "bad_users", "password must be 1-256 bytes");
            return;
        }
        const hash = if (use_caddy)
            exec.runWith(ctx.arena, &.{ "caddy", "hash-password", "--plaintext", user.password }, .{
                .max_output = 64 * 1024,
            }) catch {
                ctx.fail(500, "hash_failed", "unable to hash password");
                return;
            }
        else
            exec.runWith(ctx.arena, &.{ "openssl", "passwd", "-apr1", "-stdin" }, .{
                .stdin = user.password,
                .max_output = 64 * 1024,
            }) catch {
                ctx.fail(500, "hash_failed", "unable to hash password");
                return;
            };
        if (!hash.ok()) {
            ctx.fail(500, "hash_failed", "password hashing failed");
            return;
        }
        try users.append(.{
            .username = user.username,
            .password_hash = std.mem.trim(u8, hash.stdout, " \t\r\n"),
        });
    }
    var site = old;
    site.basic_auth.enabled = body.enabled;
    site.basic_auth.users = users.items;
    const saved = store.save(ctx.arena, ctx.app.config.data_dir, site) catch |err| {
        ctx.fail(500, "save_failed", @errorName(err));
        return;
    };
    const outcome = applySite(ctx, saved) catch |err| {
        ctx.fail(500, "sites_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) {
        try ctx.jsonStatus(400, .{ .ok = false, .output = outcome.output, .site = saved });
        return;
    }
    try ctx.json(.{ .ok = true, .output = outcome.output, .site = saved });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing site name");
        return;
    };
    const site = loadSite(ctx, name) orelse return;
    const kind = (try ctx.query("kind")) orelse "access";
    const path = if (std.mem.eql(u8, kind, "error"))
        (if (site.error_log.len > 0) site.error_log else "/var/log/nginx/error.log")
    else
        (if (site.access_log.len > 0) site.access_log else "/var/log/nginx/access.log");
    const limit_raw = (try ctx.query("lines")) orelse "200";
    const limit = std.fmt.parseInt(usize, limit_raw, 10) catch 200;
    const max = @min(limit, 2000);
    const contents = compat.cwd().readFileAlloc(ctx.arena, path, 4 * 1024 * 1024) catch |err| {
        ctx.fail(404, "logs_unavailable", @errorName(err));
        return;
    };
    const lines = tailLines(ctx.arena, contents, max);
    try ctx.json(.{ .path = path, .lines = lines });
}

fn webServer(ctx: *context.Context) []const u8 {
    if (ctx.app.config.web_server.len > 0) return ctx.app.config.web_server;
    if (nginx.available(ctx.arena)) return webserver_nginx;
    if (exec.commandExists(ctx.arena, "caddy")) return webserver_caddy;
    return "";
}

fn loadSite(ctx: *context.Context, name: []const u8) ?store.Site {
    if (!validate.isSlug(name)) {
        ctx.fail(400, "bad_name", "invalid site name");
        return null;
    }
    return store.load(ctx.arena, ctx.app.config.data_dir, name) catch |err| switch (err) {
        error.SiteNotFound => {
            ctx.fail(404, "not_found", "site not found");
            return null;
        },
        else => {
            ctx.fail(500, "sites_failed", @errorName(err));
            return null;
        },
    };
}

fn applySite(ctx: *context.Context, site: store.Site) !Outcome {
    const server = webServer(ctx);
    const dir = try store.siteDir(ctx.arena, ctx.app.config.data_dir, site.name);
    if (std.mem.eql(u8, server, webserver_caddy)) {
        const result = try caddy.apply(ctx.arena, site, dir);
        return .{ .ok = result.ok, .output = result.output };
    }
    if (!std.mem.eql(u8, server, webserver_nginx)) {
        return .{ .ok = false, .output = "当前 WebServer 不是 Nginx 或 Caddy" };
    }
    try writeHtpasswd(ctx.arena, dir, site);
    const result = try nginx.apply(ctx.arena, site, dir);
    return .{ .ok = result.ok, .output = result.output };
}

fn writeHtpasswd(allocator: std.mem.Allocator, dir: []const u8, site: store.Site) !void {
    const path = try compat.path.join(allocator, &.{ dir, "htpasswd" });
    if (!site.basic_auth.enabled or site.basic_auth.users.len == 0) {
        compat.deleteFileAbsolute(path) catch {};
        return;
    }
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    for (site.basic_auth.users) |user| {
        if (user.username.len == 0 or user.password_hash.len == 0) continue;
        try buffer.writer.print("{s}:{s}\n", .{ user.username, user.password_hash });
    }
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(buffer.written());
}

fn prepareRuntime(ctx: *context.Context, site: *store.Site) !void {
    if (!std.mem.eql(u8, site.kind, "runtime")) return;
    if (site.proxy.upstreams.len > 0) return;
    if (site.runtime_id.len == 0) return error.MissingRuntime;
    const environment = environments.get(ctx.arena, ctx.app.db, site.runtime_id) catch null;
    const env = environment orelse return error.MissingRuntime;
    const port = env.port orelse return error.MissingRuntime;
    const upstreams = try ctx.arena.alloc(store.Upstream, 1);
    upstreams[0] = .{ .address = try std.fmt.allocPrint(ctx.arena, "127.0.0.1:{d}", .{port}) };
    site.proxy.upstreams = upstreams;
}

fn validateSite(site: store.Site) !void {
    if (!validate.isSlug(site.name)) return error.InvalidName;
    const kinds = [_][]const u8{ "static", "reverse_proxy", "runtime", "subsite", "tcp_proxy", "udp_proxy" };
    var kind_ok = false;
    for (kinds) |kind| kind_ok = kind_ok or std.mem.eql(u8, kind, site.kind);
    if (!kind_ok) return error.InvalidKind;
    if (site.domains.len > 32) return error.InvalidDomains;
    for (site.domains) |domain| if (!validate.isHostname(domain)) return error.InvalidDomains;
    if (site.listen == 0) return error.InvalidPort;
    if (site.custom.enabled) {
        if (site.custom.content.len > 1024 * 1024) return error.InvalidCustom;
        if (std.mem.indexOfScalar(u8, site.custom.content, 0) != null) return error.InvalidCustom;
        return;
    }
    const is_stream = std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy");
    if (is_stream) {
        if (site.proxy.upstreams.len == 0) return error.MissingUpstream;
        for (site.proxy.upstreams) |upstream| {
            if (!safeToken(upstream.address, 256)) return error.InvalidUpstream;
        }
        return;
    }
    if (site.domains.len == 0) return error.InvalidDomains;
    if (site.root.len > 0 and !safeAbsolute(site.root)) return error.InvalidRoot;
    if (site.run_dir.len > 0 and !safeAbsolute(site.run_dir)) return error.InvalidRoot;
    if (std.mem.eql(u8, site.kind, "static") or std.mem.eql(u8, site.kind, "subsite")) {
        if (site.root.len == 0) return error.InvalidRoot;
    }
    if (site.access_log.len > 0 and !safeAbsolute(site.access_log)) return error.InvalidPath;
    if (site.error_log.len > 0 and !safeAbsolute(site.error_log)) return error.InvalidPath;
    if (site.client_max_body_size.len > 0 and !safeValue(site.client_max_body_size, 32)) return error.InvalidValue;
    if (site.tls.enabled) {
        if (site.tls.certificate.len == 0 or site.tls.key.len == 0) return error.MissingCertificate;
        if (!safeAbsolute(site.tls.certificate) or !safeAbsolute(site.tls.key)) return error.InvalidCertificate;
    }
    if (site.rate_limit.enabled) {
        if (site.rate_limit.rps == 0 or site.rate_limit.rps > 100000) return error.InvalidRate;
        if (site.rate_limit.burst == 0 or site.rate_limit.burst > 1000000) return error.InvalidRate;
    }
    if (site.basic_auth.enabled and site.basic_auth.users.len > 0) {
        for (site.basic_auth.users) |user| {
            if (!validUser(user.username)) return error.InvalidUser;
            if (user.password_hash.len == 0) return error.InvalidUser;
        }
    }
    if (site.basic_auth.enabled and site.basic_auth.users.len > 64) return error.InvalidUser;
    if (site.cors.enabled) {
        for (site.cors.origins) |origin| {
            if (!std.mem.eql(u8, origin, "*") and !safeOrigin(origin)) return error.InvalidCors;
        }
        for (site.cors.methods) |method| if (!safeToken(method, 32)) return error.InvalidCors;
        for (site.cors.headers) |header| if (!safeValue(header, 256)) return error.InvalidCors;
    }
    if (site.hotlink.enabled) {
        for (site.hotlink.extensions) |extension| if (!safeToken(extension, 32)) return error.InvalidHotlink;
    }
    for (site.redirects) |redirect| {
        if (redirect.from.len == 0 or redirect.from[0] != '/') return error.InvalidRedirect;
        if (!safeValue(redirect.from, 512) or !safeValue(redirect.to, 2048)) return error.InvalidRedirect;
        if (redirect.code < 300 or redirect.code > 399) return error.InvalidRedirect;
    }
    for (site.rewrites) |rewrite| {
        if (!safeRegex(rewrite.pattern) or !safeRegex(rewrite.replacement)) return error.InvalidRewrite;
        if (!std.mem.eql(u8, rewrite.flag, "last") and
            !std.mem.eql(u8, rewrite.flag, "break") and
            !std.mem.eql(u8, rewrite.flag, "redirect") and
            !std.mem.eql(u8, rewrite.flag, "permanent")) return error.InvalidRewrite;
    }
    if (std.mem.eql(u8, site.kind, "reverse_proxy") or std.mem.eql(u8, site.kind, "runtime")) {
        if (site.proxy.upstreams.len == 0) return error.MissingUpstream;
        for (site.proxy.upstreams) |upstream| {
            if (!safeToken(upstream.address, 256)) return error.InvalidUpstream;
        }
        if (!std.mem.eql(u8, site.proxy.load_balance, "round_robin") and
            !std.mem.eql(u8, site.proxy.load_balance, "least_conn") and
            !std.mem.eql(u8, site.proxy.load_balance, "ip_hash")) return error.InvalidUpstream;
        for (site.proxy.headers) |header| {
            if (!safeToken(header.name, 128) or !safeValue(header.value, 512)) return error.InvalidUpstream;
        }
    }
    if (site.real_ip.enabled) {
        if (!safeToken(site.real_ip.header, 128)) return error.InvalidRealIp;
        for (site.real_ip.trusted) |cidr| if (!safeToken(cidr, 128)) return error.InvalidRealIp;
    }
}

fn validateServerFeatures(ctx: *context.Context, site: store.Site) !void {
    return validateServerFeaturesValue(site, webServer(ctx));
}

fn validateServerFeaturesValue(site: store.Site, webserver: []const u8) !void {
    if (!std.mem.eql(u8, webserver, webserver_caddy)) return;
    if (std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy")) return error.UnsupportedKind;
    if (site.rate_limit.enabled) return error.UnsupportedFeature;
    if (site.hotlink.enabled) return error.UnsupportedFeature;
    if (site.real_ip.enabled) return error.UnsupportedFeature;
    if (site.error_log.len > 0) return error.UnsupportedFeature;
}

pub fn validateForTest(site: store.Site, webserver: []const u8) !void {
    try validateSite(site);
    try validateServerFeaturesValue(site, webserver);
}

fn failForValidation(ctx: *context.Context, err: anyerror) void {
    const message = switch (err) {
        error.InvalidName => "站点标识无效",
        error.InvalidKind => "不支持的站点类型",
        error.InvalidDomains => "域名无效或为空",
        error.InvalidPort => "端口无效",
        error.InvalidRoot => "目录必须是绝对路径",
        error.InvalidPath => "日志路径必须是绝对路径",
        error.InvalidValue => "配置值无效",
        error.MissingCertificate => "启用 HTTPS 前请先上传证书和私钥",
        error.InvalidCertificate => "证书路径无效",
        error.InvalidRate => "限流参数无效",
        error.InvalidUser => "密码访问用户无效",
        error.InvalidCors => "CORS 配置无效",
        error.InvalidHotlink => "防盗链扩展名无效",
        error.InvalidRedirect => "重定向规则无效",
        error.InvalidRewrite => "伪静态规则无效",
        error.MissingUpstream => "反向代理缺少上游地址",
        error.InvalidUpstream => "上游地址或负载均衡配置无效",
        error.InvalidRealIp => "真实 IP 配置无效",
        error.InvalidCustom => "自定义配置无效",
        error.MissingRuntime => "运行环境无效或没有端口",
        error.UnsupportedKind => "当前 WebServer 暂不支持该站点类型",
        error.StreamIncludeRequired => "nginx.conf 已有 stream 块，请手动加入 include /etc/nginx/stream.d/hampanel/*.conf;",
        error.StreamIncludeFailed => "无法启用 nginx stream include，请检查 nginx.conf",
        error.UnsupportedFeature => "当前 WebServer 不支持该配置项（限流/防盗链/真实 IP/错误日志）",
        else => @errorName(err),
    };
    ctx.fail(400, @errorName(err), message);
}

fn safeAbsolute(value: []const u8) bool {
    if (value.len == 0 or value.len > 2048) return false;
    if (!compat.path.isAbsolute(value)) return false;
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == ' ' or ch == ';' or ch == '{' or ch == '}' or ch == '#') return false;
    }
    return true;
}

fn safeValue(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |ch| if (ch < 0x20 or ch == 0x7f or ch == ';' or ch == '{' or ch == '}') return false;
    return true;
}

fn safeToken(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |ch| {
        if (ch <= ' ' or ch == 0x7f or ch == ';' or ch == '{' or ch == '}' or ch == '"' or ch == '\\') return false;
    }
    return true;
}

fn safeRegex(value: []const u8) bool {
    if (value.len == 0 or value.len > 2048) return false;
    for (value) |ch| if (ch == '\n' or ch == '\r' or ch == ';' or ch == '{' or ch == '}') return false;
    return true;
}

fn safeOrigin(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "http://") and !std.mem.startsWith(u8, value, "https://")) return false;
    return safeValue(value, 512);
}

fn validUser(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn tailLines(allocator: std.mem.Allocator, contents: []const u8, count: usize) []const []const u8 {
    var total: usize = 0;
    var cursor = contents.len;
    while (cursor > 0 and total < count) : (total += 1) {
        cursor -= 1;
        while (cursor > 0 and contents[cursor - 1] != '\n') cursor -= 1;
    }
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, contents[cursor..], '\n');
    while (it.next()) |line| {
        if (line.len > 0) lines.append(line) catch {};
    }
    return lines.items;
}
