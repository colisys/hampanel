# Hampanel 客户端

Flutter 桌面客户端，支持 Linux 与 Windows。

## 功能页面

- 概览：主机信息、CPU / 内存 / 磁盘 / 网络实时指标
- 进程：按内存排序，搜索名称 / PID / 命令
- 文件：目录浏览、在线编辑、新建、重命名、上传、下载；删除进入回收站，保存自动生成历史版本
- 回收站：恢复、永久删除、清空
- AI 助手：OpenAI 兼容协议，钥匙串保存密钥；系统设置勾选工具与敏感路径，修改操作强制人工审核
- 终端：基于 xterm 的 PTY 会话，WebSocket over mTLS
- 服务：systemd（Linux）/ Windows 服务管理，日志查看
- 网站：Nginx 站点创建、启停、删除、重载（Linux）
- 容器：Docker 容器与镜像，启停、删除、日志
- 防火墙：UFW（Linux）/ Windows Firewall 规则管理
- WAF：Caddy+Coraza+CRS 边缘，detect/enforce，一键构建与日志查看
- 计划任务：root crontab 区块（Linux）/ 任务计划程序（Windows）
- 日志：面板审计与服务端日志尾部
- 应用商店：Docker Compose 应用、Linux 包管理器工具（含 fail2ban）、Nix build/run
- SSH：sshd 状态与配置修改（校验/回滚）、authorized_keys 管理、日志模式切换与日志查看
- 软件：已安装软件的初始化确认、Fail2ban jail / 封禁 / 阈值管理
- 设置：连接测试、证书指纹、凭据导出

## 运行

```bash
flutter pub get
flutter run -d linux      # 或 -d windows / -d macos
```

首次启动需要粘贴服务端生成的 enrollment JSON（`hampaneld init` 或
`hampanelctl deploy` 的输出）。凭据中包含随机端口与安全入口前缀，客户端会
自动拼接，无需手动配置。凭据保存在：

- Linux/macOS: `~/.config/hampanel/enrollment.json`
- Windows: `%APPDATA%\Hampanel\enrollment.json`

如果还没有可管理的主机，登录页可以「通过 SSH 安装」：填写主机、端口、用户
与密码或私钥，选择发布二进制或源码构建，客户端会调用官方安装器并自动导入
注册凭据。macOS 客户端只用于控制 Linux / Windows 上的 daemon。

## 构建

```bash
# 版本 = 0.1.0 + git 短哈希（服务端版本由 /health 自动显示）
flutter build linux --release \
  --dart-define=HAMPANEL_VERSION=0.1.0 \
  --dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)
flutter build windows --release \
  --dart-define=HAMPANEL_VERSION=0.1.0 \
  --dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)
flutter build macos --release \
  --dart-define=HAMPANEL_VERSION=0.1.0 \
  --dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)
```

### 打包成单文件

```bash
# Linux：AppImage（脚本自动下载并缓存 appimagetool，图标取自 Windows 应用图标）
bash ../tool/package/appimage.sh
# 产物：build/packaging/hampanel-<版本>-x86_64.AppImage

# Windows：单文件绿色 exe（需要 7-Zip；脚本自动下载并缓存 7zSD.sfx）
dart ../tool/package/windows_portable.dart \
  --bundle build/windows/x64/runner/Release \
  --output build/packaging/hampanel-<版本>-windows-x86_64.exe
```

Windows 单文件 exe 内嵌压缩后的客户端，运行时解压到临时目录并启动
`hampanel.exe`；配置仍保存在 `%APPDATA%\Hampanel`，退出后临时文件自动清理。
AppImage 为单文件，`chmod +x` 后可直接运行，依赖系统 GTK3 运行库。

客户端通过 `SecurityContext` 加载 CA、客户端证书与私钥，强制校验证书链与
主机名；不会使用「忽略证书错误」的回调。因此服务端证书 SAN 必须包含你
连接时使用的主机名或 IP（部署时通过 `--san` 指定）。

## 常见问题

- **TLS 握手失败**：检查 `--san` 是否覆盖客户端使用的地址；重新初始化会
  生成新的 CA，需要重新导入 enrollment。
- **终端空白**：确认服务端 PTY 可用；Windows 当前使用 `cmd.exe` 管道会话。
- **网站页面不可用**：Linux 需要安装 Nginx；Windows 版本暂不提供站点管理。
- **上传/下载**：桌面端通过路径输入框指定本地文件路径，不依赖平台文件选择器。
