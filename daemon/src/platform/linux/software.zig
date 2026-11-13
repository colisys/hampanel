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

    const nginx_version = nginxVersion(allocator);
    try items.append(.{
        .id = "nginx",
        .name = "Nginx",
        .description = "Web 服务器与反向代理；初始化后由「网站」页面管理站点。",
        .installed = nginx_version.len > 0,
        .initialized = stateExists(allocator, data_dir, "nginx"),
        .needs_initialization = nginx_version.len > 0 and !stateExists(allocator, data_dir, "nginx"),
        .active = serviceActive(allocator, "nginx"),
        .version = nginx_version,
        .service = "nginx",
        .manage_hint = "初始化后请使用「网站」页面创建、启停与重载站点。",
    });

    const docker_version = dockerVersion(allocator);
    try items.append(.{
        .id = "docker",
        .name = "Docker",
        .description = "容器运行时；由「容器」与「应用商店」页面直接管理，无需改写配置。",
        .installed = docker_version.len > 0,
        .initialized = docker_version.len > 0,
        .needs_initialization = false,
        .active = docker_version.len > 0,
        .version = docker_version,
        .service = "docker",
        .manage_hint = "使用「容器」页面或「应用商店」管理容器与 Compose 应用。",
    });

    return items.toOwnedSlice();
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    if (std.mem.eql(u8, id, "fail2ban")) {
        const result = try fail2ban.initialize(allocator, data_dir);
        return .{ .ok = result.ok, .output = result.output };
    }
    if (std.mem.eql(u8, id, "nginx")) return initializeNginx(allocator, data_dir);
    if (std.mem.eql(u8, id, "docker")) {
        if (dockerVersion(allocator).len == 0) return error.NotInstalled;
        return .{ .ok = true, .output = "Docker 无需初始化，可直接使用容器管理。" };
    }
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
