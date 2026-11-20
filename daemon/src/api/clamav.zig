const std = @import("std");
const exec = @import("shared").exec;
const Context = @import("context.zig").Context;

fn invoke(ctx: *Context, args: []const []const u8) !void {
    if (@import("builtin").os.tag != .linux) return ctx.fail(501, "unsupported", "Linux only");
    const argv = try std.mem.concat(ctx.arena, []const u8, &.{ &.{ "runuser", "-u", "hampanel-clamav", "--", "python3", "-I", "/usr/libexec/hampanel/clamav.py", "/var/lib/hampanel-clamav" }, args });
    const result = exec.run(ctx.arena, argv, 1024 * 1024) catch return ctx.fail(503, "clamav_unavailable", "无法执行 ClamAV helper");
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{}) catch return ctx.fail(502, "clamav_helper", "ClamAV helper 未返回 JSON，请检查部署");
    if (!result.ok()) {
        if (value == .object) if (value.object.get("error")) |msg| {
            if (msg == .string) return ctx.fail(422, "clamav_failed", msg.string);
        };
        return ctx.fail(502, "clamav_failed", "ClamAV helper failed");
    }
    try ctx.json(value);
}

pub fn status(ctx: *Context) !void {
    try invoke(ctx, &.{"status"});
}

pub fn initialize(ctx: *Context) !void {
    const body = ctx.requireJson(struct { database: []const u8, threads: u8 }) catch return ctx.fail(400, "bad_request", "expected database and threads");
    try invoke(ctx, &.{ "initialize", "--database", body.database, "--threads", try std.fmt.allocPrint(ctx.arena, "{d}", .{body.threads}) });
}

pub fn scan(ctx: *Context) !void {
    const body = ctx.requireJson(struct { path: []const u8 }) catch return ctx.fail(400, "bad_request", "expected path");
    try invoke(ctx, &.{ "scan", "--path", body.path });
}
