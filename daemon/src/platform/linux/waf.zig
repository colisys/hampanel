const std = @import("std");
const exec = @import("shared").exec;

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
    mode: []const u8 = "detect",
    listen_host: []const u8 = "0.0.0.0",
    listen_port: u16 = 8088,
    upstream_host: []const u8 = "127.0.0.1",
    upstream_port: u16 = 80,
    risk_enabled: bool = true,
    risk_port: u16 = 18092,
    typesafe_enabled: bool = false,
    typesafe_endpoint: []const u8 = "https://api.typesafe.ai/v1/systemone",
    typesafe_model: []const u8 = "jev-latest",
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
    installed: bool,
    running: bool,
    version: []const u8,
    mode: []const u8,
    listen_host: []const u8,
    listen_port: u16,
    upstream_host: []const u8,
    upstream_port: u16,
    binary: []const u8,
    config_path: []const u8,
    log_path: []const u8,
    go_available: bool,
    crs: []const u8,
    message: []const u8,
    risk_enabled: bool,
    risk_running: bool,
    risk_port: u16,
    risk_binary: []const u8,
    risk_log_path: []const u8,
    typesafe_enabled: bool,
    typesafe_endpoint: []const u8,
    typesafe_model: []const u8,
    typesafe_threshold: f64,
    typesafe_timeout_ms: u16,
    typesafe_fail_open: bool,
    typesafe_key_configured: bool,
    geoip_rules: []const GeoRule,
    geosite_rules: []const GeoRule,
    routes: []const Route,
    tls_enabled: bool,
    tls_mode: []const u8,
    tls_email: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Logs = struct {
    path: []const u8,
    content: []const u8,
    truncated: bool,
};

const max_output = 8 * 1024 * 1024;
const risk_source = @embedFile("risk_gateway/main.go");

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const paths = try buildPaths(allocator, data_dir);
    const cfg = loadConfig(allocator, paths.config) catch Config{};
    const installed = fileExists(paths.binary);
    var version: []const u8 = "";
    if (installed) {
        const result = exec.run(allocator, &.{ paths.binary, "version" }, 64 * 1024) catch null;
        if (result) |res| {
            version = std.mem.trim(u8, if (res.stdout.len > 0) res.stdout else res.stderr, " \t\r\n");
        }
    }
    const go_available = blk: {
        const result = exec.run(allocator, &.{ "go", "version" }, 64 * 1024) catch break :blk false;
        break :blk result.ok();
    };
    const running = isRunning(allocator, paths.pid);
    const risk_running = cfg.risk_enabled and isRunning(allocator, paths.risk_pid);
    const key_configured = fileExists(paths.typesafe_cred);
    var message: []const u8 = "";
    if (!installed) {
        message = "尚未构建 Caddy+Coraza；请点击安装由 xcaddy 在服务器上构建。";
    } else if (!running) {
        message = "WAF 边缘未运行。启动后监听配置端口并代理到上游 Web 引擎。";
    }
    return .{
        .installed = installed,
        .running = running,
        .version = version,
        .mode = cfg.mode,
        .listen_host = cfg.listen_host,
        .listen_port = cfg.listen_port,
        .upstream_host = cfg.upstream_host,
        .upstream_port = cfg.upstream_port,
        .binary = paths.binary,
        .config_path = paths.caddyfile,
        .log_path = paths.access_log,
        .go_available = go_available,
        .crs = buildInfo(allocator, paths.binary),
        .message = message,
        .risk_enabled = cfg.risk_enabled,
        .risk_running = risk_running,
        .risk_port = cfg.risk_port,
        .risk_binary = paths.risk_bin,
        .risk_log_path = paths.risk_log,
        .typesafe_enabled = cfg.typesafe_enabled,
        .typesafe_endpoint = cfg.typesafe_endpoint,
        .typesafe_model = cfg.typesafe_model,
        .typesafe_threshold = cfg.typesafe_threshold,
        .typesafe_timeout_ms = cfg.typesafe_timeout_ms,
        .typesafe_fail_open = cfg.typesafe_fail_open,
        .typesafe_key_configured = key_configured,
        .geoip_rules = cfg.geoip_rules,
        .geosite_rules = cfg.geosite_rules,
        .routes = cfg.routes,
        .tls_enabled = cfg.tls_enabled,
        .tls_mode = cfg.tls_mode,
        .tls_email = cfg.tls_email,
    };
}

pub fn install(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    try std.fs.cwd().makePath(paths.root);
    try std.fs.cwd().makePath(paths.bin_dir);

    const go_check = exec.run(allocator, &.{ "go", "version" }, 64 * 1024) catch
        return error.GoUnavailable;
    if (!go_check.ok()) return error.GoUnavailable;

    const temporary = try std.fmt.allocPrint(allocator, "{s}.new", .{paths.binary});
    std.fs.deleteFileAbsolute(temporary) catch {};
    const result = exec.run(allocator, &.{
        "go",
        "run",
        "github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7",
        "build",
        "--with",
        "github.com/corazawaf/coraza-caddy/v2@v2.6.2",
        "--output",
        temporary,
    }, max_output) catch return error.BuildFailed;

    if (!result.ok() or !fileExists(temporary)) {
        std.fs.deleteFileAbsolute(temporary) catch {};
        return .{ .ok = false, .output = textOf(result) };
    }
    std.fs.renameAbsolute(temporary, paths.binary) catch |err| {
        std.fs.deleteFileAbsolute(temporary) catch {};
        return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "替换二进制失败：{s}", .{@errorName(err)}) };
    };
    const version = exec.run(allocator, &.{ paths.binary, "version" }, 64 * 1024) catch null;
    const version_text = if (version) |ver| std.mem.trim(u8, if (ver.stdout.len > 0) ver.stdout else ver.stderr, " \t\r\n") else "";

    const risk_dir = try std.fs.path.join(allocator, &.{ paths.root, "risk" });
    try std.fs.cwd().makePath(risk_dir);
    try writeFile(paths.risk_source, risk_source, 0o600);
    const risk_build = exec.run(allocator, &.{ "go", "build", "-o", paths.risk_bin, paths.risk_source }, max_output) catch
        return .{ .ok = false, .output = "risk gateway 构建无法启动" };
    if (!risk_build.ok() or !fileExists(paths.risk_bin)) {
        return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "Caddy 构建完成，但 risk gateway 构建失败：\n{s}", .{textOf(risk_build)}) };
    }
    return .{
        .ok = true,
        .output = try std.fmt.allocPrint(allocator, "构建完成：\n{s}\n{s}\n{s}", .{
            paths.binary,
            version_text,
            paths.risk_bin,
        }),
    };
}

