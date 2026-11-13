const std = @import("std");
const pki = @import("pki.zig");

pub const Bundle = struct {
    schema: u32 = 1,
    product: []const u8 = "Hampanel",
    endpoint: []const u8,
    entry_prefix: []const u8 = "",
    ca_pem: []const u8,
    client_cert_pem: []const u8,
    client_key_pem: []const u8,
    ca_sha256: []const u8,
    server_sha256: []const u8,
    client_cn: []const u8,
    created_at: []const u8,
};

pub fn build(
    allocator: std.mem.Allocator,
    meta: pki.Meta,
    paths: pki.Paths,
    endpoint_override: ?[]const u8,
    entry_prefix: []const u8,
) !Bundle {
    const ca_pem = try std.fs.cwd().readFileAlloc(allocator, paths.ca_cert, 1024 * 1024);
    const client_cert_pem = try std.fs.cwd().readFileAlloc(allocator, paths.client_cert, 1024 * 1024);
    const client_key_pem = try std.fs.cwd().readFileAlloc(allocator, paths.client_key, 1024 * 1024);

    return .{
        .endpoint = endpoint_override orelse meta.endpoint,
        .entry_prefix = entry_prefix,
        .ca_pem = ca_pem,
        .client_cert_pem = client_cert_pem,
        .client_key_pem = client_key_pem,
        .ca_sha256 = meta.ca_fingerprint,
        .server_sha256 = meta.server_fingerprint,
        .client_cn = meta.client_cn,
        .created_at = meta.created_at,
    };
}

pub fn save(allocator: std.mem.Allocator, bundle: Bundle, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    const json = try std.json.stringifyAlloc(allocator, bundle, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    var file = try std.fs.cwd().createFile(path, .{ .mode = 0o600, .truncate = true });
    defer file.close();
    try file.chmod(0o600);
    try file.writeAll(json);
    try file.writeAll("\n");
}

pub fn toJson(allocator: std.mem.Allocator, bundle: Bundle) ![]u8 {
    return std.json.stringifyAlloc(allocator, bundle, .{ .whitespace = .indent_2 });
}
