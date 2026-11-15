const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Status = struct {
    swap_total_bytes: u64,
    swap_used_bytes: u64,
    swapfile_path: []const u8,
    swapfile_bytes: u64,
    swapfile_active: bool,
    ntp_enabled: bool,
    ntp_synchronized: bool,
    timezone: []const u8,
    hosts_content: []const u8,
    grub_default: []const u8,
    grub_entries: []const []const u8,
};

const swapfile = "/swapfile";
const max_hosts_bytes = 512 * 1024;

pub fn status(allocator: std.mem.Allocator) !Status {
    const swap = try swapInfo(allocator);
    const time = timeInfo(allocator);
    return .{
        .swap_total_bytes = swap.total,
        .swap_used_bytes = swap.used,
        .swapfile_path = swapfile,
        .swapfile_bytes = swap.file_bytes,
        .swapfile_active = swap.file_active,
        .ntp_enabled = time.ntp,
        .ntp_synchronized = time.synchronized,
        .timezone = time.timezone,
        .hosts_content = compat.cwd().readFileAlloc(allocator, "/etc/hosts", max_hosts_bytes) catch "",
        .grub_default = grubDefault(allocator) catch "",
        .grub_entries = grubEntries(allocator) catch &.{},
    };
}

pub fn setSwap(allocator: std.mem.Allocator, size_mb: u32) !Outcome {
    if (size_mb == 0) return disableSwap(allocator);
    if (size_mb < 64 or size_mb > 65536) return error.InvalidSize;

    const size_text = try std.fmt.allocPrint(allocator, "{d}M", .{size_mb});
    var output = std.array_list.Managed(u8).init(allocator);

    var created = false;
    if (exec.run(allocator, &.{ "fallocate", "-l", size_text, swapfile }, 1024 * 1024)) |result| {
        if (result.ok()) {
            append(&output, result);
            created = true;
        }
    } else |_| {}
    if (!created) {
        const count_arg = try std.fmt.allocPrint(allocator, "count={d}", .{size_mb});
        const dd = exec.run(allocator, &.{ "dd", "if=/dev/zero", "of=" ++ swapfile, "bs=1M", count_arg, "status=none" }, 1024 * 1024) catch
            return error.ToolMissing;
        if (!dd.ok()) return .{ .ok = false, .output = errText(dd) };
        append(&output, dd);
    }

    if (compat.openFileAbsolute(swapfile, .{})) |file| {
        file.chmod(0o600) catch {};
        file.close();
    } else |_| {}

    const format = exec.run(allocator, &.{ "mkswap", swapfile }, 1024 * 1024) catch return error.ToolMissing;
    if (!format.ok()) return .{ .ok = false, .output = errText(format) };
    append(&output, format);

    const enable = exec.run(allocator, &.{ "swapon", swapfile }, 1024 * 1024) catch return error.ToolMissing;
    if (!enable.ok()) return .{ .ok = false, .output = errText(enable) };
    append(&output, enable);

    try ensureFstabEntry(allocator);
    return .{ .ok = true, .output = output.items };
}

fn disableSwap(allocator: std.mem.Allocator) !Outcome {
    const disable = exec.run(allocator, &.{ "swapoff", swapfile }, 1024 * 1024) catch null;
    compat.deleteFileAbsolute(swapfile) catch {};
    try removeFstabEntry(allocator);
    const output = if (disable) |result| errText(result) else "已关闭交换文件";
    return .{ .ok = true, .output = output };
}

fn ensureFstabEntry(allocator: std.mem.Allocator) !void {
    const content = compat.cwd().readFileAlloc(allocator, "/etc/fstab", 256 * 1024) catch "";
    var has_entry = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), swapfile)) has_entry = true;
    }
    if (has_entry) return;
    const addition = if (content.len == 0 or content[content.len - 1] == '\n')
        swapfile ++ " none swap sw 0 0\n"
    else
        "\n" ++ swapfile ++ " none swap sw 0 0\n";
    var file = try compat.openFileAbsolute("/etc/fstab", .{ .mode = .write_only });
    defer file.close();
    try file.writePositionalAll(addition, content.len);
}

fn removeFstabEntry(allocator: std.mem.Allocator) !void {
    const content = compat.cwd().readFileAlloc(allocator, "/etc/fstab", 256 * 1024) catch return;
    var kept = std.array_list.Managed(u8).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try kept.append('\n');
        first = false;
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), swapfile)) continue;
        try kept.appendSlice(line);
    }
    try writeFile("/etc/fstab", kept.items);
}

/// 使用已有分区/设备作为交换空间。只执行 swapon，不格式化块设备。
pub fn enableSwapDevice(allocator: std.mem.Allocator, device: []const u8) !Outcome {
    if (!validDevice(device)) return error.InvalidDevice;
    const result = exec.run(allocator, &.{ "swapon", device }, 1024 * 1024) catch
        return error.ToolMissing;
    return .{ .ok = result.ok(), .output = errText(result) };
}