pub fn configure(allocator: std.mem.Allocator, data_dir: []const u8, config: Config) !Outcome {
    try validateConfig(config);
    const paths = try buildPaths(allocator, data_dir);
    if (!fileExists(paths.binary)) return error.NotInstalled;
    try std.fs.cwd().makePath(paths.root);

    const old_caddyfile: ?[]u8 = std.fs.cwd().readFileAlloc(allocator, paths.caddyfile, 1024 * 1024) catch null;
    const old_config: ?[]u8 = std.fs.cwd().readFileAlloc(allocator, paths.config, 1024 * 1024) catch null;
    const running = isRunning(allocator, paths.pid);

    const geo = try downloadGeoRules(allocator, data_dir, config.geoip_rules, config.geosite_rules);
    if (!geo.ok) return geo;

    const rendered = try renderCaddyfile(allocator, paths, config);
    try writeFile(paths.caddyfile, rendered, 0o600);

    const check = try validateCaddyfile(allocator, paths.binary, paths.caddyfile);
    if (!check.ok) {
        restore(allocator, paths.caddyfile, old_caddyfile);
        return .{ .ok = false, .output = check.output };
    }

    const json = try std.json.stringifyAlloc(allocator, config, .{ .whitespace = .indent_2 });
    try writeFile(paths.config, json, 0o600);

    if (std.mem.eql(u8, config.mode, "off")) {
        if (running) _ = stop(allocator, data_dir) catch {};
        return .{ .ok = true, .output = "WAF 已切换为 off 并停止边缘" };
    }

    if (running) {
        _ = stop(allocator, data_dir) catch {};
        const start_result = startInternal(allocator, data_dir) catch |err| {
            restore(allocator, paths.caddyfile, old_caddyfile);
            restore(allocator, paths.config, old_config);
            return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "配置已回滚：{s}", .{@errorName(err)}) };
        };
        if (!start_result.ok) {
            restore(allocator, paths.caddyfile, old_caddyfile);
            restore(allocator, paths.config, old_config);
            _ = startInternal(allocator, data_dir) catch {};
            return .{ .ok = false, .output = start_result.output };
        }
        return .{ .ok = true, .output = "WAF 配置已校验并重启生效" };
    }

    return .{ .ok = true, .output = "WAF 配置已校验并保存" };
}

pub fn start(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    return startInternal(allocator, data_dir);
}

fn startInternal(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    if (!fileExists(paths.binary)) return error.NotInstalled;
    const config = loadConfig(allocator, paths.config) catch Config{};
    if (std.mem.eql(u8, config.mode, "off")) return error.ModeOff;
    if (!fileExists(paths.caddyfile)) {
        const rendered = try renderCaddyfile(allocator, paths, config);
        try writeFile(paths.caddyfile, rendered, 0o600);
    }
    const check = try validateCaddyfile(allocator, paths.binary, paths.caddyfile);
    if (!check.ok) return .{ .ok = false, .output = check.output };

    _ = stop(allocator, data_dir) catch {};

    var risk_started = false;
    if (config.risk_enabled) {
        const risk = try startRisk(allocator, paths, config);
        if (!risk.ok) return risk;
        risk_started = true;
    }

    const argv = [_][]const u8{
        paths.binary,
        "run",
        "--config",
        paths.caddyfile,
        "--adapter",
        "caddyfile",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "启动失败：{s}", .{@errorName(err)}) };
    };
    const pid = child.id;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    try writeFile(paths.pid, pid_text, 0o600);

    const Box = struct {
        child: std.process.Child,
        allocator: std.mem.Allocator,
        fn wait(self: *@This()) void {
            _ = self.child.wait() catch {};
            self.allocator.destroy(self);
        }
    };
    const boxed = try allocator.create(Box);
    boxed.* = .{ .child = child, .allocator = allocator };
    const thread = std.Thread.spawn(.{}, Box.wait, .{boxed}) catch null;
    if (thread) |handle| handle.detach() else allocator.destroy(boxed);

    std.time.sleep(400 * std.time.ns_per_ms);
    if (!pidAlive(pid)) {
        std.fs.deleteFileAbsolute(paths.pid) catch {};
        if (risk_started) _ = stopPid(allocator, paths.risk_pid);
        const tail = tailFile(allocator, paths.caddy_log, 80) catch null;
        return .{
            .ok = false,
            .output = if (tail) |value|
                try std.fmt.allocPrint(allocator, "进程启动后退出。\n{s}", .{value.content})
            else
                "进程启动后退出，请查看日志。",
        };
    }

    return .{
        .ok = true,
        .output = try std.fmt.allocPrint(
            allocator,
            "WAF 已启动：监听 {s}:{d} → 上游 {s}:{d}（{s}）",
            .{ config.listen_host, config.listen_port, config.upstream_host, config.upstream_port, config.mode },
        ),
    };
}

pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    _ = stopPid(allocator, paths.risk_pid);
    const pid = readPid(allocator, paths.pid) orelse return .{ .ok = true, .output = "WAF 未在运行" };
    if (!pidAlive(pid)) {
        std.fs.deleteFileAbsolute(paths.pid) catch {};
        return .{ .ok = true, .output = "WAF 未在运行" };
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    var waited: usize = 0;
    while (waited < 60) : (waited += 1) {
        std.time.sleep(100 * std.time.ns_per_ms);
        if (!pidAlive(pid)) {
            std.fs.deleteFileAbsolute(paths.pid) catch {};
            return .{ .ok = true, .output = "WAF 已停止" };
        }
    }
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    std.fs.deleteFileAbsolute(paths.pid) catch {};
    return .{ .ok = true, .output = "WAF 已强制停止" };
}

pub fn logs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    const paths = try buildPaths(allocator, data_dir);
    const content = tailFile(allocator, paths.access_log, lines) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = paths.access_log, .content = "", .truncated = false },
        else => return err,
    };
    return .{ .path = paths.access_log, .content = content.content, .truncated = content.truncated };
}

const Paths = struct {
    root: []const u8,
    bin_dir: []const u8,
    binary: []const u8,
    config: []const u8,
    caddyfile: []const u8,
    pid: []const u8,
    caddy_log: []const u8,
    access_log: []const u8,
    coraza_audit: []const u8,
    risk_bin: []const u8,
    risk_config: []const u8,
    risk_pid: []const u8,
    risk_log: []const u8,
    typesafe_cred: []const u8,
    geo_dir: []const u8,
    geo_meta: []const u8,
    risk_source: []const u8,
};

fn buildPaths(allocator: std.mem.Allocator, data_dir: []const u8) !Paths {
    const root = try std.fs.path.join(allocator, &.{ data_dir, "waf" });
    const bin_dir = try std.fs.path.join(allocator, &.{ root, "bin" });
    return .{
        .root = root,
        .bin_dir = bin_dir,
        .binary = try std.fs.path.join(allocator, &.{ bin_dir, "caddy-waf" }),
        .config = try std.fs.path.join(allocator, &.{ root, "config.json" }),
        .caddyfile = try std.fs.path.join(allocator, &.{ root, "Caddyfile" }),
        .pid = try std.fs.path.join(allocator, &.{ root, "waf.pid" }),
        .caddy_log = try std.fs.path.join(allocator, &.{ root, "caddy.log" }),
        .access_log = try std.fs.path.join(allocator, &.{ root, "access.log" }),
        .coraza_audit = try std.fs.path.join(allocator, &.{ root, "coraza-audit.log" }),
        .risk_bin = try std.fs.path.join(allocator, &.{ bin_dir, "hampanel-risk" }),
        .risk_config = try std.fs.path.join(allocator, &.{ root, "risk.json" }),
        .risk_pid = try std.fs.path.join(allocator, &.{ root, "risk.pid" }),
        .risk_log = try std.fs.path.join(allocator, &.{ root, "risk.log" }),
        .typesafe_cred = try std.fs.path.join(allocator, &.{ root, "typesafe.cred" }),
        .geo_dir = try std.fs.path.join(allocator, &.{ root, "geo" }),
        .geo_meta = try std.fs.path.join(allocator, &.{ root, "geo", "meta" }),
        .risk_source = try std.fs.path.join(allocator, &.{ root, "risk", "main.go" }),
    };
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return std.json.parseFromSliceLeaky(Config, allocator, raw, .{ .ignore_unknown_fields = true });
}

fn validateConfig(config: Config) !void {
    if (!std.mem.eql(u8, config.mode, "off") and
        !std.mem.eql(u8, config.mode, "detect") and
        !std.mem.eql(u8, config.mode, "enforce"))
    {
        return error.InvalidMode;
    }
    if (config.listen_port == 0 or config.upstream_port == 0) return error.InvalidPort;
    _ = std.net.Address.parseIp(config.listen_host, config.listen_port) catch return error.InvalidListenHost;
    if (!validHost(config.upstream_host)) return error.InvalidUpstream;
    if (config.risk_enabled) {
        if (config.risk_port == 0 or config.risk_port == config.listen_port) return error.InvalidPort;
        if (!_validEndpoint(config.typesafe_endpoint)) return error.InvalidTypeSafe;
        if (config.typesafe_model.len == 0 or config.typesafe_model.len > 128) return error.InvalidTypeSafe;
        if (config.typesafe_threshold <= 0 or config.typesafe_threshold > 1) return error.InvalidTypeSafe;
        if (config.typesafe_timeout_ms < 50 or config.typesafe_timeout_ms > 5000) return error.InvalidTypeSafe;
        for (config.geoip_rules) |rule| try validateGeoRule(rule);
        for (config.geosite_rules) |rule| try validateGeoRule(rule);
    }
    if (!std.mem.eql(u8, config.tls_mode, "internal") and !std.mem.eql(u8, config.tls_mode, "acme")) return error.InvalidTLS;
    if (config.tls_enabled and std.mem.eql(u8, config.tls_mode, "acme") and config.tls_email.len == 0) return error.InvalidTLS;
    for (config.routes) |route| {
        if (route.name.len == 0 or route.name.len > 64) return error.InvalidRoute;
        if (route.hosts.len == 0) return error.InvalidRoute;
        if (!validHost(route.upstream_host)) return error.InvalidRoute;
        if (route.upstream_port == 0) return error.InvalidRoute;
        if (!std.mem.eql(u8, route.mode, "inherit") and !std.mem.eql(u8, route.mode, "off") and
            !std.mem.eql(u8, route.mode, "detect") and !std.mem.eql(u8, route.mode, "enforce"))
            return error.InvalidRoute;
        for (route.hosts) |host| {
            if (host.len == 0 or host.len > 253) return error.InvalidRoute;
            for (host) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '*' and ch != '_')
                    return error.InvalidRoute;
            }
        }
    }
    if (config.routes.len > 64) return error.InvalidRoute;
}

