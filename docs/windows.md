# Windows 部署说明

## 组件

| 组件 | 路径 | 说明 |
| --- | --- | --- |
| `hampaneld.exe` | `%ProgramFiles%\Hampanel` | 用户态服务，mTLS API |
| `hampanel.sys` | 可选 | 内核伴随驱动，控制设备 `\\.\Hampanel` |
| 配置 | `%ProgramData%\hampanel\config.json` | 监听地址、端口、路径、安装方式、更新通道与 GitHub 镜像 |
| 注册凭据 | `%ProgramData%\hampanel\enroll.json` | 导入 Flutter 客户端 |

## 前置条件

- Windows 10/11 或 Windows Server 2019+
- Zig 0.17.1+（未安装时安装脚本会下载）
- OpenSSL 开发库：`vcpkg install openssl:x64-windows`，并把
  `installed\x64-windows` 作为 `-OpenSslDir`
- 管理员 PowerShell
- 可选：Visual Studio 2022 + WDK 10（仅编译内核驱动需要）

## 安装

```powershell
.\deploy\windows\install.ps1 `
  -Source (Get-Location) `
  -Endpoint 203.0.113.10 `  # 省略端口时自动选择空闲端口并生成随机入口前缀
  -San 203.0.113.10 `
  -OpenSslDir C:\vcpkg\installed\x64-windows
```

脚本执行：

1. 下载 Zig（如缺失）并校验 OpenSSL 库
2. `zig build -Doptimize=ReleaseSafe -Dopenssl-dir=...`
3. 复制 `hampaneld.exe` 与 OpenSSL DLL 到安装目录
4. 自动选择空闲端口、生成随机入口前缀、签发 CA/服务端/客户端证书
5. 注册并启动 `hampanel` 服务（`--service` 模式）
6. 读取实际配置的端口并创建入站防火墙规则

## 内核伴随驱动（可选）

```powershell
cd windows\driver
.\build.ps1
cd ..\..
.\deploy\windows\install.ps1 -InstallDriver -SkipBuild -OpenSslDir C:\vcpkg\installed\x64-windows
```

开发环境需开启测试签名：

```powershell
bcdedit /set testsigning on
# 重启
sc.exe create HampanelDriver type= kernel start= demand binPath= "C:\Program Files\Hampanel\hampanel.sys"
sc.exe start HampanelDriver
```

> 驱动只提供存活与版本 IOCTL。HTTP、TLS、文件与进程管理保留在用户态，
> 这是 Windows 的安全边界；不要试图在驱动中终止 TLS。

## 服务管理

实际端口与入口前缀可从配置或注册凭据读取：

```powershell
Get-Content C:\ProgramData\hampanel\config.json | ConvertFrom-Json |
  Select-Object port, entry_prefix, endpoint

sc.exe query hampanel
sc.exe stop hampanel
sc.exe start hampanel
Get-Content C:\ProgramData\hampanel\data\audit.jsonl -Tail 20
```

## 限制

- 终端使用 `cmd.exe` 管道会话，尚未接入 ConPTY，交互式全屏程序体验有限。
- 站点管理（Nginx）在 Windows 上标记为不可用。
- 计划任务将常见 cron 表达式映射为任务计划程序；复杂表达式会返回 501。
- 未签名驱动无法在默认配置的 Windows 上加载。
- 服务端更新与 Linux 共用同一套 Release 逻辑：`--github-mirror` 会写入
  `config.json`，可在面板「设置 → 常规 → 更新」中修改通道与镜像。
