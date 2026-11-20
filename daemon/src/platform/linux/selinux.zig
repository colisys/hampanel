const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// SELinux policy control.
///
/// Everything is probed: a host running AppArmor has no `/sys/fs/selinux`, so
/// the panel must say "not present" rather than show switches that cannot work.
/// The persistent mode lives in `/etc/selinux/config` and only takes effect on
/// reboot; the live mode is switched through `setenforce`.
pub const Status = struct {
    /// `/sys/fs/selinux` exists: the kernel actually has SELinux enabled.
    present: bool,
    /// Live mode from `/sys/fs/selinux/enforce`; null when SELinux is absent.
    enforcing: ?bool,
    /// Mode recorded in `/etc/selinux/config` (enforcing/permissive/disabled).
    configured: []const u8,
    /// Policy name from `SELINUXTYPE=`.
    policy: []const u8,
    /// `setenforce` / `getsebool` / `setsebool` resolved from PATH.
    tooling: bool,
    booleans: []const Boolean,
    message: []const u8 = "",
};

pub const Boolean = struct {
    name: []const u8,
    enabled: bool,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    /// Set when the change only applies after a reboot.
    reboot_required: bool = false,
};

pub const config_path = "/etc/selinux/config";

pub fn status(allocator: std.mem.Allocator) !Status {
    const present = exists("/sys/fs/selinux");
    const tooling = exec.commandExists(allocator, "setenforce") and
        exec.commandExists(allocator, "getsebool") and
        exec.commandExists(allocator, "setsebool");

    const configured = try readConfigured(allocator);
    const policy = try readPolicy(allocator);
    const enforcing = readEnforcing(allocator);

    var booleans: []const Boolean = &.{};
    if (present and tooling) booleans = try listBooleans(allocator);

    var message: []const u8 = "";
    if (!present) {
        message = "当前主机未启用 SELinux（可能使用 AppArmor）；不会展示无法生效的策略开关。";
    } else if (!tooling) {
        message = "未安装 setenforce/getsebool/setsebool，只能查看状态，无法修改策略。";
    }

    return .{
        .present = present,
        .enforcing = enforcing,
        .configured = configured,
        .policy = policy,
        .tooling = tooling,
        .booleans = booleans,
        .message = message,
    };
}

/// Switches the live mode. `disabled` is not a live operation: SELinux can only
/// be turned off through the config file plus a reboot.
pub fn setMode(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "setenforce")) return error.ToolingUnavailable;

    if (std.mem.eql(u8, mode, "enforcing")) {
        const result = exec.run(allocator, &.{ "setenforce", "1" }, 64 * 1024) catch
            return error.ToolingUnavailable;
        return .{ .ok = result.ok(), .output = textOf(result) };
    }
    if (std.mem.eql(u8, mode, "permissive")) {
        const result = exec.run(allocator, &.{ "setenforce", "0" }, 64 * 1024) catch
            return error.ToolingUnavailable;
        return .{ .ok = result.ok(), .output = textOf(result) };
    }
    if (std.mem.eql(u8, mode, "disabled")) {
        try writeConfigured(allocator, "disabled");
        return .{
            .ok = true,
            .output = "已写入 /etc/selinux/config；禁用 SELinux 需要重启主机后才生效",
            .reboot_required = true,
        };
    }
    return error.InvalidMode;
}

pub fn setBoolean(allocator: std.mem.Allocator, name: []const u8, enabled: bool) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "setsebool")) return error.ToolingUnavailable;
    if (!validBooleanName(name)) return error.InvalidBoolean;

    // Only names the policy actually declares may be written: anything else is
    // either a typo or an attempt to reach setsebool with unexpected input.
    const known = try listBooleans(allocator);
    defer {
        for (known) |entry| allocator.free(entry.name);
        allocator.free(known);
    }
    var found = false;
    for (known) |entry| {
        if (std.mem.eql(u8, entry.name, name)) found = true;
    }
    if (!found) return error.InvalidBoolean;

    const result = exec.run(
        allocator,
        &.{ "setsebool", "-P", name, if (enabled) "on" else "off" },
        256 * 1024,
    ) catch return error.ToolingUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn validBooleanName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

fn readEnforcing(allocator: std.mem.Allocator) ?bool {
    const raw = compat.cwd().readFileAlloc(allocator, "/sys/fs/selinux/enforce", 8) catch return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \r\n\t");
    if (text.len == 0) return null;
    return std.mem.eql(u8, text, "1");
}

fn readConfigured(allocator: std.mem.Allocator) ![]const u8 {
    return (try parseConfig(allocator, config_path, "SELINUX=")) orelse
        try allocator.dupe(u8, "");
}

fn readPolicy(allocator: std.mem.Allocator) ![]const u8 {
    return (try parseConfig(allocator, config_path, "SELINUXTYPE=")) orelse
        try allocator.dupe(u8, "");
}

/// Reads one `KEY=value` line. Comments and surrounding whitespace are ignored
/// because the file is hand-edited on most hosts.
pub fn parseConfigValue(
    allocator: std.mem.Allocator,
    contents: []const u8,
    key: []const u8,
) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or text[0] == '#') continue;
        if (!std.mem.startsWith(u8, text, key)) continue;
        return try allocator.dupe(u8, std.mem.trim(u8, text[key.len..], " \r\t"));
    }
    return null;
}

fn parseConfig(allocator: std.mem.Allocator, path: []const u8, key: []const u8) !?[]const u8 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(raw);
    return parseConfigValue(allocator, raw, key);
}

fn writeConfigured(allocator: std.mem.Allocator, mode: []const u8) !void {
    if (!std.mem.eql(u8, mode, "enforcing") and !std.mem.eql(u8, mode, "permissive") and
        !std.mem.eql(u8, mode, "disabled")) return error.InvalidMode;
    const raw = compat.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch
        try allocator.dupe(u8, "");
    defer allocator.free(raw);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    var replaced = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (!replaced and text.len > 0 and text[0] != '#' and
            std.mem.startsWith(u8, text, "SELINUX="))
        {
            try out.appendSlice(try std.fmt.allocPrint(allocator, "SELINUX={s}\n", .{mode}));
            replaced = true;
            continue;
        }
        if (line.len == 0 and !replaced) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    if (!replaced) try out.appendSlice(try std.fmt.allocPrint(allocator, "SELINUX={s}\n", .{mode}));

    var file = try compat.createFileAbsolute(config_path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(out.items);
}

/// `getsebool -a` prints lines like `httpd_can_network_connect --> off`.
pub fn parseBooleans(allocator: std.mem.Allocator, output: []const u8) ![]const Boolean {
    var list = std.array_list.Managed(Boolean).init(allocator);
    errdefer {
        for (list.items) |entry| allocator.free(entry.name);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        const arrow = std.mem.indexOf(u8, text, "-->") orelse continue;
        const name = std.mem.trim(u8, text[0..arrow], " \t:");
        const value = std.mem.trim(u8, text[arrow + 3 ..], " \r\t");
        if (!validBooleanName(name)) continue;
        try list.append(.{
            .name = try allocator.dupe(u8, name),
            .enabled = std.mem.eql(u8, value, "on"),
        });
    }
    const owned = try allocator.dupe(Boolean, list.items);
    list.deinit();
    return owned;
}

fn listBooleans(allocator: std.mem.Allocator) ![]const Boolean {
    const result = exec.run(allocator, &.{ "getsebool", "-a" }, 1024 * 1024) catch
        return &.{};
    if (!result.ok()) return &.{};
    return parseBooleans(allocator, result.stdout);
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