fn _validEndpoint(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "https://") and !std.mem.startsWith(u8, value, "http://")) return false;
    return value.len > 10;
}

fn validateGeoRule(rule: GeoRule) !void {
    if (rule.tag.len == 0 or rule.tag.len > 128) return error.InvalidGeoRule;
    for (rule.tag) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return error.InvalidGeoRule;
    }
    if (!std.mem.eql(u8, rule.action, "allow") and !std.mem.eql(u8, rule.action, "deny")) return error.InvalidGeoRule;
}

fn validHost(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn renderCaddyfile(allocator: std.mem.Allocator, paths_value: Paths, config: Config) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    const writer = out.writer();

    try writer.print(
        \\{{
        \\    admin off
        \\    default_bind {s}
        \\    order coraza_waf first
        \\
    , .{config.listen_host});
    if (!config.tls_enabled) {
        try writer.writeAll("    auto_https off\n");
    } else {
        try writer.writeAll("    auto_https disable_redirects\n");
    }
    if (config.tls_enabled and config.tls_email.len > 0) {
        try writer.print("    email {s}\n", .{config.tls_email});
    }
    try writer.print(
        \\    log {{
        \\        output file "{s}"
        \\    }}
        \\}}
        \\
    , .{paths_value.caddy_log});

    if (config.routes.len == 0) {
        try renderSite(writer, allocator, paths_value, config, &.{}, config.mode, null);
    } else {
        for (config.routes) |route| {
            const mode = if (std.mem.eql(u8, route.mode, "inherit")) config.mode else route.mode;
            try renderSite(writer, allocator, paths_value, config, route.hosts, mode, route);
        }
        if (!config.tls_enabled) {
            try renderSite(writer, allocator, paths_value, config, &.{}, config.mode, null);
        }
    }
    return out.toOwnedSlice();
}

fn renderSite(
    writer: anytype,
    allocator: std.mem.Allocator,
    paths_value: Paths,
    config: Config,
    hosts: []const []const u8,
    mode: []const u8,
    route: ?Route,
) !void {
    const scheme = if (config.tls_enabled) "https" else "http";
    const default_port: u16 = if (config.tls_enabled) 443 else 80;
    var addresses = std.ArrayList(u8).init(allocator);
    if (hosts.len == 0) {
        if (config.tls_enabled) return;
        try addresses.writer().print("http://:{d}", .{config.listen_port});
    } else {
        for (hosts, 0..) |host, index| {
            if (index > 0) try addresses.appendSlice(", ");
            if (config.listen_port == default_port)
                try addresses.writer().print("{s}://{s}", .{ scheme, host })
            else
                try addresses.writer().print("{s}://{s}:{d}", .{ scheme, host, config.listen_port });
        }
    }

    try writer.print("{s} {{\n", .{addresses.items});
    if (config.tls_enabled and std.mem.eql(u8, config.tls_mode, "internal")) {
        try writer.writeAll("    tls internal\n");
    }
    if (!std.mem.eql(u8, mode, "off")) {
        const engine = if (std.mem.eql(u8, mode, "enforce")) "On" else "DetectionOnly";
        try writer.print(
            \\    coraza_waf {{
            \\        load_owasp_crs
            \\        directives `
            \\            Include @coraza.conf-recommended
            \\            Include @crs-setup.conf.example
            \\            Include @owasp_crs/*.conf
            \\            SecRuleEngine {s}
            \\            SecAuditEngine RelevantOnly
            \\            SecAuditLogRelevantStatus "^(?:5|4)"
            \\            SecAuditLogParts ABIJDEFHZ
            \\            SecAuditLogType Serial
            \\            SecAuditLog {s}
            \\        `
            \\    }}
            \\
        , .{ engine, paths_value.coraza_audit });
    }
    if (config.risk_enabled) {
        try writer.print(
            \\    reverse_proxy 127.0.0.1:{d} {{
            \\        header_up Host {{host}}
            \\    }}
            \\
        , .{config.risk_port});
    } else if (route) |r| {
        try writer.print(
            \\    reverse_proxy {s}:{d} {{
            \\        header_up Host {{host}}
            \\    }}
            \\
        , .{ r.upstream_host, r.upstream_port });
    } else {
        try writer.print(
            \\    reverse_proxy {s}:{d} {{
            \\        header_up Host {{host}}
            \\    }}
            \\
        , .{ config.upstream_host, config.upstream_port });
    }
    try writer.print(
        \\    log {{
        \\        output file "{s}"
        \\    }}
        \\}}
        \\
    , .{paths_value.access_log});
}

const RiskTypeSafe = struct {
    enabled: bool,
    endpoint: []const u8,
    model: []const u8,
    credential: []const u8,
    credential_name: []const u8,
    threshold: f64,
    timeout_ms: u16,
    fail_open: bool,
    instructions: []const u8,
    inspect_methods: []const []const u8,
};

