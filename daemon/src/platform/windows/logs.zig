const std = @import("std");
const compat = @import("compat");
const types = @import("shared").types;

pub fn sources(allocator: std.mem.Allocator, data_dir: []const u8) ![]types.LogSource {
    var list = std.array_list.Managed(types.LogSource).init(allocator);

    const audit_path = try compat.path.join(allocator, &.{ data_dir, "audit.jsonl" });
    try list.append(.{
        .id = "audit",
        .label = "面板审计日志",
        .path = audit_path,
        .available = fileExists(audit_path),
    });

    return list.items;
}

fn fileExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}
