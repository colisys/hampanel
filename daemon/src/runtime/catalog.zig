const std = @import("std");

pub const Extension = struct {
    id: []const u8,
    label: []const u8,
};

pub const ConfigFile = struct {
    name: []const u8,
    container_path: []const u8,
    content: []const u8,
};

pub const MirrorPreset = struct {
    id: []const u8,
    label: []const u8,
    apt_host: []const u8,
    alpine_host: []const u8,
    pip_url: []const u8,
    npm_url: []const u8,
    composer_url: []const u8,
};

pub const Runtime = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    image: []const u8,
    tag: []const u8,
    docker_repo: ?[]const u8,
    workdir: []const u8,
    web_port: u16,
    recommended_tags: []const []const u8,
    extensions: []const Extension,
    config_files: []const ConfigFile,
};

pub const mirror_presets = [_]MirrorPreset{
    .{
        .id = "aliyun",
        .label = "阿里云",
        .apt_host = "mirrors.aliyun.com",
        .alpine_host = "mirrors.aliyun.com",
        .pip_url = "https://mirrors.aliyun.com/pypi/simple",
        .npm_url = "https://registry.npmmirror.com",
        .composer_url = "https://mirrors.aliyun.com/composer/",
    },
    .{
        .id = "tencent",
        .label = "腾讯云",
        .apt_host = "mirrors.cloud.tencent.com",
        .alpine_host = "mirrors.cloud.tencent.com",
        .pip_url = "https://mirrors.cloud.tencent.com/pypi/simple",
        .npm_url = "https://mirrors.cloud.tencent.com/npm/",
        .composer_url = "https://mirrors.cloud.tencent.com/composer/",
    },
    .{
        .id = "ustc",
        .label = "中科大",
        .apt_host = "mirrors.ustc.edu.cn",
        .alpine_host = "mirrors.ustc.edu.cn",
        .pip_url = "https://pypi.mirrors.ustc.edu.cn/simple",
        .npm_url = "https://npmreg.proxy.ustclug.org/",
        .composer_url = "https://mirrors.ustc.edu.cn/composer/",
    },
    .{
        .id = "tuna",
        .label = "清华",
        .apt_host = "mirrors.tuna.tsinghua.edu.cn",
        .alpine_host = "mirrors.tuna.tsinghua.edu.cn",
        .pip_url = "https://pypi.tuna.tsinghua.edu.cn/simple",
        .npm_url = "https://registry.npmmirror.com",
        .composer_url = "https://mirrors.tuna.tsinghua.edu.cn/composer/",
    },
};

const generic_supervisord =
    \\[supervisord]
    \\nodaemon=true
    \\logfile=/dev/null
    \\logfile_maxbytes=0
    \\pidfile=/tmp/supervisord.pid
    \\
    \\[unix_http_server]
    \\file=/run/supervisor.sock
    \\chmod=0700
    \\
    \\[supervisorctl]
    \\serverurl=unix:///run/supervisor.sock
    \\
    \\[rpcinterface:supervisor]
    \\supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
    \\
    \\[program:app]
    \\command=sleep infinity
    \\autostart=true
    \\autorestart=true
    \\stdout_logfile=/dev/stdout
    \\stdout_logfile_maxbytes=0
    \\stderr_logfile=/dev/stderr
    \\stderr_logfile_maxbytes=0
    \\
;

const php_supervisord =
    \\[supervisord]
    \\nodaemon=true
    \\logfile=/dev/null
    \\logfile_maxbytes=0
    \\pidfile=/tmp/supervisord.pid
    \\
    \\[unix_http_server]
    \\file=/run/supervisor.sock
    \\chmod=0700
    \\
    \\[supervisorctl]
    \\serverurl=unix:///run/supervisor.sock
    \\
    \\[rpcinterface:supervisor]
    \\supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
    \\
    \\[program:php-fpm]
    \\command=php-fpm -F
    \\autostart=true
    \\autorestart=true
    \\stdout_logfile=/dev/stdout
    \\stdout_logfile_maxbytes=0
    \\stderr_logfile=/dev/stderr
    \\stderr_logfile_maxbytes=0
    \\
    \\[program:nginx]
    \\command=nginx -g "daemon off;"
    \\autostart=true
    \\autorestart=true
    \\stdout_logfile=/dev/stdout
    \\stdout_logfile_maxbytes=0
    \\stderr_logfile=/dev/stderr
    \\stderr_logfile_maxbytes=0
    \\
