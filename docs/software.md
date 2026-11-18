# 软件托管与初始化

「软件」页面列出 Hampanel 能托管的软件。安装状态由后端实时检测；如果操作系统
已经有该软件但尚未托管，会显示 **待初始化**。

## 初始化流程

初始化必须由用户在确认对话框中勾选“我明白服务会短暂中断”后才能调用：

1. 停止现有服务（例如 `fail2ban` 或 `nginx`）。
2. 写入 Hampanel 托管配置：
   - Fail2ban：`/etc/fail2ban/jail.d/99-hampanel.local`，保留系统原有配置。
   - Nginx：创建 `/etc/nginx/conf.d/hampanel` 并由「网站」页面接管站点。
3. 执行配置校验（`fail2ban-client -t` / `nginx -t`）。
4. 设置开机自启并启动服务。
5. 在 `<data_dir>/software/<id>.json` 写入托管状态。

任一步失败都会恢复原有托管文件，并尝试重新启动原服务。原始系统配置不会被覆盖。

## Fail2ban 管理

初始化后，Fail2ban 的管理区会直接并入该软件的卡片（不再单独多出一张卡片），可以：

- 查看 jail、当前/累计失败与封禁数量。
- 查看封禁 IP 并一键解封。
- 对指定 jail 手动封禁 IP（IPv4 / IPv6）。
- 修改 `maxretry`、`bantime`、`findtime`：写入托管配置，`fail2ban-client -t`
  校验后 `reload`；失败自动回滚。

## 其他软件

- **Nginx**：初始化后请使用「网站」页面创建、启停和重载站点。
- **Docker**：无需改写配置，直接使用「容器」或「应用商店」。
- **SSH**：使用独立的「SSH」页面管理，避免与初始化的服务停止逻辑冲突。

## 接口

初始化通过 `POST /api/v1/tasks` `kind=software.initialize` `params={"id":"<软件 ID>"}`
提交，任务输出记录停止、写入配置与启动的完整过程，见 [tasks.md](tasks.md)。

## 安全说明

初始化会中断服务数秒。生产环境建议先保留一个可用会话，并确认防火墙/安全组
不会阻断新配置。所有操作仅对已认证的 mTLS 客户端开放。

## 二进制与 CPU 兼容性

发布到 Release 的 `hampaneld` 由 CI 使用 `-Dcpu=baseline` 构建，面向最基础的
x86-64 指令集，因此可以在不支持 AVX / AVX-512 / POPCNT 等扩展的旧服务器上运行。
源码构建默认按构建机 CPU 生成指令，如果要分发给其他机器，请显式加上
`-Dcpu=baseline`。

更新器在替换当前二进制前会先执行新版 `hampaneld version`；如果新二进制无法启动
（例如 CPU 指令集不兼容），会保留旧版本并返回 `UpstreamBinaryUnusable`，不会把
服务换成崩溃的版本。

如果不慎安装了会崩溃的旧 nightly，重新运行安装脚本即可恢复：

```sh
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh -o /tmp/hampanel-install.sh
sudo bash /tmp/hampanel-install.sh --mode binary --channel nightly
```

安装脚本会保留现有配置与 PKI，只替换程序文件。
