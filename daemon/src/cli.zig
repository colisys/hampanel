const std = @import("std");
const builtin = @import("builtin");
const service = @import("windows_service");
const config = @import("config.zig");
const pki = @import("pki.zig");
const enroll = @import("enroll.zig");
const server = @import("server.zig");
const app_mod = @import("app.zig");
const tls = @import("tls.zig");
const audit = @import("audit.zig");
const log = @import("log.zig");
const version = @import("version.zig");
const validate = @import("shared").validate;

const Command = enum { run, init, enroll, version, help };

const Options = struct {
    command: Command = .help,
    config_path: []const u8 = config.default_path,
    listen: ?[]const u8 = null,
    port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    tls_dir: ?[]const u8 = null,
    enroll_file: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    entry_prefix: ?[]const u8 = null,
    out: ?[]const u8 = null,
    sans: std.ArrayList([]const u8),
    force: bool = false,
    json: bool = false,
    service: bool = false,
};

pub fn run(allocator: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = Options{ .sans = std.ArrayList([]const u8).init(allocator) };
    defer opts.sans.deinit();

    var index: usize = 1;
    if (index < args.len and args[index].len > 0 and args[index][0] != '-') {
        opts.command = parseCommand(args[index]) orelse {
            std.debug.print("unknown command: {s}\n\n", .{args[index]});
            printUsage();
            return 2;
        };
        index += 1;
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--config")) {
            opts.config_path = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            opts.listen = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = takeValue(args, &index, arg) orelse return 2;
            opts.port = std.fmt.parseInt(u16, raw, 10) catch {
                std.debug.print("invalid port: {s}\n", .{raw});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            opts.data_dir = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--enroll-file")) {
            opts.enroll_file = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--tls-dir")) {
            opts.tls_dir = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--endpoint")) {
            opts.endpoint = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--entry-prefix")) {
            opts.entry_prefix = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--out")) {
            opts.out = takeValue(args, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--san")) {
            const value = takeValue(args, &index, arg) orelse return 2;
            try opts.sans.append(value);
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--service")) {
            opts.service = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        } else {
            std.debug.print("unknown option: {s}\n\n", .{arg});
            printUsage();
            return 2;
        }
    }

    if (args.len == 1) {
        printUsage();
        return 0;
    }

    return switch (opts.command) {
        .help => blk: {
            printUsage();
            break :blk 0;
        },
        .version => blk: {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("hampaneld {s} (GPL-3.0-or-later)\n", .{version.version});
            break :blk 0;
        },
        .init => cmdInit(allocator, &opts),
        .enroll => cmdEnroll(allocator, &opts),
        .run => cmdRun(allocator, &opts),
    };
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "run")) return .run;
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "enroll")) return .enroll;
    if (std.mem.eql(u8, raw, "version")) return .version;
    if (std.mem.eql(u8, raw, "help")) return .help;
    return null;
}

fn takeValue(args: []const [:0]u8, index: *usize, flag: []const u8) ?[]const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        std.debug.print("missing value for {s}\n", .{flag});
        return null;
    }
    return args[index.*];
}

fn applyOverrides(cfg: *config.Config, opts: Options) void {
    if (opts.listen) |value| cfg.listen = value;
    if (opts.port) |value| cfg.port = value;
    if (opts.data_dir) |value| cfg.data_dir = value;
    if (opts.tls_dir) |value| cfg.tls_dir = value;
    if (opts.enroll_file) |value| cfg.enroll_file = value;
}