;

const php_ini =
    \\memory_limit = 256M
    \\upload_max_filesize = 64M
    \\post_max_size = 64M
    \\max_execution_time = 120
    \\date.timezone = UTC
    \\opcache.enable = 1
    \\opcache.validate_timestamps = 1
    \\
;

const php_fpm_pool =
    \\[www]
    \\user = www-data
    \\group = www-data
    \\listen = 127.0.0.1:9000
    \\pm = dynamic
    \\pm.max_children = 10
    \\pm.start_servers = 2
    \\pm.min_spare_servers = 1
    \\pm.max_spare_servers = 3
    \\
;

const php_nginx =
    \\server {
    \\    listen 80;
    \\    listen [::]:80;
    \\    root /var/www/html;
    \\    index index.php index.html;
    \\
    \\    location / {
    \\        try_files $uri $uri/ =404;
    \\    }
    \\
    \\    location ~ \.php$ {
    \\        include fastcgi_params;
    \\        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    \\        fastcgi_pass 127.0.0.1:9000;
    \\    }
    \\}
    \\
;

const generic_configs = &[_]ConfigFile{
    .{ .name = "supervisord.conf", .container_path = "/etc/hampanel/supervisord.conf", .content = generic_supervisord },
};

const php_configs = &[_]ConfigFile{
    .{ .name = "php.ini", .container_path = "/usr/local/etc/php/conf.d/hampanel.ini", .content = php_ini },
    .{ .name = "www.conf", .container_path = "/usr/local/etc/php-fpm.d/www.conf", .content = php_fpm_pool },
    .{ .name = "nginx.conf", .container_path = "/etc/nginx/conf.d/default.conf", .content = php_nginx },
    .{ .name = "supervisord.conf", .container_path = "/etc/hampanel/supervisord.conf", .content = php_supervisord },
};

