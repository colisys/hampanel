const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Active host reconnaissance.
///
/// Scanning a host sends packets from the panel itself, so the target is
/// validated as a literal IPv4 address or RFC 1123 hostname before anything is
/// executed. No shell is involved: nmap receives argv entries, never a string.
pub const Report = struct {
    target: []const u8,
    /// Human-readable summary, newest-first.
    os_guess: []const u8,
    os_accuracy: u8,
    ports: []const Port,
    hostnames: []const []const u8,
    intel: ?Intel,
    nmap_available: bool,
    message: []const u8,
};

pub const Port = struct {
    port: u16,
    protocol: []const u8,
    state: []const u8,
    service: []const u8,
    product: []const u8,
    version: []const u8,
};

/// Free, key-less passive intel from Shodan InternetDB. Used as a fallback so a
/// probe still returns something when nmap is missing or blocked.
pub const Intel = struct {
    ports: []const u16,
    hostnames: []const []const u8,
    tags: []const []const u8,
    vulns: []const []const u8,
};

pub const Options = struct {
    /// "fast" limits to the top 100 ports; "full" scans 1-65535.
    intensity: []const u8 = "fast",
    /// OS detection needs raw sockets, so it is refused for unprivileged runs.
    os_detection: bool = true,
    service_detection: bool = true,
};

pub fn isSafeTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > 253) return false;
    if (std.mem.indexOfAny(u8, target, " /\\@?#$'\"`;|&<>()[]{}*!") != null) return false;
    // Reject anything that could be read as an nmap flag or a range/list spec.
    if (target[0] == '-') return false;
    if (std.mem.indexOf(u8, target, ",") != null) return false;
    if (std.mem.indexOf(u8, target, "..") != null) return false;

    if (std.mem.indexOf(u8, target, ":") == null and std.mem.indexOf(u8, target, ".") == null) {
        // Bare hostnames such as "localhost" are fine; single labels like "eth0"
        // are not worth rejecting either, but they must stay label-shaped.
        return isHostname(target);
    }
    if (isIpv4(target)) return true;
    if (isIpv6(target)) return true;
    // "999.1.1.1" is hostname-shaped but is a mistyped IP; refuse it rather
    // than resolving something the operator did not mean.
    if (isDottedNumeric(target)) return false;
    return isHostname(target);
}

fn isIpv6(target: []const u8) bool {
    if (std.mem.indexOf(u8, target, ":") == null) return false;
    // Scope ids ("fe80::1%eth0") are operator input we cannot validate, and a
    // bare zone would end up as an nmap argument we do not control.
    if (std.mem.indexOf(u8, target, "%") != null) return false;
    _ = std.Io.net.IpAddress.parseIp6(target, 0) catch return false;
    return true;
}

fn isDottedNumeric(target: []const u8) bool {
    var saw_dot = false;
    for (target) |c| {
        if (c == '.') {
            saw_dot = true;
            continue;
        }
        if (!std.ascii.isDigit(c)) return false;
    }
    return saw_dot;
}

fn isIpv4(target: []const u8) bool {
    var parts = std.mem.splitScalar(u8, target, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        const value = std.fmt.parseInt(u16, part, 10) catch return false;
        if (value > 255) return false;
        count += 1;
    }
    return count == 4;
}

fn isHostname(target: []const u8) bool {
    var labels = std.mem.splitScalar(u8, target, '.');
    var labels_seen: usize = 0;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        for (label) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
            if (!ok) return false;
        }
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        labels_seen += 1;
    }
    return labels_seen > 0;
}

pub fn probe(allocator: std.mem.Allocator, target: []const u8, options: Options) !Report {
    if (!isSafeTarget(target)) return error.InvalidTarget;

    const nmap_available = blk: {
        const check = exec.run(allocator, &.{ "nmap", "--version" }, 64 * 1024) catch break :blk false;
        break :blk check.ok();
    };

    var ports = std.array_list.Managed(Port).init(allocator);
    var hostnames = std.array_list.Managed([]const u8).init(allocator);
    var os_guess: []const u8 = "";
    var os_accuracy: u8 = 0;
    var message: []const u8 = "";

    if (!nmap_available) {
        message = "服务器未安装 nmap，仅返回被动情报";
    } else {
        if (runNmap(allocator, target, options)) |body| {
            var os: OsGuess = .{};
            parseNmap(&ports, &hostnames, &os, body) catch {};
            os_guess = os.guess;
            os_accuracy = os.accuracy;
            allocator.free(body);
        } else |err| {
            message = switch (err) {
                error.NmapFailed => "nmap 扫描失败（可能需要 root 或目标不可达）",
                else => "nmap 执行失败",
            };
        }
    }

    const intel = fetchIntel(allocator, target) catch null;

    return .{
        .target = target,
        .os_guess = os_guess,
        .os_accuracy = os_accuracy,
        .ports = ports.items,
        .hostnames = hostnames.items,
        .intel = intel,
        .nmap_available = nmap_available,
        .message = message,
    };
}

