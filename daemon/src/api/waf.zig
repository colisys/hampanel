const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const errutil = @import("../util/errors.zig");

pub fn status(ctx: *context.Context) anyerror!void {
    const value = platform.waf.status(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(value);
}

pub fn install(ctx: *context.Context) anyerror!void {
    const outcome = platform.waf.install(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(outcome);
}

pub fn configure(ctx: *context.Context) anyerror!void {
    const Body = struct {
        mode: []const u8,
        listen_host: []const u8,
        listen_port: u16,
        upstream_host: []const u8,
        upstream_port: u16,
        risk_enabled: bool = true,
        risk_port: u16 = 18092,
        typesafe_enabled: bool = false,
        typesafe_endpoint: []const u8 = "https://api.typesafe.ai/v1/systemone",
        typesafe_model: []const u8 = "jev-latest",
        typesafe_threshold: f64 = 0.85,
        typesafe_timeout_ms: u16 = 800,
        typesafe_fail_open: bool = true,
        geoip_rules: []const platform.waf.GeoRule = &.{},
        geosite_rules: []const platform.waf.GeoRule = &.{},
        routes: []const platform.waf.Route = &.{},
        tls_enabled: bool = false,
        tls_mode: []const u8 = "internal",
        tls_email: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected WAF configuration");
        return;
    };
    const outcome = platform.waf.configure(ctx.arena, ctx.app.config.data_dir, .{
        .mode = body.mode,
        .listen_host = body.listen_host,
        .listen_port = body.listen_port,
        .upstream_host = body.upstream_host,
        .upstream_port = body.upstream_port,
        .risk_enabled = body.risk_enabled,
        .risk_port = body.risk_port,
        .typesafe_enabled = body.typesafe_enabled,
        .typesafe_endpoint = body.typesafe_endpoint,
        .typesafe_model = body.typesafe_model,
        .typesafe_threshold = body.typesafe_threshold,
        .typesafe_timeout_ms = body.typesafe_timeout_ms,
        .typesafe_fail_open = body.typesafe_fail_open,
        .geoip_rules = body.geoip_rules,
        .geosite_rules = body.geosite_rules,
        .routes = body.routes,
        .tls_enabled = body.tls_enabled,
        .tls_mode = body.tls_mode,
        .tls_email = body.tls_email,
    }) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 400;
    try ctx.json(outcome);
}

pub fn start(ctx: *context.Context) anyerror!void {
    const outcome = platform.waf.start(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    try ctx.json(outcome);
}

pub fn stop(ctx: *context.Context) anyerror!void {
    const outcome = platform.waf.stop(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(outcome);
}

pub fn setTypesafeKey(ctx: *context.Context) anyerror!void {
    const Body = struct { api_key: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected api_key");
        return;
    };
    const outcome = platform.waf.setTypesafeKey(ctx.arena, ctx.app.config.data_dir, body.api_key) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(outcome);
}

pub fn clearTypesafeKey(ctx: *context.Context) anyerror!void {
    const outcome = platform.waf.clearTypesafeKey(ctx.arena, ctx.app.config.data_dir) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(outcome);
}

pub fn geoCatalog(ctx: *context.Context) anyerror!void {
    const refresh = if (try ctx.query("refresh")) |value| std.mem.eql(u8, value, "1") else false;
    const catalog = platform.waf.geoCatalog(ctx.arena, ctx.app.config.data_dir, refresh) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(catalog);
}

pub fn logs(ctx: *context.Context) anyerror!void {
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }
    const source = (try ctx.query("source")) orelse "access";
    const value = if (std.mem.eql(u8, source, "risk"))
        platform.waf.riskLogs(ctx.arena, ctx.app.config.data_dir, lines) catch |err| {
            fail(ctx, err);
            return;
        }
    else if (std.mem.eql(u8, source, "audit"))
        platform.waf.auditLogs(ctx.arena, ctx.app.config.data_dir, lines) catch |err| {
            fail(ctx, err);
            return;
        }
    else
        platform.waf.logs(ctx.arena, ctx.app.config.data_dir, lines) catch |err| {
            fail(ctx, err);
            return;
        };
    try ctx.json(value);
}

fn fail(ctx: *context.Context, err: anyerror) void {
    if (errutil.named(err, "InvalidMode") or
        errutil.named(err, "InvalidPort") or
        errutil.named(err, "InvalidListenHost") or
        errutil.named(err, "InvalidUpstream"))
    {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "NotInstalled")) {
        ctx.fail(409, "not_installed", "请先构建 Caddy+Coraza");
    } else if (errutil.named(err, "ModeOff")) {
        ctx.fail(400, "mode_off", "WAF 模式为 off，不会启动边缘");
    } else if (errutil.named(err, "GoUnavailable")) {
        ctx.fail(501, "go_unavailable", "服务器未安装 Go，无法用 xcaddy 构建 Caddy");
    } else if (errutil.named(err, "InvalidTypeSafe") or
        errutil.named(err, "InvalidKey") or
        errutil.named(err, "InvalidGeoRule"))
    {
        ctx.fail(400, "bad_input", @errorName(err));
    } else if (errutil.named(err, "RiskNotBuilt")) {
        ctx.fail(409, "risk_not_built", "risk gateway 未构建，请重新安装 WAF");
    } else if (errutil.named(err, "SystemdCredsUnavailable")) {
        ctx.fail(501, "systemd_creds_unavailable", "systemd-creds 不可用，无法加密保存密钥");
    } else if (errutil.named(err, "CatalogDownloadFailed")) {
        ctx.fail(502, "geo_catalog_failed", "无法下载 Geo-Aggregator 目录");
    } else if (errutil.named(err, "BuildFailed")) {
        ctx.fail(502, "build_failed", "xcaddy 构建失败，请查看服务端日志");
    } else if (errutil.isUnsupported(err)) {
        ctx.fail(501, "unsupported", "WAF 边缘仅支持 Linux 远端");
    } else {
        ctx.fail(500, "waf_failed", @errorName(err));
    }
}
