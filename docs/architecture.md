# Hampanel 架构设计

## 1. 总览

Hampanel 由三个可独立部署的部分组成：

| 组件 | 技术 | 位置 | 职责 |
| --- | --- | --- | --- |
| `hampaneld` | Zig + OpenSSL | 被管理服务器 | 提供 mTLS API、执行系统操作 |
| Hampanel App | Flutter | 运维人员设备 | 可视化操作面板 |
| `hampanelctl` | Dart CLI | 运维人员设备 | 通过 SSH 编排远端编译、安装与注册 |

```
┌──────────────┐   SSH (scp/ssh)   ┌─────────────────────────┐
│ hampanelctl  │ ────────────────> │ deploy/bootstrap.sh     │
└──────┬───────┘                   │  ├─ 安装 Zig 工具链      │
       │ enrollment.json           │  ├─ zig build           │
       v                           │  ├─ 安装 systemd 单元    │
┌──────────────┐                   │  └─ hampaneld init      │
│ Flutter App  │                   └───────────┬─────────────┘
└──────┬───────┘                               │
       │ mTLS (TLS 1.3, 客户端证书)             v
       └──────────────────────────────> ┌──────────────┐
                                        │  hampaneld   │
                                        │  :8443       │
                                        └──────────────┘
```

## 2. 信任模型

首次初始化时 `hampaneld init` 生成：

- **CA**：EC P-256，自签名，`CA:TRUE`，有效期 10 年。
- **服务端证书**：EC P-256，`serverAuth`，SAN 包含 `localhost`、`127.0.0.1` 以及 `--san` 指定的地址。
- **客户端证书**：EC P-256，`clientAuth`，CN 为 `hampanel-client-<随机标识>`。

注册凭据（enrollment bundle）是一个 JSON，包含 CA 证书、客户端证书、客户端私钥、服务端指纹、endpoint 与 `entry_prefix`。初始化时默认随机挑选空闲端口，并生成随机入口前缀；客户端将其保存在本地配置目录，后续所有连接自动拼接前缀并使用该证书。

服务端 TLS 配置：

- `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`
- 信任链仅为本项目 CA
- 最低 TLS 1.2，优先 TLS 1.3
- 校验客户端证书 CN 前缀（默认 `hampanel-client`）
- 拒绝会话重协商与压缩

私钥权限：`0600`；PKI 目录：`0700`。

## 3. 通信层

- **HTTP/1.1**：自研最小实现，支持 keep-alive、`Content-Length`、请求体大小上限、查询串百分号解码。
- **路由**：`METHOD /api/v1/<module>/<action>`，支持 `:param` 路径段。若配置了
  `entry_prefix`，服务端会先校验并剥离前缀，未携带前缀的请求返回 404。
- **响应**：JSON 为主；文件下载为二进制流。
- **WebSocket**：用于交互终端；握手手工实现（SHA-1 + Base64），支持文本 / 二进制 / ping / close 帧。
- **并发**：每连接一个 OS 线程；请求内存使用 arena，请求结束统一释放。

## 4. 模块边界（daemon）

