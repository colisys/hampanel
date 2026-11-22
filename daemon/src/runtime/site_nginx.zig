const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const store = @import("site_store.zig");

const conf_dir = "/etc/nginx/conf.d";
const stream_dir = "/etc/nginx/stream.d/hampanel";
const max_output = 2 * 1024 * 1024;

pub const Outcome = struct {
    ok: bool,
    output: []const u8 = "",
};

pub fn available(allocator: std.mem.Allocator) bool {
    return exec.commandExists(allocator, "nginx");
}

pub fn render(allocator: std.mem.Allocator, site: store.Site, site_dir: []const u8) ![]const u8 {
    const webhook = @import("site_webhook.zig");
    const hook = if (std.mem.eql(u8, site.kind, "webhook")) try webhook.target(site) else null;
    if (site.custom.enabled) return allocator.dupe(u8, site.custom.content);
    if (std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy")) {
        return renderStream(allocator, site);
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const w = &output.writer;

    const zone = try sanitize(allocator, site.name);
    const is_proxy = std.mem.eql(u8, site.kind, "reverse_proxy") or std.mem.eql(u8, site.kind, "runtime");
    const has_upstreams = site.proxy.upstreams.len > 0;
    if (is_proxy and !has_upstreams) return error.MissingUpstream;

    try w.print("# Managed by Hampanel. Manual edits are overwritten unless custom config is enabled.\n", .{});
    if (site.rate_limit.enabled) {
        try w.print("limit_req_zone $binary_remote_addr zone=hampanel_req_{s}:10m rate={d}r/s;\n", .{ zone, site.rate_limit.rps });
        if (site.rate_limit.connections > 0) {
            try w.print("limit_conn_zone $binary_remote_addr zone=hampanel_conn_{s}:10m;\n", .{zone});
        }
    }
    if (site.tls.enabled and site.tls.certificate.len == 0) return error.MissingCertificate;
    if (site.tls.enabled and site.tls.key.len == 0) return error.MissingCertificate;

    var cors_wildcard = false;
    if (site.cors.enabled) {
        for (site.cors.origins) |origin| {
            if (std.mem.eql(u8, origin, "*")) cors_wildcard = true;
        }
        if (!cors_wildcard and site.cors.origins.len > 0) {
            try w.print("map $http_origin $hampanel_cors_{s} {{\n", .{zone});
            try w.print("    default \"\";\n", .{});
            for (site.cors.origins) |origin| {
                try w.print("    \"{s}\" \"$http_origin\";\n", .{origin});
            }
            try w.print("}}\n", .{});
        }
    }

    if (is_proxy and site.proxy.websocket) {
        try w.print("map $http_upgrade $hampanel_upgrade_{s} {{ default upgrade; '' close; }}\n", .{zone});
    }
    if (is_proxy) {
        try w.print("upstream hampanel_{s} {{\n", .{zone});
        if (std.mem.eql(u8, site.proxy.load_balance, "least_conn")) try w.print("    least_conn;\n", .{});
        if (std.mem.eql(u8, site.proxy.load_balance, "ip_hash")) try w.print("    ip_hash;\n", .{});
        for (site.proxy.upstreams) |upstream| {
            try w.print("    server {s}", .{upstream.address});
            if (upstream.weight > 1) try w.print(" weight={d}", .{upstream.weight});
            try w.print(";\n", .{});
        }
        try w.print("}}\n", .{});
    }

    const cron_hook = @import("cron_webhook.zig").internal(site);
    if (cron_hook and !@import("cron_webhook.zig").secure(site)) return error.InsecureWebhookTransport;
    if (site.tls.enabled and (site.tls.redirect_http or cron_hook)) {
        try writeServerHead(w, site, zone, false);
        try w.print("    listen 80;\n", .{});
        try w.print("    listen [::]:80;\n", .{});
        if (cron_hook) try w.writeAll("    return 404;\n") else try w.print("    return 301 https://$host$request_uri;\n", .{});
        try w.print("}}\n\n", .{});
    }

    try writeServerHead(w, site, zone, true);
    if (site.tls.enabled) {
        try w.print("    listen 443 ssl http2;\n", .{});
        if (site.ipv6) try w.print("    listen [::]:443 ssl http2;\n", .{});
        try w.print("    ssl_certificate {s};\n", .{site.tls.certificate});
        try w.print("    ssl_certificate_key {s};\n", .{site.tls.key});
        try w.print("    ssl_protocols TLSv1.2 TLSv1.3;\n", .{});
        if (site.tls.hsts) {
            try w.print("    add_header Strict-Transport-Security \"max-age=31536000\" always;\n", .{});
        }
    } else {
        try w.print("    listen {d};\n", .{site.listen});
        if (site.ipv6) try w.print("    listen [::]:{d};\n", .{site.listen});
    }

    if (site.access_log.len > 0) try w.print("    access_log {s};\n", .{site.access_log});
    if (site.error_log.len > 0) try w.print("    error_log {s};\n", .{site.error_log});
    if (site.client_max_body_size.len > 0) try w.print("    client_max_body_size {s};\n", .{site.client_max_body_size});
    if (site.rate_limit.enabled) {
        try w.print("    limit_req zone=hampanel_req_{s} burst={d} nodelay;\n", .{ zone, site.rate_limit.burst });
        if (site.rate_limit.connections > 0) {
            try w.print("    limit_conn hampanel_conn_{s} {d};\n", .{ zone, site.rate_limit.connections });
        }
    }

    if (site.real_ip.enabled) {
        for (site.real_ip.trusted) |cidr| try w.print("    set_real_ip_from {s};\n", .{cidr});
        try w.print("    real_ip_header {s};\n", .{site.real_ip.header});
        try w.print("    real_ip_recursive on;\n", .{});
    }

    if (site.basic_auth.enabled and site.basic_auth.users.len > 0) {
        try w.print("    auth_basic \"Restricted\";\n", .{});
        const htpasswd = try compat.path.join(allocator, &.{ site_dir, "htpasswd" });
        try w.print("    auth_basic_user_file {s};\n", .{htpasswd});
    }

    if (site.cors.enabled) {
        if (cors_wildcard) {
            try w.print("    add_header Access-Control-Allow-Origin \"*\" always;\n", .{});
        } else if (site.cors.origins.len > 0) {
            try w.print("    add_header Access-Control-Allow-Origin $hampanel_cors_{s} always;\n", .{zone});
        }
        if (site.cors.methods.len > 0) {
            try w.print("    add_header Access-Control-Allow-Methods \"", .{});
            try writeJoined(w, site.cors.methods, ", ");
            try w.print("\" always;\n", .{});
        }
        if (site.cors.headers.len > 0) {
            try w.print("    add_header Access-Control-Allow-Headers \"", .{});
            try writeJoined(w, site.cors.headers, ", ");
            try w.print("\" always;\n", .{});
        }
        if (site.cors.credentials) {
            try w.print("    add_header Access-Control-Allow-Credentials \"true\" always;\n", .{});
        }
    }

    for (site.rewrites) |rewrite| {
        try w.print("    rewrite {s} {s} {s};\n", .{ rewrite.pattern, rewrite.replacement, rewrite.flag });
    }
    for (site.redirects) |redirect| {
        try w.print("    location = {s} {{ return {d} {s}; }}\n", .{ redirect.from, redirect.code, redirect.to });
    }

    if (site.hotlink.enabled and site.hotlink.extensions.len > 0) {
        try w.print("    location ~* \\.(", .{});
        try writeJoined(w, site.hotlink.extensions, "|");
        try w.print(")$ {{\n", .{});
        try w.print("        valid_referers ", .{});
        if (site.hotlink.allow_empty_referer) try w.print("none blocked ", .{});
        try w.print("server_names;\n", .{});
        try w.print("        if ($invalid_referer) {{ return 403; }}\n", .{});
        try w.print("    }}\n", .{});
    }

    if (hook) |t| {
        try webhook.writeNginx(w, t);
        try w.writeAll("}\n");
        return allocator.dupe(u8, output.written());
    }
    try w.print("    location / {{\n", .{});
    if (is_proxy) {
        try w.print("        proxy_pass http://hampanel_{s};\n", .{zone});
        try w.print("        proxy_http_version 1.1;\n", .{});
        if (site.proxy.websocket) {
            try w.print("        proxy_set_header Upgrade $http_upgrade;\n", .{});
            try w.print("        proxy_set_header Connection $hampanel_upgrade_{s};\n", .{zone});
        }
        if (site.proxy.preserve_host) {
            try w.print("        proxy_set_header Host $host;\n", .{});
        } else {
            try w.print("        proxy_set_header Host $proxy_host;\n", .{});
        }
        try w.print("        proxy_set_header X-Real-IP $remote_addr;\n", .{});
        try w.print("        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n", .{});
        try w.print("        proxy_set_header X-Forwarded-Proto $scheme;\n", .{});
        for (site.proxy.headers) |header| {
            try w.print("        proxy_set_header {s} {s};\n", .{ header.name, header.value });
        }
    } else {
        if (site.root.len > 0) try w.print("        root {s};\n", .{site.root});
        if (site.index.len > 0) {
            try w.print("        index", .{});
            for (site.index) |index| try w.print(" {s}", .{index});
            try w.print(";\n", .{});
        }
        try w.print("        try_files $uri $uri/ =404;\n", .{});
    }
    try w.print("    }}\n", .{});
    try w.print("}}\n", .{});
    return allocator.dupe(u8, output.written());
}

fn renderStream(allocator: std.mem.Allocator, site: store.Site) ![]const u8 {
    if (site.proxy.upstreams.len == 0) return error.MissingUpstream;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("# Managed by Hampanel. Manual edits are overwritten unless custom config is enabled.\n", .{});
    try w.print("server {{\n", .{});
    if (std.mem.eql(u8, site.kind, "udp_proxy")) {
        try w.print("    listen {d} udp;\n", .{site.listen});
    } else {
        try w.print("    listen {d};\n", .{site.listen});
    }
    try w.print("    proxy_pass {s};\n", .{site.proxy.upstreams[0].address});
    try w.print("    proxy_timeout 30s;\n", .{});
    try w.print("}}\n", .{});
    return allocator.dupe(u8, out.written());
}

fn writeServerHead(w: *std.Io.Writer, site: store.Site, zone: []const u8, main: bool) !void {
    _ = zone;
    _ = main;
    try w.print("server {{\n", .{});
    if (@import("cron_webhook.zig").internal(site)) try w.writeAll("    access_log off;\n    error_log /dev/null;\n");
    try w.print("    server_name", .{});
    if (site.domains.len == 0) {
        try w.print(" _", .{});
    } else {
        for (site.domains) |domain| try w.print(" {s}", .{domain});
    }
    try w.print(";\n", .{});
}

fn writeJoined(w: *std.Io.Writer, values: []const []const u8, separator: []const u8) !void {
    for (values, 0..) |value, index| {
        if (index > 0) try w.print("{s}", .{separator});
        try w.print("{s}", .{value});
    }
}

fn sanitize(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |ch, index| out[index] = if (ch == '-') '_' else ch;
    return out;
}

const engine_mod = @import("engine.zig");

pub const Container = struct {
    engine: engine_mod.Engine,
    socket: []const u8,
    id: []const u8,
    dir: []const u8,
    data_dir: []const u8,

    fn command(self: Container, a: std.mem.Allocator, action: enum { check, reload }) Outcome {
        const args: []const []const u8 = switch (action) {
            .check => &.{ self.engine.name, "exec", self.id, "nginx", "-t" },
            .reload => &.{ self.engine.name, "exec", self.id, "nginx", "-s", "reload" },
        };
        const r = engine_mod.run(a, self.engine, self.socket, args, .{ .max_output = max_output }) catch return .{ .ok = false, .output = "managed nginx unavailable" };
        return .{ .ok = r.ok(), .output = textOf(r) };
    }
};

pub fn resolveContainer(a: std.mem.Allocator, data_dir: []const u8, socket: []const u8) !Container {
    return inspectContainer(a, data_dir, socket, false);
}

pub fn inspectContainer(a: std.mem.Allocator, data_dir: []const u8, socket: []const u8, require_socket: bool) !Container {
    const dir = try compat.path.join(a, &.{ data_dir, "apps/nginx/sites-conf" });
    const engine = try engine_mod.detect(a, socket);
    const ps = try engine_mod.run(a, engine, socket, &.{ engine.name, "ps", "--no-trunc", "--filter", "label=com.docker.compose.project=hampanel-nginx", "--filter", "label=com.docker.compose.service=web", "--format", "{{.ID}}" }, .{});
    const id = std.mem.trim(u8, ps.stdout, " \t\r\n");
    if (!ps.ok() or id.len != 64) return error.ManagedNginxUnavailable;
    for (id) |c| if (!std.ascii.isHex(c)) return error.ManagedNginxUnavailable;
    // Require the catalog image and mount layout, not just spoofable labels.
    const layout = "{{.Config.Image}}\n{{.HostConfig.Privileged}}\n{{range .Mounts}}{{.Type}} {{.Destination}} {{.RW}} {{.Source}}\n{{end}}";
    const inspect = try engine_mod.run(a, engine, socket, &.{ engine.name, "inspect", "--format", layout, id }, .{});
    const snippet = try compat.path.join(a, &.{ data_dir, "apps/nginx/sites-include.conf" });
    const container_mod = @import("site_nginx_container.zig");
    const expect = @import("site_nginx_layout.zig").Expect{
        .conf = dir,
        .snippet = snippet,
        .main = try container_mod.mainConfigPath(a, data_dir),
        .stream = try container_mod.streamDir(a, data_dir),
        .require_socket = require_socket,
    };
    if (!inspect.ok() or !try @import("site_nginx_layout.zig").catalogLayout(a, inspect.stdout, expect)) return error.ManagedNginxUnavailable;
    return .{ .engine = engine, .socket = socket, .id = id, .dir = dir, .data_dir = data_dir };
}

pub fn apply(allocator: std.mem.Allocator, container_in: ?Container, site: store.Site, site_dir: []const u8) !Outcome {
    var container = container_in;
    const is_stream = std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy");
    if (is_stream) {
        if (container) |c| {
            try compat.cwd().makePath(try @import("site_nginx_container.zig").streamDir(allocator, c.data_dir));
        } else {
            try compat.cwd().makePath(stream_dir);
            ensureStreamInclude(allocator) catch |err| {
                return .{ .ok = false, .output = @errorName(err) };
            };
        }
    } else {
        try compat.cwd().makePath(if (container) |c| c.dir else conf_dir);
    }
    const active = if (is_stream) try streamConfPath(allocator, container, site.name, true) else try confPath(allocator, container, site.name, true);
    const disabled = if (is_stream) try streamConfPath(allocator, container, site.name, false) else try confPath(allocator, container, site.name, false);
    const target = if (site.enabled) active else disabled;
    const alternate = if (site.enabled) disabled else active;

    const previous_target = readOptional(allocator, target);
    const previous_alternate = readOptional(allocator, alternate);
    errdefer restoreFile(target, previous_target);
    errdefer restoreFile(alternate, previous_alternate);

    const rendered = render(allocator, site, site_dir) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    try writeRaw(target, rendered);
    if (readOptional(allocator, alternate) != null) compat.deleteFileAbsolute(alternate) catch {};

    if (container) |current| {
        const container_mod = @import("site_nginx_container.zig");
        const sync = container_mod.sync(allocator, current.data_dir, current.socket) catch |err| {
            restoreFile(target, previous_target);
            restoreFile(alternate, previous_alternate);
            return .{ .ok = false, .output = @errorName(err) };
        };
        if (!sync.ok) {
            restoreFile(target, previous_target);
            restoreFile(alternate, previous_alternate);
            return .{ .ok = false, .output = sync.output };
        }
        const require_socket = site.enabled and @import("cron_webhook.zig").internal(site);
        if (sync.recreated or require_socket) {
            container = inspectContainer(allocator, current.data_dir, current.socket, require_socket) catch {
                restoreFile(target, previous_target);
                restoreFile(alternate, previous_alternate);
                return .{ .ok = false, .output = "managed nginx mount verification failed" };
            };
        }
    }

    if (site.enabled) {
        const test_result = if (container) |c| c.command(allocator, .check) else nginxTest(allocator);
        if (!test_result.ok) {
            restoreFile(target, previous_target);
            restoreFile(alternate, previous_alternate);
            return test_result;
        }
    }
    const reload_result = try reloadTarget(allocator, container);
    if (!reload_result.ok) {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return reload_result;
    }
    return .{ .ok = true, .output = reload_result.output };
}

pub fn remove(allocator: std.mem.Allocator, container_in: ?Container, name: []const u8) !Outcome {
    var container = container_in;
    const active = try confPath(allocator, container, name, true);
    const disabled = try confPath(allocator, container, name, false);
    const stream_active = try streamConfPath(allocator, container, name, true);
    const stream_disabled = try streamConfPath(allocator, container, name, false);
    const previous_active = readOptional(allocator, active);
    const previous_disabled = readOptional(allocator, disabled);
    const previous_stream_active = readOptional(allocator, stream_active);
    const previous_stream_disabled = readOptional(allocator, stream_disabled);
    compat.deleteFileAbsolute(active) catch {};
    compat.deleteFileAbsolute(disabled) catch {};
    compat.deleteFileAbsolute(stream_active) catch {};
    compat.deleteFileAbsolute(stream_disabled) catch {};

    if (container) |current| {
        const sync = @import("site_nginx_container.zig").sync(allocator, current.data_dir, current.socket) catch |err| {
            return .{ .ok = false, .output = @errorName(err) };
        };
        if (!sync.ok) return .{ .ok = false, .output = sync.output };
        if (sync.recreated) {
            container = resolveContainer(allocator, current.data_dir, current.socket) catch {
                return .{ .ok = false, .output = "managed nginx did not return after removing site mounts" };
            };
        }
    }

    const test_result = if (container) |c| c.command(allocator, .check) else nginxTest(allocator);
    if (!test_result.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        restoreFile(stream_active, previous_stream_active);
        restoreFile(stream_disabled, previous_stream_disabled);
        return test_result;
    }
    const reload_result = try reloadTarget(allocator, container);
    if (!reload_result.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        restoreFile(stream_active, previous_stream_active);
        restoreFile(stream_disabled, previous_stream_disabled);
        return reload_result;
    }
    return .{ .ok = true, .output = reload_result.output };
}

pub fn reloadTarget(allocator: std.mem.Allocator, container: ?Container) !Outcome {
    if (container) |c| return c.command(allocator, .reload);
    return reload(allocator);
}

pub fn reload(allocator: std.mem.Allocator) !Outcome {
    const result = exec.run(allocator, &.{ "systemctl", "reload", "nginx" }, max_output) catch null;
    if (result) |value| {
        if (value.ok()) return .{ .ok = true, .output = textOf(value) };
    }
    const direct = exec.run(allocator, &.{ "nginx", "-s", "reload" }, max_output) catch {
        return .{ .ok = false, .output = "unable to reload nginx" };
    };
    return .{ .ok = direct.ok(), .output = textOf(direct) };
}

pub fn configPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return confPath(allocator, null, name, true);
}

