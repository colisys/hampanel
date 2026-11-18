const std = @import("std");
const compat = @import("compat");
const builtin = @import("builtin");
const service = @import("windows_service");
const config = @import("config.zig");
const db = @import("db.zig");
const migrations = @import("migrations.zig");
const pki = @import("pki.zig");
const enroll = @import("enroll.zig");
const server = @import("server.zig");
const app_mod = @import("app.zig");
const tls = @import("tls.zig");
const audit = @import("audit.zig");
const log = @import("log.zig");
const version = @import("version.zig");
const update = @import("update.zig");
const engine_mod = @import("runtime/engine.zig");
const exec = @import("shared").exec;
const notify = @import("notify.zig");
const validate = @import("shared").validate;

const Command = enum { run, init, enroll, version, update, help };

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
    sans: std.array_list.Managed([]const u8),
    force: bool = false,
    json: bool = false,
    service: bool = false,
    check: bool = false,
    apply: bool = false,
    auto: bool = false,
    install_schedule: bool = false,
    remove_schedule: bool = false,
    install_mode: ?[]const u8 = null,
    update_channel: ?[]const u8 = null,
    update_repo: ?[]const u8 = null,
    github_mirror: ?[]const u8 = null,
    service_name: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, process_args: std.process.Args) !u8 {
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    var iterator = try process_args.iterateAllocator(allocator);
    defer iterator.deinit();
    while (iterator.next()) |arg| try args.append(arg);

    var opts = Options{ .sans = std.array_list.Managed([]const u8).init(allocator) };
    defer opts.sans.deinit();

    var index: usize = 1;
    if (index < args.items.len and args.items[index].len > 0 and args.items[index][0] != '-') {
        opts.command = parseCommand(args.items[index]) orelse {
            std.debug.print("unknown command: {s}\n\n", .{args.items[index]});
            printUsage();
            return 2;
        };
        index += 1;
    }

    while (index < args.items.len) : (index += 1) {
        const arg = args.items[index];
        if (std.mem.eql(u8, arg, "--config")) {
            opts.config_path = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            opts.listen = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = takeValue(args.items, &index, arg) orelse return 2;
            opts.port = std.fmt.parseInt(u16, raw, 10) catch {
                std.debug.print("invalid port: {s}\n", .{raw});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            opts.data_dir = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--enroll-file")) {
            opts.enroll_file = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--tls-dir")) {
            opts.tls_dir = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--endpoint")) {
            opts.endpoint = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--entry-prefix")) {
            opts.entry_prefix = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--out")) {
            opts.out = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--san")) {
            const value = takeValue(args.items, &index, arg) orelse return 2;
            try opts.sans.append(value);
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--service")) {
            opts.service = true;
        } else if (std.mem.eql(u8, arg, "--service-name")) {
            opts.service_name = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--install-mode")) {
            opts.install_mode = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--update-channel")) {
            opts.update_channel = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--update-repo")) {
            opts.update_repo = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--github-mirror")) {
            opts.github_mirror = takeValue(args.items, &index, arg) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--check")) {
            opts.check = true;
        } else if (std.mem.eql(u8, arg, "--apply")) {
            opts.apply = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            opts.auto = true;
        } else if (std.mem.eql(u8, arg, "--install-schedule")) {
            opts.install_schedule = true;
        } else if (std.mem.eql(u8, arg, "--remove-schedule")) {
            opts.remove_schedule = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        } else {
            std.debug.print("unknown option: {s}\n\n", .{arg});
            printUsage();
            return 2;
        }
    }

    if (args.items.len == 1) {
        // Older service units sometimes invoke the binary without `run`.
        // Under systemd, treat that as the server command instead of exiting
        // and letting Restart=always produce a restart loop.
        if (compat.getEnv("INVOCATION_ID") != null) {
            opts.command = .run;
        } else {
            printUsage();
            return 0;
        }
    }

    return switch (opts.command) {
        .help => blk: {
            printUsage();
            break :blk 0;
        },
        .version => blk: {
            try compat.printOut("hampaneld {s} (GPL-3.0-or-later)\n", .{version.version});
            break :blk 0;
        },
        .init => cmdInit(allocator, &opts),
        .enroll => cmdEnroll(allocator, &opts),
        .run => cmdRun(allocator, &opts),
        .update => cmdUpdate(allocator, &opts),
    };
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "run")) return .run;
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "enroll")) return .enroll;
    if (std.mem.eql(u8, raw, "update")) return .update;
    if (std.mem.eql(u8, raw, "version")) return .version;
    if (std.mem.eql(u8, raw, "help")) return .help;
    return null;
}