```
src/main.zig            进程入口，仅做 argv 与错误出口
src/cli.zig             子命令：run / init / enroll / version（Windows: --service）
src/config.zig          按平台选择默认目录，JSON 加载与保存
src/log.zig             分级日志（stderr）
src/server.zig          监听循环、连接线程
src/net/conn.zig        TLS 连接、带缓冲读写
src/tls.zig             OpenSSL 上下文 / 握手 / 读写封装
src/pki.zig             证书签发、PEM 输出、指纹
src/enroll.zig          注册凭据生成与读取
src/http/request.zig    请求行、头、体解析
src/http/response.zig   状态码、JSON、文件流
src/http/router.zig     路由匹配与分发
src/http/websocket.zig  握手与帧编解码
src/api/context.zig     请求上下文与统一 JSON 错误
src/api/mod.zig         路由注册表
src/api/*.zig           薄处理器：参数校验、调用平台后端、组织 JSON
src/platform/mod.zig    通过 build 注入的 platform_backend 模块选择实现
src/platform/types.zig  跨平台返回结构
src/platform/linux/*    Linux 实现（procfs、systemd、Nginx、UFW、crontab、PTY）
src/platform/windows/*  Windows 实现（Win32、PowerShell、管道式 shell、服务包装）
src/sys/exec.zig        安全 argv 执行（两平台共用）
src/sys/procfs.zig      Linux /proc 与磁盘指标
src/recycle.zig         文件回收站（移动/恢复/永久删除）
src/versions.zig        文件历史版本（面板数据目录、内容寻址）
src/notify.zig          Bark / ntfy 推送（登录、AI 操作等事件）
src/audit.zig           请求审计
src/runtime/site_webhook.zig  Webhook 站点 Nginx/Caddy 转发配置
src/runtime/cron_webhook.zig  Linux 内部 Cron 回调的独立回环监听、凭据校验与任务触发
src/service_stub.zig    非 Linux 目标的 systemd 占位实现
src/platform/linux/waf.zig  Caddy+Coraza WAF 边缘（构建/配置/进程/日志）
src/store/catalog.zig   内嵌 Docker 应用目录
src/store/apps.zig      参数校验、Compose 渲染与执行
src/platform/linux/packages.zig  包管理器检测与精选工具安装
src/platform/linux/nix.zig       Nix 状态、白名单 build / run
src/platform/linux/ssh.zig       sshd 状态、drop-in 配置校验/回滚、authorized_keys
src/platform/linux/software.zig  软件安装/托管状态、Nginx/Docker 初始化
src/platform/linux/host_settings.zig  swap / NTP / GRUB / hosts
src/platform/linux/fail2ban.zig  Fail2ban 初始化、jail、封禁与阈值
src/util/*.zig          查询串、校验、错误名、文本工具
```

**平台隔离方式**：`build.zig` 根据目标 OS 选择 `platform_backend` 模块的根文件，
源代码中统一 `@import("platform_backend")`。Linux 目标不会分析 Windows 代码，
反之亦然；`zig build check-windows` 会对 Windows 后端做跨平台类型检查。

每个 API 模块只依赖 `api/context.zig`、`platform/*`、`shared` 模块与标准库，
禁止跨模块调用彼此的内部函数，也不直接调用 systemctl/ufw/crontab 等平台工具。

**Webhook WebServer 差异**：固定外部上游转发支持 Nginx 与 Caddy。内部 Cron 回调仅在显式选择 Nginx 且内部监听就绪时提供；宿主和受管容器 Nginx 通过专用 Unix socket 转发，daemon 另监听本机回环地址，内部端点不复用 mTLS 管理 API。凭据是 URL 路径中的 bearer token，站点须配置 HTTPS。QEMU 客体中 Nginx 的 HTTPS 创建、触发、拒绝、轮换、撤销及日志检查通过；受管容器的只读 socket 挂载与转发仅通过隔离容器验证，尚未完成完整受管部署验收。

Caddy 2.6.2 在 QEMU 中能创建内部回调站点、成功触发并执行轮换/撤销，但 `caddy.service` 的 `http.log.access` 仍将含 token 的请求 URI 写入 journal，即使站点设置了 `log { output discard }`。因此当前 daemon 对 Caddy 不声明内部 Cron 能力，并拒绝创建、换绑和轮换该类站点；Caddy 仍可用于固定外部上游转发。升级不能清除已写入 journal 的旧凭据，也不会自动卸载先前加载的 Caddy 内部回调站点：先停止旧 URL 投递、删除旧站点并确认 Caddy 重载，限制历史日志访问，再从 Nginx 重新签发 HTTPS URL。勿将 Caddy（包括 Caddy WAF 边缘）置于路径 token 入口前，除非已独立验证其日志策略不会记录 URI。

构建版本：`build.zig` 读取 `git rev-parse --short HEAD` 与工作区状态，通过
`build_info` 模块注入 `src/version.zig`，格式为 `0.1.0+<hash>[.dirty]`。
`/api/v1/health` 和 `hampaneld version` 返回同一字符串。

