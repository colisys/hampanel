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
