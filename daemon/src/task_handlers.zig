const std = @import("std");
const compat = @import("compat");
const tasks = @import("tasks.zig");
const platform = @import("platform/mod.zig");

pub fn register(manager: *tasks.Manager) !void {
    try manager.register(.{ .kind = "nix.build", .lock_key = "nix", .handler = nixBuild });
    try manager.register(.{ .kind = "nix.run", .lock_key = "nix", .handler = nixRun });
    try manager.register(.{ .kind = "package.install", .lock_key = "packages", .handler = packageInstall });
    try manager.register(.{ .kind = "package.custom", .lock_key = "packages", .handler = packageCustom });
    try manager.register(.{ .kind = "package.refresh", .lock_key = "packages", .handler = packageRefresh });
    try manager.register(.{ .kind = "waf.install", .lock_key = "waf", .handler = wafInstall });
    try manager.register(.{ .kind = "waf.start", .lock_key = "waf", .handler = wafStart });
    try manager.register(.{ .kind = "waf.stop", .lock_key = "waf", .handler = wafStop });
    try manager.register(.{ .kind = "runtime.create", .lock_key = "runtime", .handler = runtimeCreate });
    try manager.register(.{ .kind = "runtime.rebuild", .lock_key = "runtime", .handler = runtimeRebuild });
    try manager.register(.{ .kind = "runtime.extensions", .lock_key = "runtime", .handler = runtimeExtensions });
    try manager.register(.{ .kind = "runtime.action", .lock_key = "runtime", .handler = runtimeAction });
    try manager.register(.{ .kind = "software.initialize", .lock_key = "software", .handler = softwareInitialize });
    try manager.register(.{ .kind = "store.deploy", .lock_key = "store", .handler = storeDeploy });
    try manager.register(.{ .kind = "store.app", .lock_key = "store", .handler = storeApp });
    try manager.register(.{ .kind = "service.action", .lock_key = "services", .handler = serviceAction });
    try manager.register(.{ .kind = "sites.reload", .lock_key = "sites", .handler = sitesReload });
    try manager.register(.{ .kind = "host.change", .lock_key = "host", .handler = hostChange });
    try manager.register(.{ .kind = "update.apply", .lock_key = "update", .handler = updateApply });
    try manager.register(.{ .kind = "security.probe", .lock_key = "security-probe", .handler = securityProbe });
    try manager.register(.{ .kind = "security.honeypot.build", .lock_key = "honeypot", .handler = honeypotBuild });
    try manager.register(.{ .kind = "security.honeypot.start", .lock_key = "honeypot", .handler = honeypotStart });
    try manager.register(.{ .kind = "selinux.initialize", .lock_key = "selinux", .handler = selinuxInitialize });
}

fn stringParam(ctx: *tasks.Context, key: []const u8) ![]const u8 {
    switch (ctx.params) {
        .object => |object| {
            if (object.get(key)) |value| {
                if (value == .string) return value.string;
            }
        },
        else => {},
    }
    return "";
}

fn nixBuild(ctx: *tasks.Context) !void {
    const target = try stringParam(ctx, "target");
    if (target.len == 0) return error.InvalidParams;
    const substituters = try stringParam(ctx, "substituters");
    if (!validSubstituters(substituters)) return error.InvalidParams;
    try ctx.setPhase("building");
    const outcome = try platform.nix.build(ctx.allocator, target, substituters);
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.NixBuildFailed;
}

fn nixRun(ctx: *tasks.Context) !void {
    const target = try stringParam(ctx, "target");
    if (target.len == 0) return error.InvalidParams;
    const substituters = try stringParam(ctx, "substituters");
    if (!validSubstituters(substituters)) return error.InvalidParams;
    var args = std.array_list.Managed([]const u8).init(ctx.allocator);
    switch (ctx.params) {
        .object => |object| {
            if (object.get("args")) |value| {
                if (value == .array) {
                    for (value.array.items) |item| {
                        if (item == .string) try args.append(item.string);
                    }
                }
            }
        },
        else => {},
    }
    try ctx.setPhase("running");
    const outcome = try platform.nix.run(ctx.allocator, target, args.items, substituters);
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.NixRunFailed;
}

