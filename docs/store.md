# 应用商店

应用商店由三部分组成：仓库内置的 Docker Compose 应用目录、Linux 包管理器精选工具、
以及 Nix 的构建 / 运行入口。所有操作都通过 mTLS API 执行，客户端不直接接触服务器 shell。

## 1. Docker 应用目录

应用定义位于 `daemon/src/store/catalog/`，通过 `@embedFile` 编入二进制，因此部署时
不需要额外上传目录。

| slug | 应用 | 默认参数 |
| --- | --- | --- |
| nginx | Nginx 1.27 Alpine | HTTP 端口 |
| redis | Redis 7 Alpine（密码保护） | 端口、密码（留空自动生成） |
| postgres | PostgreSQL 16 Alpine | 端口、用户、数据库、密码 |
| mariadb | MariaDB 11 | 端口、数据库、root 密码 |
| minio | MinIO 对象存储 | API 端口、控制台端口、账号、密码 |
| gitea | Gitea | Web 端口、SSH 端口 |
| uptime-kuma | Uptime Kuma | 端口 |
| adminer | Adminer | 端口 |
| code-server | code-server | 端口、密码 |

部署通过 `POST /api/v1/tasks` `kind=store.deploy` `params={"slug":"<应用>","params":{...}}`
提交；daemon 在 `<data_dir>/apps/<slug>/compose.yml` 生成 Compose 文件
（权限 `0600`），并以 `docker compose -p hampanel-<slug> up -d` 启动。
生成的密码等实际参数写入任务的 `result`，部署日志走任务输出。
数据使用命名卷，卸载时默认保留；选择「卸载并删除数据」才会执行 `down -v`。

### 参数与安全

- 参数值经过白名单字符校验，禁止换行、引号、反斜杠与 `$`，避免 YAML / Compose 注入。
- 端口必须是 `1..65535` 的整数。
- 密码参数留空时由 `std.crypto.random` 生成 32 位十六进制字符串，并在部署结果中返回一次。
- 应用 slug 来自代码内静态目录，API 不接受任意镜像名或 Compose 内容。
- Compose 命令通过 argv 直接执行，不经过 shell。

### 新增应用

1. 在 `daemon/src/store/catalog/` 添加 Compose YAML，使用 `{{param}}` 占位符。
2. 在 `daemon/src/store/catalog.zig` 的 `apps` 中登记元数据与参数。
3. `zig build` 重新编译。

参数模板必须覆盖所有占位符，否则渲染会拒绝部署。

## 2. Linux 包管理器

自动检测 `apt` / `dnf` / `yum` / `zypper` / `pacman` / `apk`，提供固定白名单工具：
Git、cURL、Wget、htop、Vim、tmux、jq、unzip、rsync、tree、ncdu、zstd、ripgrep、
fail2ban、rsyslog、Docker、Podman 等。安装命令由后端根据管理器生成，API 只接受工具 ID。

- `GET /api/v1/store/packages`
- `POST /api/v1/tasks` `kind=package.refresh`
- `POST /api/v1/tasks` `kind=package.install` `params={"id":"<工具 ID>"}`
- `POST /api/v1/tasks` `kind=package.custom` `params={"name":"<包名>"}`：安装目录未收录的工具，
  包名仍需通过字符白名单校验（不接受空格、选项或 shell 元字符）。

Windows 后端返回“不支持”，不会调用任意命令。

### 容器引擎

「容器」页面优先使用 `docker`，未安装时回退到 `podman`（CLI 与 Docker 兼容）；
两者都不可用时页面给出安装引导，而不是只报错。应用商店提供 Docker 与 Podman 的安装项。

安装后的 Fail2ban 可在「软件」页面完成初始化与托管管理（需用户确认），
详见 [software.md](software.md)。

## 3. Nix

### 服务器端

检测 `nix` 与 flakes 支持，允许对精选属性执行：

- `POST /api/v1/tasks` `kind=nix.build` `params={"target":"jq"}` → `nix build --no-link --print-out-paths nixpkgs#jq`
- `POST /api/v1/tasks` `kind=nix.run` `params={"target":"hello","args":[]}` → `nix run nixpkgs#hello`

两类操作都走任务接口，见 [tasks.md](tasks.md)。

目标可以是内置白名单（hello / jq / ripgrep / fd / bat / htop / tree / cowsay），
也可以填写自定义 nixpkgs 属性名（只允许包名字符，不含表达式语法），
避免把面板变成任意表达式执行器。Nix 本身需要管理员在服务器上自行安装。

### 仓库 flake

仓库根目录提供 `flake.nix`：

```bash
nix build .#default     # 构建 hampaneld
nix run .#default -- version
nix develop             # Zig + OpenSSL + pkg-config 开发环境
```

flake 通过 `-Dopenssl-include` / `-Dopenssl-lib-dir` 指向 Nix store 中的 OpenSSL，
并把 `self.shortRev` 注入版本号。Flake 需要仓库至少有一个 Git 提交；未提交的工作区
可以使用 `nix build path:.` 调试。
