# Hampanel

[![稳定版](https://img.shields.io/github/actions/workflow/status/colisys/hampanel/build.yml?branch=main&label=%E7%A8%B3%E5%AE%9A%E7%89%88)](https://github.com/colisys/hampanel/actions/workflows/build.yml)
[![nightly](https://img.shields.io/github/actions/workflow/status/colisys/hampanel/build.yml?branch=nightly&label=nightly)](https://github.com/colisys/hampanel/actions/workflows/build.yml)

Hampanel 是 GPL-3.0-or-later 授权的开源服务器运维面板：Flutter 桌面 / 移动客户端通过双向 TLS 连接部署在 Linux 或 Windows 上的 Zig 受控端 `hampaneld`。客户端提供界面并保存主机凭据，文件、终端、服务、容器、网站等操作在受控端执行。功能和平台支持见[文档站](https://hampanel.dawncall.work/guide/)或仓库内的 [website/docs/features](website/docs/features/index.md)。

> 本项目为 CleanRoom 实现，与 AcePanel、宝塔 / aaPanel、1Panel 无隶属关系。详见 [CLEANROOM.md](CLEANROOM.md)。

## 快速开始

1. 在 Linux 或 Windows 服务器上[安装受控端](https://hampanel.dawncall.work/guide/install)；当前使用 `nightly` 预发布通道。例如在目标 Linux 主机上（替换 `YOUR_SERVER_IP`）：

   ```bash
   curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
     | sudo bash -s -- --mode binary --channel nightly --endpoint YOUR_SERVER_IP
   ```

   也可从客户端启动页通过 SSH 安装，或用 `hampanelctl` 远程部署；Windows、源码构建及权限要求见[安装指南](https://hampanel.dawncall.work/guide/install)。
2. 从 [GitHub Releases](https://github.com/colisys/hampanel/releases/tag/nightly) 下载适合设备的客户端（Linux、Windows、macOS、Android 或 iOS；iOS 包需要自行签名）。
3. 通过可信渠道取得安装器生成的 `enroll.json`，在客户端启动页导入并连接。该文件**包含客户端私钥**，不要提交到仓库或发到公开聊天。详见[首次连接与排障](https://hampanel.dawncall.work/guide/first-connect)。

受控端需要管理员权限；建议仅通过内网访问或限制管理端口的来源。macOS 和移动端只能作为客户端。[平台差异](https://hampanel.dawncall.work/reference/platforms) · [升级与更新](https://hampanel.dawncall.work/guide/update)

## 文档与开发

- [使用文档](https://hampanel.dawncall.work/)（仓库源码：[website/docs](website/docs/index.md)）：安装、功能操作、应用商店及常见问题。
- [架构](docs/architecture.md) · [安全模型](docs/security.md) · [应用商店实现](docs/store.md) · [任务队列](docs/tasks.md)：面向贡献者的设计说明。
- 代码目录：`daemon/` 为 Zig 受控端，`app/` 为 Flutter 客户端，`deploy/` 为安装脚本，`tool/hampanelctl/` 为 SSH 部署工具，`website/` 为 VitePress 文档站。

本地验证（需要相应 Zig / Flutter 工具链）：

```bash
cd daemon && zig build test && zig build check-windows
cd ../app && flutter analyze && flutter test
```

许可证：[GNU GPL-3.0-or-later](LICENSE)。
