const std = @import("std");
const Conn = @import("../net/conn.zig").Conn;
const version = @import("../version.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: []const u8 = "",
    extra: []const Header = &.{},
    file_path: ?[]const u8 = null,
    close: bool = false,
};

pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

pub fn write(conn: *Conn, resp: Response, keep_alive: bool) !void {
    var file: ?std.fs.File = null;
    defer if (file) |f| f.close();

    var body_length: u64 = resp.body.len;
    if (resp.file_path) |path| {
        const handle = std.fs.cwd().openFile(path, .{}) catch return error.FileOpen;
        file = handle;
        const stat = handle.stat() catch return error.FileStat;
        body_length = stat.size;
    }

    var head = std.ArrayList(u8).init(std.heap.page_allocator);
    defer head.deinit();
    const writer = head.writer();
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ resp.status, statusText(resp.status) });
    try writer.print("Server: {s}\r\n", .{version.user_agent});
    try writer.print("Content-Type: {s}\r\n", .{resp.content_type});
    try writer.print("Content-Length: {d}\r\n", .{body_length});
    try writer.print("Cache-Control: no-store\r\n", .{});
    try writer.print("X-Content-Type-Options: nosniff\r\n", .{});
    try writer.print("Connection: {s}\r\n", .{if (keep_alive and !resp.close) "keep-alive" else "close"});
    for (resp.extra) |h| {
        try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.print("\r\n", .{});

    try conn.writeAll(head.items);

    if (resp.file_path != null) {
        var buffer: [64 * 1024]u8 = undefined;
        const handle = file.?;
        var remaining = body_length;
        while (remaining > 0) {
            const want: usize = @intCast(@min(remaining, buffer.len));
            const n = handle.read(buffer[0..want]) catch return error.FileRead;
            if (n == 0) break;
            try conn.writeAll(buffer[0..n]);
            remaining -= n;
        }
    } else if (resp.body.len > 0) {
        try conn.writeAll(resp.body);
    }
}
