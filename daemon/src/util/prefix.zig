const std = @import("std");

/// Returns the route path after removing the secret entry prefix.
/// Returns null when the request did not carry the prefix.
pub fn strip(prefix: []const u8, path: []const u8) ?[]const u8 {
    if (prefix.len == 0) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len > 0 and rest[0] != '/') return null;
    if (rest.len == 0) return "/";
    return rest;
}

test "strip entry prefix" {
    try std.testing.expectEqualStrings("/api/v1/health", strip("/secret", "/secret/api/v1/health").?);
    try std.testing.expectEqualStrings("/", strip("/secret", "/secret").?);
    try std.testing.expectEqualStrings("/", strip("/secret", "/secret/").?);
    try std.testing.expect(strip("/secret", "/api/v1/health") == null);
    try std.testing.expect(strip("/secret", "/secrets/api") == null);
    try std.testing.expectEqualStrings("/api", strip("", "/api").?);
}
