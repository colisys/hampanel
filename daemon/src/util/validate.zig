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

pub fn isContainerName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn isNetworkName(value: []const u8) bool {
    return isContainerName(value);
}

pub fn isVolumeName(value: []const u8) bool {
    return isContainerName(value);
}

pub fn isImageRef(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    if (value[0] == '-') return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (std.mem.indexOfScalar(u8, "._/:@-+", ch) != null) continue;
        return false;
    }
    return true;
}

pub fn isRegistryHost(value: []const u8) bool {
    if (value.len == 0 or value.len > 253) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (std.mem.indexOfScalar(u8, ".-:[]_", ch) != null) continue;
        return false;
    }
    return true;
}

pub fn isEnvKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

pub fn isEnvValue(value: []const u8) bool {
    if (value.len > 4096) return false;
    for (value) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r') return false;
    }
    return true;
}

pub fn isPortMapping(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    var colons: usize = 0;
    for (value) |ch| {
        if (ch == ':') {
            colons += 1;
            continue;
        }
        if (std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '[' or ch == ']' or ch == '/') continue;
        if (std.ascii.isAlphabetic(ch) and (ch == 't' or ch == 'c' or ch == 'p' or ch == 'u' or ch == 'd')) continue;
        return false;
    }
    return colons >= 1;
}

pub fn isMountSpec(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r' or ch == '\t') return false;
    }
    return true;
}

pub fn isComposeName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (!std.ascii.isAlphanumeric(value[0]) or std.ascii.isUpper(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
        if (std.ascii.isUpper(ch)) return false;
    }
    return true;
}

pub fn isSocketPath(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len > 256) return false;
    const prefixes = [_][]const u8{ "unix://", "npipe://", "tcp://", "http://", "https://" };
    var matched = false;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) matched = true;
    }
    if (!matched) return false;
    for (value) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r' or ch == ' ') return false;
    }
    return true;
}

test "docker management validators" {
    try std.testing.expect(isContainerName("web-1"));
    try std.testing.expect(!isContainerName("bad name"));
    try std.testing.expect(isComposeName("my-stack"));
    try std.testing.expect(!isComposeName("My-Stack"));
    try std.testing.expect(isSocketPath("unix:///var/run/docker.sock"));
    try std.testing.expect(!isSocketPath("var/run/docker.sock"));
    try std.testing.expect(isRegistryHost("registry.example.com:5000"));
    try std.testing.expect(!isRegistryHost("http://registry"));
    try std.testing.expect(isPortMapping("8080:80"));
    try std.testing.expect(isMountSpec("/data:/data:ro"));
    try std.testing.expect(isImageRef("nginx:alpine"));
    try std.testing.expect(isImageRef("sha256:abc123"));
}
