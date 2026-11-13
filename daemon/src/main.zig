const std = @import("std");
const cli = @import("cli.zig");
const compat = @import("compat");

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnviron(init.environ_map);

    const code = cli.run(init.gpa, init.minimal.args) catch |err| blk: {
        std.debug.print("hampaneld: fatal: {t}\n", .{err});
        break :blk @as(u8, 1);
    };
    std.process.exit(code);
}
