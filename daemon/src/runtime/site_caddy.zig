const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const store = @import("site_store.zig");

pub const webserver = "caddy";
pub const conf_dir = "/etc/caddy/hampanel";
const main_config = "/etc/caddy/Caddyfile";
const max_output = 8 * 1024 * 1024;

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn available(allocator: std.mem.Allocator) bool {
    if (!exec.commandExists(allocator, "caddy")) return false;
    const result = exec.run(allocator, &.{ "caddy", "version" }, 64 * 1024) catch return false;
    return result.ok();
}

pub fn render(allocator: std.mem.Allocator, site: store.Site, site_dir: []const u8) ![]const u8 {
    _ = site_dir;
    if (site.custom.enabled) return allocator.dupe(u8, site.custom.content);
    if (std.mem.eql(u8, site.kind, "tcp_proxy") or std.mem.eql(u8, site.kind, "udp_proxy")) return error.UnsupportedKind;
    if (site.rate_limit.enabled) return error.UnsupportedFeature;
    if (site.hotlink.enabled) return error.UnsupportedFeature;
    if (site.real_ip.enabled) return error.UnsupportedFeature;
    if (site.error_log.len > 0) return error.UnsupportedFeature;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try writeAddresses(w, site);
    try w.print(" {{\n", .{});
    if (site.tls.enabled) {
        if (site.tls.certificate.len > 0 and site.tls.key.len > 0) {
            try w.print("    tls {s} {s}\n", .{ site.tls.certificate, site.tls.key });
        } else if (site.tls.acme_email.len > 0) {
            try w.print("    tls {s}\n", .{site.tls.acme_email});
        }
    }
    if (site.tls.enabled and site.tls.hsts) {
        try w.print("    header Strict-Transport-Security \"max-age=31536000\"\n", .{});
    }
    if (site.cors.enabled and site.cors.origins.len > 0) {
        const wildcard = contains(site.cors.origins, "*");
        try w.print("    header {{\n", .{});
        if (wildcard) {
            try w.print("        Access-Control-Allow-Origin \"*\"\n", .{});
        } else {
            try w.print("        Access-Control-Allow-Origin \"{s}\"\n", .{site.cors.origins[0]});
        }
        if (site.cors.methods.len > 0) {
            try w.print("        Access-Control-Allow-Methods \"", .{});
            try writeJoined(w, site.cors.methods, ", ");
            try w.print("\"\n", .{});
        }
        if (site.cors.headers.len > 0) {
            try w.print("        Access-Control-Allow-Headers \"", .{});
            try writeJoined(w, site.cors.headers, ", ");
            try w.print("\"\n", .{});
        }
        if (site.cors.credentials) try w.print("        Access-Control-Allow-Credentials \"true\"\n", .{});
        try w.print("    }}\n", .{});
    }
    if (site.client_max_body_size.len > 0) {
        try w.print("    request_body {{\n        max_size {s}\n    }}\n", .{site.client_max_body_size});
    }
    if (site.basic_auth.enabled and site.basic_auth.users.len > 0) {
        try w.print("    basicauth {{\n", .{});
        for (site.basic_auth.users) |user| {
            if (user.username.len == 0 or user.password_hash.len == 0) continue;
            try w.print("        {s} {s}\n", .{ user.username, user.password_hash });
        }
        try w.print("    }}\n", .{});
    }
    if (site.access_log.len > 0) {
        try w.print("    log {{\n        output file {s}\n    }}\n", .{site.access_log});
    }
    for (site.redirects) |redirect| {
        try w.print("    redir {s} {s} {d}\n", .{ redirect.from, redirect.to, redirect.code });
    }
    for (site.rewrites, 0..) |rewrite, i| {
        try w.print("    @rewrite_{d} path_regexp {s}\n", .{ i, rewrite.pattern });
        try w.print("    rewrite @rewrite_{d} ", .{i});
        try writeCaddyReplacement(w, rewrite.replacement, i);
        try w.print("\n", .{});
    }

    const is_proxy = std.mem.eql(u8, site.kind, "reverse_proxy") or std.mem.eql(u8, site.kind, "runtime");
    if (is_proxy) {
        if (site.proxy.upstreams.len == 0) return error.MissingUpstream;
        try w.print("    reverse_proxy", .{});
        for (site.proxy.upstreams) |upstream| try w.print(" {s}", .{upstream.address});
        try w.print(" {{\n", .{});
        if (std.mem.eql(u8, site.proxy.load_balance, "least_conn")) {
            try w.print("        lb_policy least_conn\n", .{});
        } else if (std.mem.eql(u8, site.proxy.load_balance, "ip_hash")) {
            try w.print("        lb_policy ip_hash\n", .{});
        }
        if (site.proxy.preserve_host) {
            try w.print("        header_up Host {{host}}\n", .{});
        } else {
            try w.print("        header_up Host {{upstream_hostport}}\n", .{});
        }
        for (site.proxy.headers) |header| {
            try w.print("        header_up {s} {s}\n", .{ header.name, header.value });
        }
        try w.print("    }}\n", .{});
    } else {
        if (site.root.len > 0) try w.print("    root * {s}\n", .{site.root});
        try w.print("    file_server\n", .{});
    }
    try w.print("}}\n", .{});
    return allocator.dupe(u8, out.written());
}

