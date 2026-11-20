const Context = @import("context.zig").Context;
const exec = @import("shared").exec;
const helper = "/usr/local/libexec/hampanel/pure_ftpd.py";
const root = "/var/lib/hampanel-ftps";
const compat = @import("compat");

fn invoke(ctx: *Context, args: []const []const u8, input: ?[]const u8) !bool {
    const r = exec.runWith(ctx.arena, args, .{ .stdin = input, .max_output = 64 * 1024 }) catch {
        ctx.fail(500, "ftps_failed", "cannot invoke managed FTPS command");
        return false;
    };
    if (!r.ok()) ctx.fail(409, "ftps_failed", "managed FTPS operation failed");
    return r.ok();
}

pub fn initialize(ctx: *Context) !void {
    if (compat.cwd().access(root ++ "/pure-ftpd.conf", .{})) |_| {} else |_| {
        if (!try invoke(ctx, &.{ "python3", "-I", helper, "init", root }, null)) return;
    }
    if (!try invoke(ctx, &.{ "systemctl", "enable", "--now", "hampanel-pure-ftpd.service" }, null)) return;
    if (try invoke(ctx, &.{ "systemctl", "is-active", "--quiet", "hampanel-pure-ftpd.service" }, null)) try ctx.json(.{ .ok = true });
}

pub fn add(ctx: *Context) !void {
    const b = ctx.requireJson(struct { name: []const u8, password: []const u8 }) catch {
        ctx.fail(400, "bad_request", "expected virtual name and password");
        return;
    };
    // Resolve the provisioned service identity locally, never from API input.
    const uid = exec.run(ctx.arena, &.{ "id", "-u", "hampanel-ftps" }, 128) catch return error.IdentityUnavailable;
    const gid = exec.run(ctx.arena, &.{ "id", "-g", "hampanel-ftps" }, 128) catch return error.IdentityUnavailable;
    if (!uid.ok() or !gid.ok()) return error.IdentityUnavailable;
    const trim = @import("std").mem.trim;
    if (try invoke(ctx, &.{ "python3", "-I", helper, "add", root, "--uid", trim(u8, uid.stdout, " \r\n"), "--gid", trim(u8, gid.stdout, " \r\n"), "--name", b.name }, b.password)) try ctx.json(.{ .ok = true });
}

pub fn remove(ctx: *Context) !void {
    const b = ctx.requireJson(struct { name: []const u8 }) catch {
        ctx.fail(400, "bad_request", "expected virtual name");
        return;
    };
    if (try invoke(ctx, &.{ "python3", "-I", helper, "delete", root, "--name", b.name }, null)) try ctx.json(.{ .ok = true });
}