pub const runtimes = [_]Runtime{
    .{
        .id = "node",
        .name = "Node.js",
        .description = "JavaScript / TypeScript 运行时，预装 npm、pnpm、TypeScript、PM2。",
        .image = "node",
        .tag = "24-bookworm-slim",
        .docker_repo = "library/node",
        .workdir = "/app",
        .web_port = 3000,
        .recommended_tags = &.{ "24-bookworm-slim", "22-bookworm-slim", "24-alpine", "22-alpine", "24-bookworm", "22-bookworm" },
        .extensions = &.{
            .{ .id = "typescript", .label = "TypeScript" },
            .{ .id = "pnpm", .label = "pnpm" },
            .{ .id = "nodemon", .label = "nodemon" },
            .{ .id = "pm2", .label = "PM2" },
        },
        .config_files = generic_configs,
    },
    .{
        .id = "python",
        .name = "Python",
        .description = "Python 3 运行时，预装 pip 与常用 Web 框架。",
        .image = "python",
        .tag = "3.13-slim-bookworm",
        .docker_repo = "library/python",
        .workdir = "/app",
        .web_port = 8000,
        .recommended_tags = &.{ "3.13-slim-bookworm", "3.12-slim-bookworm", "3.13-alpine", "3.12-alpine" },
        .extensions = &.{
            .{ .id = "flask", .label = "Flask" },
            .{ .id = "fastapi", .label = "FastAPI" },
            .{ .id = "uvicorn", .label = "Uvicorn" },
            .{ .id = "gunicorn", .label = "Gunicorn" },
            .{ .id = "requests", .label = "Requests" },
        },
        .config_files = generic_configs,
    },
    .{
        .id = "java",
        .name = "Java",
        .description = "Eclipse Temurin JDK，适合 Spring Boot 等 JVM 应用。",
        .image = "eclipse-temurin",
        .tag = "25-jdk",
        .docker_repo = null,
        .workdir = "/app",
        .web_port = 8080,
        .recommended_tags = &.{ "25-jdk", "21-jdk", "25-jre", "21-jre" },
        .extensions = &.{},
        .config_files = generic_configs,
    },
    .{
        .id = "go",
        .name = "Go",
        .description = "Go 工具链与构建缓存，适合 API 服务与命令行程序。",
        .image = "golang",
        .tag = "1.25-bookworm",
        .docker_repo = "library/golang",
        .workdir = "/app",
        .web_port = 8080,
        .recommended_tags = &.{ "1.25-bookworm", "1.24-bookworm", "1.25-alpine" },
        .extensions = &.{
            .{ .id = "air", .label = "Air（热重载）" },
            .{ .id = "delve", .label = "Delve（调试）" },
        },
        .config_files = generic_configs,
    },
    .{
        .id = "php",
        .name = "PHP-FPM",
        .description = "PHP-FPM + Nginx 部署形态；扩展与 FPM/Nginx 配置均可编辑。",
        .image = "php",
        .tag = "8.5-fpm-bookworm",
        .docker_repo = "library/php",
        .workdir = "/var/www/html",
        .web_port = 80,
        .recommended_tags = &.{ "8.5-fpm-bookworm", "8.5-fpm-alpine", "8.5-fpm" },
        .extensions = &.{
            .{ .id = "opcache", .label = "OPcache" },
            .{ .id = "redis", .label = "Redis" },
            .{ .id = "mbstring", .label = "mbstring" },
            .{ .id = "gd", .label = "GD" },
            .{ .id = "zip", .label = "Zip" },
            .{ .id = "intl", .label = "Intl" },
            .{ .id = "bcmath", .label = "BCMath" },
            .{ .id = "pdo_mysql", .label = "PDO MySQL" },
            .{ .id = "pdo_pgsql", .label = "PDO PostgreSQL" },
            .{ .id = "imagick", .label = "Imagick" },
        },
        .config_files = php_configs,
    },
    .{
        .id = "ruby",
        .name = "Ruby",
        .description = "Ruby 运行时，预装 Bundler 与常用 Web 框架。",
        .image = "ruby",
        .tag = "3.4-slim-bookworm",
        .docker_repo = "library/ruby",
        .workdir = "/app",
        .web_port = 3000,
        .recommended_tags = &.{ "3.4-slim-bookworm", "3.3-slim-bookworm", "3.4-alpine", "3.3-alpine" },
        .extensions = &.{
            .{ .id = "rails", .label = "Rails" },
            .{ .id = "sinatra", .label = "Sinatra" },
            .{ .id = "puma", .label = "Puma" },
        },
        .config_files = generic_configs,
    },
    .{
        .id = "dotnet",
        .name = ".NET",
        .description = ".NET ASP.NET Core 运行时（LTS）。",
        .image = "mcr.microsoft.com/dotnet/aspnet",
        .tag = "10.0",
        .docker_repo = null,
        .workdir = "/app",
        .web_port = 8080,
        .recommended_tags = &.{ "10.0", "8.0" },
        .extensions = &.{},
        .config_files = generic_configs,
    },
    .{
        .id = "custom",
        .name = "自定义镜像",
        .description = "使用任意 Docker 镜像；需自行保证包含 supervisord 或可安装的包管理器。",
        .image = "",
        .tag = "",
        .docker_repo = null,
        .workdir = "/app",
        .web_port = 8080,
        .recommended_tags = &.{},
        .extensions = &.{},
        .config_files = generic_configs,
    },
};

pub fn find(id: []const u8) ?*const Runtime {
    for (&runtimes) |*runtime| {
        if (std.mem.eql(u8, runtime.id, id)) return runtime;
    }
    return null;
}

pub fn mirrorPreset(id: []const u8) ?*const MirrorPreset {
    for (&mirror_presets) |*preset| {
        if (std.mem.eql(u8, preset.id, id)) return preset;
    }
    return null;
}

pub fn extensionAllowed(runtime: *const Runtime, id: []const u8) bool {
    for (runtime.extensions) |extension| {
        if (std.mem.eql(u8, extension.id, id)) return true;
    }
    return false;
}
