---
title: 安装受控端
description: 在 Linux 或 Windows 服务器上安装 hampaneld，以及安装参数、校验与排查。
outline: [2, 3]
---

# 安装受控端

受控端支持 Linux 与 Windows；macOS、iOS、Android 只作为客户端。安装需要管理员权限：Linux 用 root 或 sudo，Windows 用管理员账户。

三种安装方式：

| 方式 | 适用 | 特点 |
| --- | --- | --- |
| 客户端 SSH 安装 | 手头已有客户端 | 在启动页填写 SSH 信息，装完自动导入凭据 |
| `hampanelctl` 远程安装 | 批量部署、从运维机操作 | 一条命令完成上传、安装与凭据回传 |
| 目标机本地安装 | 无法从外部 SSH 接入 | 在服务器上直接执行安装脚本 |

安装前确认：

- 目标机可以用 SSH 或控制台登录，并具备管理员权限。
- 准备一个客户端能访问的地址（IP 或域名）作为 `--endpoint`；填错会导致凭据里的连接地址不可用。
- Linux 目标机需能下载发布产物；源码模式会准备 Zig 0.17.1+ 和 OpenSSL 开发库等构建依赖。默认以 systemd 托管服务。
- 端口默认随机选择空闲端口；如需固定端口，加 `--port`。

## 方式一：客户端 SSH 安装

1. 打开客户端启动页，选择 **通过 SSH 安装**。
2. 填写主机地址、SSH 端口、用户名，以及密码或私钥。
3. 选择 **发布二进制** 或 **从头构建**。
4. 安装过程中保持窗口打开；完成后凭据自动导入，可直接连接。

发布二进制模式会启用每日更新检查；从头构建不会启用。

## 方式二：hampanelctl 远程安装

在仓库根目录运行。本机需已配置免密 SSH：

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy \
  --channel nightly \
  --host [IP] --user root \
  --san [IP] \
  --out enroll.json
```

Windows 目标加 `--os windows` 并使用管理员账户：

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --os windows \
  --channel nightly \
  --host [IP] --user Administrator \
  --endpoint [IP] --san [IP]
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--host` / `--user` | 目标机地址与登录用户，`--user` 默认 `root` |
| `--ssh-port` / `--identity` | SSH 端口（默认 22）与私钥路径 |
| `--endpoint` | 写入凭据的服务地址；省略时使用 `--host` |
| `--san` | 追加证书 SAN，可重复 |
| `--channel` | `stable` 或 `nightly` |
| `--mode` | `binary`（默认）或 `source` |
| `--out` | 凭据保存到本机的路径 |

源码模式在目标机编译，安装过程更长，且不启用更新检查。

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

安装脚本参数：

| 参数（Linux / Windows） | 说明 |
| --- | --- |
| `--endpoint` / `-Endpoint` | 对外服务地址，必填 |
| `--mode` / `-Mode` | `binary`（默认）或 `source` |
| `--channel` / `-Channel` | `stable` 或 `nightly` |
| `--ref` / `-Ref` | 源码模式使用的 tag 或分支 |
| `--port` / `-Port` | 固定监听端口，默认随机 |
| `--entry-prefix` / `-EntryPrefix` | 固定入口前缀，默认随机 |
| `--san` / `-San` | 追加证书 SAN，可重复 |
| `--github-mirror` / `-GithubMirror` | GitHub 镜像前缀 |
| `--prefix`、`--config-dir`、`--data-dir`、`--tls-dir`、`--enroll-file` | 自定义安装与数据路径（Linux） |
| `--service-name` / `-ServiceName` | 服务名，默认 `hampanel` |
| `--mirror` | 系统包镜像预设，Linux 源码模式使用 |
| `--no-systemd`（Linux）、`--no-start` / `-NoStart` | 不安装服务单元 / 安装后不启动 |
| `-InstallDriver` | 安装 Windows 内核伴随驱动（需测试签名） |

## 安装器做了什么

1. 按通道下载对应架构的发布产物并校验 `SHA256SUMS.txt`（源码模式跳过下载，改为拉取代码并编译）。
2. 安装程序与服务：Linux 写入 `/usr/local/bin/hampaneld` 与 systemd 单元；Windows 安装为 `hampanel` 服务。
3. 选择空闲端口，生成随机入口前缀（可用上面的参数固定）。
4. 在宿主防火墙上放行该端口：Linux 走 ufw 或 firewalld，Windows 新增名为 `Hampanel Panel (<端口>)` 的入站规则。云安全组需自行放行。
5. 生成 CA、服务端证书与客户端证书，写入配置并启动服务。
6. 二进制模式写入每日更新检查；源码模式不写入。
7. 输出注册凭据 `enroll.json`。

凭据位置：Linux `/etc/hampanel/enroll.json`，Windows `C:\ProgramData\hampanel\enroll.json`。

::: warning 妥善保管注册凭据
`enroll.json` 含有客户端私钥，导入后即可管理服务器。通过可信渠道传输，不要贴在工单、截图或公开仓库里。
:::

## 安装后检查

```bash
# Linux
systemctl status hampanel
ss -lntp | grep hampaneld
sudo ls -l /etc/hampanel/enroll.json
```

```powershell
# Windows
Get-Service hampanel
Get-NetTCPConnection -State Listen | Where-Object OwningProcess -in (Get-Process hampaneld).Id
Test-Path C:\ProgramData\hampanel\enroll.json
```

服务在运行、端口在监听、凭据文件已生成，就可以安装客户端并导入。端口不通时依次检查 endpoint 与端口是否和实际监听一致、宿主防火墙是否有对应规则、云安全组是否放行。

安装脚本的输出会直接列出端口、入口前缀与凭据路径；失败时先看该输出末尾的错误。安装后排查服务：Linux 用 `journalctl -u hampanel -n 200`，Windows 用 `Get-Service hampanel` 与「事件查看器 → Windows 日志」，服务名不是 `hampanel` 时替换为实际名称。

## 通道选择

`stable` 对应正式 tag，`nightly` 对应当前滚动预发布。两者不会互相回退。仓库目前以 nightly 分支持续发布；正式版发布后改用 `stable` 即可。

## 手动构建与运行

需要完全控制构建过程时，直接用 Zig 编译：

```bash
cd daemon
zig build -Doptimize=ReleaseSafe
./zig-out/bin/hampaneld init --endpoint <服务器IP或域名>
./zig-out/bin/hampaneld run
```

`init` 默认自动选择空闲端口并生成随机入口前缀，也可以显式指定：

```bash
./zig-out/bin/hampaneld init --endpoint 203.0.113.10 \
  --port 8443 --entry-prefix /my-secret-entry
```

依赖 Zig 0.17.1+、OpenSSL 1.1.1+/3.x 开发库。也可以 `nix build .#default`，见[应用商店的 Nix 入口](/store/tools#nix)。

## 接下来

[安装客户端](/guide/client) →