const RiskRoute = struct {
    name: []const u8,
    hosts: []const []const u8,
    upstream: []const u8,
    mode: []const u8,
};

const RiskGeo = struct {
    enabled: bool,
    mode: []const u8,
    data_dir: []const u8,
    geoip: []const GeoRule,
    geosite: []const GeoRule,
};

const RiskConfig = struct {
    listen: []const u8,
    upstream: []const u8,
    mode: []const u8,
    max_body_bytes: u32,
    log_path: []const u8,
    typesafe: RiskTypeSafe,
    geo: RiskGeo,
    routes: []const RiskRoute,
};

fn writeRiskConfig(allocator: std.mem.Allocator, paths_value: Paths, config: Config) !void {
    const listen = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{config.risk_port});
    const upstream = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ config.upstream_host, config.upstream_port });
    var risk_routes = std.ArrayList(RiskRoute).init(allocator);
    for (config.routes) |route| {
        const route_mode = if (std.mem.eql(u8, route.mode, "inherit")) config.mode else route.mode;
        try risk_routes.append(.{
            .name = route.name,
            .hosts = route.hosts,
            .upstream = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ route.upstream_host, route.upstream_port }),
            .mode = route_mode,
        });
    }
    const risk = RiskConfig{
        .listen = listen,
        .upstream = upstream,
        .mode = if (std.mem.eql(u8, config.mode, "enforce")) "enforce" else "detect",
        .max_body_bytes = 65536,
        .log_path = paths_value.risk_log,
        .typesafe = .{
            .enabled = config.typesafe_enabled,
            .endpoint = config.typesafe_endpoint,
            .model = config.typesafe_model,
            .credential = if (fileExists(paths_value.typesafe_cred)) paths_value.typesafe_cred else "",
            .credential_name = "hampanel-typesafe",
            .threshold = config.typesafe_threshold,
            .timeout_ms = config.typesafe_timeout_ms,
            .fail_open = config.typesafe_fail_open,
            .instructions = "Is this HTTP request malicious, an exploit attempt, or abusive automation?",
            .inspect_methods = &[_][]const u8{ "POST", "PUT", "PATCH", "DELETE" },
        },
        .geo = .{
            .enabled = config.geoip_rules.len > 0 or config.geosite_rules.len > 0,
            .mode = if (std.mem.eql(u8, config.mode, "enforce")) "enforce" else "detect",
            .data_dir = paths_value.geo_dir,
            .geoip = config.geoip_rules,
            .geosite = config.geosite_rules,
        },
        .routes = risk_routes.items,
    };
    const json = try std.json.stringifyAlloc(allocator, risk, .{ .whitespace = .indent_2 });
    try writeFile(paths_value.risk_config, json, 0o600);
}

fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8, pid_path: []const u8) !std.posix.pid_t {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const pid = child.id;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    try writeFile(pid_path, pid_text, 0o600);
    const Box = struct {
        child: std.process.Child,
        allocator: std.mem.Allocator,
        fn wait(self: *@This()) void {
            _ = self.child.wait() catch {};
            self.allocator.destroy(self);
        }
    };
    const boxed = allocator.create(Box) catch return pid;
    boxed.* = .{ .child = child, .allocator = allocator };
    const thread = std.Thread.spawn(.{}, Box.wait, .{boxed}) catch null;
    if (thread) |handle| handle.detach() else allocator.destroy(boxed);
    return pid;
}

fn startRisk(allocator: std.mem.Allocator, paths_value: Paths, config: Config) !Outcome {
    if (!config.risk_enabled) return .{ .ok = true, .output = "" };
    if (!fileExists(paths_value.risk_bin)) return error.RiskNotBuilt;
    try writeRiskConfig(allocator, paths_value, config);
    const argv = [_][]const u8{ paths_value.risk_bin, "-config", paths_value.risk_config };
    const pid = spawnDetached(allocator, &argv, paths_value.risk_pid) catch |err| {
        return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "risk gateway 启动失败：{s}", .{@errorName(err)}) };
    };
    var waited: usize = 0;
    while (waited < 60) : (waited += 1) {
        std.time.sleep(100 * std.time.ns_per_ms);
        if (!pidAlive(pid)) {
            std.fs.deleteFileAbsolute(paths_value.risk_pid) catch {};
            const tail = tailFile(allocator, paths_value.risk_log, 60) catch null;
            return .{ .ok = false, .output = if (tail) |value| value.content else "risk gateway 启动后退出" };
        }
        if (std.net.tcpConnectToHost(allocator, "127.0.0.1", config.risk_port)) |stream| {
            stream.close();
            return .{ .ok = true, .output = "risk gateway 已启动" };
        } else |_| {}
    }
    _ = stopPid(allocator, paths_value.risk_pid);
    return .{ .ok = false, .output = "risk gateway 在 6 秒内未监听配置端口" };
}

fn stopPid(allocator: std.mem.Allocator, pid_path: []const u8) Outcome {
    _ = allocator;
    const pid = readPid(std.heap.page_allocator, pid_path) orelse return .{ .ok = true, .output = "未在运行" };
    if (!pidAlive(pid)) {
        std.fs.deleteFileAbsolute(pid_path) catch {};
        return .{ .ok = true, .output = "未在运行" };
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        std.time.sleep(100 * std.time.ns_per_ms);
        if (!pidAlive(pid)) {
            std.fs.deleteFileAbsolute(pid_path) catch {};
            return .{ .ok = true, .output = "已停止" };
        }
    }
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    std.fs.deleteFileAbsolute(pid_path) catch {};
    return .{ .ok = true, .output = "已强制停止" };
}

