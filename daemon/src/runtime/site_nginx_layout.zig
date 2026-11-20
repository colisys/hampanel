const std = @import("std");

pub fn catalogLayout(a: std.mem.Allocator, raw: []const u8, dir: []const u8, snippet: []const u8) !bool {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    if (!std.mem.eql(u8, lines.next() orelse return false, "docker.io/library/nginx:1.27-alpine")) return false;
    if (!std.mem.eql(u8, lines.next() orelse return false, "false")) return false;
    const config = try std.mem.concat(a, u8, &.{ "bind /etc/nginx/hampanel false ", dir });
    defer a.free(config);
    const include = try std.mem.concat(a, u8, &.{ "bind /etc/nginx/conf.d/hampanel.conf false ", snippet });
    defer a.free(include);
    var mask: u8 = 0;
    while (lines.next()) |line| {
        const bit: u8 = if (std.mem.eql(u8, line, config)) 1 else if (std.mem.eql(u8, line, include)) 2 else if (std.mem.startsWith(u8, line, "volume /usr/share/nginx/html true ")) 4 else return false;
        if (mask & bit != 0) return false;
        mask |= bit;
    }
    return mask == 7;
}

test "managed nginx rejects extra mounts and privileged containers" {
    const image = "docker.io/library/nginx:1.27-alpine\n";
    const mounts = "bind /etc/nginx/hampanel false /conf\nbind /etc/nginx/conf.d/hampanel.conf false /snippet\nvolume /usr/share/nginx/html true /volume\n";
    const a = std.testing.allocator;
    try std.testing.expect(try catalogLayout(a, image ++ "false\n" ++ mounts, "/conf", "/snippet"));
    try std.testing.expect(!try catalogLayout(a, image ++ "true\n" ++ mounts, "/conf", "/snippet"));
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ mounts ++ "bind /host true /\n", "/conf", "/snippet"));
}
