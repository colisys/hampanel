const std = @import("std");
const cli = @import("cli.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const code = cli.run(gpa.allocator()) catch |err| blk: {
        std.debug.print("hampaneld: fatal: {s}\n", .{@errorName(err)});
        break :blk @as(u8, 1);
    };
    std.process.exit(code);
}
