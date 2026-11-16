const std = @import("std");
const context = @import("context.zig");
const version = @import("../version.zig");
const pki = @import("../pki.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const Body = struct {
        status: []const u8,
        product: []const u8,
        version: []const u8,
        api: u32,
        ca_sha256: []const u8,
        server_sha256: []const u8,
    };
    var ca_sha256: []const u8 = "";
    var server_sha256: []const u8 = "";
    if (pki.paths(ctx.arena, ctx.app.config.tls_dir)) |paths| {
        if (pki.loadMeta(ctx.arena, paths)) |meta| {
            ca_sha256 = meta.ca_fingerprint;
            server_sha256 = meta.server_fingerprint;
        } else |_| {}
    } else |_| {}
    try ctx.json(Body{
        .status = "ok",
        .product = "Hampanel",
        .version = version.version,
        .api = version.protocol_version,
        .ca_sha256 = ca_sha256,
        .server_sha256 = server_sha256,
    });
}
