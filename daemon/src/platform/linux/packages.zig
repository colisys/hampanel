const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

pub const ToolStatus = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    binary: []const u8,
    installed: bool,
};

pub const Status = struct {
    manager: []const u8,
    available: bool,
    tools: []const ToolStatus,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const Manager = enum {
    apt,
    dnf,
    yum,
    zypper,
    pacman,
    apk,
    none,

    fn name(self: Manager) []const u8 {
        return @tagName(self);
    }
};

const Tool = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    package: []const u8,
    binary: []const u8,
    apt_package: ?[]const u8 = null,
};

const tools = [_]Tool{
    .{ .id = "git", .name = "Git", .description = "分布式版本控制", .package = "git", .binary = "git" },
    .{ .id = "curl", .name = "cURL", .description = "HTTP 请求与下载工具", .package = "curl", .binary = "curl" },
    .{ .id = "wget", .name = "Wget", .description = "命令行下载工具", .package = "wget", .binary = "wget" },
    .{ .id = "htop", .name = "htop", .description = "交互式进程查看器", .package = "htop", .binary = "htop" },
    .{ .id = "vim", .name = "Vim", .description = "终端文本编辑器", .package = "vim", .binary = "vim" },
    .{ .id = "tmux", .name = "tmux", .description = "终端复用器", .package = "tmux", .binary = "tmux" },
    .{ .id = "jq", .name = "jq", .description = "JSON 处理工具", .package = "jq", .binary = "jq" },
    .{ .id = "unzip", .name = "unzip", .description = "ZIP 解压工具", .package = "unzip", .binary = "unzip" },
    .{ .id = "rsync", .name = "rsync", .description = "增量文件同步", .package = "rsync", .binary = "rsync" },
    .{ .id = "tree", .name = "tree", .description = "目录树展示", .package = "tree", .binary = "tree" },
    .{ .id = "ncdu", .name = "ncdu", .description = "磁盘占用分析", .package = "ncdu", .binary = "ncdu" },
    .{ .id = "zstd", .name = "zstd", .description = "Zstandard 压缩工具", .package = "zstd", .binary = "zstd" },
    .{ .id = "ripgrep", .name = "ripgrep", .description = "快速文本搜索 (rg)", .package = "ripgrep", .binary = "rg" },
    .{ .id = "fail2ban", .name = "Fail2ban", .description = "SSH 等服务防暴力破解", .package = "fail2ban", .binary = "fail2ban-client" },
    .{ .id = "rsyslog", .name = "rsyslog", .description = "传统文件日志服务（SSH 文件模式）", .package = "rsyslog", .binary = "rsyslogd" },
    .{ .id = "nix", .name = "Nix", .description = "可复现构建与运行环境（本面板使用精选属性）", .package = "nix", .binary = "nix", .apt_package = "nix-bin" },
};

pub fn list(allocator: std.mem.Allocator) !Status {
    const manager = detect(allocator);
    var items = std.array_list.Managed(ToolStatus).init(allocator);
    for (tools) |tool| {
        try items.append(.{
            .id = tool.id,
            .name = tool.name,
            .description = tool.description,
            .binary = tool.binary,
            .installed = binaryExists(allocator, tool.binary),
        });
    }
    return .{
        .manager = manager.name(),
        .available = manager != .none,
        .tools = items.items,
    };
}

pub fn install(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    const tool = findTool(id) orelse return error.UnknownTool;
    const manager = detect(allocator);
    if (manager == .none) return error.ManagerUnavailable;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    const package = packageFor(tool, manager);
    switch (manager) {
        .apt => try argv.appendSlice(&.{
            "apt-get", "-y",
            "-o",      "Dpkg::Options::=--force-confdef",
            "-o",      "Dpkg::Options::=--force-confold",
            "install", package,
        }),
        .dnf => try argv.appendSlice(&.{ "dnf", "install", "-y", package }),
        .yum => try argv.appendSlice(&.{ "yum", "install", "-y", package }),
        .zypper => try argv.appendSlice(&.{ "zypper", "--non-interactive", "install", package }),
        .pacman => try argv.appendSlice(&.{ "pacman", "-S", "--noconfirm", "--needed", package }),
        .apk => try argv.appendSlice(&.{ "apk", "add", "--no-cache", package }),
        .none => unreachable,
    }

    var result = exec.run(allocator, argv.items, 8 * 1024 * 1024) catch return error.ManagerUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn refresh(allocator: std.mem.Allocator) !Outcome {
    const manager = detect(allocator);
    if (manager == .none) return error.ManagerUnavailable;

    const argv: []const []const u8 = switch (manager) {
        .apt => &.{ "apt-get", "update" },
        .dnf => &.{ "dnf", "makecache" },
        .yum => &.{ "yum", "makecache" },
        .zypper => &.{ "zypper", "--non-interactive", "refresh" },
        .pacman => &.{ "pacman", "-Sy", "--noconfirm" },
        .apk => &.{ "apk", "update" },
        .none => unreachable,
    };

    var result = exec.run(allocator, argv, 8 * 1024 * 1024) catch return error.ManagerUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn detect(allocator: std.mem.Allocator) Manager {
    if (binaryExists(allocator, "apt-get")) return .apt;
    if (binaryExists(allocator, "dnf")) return .dnf;
    if (binaryExists(allocator, "yum")) return .yum;
    if (binaryExists(allocator, "zypper")) return .zypper;
    if (binaryExists(allocator, "pacman")) return .pacman;
    if (binaryExists(allocator, "apk")) return .apk;
    return .none;
}

fn packageFor(tool: Tool, manager: Manager) []const u8 {
    if (manager == .apt) return tool.apt_package orelse tool.package;
    return tool.package;
}

fn findTool(id: []const u8) ?Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.id, id)) return tool;
    }
    return null;
}

fn binaryExists(allocator: std.mem.Allocator, binary: []const u8) bool {
    const path = compat.getEnv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = compat.path.join(allocator, &.{ dir, binary }) catch continue;
        compat.cwd().access(full, .{}) catch continue;
        return true;
    }
    return false;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
