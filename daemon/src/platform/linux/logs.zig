const std = @import("std");
const types = @import("shared").types;

pub fn sources(allocator: std.mem.Allocator, data_dir: []const u8) ![]types.LogSource {
    var list = std.ArrayList(types.LogSource).init(allocator);

    const audit_path = try std.fs.path.join(allocator, &.{ data_dir, "audit.jsonl" });
    try add(&list, "audit", "面板审计日志", audit_path);

    try add(&list, "nginx_access", "Nginx 访问日志", "/var/log/nginx/access.log");
    try add(&list, "nginx_error", "Nginx 错误日志", "/var/log/nginx/error.log");

    if (fileExists("/var/log/auth.log")) {
        try add(&list, "auth", "认证日志", "/var/log/auth.log");
    } else {
        try add(&list, "auth", "认证日志", "/var/log/secure");
    }

    if (fileExists("/var/log/syslog")) {
        try add(&list, "syslog", "系统日志", "/var/log/syslog");
    } else {
        try add(&list, "syslog", "系统日志", "/var/log/messages");
    }

    return list.items;
}

fn add(list: *std.ArrayList(types.LogSource), id: []const u8, label: []const u8, path: []const u8) !void {
    try list.append(.{
        .id = id,
        .label = label,
        .path = path,
        .available = fileExists(path),
    });
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