fn takeValue(args: []const []const u8, index: *usize, flag: []const u8) ?[]const u8 {
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
    _ = detectContainer(a, &cfg, "");
    _ = detectWebServer(a, &cfg);

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

    if (opts.install_mode) |mode| {
        if (!std.mem.eql(u8, mode, "binary") and !std.mem.eql(u8, mode, "source")) {
            std.debug.print("invalid --install-mode: use binary or source\n", .{});
            return 2;
        }
        cfg.install_mode = mode;
    }
    if (opts.update_channel) |channel| {
        if (channel.len == 0 or channel.len > 64) {
            std.debug.print("invalid --update-channel\n", .{});
            return 2;
        }
        cfg.update_channel = channel;
    }
    if (opts.update_repo) |repo| {
        if (std.mem.indexOfScalar(u8, repo, '/') == null or repo.len > 128) {
            std.debug.print("invalid --update-repo: expected owner/repo\n", .{});
            return 2;
        }
        cfg.update_repo = repo;
    }
    if (opts.github_mirror) |mirror| {
        const trimmed = std.mem.trim(u8, mirror, " \t\r\n/");
        if (trimmed.len > 200 or
            (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "http://") and
                !std.mem.startsWith(u8, trimmed, "https://")))
        {
            std.debug.print("invalid --github-mirror: expected an http(s) URL\n", .{});
            return 2;
        }
        cfg.github_mirror = trimmed;
    }
    if (opts.service_name) |service_name| {
        if (!validate.isUnitName(service_name)) {
            std.debug.print("invalid --service-name\n", .{});
            return 2;
        }
        cfg.service_name = service_name;
    }

    {
        var present = false;
        for (opts.sans.items) |existing| {
            if (std.mem.eql(u8, existing, parts.host)) present = true;
        }
        if (!present) try opts.sans.append(parts.host);
    }

    try compat.cwd().makePath(cfg.data_dir);
    try cfg.save(a, opts.config_path);

    const db_path = try db.pathFor(a, cfg.data_dir);
    var database = try db.Db.open(db_path);
    defer database.close();
    try migrations.migrate(a, &database);

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
        try compat.writeOut(json);
        try compat.writeOut("\n");
    } else {
        std.debug.print("Enrollment bundle written to {s}\n", .{out_path});
        std.debug.print("  endpoint   : {s}\n", .{bundle.endpoint});
        std.debug.print("  entry prefix: {s}\n", .{bundle.entry_prefix});
        std.debug.print("  client CN  : {s}\n", .{bundle.client_cn});
        std.debug.print("  CA SHA-256 : {s}\n", .{bundle.ca_sha256});
    }
    return 0;
}

