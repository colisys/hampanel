const std = @import("std");

pub const max_target_bytes = 8192;
pub const max_header_name = 256;
pub const max_content_length = 1 << 40;

pub fn isTokenChar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_header_name) return false;
    for (name) |ch| if (!isTokenChar(ch)) return false;
    return true;
}

pub fn validHeaderValue(value: []const u8) bool {
    for (value) |ch| {
        if (ch == '\r' or ch == '\n' or ch == 0 or ch == 0x7f) return false;
        if (ch < 0x20 and ch != '\t') return false;
    }
    return true;
}

pub fn validTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > max_target_bytes) return false;
    if (std.mem.startsWith(u8, target, "http://") or
        std.mem.startsWith(u8, target, "https://")) return false;
    for (target) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

pub fn parseContentLength(raw: []const u8) ?usize {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    var result: usize = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        const digit: usize = ch - '0';
        if (result > (max_content_length - digit) / 10) return null;
        result = result * 10 + digit;
    }
    return result;
}

/// Route paths are ASCII and must not contain traversal or encoded separators.
/// Query parameters are not part of this check.
pub fn safeRoutePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_target_bytes) return false;
    for (path) |ch| {
        if (ch == 0 or ch == '\\' or ch == 0x7f or ch < 0x20) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return false;
        }
        // Reject percent-encoded separators/traversal; the API does not need
        // percent-encoded route segments.
        if (std.mem.indexOfScalar(u8, segment, '%') != null) return false;
    }
    return true;
}

/// RFC 6266 disposition with a sanitized ASCII fallback and a UTF-8 encoded
/// filename*. Header values must never contain CR/LF.
pub fn contentDisposition(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var fallback: [120]u8 = undefined;
    var len: usize = 0;
    for (name) |ch| {
        if (len >= fallback.len) break;
        const keep = std.ascii.isAlphanumeric(ch) or
            ch == '.' or ch == '_' or ch == '-' or ch == ' ' or ch == '(' or ch == ')';
        fallback[len] = if (keep) ch else '_';
        len += 1;
    }
    if (len == 0) {
        @memcpy(fallback[0..8], "download");
        len = 8;
    }

    var encoded = std.array_list.Managed(u8).init(allocator);
    defer encoded.deinit();
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or
            ch == '_' or ch == '~')
        {
            try encoded.append(ch);
        } else {
            var buf: [3]u8 = undefined;
            const part = std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable;
            try encoded.appendSlice(part);
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "attachment; filename=\"{s}\"; filename*=UTF-8''{s}",
        .{ fallback[0..len], encoded.items },
    );
}

pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "header and target validation" {
    try std.testing.expect(validHeaderName("Content-Length"));
    try std.testing.expect(!validHeaderName("Bad Header"));
    try std.testing.expect(!validHeaderName("X\r\nInjected"));
    try std.testing.expect(validHeaderValue("text/plain; charset=utf-8"));
    try std.testing.expect(!validHeaderValue("x\r\nInjected: 1"));
    try std.testing.expect(validTarget("/api/v1/tasks?x=1"));
    try std.testing.expect(!validTarget("http://example.com/"));
    try std.testing.expect(!validTarget("/api/\x00"));
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("42"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("+42"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("4 2"));
}

test "route path safety" {
    try std.testing.expect(safeRoutePath("/api/v1/tasks/id"));
    try std.testing.expect(!safeRoutePath("/api/../etc/passwd"));
    try std.testing.expect(!safeRoutePath("/api/%2e%2e/etc"));
    try std.testing.expect(!safeRoutePath("/api\\..\\etc"));
}

test "content disposition" {
    const a = std.testing.allocator;
    const value = try contentDisposition(a, "报告\"\r\n.txt");
    defer a.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "\r") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "filename*=UTF-8''") != null);
}

test "constant time equality" {
    try std.testing.expect(constantTimeEql("secret", "secret"));
    try std.testing.expect(!constantTimeEql("secret", "secreu"));
    try std.testing.expect(!constantTimeEql("secret", "secret2"));
}
