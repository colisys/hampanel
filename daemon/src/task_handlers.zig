const std = @import("std");
const tasks = @import("tasks.zig");
const platform = @import("platform/mod.zig");

pub fn register(manager: *tasks.Manager) !void {
    try manager.register(.{ .kind = "nix.build", .lock_key = "nix", .handler = nixBuild });
    try manager.register(.{ .kind = "nix.run", .lock_key = "nix", .handler = nixRun });
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