fn runNmap(allocator: std.mem.Allocator, target: []const u8, options: Options) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "nmap", "-oX", "-" });
    if (isIpv6(target)) try argv.append("-6");
    try argv.append(if (std.mem.eql(u8, options.intensity, "full")) "-p-" else "-F");
    if (options.os_detection) try argv.append("-O");
    if (options.service_detection) try argv.append("-sV");
    try argv.append("--host-timeout");
    try argv.append(if (std.mem.eql(u8, options.intensity, "full")) "10m" else "2m");
    try argv.append("--");
    try argv.append(target);

    const result = exec.run(allocator, argv.items, 8 * 1024 * 1024) catch
        return error.NmapFailed;
    if (result.stdout.len == 0) return error.NmapFailed;
    return allocator.dupe(u8, result.stdout);
}

/// The XML is only used to read a handful of fields, so a scan over the tags is
/// enough and avoids pulling a full XML parser into the daemon.
pub const OsGuess = struct { guess: []const u8 = "", accuracy: u8 = 0 };

pub fn parseNmap(
    ports: *std.array_list.Managed(Port),
    hostnames: *std.array_list.Managed([]const u8),
    last_os: *OsGuess,
    xml: []const u8,
) !void {

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, xml, cursor, "<port ")) |start| {
        const end = std.mem.indexOfPos(u8, xml, start, "</port>") orelse break;
        const chunk = xml[start..end];
        cursor = end + 1;
        const number = attr(chunk, "portid") orelse continue;
        const protocol = attr(chunk, "protocol") orelse continue;
        const state = tagAttr(chunk, "<state", "state") orelse continue;
        if (!std.mem.eql(u8, state, "open")) continue;
        try ports.append(.{
            .port = std.fmt.parseInt(u16, number, 10) catch continue,
            .protocol = protocol,
            .state = state,
            .service = attrIn(chunk, "<service", "name") orelse "",
            .product = attrIn(chunk, "<service", "product") orelse "",
            .version = attrIn(chunk, "<service", "version") orelse "",
        });
    }

    cursor = 0;
    while (std.mem.indexOfPos(u8, xml, cursor, "<hostname ")) |start| {
        const end = std.mem.indexOfPos(u8, xml, start, "/>") orelse break;
        const chunk = xml[start..end];
        cursor = end + 1;
        const name = attr(chunk, "name") orelse continue;
        try hostnames.append(name);
    }

    var os_guess: []const u8 = "";
    var os_accuracy: u8 = 0;
    if (std.mem.indexOf(u8, xml, "<osmatch ")) |start| {
        const end = std.mem.indexOfPos(u8, xml, start, ">") orelse xml.len;
        const chunk = xml[start..end];
        os_guess = attr(chunk, "name") orelse "";
        os_accuracy = if (attr(chunk, "accuracy")) |value|
            std.fmt.parseInt(u8, value, 10) catch 0
        else
            0;
    }

    if (os_guess.len > 0) last_os.* = .{ .guess = os_guess, .accuracy = os_accuracy };
}

fn attr(chunk: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, chunk, needle) orelse return null;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfPos(u8, chunk, value_start, "\"") orelse return null;
    return chunk[value_start..value_end];
}

fn tagAttr(chunk: []const u8, tag: []const u8, name: []const u8) ?[]const u8 {
    const tag_start = std.mem.indexOf(u8, chunk, tag) orelse return null;
    return attr(chunk[tag_start..], name);
}

fn attrIn(chunk: []const u8, tag: []const u8, name: []const u8) ?[]const u8 {
    return tagAttr(chunk, tag, name);
}

fn fetchIntel(allocator: std.mem.Allocator, target: []const u8) !Intel {
    var url_buf: [320]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://internetdb.shodan.io/{s}", .{target});
    const result = exec.run(allocator, &.{ "curl", "-sS", "-m", "8", "--fail", url }, 512 * 1024) catch
        return error.IntelUnavailable;
    if (!result.ok()) return error.IntelUnavailable;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch
        return error.IntelUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return error.IntelUnavailable;
    const object = parsed.value.object;

    var ports = std.array_list.Managed(u16).init(allocator);
    if (object.get("ports")) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                if (item == .integer and item.integer > 0 and item.integer < 65536) {
                    try ports.append(@intCast(item.integer));
                }
            }
        }
    }
    return .{
        .ports = ports.items,
        .hostnames = try stringArray(allocator, object.get("hostnames")),
        .tags = try stringArray(allocator, object.get("tags")),
        .vulns = try stringArray(allocator, object.get("vulns")),
    };
}

fn stringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    if (value) |entry| {
        if (entry == .array) {
            for (entry.array.items) |item| {
                if (item == .string) try list.append(item.string);
            }
        }
    }
    return list.items;
}
