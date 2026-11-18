const std = @import("std");
const compat = @import("compat");
const types = @import("shared").types;

pub fn sources(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    web_server: []const u8,
) ![]types.LogSource {
    var list = std.array_list.Managed(types.LogSource).init(allocator);

    _ = data_dir;
    _ = web_server;
    try list.append(.{
        .id = "audit",
        .label = "面板审计日志",
        .path = "sqlite:audit_log",
        .available = true,
    });

    return list.items;
}

fn fileExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}
