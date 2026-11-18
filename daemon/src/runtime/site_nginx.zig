const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const store = @import("site_store.zig");

const conf_dir = "/etc/nginx/conf.d";
const max_output = 2 * 1024 * 1024;

pub const Outcome = struct {
    ok: bool,
    output: []const u8 = "",
};

pub fn available(allocator: std.mem.Allocator) bool {
    return exec.commandExists(allocator, "nginx");
}

pub fn render(allocator: std.mem.Allocator, site: store.Site, site_dir: []const u8) ![]const u8 {
    if (site.custom.enabled) return allocator.dupe(u8, site.custom.content);
    if (std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy")) {
        return error.UnsupportedKind;
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

    if (site.tls.enabled and site.tls.redirect_http) {
        try writeServerHead(w, site, zone, false);
        try w.print("    listen 80;\n", .{});
        try w.print("    listen [::]:80;\n", .{});
        try w.print("    return 301 https://$host$request_uri;\n", .{});
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

fn writeServerHead(w: *std.Io.Writer, site: store.Site, zone: []const u8, main: bool) !void {
    _ = zone;
    _ = main;
    try w.print("server {{\n", .{});
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

pub fn apply(allocator: std.mem.Allocator, site: store.Site, site_dir: []const u8) !Outcome {
    const active = try confPath(allocator, site.name, true);
    const disabled = try confPath(allocator, site.name, false);
    const target = if (site.enabled) active else disabled;
    const alternate = if (site.enabled) disabled else active;
    try compat.cwd().makePath(conf_dir);

    const previous_target = readOptional(allocator, target);
    const previous_alternate = readOptional(allocator, alternate);
    errdefer restoreFile(target, previous_target);
    errdefer restoreFile(alternate, previous_alternate);

    const rendered = render(allocator, site, site_dir) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    try writeRaw(target, rendered);
    if (readOptional(allocator, alternate) != null) compat.deleteFileAbsolute(alternate) catch {};

    if (site.enabled) {
        const test_result = nginxTest(allocator);
        if (!test_result.ok) {
            restoreFile(target, previous_target);
            restoreFile(alternate, previous_alternate);
            return test_result;
        }
    }
    const reload_result = try reload(allocator);
    if (!reload_result.ok) {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return reload_result;
    }
    return .{ .ok = true, .output = reload_result.output };
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !Outcome {
    const active = try confPath(allocator, name, true);
    const disabled = try confPath(allocator, name, false);
    const previous_active = readOptional(allocator, active);
    const previous_disabled = readOptional(allocator, disabled);
    compat.deleteFileAbsolute(active) catch {};
    compat.deleteFileAbsolute(disabled) catch {};

    const test_result = nginxTest(allocator);
    if (!test_result.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return test_result;
    }
    const reload_result = try reload(allocator);
    if (!reload_result.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return reload_result;
    }
    return .{ .ok = true, .output = reload_result.output };
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
    return confPath(allocator, name, true);
}

fn confPath(allocator: std.mem.Allocator, name: []const u8, enabled: bool) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/hampanel-{s}.conf{s}",
        .{ conf_dir, name, if (enabled) "" else ".disabled" },
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
