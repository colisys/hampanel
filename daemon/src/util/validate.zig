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
    if (value[0] == '-' or value[value.len - 1] == ':') return false;
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

pub fn isLabelKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-' and ch != '/') return false;
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
    var mapping = value;
    if (std.mem.indexOfScalar(u8, mapping, '/')) |split| {
        const proto = mapping[split + 1 ..];
        if (!std.mem.eql(u8, proto, "tcp") and !std.mem.eql(u8, proto, "udp") and !std.mem.eql(u8, proto, "sctp")) return false;
        mapping = mapping[0..split];
    }
    if (std.mem.startsWith(u8, mapping, "[")) {
        const end = std.mem.indexOf(u8, mapping, "]:") orelse return false;
        _ = std.Io.net.IpAddress.parseIp6(mapping[1..end], 0) catch return false;
        mapping = mapping[end + 2 ..];
    } else if (std.mem.count(u8, mapping, ":") == 2) {
        const end = std.mem.indexOfScalar(u8, mapping, ':').?;
        _ = std.Io.net.IpAddress.parseIp4(mapping[0..end], 0) catch return false;
        mapping = mapping[end + 1 ..];
    }
    const split = std.mem.indexOfScalar(u8, mapping, ':') orelse return false;
    return (split == 0 or validPortRange(mapping[0..split])) and validPortRange(mapping[split + 1 ..]);
}

fn validPortRange(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '-');
    const first = std.fmt.parseUnsigned(u16, parts.next().?, 10) catch return false;
    if (first == 0) return false;
    const end = parts.next() orelse return true;
    const last = std.fmt.parseUnsigned(u16, end, 10) catch return false;
    return last >= first and parts.next() == null;
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

test "published port mappings" {
    for ([_][]const u8{ "[fd00::ab]:8080:80/tcp", ":53/udp", "127.0.0.1:100-110:200-210/sctp" }) |spec| try std.testing.expect(isPortMapping(spec));
    for ([_][]const u8{ "65536:80", "80:0", "[bad]:1:2", "80:80/other" }) |spec| try std.testing.expect(!isPortMapping(spec));
}

test "container labels accept namespaced keys" {
    try std.testing.expect(isLabelKey("org.opencontainers.image.title"));
    try std.testing.expect(isLabelKey("io.example/team"));
    try std.testing.expect(!isLabelKey("bad key"));
    try std.testing.expect(!isLabelKey("key=value"));
}

test "image references reject a dangling colon and preserve ports and digests" {
    for ([_][]const u8{ "nginx:", "registry:5000/team/app:", "app@sha256:" }) |ref| {
        try std.testing.expect(!isImageRef(ref));
    }
    for ([_][]const u8{ "registry:5000/team/app", "registry:5000/team/app:v1", "registry:5000/team/app@sha256:abc" }) |ref| {
        try std.testing.expect(isImageRef(ref));
    }
}