## 5. API 一览

所有路径前缀 `/api/v1`，并且默认还需要客户端配置中的安全入口前缀
（`entry_prefix`）。下表中的路径均指剥离入口前缀后的路径。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 健康检查 |
| GET | `/system` | 主机信息 |
| GET | `/metrics` | CPU / 内存 / 磁盘 / 网络（含各网卡速率） |
| GET | `/processes` | 进程列表 |
| GET | `/processes/:pid` | 进程详情（exe、cwd、UID/GID、线程、打开文件、监听端口） |
| POST | `/processes/:pid/kill` | 发送 TERM / KILL 信号 |
| GET | `/files?path=` | 目录列表 |
| GET | `/files/meta?path=` | 文件元数据（`file(1)` 类型、权限位、属主） |
| GET | `/files/accounts` | 系统用户与用户组 |
| POST | `/files/permissions` | 修改权限 / 属主（仅文本文件） |
| GET | `/files/content?path=` | 读取文本文件 |
| PUT | `/files/content` | 写入文件 |
| POST | `/files/mkdir` | 新建目录 |
| POST | `/files/rename` | 重命名 |
| POST | `/files/delete` | 删除（移动到回收站） |
| GET | `/files/download?path=` | 下载 |
| POST | `/files/upload?path=` | 上传（原始 body；覆盖前保存版本） |
| GET | `/files/versions?path=` | 文件历史版本 |
| GET | `/files/versions/content?path=&id=` | 版本内容 |
| POST | `/files/versions/restore` | 恢复历史版本 |
| GET | `/waf` | WAF 边缘状态 |
| POST | `/waf/config` | 保存/校验 WAF 边缘配置 |
| GET | `/waf/logs` | WAF 访问日志 |
| GET | `/waf/geo/catalog` | GeoIP / GeoSite 分类目录 |
| POST / DELETE | `/waf/typesafe/key` | TypeSafe 风险复检密钥 |
| GET | `/recycle` | 回收站列表 |
| POST | `/recycle/restore` / `delete` / `empty` | 恢复 / 永久删除 / 清空 |
| GET | `/terminal/ws` | 交互终端（WebSocket） |
| GET | `/services` | systemd 单元 |
| GET | `/services/:name/logs` | journal |
| GET | `/sites` | 站点列表 |
| POST | `/sites` | 创建 / 更新站点 |
| POST | `/sites/:name/toggle` | 启用 / 停用 |
| GET | `/docker/overview`、`/docker/info`、`/docker/test-connection` | 概览与引擎信息 |
| GET | `/docker/containers`、`/docker/containers/:id` | 容器列表（含 inspect/统计/备注）与详情 |
| POST | `/docker/containers`、`/docker/containers/:id/recreate` | 从镜像创建、按配置重建 |
| POST | `/docker/containers/:id/:action` | 启停 / 重启 / 删除 |
| POST | `/docker/containers/:id/commit` | 导出为镜像 |
| GET | `/docker/containers/:id/logs`、`/terminal/ws`、`/files*` | 日志、终端、容器内文件 |
| GET / PUT / DELETE | `/docker/notes`、`/docker/notes/:name` | 容器备注 |
| GET / POST | `/docker/compose`、`/docker/compose/adopt` | 编排列表、创建、接管 |
| GET / PUT / DELETE | `/docker/compose/:name` | 编排详情、保存、删除 |
| POST | `/docker/compose/:name/:action` | up / down / restart / pull |
| GET | `/docker/compose/:name/logs` | 编排日志 |
| GET | `/docker/images`、`/docker/images/search` | 镜像列表与检索 |
| POST | `/docker/images/pull`、`push`、`update`、`tag`、`export`、`import`、`build*`、`prune` | 镜像动作（长任务返回 job id） |
| DELETE | `/docker/images/:id` | 删除镜像 |
| GET / POST | `/docker/networks`、`/docker/volumes` | 网络 / 存储卷列表与创建 |
| DELETE | `/docker/networks/:name`、`/docker/volumes/:name` | 删除网络 / 存储卷 |
| POST | `/docker/networks/prune`、`/docker/volumes/prune` | 清理 |
| GET / POST | `/docker/registries` | 镜像源列表与添加 |
| PUT / DELETE | `/docker/registries/:id`、`/docker/registries/:id/sync` | 编辑 / 删除 / 登录同步 |
| GET | `/docker/jobs/:id`、`/docker/jobs/:id/download` | 异步任务状态与产物下载 |
| GET | `/firewall` | UFW 状态与规则 |
| POST | `/firewall/rules` | 新增规则 |
| POST | `/firewall/rules/delete` | 按规则 id 删除（Linux: 编号，Windows: 规则名） |
| GET | `/cron` | 计划任务 |
| POST | `/cron` | 新增 |
| POST | `/cron/delete` | 删除 |
| GET | `/logs/sources` | 可查看日志源 |
| GET | `/logs/tail?source=&lines=` | 日志尾部 |
| GET | `/audit` | 面板审计记录 |
| GET / POST | `/tasks`、`/tasks/:id`、`/tasks/events` | 异步任务：提交、查询、取消、SSE 推送 |
| GET | `/store/apps` | Docker 应用目录与部署状态 |
| GET | `/store/apps/:slug` | 应用详情与 Compose 状态 |
| GET | `/store/apps/:slug/logs` | Compose 日志 |
| GET | `/store/packages` | 包管理器与精选工具状态 |
| GET | `/store/nix` | Nix 状态与白名单目标 |
| GET | `/ssh` | sshd 状态与生效配置 |
| POST | `/ssh/config` | 写入 drop-in、`sshd -t` 校验并重载 |
| GET | `/ssh/keys?user=` | authorized_keys 列表 |
| POST | `/ssh/keys` | 添加公钥 |
| POST | `/ssh/keys/delete` | 按索引删除公钥 |
| GET | `/ssh/logging` | 当前日志记录模式与可用来源 |
| POST | `/ssh/logging` | 切换 syslog / rsyslog 文件模式 |
| GET | `/ssh/logs?source=&lines=` | journald / auth.log / 文件日志 |
| GET | `/software` | 支持软件的安装/初始化/运行状态 |
| GET | `/fail2ban` | Fail2ban 状态、jail、封禁 IP |
| POST | `/fail2ban/ban` / `unban` | 封禁 / 解封 IP |
| POST | `/fail2ban/config` | 更新 maxretry / bantime / findtime 并重载 |
| GET / PUT | `/docker/settings` | Docker 守护进程配置（加速、私有仓库、IPv6、日志、iptables、Live Restore、Cgroup、NVIDIA、Socket） |
| GET | `/runtimes`、`/runtimes/catalog`、`/runtimes/:id/*` | 运行环境与扩展、配置、进程管理（写操作见任务接口） |
| GET | `/host/settings` | 主机设置状态（swap / NTP / GRUB / hosts） |
| PUT | `/host/hosts` | 写入 /etc/hosts |
| GET / PUT | `/notifications` | Bark / ntfy 推送配置 |
| POST | `/notifications/test` | 发送测试推送 |
| GET | `/update` | 更新状态、通道与 GitHub 镜像 |
| POST | `/update/check` | 检查更新（执行更新见任务接口） |
| PUT | `/update/config` | 修改更新通道与 GitHub 镜像 |
| POST / DELETE | `/update/schedule` | 每日更新检查开关 |

