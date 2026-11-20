const std = @import("std");

const Addresses = struct { ip: []const u8 = "", mac: []const u8 = "" };

fn child(value: std.json.Value, key: []const u8) std.json.Value {
    if (value != .object) return .null;
    return value.object.get(key) orelse .null;
}

fn text(value: std.json.Value, key: []const u8) []const u8 {
    const field = child(value, key);
    return if (field == .string) field.string else "";
}

pub fn configured(value: std.json.Value, mode: []const u8) Addresses {
    const networks = child(child(value, "NetworkSettings"), "Networks");
    const name = if (mode.len == 0 or std.mem.eql(u8, mode, "default")) "bridge" else mode;
    const endpoint = child(networks, name);
    const ipam = child(endpoint, "IPAMConfig");
    const ipv4 = text(ipam, "IPv4Address");
    const mac = text(child(endpoint, "DriverOpts"), "com.docker.network.endpoint.macaddress");
    return .{
        .ip = if (ipv4.len > 0) ipv4 else text(ipam, "IPv6Address"),
        .mac = if (mac.len > 0) mac else text(child(value, "Config"), "MacAddress"),
    };
}

test "configured addresses ignore runtime assignments and other networks" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.2","MacAddress":"02:42:00:00:00:01"},"custom":{"IPAMConfig":{"IPv4Address":"192.0.2.10"},"DriverOpts":{"com.docker.network.endpoint.macaddress":"02:42:00:00:00:02"}}}}}
    , .{});
    defer parsed.deinit();
    const automatic = configured(parsed.value, "default");
    try std.testing.expectEqualStrings("", automatic.ip);
    try std.testing.expectEqualStrings("", automatic.mac);
    const custom = configured(parsed.value, "custom");
    try std.testing.expectEqualStrings("192.0.2.10", custom.ip);
    try std.testing.expectEqualStrings("02:42:00:00:00:02", custom.mac);
}