fn validDevice(device: []const u8) bool {
    if (device.len <= 5 or device.len > 128) return false;
    if (!std.mem.startsWith(u8, device, "/dev/")) return false;
    if (std.mem.indexOf(u8, device, "..") != null) return false;
    for (device) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '/' or ch == '.' or ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

pub fn setNtp(allocator: std.mem.Allocator, enabled: bool) !Outcome {
    const value = if (enabled) "true" else "false";
    const result = exec.run(allocator, &.{ "timedatectl", "set-ntp", value }, 1024 * 1024) catch
        return error.TimeSyncUnavailable;
    return .{ .ok = result.ok(), .output = errText(result) };
}

pub fn saveHosts(allocator: std.mem.Allocator, content: []const u8) !Outcome {
    _ = allocator;
    if (content.len > max_hosts_bytes) return error.ContentTooLarge;
    if (std.mem.indexOfScalar(u8, content, 0) != null) return error.InvalidContent;
    try writeFile("/etc/hosts", content);
    return .{ .ok = true, .output = "已保存 /etc/hosts" };
}

pub fn setGrubDefault(allocator: std.mem.Allocator, index: usize) !Outcome {
    const entries = try grubEntries(allocator);
    if (entries.len == 0) return error.GrubUnavailable;
    if (index >= entries.len) return error.InvalidEntry;

    const content = compat.cwd().readFileAlloc(allocator, "/etc/default/grub", 256 * 1024) catch
        return error.GrubUnavailable;
    const value = try std.fmt.allocPrint(allocator, "{d}", .{index});
    var updated = std.array_list.Managed(u8).init(allocator);
    var found = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try updated.append('\n');
        first = false;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "GRUB_DEFAULT=")) {
            try updated.appendSlice("GRUB_DEFAULT=");
            try updated.appendSlice(value);
            found = true;
            continue;
        }
        try updated.appendSlice(line);
    }
    if (!found) {
        if (updated.items.len > 0 and updated.items[updated.items.len - 1] != '\n') try updated.append('\n');
        try updated.appendSlice("GRUB_DEFAULT=");
        try updated.appendSlice(value);
        try updated.append('\n');
    }
    try writeFile("/etc/default/grub", updated.items);

    const result = if (binaryExists(allocator, "update-grub"))
        exec.run(allocator, &.{"update-grub"}, 4 * 1024 * 1024) catch return error.GrubUnavailable
    else if (binaryExists(allocator, "grub2-mkconfig"))
        exec.run(allocator, &.{ "grub2-mkconfig", "-o", "/boot/grub2/grub.cfg" }, 4 * 1024 * 1024) catch
            return error.GrubUnavailable
    else
        return error.GrubUnavailable;

    return .{ .ok = result.ok(), .output = errText(result) };
}

const SwapInfo = struct { total: u64, used: u64, file_bytes: u64, file_active: bool };

fn swapInfo(allocator: std.mem.Allocator) !SwapInfo {
    const raw = compat.cwd().readFileAlloc(allocator, "/proc/swaps", 256 * 1024) catch
        return .{ .total = 0, .used = 0, .file_bytes = 0, .file_active = false };
    var result = SwapInfo{ .total = 0, .used = 0, .file_bytes = 0, .file_active = false };
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const size_kb = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const used_kb = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        result.total += size_kb * 1024;
        result.used += used_kb * 1024;
        if (std.mem.eql(u8, name, swapfile)) {
            result.file_bytes = size_kb * 1024;
            result.file_active = true;
        }
    }
    return result;
}

const TimeInfo = struct { ntp: bool, synchronized: bool, timezone: []const u8 };

fn timeInfo(allocator: std.mem.Allocator) TimeInfo {
    const result = exec.run(
        allocator,
        &.{ "timedatectl", "show", "-p", "NTP", "-p", "NTPSynchronized", "-p", "Timezone" },
        256 * 1024,
    ) catch return .{ .ntp = false, .synchronized = false, .timezone = "" };

    var info = TimeInfo{ .ntp = false, .synchronized = false, .timezone = "" };
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "NTP")) info.ntp = std.mem.eql(u8, value, "yes");
        if (std.mem.eql(u8, key, "NTPSynchronized")) info.synchronized = std.mem.eql(u8, value, "yes");
        if (std.mem.eql(u8, key, "Timezone")) info.timezone = value;
    }
    return info;
}

fn grubDefault(allocator: std.mem.Allocator) ![]const u8 {
    const content = try compat.cwd().readFileAlloc(allocator, "/etc/default/grub", 256 * 1024);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "GRUB_DEFAULT=")) {
            return std.mem.trim(u8, trimmed["GRUB_DEFAULT=".len..], "\"'");
        }
    }
    return "0";
}

fn grubEntries(allocator: std.mem.Allocator) ![]const []const u8 {
    const content = compat.cwd().readFileAlloc(allocator, "/boot/grub/grub.cfg", 4 * 1024 * 1024) catch
        return &.{};
    var entries = std.array_list.Managed([]const u8).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "menuentry ")) continue;
        const quote: u8 = if (std.mem.indexOfScalar(u8, trimmed, '\'')) |_| '\'' else '"';
        const start = std.mem.indexOfScalar(u8, trimmed, quote) orelse continue;
        const rest = trimmed[start + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, quote) orelse continue;
        try entries.append(try allocator.dupe(u8, rest[0..end]));
    }
    return entries.items;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(data);
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

fn append(out: *std.array_list.Managed(u8), result: exec.Result) void {
    const text = if (result.stderr.len > 0) result.stderr else result.stdout;
    if (text.len == 0) return;
    if (out.items.len > 0) out.append('\n') catch {};
    out.appendSlice(text) catch {};
}

fn errText(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    if (result.stdout.len > 0) return result.stdout;
    return if (result.ok()) "完成" else "操作失败";
}