fn validSubstituters(value: []const u8) bool {
    if (value.len > 2048) return false;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        count += 1;
        if (count > 16) return false;
        if (!(std.mem.startsWith(u8, token, "https://") or
            std.mem.startsWith(u8, token, "http://"))) return false;
        for (token) |ch| {
            if (ch < 0x21 or ch == 0x7f) return false;
        }
    }
    return true;
}

fn packageInstall(ctx: *tasks.Context) !void {
    const id = try stringParam(ctx, "id");
    if (id.len == 0) return error.InvalidParams;
    try ctx.setPhase("installing");
    const outcome = platform.packages.install(ctx.allocator, id) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.PackageInstallFailed;
}

fn packageCustom(ctx: *tasks.Context) !void {
    const name = try stringParam(ctx, "name");
    if (name.len == 0) return error.InvalidParams;
    try ctx.setPhase("installing");
    const outcome = platform.packages.installCustom(ctx.allocator, name) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.PackageInstallFailed;
}

fn packageRefresh(ctx: *tasks.Context) !void {
    try ctx.setPhase("refreshing");
    const outcome = platform.packages.refresh(ctx.allocator) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.PackageRefreshFailed;
}

fn wafInstall(ctx: *tasks.Context) !void {
    try ctx.setPhase("building");
    const outcome = platform.waf.install(ctx.allocator, ctx.manager.data_dir) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.WafInstallFailed;
}

fn wafStart(ctx: *tasks.Context) !void {
    try ctx.setPhase("starting");
    const outcome = platform.waf.start(ctx.allocator, ctx.manager.data_dir) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.WafStartFailed;
}