fn validateCaddyfile(allocator: std.mem.Allocator, binary: []const u8, caddyfile: []const u8) !Outcome {
    const result = exec.run(allocator, &.{ binary, "validate", "--config", caddyfile, "--adapter", "caddyfile" }, max_output) catch
        return .{ .ok = false, .output = "无法执行 caddy-waf" };
    return .{ .ok = result.ok(), .output = if (result.ok()) "" else textOf(result) };
}

fn restore(allocator: std.mem.Allocator, path: []const u8, previous: ?[]u8) void {
    _ = allocator;
    if (previous) |contents| {
        writeFile(path, contents, 0o600) catch {};
    } else {
        std.fs.deleteFileAbsolute(path) catch {};
    }
}

fn writeFile(path: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = mode });
    defer file.close();
    try file.writeAll(data);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readPid(allocator: std.mem.Allocator, path: []const u8) ?std.posix.pid_t {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 128) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
}

fn isRunning(allocator: std.mem.Allocator, pid_path: []const u8) bool {
    const pid = readPid(allocator, pid_path) orelse return false;
    return pidAlive(pid);
}

fn pidAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch |err| switch (err) {
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

const Tail = struct { content: []const u8, truncated: bool };

fn tailFile(allocator: std.mem.Allocator, path: []const u8, lines: usize) !Tail {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const window: u64 = @min(size, 512 * 1024);
    if (window == 0) return .{ .content = "", .truncated = false };
    try file.seekFromEnd(-@as(i64, @intCast(window)));
    const buffer = try allocator.alloc(u8, window);
    const read = try file.readAll(buffer);
    var items = std.ArrayList([]const u8).init(allocator);
    var iterator = std.mem.splitScalar(u8, buffer[0..read], '\n');
    while (iterator.next()) |line| try items.append(line);
    const wanted = std.math.clamp(lines, 1, 2000);
    const offset = if (items.items.len > wanted) items.items.len - wanted else 0;
    return .{
        .content = try std.mem.join(allocator, "\n", items.items[offset..]),
        .truncated = size > window,
    };
}

pub fn setTypesafeKey(allocator: std.mem.Allocator, data_dir: []const u8, key: []const u8) !Outcome {
    if (key.len < 8 or key.len > 512) return error.InvalidKey;
    for (key) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidKey;
    }
    const paths = try buildPaths(allocator, data_dir);
    try std.fs.cwd().makePath(paths.root);
    const temp = try std.fmt.allocPrint(allocator, "{s}/.typesafe.tmp", .{paths.root});
    defer std.fs.deleteFileAbsolute(temp) catch {};
    try writeFile(temp, key, 0o600);
    const result = exec.run(allocator, &.{ "systemd-creds", "encrypt", "--name=hampanel-typesafe", temp, paths.typesafe_cred }, 1024 * 1024) catch
        return error.SystemdCredsUnavailable;
    if (!result.ok()) return .{ .ok = false, .output = textOf(result) };
    std.posix.fchmodat(std.posix.AT.FDCWD, paths.typesafe_cred, 0o600, 0) catch {};
    if (isRunning(allocator, paths.pid)) {
        _ = stop(allocator, data_dir) catch {};
        const restarted = start(allocator, data_dir) catch return .{ .ok = true, .output = "密钥已加密保存；请重新启动 WAF 使其生效" };
        return .{ .ok = restarted.ok, .output = try std.fmt.allocPrint(allocator, "密钥已加密保存。{s}", .{restarted.output}) };
    }
    return .{ .ok = true, .output = "TypeSafe 密钥已使用 systemd-creds 加密保存" };
}

pub fn clearTypesafeKey(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    std.fs.deleteFileAbsolute(paths.typesafe_cred) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = true, .output = "没有已保存的密钥" },
        else => return err,
    };
    return .{ .ok = true, .output = "TypeSafe 密钥已删除" };
}

pub const Country = struct { code: []const u8, name: []const u8 };
pub const GeoSiteService = struct { id: []const u8, name: []const u8, category: []const u8, src: []const u8 };
pub const GeoCatalog = struct { countries: []Country, geosite: []GeoSiteService, updated_at: []const u8 };

const CatalogFile = struct {
    base: []const u8 = "",
    generated: []const u8 = "",
    services: []const struct {
        id: []const u8,
        name: []const u8,
        cat: []const u8 = "",
        src: []const u8,
    },
};

pub fn geoCatalog(allocator: std.mem.Allocator, data_dir: []const u8, refresh: bool) !GeoCatalog {
    const paths = try buildPaths(allocator, data_dir);
    try std.fs.cwd().makePath(paths.geo_meta);
    try ensureCatalog(allocator, paths, refresh);
    const catalog_path = try std.fs.path.join(allocator, &.{ paths.geo_meta, "catalog.json" });
    const raw = try std.fs.cwd().readFileAlloc(allocator, catalog_path, 16 * 1024 * 1024);
    const parsed = try std.json.parseFromSliceLeaky(CatalogFile, allocator, raw, .{ .ignore_unknown_fields = true });
    var services = std.ArrayList(GeoSiteService).init(allocator);
    for (parsed.services) |service| {
        if (!std.mem.startsWith(u8, service.src, "source1/")) continue;
        try services.append(.{ .id = service.id, .name = service.name, .category = service.cat, .src = service.src });
    }
    var countries = std.ArrayList(Country).init(allocator);
    for (country_list) |item| try countries.append(item);
    return .{
        .countries = countries.items,
        .geosite = services.items,
        .updated_at = parsed.generated,
    };
}

