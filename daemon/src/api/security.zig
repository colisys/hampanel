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

/// GET /tamper/lsm; POST /tamper/lsm and /tamper/lsm/remove take {"path":"/absolute/file"}.
/// Success returns backend, scope, guards, excludes, degraded and per-inode entries.
pub fn lsmStatus(ctx: *context.Context) anyerror!void {
    try lsmRequest(ctx, "status");
}
pub fn lsmAdd(ctx: *context.Context) anyerror!void {
    try lsmRequest(ctx, "add");
}
pub fn lsmRemove(ctx: *context.Context) anyerror!void {
    try lsmRequest(ctx, "remove");
}

fn lsmRequest(ctx: *context.Context, op: []const u8) anyerror!void {
    const path = if (std.mem.eql(u8, op, "status")) "" else blk: {
        const body = ctx.requireJson(struct { path: []const u8 }) catch {
            ctx.fail(400, "bad_request", "expected path");
            return;
        };
        break :blk body.path;
    };
    const json = platform.tamper.lsm(ctx.arena, op, path) catch |err| {
        ctx.fail(switch (@as(anyerror, err)) {
            error.Unsupported => 501,
            error.InvalidPath => 400,
            error.FileNotFound => 404,
            error.PolicyConflict => 409,
            error.LoaderTimedOut => 504,
            else => 503,
        }, "tamper_lsm_failed", @errorName(err));
        return;
    };
    ctx.response.content_type = "application/json";
    ctx.response.body = json;
}