fn wafStop(ctx: *tasks.Context) !void {
    try ctx.setPhase("stopping");
    const outcome = platform.waf.stop(ctx.allocator, ctx.manager.data_dir) catch |err| {
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.WafStopFailed;
}

const runtime_env = @import("runtime/environments.zig");

fn boolParam(ctx: *tasks.Context, key: []const u8) bool {
    switch (ctx.params) {
        .object => |object| {
            if (object.get(key)) |value| {
                if (value == .bool) return value.bool;
            }
        },
        else => {},
    }
    return false;
}

fn runtimeCreate(ctx: *tasks.Context) !void {
    const Request = struct {
        name: []const u8,
        runtime: []const u8,
        image: []const u8 = "",
        tag: []const u8 = "",
        port: ?u16 = null,
        cpu: ?f64 = null,
        memory_mb: ?u32 = null,
        extensions: []const []const u8 = &.{},
        pkg_mirror: []const u8 = "",
    };
    const request = std.json.parseFromSliceLeaky(
        Request,
        ctx.allocator,
        ctx.params_json,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidParams;
    try ctx.setPhase("creating");
    const result = runtime_env.create(
        ctx.allocator,
        ctx.manager.database,
        ctx.manager.data_dir,
        .{
            .name = request.name,
            .runtime = request.runtime,
            .image = request.image,
            .tag = request.tag,
            .port = request.port,
            .cpu = request.cpu,
            .memory_mb = request.memory_mb,
            .extensions = request.extensions,
            .pkg_mirror = request.pkg_mirror,
        },
    ) catch |err| return err;
    try ctx.write(result.output);
    if (!result.ok) return error.RuntimeCreateFailed;
}

fn runtimeRebuild(ctx: *tasks.Context) !void {
    const id = try stringParam(ctx, "id");
    if (id.len == 0) return error.InvalidParams;
    try ctx.setPhase("rebuilding");
    const outcome = runtime_env.rebuild(
        ctx.allocator,
        ctx.manager.database,
        ctx.manager.data_dir,
        id,
    ) catch |err| return err;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.RuntimeRebuildFailed;
}

fn runtimeExtensions(ctx: *tasks.Context) !void {
    const id = try stringParam(ctx, "id");
    if (id.len == 0) return error.InvalidParams;
    var items = std.array_list.Managed([]const u8).init(ctx.allocator);
    switch (ctx.params) {
        .object => |object| {
            if (object.get("extensions")) |value| {
                if (value == .array) {
                    for (value.array.items) |item| {
                        if (item == .string) try items.append(item.string);
                    }
                }
            }
        },
        else => {},
    }
    try ctx.setPhase("rebuilding");
    const outcome = runtime_env.extensionsSet(
        ctx.allocator,
        ctx.manager.database,
        ctx.manager.data_dir,
        id,
        items.items,
    ) catch |err| return err;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.RuntimeRebuildFailed;
}

fn runtimeAction(ctx: *tasks.Context) !void {
    const id = try stringParam(ctx, "id");
    const action = try stringParam(ctx, "action");
    if (id.len == 0 or action.len == 0) return error.InvalidParams;
    try ctx.setPhase(action);
    const outcome = if (std.mem.eql(u8, action, "start"))
        runtime_env.start(ctx.allocator, ctx.manager.database, id) catch |err| return err
    else if (std.mem.eql(u8, action, "stop"))
        runtime_env.stop(ctx.allocator, ctx.manager.database, id) catch |err| return err
    else if (std.mem.eql(u8, action, "restart"))
        runtime_env.restart(ctx.allocator, ctx.manager.database, id) catch |err| return err
    else if (std.mem.eql(u8, action, "remove"))
        runtime_env.remove(
            ctx.allocator,
            ctx.manager.database,
            id,
            boolParam(ctx, "volumes"),
        ) catch |err| return err
    else
        return error.InvalidParams;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.RuntimeActionFailed;
}

fn softwareInitialize(ctx: *tasks.Context) !void {
    const id = try stringParam(ctx, "id");
    if (id.len == 0) return error.InvalidParams;
    try ctx.setPhase("initializing");
    const outcome = platform.software.initialize(
        ctx.allocator,
        ctx.manager.data_dir,
        id,
    ) catch |err| return err;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.SoftwareInitializeFailed;
}

const store_catalog = @import("store/catalog.zig");
const store_apps = @import("store/apps.zig");
const engine_mod = @import("runtime/engine.zig");

fn storeDeploy(ctx: *tasks.Context) !void {
    const slug = try stringParam(ctx, "slug");
    const app = store_catalog.find(slug) orelse return error.NotFound;
    var provided = std.StringHashMap([]const u8).init(ctx.allocator);
    switch (ctx.params) {
        .object => |object| {
            if (object.get("params")) |params| {
                if (params == .object) {
                    var iterator = params.object.iterator();
                    while (iterator.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            try provided.put(entry.key_ptr.*, entry.value_ptr.string);
                        }
                    }
                }
            }
        },
        else => {},
    }
    const socket = engine_mod.socketFromDb(ctx.allocator, ctx.manager.database);
    const engine = engine_mod.detect(ctx.allocator, socket) catch return error.EngineUnavailable;
    try ctx.setPhase("deploying");
    const result = store_apps.deploy(
        ctx.allocator,
        engine,
        socket,
        ctx.manager.data_dir,
        app,
        &provided,
    ) catch |err| return err;
    try ctx.write(result.output);
    ctx.result = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        .{ .params = result.params },
        .{},
    );
    if (!result.ok) return error.DeployFailed;
}

const platform_mod = @import("platform/mod.zig");
const site_nginx = @import("runtime/site_nginx.zig");
const site_caddy = @import("runtime/site_caddy.zig");

