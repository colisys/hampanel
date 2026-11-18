const std = @import("std");
const compat = @import("compat");
const Conn = @import("../net/conn.zig").Conn;
const version = @import("../version.zig");
const validate = @import("validate.zig");

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
    delete_after_send: bool = false,
    close: bool = false,
};

pub fn writeHeader(writer: anytype, name: []const u8, value: []const u8) !void {
    if (!validate.validHeaderName(name) or !validate.validHeaderValue(value)) {
        return error.InvalidHeader;
    }
    try writer.print("{s}: {s}\r\n", .{ name, value });
}

fn statusText(status: u16) []const u8 {
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

pub fn write(
    conn: *Conn,
    resp: Response,
    keep_alive: bool,
    head_only: bool,
) !void {
    var file: ?compat.File = null;
    defer if (file) |f| f.close();

    var body_length: u64 = resp.body.len;
    if (resp.file_path) |path| {
        const handle = compat.cwd().openFile(path, .{}) catch return error.FileOpen;
        file = handle;
        const stat = handle.stat() catch return error.FileStat;
        body_length = stat.size;
    }

    var head: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer head.deinit();
    const writer = &head.writer;
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ resp.status, statusText(resp.status) });
    try writeHeader(writer, "Server", version.user_agent);
    try writeHeader(writer, "Content-Type", resp.content_type);
    try writer.print("Content-Length: {d}\r\n", .{body_length});
    try writeHeader(writer, "Cache-Control", "no-store");
    try writeHeader(writer, "X-Content-Type-Options", "nosniff");
    try writeHeader(writer, "Connection", if (keep_alive and !resp.close) "keep-alive" else "close");
    for (resp.extra) |h| try writeHeader(writer, h.name, h.value);
    try writer.print("\r\n", .{});

    try conn.writeAll(head.written());

    if (head_only) return;

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

    if (resp.delete_after_send) {
        if (file) |handle| {
            handle.close();
            file = null;
        }
        if (resp.file_path) |path| {
            compat.deleteFileAbsolute(path) catch {};
        }
    }
}

test "response header rejects CRLF" {
    var head: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer head.deinit();
    try std.testing.expectError(
        error.InvalidHeader,
        writeHeader(&head.writer, "X-Test", "ok\r\nInjected: 1"),
    );
    try writeHeader(&head.writer, "X-Test", "ok");
}

fn writeChunk(conn: *Conn, payload: []const u8) !void {
    if (payload.len == 0) return;
    var head: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&head, "{x}\r\n", .{payload.len});
    try conn.writeAll(line);
    try conn.writeAll(payload);
    try conn.writeAll("\r\n");
}

pub fn beginEventStream(conn: *Conn) !void {
    var head: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer head.deinit();
    const writer = &head.writer;
    try writer.print("HTTP/1.1 200 OK\r\n", .{});
    try writeHeader(writer, "Server", version.user_agent);
    try writeHeader(writer, "Content-Type", "text/event-stream");
    try writeHeader(writer, "Cache-Control", "no-cache");
    try writeHeader(writer, "Connection", "keep-alive");
    try writeHeader(writer, "Transfer-Encoding", "chunked");
    try writeHeader(writer, "X-Accel-Buffering", "no");
    try writeHeader(writer, "X-Content-Type-Options", "nosniff");
    try writer.print("\r\n", .{});
    try conn.writeAll(head.written());
}

pub fn event(conn: *Conn, name: []const u8, data: []const u8) !void {
    if (!validate.validHeaderName(name)) return error.InvalidEvent;
    if (std.mem.indexOfAny(u8, data, "\r\n") != null) return error.InvalidEvent;
    const payload = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "event: {s}\ndata: {s}\n\n",
        .{ name, data },
    );
    defer std.heap.page_allocator.free(payload);
    try writeChunk(conn, payload);
}

pub fn comment(conn: *Conn, text: []const u8) !void {
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidEvent;
    const payload = try std.fmt.allocPrint(
        std.heap.page_allocator,
        ": {s}\n\n",
        .{text},
    );
    defer std.heap.page_allocator.free(payload);
    try writeChunk(conn, payload);
}

pub fn endEventStream(conn: *Conn) !void {
    try conn.writeAll("0\r\n\r\n");
}
