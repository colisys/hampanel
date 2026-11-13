const std = @import("std");
const exec = @import("shared").exec;

const managed_path = "/etc/fail2ban/jail.d/99-hampanel.local";
const service_name = "fail2ban";

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Jail = struct {
    name: []const u8,
    currently_failed: usize,
    total_failed: usize,
    currently_banned: usize,
    total_banned: usize,
    maxretry: []const u8,
    bantime: []const u8,
    findtime: []const u8,
    banned_ips: []const []const u8,
};

pub const Status = struct {
    installed: bool,
    initialized: bool,
    active: bool,
    version: []const u8,
    jails: []const Jail,
    message: []const u8 = "",
};

pub fn version(allocator: std.mem.Allocator) []const u8 {
    const result = exec.run(allocator, &.{ "fail2ban-client", "--version" }, 64 * 1024) catch return "";
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    return std.mem.trim(u8, raw, " \t\r\n");
}

pub fn isActive(allocator: std.mem.Allocator) bool {
    const result = exec.run(allocator, &.{ "systemctl", "is-active", service_name }, 64 * 1024) catch return false;
    return result.ok() and std.mem.indexOf(u8, result.stdout, "active") != null;
}

pub fn statePath(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ data_dir, "software", "fail2ban.json" });
}

pub fn isInitialized(allocator: std.mem.Allocator, data_dir: []const u8) bool {
    const path = statePath(allocator, data_dir) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    if (version(allocator).len == 0) return error.NotInstalled;

    const previous = std.fs.cwd().readFileAlloc(allocator, managed_path, 1024 * 1024) catch null;
    _ = exec.run(allocator, &.{ "systemctl", "stop", service_name }, 256 * 1024) catch {};

    const config = try render(allocator, 3600, 600, 5);
    writeManaged(config) catch |err| {
        if (previous) |content| writeManaged(content) catch {};
        _ = exec.run(allocator, &.{ "systemctl", "start", service_name }, 256 * 1024) catch {};
        return err;
    };

    const test_result = exec.run(allocator, &.{ "fail2ban-client", "-t" }, 1024 * 1024) catch null;
    if (test_result == null or !test_result.?.ok()) {
        restore(previous);
        _ = exec.run(allocator, &.{ "systemctl", "start", service_name }, 256 * 1024) catch {};
        return .{
            .ok = false,
            .output = if (test_result) |result| textOf(result, "fail2ban-client -t 未通过，已回滚") else "无法执行 fail2ban-client -t，已回滚",
        };
    }

    _ = exec.run(allocator, &.{ "systemctl", "enable", service_name }, 256 * 1024) catch {};
    const start = exec.run(allocator, &.{ "systemctl", "start", service_name }, 256 * 1024) catch null;
    if (start == null or !start.?.ok()) {
        restore(previous);
        _ = exec.run(allocator, &.{ "systemctl", "start", service_name }, 256 * 1024) catch {};
        return .{
            .ok = false,
            .output = if (start) |result| textOf(result, "fail2ban 启动失败，已回滚") else "无法启动 fail2ban，已回滚",
        };
    }

    try writeState(allocator, data_dir);
    return .{
        .ok = true,
        .output = "初始化完成：已停止原 fail2ban 服务，写入面板托管配置并重新启动（已设置开机自启）。",
    };
}

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const ver = version(allocator);
    if (ver.len == 0) {
        return .{
            .installed = false,
            .initialized = false,
            .active = false,
            .version = "",
            .jails = &.{},
            .message = "未安装 fail2ban",
        };
    }

    const list_result = exec.run(allocator, &.{ "fail2ban-client", "status" }, 1024 * 1024) catch null;
    if (list_result == null or !list_result.?.ok()) {
        return .{
            .installed = true,
            .initialized = isInitialized(allocator, data_dir),
            .active = isActive(allocator),
            .version = ver,
            .jails = &.{},
            .message = if (list_result) |result| textOf(result, "fail2ban-client status 失败") else "无法执行 fail2ban-client",
        };
    }

    const jails = try parseJails(allocator, list_result.?.stdout);
    return .{
        .installed = true,
        .initialized = isInitialized(allocator, data_dir),
        .active = isActive(allocator),
        .version = ver,
        .jails = jails,
        .message = "",
    };
}

pub fn ban(allocator: std.mem.Allocator, jail: []const u8, ip: []const u8) !Outcome {
    if (!validJail(jail)) return error.InvalidJail;
    if (!validIp(ip)) return error.InvalidIP;
    const result = exec.run(allocator, &.{ "fail2ban-client", "set", jail, "banip", ip }, 1024 * 1024) catch return error.Fail2banUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result, "已提交封禁") };
}

pub fn unban(allocator: std.mem.Allocator, jail: []const u8, ip: []const u8) !Outcome {
    if (!validJail(jail)) return error.InvalidJail;
    if (!validIp(ip)) return error.InvalidIP;
    const result = exec.run(allocator, &.{ "fail2ban-client", "set", jail, "unbanip", ip }, 1024 * 1024) catch return error.Fail2banUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result, "已提交解封") };
}

