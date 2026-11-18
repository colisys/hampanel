const std = @import("std");
const Conn = @import("../net/conn.zig").Conn;
const url = @import("../util/url.zig");
const validate = @import("validate.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    minor: u8,
    headers: []Header,
    body: []const u8,
    keep_alive: bool,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn queryValue(self: Request, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        return url.value(allocator, self.query, name);
    }

    pub fn hasToken(self: Request, name: []const u8, token: []const u8) bool {
        const raw = self.header(name) orelse return false;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
        }
        return false;
    }
};

pub const ReadError = error{
    EndOfStream,
    UnexpectedEof,
    LineTooLong,
    BadRequest,
    HeaderTooLarge,
    BodyTooLarge,
    OutOfMemory,
    Io,
    WouldBlock,
};

const max_headers = 64;
const max_header_bytes = 32 * 1024;

pub fn read(conn: *Conn, allocator: std.mem.Allocator, max_body: usize) ReadError!Request {
    const request_line = conn.readLine(allocator, 8192) catch |e| switch (e) {
        error.EndOfStream => return error.EndOfStream,
        error.LineTooLong => return error.LineTooLong,
        error.UnexpectedEof => return error.UnexpectedEof,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };

    var line_it = std.mem.splitScalar(u8, request_line, ' ');
    const method_raw = line_it.next() orelse return error.BadRequest;
    const target = line_it.next() orelse return error.BadRequest;
    const version = line_it.next() orelse return error.BadRequest;
    if (line_it.next() != null) return error.BadRequest;

    const method = std.meta.stringToEnum(Method, method_raw) orelse return error.BadRequest;

    if (!validate.validTarget(target)) return error.BadRequest;
    const minor: u8 = blk: {
        if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;
        const raw_minor = version["HTTP/1.".len..];
        const parsed = std.fmt.parseInt(u8, raw_minor, 10) catch return error.BadRequest;
        if (parsed > 1) return error.BadRequest;
        break :blk parsed;
    };

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
        path = target[0..idx];
        query = target[idx + 1 ..];
    }

    var headers = try std.array_list.Managed(Header).initCapacity(allocator, 8);
    var header_bytes: usize = 0;
    while (true) {
        const line = conn.readLine(allocator, max_header_bytes) catch |e| switch (e) {
            error.EndOfStream => return error.UnexpectedEof,
            error.LineTooLong => return error.HeaderTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Io,
        };
        if (line.len == 0) break;
        if (headers.items.len >= max_headers) return error.HeaderTooLarge;
        header_bytes += line.len;
        if (header_bytes > max_header_bytes) return error.HeaderTooLarge;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!validate.validHeaderName(name) or !validate.validHeaderValue(value)) {
            return error.BadRequest;
        }
        try headers.append(.{ .name = name, .value = value });
    }

    if (minor >= 1) {
        const host = findHeader(headers.items, "host") orelse return error.BadRequest;
        if (host.len == 0) return error.BadRequest;
    }

    const connection = findHeader(headers.items, "connection");
    const keep_alive = blk: {
        if (connection) |raw| {
            if (hasTokenIn(raw, "close")) break :blk false;
            if (hasTokenIn(raw, "keep-alive")) break :blk true;
        }
        break :blk minor >= 1;
    };

    var body: []const u8 = "";
    if (findHeader(headers.items, "transfer-encoding")) |_| return error.BadRequest;

    var content_lengths: usize = 0;
    var content_length_raw: ?[]const u8 = null;
    for (headers.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "content-length")) {
            content_lengths += 1;
            content_length_raw = entry.value;
        }
    }
    if (content_lengths > 1) return error.BadRequest;
    if (content_length_raw) |raw_len| {
        const length = validate.parseContentLength(raw_len) orelse return error.BadRequest;
        if (length > max_body) return error.BodyTooLarge;
        if (findHeader(headers.items, "expect")) |expect| {
            if (hasTokenIn(expect, "100-continue")) {
                conn.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return error.Io;
            }
        }
        if (length > 0) {
            const buffer = allocator.alloc(u8, length) catch return error.OutOfMemory;
            conn.readFull(buffer) catch |e| switch (e) {
                error.EndOfStream => return error.UnexpectedEof,
                error.WouldBlock => return error.WouldBlock,
                else => return error.Io,
            };
            body = buffer;
        }
    }

    return .{
        .method = method,
        .target = target,
        .path = path,
        .query = query,
        .minor = minor,
        .headers = headers.items,
        .body = body,
        .keep_alive = keep_alive,
    };
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

fn hasTokenIn(raw: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}