fn storeApp(ctx: *tasks.Context) !void {
    const slug = try stringParam(ctx, "slug");
    const action = try stringParam(ctx, "action");
    const app = store_catalog.find(slug) orelse return error.NotFound;
    if (action.len == 0) return error.InvalidParams;
    const socket = engine_mod.socketFromDb(ctx.allocator, ctx.manager.database);
    const engine = engine_mod.detect(ctx.allocator, socket) catch return error.EngineUnavailable;
    try ctx.setPhase(action);
    const outcome = if (std.mem.eql(u8, action, "upgrade-nginx"))
        try store_apps.upgradeNginx(ctx.allocator, engine, socket, ctx.manager.data_dir, app)
    else if (std.mem.eql(u8, action, "start"))
        store_apps.start(ctx.allocator, engine, socket, ctx.manager.data_dir, app) catch |err| return err
    else if (std.mem.eql(u8, action, "stop"))
        store_apps.stop(ctx.allocator, engine, socket, ctx.manager.data_dir, app) catch |err| return err
    else if (std.mem.eql(u8, action, "remove"))
        store_apps.remove(
            ctx.allocator,
            engine,
            socket,
            ctx.manager.data_dir,
            app,
            boolParam(ctx, "volumes"),
        ) catch |err| return err
    else
        return error.InvalidParams;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.StoreActionFailed;
}

fn serviceAction(ctx: *tasks.Context) !void {
    const unit = try stringParam(ctx, "unit");
    const action = try stringParam(ctx, "action");
    if (!@import("shared").validate.isUnitName(unit)) return error.InvalidParams;
    // Starting a reboot/halt unit takes the host down exactly like a reboot
    // command would. Before SELinux has been relabelled that is how a machine
    // stops booting, so the action is refused rather than executed.
    if (platform_mod.selinux.isRebootUnit(unit) and
        !platform_mod.selinux.rebootAllowed(ctx.allocator))
    {
        try ctx.write(
            "已拒绝：SELinux 尚未完成重打标签。此时重启或关机会让主机回到无法启动的状态，" ++
                "请先在 安全中心 → SELinux 完成初始化。\n",
        );
        return error.RebootBlocked;
    }
    const allowed = [_][]const u8{ "start", "stop", "restart", "reload", "enable", "disable" };
    for (allowed) |candidate| {
        if (std.mem.eql(u8, action, candidate)) break;
    } else return error.InvalidParams;
    try ctx.setPhase(action);
    const outcome = platform_mod.services.action(ctx.allocator, unit, action) catch |err| return err;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.ServiceActionFailed;
}

fn sitesReload(ctx: *tasks.Context) !void {
    try ctx.setPhase("reloading");
    const Reloaded = struct { ok: bool, output: []const u8 };
    const provider = @import("runtime/site_provider.zig");
    const server = provider.webServer(ctx.allocator, ctx.manager.data_dir, ctx.manager.config.web_server);
    const reloaded: Reloaded = if (std.mem.eql(u8, server, "nginx")) blk: {
        const target = try provider.nginxTarget(ctx.allocator, ctx.manager.data_dir, ctx.manager.database);
        const result = try site_nginx.reloadTarget(ctx.allocator, target);
        break :blk .{ .ok = result.ok, .output = result.output };
    } else if (std.mem.eql(u8, server, "caddy")) blk: {
        const result = site_caddy.reload(ctx.allocator) catch |err| return err;
        break :blk .{ .ok = result.ok, .output = result.output };
    } else return error.WebServerUnavailable;
    try ctx.write(reloaded.output);
    if (!reloaded.ok) return error.SitesReloadFailed;
}

