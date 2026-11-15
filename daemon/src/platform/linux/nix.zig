const std = @import("std");
const exec = @import("shared").exec;

pub const Target = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Status = struct {
    available: bool,
    version: []const u8,
    flakes: bool,
    targets: []const Target,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const targets = [_]Target{
    .{ .id = "hello", .name = "GNU hello", .description = "经典示例程序，用于验证 Nix 环境" },
    .{ .id = "jq", .name = "jq", .description = "JSON 处理工具" },
    .{ .id = "ripgrep", .name = "ripgrep", .description = "快速文本搜索" },
    .{ .id = "fd", .name = "fd", .description = "友好的 find 替代品" },
    .{ .id = "bat", .name = "bat", .description = "带语法高亮的 cat" },
    .{ .id = "htop", .name = "htop", .description = "进程查看器" },
    .{ .id = "tree", .name = "tree", .description = "目录树展示" },
    .{ .id = "cowsay", .name = "cowsay", .description = "终端趣味输出" },
};

const experimental = "--extra-experimental-features";

pub fn status(allocator: std.mem.Allocator) !Status {
    var version_result = exec.run(allocator, &.{ "nix", "--version" }, 64 * 1024) catch {
        return .{ .available = false, .version = "", .flakes = false, .targets = &targets };
    };
    if (!version_result.ok()) {
        return .{ .available = false, .version = "", .flakes = false, .targets = &targets };
    }

    const version = std.mem.trim(u8, version_result.stdout, " \t\r\n");
    var flake_result = exec.run(allocator, &.{
        "nix", experimental, "nix-command flakes", "flake", "--help",
    }, 256 * 1024) catch {
        return .{ .available = true, .version = version, .flakes = false, .targets = &targets };
    };

    return .{
        .available = true,
        .version = version,
        .flakes = flake_result.ok(),
        .targets = &targets,
    };
}

pub fn build(allocator: std.mem.Allocator, target: []const u8) !Outcome {
    const attribute = try resolveAttribute(target);
    const flake = try std.fmt.allocPrint(allocator, "nixpkgs#{s}", .{attribute});

    var result = exec.run(allocator, &.{
        "nix",   experimental, "nix-command flakes",
        "build", "--no-link",  "--print-out-paths",
        flake,
    }, 8 * 1024 * 1024) catch return error.NixUnavailable;

    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn run(allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !Outcome {
    const attribute = try resolveAttribute(target);
    if (args.len > 32) return error.InvalidTarget;
    for (args) |arg| {
        if (arg.len > 256) return error.InvalidTarget;
        for (arg) |ch| {
            if (ch < 0x20 or ch == 0x7f) return error.InvalidTarget;
        }
    }

    const flake = try std.fmt.allocPrint(allocator, "nixpkgs#{s}", .{attribute});
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{
        "nix", experimental, "nix-command flakes",
        "run", flake,        "--",
    });
    try argv.appendSlice(args);

    var result = exec.run(allocator, argv.items, 8 * 1024 * 1024) catch return error.NixUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

/// 精选列表之外允许安装任意 nixpkgs 属性名；属性语法受限，不接受
/// URL、flake 引用或 shell 元字符。
fn resolveAttribute(target: []const u8) ![]const u8 {
    if (findTarget(target)) |found| return found.id;
    if (target.len == 0 or target.len > 96) return error.InvalidTarget;
    for (target) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '.' or ch == '_' or ch == '-' or ch == '+') continue;
        return error.InvalidTarget;
    }
    return target;
}

fn findTarget(id: []const u8) ?Target {
    for (targets) |target| {
        if (std.mem.eql(u8, target.id, id)) return target;
    }
    return null;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
