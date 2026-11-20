const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
const fail2ban = @import("fail2ban.zig");

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    installed: bool,
    initialized: bool,
    needs_initialization: bool,
    active: bool,
    version: []const u8,
    service: []const u8,
    manage_hint: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator, data_dir: []const u8) ![]Item {
    var items = std.array_list.Managed(Item).init(allocator);

    const f2b_version = fail2ban.version(allocator);
    try items.append(.{
        .id = "fail2ban",
        .name = "Fail2ban",
        .description = "SSH 等服务防暴力破解，管理 jail、封禁记录与阈值。",
        .installed = f2b_version.len > 0,
        .initialized = fail2ban.isInitialized(allocator, data_dir),
        .needs_initialization = f2b_version.len > 0 and !fail2ban.isInitialized(allocator, data_dir),
        .active = fail2ban.isActive(allocator),
        .version = f2b_version,
        .service = "fail2ban",
        .manage_hint = "初始化后可在此管理 jail、封禁 IP 与阈值。",
    });

    const clam_version = commandVersion(allocator, "clamdscan", &.{"--version"});
    const clam_installed = clam_version.len > 0 and commandAvailable(allocator, "clamd", &.{"--help"});
    const clam_initialized = pathExists("/var/lib/hampanel-clamav/clamd.conf");
    const clam_active = blk: {
        const r = exec.run(allocator, &.{ "runuser", "-u", "hampanel-clamav", "--", "clamdscan", "--config-file", "/var/lib/hampanel-clamav/clamd.conf", "--ping=1" }, 4096) catch break :blk false;
        break :blk r.ok();
    };
    try items.append(.{
        .id = "clamav", .name = "ClamAV", .description = "面板专用 ClamAV 实例。",
        .installed = clam_installed, .initialized = clam_initialized,
        .needs_initialization = clam_installed and !clam_initialized,
        .active = clam_active, .version = clam_version, .service = "",
        .manage_hint = "通过 ClamAV 面板初始化私有 clamd；不操作发行版服务。",
    });

    const supervisor_version = commandVersion(allocator, "supervisord", &.{"--version"});
    const supervisor_conf = try compat.path.join(allocator, &.{ data_dir, "supervisord", "supervisord.conf" });
    const supervisor_initialized = pathExists(supervisor_conf);
    const supervisor_active = blk: {
        if (!supervisor_initialized) break :blk false;
        const r = exec.run(allocator, &.{ "supervisorctl", "-c", supervisor_conf, "pid" }, 4096) catch break :blk false;
        break :blk r.ok();
    };
    try items.append(.{
        .id = "supervisord", .name = "Supervisord", .description = "面板专用 Supervisord 实例。",
        .installed = supervisor_version.len > 0, .initialized = supervisor_initialized,
        .needs_initialization = supervisor_version.len > 0 and !supervisor_initialized,
        .active = supervisor_active, .version = supervisor_version, .service = "",
        .manage_hint = "使用专用面板启动实例；不操作系统 supervisor 服务。",
    });

    const pureftpd_version = commandVersion(allocator, "pure-ftpd", &.{"--help"});
    const pureftpd_installed = pureftpd_version.len > 0 and commandAvailable(allocator, "pure-pw", &.{"--help"});
    const pureftpd_initialized = pathExists("/var/lib/hampanel-ftps/pure-ftpd.conf");
    const pureftpd_active = serviceActive(allocator, "hampanel-pure-ftpd.service");
    try items.append(.{
        .id = "pure-ftpd", .name = "Pure-FTPD", .description = "面板专用显式 FTPS 实例。",
        .installed = pureftpd_installed,
        .initialized = pureftpd_initialized,
        .needs_initialization = pureftpd_installed and !pureftpd_initialized,
        .active = pureftpd_active, .version = pureftpd_version, .service = "",
        .manage_hint = "使用独立 hampanel-pure-ftpd unit；不操作发行版 pure-ftpd 服务。",
    });

    return items.toOwnedSlice();
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    if (std.mem.eql(u8, id, "fail2ban")) {
        const result = try fail2ban.initialize(allocator, data_dir);
        return .{ .ok = result.ok, .output = result.output };
    }
    // Dedicated instances are initialized only by their authenticated API routes.
    // Never fall back to the distribution's service manager for these IDs.
    if (std.mem.eql(u8, id, "clamav") or std.mem.eql(u8, id, "supervisord") or std.mem.eql(u8, id, "pure-ftpd"))
        return error.DedicatedInitializationRequired;
    return error.UnknownSoftware;
}

