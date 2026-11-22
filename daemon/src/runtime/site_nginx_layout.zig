const std = @import("std");

pub const Expect = struct {
    require_socket: bool = false,
    conf: []const u8,
    snippet: []const u8,
    main: []const u8,
    stream: []const u8,
};

fn required(a: std.mem.Allocator, destination: []const u8, source: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "bind ", destination, " false ", source });
}

fn allowedExtra(line: []const u8) bool {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const kind = fields.next() orelse return false;
    if (!std.mem.eql(u8, kind, "bind")) return false;
    const destination = fields.next() orelse return false;
    const rw = fields.next() orelse return false;
    const source = fields.next() orelse return false;
    const socket_dir = @import("cron_webhook.zig").dir;
    if (std.mem.eql(u8, destination, socket_dir) or std.mem.eql(u8, source, socket_dir)) return std.mem.eql(u8, destination, socket_dir) and std.mem.eql(u8, source, socket_dir) and std.mem.eql(u8, rw, "false") and fields.next() == null;
    if (std.mem.eql(u8, destination, "/") or std.mem.eql(u8, source, "/")) return false;
    if (std.mem.indexOf(u8, source, "docker.sock") != null) return false;
    if (std.mem.indexOf(u8, source, "/proc") != null) return false;
    if (std.mem.indexOf(u8, source, "/sys/") != null) return false;
    return !std.mem.startsWith(u8, destination, "/etc/nginx/") and !std.mem.startsWith(u8, destination, "/var/run");
}

pub fn catalogLayout(a: std.mem.Allocator, raw: []const u8, expect: Expect) !bool {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    if (!std.mem.eql(u8, lines.next() orelse return false, "docker.io/library/nginx:1.27-alpine")) return false;
    if (!std.mem.eql(u8, lines.next() orelse return false, "false")) return false;

    const conf = try required(a, "/etc/nginx/hampanel", expect.conf);
    defer a.free(conf);
    const snippet = try required(a, "/etc/nginx/conf.d/hampanel.conf", expect.snippet);
    defer a.free(snippet);
    const main = try required(a, "/etc/nginx/nginx.conf", expect.main);
    defer a.free(main);
    const stream = try required(a, "/etc/nginx/stream.d/hampanel", expect.stream);
    defer a.free(stream);

    var mask: u8 = 0;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, conf)) {
            if (mask & 1 != 0) return false;
            mask |= 1;
        } else if (std.mem.eql(u8, line, snippet)) {
            if (mask & 2 != 0) return false;
            mask |= 2;
        } else if (std.mem.eql(u8, line, main)) {
            if (mask & 8 != 0) return false;
            mask |= 8;
        } else if (std.mem.eql(u8, line, stream)) {
            if (mask & 16 != 0) return false;
            mask |= 16;
        } else if (std.mem.startsWith(u8, line, "volume /usr/share/nginx/html true ")) {
            if (mask & 4 != 0) return false;
            mask |= 4;
        } else if (std.mem.eql(u8, line, "bind " ++ @import("cron_webhook.zig").dir ++ " false " ++ @import("cron_webhook.zig").dir)) {
            if (mask & 32 != 0) return false;
            mask |= 32;
        } else if (!allowedExtra(line)) {
            return false;
        }
    }
    return mask == 63 or (!expect.require_socket and mask == 31);
}

test "managed nginx rejects extra mounts and privileged containers" {
    const image = "docker.io/library/nginx:1.27-alpine\n";
    const core = "bind /etc/nginx/hampanel false /conf\n" ++
        "bind /etc/nginx/conf.d/hampanel.conf false /snippet\n" ++
        "bind /etc/nginx/nginx.conf false /main\n" ++
        "bind /etc/nginx/stream.d/hampanel false /stream\n" ++
        "volume /usr/share/nginx/html true /volume\n";
    const expect = Expect{ .conf = "/conf", .snippet = "/snippet", .main = "/main", .stream = "/stream" };
    const a = std.testing.allocator;
    try std.testing.expect(try catalogLayout(a, image ++ "false\n" ++ core, expect));
    var cron = expect;
    cron.require_socket = true;
    const dir = @import("cron_webhook.zig").dir;
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ core, cron));
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ core ++ "bind " ++ dir ++ " true " ++ dir, cron));
    try std.testing.expect(try catalogLayout(a, image ++ "false\n" ++ core ++ "bind " ++ dir ++ " false " ++ dir, cron));
    try std.testing.expect(!try catalogLayout(a, image ++ "true\n" ++ core, expect));
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ core ++ "bind /host true /\n", expect));
}

test "managed nginx accepts site mounts but rejects the docker socket" {
    const image = "docker.io/library/nginx:1.27-alpine\n";
    const core = "bind /etc/nginx/hampanel false /conf\n" ++
        "bind /etc/nginx/conf.d/hampanel.conf false /snippet\n" ++
        "bind /etc/nginx/nginx.conf false /main\n" ++
        "bind /etc/nginx/stream.d/hampanel false /stream\n" ++
        "volume /usr/share/nginx/html true /volume\n";
    const expect = Expect{ .conf = "/conf", .snippet = "/snippet", .main = "/main", .stream = "/stream" };
    const a = std.testing.allocator;
    try std.testing.expect(try catalogLayout(a, image ++ "false\n" ++ core ++ "bind /srv/www true /srv/www\n", expect));
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ core ++ "bind /var/run/docker.sock true /var/run/docker.sock\n", expect));
    try std.testing.expect(!try catalogLayout(a, image ++ "false\n" ++ core ++ "bind /etc/nginx/nginx.conf true /etc/nginx/nginx.conf\n", expect));
}
