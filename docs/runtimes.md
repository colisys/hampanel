# 运行环境管理器

运行环境管理器借用宿主机的 Docker，为 Node、Python、Java、Go、PHP、Ruby、.NET
或任意自定义镜像创建隔离运行时，并在客户端「运行环境」页面统一管理。受管数据
（环境、可编辑配置、审计日志、更新状态、设置）存放在 SQLite
`<data-dir>/hampanel.db` 中，不再散落 JSON 文件。

## 版本策略

- 目录中的版本只是**推荐预设**（当前 LTS / 当前稳定版、锁定 minor tag、随安全
  通告更新）：Node 24/22 LTS、Python 3.13、Java 25/21 LTS、Go 1.25、PHP
  ≥ 8.5.12（8.5-fpm）、Ruby 3.4、.NET 10/8 LTS。
- **不限制用户安装的版本**：tag 可从 Docker 注册表 tags 列表选择，也可自由填写任意
  `image:tag` 或自定义镜像。旧版本同样可以安装，面板会标注非推荐风险。
- PHP 低于 8.5.12 存在已知漏洞，不进入推荐预设。

## 环境组成

每个环境由面板生成一份 Dockerfile 并构建镜像 `hampanel-rt-<id>:cfg<n>`：

1. `FROM <镜像:tag>`；
2. 可选注入镜像内包管理器镜像源（apt / apk / pip / npm / composer，预置阿里云、
   腾讯云、中科大、清华，也支持 `custom:<url>`）；
3. 安装 `supervisor`（PID 1）；
4. 按勾选的扩展安装插件（PHP 使用 `install-php-extensions`；Node 使用
   `npm install -g`；Python 使用 `pip`；Ruby 使用 `gem`；Go 使用 `go install`）；
5. 启动 `supervisord -c /etc/hampanel/supervisord.conf`。

配置目录 `<data-dir>/runtimes/<id>/config/` 以只读方式挂载进容器；`php.ini`、
`www.conf`、`nginx.conf`、`supervisord.conf` 等均可在面板中编辑，保存后重启容器
生效。扩展 / 包管理器镜像源变更会触发镜像重建。

## supervisord 与进程

- PHP 形态默认运行 `php-fpm` 与 `nginx` 两个 program；其他运行时默认运行
  `app`（`sleep infinity`，可在 `supervisord.conf` 中改成实际应用命令）。
- 面板提供 `supervisorctl status/start/stop/restart` 的进程级操作。
- Supervisor 使用 `/run/supervisor.sock` 与
  `[rpcinterface:supervisor]`，支持容器内 `supervisorctl -c
  /etc/hampanel/supervisord.conf ...`。

## Docker 守护进程设置

「运行环境」页提供 Docker 设置，可写 `/etc/docker/daemon.json`（Windows 为
`C:\ProgramData\docker\config\daemon.json`）：

- `registry-mirrors`：镜像拉取源列表；
- `ipv6` / `fixed-cidr-v6`：IPv6 实验特性；
- `experimental`：Docker 实验特性。

保存时读取并合并现有 JSON，保留未知字段；写入前备份为 `daemon.json.bak-<时间戳>`。
可选择同时重启 Docker（会中断运行中的容器），非特权环境会返回明确错误。测试或
非标准安装可用环境变量 `HAMPANEL_DOCKER_CONFIG=<path>` 覆盖配置文件路径。

## 环境管理页

每个环境在客户端有「管理」入口，用标签页组织：日志（容器输出，可搜索与截断）、
配置（可编辑并保存后重启）、扩展（勾选插件触发重建）、进程（`supervisorctl` 逐进程操作）。

## API 摘要

- `GET/POST /api/v1/runtimes`
- `GET /api/v1/runtimes/catalog`、`GET /api/v1/runtimes/catalog/:runtime/tags`
- `POST /api/v1/runtimes/:id/{start|stop|restart|rebuild}`
- `GET /api/v1/runtimes/:id/logs`、`GET /api/v1/runtimes/:id/processes`
- `POST /api/v1/runtimes/:id/processes/:name/{start|stop|restart}`
- `GET/PUT /api/v1/runtimes/:id/config`
- `GET/PUT /api/v1/runtimes/:id/extensions`
- `DELETE /api/v1/runtimes/:id?volumes=`
- `GET/PUT /api/v1/docker/settings`

## 存储

SQLite 由 vendored amalgamation（`daemon/vendor/sqlite/`）编译，不依赖系统
libsqlite3。schema 版本记录在 `schema_migrations`：

- `settings`：更新状态、Docker 设置快照等；
- `runtime_environments`；
- `runtime_config_files`；
- `audit_log`（新审计记录；旧 `audit.jsonl` 保留只读）。

`config.json` 仅作为安装器的引导配置（监听、端口、TLS、入口前缀）；运行期可变数据
统一进入 SQLite。