### 5.1 应用商店

Docker 应用目录以 YAML + 元数据的形式编入 daemon（`@embedFile`），部署时渲染
`{{param}}` 占位符并写入 `<data_dir>/apps/<slug>/compose.yml`。参数经过字符白名单
与端口校验，Compose 以 `docker compose -p hampanel-<slug>` 执行；卸载可选 `-v`。
包管理器与 Nix 能力位于平台后端，Windows 返回 `Unsupported`。详见
[docs/store.md](store.md)。

### 5.2 AI 助手边界

AI 助手与端口穿透完全位于 Flutter 管理端：模型配置、工具勾选、敏感路径和隧道配置保存在客户端；
API Key 写入系统钥匙串；SSH/socat 子进程也由管理端启动，daemon 不保存隧道凭据。
它只调用 daemon 的公开 API 白名单，不存在 shell 工具；修改类工具在执行前必须由
用户确认。文件删除只能进入回收站，写入会自动创建历史版本。详见
[docs/ai.md](ai.md)。

## 6. Windows 运行时模型

```
┌──────────────────────────── Windows ─────────────────────────────┐
│  hampaneld.exe (用户态服务)                                       │
│    ├─ TLS 1.3 mTLS 监听 / HTTP / WebSocket                        │
│    ├─ 文件、终端(shell 管道)、服务、防火墙、任务计划              │
│    └─ \\.\Hampanel  ──► hampanel.sys (可选内核伴随驱动)          │
│                                 IOCTL: PING / GET_VERSION          │
└──────────────────────────────────────────────────────────────────┘
```