fn streamConfPath(allocator: std.mem.Allocator, container: ?Container, name: []const u8, enabled: bool) ![]const u8 {
    const dir = if (container) |c|
        try @import("site_nginx_container.zig").streamDir(allocator, c.data_dir)
    else
        stream_dir;
    return std.fmt.allocPrint(
        allocator,
        "{s}/hampanel-{s}.conf{s}",
        .{ dir, name, if (enabled) "" else ".disabled" },
    );
}

fn ensureStreamInclude(allocator: std.mem.Allocator) !void {
    const main = "/etc/nginx/nginx.conf";
    const include_line = "include " ++ stream_dir ++ "/*.conf;";
    const module_path = "/usr/lib/nginx/modules/ngx_stream_module.so";
    const raw = compat.cwd().readFileAlloc(allocator, main, 1024 * 1024) catch return error.NginxConfigUnreadable;
    if (std.mem.indexOf(u8, raw, include_line) != null) return;
    if (std.mem.indexOf(u8, raw, "stream {") != null) return error.StreamIncludeRequired;
    const backup = main ++ ".hampanel.bak";
    const existing_backup = compat.cwd().readFileAlloc(allocator, backup, 1024 * 1024) catch null;
    if (existing_backup == null) writeRaw(backup, raw) catch {};

    // Prefer the module already loaded via /etc/nginx/modules-enabled.
    if (try appendAndTest(allocator, main, raw, include_line, false)) return;
    if (fileExists(module_path)) {
        if (try appendAndTest(allocator, main, raw, include_line, true)) return;
    }
    writeRaw(main, raw) catch {};
    return error.StreamIncludeFailed;
}