fn cmdInit(allocator: std.mem.Allocator, opts: *Options) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = try config.Config.load(a, opts.config_path);
    applyOverrides(&cfg, opts.*);
    log.setLevelName(cfg.log_level);

    const endpoint_raw = opts.endpoint orelse {
        std.debug.print("init requires --endpoint HOST[:PORT]\n", .{});
        return 2;
    };
    const pki_ready = pki.exists(a, cfg.tls_dir);
    const parts = parseEndpoint(endpoint_raw);
    if (parts.host.len == 0) {
        std.debug.print("invalid --endpoint: host is empty\n", .{});
        return 2;
    }

    var final_port: u16 = 0;
    if (opts.port) |value| {
        if (value > 0) final_port = value;
    }
    if (final_port == 0) {
        if (parts.port) |value| final_port = value;
    }
    if (final_port == 0) {
        if (pki_ready and cfg.port > 0) {
            final_port = cfg.port;
        } else {
            final_port = pickFreePort(cfg.listen) catch {
                std.debug.print("could not allocate a free TCP port\n", .{});
                return 1;
            };
        }
    }
    cfg.port = final_port;

    cfg.entry_prefix = if (opts.entry_prefix) |raw|
        normalizeEntryPrefix(a, raw) catch {
            std.debug.print("invalid --entry-prefix: use /<token> with letters, digits, '-' or '_'\n", .{});
            return 2;
        }
    else if (pki_ready and validate.isEntryPrefix(cfg.entry_prefix) and cfg.entry_prefix.len > 0)
        cfg.entry_prefix
    else
        try randomEntryPrefix(a);

    const endpoint = try formatEndpoint(a, parts.host, final_port);

    {
        var present = false;
        for (opts.sans.items) |existing| {
            if (std.mem.eql(u8, existing, parts.host)) present = true;
        }
        if (!present) try opts.sans.append(parts.host);
    }

    try std.fs.cwd().makePath(cfg.data_dir);
    try cfg.save(a, opts.config_path);

    const meta = try pki.initialize(a, cfg.tls_dir, endpoint, opts.sans.items, opts.force);
    const paths = try pki.paths(a, cfg.tls_dir);
    const bundle = try enroll.build(a, meta, paths, endpoint, cfg.entry_prefix);
    try enroll.save(a, bundle, cfg.enroll_file);

    std.debug.print("Hampanel initialized\n", .{});
    std.debug.print("  endpoint      : {s}\n", .{endpoint});
    std.debug.print("  entry prefix  : {s}\n", .{cfg.entry_prefix});
    std.debug.print("  mTLS URL      : https://{s}{s}/\n", .{ endpoint, cfg.entry_prefix });
    std.debug.print("  client CN     : {s}\n", .{meta.client_cn});
    std.debug.print("  CA SHA-256    : {s}\n", .{meta.ca_fingerprint});
    std.debug.print("  server SHA-256: {s}\n", .{meta.server_fingerprint});
    std.debug.print("  enrollment    : {s}\n", .{cfg.enroll_file});
    return 0;
}

fn cmdEnroll(allocator: std.mem.Allocator, opts: *Options) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = try config.Config.load(a, opts.config_path);
    applyOverrides(&cfg, opts.*);
    log.setLevelName(cfg.log_level);

    if (!pki.exists(a, cfg.tls_dir)) {
        std.debug.print("PKI not found in {s}; run `hampaneld init` first\n", .{cfg.tls_dir});
        return 1;
    }

    if (!validate.isEntryPrefix(cfg.entry_prefix)) {
        std.debug.print("configuration has an invalid entry_prefix: {s}\n", .{cfg.entry_prefix});
        return 1;
    }

    const paths = try pki.paths(a, cfg.tls_dir);
    const meta = try pki.loadMeta(a, paths);
    const bundle = try enroll.build(a, meta, paths, opts.endpoint, cfg.entry_prefix);

    const out_path = opts.out orelse cfg.enroll_file;
    try enroll.save(a, bundle, out_path);

    if (opts.json) {
        const json = try enroll.toJson(a, bundle);
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(json);
        try stdout.writeAll("\n");
    } else {
        std.debug.print("Enrollment bundle written to {s}\n", .{out_path});
        std.debug.print("  endpoint   : {s}\n", .{bundle.endpoint});
        std.debug.print("  entry prefix: {s}\n", .{bundle.entry_prefix});
        std.debug.print("  client CN  : {s}\n", .{bundle.client_cn});
        std.debug.print("  CA SHA-256 : {s}\n", .{bundle.ca_sha256});
    }
    return 0;
}