fn initializeNginx(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    if (nginxVersion(allocator).len == 0) return error.NotInstalled;

    _ = exec.run(allocator, &.{ "systemctl", "stop", "nginx" }, 256 * 1024) catch {};

    compat.cwd().makePath("/etc/nginx/conf.d/hampanel") catch |err| {
        _ = exec.run(allocator, &.{ "systemctl", "start", "nginx" }, 256 * 1024) catch {};
        return err;
    };

    const test_result = exec.run(allocator, &.{ "nginx", "-t" }, 1024 * 1024) catch null;
    if (test_result == null or !test_result.?.ok()) {
        _ = exec.run(allocator, &.{ "systemctl", "start", "nginx" }, 256 * 1024) catch {};
        return .{
            .ok = false,
            .output = if (test_result) |result| textOf(result, "nginx -t 未通过，已尝试恢复服务") else "无法执行 nginx -t，已尝试恢复服务",
        };
    }

    _ = exec.run(allocator, &.{ "systemctl", "enable", "nginx" }, 256 * 1024) catch {};
    const start = exec.run(allocator, &.{ "systemctl", "start", "nginx" }, 256 * 1024) catch null;
    if (start == null or !start.?.ok()) {
        return .{
            .ok = false,
            .output = if (start) |result| textOf(result, "nginx 启动失败") else "无法启动 nginx",
        };
    }

    try writeState(allocator, data_dir, "nginx", "nginx", "/etc/nginx/conf.d/hampanel");
    return .{
        .ok = true,
        .output = "初始化完成：已停止 nginx，创建面板托管目录并通过校验后重新启动（已设置开机自启）。",
    };
}

fn initializeService(allocator: std.mem.Allocator, service: []const u8, binary: []const u8) !Outcome {
    if (commandVersion(allocator, binary, &.{"--version"}).len == 0) return error.NotInstalled;
    const enable = exec.run(allocator, &.{ "systemctl", "enable", "--now", service }, 512 * 1024) catch
        return error.ServiceManagerUnavailable;
    const start = if (!enable.ok())
        exec.run(allocator, &.{ "systemctl", "start", service }, 512 * 1024) catch null
    else
        null;
    const primary = if (!enable.ok() and start != null) start.? else enable;
    return .{
        .ok = primary.ok(),
        .output = textOf(primary, if (primary.ok()) "服务已启动" else "服务启动失败"),
    };
}

fn commandVersion(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) []const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(command) catch return "";
    argv.appendSlice(args) catch return "";
    const result = exec.run(allocator, argv.items, 64 * 1024) catch return "";
    if (!result.ok()) return "";
    const raw = if (result.stderr.len > 0) result.stderr else result.stdout;
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    return std.mem.trim(u8, raw[0..line_end], " \t\r");
}

fn commandAvailable(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) bool {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(command) catch return false;
    argv.appendSlice(args) catch return false;
    const result = exec.run(allocator, argv.items, 64 * 1024) catch return false;
    return result.ok();
}

fn nginxVersion(allocator: std.mem.Allocator) []const u8 {
    const result = exec.run(allocator, &.{ "nginx", "-v" }, 64 * 1024) catch return "";
    const raw = if (result.stderr.len > 0) result.stderr else result.stdout;
    const marker = "nginx/";
    const index = std.mem.indexOf(u8, raw, marker) orelse return "";
    const rest = raw[index + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    return rest[0..end];
}

fn dockerVersion(allocator: std.mem.Allocator) []const u8 {
    const result = exec.run(allocator, &.{ "docker", "version", "--format", "{{.Server.Version}}" }, 64 * 1024) catch return "";
    if (!result.ok()) return "";
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn pathExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn serviceActive(allocator: std.mem.Allocator, service: []const u8) bool {
    const result = exec.run(allocator, &.{ "systemctl", "is-active", service }, 64 * 1024) catch return false;
    return result.ok() and std.mem.indexOf(u8, result.stdout, "active") != null;
}

fn stateExists(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) bool {
    const path = compat.path.join(allocator, &.{ data_dir, "software", std.fmt.allocPrint(allocator, "{s}.json", .{id}) catch return false }) catch return false;
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeState(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    id: []const u8,
    service: []const u8,
    managed_dir: []const u8,
) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    const path = try compat.path.join(allocator, &.{ data_dir, "software", filename });
    const dir = compat.path.dirname(path) orelse data_dir;
    try compat.cwd().makePath(dir);

    const State = struct {
        initialized_at: i64,
        service: []const u8,
        managed_dir: []const u8,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, State{
        .initialized_at = compat.timestamp(),
        .service = service,
        .managed_dir = managed_dir,
    }, .{ .whitespace = .indent_2 });

    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

fn textOf(result: exec.Result, fallback: []const u8) []const u8 {
    const primary = if (result.stderr.len > 0) result.stderr else result.stdout;
    const trimmed = std.mem.trim(u8, primary, " \t\r\n");
    return if (trimmed.len > 0) trimmed else fallback;
}
