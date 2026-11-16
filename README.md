# Hampanel

[![Build (main)](https://github.com/colisys/hampanel/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/colisys/hampanel/actions/workflows/build.yml)
[![Build (nightly)](https://github.com/colisys/hampanel/actions/workflows/build.yml/badge.svg?branch=nightly)](https://github.com/colisys/hampanel/actions/workflows/build.yml)

官网：<https://hampanel.dawncall.work> · 产品标识：`work.dawncall.hampanel`

Hampanel 是一个 **CleanRoom 实现**、以 **GPL-3.0-or-later** 授权的开源服务器运维面板。

- **后端**：Zig（单二进制 daemon，直接调用操作系统能力）
- **界面**：Flutter（桌面 / 移动端原生客户端）
- **传输**：双向 TLS（mTLS），客户端证书由服务端 CA 签发
- **部署**：`hampanelctl` 默认通过 SSH 安装 GitHub Release 发布的二进制（可切换为源码构建），随后初始化 PKI、安装服务并输出注册凭据

> 本项目与 AcePanel、宝塔 / aaPanel、1Panel 均无任何隶属关系，未复制其任何代码或算法。
> 参考的仅是公开的产品功能描述。详见 [CLEANROOM.md](CLEANROOM.md)。

## 功能

| 模块 | 能力 |
| --- | --- |
| 概览 | 主机信息、CPU / 内存 / 磁盘 / 网络指标与趋势图（网卡可切换）、负载、刷新间隔可配置 |
| 文件 | 浏览、读取、在线编辑、新建、重命名、上传、下载；删除进入回收站；编辑自动保存历史版本 |
| 终端 | 基于 PTY 的 WebSocket 交互终端，支持窗口尺寸调整 |
| 服务 | systemd 单元列表、启停、重启、开机自启、日志（可搜索、按行数截断） |
| 进程 | 进程列表、PID/名称/命令搜索、TERM/KILL、详情（打开文件、监听端口、cwd、线程） |
| SSH | 二级导航（概览 / 密钥 / 日志）；sshd 状态与生效配置、安全项修改（校验+回滚）、authorized_keys 管理、日志记录方式（syslog/文件）与日志查询 |
| 软件 | 已安装软件的托管状态、确认后初始化（停止→写入托管配置→启动）、Fail2ban 卡片内合并的 jail/封禁/阈值管理 |
| 网站 | Nginx 站点生成、启停、配置校验后热重载 |
| 容器 | Docker（未安装时回退 Podman）全量管理：概览、容器创建 / 重建 / 终端 / 文件 / 日志 / 备注 / 导出、编排、镜像、网络、存储卷、镜像源与 Docker 设置；引擎缺失时给出安装引导 |
| 应用商店 | 内嵌 Docker Compose 应用目录、Linux 包管理器精选工具（含 fail2ban、Docker / Podman、rsyslog）、自定义包安装、Nix build / run（含自定义属性） |
| 运行环境 | 借宿主机 Docker 管理 Node / Python / Java / Go / PHP / Ruby / .NET / 自定义镜像；推荐+开放版本、包管理器镜像源；每环境「管理」页含日志 / 配置 / 扩展 / 进程 |
| 防火墙 | UFW 规则查看、放行、拒绝、删除 |
| WAF | Caddy + Coraza + 内嵌 OWASP CRS；risk gateway、TypeSafe 风险复检、GeoIP/GeoSite 选择器、detect/enforce、日志 |
| 计划任务 | 面板托管的 root crontab 区块（增删查） |
| 回收站 | 面板删除的文件/目录恢复、永久删除、清空 |
| 日志 | 面板审计日志与系统日志尾部查看 |
| AI 助手 | OpenAI 兼容 Chat Completions（流式）/ Responses；多对话侧栏、Markdown（含表格）渲染；系统设置勾选工具与敏感路径、人工审批、无 shell、删除仅回收站 |
| 主机设置 | Swap（交换文件或已有分区）、NTP 同步、GRUB2 启动项、/etc/hosts |
| 通知 | Bark / ntfy 推送（登录、AI 执行操作等事件），可在面板配置与测试 |
| 设置 | 二级导航：常规 / AI / 主机 / 关于；管理端自更新（通道 + GitHub 镜像）与受控端更新配置 |
| 安全 | 强制客户端证书校验、TLS 1.2+（优先 1.3）、CN 前缀校验、请求审计 |

## 架构

```
Flutter 客户端 ── mTLS (TLS 1.3) ──> hampaneld (Zig)
                                      ├── net     TLS / HTTP / WebSocket
                                      ├── http    解析、路由、响应
                                      ├── api     按功能拆分的处理器
                                      ├── sys     进程、PTY、/proc、命令执行
                                      └── pki     CA / 服务端 / 客户端证书签发
```

详细设计见 [docs/architecture.md](docs/architecture.md)。

## 目录

```
daemon/                 Zig 后端（按模块拆分）
  src/api/              薄处理器：校验 + JSON 编排
  src/http/             请求解析、响应、路由、WebSocket
  src/net/              TLS 连接与监听
  src/platform/         平台抽象层
    types.zig           跨平台数据结构
    linux/              Linux 后端（/proc、systemd、ufw、crontab、PTY）
    windows/            Windows 后端（Win32、PowerShell、服务包装）
  src/sys/              命令执行、/proc 采样
  src/store/            Docker Compose 应用目录与编排（YAML 内嵌）
  src/runtime/          运行环境目录、镜像构建与生命周期管理
  src/db.zig            SQLite 封装与迁移
  src/notify.zig        Bark / ntfy 推送
  src/versions.zig      文件历史版本（内容寻址）
  vendor/sqlite/        vendored SQLite amalgamation
  src/pki.zig           证书签发
  src/tls.zig           OpenSSL 封装
app/                    Flutter 客户端（Linux / Windows / macOS / Android / iOS）
app/assets/branding/    8-bit 火腿标志（SVG / PNG）
  lib/core/             mTLS 客户端、注册凭据、模型、客户端设置与自更新
  lib/features/         每个页面一个目录
  lib/ui/               主题、通用组件、Markdown 渲染
  android/ ios/         移动端工程（release 签名由 key.properties 或 CI secret 提供）
deploy/bootstrap.sh     远端 Linux 构建 / 安装脚本（在目标机执行）
deploy/windows/         Windows 安装脚本（服务 + 可选驱动）
windows/driver/         WDM 内核伴随驱动（C + INF）
tool/hampanelctl        SSH 编排 CLI
tool/package/           Linux AppImage / Windows 单文件 exe 打包脚本
flake.nix               Nix：构建 daemon、开发环境
docs/                   架构与接口文档（含 docs/store.md、docs/runtimes.md）
```

应用商店的实现与新增应用方式见 [docs/store.md](docs/store.md)；SSH 管理说明见
[docs/ssh.md](docs/ssh.md)；软件托管与初始化语义见 [docs/software.md](docs/software.md)；回收站与版本历史见 [docs/recycle.md](docs/recycle.md)，
AI 助手见 [docs/ai.md](docs/ai.md)；运行环境管理与 SQLite 存储见 [docs/runtimes.md](docs/runtimes.md)。

## 数据存储

运行期受管数据存放在 `<data-dir>/hampanel.db`（SQLite，vendored amalgamation，不依赖
系统 libsqlite3）：运行环境、可编辑配置、审计日志、更新状态与面板设置。`config.json`
仅保留为安装器的引导配置（监听、端口、TLS、入口前缀）。详见
[docs/runtimes.md](docs/runtimes.md)。

## 平台支持

| 平台 | 后端 | 客户端 | 说明 |
| --- | --- | --- | --- |
| Linux（glibc/musl） | 原生 | ✅ | systemd、/proc、ufw、crontab、PTY |
| Windows 10/11 Server | 原生 Win32 + PowerShell | ✅ | Windows 服务；防火墙、任务计划、进程、磁盘、网络均走系统 API |
| macOS | — | ✅ | 需 macOS 13+；按 Metal 能力自动选择 Impeller / Skia |
| Android | — | ✅ | CI 产出已签名 APK；移动端布局（抽屉式主菜单 + 紧凑二级菜单） |
| iOS | — | ✅ | 未签名 IPA 由 CI 产出，使用前需自行签名（侧载 / 自签工具） |

Windows 上 `hampaneld` 以 **Windows 服务**运行；`windows/driver/` 提供可选的
**内核伴随驱动**（`hampanel.sys`），通过控制设备暴露存活与版本信息。
HTTP/TLS/文件/进程等管理 API 保持在用户态，这是 Windows 网络与安全模型的
正确边界；驱动不承担 TLS 终止。详见 `windows/driver/README.md`。

## 发布产物

CI 在 `v*` tag 上发布正式版，在 `nightly` 分支上维护滚动预发布。每次发布包含：

| 产物 | 说明 |
| --- | --- |
| `hampanel-client-linux-x86_64.AppImage` | Linux 客户端，单文件；`chmod +x` 后直接运行 |
| `hampanel-client-windows-x86_64.exe` | Windows 客户端，单文件绿色版；双击运行 |
| `hampanel-client-macos-<arch>.dmg` | macOS 客户端（仅控制 Linux / Windows） |
| `hampanel-client-android-universal.apk` | Android 客户端，CI 使用发布密钥签名（v2 + v3）；未配置密钥时退化为 `-unsigned.apk` |
| `hampanel-client-ios-unsigned.ipa` | iOS 客户端，未签名，需自行签名后安装 |
| `hampanel-daemon-linux-x86_64.tar.gz` | `hampaneld`、风险网关、`bootstrap.sh`、`install.sh` |
| `hampanel-daemon-windows-x86_64.zip` | `hampaneld.exe`、OpenSSL DLL、`install.ps1` |
| `hampanel-install-linux.sh` / `hampanel-install-windows.ps1` | 一键安装器；默认装发布二进制，也可源码构建 |
| `version.txt` / `SHA256SUMS.txt` / `LICENSE.txt` | 版本、校验和与许可证 |

AppImage 依赖系统自带的 GTK3 运行库（主流桌面发行版均已提供）；若系统缺少
FUSE（`libfuse2`），可用 `./hampanel-*.AppImage --appimage-extract-and-run` 运行。
Windows 绿色版首次运行时会解压到用户临时目录并启动客户端，凭据与配置仍保存在
`%APPDATA%\Hampanel`，不写入安装目录。macOS 客户端未签名，首次打开需右键「打开」；
需要 macOS 13 或更高版本。客户端会检测 Metal GPU Family：Metal 2 及以上使用
Impeller，老款 GPU 自动回退 Skia；也可用 `FLTEnableImpeller` 显式覆盖。
iOS 的 IPA 同样未签名，需要用自己的证书和描述文件重新签名后侧载。

Android 签名使用仓库 secrets：`ANDROID_KEYSTORE_BASE64`（PKCS#12 的 base64）、
`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。本地构建时也可以提供
`app/android/key.properties`（`storeFile` / `storePassword` / `keyAlias` / `keyPassword`），
或设置同名环境变量 `HAMPANEL_ANDROID_KEYSTORE*`。缺少密钥时 APK 不会被签名。

签名证书为自签名，`CN=Dawncall`，有效期 30 年；`apksigner verify --print-certs` 可核对
指纹 `c0:e1:e4:2f:…:98:85`。请务必离线备份该 keystore：Android 只允许用同一把密钥
升级已安装的应用，丢失后就只能卸载重装。

### 安装方式与更新

- **发布二进制**（默认）：按所选通道直接从 GitHub Release 下载对应架构的产物并校验
  `SHA256SUMS.txt`。`stable` 对应正式 Release（tag），`nightly` 对应滚动预发布；
  不会自动切换通道。daemon 记录 `install_mode=binary`，安装时自动加入每日更新检查
  （Linux `/etc/cron.d/hampanel-update`，Windows 计划任务 `\Hampanel\update`），并在
  面板「设置 → 常规 → 更新」中提供检查/立即更新、通道选择与 GitHub 镜像配置。
  镜像既是安装期参数也可以长期修改：`--github-mirror <url>` 会写入 daemon 配置，
  Release 查询与下载都会经该前缀（只拼接一次）。

管理端自身也可以在「设置 → 常规 → 管理端更新」中先选择 `stable` / `nightly` 通道，
再检查新版本；同一个卡片支持配置 GitHub 镜像，并直接跳到对应平台的安装包。
- **源码构建**：必须显式选择通道或引用，`--channel stable` 解析为最新正式 tag，
  `--channel nightly` 拉取 nightly 分支，也可用 `--ref <tag|branch>` 指定。daemon
  记录 `install_mode=source`，**不会**启用更新检查，面板 API 也会拒绝再添加检查更新
  的计划任务。

> 当前尚未发布正式版，请使用 `--channel nightly`（Linux）或 `-Channel nightly`
> （Windows）安装预发布产物；`stable` 会在没有正式 Release 时给出明确错误。

## 快速开始

### 1. 远端部署

`hampanelctl` 默认安装 GitHub Release 发布的二进制；加 `--mode source` 则上传并构建本地源码。

```bash
# 需要本地已配置好免密 SSH；远端需要 Linux + root/sudo
dart run tool/hampanelctl/bin/hampanelctl.dart deploy \
  --host 203.0.113.10 --user root \
  --san 203.0.113.10 \
  --out hampanel-203.0.113.10.json

# 当前只有预发布：显式选择 nightly
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --channel nightly \
  --host 203.0.113.10 --user root --san 203.0.113.10

# 从源码构建（不启用更新检查）
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --mode source \
  --host 203.0.113.10 --user root \
  --san 203.0.113.10
```

安装器会自动：

1. 按通道下载并校验对应架构的 release 产物（或拉取源码并编译）
2. 安装 `/usr/local/bin/hampaneld`（源码模式还包含风险网关）与 systemd 单元
3. 自动选择空闲端口并生成随机安全入口前缀（如 `/a1b2c3d4e5f6`），随后生成 CA、服务端证书、客户端证书并启动服务
4. 二进制模式自动加入每日更新检查；源码模式不启用
5. 将注册凭据（CA + 客户端证书 + 私钥 + endpoint + 入口前缀）保存为本地 JSON

也可以直接在目标机执行安装器：

```bash
# 正式版发布后使用 latest；当前请使用 nightly 预发布
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode binary --channel nightly --endpoint 203.0.113.10

# 源码构建（stable 按 tag，nightly 按分支；也可 --ref <tag|branch>）
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode source --channel nightly --endpoint 203.0.113.10
```

### Windows 部署

在目标 Windows 机器（管理员 PowerShell）执行发布二进制安装器：

```powershell
Invoke-WebRequest -UseBasicParsing `
  https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-windows.ps1 `
  -OutFile install.ps1
.\install.ps1 -Endpoint 203.0.113.10 -San 203.0.113.10 -Channel nightly
# 源码构建：.\install.ps1 -Mode source -Channel nightly -Endpoint ... -San ...
# 或按 tag 构建：.\install.ps1 -Mode source -Ref v0.1.0 -Endpoint ... -San ...
# 可选：-InstallDriver 安装内核伴随驱动（需测试签名）
```

安装器会安装为 `hampanel` 服务、生成 PKI、放行防火墙端口，并输出
`C:\ProgramData\hampanel\enroll.json`。

通过 SSH 编排 Windows 目标：

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --os windows \
  --host 203.0.113.10 --user Administrator \
  --endpoint 203.0.113.10 --san 203.0.113.10
```

### 2. 客户端

```bash
cd app
flutter pub get
flutter run -d linux        # Windows: -d windows，macOS: -d macos
flutter run -d android      # 或 -d ios；移动端为管理端，需能访问受控端端口
```

首次启动粘贴上一步生成的注册凭据 JSON。客户端会自动使用其中的 endpoint、
客户端证书和安全入口前缀建立 mTLS 连接，无需手动填写端口或路径。

如果还没有可管理的主机，登录页提供 **「通过 SSH 安装」**：填写主机、端口、
用户与密码或私钥，选择「发布二进制」或「从头构建」，客户端会调用对应平台的
安装器并自动导入生成的注册凭据。发布二进制安装会启用每日更新检查；源码构建
不会启用，面板 API 也会拒绝添加更新检查任务。

### 应用商店

登录后打开「应用商店」：

- **Docker 应用**：部署 Nginx、Redis、PostgreSQL、MariaDB、MinIO、Gitea 等
  Compose 应用；支持启停、日志、卸载，密码留空时自动生成。
- **系统工具**：检测 apt/dnf/yum/zypper/pacman/apk，一键安装 Git、htop、jq、
  ripgrep 等精选工具。
- **Nix**：检测 Nix 环境，白名单属性可执行 `nix build` / `nix run`；仓库同时
  提供 `flake.nix`，见 [docs/store.md](docs/store.md)。

##### Nix

```bash
nix build .#default
nix run .#default -- version
nix develop
```

### 手动编译 daemon

```bash
cd daemon
zig build -Doptimize=ReleaseSafe
# 省略端口时自动选择空闲端口，并生成随机入口前缀
./zig-out/bin/hampaneld init --endpoint <服务器IP或域名>
./zig-out/bin/hampaneld run

# 也可以显式指定：--port 8443 --entry-prefix /my-secret-entry
# 或关闭前缀：--entry-prefix ""
```

依赖：Zig 0.17.1+、OpenSSL 1.1.1+/3.x（开发头文件）、Linux、glibc。

## 安全模型

- 服务端只接受由本项目 CA 签发、CN 以 `hampanel-client` 开头的客户端证书；没有有效客户端证书的 TLS 握手直接失败。
- 私钥落盘权限 `0600`（Windows 使用 `%ProgramData%` 的 ACL 继承），Linux TLS 目录 `0700`。
- 所有操作命令使用 argv 直接执行，不经过 shell；容器名、单元名、UFW 规则、任务名均做白名单校验。
- PowerShell 调用只拼接经过校验的端口、IP、动作与转义后的显示名，不接收任意脚本。
- 客户端信任固定 CA，不做「忽略证书错误」。
- 初始化时默认随机选择监听端口，并生成 `/` + 96 位随机 token 的入口前缀。除
  健康检查等 API 外，所有请求都必须携带该前缀，否则直接返回 404；前缀随
  注册凭据下发，客户端自动拼接。前缀只是额外的隐蔽层，**不能替代 mTLS**。
- 面板需要 root / Administrator 权限管理系统服务；建议仅监听内网或通过防火墙限制端口。
- Windows 驱动是**可选**组件，只暴露 `\\.\Hampanel` 控制设备与两个 IOCTL；加载未签名驱动需要测试签名模式。

## 开发与验证

```bash
# 后端单元测试 + Windows 后端类型检查
cd daemon && zig build test && zig build check-windows

# Flutter 静态检查与测试
cd app && flutter analyze && flutter test
```

时间戳统一使用本机时区渲染（epoch 秒/毫秒与 ISO-8601 都会转成本地时间），
因此界面里不会再混用 UTC 与本地时间。

版本格式为 `0.1.0+<git 短哈希>`（工作区有未提交修改时追加 `.dirty`）。
`daemon/build.zig` 在编译时自动执行 `git rev-parse --short HEAD`，也可用
`-Dcommit=<hash>` 覆盖（CI 打包时有用）。Flutter 客户端通过
`--dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)` 注入相同哈希：

```bash
cd app
flutter build linux --release \
  --dart-define=HAMPANEL_VERSION=0.1.0 \
  --dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)
```

## 状态

`0.1.0` — 可用骨架：mTLS 通道、核心 API、Flutter 客户端、远端部署链路。

已验证：

- Linux：Zig 单元测试、真实 mTLS 握手、证书链校验、文件上传/下载、终端
  WebSocket、Docker API、bootstrap 本地构建安装。
- Windows：Windows 后端通过 `zig build check-windows` 跨平台类型检查；
  Win32 / PowerShell 逻辑尚未在 Windows 主机上运行验证。
- Flutter：`flutter analyze`、`flutter test`（含响应式布局与 Markdown 表格）、
  各平台 release 构建由 CI 覆盖：Linux AppImage、Windows 单文件 exe、macOS dmg、
  Android 签名 APK、iOS 未签名 IPA。
- 内核驱动与 Windows 服务安装脚本需要 WDK / 测试签名后在真实 Windows
  环境验证。

## 许可证

GNU General Public License v3.0 or later。见 [LICENSE](LICENSE)。

```
SPDX-License-Identifier: GPL-3.0-or-later
```