fn cmdRun(allocator: std.mem.Allocator, opts: *Options) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = try config.Config.load(a, opts.config_path);
    applyOverrides(&cfg, opts.*);
    log.setLevelName(cfg.log_level);

    if (!pki.exists(a, cfg.tls_dir)) {
        std.debug.print("PKI not found in {s}; run `hampaneld init --endpoint HOST` first\n", .{cfg.tls_dir});
        return 1;
    }
    if (!validate.isEntryPrefix(cfg.entry_prefix)) {
        std.debug.print("invalid entry_prefix in configuration: {s}\n", .{cfg.entry_prefix});
        return 1;
    }

    const paths = try pki.paths(a, cfg.tls_dir);
    var tls_context = try tls.Context.init(a, paths.server_cert, paths.server_key, paths.ca_cert);
    defer tls_context.deinit();

    const audit_log = try audit.Log.init(allocator, cfg.data_dir);
    var app = app_mod.App{
        .allocator = allocator,
        .config = cfg,
        .started_at = std.time.timestamp(),
        .tls = tls_context,
        .pki = paths,
        .audit = audit_log,
    };

    log.info("hampaneld {s} starting (GPL-3.0-or-later)", .{version.version});

    if (opts.service) {
        if (builtin.os.tag != .windows) {
            std.debug.print("--service is only supported on Windows\n", .{});
            return 2;
        }
        service_app = &app;
        service.run(&serviceServe) catch |err| {
            std.debug.print("failed to run as a service: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    try server.serve(&app);
    return 0;
}

var service_app: ?*app_mod.App = null;

fn serviceServe() anyerror!void {
    const app = service_app orelse return error.NotInitialized;
    try server.serve(app);
}

const EndpointParts = struct {
    host: []const u8,
    port: ?u16,
};

fn parseEndpoint(raw: []const u8) EndpointParts {
    const value = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, value, "[")) {
        if (std.mem.indexOfScalar(u8, value, ']')) |close| {
            const host = value[1..close];
            if (close + 1 < value.len and value[close + 1] == ':') {
                const port = std.fmt.parseInt(u16, value[close + 2 ..], 10) catch null;
                if (port) |p| {
                    if (p > 0) return .{ .host = host, .port = p };
                }
            }
            return .{ .host = host, .port = null };
        }
    }
    if (std.mem.count(u8, value, ":") == 1) {
        const idx = std.mem.indexOfScalar(u8, value, ':').?;
        if (idx > 0) {
            const port = std.fmt.parseInt(u16, value[idx + 1 ..], 10) catch null;
            if (port) |p| {
                if (p > 0) return .{ .host = value[0..idx], .port = p };
            }
        }
    }
    return .{ .host = value, .port = null };
}

fn formatEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

fn pickFreePort(listen: []const u8) !u16 {
    const address = std.net.Address.parseIp(listen, 0) catch
        std.net.Address.parseIp("0.0.0.0", 0) catch return error.NoAddress;
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn randomEntryPrefix(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [12]u8 = undefined;
    std.crypto.random.bytes(&raw);
    return std.fmt.allocPrint(allocator, "/{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn normalizeEntryPrefix(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";
    var value = raw;
    if (value[0] != '/') value = try std.fmt.allocPrint(allocator, "/{s}", .{value});
    const trimmed = std.mem.trimRight(u8, value, "/");
    if (!validate.isEntryPrefix(trimmed)) return error.InvalidEntryPrefix;
    return trimmed;
}

fn printUsage() void {
    const out = std.io.getStdOut().writer();
    out.writeAll(
        \\Hampanel daemon
        \\
        \\Usage:
        \\  hampaneld run      [--config PATH] [--listen ADDR] [--port N] [--data-dir DIR] [--tls-dir DIR] [--enroll-file PATH] [--service]
        \\  hampaneld init     [--endpoint HOST[:PORT]] [--san HOST]... [--entry-prefix /TOKEN] [--config PATH] [--force]
        \\  hampaneld enroll   [--config PATH] [--endpoint HOST:PORT] [--out PATH] [--json]
        \\  hampaneld version
        \\
        \\Defaults:
        \\  config    /etc/hampanel/config.json
        \\  tls dir   /etc/hampanel/tls
        \\  data dir  /var/lib/hampanel
        \\
    ) catch {};
}