pub fn detectTamperWrites(ctx: *context.Context) anyerror!void {
    const body = ctx.requireJson(struct { path: []const u8 }) catch {
        ctx.fail(400, "bad_request", "expected path");
        return;
    };
    const path = platform.files.resolve(ctx.arena, body.path) catch {
        ctx.fail(400, "bad_path", "path must be absolute");
        return;
    };
    const attempts = platform.tamper.detectWrites(ctx.arena, path) catch |err| {
        ctx.fail(switch (@as(anyerror, err)) {
            error.RegularFileRequired, error.InvalidPath => 400,
            error.FileNotFound => 404,
            error.AccessDenied => 403,
            error.ProbeTimedOut => 504,
            error.ProbeBusy => 409,
            error.Unsupported => 501,
            else => 503,
        }, "tamper_detection_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .mode = "ebpf_detect", .blocking = false, .write_attempts = attempts });
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

/// Host hardening: dangling links, umask, at/cron/sudo access, kernel params.
pub fn hardening(ctx: *context.Context) anyerror!void {
    const status = platform.hardening.status(ctx.arena) catch |err| {
        ctx.fail(500, "hardening_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn pruneDangling(ctx: *context.Context) anyerror!void {
    const Body = struct { paths: []const []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected paths");
        return;
    };
    if (body.paths.len == 0 or body.paths.len > 500) {
        ctx.fail(400, "bad_request", "expected 1..500 paths");
        return;
    }
    const outcome = platform.hardening.pruneDangling(ctx.arena, body.paths) catch |err| {
        ctx.fail(400, "hardening_failed", @errorName(err));
        return;
    };
    log.info("security: pruned dangling links: {s}", .{outcome.output});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn setUmask(ctx: *context.Context) anyerror!void {
    const Body = struct { umask: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected umask");
        return;
    };
    const outcome = platform.hardening.setUmask(ctx.arena, body.umask) catch |err| {
        ctx.fail(mapHardeningError(err), "hardening_failed", @errorName(err));
        return;
    };
    log.info("security: umask configured ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn schedulerAccess(ctx: *context.Context) anyerror!void {
    const Body = struct {
        tool: []const u8,
        users: []const []const u8 = &.{},
        enabled: bool,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected tool/users/enabled");
        return;
    };
    const tool = platform.hardening.AccessTool.fromString(body.tool) orelse {
        ctx.fail(400, "bad_tool", "tool must be at or cron");
        return;
    };
    const outcome = platform.hardening.restrictScheduler(ctx.arena, tool, body.users, body.enabled) catch |err| {
        ctx.fail(mapHardeningError(err), "hardening_failed", @errorName(err));
        return;
    };
    log.info("security: {s} access restricted={}", .{ body.tool, body.enabled });
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn hardenSudo(ctx: *context.Context) anyerror!void {
    const outcome = platform.hardening.hardenSudo(ctx.arena) catch |err| {
        ctx.fail(mapHardeningError(err), "hardening_failed", @errorName(err));
        return;
    };
    log.info("security: sudo hardened ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn setKernel(ctx: *context.Context) anyerror!void {
    const Body = struct { params: []const platform.hardening.Request };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected params");
        return;
    };
    if (body.params.len == 0 or body.params.len > 64) {
        ctx.fail(400, "bad_request", "expected 1..64 parameters");
        return;
    }
    const outcome = platform.hardening.setKernel(ctx.arena, body.params) catch |err| {
        ctx.fail(mapHardeningError(err), "hardening_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: kernel hardening applied={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn mapHardeningError(err: anyerror) u16 {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "InvalidUmask") or
        std.mem.eql(u8, name, "InvalidUser") or
        std.mem.eql(u8, name, "InvalidKey") or
        std.mem.eql(u8, name, "InvalidValue") or
        std.mem.eql(u8, name, "InvalidPath") or
        std.mem.eql(u8, name, "InvalidParams")) return 400;
    if (std.mem.eql(u8, name, "PamUnavailable") or
        std.mem.eql(u8, name, "SudoUnavailable") or
        std.mem.eql(u8, name, "SysctlUnavailable") or
        std.mem.eql(u8, name, "Unsupported")) return 501;
    return 500;
}

/// Honeypot state: host profile being replicated and running guests.
pub fn honeypot(ctx: *context.Context) anyerror!void {
    const status = platform.honeypot.status(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "honeypot_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn honeypotStop(ctx: *context.Context) anyerror!void {
    const Body = struct { id: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected id");
        return;
    };
    const outcome = platform.honeypot.stop(ctx.arena, ctx.app.config.data_dir, body.id) catch |err| {
        const name = @errorName(err);
        ctx.fail(if (std.mem.eql(u8, name, "InvalidSession")) 404 else 500, "honeypot_failed", name);
        return;
    };
    log.info("security: honeypot stopped", .{});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn honeypotConsole(ctx: *context.Context) anyerror!void {
    const id = (try ctx.query("id")) orelse {
        ctx.fail(400, "bad_request", "expected id");
        return;
    };
    if (!platform.honeypot.validId(id)) {
        ctx.fail(400, "bad_id", "invalid session id");
        return;
    }
    const paths = platform.honeypot.buildPaths(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "honeypot_failed", @errorName(err));
        return;
    };
    const path = paths.state(ctx.arena, id, "console.log") catch |err| {
        ctx.fail(500, "honeypot_failed", @errorName(err));
        return;
    };
    const raw = compat.cwd().readFileAlloc(ctx.arena, path, 2 * 1024 * 1024) catch {
        ctx.fail(404, "not_found", "no console for this session");
        return;
    };
    // The console is a boot log, not a shell: drop terminal control sequences
    // so the panel renders text instead of escape codes.
    var out = std.array_list.Managed(u8).init(ctx.arena);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == 0x1b) {
            index += 1;
            if (index < raw.len and raw[index] == '[') {
                index += 1;
                while (index < raw.len and !(raw[index] >= 0x40 and raw[index] <= 0x7e)) index += 1;
            }
            index += 1;
            continue;
        }
        if (raw[index] == '\r') {
            index += 1;
            continue;
        }
        try out.append(raw[index]);
        index += 1;
    }
    try ctx.json(.{ .id = id, .content = out.items });
}

/// SELinux status: presence, live mode, policy and tunable booleans.
pub fn selinux(ctx: *context.Context) anyerror!void {
    const status = platform.selinux.status(ctx.arena, ctx.app.config.data_dir) catch |err| {
        ctx.fail(500, "selinux_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn selinuxMode(ctx: *context.Context) anyerror!void {
    const Body = struct { mode: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected mode");
        return;
    };
    const outcome = platform.selinux.setMode(ctx.arena, body.mode) catch |err| {
        ctx.fail(mapSelinuxError(err), "selinux_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: selinux mode -> {s} ok={}", .{ body.mode, outcome.ok });
    try ctx.json(.{
        .ok = outcome.ok,
        .output = outcome.output,
        .reboot_required = outcome.reboot_required,
    });
}

/// Filesystem relabel is minutes-long on a real root, so this only submits a
/// task; the client watches it through the task list.
pub fn selinuxInitialize(ctx: *context.Context) anyerror!void {
    const summary = ctx.app.tasks.create(
        ctx.arena,
        "selinux.initialize",
        "初始化 SELinux 面板保护",
        "{}",
        "",
        ctx.peer_cn,
    ) catch |err| switch (err) {
        error.UnknownKind => {
            ctx.fail(400, "unknown_kind", "unknown task kind");
            return;
        },
        else => {
            ctx.fail(500, "task_failed", @errorName(err));
            return;
        },
    };
    ctx.response.status = 202;
    try ctx.json(.{ .task_id = summary.id });
}

pub fn selinuxBoolean(ctx: *context.Context) anyerror!void {
    const Body = struct { name: []const u8, enabled: bool };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name and enabled");
        return;
    };
    const outcome = platform.selinux.setBoolean(ctx.arena, body.name, body.enabled) catch |err| {
        ctx.fail(mapSelinuxError(err), "selinux_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: selinux boolean updated ok={}", .{outcome.ok});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn selinuxContext(ctx: *context.Context) anyerror!void {
    const Body = struct {
        path: []const u8,
        kind: []const u8,
        file_type: []const u8 = "all",
        remove: bool = false,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and kind");
        return;
    };
    const outcome = platform.selinux.setContext(ctx.arena, .{
        .path = body.path,
        .kind = body.kind,
        .file_type = body.file_type,
    }, body.remove) catch |err| {
        ctx.fail(mapSelinuxError(err), "selinux_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: selinux fcontext written remove={}", .{body.remove});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

pub fn selinuxPort(ctx: *context.Context) anyerror!void {
    const Body = struct {
        port: u16,
        protocol: []const u8,
        kind: []const u8,
        remove: bool = false,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected port, protocol and kind");
        return;
    };
    const outcome = platform.selinux.setPort(ctx.arena, .{
        .port = body.port,
        .protocol = body.protocol,
        .kind = body.kind,
    }, body.remove) catch |err| {
        ctx.fail(mapSelinuxError(err), "selinux_failed", @errorName(err));
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("security: selinux port written remove={}", .{body.remove});
    try ctx.json(.{ .ok = outcome.ok, .output = outcome.output });
}

fn mapSelinuxError(err: anyerror) u16 {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "InvalidMode") or
        std.mem.eql(u8, name, "InvalidBoolean") or
        std.mem.eql(u8, name, "InvalidPath") or
        std.mem.eql(u8, name, "InvalidType") or
        std.mem.eql(u8, name, "InvalidPort") or
        std.mem.eql(u8, name, "InvalidProtocol")) return 400;
    if (std.mem.eql(u8, name, "RelabelRequired")) return 409;
    if (std.mem.eql(u8, name, "NotPresent")) return 409;
    if (std.mem.eql(u8, name, "ToolingUnavailable") or std.mem.eql(u8, name, "Unsupported")) return 501;
    return 500;
}

/// Passive scan sensing: probe state, recent observations and bans.
pub fn scan(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    const status = platform.security.scanStatus(ctx.arena, data_dir) catch |err| {
        ctx.fail(500, "scan_failed", @errorName(err));
        return;
    };
    try ctx.json(status);
}

pub fn installScan(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    platform.security.installScan(ctx.arena, data_dir) catch |err| {
        ctx.fail(if (err == error.BpftraceUnavailable) 501 else 500, "scan_install_failed", @errorName(err));
        return;
    };
    log.info("security: scan sensor installed", .{});
    try ctx.json(.{ .ok = true });
}

pub fn startScan(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    platform.security.startScan(ctx.arena, data_dir) catch |err| {
        const name = @errorName(err);
        const code: u16 = if (std.mem.eql(u8, name, "BpftraceUnavailable")) 501 else if (std.mem.eql(u8, name, "AlreadyRunning")) 409 else 500;
        ctx.fail(code, "scan_start_failed", name);
        return;
    };
    log.info("security: scan sensor started", .{});
    try ctx.json(.{ .ok = true });
}

pub fn stopScan(ctx: *context.Context) anyerror!void {
    const data_dir = ctx.app.config.data_dir;
    platform.security.stopScan(ctx.arena, data_dir) catch |err| {
        ctx.fail(500, "scan_stop_failed", @errorName(err));
        return;
    };
    log.info("security: scan sensor stopped", .{});
    try ctx.json(.{ .ok = true });
}

/// Lifts one ban and removes the matching ufw rule.
pub fn unban(ctx: *context.Context) anyerror!void {
    const Body = struct { source: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected source");
        return;
    };
    if (std.Io.net.IpAddress.parse(body.source, 0)) |_| {} else |_| {
        ctx.fail(400, "bad_source", "source must be a literal address");
        return;
    }
    const data_dir = ctx.app.config.data_dir;
    platform.security.unban(ctx.arena, data_dir, body.source) catch |err| {
        ctx.fail(500, "unban_failed", @errorName(err));
        return;
    };
    log.info("security: unbanned source", .{});
    try ctx.json(.{ .ok = true });
}

/// Active probe status: whether nmap exists and which passive source is used.
pub fn probeStatus(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    try ctx.json(.{
        .nmap = commandExists(a, "nmap"),
        .curl = commandExists(a, "curl"),
        .intel_source = "Shodan InternetDB（免密钥）",
        .linux_only = true,
    });
}

/// Read-only capability report. Every entry states whether the host can run the
/// feature instead of pretending it works.
pub fn capabilities(ctx: *context.Context) anyerror!void {
    const a = ctx.arena;
    try ctx.json(.{
        .ebpf = platform.security.kernelBpfAvailable(),
        .bpftrace_available = platform.security.bpftraceAvailable(a),
        .chattr = commandExists(a, "chattr"),
        .qemu = commandExists(a, "qemu-system-x86_64"),
        .nft = commandExists(a, "nft"),
        .ufw = commandExists(a, "ufw"),
        .selinux = selinuxCapability(a),
        .auditd = commandExists(a, "ausearch"),
        .root = effectiveRoot(a),
    });
}

/// SELinux is a probe, not an assumption: a host that runs AppArmor has no
/// `/sys/fs/selinux`, and a missing `getenforce` must not be read as "present".
fn selinuxCapability(a: std.mem.Allocator) bool {
    _ = a;
    compat.cwd().access("/sys/fs/selinux", .{}) catch return false;
    return true;
}

fn commandExists(a: std.mem.Allocator, name: []const u8) bool {
    return exec.commandExists(a, name);
}

fn effectiveRoot(a: std.mem.Allocator) bool {
    _ = a;
    return platform.security.isRoot();
}