- 服务通过 `sc.exe create` 注册，`--service` 模式使用
  `StartServiceCtrlDispatcherW`，支持 SCM 停止/关机控制。
- 系统信息、CPU/内存/磁盘/网络、进程均调用 Win32 API；服务、防火墙、
  任务计划使用 PowerShell 的强类型 Cmdlet 并输出 JSON。
- 终端目前使用 `cmd.exe` 管道会话；ConPTY 支持计划在后续版本接入。
- PowerShell 输出强制 UTF-8，服务端统一解析为 JSON。

## 7. 命令执行安全

- 所有外部命令通过 `argv` 数组执行，不拼接 shell。
- 单元名、容器 ID、站点名、UFW 规格、Cron 字段在进入命令前做正则白名单校验。
- 站点配置写入后先执行 `nginx -t`，失败则回滚文件，不触发 reload。
- 日志源使用固定 allowlist，不接受任意路径读取。

## 8. 远端编译与安装

`deploy/bootstrap.sh` 在目标机执行，幂等：

1. 识别 `uname -m` / libc，选择 Zig 工具链。
2. 若系统无 Zig 0.17.1+，下载官方静态包到 `/opt/hampanel/toolchain`。
3. 检查 OpenSSL 开发头文件，按包管理器安装 `libssl-dev` / `openssl-devel`。
4. 解压源码到 `/opt/hampanel/build`，`zig build -Doptimize=ReleaseSafe`。
5. 安装二进制、配置目录、systemd 单元。
6. 首次运行 `hampaneld init` 生成 PKI 与注册凭据。
7. 启动服务并等待健康检查。
8. 二进制安装会写入 `install_mode=binary`，并由客户端安装器选择是否启用每日更新检查。

`hampanelctl` 只负责 SSH / SCP 编排与结果回收，构建逻辑全部在远端脚本中，便于审计和离线复用。

## 9. 客户端设计

Flutter 客户端按 feature 拆分：

- `core/api_client.dart`：基于 `dart:io HttpClient` 与 `SecurityContext` 的 mTLS 客户端。
- `core/enrollment.dart`：注册凭据解析与本地持久化。
- `core/models/`：按领域拆分的强类型模型。
- `features/<domain>/`：页面 + 该领域的局部组件 / 状态。
- `ui/`：主题、卡片、空状态、错误提示等通用组件。

WebSocket 通过 `WebSocket.connect(..., customClient: httpClient)` 复用同一 mTLS 上下文。

窗口宽度小于 900px 时主侧栏收起为抽屉，小于 720px 时二级导航（设置、SSH、AI 对话列表）
改为标题栏上的紧凑菜单或底部弹层；所有对话框主体通过 `DialogBody` 限制在当前视口内。

## 10. 已知边界

- 受控端支持 Linux 与 Windows；Docker 能力要求目标机安装 Docker 或 Podman。
- macOS / Android / iOS 只提供管理端，不能作为受控端。
- 暂未实现数据库管理、备份、ACME 证书申请和多用户 RBAC。
- 界面语言为简体中文，代码标识符与 API 为英文。
