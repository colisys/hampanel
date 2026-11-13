const std = @import("std");

pub fn decode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch == '+') {
            try out.append(' ');
            i += 1;
        } else if (ch == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                try out.append(ch);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                try out.append(ch);
                i += 1;
                continue;
            };
            try out.append(@intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(ch);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

pub fn value(allocator: std.mem.Allocator, raw_query: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, raw_query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key_raw = if (eq) |idx| pair[0..idx] else pair;
        const value_raw = if (eq) |idx| pair[idx + 1 ..] else "";
        const key = try decode(allocator, key_raw);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, name)) {
            return try decode(allocator, value_raw);
        }
    }
    return null;
}