fn writeAddresses(w: *std.Io.Writer, site: store.Site) !void {
    if (site.domains.len == 0) {
        if (site.tls.enabled) return error.InvalidDomains;
        try w.print(":{d}", .{site.listen});
        return;
    }
    for (site.domains, 0..) |domain, i| {
        if (i > 0) try w.print(", ", .{});
        if (site.tls.enabled) {
            try w.print("https://{s}", .{domain});
        } else if (site.listen == 80) {
            try w.print("http://{s}", .{domain});
        } else {
            try w.print("http://{s}:{d}", .{ domain, site.listen });
        }
    }
}

fn writeCaddyReplacement(w: *std.Io.Writer, value: []const u8, index: usize) !void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '$' and i + 1 < value.len and std.ascii.isDigit(value[i + 1])) {
            try w.print("{{re.rewrite_{d}.{c}}}", .{ index, value[i + 1] });
            i += 2;
            continue;
        }
        try w.print("{c}", .{value[i]});
        i += 1;
    }
}

fn writeJoined(w: *std.Io.Writer, values: []const []const u8, separator: []const u8) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try w.print("{s}", .{separator});
        try w.print("{s}", .{value});
    }
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

pub fn apply(allocator: std.mem.Allocator, site: store.Site, site_dir: []const u8) !Outcome {
    try compat.cwd().makePath(conf_dir);
    ensureImport(allocator) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };

    const active = try confPath(allocator, site.name, true);
    const disabled = try confPath(allocator, site.name, false);
    const target = if (site.enabled) active else disabled;
    const alternate = if (site.enabled) disabled else active;
    const previous_target = readOptional(allocator, target);
    const previous_alternate = readOptional(allocator, alternate);
    errdefer restoreFile(target, previous_target);
    errdefer restoreFile(alternate, previous_alternate);

    const rendered = render(allocator, site, site_dir) catch |err| {
        return .{ .ok = false, .output = @errorName(err) };
    };
    writeFile(target, rendered) catch |err| return .{ .ok = false, .output = @errorName(err) };
    restoreFile(alternate, null);

    const validation = validateConfig(allocator) catch |err| {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return .{ .ok = false, .output = @errorName(err) };
    };
    if (!validation.ok) {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return validation;
    }
    const reloaded = reload(allocator) catch |err| {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return .{ .ok = false, .output = @errorName(err) };
    };
    if (!reloaded.ok) {
        restoreFile(target, previous_target);
        restoreFile(alternate, previous_alternate);
        return reloaded;
    }
    return .{ .ok = true, .output = reloaded.output };
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !Outcome {
    const active = try confPath(allocator, name, true);
    const disabled = try confPath(allocator, name, false);
    const previous_active = readOptional(allocator, active);
    const previous_disabled = readOptional(allocator, disabled);
    errdefer restoreFile(active, previous_active);
    errdefer restoreFile(disabled, previous_disabled);
    compat.deleteFileAbsolute(active) catch {};
    compat.deleteFileAbsolute(disabled) catch {};

    const validation = validateConfig(allocator) catch |err| {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return .{ .ok = false, .output = @errorName(err) };
    };
    if (!validation.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return validation;
    }
    const reloaded = reload(allocator) catch |err| {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return .{ .ok = false, .output = @errorName(err) };
    };
    if (!reloaded.ok) {
        restoreFile(active, previous_active);
        restoreFile(disabled, previous_disabled);
        return reloaded;
    }
    return .{ .ok = true, .output = reloaded.output };
}

pub fn reload(allocator: std.mem.Allocator) !Outcome {
    // Reload through the admin API first: config errors return immediately,
    // while `systemctl reload` can block for the full stop timeout.
    const direct = exec.run(allocator, &.{ "caddy", "reload", "--config", main_config, "--adapter", "caddyfile" }, max_output) catch {
        return .{ .ok = false, .output = "unable to reload caddy" };
    };
    return .{ .ok = direct.ok(), .output = textOf(direct) };
}

fn validateConfig(allocator: std.mem.Allocator) !Outcome {
    const result = exec.run(allocator, &.{ "caddy", "validate", "--config", main_config, "--adapter", "caddyfile" }, max_output) catch {
        return .{ .ok = false, .output = "unable to execute caddy" };
    };
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn ensureImport(allocator: std.mem.Allocator) !void {
    const raw = compat.cwd().readFileAlloc(allocator, main_config, 1024 * 1024) catch "";
    if (std.mem.indexOf(u8, raw, "import " ++ conf_dir ++ "/*.caddy") != null) return;
    const backup = main_config ++ ".hampanel.bak";
    const existing_backup = compat.cwd().readFileAlloc(allocator, backup, 1024 * 1024) catch null;
    if (existing_backup == null) writeFile(backup, raw) catch {};
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll(raw);
    if (raw.len > 0 and raw[raw.len - 1] != '\n') try buffer.writer.writeAll("\n");
    try buffer.writer.print("import {s}/*.caddy\n", .{conf_dir});
    writeFile(main_config, buffer.written()) catch |err| return err;
}

fn textOf(result: exec.Result) []const u8 {
    return if (result.stderr.len > 0) result.stderr else result.stdout;
}

fn confPath(allocator: std.mem.Allocator, name: []const u8, enabled: bool) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.caddy{s}", .{ conf_dir, name, if (enabled) "" else ".disabled" });
}

fn readOptional(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return compat.cwd().readFileAlloc(allocator, path, max_output) catch null;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try compat.cwd().makePath(std.fs.path.dirname(path) orelse ".");
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(data);
}

fn restoreFile(path: []const u8, previous: ?[]const u8) void {
    if (previous) |data| {
        writeFile(path, data) catch {};
    } else {
        compat.deleteFileAbsolute(path) catch {};
    }
}
