const std = @import("std");
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
