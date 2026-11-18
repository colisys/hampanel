const std = @import("std");
const compat = @import("compat");
const types = @import("shared").types;
const exec = @import("shared").exec;

pub fn sources(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    web_server: []const u8,
) ![]types.LogSource {
    var list = std.array_list.Managed(types.LogSource).init(allocator);

    _ = data_dir;
    try add(&list, "audit", "面板审计日志", "sqlite:audit_log");
    list.items[list.items.len - 1].available = true;

    const nginx = if (web_server.len > 0)
        std.mem.eql(u8, web_server, "nginx")
    else
        exec.commandExists(allocator, "nginx");
    const caddy = if (web_server.len > 0)
        std.mem.eql(u8, web_server, "caddy")
    else
        exec.commandExists(allocator, "caddy");

    if (nginx) {
        try add(&list, "nginx_access", "Nginx 访问日志", "/var/log/nginx/access.log");
        try add(&list, "nginx_error", "Nginx 错误日志", "/var/log/nginx/error.log");
    }
    if (caddy) {
        try add(&list, "caddy_access", "Caddy 访问日志", "/var/log/caddy/access.log");
        try add(&list, "caddy_error", "Caddy 错误日志", "/var/log/caddy/error.log");
    }

    const journal = exec.commandExists(allocator, "journalctl");
    if (fileExists("/var/log/auth.log")) {
        try add(&list, "auth", "认证日志", "/var/log/auth.log");
    } else if (fileExists("/var/log/secure")) {
        try add(&list, "auth", "认证日志", "/var/log/secure");
    } else if (journal) {
        try add(&list, "auth", "认证日志（journald）", "journal:auth");
        list.items[list.items.len - 1].available = true;
    }

    if (fileExists("/var/log/syslog")) {
        try add(&list, "syslog", "系统日志", "/var/log/syslog");
    } else if (fileExists("/var/log/messages")) {
        try add(&list, "syslog", "系统日志", "/var/log/messages");
    } else if (journal) {
        try add(&list, "syslog", "系统日志（journald）", "journal:system");
        list.items[list.items.len - 1].available = true;
    }

    return list.items;
}

fn add(list: *std.array_list.Managed(types.LogSource), id: []const u8, label: []const u8, path: []const u8) !void {
    try list.append(.{
        .id = id,
        .label = label,
        .path = path,
        .available = fileExists(path),
    });
}

fn fileExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}
