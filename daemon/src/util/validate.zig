const std = @import("std");

pub fn isSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn isUnitName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '@' and ch != '.' and ch != '_' and ch != ':' and ch != '-') return false;
    }
    return true;
}

pub fn isContainerId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn isHostname(value: []const u8) bool {
    if (value.len == 0 or value.len > 253) return false;
    var label_len: usize = 0;
    for (value) |ch| {
        if (ch == '.') {
            if (label_len == 0) return false;
            label_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '*') return false;
        label_len += 1;
        if (label_len > 63) return false;
    }
    return label_len > 0;
}

pub fn isPort(value: []const u8) bool {
    const port = std.fmt.parseInt(u16, value, 10) catch return false;
    return port > 0;
}

pub fn isPortSpec(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, ':')) |_| return false;
    var it = std.mem.splitScalar(u8, value, '/');
    const port_part = it.next() orelse return false;
    if (!isPort(port_part)) return false;
    if (it.next()) |proto| {
        if (!std.mem.eql(u8, proto, "tcp") and !std.mem.eql(u8, proto, "udp")) return false;
    }
    return it.next() == null;
}

pub fn isIpOrCidr(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '/')) |idx| {
        const addr = value[0..idx];
        const bits = std.fmt.parseInt(u8, value[idx + 1 ..], 10) catch return false;
        if (std.mem.indexOfScalar(u8, addr, ':')) |_| {
            _ = std.Io.net.IpAddress.parseIp6(addr, 0) catch return false;
            return bits <= 128;
        }
        _ = std.Io.net.IpAddress.parseIp4(addr, 0) catch return false;
        return bits <= 32;
    }
    _ = std.Io.net.IpAddress.parse(value, 0) catch return false;
    return true;
}

pub fn isEntryPrefix(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len < 5 or value.len > 65) return false;
    if (value[0] != '/') return false;
    if (value.len > 1 and value[value.len - 1] == '/') return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

pub fn isPackageName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '.' or ch == '_' or ch == '-' or ch == '+' or ch == '=' or ch == ':') continue;
        return false;
    }
    return true;
}