fn appendAndTest(allocator: std.mem.Allocator, main: []const u8, raw: []const u8, include_line: []const u8, load_module: bool) !bool {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    if (load_module) try buffer.writer.writeAll("load_module /usr/lib/nginx/modules/ngx_stream_module.so;\n");
    try buffer.writer.writeAll(raw);
    if (raw.len > 0 and raw[raw.len - 1] != '\n') try buffer.writer.writeAll("\n");
    try buffer.writer.print("stream {{\n    {s}\n}}\n", .{include_line});
    writeRaw(main, buffer.written()) catch return false;
    return nginxTest(allocator).ok;
}

fn fileExists(path: []const u8) bool {
    var file = compat.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn confPath(allocator: std.mem.Allocator, container: ?Container, name: []const u8, enabled: bool) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/hampanel-{s}.conf{s}",
        .{ if (container) |c| c.dir else conf_dir, name, if (enabled) "" else ".disabled" },
    );
}

fn nginxTest(allocator: std.mem.Allocator) Outcome {
    const result = exec.run(allocator, &.{ "nginx", "-t" }, max_output) catch {
        return .{ .ok = false, .output = "nginx is not installed" };
    };
    return .{ .ok = result.ok(), .output = if (result.ok()) "" else textOf(result) };
}

fn readOptional(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return compat.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
}

fn restoreFile(path: []const u8, previous: ?[]const u8) void {
    if (previous) |content| {
        writeRaw(path, content) catch {};
    } else {
        compat.deleteFileAbsolute(path) catch {};
    }
}

fn writeRaw(path: []const u8, data: []const u8) !void {
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(data);
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
