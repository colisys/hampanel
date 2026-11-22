const std = @import("std");
const Site = @import("site_store.zig").Site;

pub const Target = struct {
    site: ?[]const u8 = null,
    origin: []const u8,
    authority: []const u8,
    tls: bool,
};

// Only literal origins, never provider expressions, URI templates or credentials.
// Internal services are valid destinations; network egress policy belongs to the provider.
pub fn parse(url: []const u8) !Target {
    const tls = std.mem.startsWith(u8, url, "https://");
    if (url.len > 512 or (!tls and !std.mem.startsWith(u8, url, "http://"))) return error.InvalidWebhookUrl;
    const offset: usize = if (tls) 8 else 7;
    const authority = url[offset..];
    const host_end = if (std.mem.startsWith(u8, authority, "[")) end: {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidWebhookUrl;
        const host = authority[1..close];
        for (host) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return error.InvalidWebhookUrl;
        _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return error.InvalidWebhookUrl;
        break :end close + 1;
    } else end: {
        const end = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        const host = authority[0..end];
        // Nginx interprets the unix: prefix as a socket rather than a TCP origin.
        if (host.len == 0 or host.len > 253 or std.ascii.eqlIgnoreCase(host, "unix")) return error.InvalidWebhookUrl;
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidWebhookUrl;
            for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidWebhookUrl;
        }
        break :end end;
    };
    if (host_end < authority.len) {
        if (authority[host_end] != ':') return error.InvalidWebhookUrl;
        const port = authority[host_end + 1 ..];
        if (port.len > 5) return error.InvalidWebhookUrl;
        for (port) |c| if (!std.ascii.isDigit(c)) return error.InvalidWebhookUrl;
        if ((std.fmt.parseInt(u16, port, 10) catch 0) == 0) return error.InvalidWebhookUrl;
    }
    return .{ .origin = url, .authority = authority, .tls = tls };
}

pub fn target(site: Site) !Target {
    if (site.webhook) |binding| {
        if (std.mem.eql(u8, binding.target, "cron")) {
            if (site.proxy.upstreams.len != 0) return error.InternalWebhookUnavailable;
            if (!@import("shared").validate.isSlug(site.name) or binding.cron_id.len != 8) return error.InvalidWebhookOptions;
            for (binding.cron_id) |c| if (!std.ascii.isHex(c)) return error.InvalidWebhookOptions;
        } else if (!std.mem.eql(u8, binding.target, "upstream") or binding.cron_id.len != 0) return error.InvalidWebhookOptions;
    }
    if (site.custom.enabled or site.redirects.len != 0 or site.rewrites.len != 0 or site.proxy.headers.len != 0 or site.cors.enabled or site.hotlink.enabled or site.real_ip.enabled or site.basic_auth.enabled or site.access_log.len != 0 or site.error_log.len != 0 or site.client_max_body_size.len != 0 or site.root.len != 0 or site.run_dir.len != 0) return error.InvalidWebhookOptions;
    if (site.tls.enabled) {
        for ([_][]const u8{ site.tls.certificate, site.tls.key }) |path| {
            if (!std.mem.startsWith(u8, path, "/") or path.len > 2048) return error.InvalidWebhookOptions;
            // A certificate path is emitted as a bare Nginx/Caddy argument; reject
            // delimiters and Nginx variables, but allow ordinary filename characters.
            for (path) |c| {
                if (c <= ' ' or c == 0x7f or std.mem.indexOfScalar(u8, ";{}#\"'`\\$", c) != null) return error.InvalidWebhookOptions;
            }
        }
    }
    if (@import("cron_webhook.zig").internal(site)) return .{ .site = site.name, .origin = "", .authority = "", .tls = false };
    if (site.proxy.upstreams.len != 1 or site.proxy.upstreams[0].weight != 1) return error.InvalidWebhookUrl;
    return parse(site.proxy.upstreams[0].address);
}

pub fn writeNginx(w: *std.Io.Writer, t: Target) !void {
    if (t.site) |site| {
        try w.print("    location ^~ /hook/{s}/ {{\n        proxy_pass http://unix:" ++ @import("cron_webhook.zig").socket ++ ":;\n        proxy_pass_request_body off;\n        proxy_pass_request_headers off;\n        proxy_set_header Content-Length \"\";\n    }}\n    location / {{ return 404; }}\n", .{site});
        return;
    }
    try w.writeAll("    location / {\n");
    try w.print("        proxy_pass {s};\n        proxy_set_header Host {s};\n        proxy_set_header X-Forwarded-Host {s};\n", .{ t.origin, t.authority, t.authority });
    try w.writeAll("        proxy_ignore_headers X-Accel-Redirect;\n        proxy_redirect off;\n");
    if (t.tls) try w.writeAll("        proxy_ssl_server_name on;\n        proxy_ssl_verify on;\n        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n");
    try w.writeAll("    }\n");
}

pub fn writeCaddy(w: *std.Io.Writer, t: Target) !void {
    if (t.site != null) return error.InternalWebhookProviderUnsupported;
    try w.writeAll("    handle {\n");
    try w.print("        reverse_proxy {s} {{\n            header_up Host {s}\n            header_up X-Forwarded-Host {s}\n        }}\n", .{ t.origin, t.authority, t.authority });
    try w.writeAll("    }\n");
}
