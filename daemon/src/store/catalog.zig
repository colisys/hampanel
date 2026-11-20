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
        .slug = "emqx", .name = "EMQX", .description = "MQTT 消息代理；部署后请设置 Dashboard 管理员密码并配置客户端认证。", .category = "消息队列", .icon = "database", .compose = @embedFile("catalog/emqx.yml"),
        .params = &.{ .{ .key = "mqtt_port", .label = "MQTT 端口", .kind = .port, .default = "1883" }, .{ .key = "dashboard_port", .label = "Dashboard 端口", .kind = .port, .default = "18083" } },
    },
    .{
        .slug = "kafka", .name = "Kafka", .description = "单节点 KRaft 消息队列；明文连接，仅用于可信网络。填写客户端可达的主机地址。", .category = "消息队列", .icon = "database", .compose = @embedFile("catalog/kafka.yml"),
        .params = &.{ .{ .key = "advertised_host", .label = "客户端可达主机地址", .default = "localhost" }, .{ .key = "port", .label = "服务端口", .kind = .port, .default = "9092" } },
    },
    .{
        .slug = "mcsmanager", .name = "MCSManager", .description = "游戏服务管理面板和守护进程；需在 Web 界面添加节点，不提供宿主容器引擎权限。", .category = "游戏", .icon = "tools", .compose = @embedFile("catalog/mcsmanager.yml"),
        .params = &.{ .{ .key = "web_port", .label = "面板端口", .kind = .port, .default = "23333" }, .{ .key = "daemon_port", .label = "守护进程端口", .kind = .port, .default = "24444" } },
    },
    .{
        .slug = "vllm", .name = "vLLM", .description = "OpenAI 兼容推理服务；需要 NVIDIA GPU、驱动和容器工具包。", .category = "AI", .icon = "code", .compose = @embedFile("catalog/vllm.yml"),
        .params = &.{ .{ .key = "port", .label = "API 端口", .kind = .port, .default = "8000" }, .{ .key = "api_key", .label = "API 密钥", .kind = .password, .secret = true } },
    },
    .{
        .slug = "frps", .name = "FRPS", .description = "frp 服务端；开放控制端口与一个 TCP 映射端口。", .category = "网络", .icon = "web", .compose = @embedFile("catalog/frps.yml"),
        .params = &.{ .{ .key = "server_port", .label = "控制端口", .kind = .port, .default = "7000" }, .{ .key = "remote_port", .label = "映射端口", .kind = .port, .default = "6000" }, .{ .key = "token", .label = "共享令牌", .kind = .password, .secret = true } },
    },
    .{
        .slug = "frpd", .name = "FRPD (frpc)", .description = "frp 客户端常驻服务；本地地址需从容器网络可访问，令牌需与 FRPS 一致。", .category = "网络", .icon = "web", .compose = @embedFile("catalog/frpd.yml"),
        .params = &.{ .{ .key = "server_addr", .label = "服务端地址", .default = "host.docker.internal" }, .{ .key = "server_port", .label = "控制端口", .kind = .port, .default = "7000" }, .{ .key = "local_ip", .label = "本地服务地址", .default = "host.docker.internal" }, .{ .key = "local_port", .label = "本地服务端口", .kind = .port, .default = "80" }, .{ .key = "remote_port", .label = "服务端映射端口", .kind = .port, .default = "6000" }, .{ .key = "token", .label = "共享令牌", .kind = .password, .secret = true } },
    },
    .{
        .slug = "nacos", .name = "Nacos", .description = "单节点服务发现与配置中心；采用内嵌数据库，请初始化管理员凭据。", .category = "开发", .icon = "database", .compose = @embedFile("catalog/nacos.yml"),
        .params = &.{ .{ .key = "web_port", .label = "API 端口", .kind = .port, .default = "8848" }, .{ .key = "grpc_port", .label = "gRPC 端口", .kind = .port, .default = "9848" }, .{ .key = "auth_token", .label = "Base64 认证密钥", .kind = .password, .secret = true }, .{ .key = "identity_value", .label = "服务身份密钥", .kind = .password, .secret = true } },
    },
    .{
        .slug = "caddy", .name = "Caddy", .description = "Web 服务器；站点配置和证书保存在持久化卷，HTTPS 需要配置站点。", .category = "Web", .icon = "web", .compose = @embedFile("catalog/caddy.yml"),
        .params = &.{ .{ .key = "http_port", .label = "HTTP 端口", .kind = .port, .default = "8081" }, .{ .key = "https_port", .label = "HTTPS 端口", .kind = .port, .default = "8443" } },
    },
    .{
        .slug = "newapi", .name = "NewAPI", .description = "AI 网关；默认使用持久化 SQLite 数据卷。", .category = "AI 网关", .icon = "web", .compose = @embedFile("catalog/newapi.yml"),
        .params = &.{ .{ .key = "port", .label = "Web 端口", .kind = .port, .default = "3002" }, .{ .key = "session_secret", .label = "会话密钥", .kind = .password, .secret = true } },
    },
    .{
        .slug = "sub2api", .name = "Sub2API", .description = "AI 网关；附带私有 PostgreSQL 和 Redis，部署时设置管理员凭据。", .category = "AI 网关", .icon = "web", .compose = @embedFile("catalog/sub2api.yml"),
        .params = &.{ .{ .key = "port", .label = "Web 端口", .kind = .port, .default = "8082" }, .{ .key = "db_password", .label = "数据库密码", .kind = .password, .secret = true }, .{ .key = "redis_password", .label = "Redis 密码", .kind = .password, .secret = true }, .{ .key = "admin_email", .label = "管理员邮箱", .default = "admin@example.com" }, .{ .key = "admin_password", .label = "管理员密码", .kind = .password, .secret = true }, .{ .key = "jwt_secret", .label = "JWT 密钥", .kind = .password, .secret = true }, .{ .key = "totp_encryption_key", .label = "TOTP 加密密钥（64 位十六进制）", .kind = .password, .secret = true } },
    },
    .{
        .slug = "comfyui", .name = "ComfyUI", .description = "CPU 版图像工作流；首次部署从官方源码构建，模型需自行导入。", .category = "AI", .icon = "code", .compose = @embedFile("catalog/comfyui.yml"),
        .params = &.{ .{ .key = "port", .label = "本机 Web 端口", .kind = .port, .default = "8188" } },
    },
    .{
        .slug = "easytier", .name = "EasyTier", .description = "组网节点；使用宿主网络、TUN 和 NET_ADMIN，可能改变宿主机路由。", .category = "网络", .icon = "web", .compose = @embedFile("catalog/easytier.yml"),
        .params = &.{ .{ .key = "network_name", .label = "网络名称", .default = "hampanel" }, .{ .key = "network_secret", .label = "网络密钥", .kind = .password, .secret = true }, .{ .key = "peer_host", .label = "对等节点主机", .default = "example.com" }, .{ .key = "peer_port", .label = "对等节点端口", .kind = .port, .default = "11010" } },
    },
    .{
        .slug = "act-runner", .name = "Act Runner", .description = "Gitea Actions 运行器；挂载容器引擎 socket 等同于授予宿主机控制权限，仅用于可信环境。", .category = "开发", .icon = "git", .compose = @embedFile("catalog/act-runner.yml"),
        .params = &.{ .{ .key = "instance_host", .label = "Gitea 主机名", .default = "host.docker.internal" }, .{ .key = "instance_port", .label = "Gitea Web 端口", .kind = .port, .default = "3000" }, .{ .key = "registration_token", .label = "注册令牌", .kind = .password, .secret = true } },
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

test "catalog entries have unique slugs, categories, and declared template parameters" {
    for (apps, 0..) |app, index| {
        try std.testing.expect(app.slug.len > 0 and app.category.len > 0);
        for (apps[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, app.slug, other.slug));
        }
        for (app.params) |param| {
            const needle = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}}}}}", .{param.key});
            defer std.testing.allocator.free(needle);
            try std.testing.expect(std.mem.indexOf(u8, app.compose, needle) != null);
        }
        var rest = app.compose;
        while (std.mem.indexOf(u8, rest, "{{")) |start| {
            const end = std.mem.indexOfPos(u8, rest, start + 2, "}}") orelse return error.InvalidTemplate;
            const key = rest[start + 2 .. end];
            var declared = false;
            for (app.params) |param| {
                if (std.mem.eql(u8, key, param.key)) declared = true;
            }
            try std.testing.expect(declared);
            rest = rest[end + 2 ..];
        }
    }
}

pub fn find(slug: []const u8) ?*const App {
    for (&apps) |*app| {
        if (std.mem.eql(u8, app.slug, slug)) return app;
    }
    return null;
}
