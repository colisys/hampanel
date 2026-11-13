const std = @import("std");
const context = @import("context.zig");
const version = @import("../version.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const Body = struct {
        status: []const u8,
        product: []const u8,
        version: []const u8,
        api: u32,
    };
    try ctx.json(Body{
        .status = "ok",
        .product = "Hampanel",
        .version = version.version,
        .api = version.protocol_version,
    });
}
