const std = @import("std");
const Context = @import("context.zig").Context;
const exec = @import("shared").exec;
const helper = @embedFile("../platform/linux/supervisord/managed.py");
const Action = enum { launch, start, stop, restart, logs, create, update, delete };

pub fn list(ctx: *Context) !void {
    try invoke(ctx, "list", "", "stdout", "[]");
}

pub fn action(ctx: *Context) !void {
    const Body = struct { action: Action, name: []const u8 = "", argv: []const []const u8 = &.{}, stream: enum { stdout, stderr } = .stdout };
    const body = ctx.requireJson(Body) catch return ctx.fail(400, "invalid_action", "Invalid Supervisord action");
    if (body.name.len > 256 or std.mem.indexOfScalar(u8, body.name, 0) != null or body.argv.len > 16) return ctx.fail(400, "invalid_program", "Invalid program");
    for (body.argv) |arg| if (arg.len > 128) return ctx.fail(400, "invalid_argv", "Argument too long");
    try invoke(ctx, @tagName(body.action), body.name, @tagName(body.stream), try std.json.Stringify.valueAlloc(ctx.arena, body.argv, .{}));
}

fn invoke(ctx: *Context, verb: []const u8, name: []const u8, stream: []const u8, argv: []const u8) !void {
    if (@import("builtin").os.tag != .linux) return ctx.fail(501, "unsupported", "Linux only");
    const root = try @import("compat").path.join(ctx.arena, &.{ ctx.app.config.data_dir, "supervisord" });
    const r = try exec.run(ctx.arena, &.{ "python3", "-I", "-c", helper, root, verb, "--", name, stream, argv }, 1024 * 1024);
    if (!r.ok()) return ctx.fail(409, "supervisord_failed", std.mem.trim(u8, r.stderr, " \n\r"));
    ctx.response.body = r.stdout;
    ctx.response.content_type = "application/json";
}
