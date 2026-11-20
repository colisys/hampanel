---
title: 安装受控端
description: 在 Linux 或 Windows 服务器上安装 hampaneld。
outline: [2, 3]
---

# 安装受控端

受控端只支持 Linux 和 Windows。macOS、iOS、Android 只能作为客户端。

三种安装方式，按你的场景选一种：

| 方式 | 适用 | 特点 |
| --- | --- | --- |
| 图形安装（推荐） | 手头有客户端、刚开始用 | 在客户端启动页填写 SSH 信息，装完自动导入凭据 |
| 命令行编排 | 批量部署、运维机操作 | 一条 `hampanelctl` 命令完成远程安装 |
| 目标机本地脚本 | 无法从外部 SSH 接入 | 在服务器上直接执行安装脚本 |

## 方式一：客户端 SSH 安装

1. 打开客户端启动页，选择 **通过 SSH 安装**。
2. 填写主机地址、SSH 端口、用户名，以及密码或私钥。
3. 选择 **发布二进制** 或 **从头构建**。
4. 等待安装完成，凭据会自动导入。

前提是目标机可以通过 SSH 登录，Linux 需要 root 或 sudo 权限。

## 方式二：hampanelctl 远程安装

本机需已配置免密 SSH。默认安装 GitHub Release 发布的二进制并校验 `SHA256SUMS.txt`。

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy \
  --channel nightly \
  --host [IP] --user root \
  --san [IP] \
  --out enroll.json
```

Windows 目标加 `--os windows`，并使用管理员账户：

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --os windows \
  --channel nightly \
  --host [IP] --user Administrator \
  --endpoint [IP] --san [IP]
```

改为源码构建加 `--mode source`。源码模式拉取仓库代码在目标机编译，不会启用更新检查。

## 方式三：目标机本地安装

**Linux**（root 权限）：

```bash
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode binary --channel nightly --endpoint [IP]
```

**Windows**（管理员 PowerShell）：

```powershell
Invoke-WebRequest -UseBasicParsing `
  https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-windows.ps1 `
  -OutFile install.ps1
.\install.ps1 -Channel nightly -Endpoint [IP] -San [IP]
```

## 安装器做了什么

1. 按通道下载对应架构的发布产物并校验哈希（源码模式跳过）。
2. 安装 `/usr/local/bin/hampaneld` 与 systemd 单元（Windows 为 `hampanel` 服务）。
3. 自动选择空闲端口，生成随机入口前缀。
4. 生成 CA、服务端证书与客户端证书并启动服务。
5. 二进制模式写入每日更新检查；源码模式不写入。
6. 输出注册凭据 `enroll.json`。

Windows 的凭据位于 `C:\ProgramData\hampanel\enroll.json`，Linux 默认在 `/etc/hampanel/enroll.json`。

::: warning 妥善保管注册凭据
`enroll.json` 含有客户端私钥，导入后即可管理服务器。通过可信渠道传输，不要贴在工单、截图或公开仓库里。
:::

## 通道选择

`stable` 对应正式 tag，`nightly` 对应当前滚动预发布。两者不会互相回退。仓库目前以 nightly 分支持续发布，正式版发布后可直接改用 `stable`。

## 手动部署

想完全自己控制构建过程时，直接用 Zig 编译：

```bash
cd daemon
zig build -Doptimize=ReleaseSafe
./zig-out/bin/hampaneld init --endpoint <服务器IP或域名>
./zig-out/bin/hampaneld run
```

依赖 Zig 0.17.1+ 与 OpenSSL 开发库。也可以 `nix build .#default`。

## 接下来

[安装客户端](/guide/client) →