pub fn downloadGeoRules(allocator: std.mem.Allocator, data_dir: []const u8, geoip: []const GeoRule, geosite: []const GeoRule) !Outcome {
    if (geoip.len == 0 and geosite.len == 0) return .{ .ok = true, .output = "" };
    const paths = try buildPaths(allocator, data_dir);
    try std.fs.cwd().makePath(paths.geo_dir);
    try ensureCatalog(allocator, paths, false);
    const catalog_path = try std.fs.path.join(allocator, &.{ paths.geo_meta, "catalog.json" });
    const raw = try std.fs.cwd().readFileAlloc(allocator, catalog_path, 16 * 1024 * 1024);
    const catalog = try std.json.parseFromSliceLeaky(CatalogFile, allocator, raw, .{ .ignore_unknown_fields = true });

    var messages = std.ArrayList(u8).init(allocator);
    for (geoip) |rule| {
        if (rule.tag.len != 2) continue;
        const url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/Ground-Zerro/Geo-Aggregator/main/source2/{s}.txt", .{rule.tag});
        const path = try std.fmt.allocPrint(allocator, "{s}/geoip-{s}.txt", .{ paths.geo_dir, rule.tag });
        const result = try downloadFile(allocator, url, path);
        if (!result.ok) return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "下载 GeoIP {s} 失败：{s}", .{ rule.tag, result.output }) };
        try messages.writer().print("geoip:{s}\n", .{rule.tag});
    }
    for (geosite) |rule| {
        var source: ?[]const u8 = null;
        for (catalog.services) |service| {
            if (std.mem.eql(u8, service.id, rule.tag)) {
                if (!std.mem.startsWith(u8, service.src, "source1/")) {
                    return .{ .ok = false, .output = "GeoSite 规则只能选择 source1 域名分类" };
                }
                source = try std.fmt.allocPrint(allocator, "{s}{s}", .{ catalog.base, service.src });
                break;
            }
        }
        const url = source orelse try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/Ground-Zerro/Geo-Aggregator/main/source1/{s}.txt", .{rule.tag});
        const path = try std.fmt.allocPrint(allocator, "{s}/geosite-{s}.txt", .{ paths.geo_dir, rule.tag });
        const result = try downloadFile(allocator, url, path);
        if (!result.ok) return .{ .ok = false, .output = try std.fmt.allocPrint(allocator, "下载 GeoSite {s} 失败：{s}", .{ rule.tag, result.output }) };
        try messages.writer().print("geosite:{s}\n", .{rule.tag});
    }
    return .{ .ok = true, .output = messages.items };
}

fn ensureCatalog(allocator: std.mem.Allocator, paths_value: Paths, refresh: bool) !void {
    const catalog_path = try std.fs.path.join(allocator, &.{ paths_value.geo_meta, "catalog.json" });
    const database_path = try std.fs.path.join(allocator, &.{ paths_value.geo_meta, "database.json" });
    if (!refresh and fileExists(catalog_path) and fileExists(database_path)) return;
    try std.fs.cwd().makePath(paths_value.geo_meta);
    const base = "https://raw.githubusercontent.com/Ground-Zerro/Geo-Aggregator/main/";
    const catalog_url = try std.fmt.allocPrint(allocator, "{s}db/catalog.json", .{base});
    const database_url = try std.fmt.allocPrint(allocator, "{s}db/database.json", .{base});
    const catalog_result = try downloadFile(allocator, catalog_url, catalog_path);
    if (!catalog_result.ok) return error.CatalogDownloadFailed;
    const database_result = try downloadFile(allocator, database_url, database_path);
    if (!database_result.ok) return error.CatalogDownloadFailed;
}

fn downloadFile(allocator: std.mem.Allocator, url: []const u8, path: []const u8) !Outcome {
    const temp = try std.fmt.allocPrint(allocator, "{s}.part", .{path});
    defer std.fs.deleteFileAbsolute(temp) catch {};
    const result = exec.run(allocator, &.{ "curl", "-fsSL", "--max-time", "60", "-o", temp, url }, 1024 * 1024) catch {
        return .{ .ok = false, .output = "curl 不可用" };
    };
    if (!result.ok()) return .{ .ok = false, .output = textOf(result) };
    const stat = std.fs.cwd().statFile(temp) catch return .{ .ok = false, .output = "下载文件为空" };
    if (stat.size == 0) return .{ .ok = false, .output = "下载文件为空" };
    std.fs.renameAbsolute(temp, path) catch |err| return .{ .ok = false, .output = @errorName(err) };
    return .{ .ok = true, .output = "" };
}

pub fn auditLogs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    const paths = try buildPaths(allocator, data_dir);
    const content = tailFile(allocator, paths.coraza_audit, 512 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = paths.coraza_audit, .content = "", .truncated = false },
        else => return err,
    };
    return .{
        .path = paths.coraza_audit,
        .content = try auditSummary(allocator, content.content, lines),
        .truncated = content.truncated,
    };
}

