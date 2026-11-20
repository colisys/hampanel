const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const exec = @import("shared").exec;
const log = @import("../log.zig");

/// Aggregate the three existing security surfaces plus the new sensors so the
/// hub can render one overview without six round trips.
pub fn overview(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    const data_dir = ctx.app.config.data_dir;

    // `catch null` cannot widen a concrete value to an optional, so the
    // fallible calls are typed explicitly.
    const firewall: ?platform.firewall.Status = platform.firewall.status(a) catch null;
    const ssh: ?platform.ssh.Status = platform.ssh.status(a) catch null;
    const ssh_active = if (ssh) |value| value.active else false;
    const waf: ?platform.waf.Status = platform.waf.status(a, data_dir) catch null;
    const fail2ban: ?platform.fail2ban.Status = platform.fail2ban.status(a, data_dir) catch null;

    try ctx.json(.{
        .firewall = if (firewall) |value| .{
            .available = value.available,
            .active = value.active,
            .rules = value.rules.len,
        } else null,
        .ssh = if (ssh) |value| .{
            .available = value.available,
            .running = ssh_active,
        } else null,
        .waf = if (waf) |value| .{
            .installed = value.installed,
            .running = value.running,
            .mode = value.mode,
        } else null,
        .fail2ban = if (fail2ban) |value| .{
            .installed = value.installed,
            .initialized = value.initialized,
            .active = value.active,
            .jails = value.jails.len,
            .banned = bannedCount(value.jails),
        } else null,
    });
}

fn bannedCount(jails: []const platform.fail2ban.Jail) usize {
    var total: usize = 0;
    for (jails) |jail| total += jail.currently_banned;
    return total;
}

/// Tamper protection list and its enforcement state.
pub fn tamper(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    const status = platform.tamper.status(ctx.arena, data_dir) catch |err| {
        ctx.fail(500, "tamper_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn protect(ctx: *context.Context) anyerror!void {
    const Body = struct { path: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path");
        return;
    };
    const path = platform.files.resolve(ctx.arena, body.path) catch {
        ctx.fail(400, "bad_path", "path must be absolute");
        return;
    };
    // The target must exist, otherwise chattr would protect nothing while the
    // manifest claims otherwise.
    _ = platform.files.stat(ctx.arena, path) catch {
        ctx.fail(404, "not_found", "path does not exist");
        return;
    };
    const outcome = platform.tamper.protect(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
        ctx.fail(if (err == error.Unsupported) 501 else 502, "tamper_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: tamper protect ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn unprotect(ctx: *context.Context) anyerror!void {
    const Body = struct { path: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path");
        return;
    };
    const path = platform.files.resolve(ctx.arena, body.path) catch {
        ctx.fail(400, "bad_path", "path must be absolute");
        return;
    };
    const outcome = platform.tamper.unprotect(ctx.arena, ctx.app.config.data_dir, path) catch |err| {
        ctx.fail(if (err == error.Unsupported) 501 else 502, "tamper_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: tamper unprotect ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

/// Read-only capability report. Every entry states whether the host can run the
/// feature instead of pretending it works.
pub fn capabilities(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    try ctx.json(.{
        .ebpf = ebpfCapability(a),
        .chattr = commandExists(a, "chattr"),
        .qemu = commandExists(a, "qemu-system-x86_64"),
        .nft = commandExists(a, "nft"),
        .ufw = commandExists(a, "ufw"),
        .selinux = selinuxCapability(a),
        .root = effectiveRoot(a),
    });
}

/// `bpftool feature probe kernel` prints "CONFIG_X is set to y" lines; look for
/// the two that actually gate loading a program.
fn ebpfCapability(a: std.mem.Allocator) bool {
    if (!commandExists(a, "bpftool")) return false;
    if (!exists("/sys/kernel/btf/vmlinux")) return false;
    const probe = exec.run(a, &.{ "bpftool", "feature", "probe", "kernel" }, 256 * 1024) catch return false;
    if (!probe.ok()) return false;
    return std.mem.indexOf(u8, probe.stdout, "CONFIG_BPF_SYSCALL is set to y") != null and
        std.mem.indexOf(u8, probe.stdout, "CONFIG_BPF is set to y") != null;
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

/// SELinux is a probe, not an assumption: a host that runs AppArmor must not
/// be shown an enforcing toggle it cannot honour.
fn selinuxCapability(a: std.mem.Allocator) bool {
    compat.cwd().access("/sys/fs/selinux/enforce", .{}) catch return false;
    const probe = exec.run(a, &.{ "getenforce" }, 16 * 1024) catch return true;
    _ = probe;
    return true;
}

fn commandExists(a: std.mem.Allocator, name: []const u8) bool {
    return exec.commandExists(a, name);
}

fn effectiveRoot(a: std.mem.Allocator) bool {
    const probe = exec.run(a, &.{ "id", "-u" }, 16) catch return false;
    return probe.ok() and std.mem.eql(u8, std.mem.trim(u8, probe.stdout, " \r\n\t"), "0");
}
