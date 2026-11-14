const std = @import("std");

pub const ParamKind = enum {
    text,
    port,
    password,
};

pub const Param = struct {
    key: []const u8,
    label: []const u8,
    kind: ParamKind = .text,
    default: []const u8 = "",
    secret: bool = false,
};

pub const App = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    category: []const u8,
    icon: []const u8,
    compose: []const u8,
    params: []const Param,
};

pub const apps = [_]App{
    .{
        .slug = "nginx",
        .name = "Nginx",
        .description = "轻量级 Web 服务器与反向代理，预置默认站点。",
        .category = "Web",
        .icon = "web",
        .compose = @embedFile("catalog/nginx.yml"),
        .params = &.{
            .{ .key = "port", .label = "HTTP 端口", .kind = .port, .default = "8080" },
        },
    },
    .{
        .slug = "redis",
        .name = "Redis",
        .description = "内存键值数据库，启用密码保护与持久化卷。",
        .category = "数据库",
        .icon = "database",
        .compose = @embedFile("catalog/redis.yml"),
        .params = &.{
            .{ .key = "port", .label = "服务端口", .kind = .port, .default = "6379" },
            .{ .key = "password", .label = "访问密码", .kind = .password, .secret = true },
        },
    },
    .{
        .slug = "postgres",
        .name = "PostgreSQL",
        .description = "功能完整的关系型数据库，自动创建用户与数据库。",
        .category = "数据库",
        .icon = "database",
        .compose = @embedFile("catalog/postgres.yml"),
        .params = &.{
            .{ .key = "port", .label = "服务端口", .kind = .port, .default = "5432" },
            .{ .key = "user", .label = "用户名", .default = "hampanel" },
            .{ .key = "database", .label = "数据库名", .default = "hampanel" },
            .{ .key = "password", .label = "用户密码", .kind = .password, .secret = true },
        },
    },
    .{
        .slug = "mariadb",
        .name = "MariaDB",
        .description = "MySQL 兼容数据库，初始化数据库与 root 密码。",
        .category = "数据库",
        .icon = "database",
        .compose = @embedFile("catalog/mariadb.yml"),
        .params = &.{
            .{ .key = "port", .label = "服务端口", .kind = .port, .default = "3306" },
            .{ .key = "database", .label = "数据库名", .default = "hampanel" },
            .{ .key = "password", .label = "root 密码", .kind = .password, .secret = true },
        },
    },
    .{
        .slug = "minio",
        .name = "MinIO",
        .description = "S3 兼容对象存储，包含 API 与 Web 控制台。",
        .category = "存储",
        .icon = "storage",
        .compose = @embedFile("catalog/minio.yml"),
        .params = &.{
            .{ .key = "api_port", .label = "API 端口", .kind = .port, .default = "9000" },
            .{ .key = "console_port", .label = "控制台端口", .kind = .port, .default = "9001" },
            .{ .key = "user", .label = "访问用户", .default = "hampanel" },
            .{ .key = "password", .label = "访问密钥", .kind = .password, .secret = true },
        },
    },
    .{
        .slug = "gitea",
        .name = "Gitea",
        .description = "自托管 Git 服务，含 Web 界面与 SSH 访问。",
        .category = "开发",
        .icon = "git",
        .compose = @embedFile("catalog/gitea.yml"),
        .params = &.{
            .{ .key = "web_port", .label = "Web 端口", .kind = .port, .default = "3000" },
            .{ .key = "ssh_port", .label = "SSH 端口", .kind = .port, .default = "2222" },
        },
    },
    .{
        .slug = "uptime-kuma",
        .name = "Uptime Kuma",
        .description = "自托管可用性监控与状态页面。",
        .category = "监控",
        .icon = "monitor",
        .compose = @embedFile("catalog/uptime-kuma.yml"),
        .params = &.{
            .{ .key = "port", .label = "Web 端口", .kind = .port, .default = "3001" },
        },
    },
    .{
        .slug = "bark",
        .name = "Bark",
        .description = "自托管 iOS 推送服务，只监听本机 HTTP 端口。Bark 不支持 mTLS，公网访问请在 WAF 中为它添加一条域名路由（面板内置 Caddy 自动签发受信任证书），或接入你自己的反向代理。",
        .category = "工具",
        .icon = "bell",
        .compose = @embedFile("catalog/bark.yml"),
        .params = &.{
            .{ .key = "port", .label = "本机 HTTP 端口", .kind = .port, .default = "8089" },
        },
    },
    .{
        .slug = "certbot",
        .name = "Certbot",
        .description = "Let's Encrypt 证书签发与续期（standalone 模式）。先停占用 80 端口的服务，签好后在 Nginx 等站点中引用证书。",
        .category = "工具",
        .icon = "cert",
        .compose = @embedFile("catalog/certbot.yml"),
        .params = &.{
            .{ .key = "domain", .label = "域名", .default = "" },
            .{ .key = "email", .label = "联系邮箱", .default = "" },
            .{ .key = "http_port", .label = "HTTP 验证端口", .kind = .port, .default = "80" },
        },
    },
    .{
        .slug = "adminer",
        .name = "Adminer",
        .description = "单文件数据库管理界面，支持 MySQL/PostgreSQL 等。",
        .category = "工具",
        .icon = "tools",
        .compose = @embedFile("catalog/adminer.yml"),
        .params = &.{
            .{ .key = "port", .label = "Web 端口", .kind = .port, .default = "8088" },
        },
    },
    .{
        .slug = "code-server",
        .name = "code-server",
        .description = "浏览器中的 VS Code，带密码保护与持久化工作区。",
        .category = "开发",
        .icon = "code",
        .compose = @embedFile("catalog/code-server.yml"),
        .params = &.{
            .{ .key = "port", .label = "Web 端口", .kind = .port, .default = "8087" },
            .{ .key = "password", .label = "访问密码", .kind = .password, .secret = true },
        },
    },
};

pub fn find(slug: []const u8) ?*const App {
    for (&apps) |*app| {
        if (std.mem.eql(u8, app.slug, slug)) return app;
    }
    return null;
}