pub fn setLimits(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    maxretry: u32,
    bantime: u32,
    findtime: u32,
) !Outcome {
    if (!isInitialized(allocator, data_dir)) return error.NotInitialized;
    if (maxretry < 1 or maxretry > 100) return error.InvalidLimits;
    if (bantime < 60 or bantime > 31_536_000) return error.InvalidLimits;
    if (findtime < 60 or findtime > 31_536_000) return error.InvalidLimits;

    const previous = std.fs.cwd().readFileAlloc(allocator, managed_path, 1024 * 1024) catch null;
    const config = try render(allocator, bantime, findtime, maxretry);
    try writeManaged(config);

    const test_result = exec.run(allocator, &.{ "fail2ban-client", "-t" }, 1024 * 1024) catch null;
    if (test_result == null or !test_result.?.ok()) {
        restore(previous);
        return .{
            .ok = false,
            .output = if (test_result) |result| textOf(result, "配置校验失败，已回滚") else "无法执行 fail2ban-client -t，已回滚",
        };
    }

    const reload = exec.run(allocator, &.{ "fail2ban-client", "reload" }, 1024 * 1024) catch null;
    if (reload == null or !reload.?.ok()) {
        restore(previous);
        return .{
            .ok = false,
            .output = if (reload) |result| textOf(result, "reload 失败，已回滚") else "无法重载 fail2ban，已回滚",
        };
    }

    return .{ .ok = true, .output = "封禁阈值已更新并重载。" };
}

fn render(allocator: std.mem.Allocator, bantime: u32, findtime: u32, maxretry: u32) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "# Managed by Hampanel. Original configuration files are preserved.\n" ++
            "[DEFAULT]\n" ++
            "bantime = {d}\n" ++
            "findtime = {d}\n" ++
            "maxretry = {d}\n" ++
            "backend = systemd\n" ++
            "\n" ++
            "[sshd]\n" ++
            "enabled = true\n" ++
            "port = ssh\n",
        .{ bantime, findtime, maxretry },
    );
}

fn writeManaged(content: []const u8) !void {
    const dir = std.fs.path.dirname(managed_path) orelse "/etc/fail2ban/jail.d";
    try std.fs.cwd().makePath(dir);
    var file = try std.fs.createFileAbsolute(managed_path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(content);
    file.chmod(0o644) catch {};
}

fn restore(previous: ?[]const u8) void {
    if (previous) |content| {
        writeManaged(content) catch {};
    } else {
        std.fs.deleteFileAbsolute(managed_path) catch {};
    }
}

fn writeState(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const path = try statePath(allocator, data_dir);
    const dir = std.fs.path.dirname(path) orelse data_dir;
    try std.fs.cwd().makePath(dir);

    const State = struct {
        initialized_at: i64,
        service: []const u8,
        managed_file: []const u8,
    };
    const json = try std.json.stringifyAlloc(allocator, State{
        .initialized_at = std.time.timestamp(),
        .service = service_name,
        .managed_file = managed_path,
    }, .{ .whitespace = .indent_2 });

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

fn parseJails(allocator: std.mem.Allocator, list_output: []const u8) ![]Jail {
    const marker = "Jail list:";
    const marker_index = std.mem.indexOf(u8, list_output, marker) orelse return &.{};
    var rest = list_output[marker_index + marker.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |end| rest = rest[0..end];

    var jails = std.ArrayList(Jail).init(allocator);
    var names = std.mem.splitScalar(u8, rest, ',');
    while (names.next()) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t\r");
        if (name.len == 0) continue;
        if (jails.items.len >= 20) break;
        const jail = parseJail(allocator, name) catch continue;
        try jails.append(jail);
    }
    return jails.toOwnedSlice();
}

fn parseJail(allocator: std.mem.Allocator, name: []const u8) !Jail {
    const result = try exec.run(allocator, &.{ "fail2ban-client", "status", name }, 1024 * 1024);
    if (!result.ok()) return error.JailStatus;

    var jail = Jail{
        .name = name,
        .currently_failed = 0,
        .total_failed = 0,
        .currently_banned = 0,
        .total_banned = 0,
        .maxretry = try getValue(allocator, name, "maxretry"),
        .bantime = try getValue(allocator, name, "bantime"),
        .findtime = try getValue(allocator, name, "findtime"),
        .banned_ips = &.{},
    };

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "Currently failed:")) |index| {
            jail.currently_failed = parseNumber(line[index + "Currently failed:".len ..]);
        } else if (std.mem.indexOf(u8, line, "Total failed:")) |index| {
            jail.total_failed = parseNumber(line[index + "Total failed:".len ..]);
        } else if (std.mem.indexOf(u8, line, "Currently banned:")) |index| {
            jail.currently_banned = parseNumber(line[index + "Currently banned:".len ..]);
        } else if (std.mem.indexOf(u8, line, "Total banned:")) |index| {
            jail.total_banned = parseNumber(line[index + "Total banned:".len ..]);
        } else if (std.mem.indexOf(u8, line, "Banned IP list:")) |index| {
            const ips_text = std.mem.trim(u8, line[index + "Banned IP list:".len ..], " \t\r");
            var ips = std.ArrayList([]const u8).init(allocator);
            var tokens = std.mem.tokenizeAny(u8, ips_text, " \t");
            while (tokens.next()) |ip| {
                if (ips.items.len >= 200) break;
                try ips.append(ip);
            }
            jail.banned_ips = try ips.toOwnedSlice();
        }
    }
    return jail;
}

fn getValue(allocator: std.mem.Allocator, jail: []const u8, key: []const u8) ![]const u8 {
    const result = exec.run(allocator, &.{ "fail2ban-client", "get", jail, key }, 64 * 1024) catch return "";
    if (!result.ok()) return "";
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn parseNumber(raw: []const u8) usize {
    const value = std.mem.trim(u8, raw, " \t\r");
    return std.fmt.parseInt(usize, value, 10) catch 0;
}

fn validJail(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn validIp(value: []const u8) bool {
    _ = std.net.Address.parseIp(value, 0) catch return false;
    return true;
}

fn textOf(result: exec.Result, fallback: []const u8) []const u8 {
    const primary = if (result.stderr.len > 0) result.stderr else result.stdout;
    const trimmed = std.mem.trim(u8, primary, " \t\r\n");
    return if (trimmed.len > 0) trimmed else fallback;
}