fn hostChange(ctx: *tasks.Context) !void {
    const op = try stringParam(ctx, "op");
    try ctx.setPhase(op);
    const outcome = if (std.mem.eql(u8, op, "swap")) blk: {
        const size: u32 = switch (ctx.params) {
            .object => |object| if (object.get("size_mb")) |value|
                if (value == .integer) @as(u32, @intCast(@max(value.integer, 0))) else 0
            else
                0,
            else => 0,
        };
        break :blk platform_mod.host_settings.setSwap(ctx.allocator, size) catch |err| return err;
    } else if (std.mem.eql(u8, op, "swap-device")) blk: {
        const device = try stringParam(ctx, "device");
        if (device.len == 0) return error.InvalidParams;
        break :blk platform_mod.host_settings.enableSwapDevice(ctx.allocator, device) catch |err| return err;
    } else if (std.mem.eql(u8, op, "ntp")) blk: {
        break :blk platform_mod.host_settings.setNtp(ctx.allocator, boolParam(ctx, "enabled")) catch |err| return err;
    } else if (std.mem.eql(u8, op, "grub")) blk: {
        const index: usize = switch (ctx.params) {
            .object => |object| if (object.get("index")) |value|
                if (value == .integer) @as(usize, @intCast(@max(value.integer, 0))) else 0
            else
                0,
            else => 0,
        };
        break :blk platform_mod.host_settings.setGrubDefault(ctx.allocator, index) catch |err| return err;
    } else return error.InvalidParams;
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.HostChangeFailed;
}

const update_mod = @import("update.zig");

fn updateApply(ctx: *tasks.Context) !void {
    const mutex = ctx.manager.update_mutex orelse return error.UpdateDisabled;
    mutex.lockUncancelable(compat.io());
    defer mutex.unlock(compat.io());
    try ctx.setPhase("applying");
    const outcome = update_mod.apply(
        ctx.allocator,
        ctx.manager.database,
        ctx.manager.config,
    ) catch |err| return err;
    try ctx.write(outcome.message);
    ctx.result = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"updated\":{},\"message\":{f}}}",
        .{ outcome.updated, std.json.fmt(outcome.message, .{}) },
    );
    if (!outcome.updated) return error.UpdateFailed;
}

/// Active host probe. Scanning is slow (nmap may take minutes), so it is always
/// a task; the report is written to the task result and the human summary to
/// the output stream.
/// Relabels the filesystem for the panel's own paths and the container storage
/// it manages. Long-running, so it is a task rather than a request.
fn selinuxInitialize(ctx: *tasks.Context) !void {
    try ctx.setPhase("relabelling");
    const data_dir = try stringParam(ctx, "data_dir");
    const outcome = try platform_mod.selinux.initialize(ctx.allocator, data_dir);
    if (outcome.output.len > 0) try ctx.write(outcome.output);
    if (!outcome.ok) return error.RelabelFailed;
    try ctx.setPhase("ready");
}