fn cmdUpdate(allocator: std.mem.Allocator, opts: *Options) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = try config.Config.load(a, opts.config_path);
    applyOverrides(&cfg, opts.*);
    log.setLevelName(cfg.log_level);

    const db_path = try db.pathFor(a, cfg.data_dir);
    var database = try db.Db.open(db_path);
    defer database.close();
    try migrations.migrate(a, &database);

    if (opts.install_schedule) {
        const self_exe = try compat.selfExePathAlloc(a);
        const outcome = update.installSchedule(a, cfg, self_exe, opts.config_path) catch |err| switch (err) {
            error.UpdateDisabled => {
                std.debug.print("update checks are disabled for source installs\n", .{});
                return 1;
            },
            else => {
                std.debug.print("could not install update check: {s}\n", .{@errorName(err)});
                return 1;
            },
        };
        std.debug.print("{s}\n", .{outcome.message});
        return if (outcome.installed) 0 else 1;
    }

    if (opts.remove_schedule) {
        const outcome = update.removeSchedule(a) catch |err| {
            std.debug.print("could not remove update check: {s}\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("{s}\n", .{outcome.message});
        return 0;
    }

    if (opts.apply) {
        const outcome = update.apply(a, &database, cfg) catch |err| switch (err) {
            error.UpdateDisabled => {
                std.debug.print("update checks are disabled for source installs\n", .{});
                return 1;
            },
            error.NothingToDo => {
                std.debug.print("already up to date ({s})\n", .{version.version});
                return 0;
            },
            else => {
                std.debug.print("update failed: {s}\n", .{@errorName(err)});
                return 1;
            },
        };
        std.debug.print("{s}\n", .{outcome.message});
        return 0;
    }

    const state = update.check(a, &database, cfg);

    if (opts.auto) {
        if (state.update_available and cfg.update_auto) {
            _ = update.apply(a, &database, cfg) catch |err| {
                std.debug.print("automatic update failed: {s}\n", .{@errorName(err)});
                return 0;
            };
        }
        return 0;
    }

    if (opts.json) {
        const body = try std.json.Stringify.valueAlloc(a, state, .{});
        try compat.printOut("{s}\n", .{body});
    } else {
        try compat.printOut("current:     {s}\n", .{state.current_version});
        try compat.printOut("channel:     {s} ({s})\n", .{ state.channel, state.install_mode });
        try compat.printOut("latest:      {s}\n", .{if (state.latest_version.len > 0) state.latest_version else "unknown"});
        try compat.printOut("available:   {s}\n", .{if (state.update_available) "yes" else "no"});
        try compat.printOut("scheduled:   {s}\n", .{if (update.scheduleInstalled(a)) "yes" else "no"});
        if (state.error_message.len > 0) {
            try compat.printOut("error:       {s}\n", .{state.error_message});
        }
    }

    if (state.error_message.len > 0) return 1;
    return 0;
}

fn detectContainer(allocator: std.mem.Allocator, cfg: *config.Config, socket: []const u8) bool {
    if (cfg.container.len > 0) {
        engine_mod.setPreferred(cfg.container);
        return false;
    }
    if (engine_mod.autoDetect(allocator, socket)) |engine| {
        cfg.container = allocator.dupe(u8, engine.name) catch "";
        engine_mod.setPreferred(cfg.container);
        log.info("container engine configured as {s}", .{engine.name});
        return true;
    } else |err| {
        log.warn("no container engine detected ({s}); set \"container\" to docker or podman", .{@errorName(err)});
        return false;
    }
}

fn detectWebServer(allocator: std.mem.Allocator, cfg: *config.Config) bool {
    if (cfg.web_server.len > 0) return false;
    if (exec.commandExists(allocator, "nginx")) {
        const probe = exec.run(allocator, &.{ "nginx", "-v" }, 4096) catch null;
        if (probe != null and probe.?.exit_code == 0) {
            cfg.web_server = "nginx";
            log.info("web server configured as nginx", .{});
            return true;
        }
    }
    if (exec.commandExists(allocator, "caddy")) {
        const probe = exec.run(allocator, &.{ "caddy", "version" }, 4096) catch null;
        if (probe != null and probe.?.exit_code == 0) {
            cfg.web_server = "caddy";
            log.info("web server configured as caddy", .{});
            return true;
        }
    }
    log.warn("no supported web server detected; set \"web_server\" to nginx or caddy", .{});
    return false;
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

    const db_path = try db.pathFor(a, cfg.data_dir);
    var database = try db.Db.open(db_path);
    defer database.close();
    try migrations.migrate(a, &database);

    const container_changed = detectContainer(a, &cfg, engine_mod.socketFromDb(a, &database));
    const web_changed = detectWebServer(a, &cfg);
    if (container_changed or web_changed) {
        cfg.save(a, opts.config_path) catch |err| {
            log.warn("failed to persist detected services: {s}", .{@errorName(err)});
        };
    }

    const audit_log = try audit.Log.init(allocator, &database);
    const task_manager = try @import("tasks.zig").Manager.init(allocator, &database, cfg.data_dir);
    defer task_manager.deinit();
    try @import("task_handlers.zig").register(task_manager);
    try task_manager.start();
    var app = app_mod.App{
        .allocator = allocator,
        .config = cfg,
        .config_path = opts.config_path,
        .db = &database,
        .started_at = compat.timestamp(),
        .tls = tls_context,
        .pki = paths,
        .audit = audit_log,
        .tasks = task_manager,
    };

    defer app.deinitUpdateConfig();
    defer app.stream_clients.deinit(allocator);
    defer app.task_limits.deinit(allocator);

    log.info("hampaneld {s} starting (GPL-3.0-or-later)", .{version.version});
    notify.startMonitor(&database);

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
    const io = compat.io();
    var address = std.Io.net.IpAddress.parse(listen, 0) catch
        std.Io.net.IpAddress.parse("0.0.0.0", 0) catch return error.NoAddress;
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

fn randomEntryPrefix(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [12]u8 = undefined;
    compat.randomBytes(&raw);
    return std.fmt.allocPrint(allocator, "/{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn normalizeEntryPrefix(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";
    var value = raw;
    if (value[0] != '/') value = try std.fmt.allocPrint(allocator, "/{s}", .{value});
    const trimmed = std.mem.trimEnd(u8, value, "/");
    if (!validate.isEntryPrefix(trimmed)) return error.InvalidEntryPrefix;
    return trimmed;
}

fn printUsage() void {
    compat.writeOut(
        \\Hampanel daemon
        \\
        \\Usage:
        \\  hampaneld run      [--config PATH] [--listen ADDR] [--port N] [--data-dir DIR] [--tls-dir DIR] [--enroll-file PATH] [--service]
        \\  hampaneld init     [--endpoint HOST[:PORT]] [--san HOST]... [--entry-prefix /TOKEN] [--config PATH] [--force]
        \\  hampaneld enroll   [--config PATH] [--endpoint HOST:PORT] [--out PATH] [--json]
        \\  hampaneld update   [--check|--apply|--auto] [--json] [--config PATH]
        \\  hampaneld update   [--install-schedule|--remove-schedule] [--config PATH]
        \\  hampaneld version
        \\
        \\Update options:
        \\  --install-mode binary|source   recorded at init; source installs cannot update or schedule checks
        \\  --update-channel stable|nightly
        \\  --update-repo owner/repo
        \\
        \\Defaults:
        \\  config    /etc/hampanel/config.json
        \\  tls dir   /etc/hampanel/tls
        \\  data dir  /var/lib/hampanel
        \\
    ) catch {};
}
