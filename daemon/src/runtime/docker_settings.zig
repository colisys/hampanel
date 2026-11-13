const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const exec = @import("shared").exec;

pub const Settings = struct {
    registry_mirrors: []const []const u8 = &.{},
    ipv6: bool = false,
    experimental: bool = false,
    fixed_cidr_v6: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    restart_required: bool = true,
};

pub fn configPath() []const u8 {
    if (compat.getEnv("HAMPANEL_DOCKER_CONFIG")) |override| return override;
    return if (builtin.os.tag == .windows)
        "C:\\ProgramData\\docker\\config\\daemon.json"
    else
        "/etc/docker/daemon.json";
}

pub fn read(allocator: std.mem.Allocator) !Settings {
    const data = compat.cwd().readFileAlloc(allocator, configPath(), 1024 * 1024) catch
        return Settings{};
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return Settings{};
    if (value != .object) return Settings{};

    var settings = Settings{};
    if (value.object.get("registry-mirrors")) |mirrors_value| {
        if (mirrors_value == .array) {
            var mirrors = std.array_list.Managed([]const u8).init(allocator);
            for (mirrors_value.array.items) |item| {
                if (item == .string) try mirrors.append(item.string);
            }
            settings.registry_mirrors = mirrors.items;
        }
    }
    if (value.object.get("ipv6")) |ipv6_value| {
        if (ipv6_value == .bool) settings.ipv6 = ipv6_value.bool;
    }
    if (value.object.get("experimental")) |experimental_value| {
        if (experimental_value == .bool) settings.experimental = experimental_value.bool;
    }
    if (value.object.get("fixed-cidr-v6")) |cidr_value| {
        if (cidr_value == .string) settings.fixed_cidr_v6 = cidr_value.string;
    }
    return settings;
}

pub fn apply(allocator: std.mem.Allocator, settings: Settings, restart: bool) !Outcome {
    for (settings.registry_mirrors) |mirror| {
        if (!std.mem.startsWith(u8, mirror, "http://") and !std.mem.startsWith(u8, mirror, "https://")) {
            return error.InvalidMirror;
        }
        if (mirror.len > 512) return error.InvalidMirror;
    }
    if (settings.fixed_cidr_v6.len > 128) return error.InvalidCidr;

    const path = configPath();
    const existing_text = compat.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;

    var root: std.json.Value = .{ .object = .empty };
    if (existing_text) |text| {
        if (std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        })) |value| {
            if (value == .object) root = value;
        } else |_| {
            return error.InvalidDaemonJson;
        }
    }
    if (root != .object) return error.InvalidDaemonJson;

    var mirrors: std.json.Array = .init(allocator);
    for (settings.registry_mirrors) |mirror| try mirrors.append(.{ .string = mirror });
    try root.object.put(allocator, "registry-mirrors", .{ .array = mirrors });
    try root.object.put(allocator, "ipv6", .{ .bool = settings.ipv6 });
    try root.object.put(allocator, "experimental", .{ .bool = settings.experimental });
    if (settings.ipv6 and settings.fixed_cidr_v6.len > 0) {
        try root.object.put(allocator, "fixed-cidr-v6", .{ .string = settings.fixed_cidr_v6 });
    } else {
        _ = root.object.swapRemove("fixed-cidr-v6");
    }

    const body = try std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
    if (compat.path.dirname(path)) |dir| try compat.cwd().makePath(dir);

    if (existing_text) |text| {
        const stamp = try std.fmt.allocPrint(allocator, "{s}.bak-{d}", .{ path, compat.timestamp() });
        const backup = try compat.createFileAbsolute(stamp, .{ .truncate = true, .mode = 0o600 });
        defer backup.close();
        try backup.writeAll(text);
    }

    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(body);
    try file.writeAll("\n");

    if (!restart) return .{ .ok = true, .output = "daemon.json 已写入；重启 Docker 后生效" };

    const result = if (builtin.os.tag == .windows)
        try exec.run(allocator, &.{ "powershell.exe", "-NoProfile", "-Command", "Restart-Service docker" }, 1024 * 1024)
    else
        try exec.run(allocator, &.{ "systemctl", "restart", "docker" }, 1024 * 1024);

    return .{
        .ok = result.ok(),
        .output = if (result.ok()) "daemon.json 已写入并重启 Docker" else textOf(result),
    };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