fn securityProbe(ctx: *tasks.Context) !void {
    const target = try stringParam(ctx, "target");
    if (!platform_mod.hostprobe.isSafeTarget(target)) return error.InvalidTarget;
    const intensity = try stringParam(ctx, "intensity");
    if (intensity.len > 0 and !std.mem.eql(u8, intensity, "fast") and
        !std.mem.eql(u8, intensity, "full")) return error.InvalidParams;

    const os_detection = switch (ctx.params) {
        .object => |object| blk: {
            const value = object.get("os_detection") orelse break :blk true;
            break :blk !(value == .bool and !value.bool);
        },
        else => true,
    };

    try ctx.setPhase("probing");
    const report = platform_mod.hostprobe.probe(ctx.allocator, target, .{
        .intensity = if (intensity.len == 0) "fast" else intensity,
        .os_detection = os_detection,
        .service_detection = true,
    }) catch |err| {
        // The two backends expose different error sets, so match on names.
        const name = @errorName(err);
        const reason: []const u8 = if (std.mem.eql(u8, name, "InvalidTarget"))
            "目标非法（只接受 IPv4 或主机名）"
        else if (std.mem.eql(u8, name, "Unsupported"))
            "当前平台不支持主动探测"
        else
            name;
        try ctx.write(try std.fmt.allocPrint(ctx.allocator, "探测失败：{s}\n", .{reason}));
        return err;
    };

    var summary: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &summary.writer;
    try writer.print("目标 {s}\n", .{report.target});
    if (report.os_guess.len > 0) {
        try writer.print("系统猜测：{s}（{d}%）\n", .{ report.os_guess, report.os_accuracy });
    } else if (report.nmap_available) {
        try writer.print("系统猜测：无可靠结论\n", .{});
    }
    if (report.message.len > 0) try writer.print("{s}\n", .{report.message});
    if (report.ports.len == 0) {
        try writer.print("开放端口：无\n", .{});
    } else {
        try writer.print("开放端口（{d}）：\n", .{report.ports.len});
        for (report.ports) |port| {
            if (port.product.len > 0) {
                try writer.print("  {d}/{s} {s} {s} {s}\n", .{ port.port, port.protocol, port.service, port.product, port.version });
            } else {
                try writer.print("  {d}/{s} {s}\n", .{ port.port, port.protocol, port.service });
            }
        }
    }
    if (report.intel) |intel| {
        if (intel.tags.len > 0) {
            try writer.print("被动标签：", .{});
            for (intel.tags, 0..) |tag, index| {
                if (index > 0) try writer.print(", ", .{});
                try writer.print("{s}", .{tag});
            }
            try writer.print("\n", .{});
        }
        if (intel.vulns.len > 0) {
            try writer.print("被动情报漏洞：{d} 项\n", .{intel.vulns.len});
        }
    }
    try ctx.write(summary.written());

    ctx.result = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .target = report.target,
        .os_guess = report.os_guess,
        .os_accuracy = report.os_accuracy,
        .ports = report.ports,
        .hostnames = report.hostnames,
        .intel = report.intel,
        .nmap_available = report.nmap_available,
    }, .{});
}

/// Building the guest initramfs copies busybox and archives it; kept off the
/// request path because it rewrites a file tree.
fn honeypotBuild(ctx: *tasks.Context) !void {
    const mode_text = try stringParam(ctx, "mode");
    const mode = platform_mod.honeypot.Mode.fromString(if (mode_text.len == 0) "web" else mode_text) orelse
        return error.InvalidParams;
    try ctx.setPhase("building");
    const outcome = platform_mod.honeypot.buildImage(ctx.allocator, ctx.manager.data_dir, mode) catch |err| {
        try ctx.write(try std.fmt.allocPrint(ctx.allocator, "构建失败：{s}\n", .{@errorName(err)}));
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.BuildFailed;
}

fn honeypotStart(ctx: *tasks.Context) !void {
    const mode_text = try stringParam(ctx, "mode");
    const mode = platform_mod.honeypot.Mode.fromString(mode_text) orelse
        return error.InvalidParams;
    const port: u16 = switch (ctx.params) {
        .object => |object| blk: {
            const confirmed = object.get("confirmed") orelse return error.ConfirmationRequired;
            if (confirmed != .bool or !confirmed.bool) return error.ConfirmationRequired;
            const value = object.get("port") orelse return error.InvalidPort;
            if (value != .integer or value.integer < 1024 or value.integer > 65535) return error.InvalidPort;
            break :blk @intCast(value.integer);
        },
        else => return error.InvalidParams,
    };
    try ctx.setPhase("starting");
    const outcome = platform_mod.honeypot.start(ctx.allocator, ctx.manager.data_dir, mode, port) catch |err| {
        try ctx.write(try std.fmt.allocPrint(ctx.allocator, "启动失败：{s}\n", .{@errorName(err)}));
        return err;
    };
    try ctx.write(outcome.output);
    if (!outcome.ok) return error.StartFailed;
    if (outcome.session_id) |id| {
        ctx.result = try std.json.Stringify.valueAlloc(ctx.allocator, .{
            .session_id = id,
            .port = outcome.port,
            .mode = mode.name(),
        }, .{});
    }
}
