const std = @import("std");

/// Replacement for values that must never reach a log line: tokens, keys,
/// passwords, request bodies and raw request targets.
pub const hidden = "***";

/// Maximum number of characters copied by `text`; keeps one log field short.
pub const max_text = 96;

/// Renders user-controlled text for logging: control characters are replaced
/// so a value cannot forge extra log lines, and long values are truncated.
pub fn text(buf: []u8, value: []const u8) []const u8 {
    const limit = @min(value.len, @min(buf.len, max_text));
    for (value[0..limit], 0..) |ch, index| {
        buf[index] = if (ch < 0x20 or ch == 0x7f) '?' else ch;
    }
    return buf[0..limit];
}

test "text strips control characters and truncates" {
    var buf: [max_text]u8 = undefined;
    try std.testing.expectEqualStrings("a?b", text(&buf, "a\nb"));
    var long: [max_text + 32]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectEqual(@as(usize, max_text), text(&buf, &long).len);
}