fn auditSummary(allocator: std.mem.Allocator, raw: []const u8, limit: usize) ![]const u8 {
    var entries = std.ArrayList([]const u8).init(allocator);
    var rules = std.ArrayList(u8).init(allocator);
    var timestamp: []const u8 = "";
    var client: []const u8 = "";
    var request_line: []const u8 = "";
    var section: u8 = 0;
    var in_tx = false;

    var raw_lines = std.mem.splitScalar(u8, raw, '\n');
    while (raw_lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len >= 5 and std.mem.startsWith(u8, line, "--") and std.mem.endsWith(u8, line, "--")) {
            const letter = line[line.len - 3];
            if (letter == 'A') {
                timestamp = "";
                client = "";
                request_line = "";
                rules.clearRetainingCapacity();
                in_tx = true;
            }
            section = letter;
            if (letter == 'Z') {
                if (in_tx and (request_line.len > 0 or rules.items.len > 0)) {
                    const request = if (request_line.len > 160) request_line[0..160] else request_line;
                    const summary = try std.fmt.allocPrint(allocator, "{s}  {s}  {s}  =>  {s}", .{
                        if (timestamp.len > 0) timestamp else "-",
                        if (client.len > 0) client else "-",
                        if (request.len > 0) request else "-",
                        if (rules.items.len > 0) rules.items else "no-rule",
                    });
                    try entries.append(summary);
                }
                in_tx = false;
            }
            continue;
        }
        if (!in_tx) continue;
        if (section == 'A') {
            if (std.mem.indexOfScalar(u8, line, ']')) |close| {
                timestamp = std.mem.trim(u8, line[1..@min(close, line.len)], " \t");
                var meta = std.mem.tokenizeAny(u8, line[@min(close + 1, line.len)..], " \t");
                _ = meta.next();
                if (meta.next()) |value| client = value;
            }
        } else if (section == 'B') {
            if (request_line.len == 0 and line.len > 0) request_line = std.mem.trim(u8, line, " \t");
        } else if (section == 'H') {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, "[id \"")) |id_start| {
                const value_start = id_start + 5;
                const id_end = std.mem.indexOfPos(u8, line, value_start, "\"]") orelse break;
                const id = line[value_start..id_end];
                if (std.mem.indexOf(u8, rules.items, id) == null) {
                    if (rules.items.len > 0) try rules.append(' ');
                    try rules.appendSlice(id);
                }
                pos = id_end + 2;
            }
        }
    }
    const offset = if (entries.items.len > limit) entries.items.len - limit else 0;
    return std.mem.join(allocator, "\n", entries.items[offset..]);
}

pub fn riskLogs(allocator: std.mem.Allocator, data_dir: []const u8, lines: usize) !Logs {
    const paths = try buildPaths(allocator, data_dir);
    const content = tailFile(allocator, paths.risk_log, lines) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = paths.risk_log, .content = "", .truncated = false },
        else => return err,
    };
    return .{ .path = paths.risk_log, .content = content.content, .truncated = content.truncated };
}

const country_list = [_]Country{
    .{ .code = "us", .name = "美国 US" },       .{ .code = "cn", .name = "中国 CN" },
    .{ .code = "ru", .name = "俄罗斯 RU" },    .{ .code = "de", .name = "德国 DE" },
    .{ .code = "fr", .name = "法国 FR" },       .{ .code = "gb", .name = "英国 GB" },
    .{ .code = "jp", .name = "日本 JP" },       .{ .code = "kr", .name = "韩国 KR" },
    .{ .code = "sg", .name = "新加坡 SG" },    .{ .code = "hk", .name = "香港 HK" },
    .{ .code = "tw", .name = "台湾 TW" },       .{ .code = "ca", .name = "加拿大 CA" },
    .{ .code = "au", .name = "澳大利亚 AU" }, .{ .code = "in", .name = "印度 IN" },
    .{ .code = "br", .name = "巴西 BR" },       .{ .code = "nl", .name = "荷兰 NL" },
    .{ .code = "se", .name = "瑞典 SE" },       .{ .code = "ch", .name = "瑞士 CH" },
    .{ .code = "it", .name = "意大利 IT" },    .{ .code = "es", .name = "西班牙 ES" },
    .{ .code = "pl", .name = "波兰 PL" },       .{ .code = "tr", .name = "土耳其 TR" },
    .{ .code = "vn", .name = "越南 VN" },       .{ .code = "th", .name = "泰国 TH" },
    .{ .code = "id", .name = "印尼 ID" },       .{ .code = "my", .name = "马来西亚 MY" },
    .{ .code = "ae", .name = "阿联酋 AE" },    .{ .code = "sa", .name = "沙特 SA" },
    .{ .code = "za", .name = "南非 ZA" },       .{ .code = "mx", .name = "墨西哥 MX" },
};

fn buildInfo(allocator: std.mem.Allocator, binary: []const u8) []const u8 {
    const result = exec.run(allocator, &.{ binary, "build-info" }, 2 * 1024 * 1024) catch return "OWASP CRS（内嵌）";
    var crs: []const u8 = "";
    var caddy_module: []const u8 = "";
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "coraza-coreruleset") != null) {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next();
            _ = fields.next();
            if (fields.next()) |version| crs = version;
        } else if (std.mem.indexOf(u8, line, "coraza-caddy") != null) {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next();
            _ = fields.next();
            if (fields.next()) |version| caddy_module = version;
        }
    }
    if (crs.len == 0) return "OWASP CRS（内嵌）";
    return std.fmt.allocPrint(allocator, "OWASP CRS {s} · coraza-caddy {s}", .{ crs, if (caddy_module.len > 0) caddy_module else "unknown" }) catch "OWASP CRS（内嵌）";
}

fn textOf(result: exec.Result) []const u8 {
    const primary = if (result.stderr.len > 0) result.stderr else result.stdout;
    const trimmed = std.mem.trim(u8, primary, " \t\r\n");
    return if (trimmed.len > 0) trimmed else "command failed";
}
