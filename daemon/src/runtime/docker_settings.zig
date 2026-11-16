const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const exec = @import("shared").exec;
const validate = @import("shared").validate;

pub const Settings = struct {
    registry_mirrors: []const []const u8 = &.{},
    insecure_registries: []const []const u8 = &.{},
    ipv6: bool = false,
    experimental: bool = false,
    fixed_cidr_v6: []const u8 = "",
    log_driver: []const u8 = "json-file",
    log_max_size: []const u8 = "10m",
    log_max_file: []const u8 = "3",
    iptables: bool = true,
    live_restore: bool = false,
    cgroup_driver: []const u8 = "systemd",
    nvidia_runtime: bool = false,
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
    settings.registry_mirrors = readStringArray(allocator, value, "registry-mirrors");
    settings.insecure_registries = readStringArray(allocator, value, "insecure-registries");
    if (value.object.get("ipv6")) |ipv6_value| {
        if (ipv6_value == .bool) settings.ipv6 = ipv6_value.bool;
    }
    if (value.object.get("experimental")) |experimental_value| {
        if (experimental_value == .bool) settings.experimental = experimental_value.bool;
    }
    if (value.object.get("fixed-cidr-v6")) |cidr_value| {
        if (cidr_value == .string) settings.fixed_cidr_v6 = cidr_value.string;
    }
    if (value.object.get("log-driver")) |log_driver| {
        if (log_driver == .string) settings.log_driver = log_driver.string;
    }
    if (value.object.get("log-opts")) |log_opts| {
        if (log_opts == .object) {
            if (log_opts.object.get("max-size")) |max_size| {
                if (max_size == .string) settings.log_max_size = max_size.string;
            }
            if (log_opts.object.get("max-file")) |max_file| {
                if (max_file == .string) settings.log_max_file = max_file.string;
            }
        }
    }
    if (value.object.get("iptables")) |iptables| {
        if (iptables == .bool) settings.iptables = iptables.bool;
    }
    if (value.object.get("live-restore")) |live_restore| {
        if (live_restore == .bool) settings.live_restore = live_restore.bool;
    }
    if (value.object.get("exec-opts")) |exec_opts| {
        if (exec_opts == .array) {
            for (exec_opts.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.startsWith(u8, item.string, "native.cgroupdriver=")) {
                    settings.cgroup_driver = item.string["native.cgroupdriver=".len..];
                }
            }
        }
    }
    if (value.object.get("default-runtime")) |default_runtime| {
        if (default_runtime == .string and std.mem.eql(u8, default_runtime.string, "nvidia")) {
            settings.nvidia_runtime = true;
        }
    }
    if (value.object.get("runtimes")) |runtimes| {
        if (runtimes == .object and runtimes.object.get("nvidia") != null) {
            settings.nvidia_runtime = true;
        }
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
    for (settings.insecure_registries) |host| {
        if (!validate.isRegistryHost(host)) return error.InvalidRegistry;
    }
    if (settings.fixed_cidr_v6.len > 128) return error.InvalidCidr;
    if (!validLogDriver(settings.log_driver)) return error.InvalidLogDriver;
    if (!validLogSize(settings.log_max_size)) return error.InvalidLogSize;
    if (!validLogFile(settings.log_max_file)) return error.InvalidLogFile;
    if (!std.mem.eql(u8, settings.cgroup_driver, "systemd") and
        !std.mem.eql(u8, settings.cgroup_driver, "cgroupfs") and
        settings.cgroup_driver.len != 0)
    {
        return error.InvalidCgroupDriver;
    }

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

    try root.object.put(allocator, "registry-mirrors", stringArray(allocator, settings.registry_mirrors));
    if (settings.insecure_registries.len > 0) {
        try root.object.put(allocator, "insecure-registries", stringArray(allocator, settings.insecure_registries));
    } else {
        _ = root.object.swapRemove("insecure-registries");
    }
    try root.object.put(allocator, "ipv6", .{ .bool = settings.ipv6 });
    try root.object.put(allocator, "experimental", .{ .bool = settings.experimental });
    if (settings.ipv6 and settings.fixed_cidr_v6.len > 0) {
        try root.object.put(allocator, "fixed-cidr-v6", .{ .string = settings.fixed_cidr_v6 });
    } else {
        _ = root.object.swapRemove("fixed-cidr-v6");
    }
    try root.object.put(allocator, "log-driver", .{ .string = settings.log_driver });
    var log_opts: std.json.ObjectMap = .empty;
    if (root.object.get("log-opts")) |existing| {
        if (existing == .object) {
            var iterator = existing.object.iterator();
            while (iterator.next()) |entry| try log_opts.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try log_opts.put(allocator, "max-size", .{ .string = settings.log_max_size });
    try log_opts.put(allocator, "max-file", .{ .string = settings.log_max_file });
    try root.object.put(allocator, "log-opts", .{ .object = log_opts });
    try root.object.put(allocator, "iptables", .{ .bool = settings.iptables });
    try root.object.put(allocator, "live-restore", .{ .bool = settings.live_restore });

    var exec_opts: std.json.Array = .init(allocator);
    if (root.object.get("exec-opts")) |existing| {
        if (existing == .array) {
            for (existing.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.startsWith(u8, item.string, "native.cgroupdriver=")) continue;
                try exec_opts.append(item);
            }
        }
    }
    if (settings.cgroup_driver.len > 0) {
        try exec_opts.append(.{
            .string = try std.fmt.allocPrint(allocator, "native.cgroupdriver={s}", .{settings.cgroup_driver}),
        });
    }
    if (exec_opts.items.len > 0) {
        try root.object.put(allocator, "exec-opts", .{ .array = exec_opts });
    } else {
        _ = root.object.swapRemove("exec-opts");
    }

    var runtimes: std.json.ObjectMap = .empty;
    if (root.object.get("runtimes")) |existing| {
        if (existing == .object) {
            var iterator = existing.object.iterator();
            while (iterator.next()) |entry| try runtimes.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    if (settings.nvidia_runtime) {
        var nvidia: std.json.ObjectMap = .empty;
        try nvidia.put(allocator, "path", .{ .string = "nvidia-container-runtime" });
        try runtimes.put(allocator, "nvidia", .{ .object = nvidia });
        try root.object.put(allocator, "runtimes", .{ .object = runtimes });
        try root.object.put(allocator, "default-runtime", .{ .string = "nvidia" });
    } else {
        _ = runtimes.swapRemove("nvidia");
        if (runtimes.count() > 0) {
            try root.object.put(allocator, "runtimes", .{ .object = runtimes });
        } else {
            _ = root.object.swapRemove("runtimes");
        }
        if (root.object.get("default-runtime")) |default_runtime| {
            if (default_runtime == .string and std.mem.eql(u8, default_runtime.string, "nvidia")) {
                _ = root.object.swapRemove("default-runtime");
            }
        }
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

fn readStringArray(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) []const []const u8 {
    const entry = value.object.get(key) orelse return &.{};
    if (entry != .array) return &.{};
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (entry.array.items) |item| {
        if (item == .string) list.append(item.string) catch {};
    }
    return list.items;
}

fn stringArray(allocator: std.mem.Allocator, values: []const []const u8) std.json.Value {
    var list: std.json.Array = .init(allocator);
    for (values) |value| list.append(.{ .string = value }) catch {};
    return .{ .array = list };
}

fn validLogDriver(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn validLogSize(value: []const u8) bool {
    if (value.len < 2 or value.len > 16) return false;
    const suffix = value[value.len - 1];
    if (suffix != 'k' and suffix != 'm' and suffix != 'g') return false;
    _ = std.fmt.parseInt(u64, value[0 .. value.len - 1], 10) catch return false;
    return true;
}

fn validLogFile(value: []const u8) bool {
    const count = std.fmt.parseInt(u32, value, 10) catch return false;
    return count >= 1 and count <= 100;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
